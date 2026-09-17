#import "StartupPermission.h"
#import <AppKit/AppKit.h>
#include <errno.h>
#include <fcntl.h>
#include <os/log.h>
#include <sys/stat.h>
#include <unistd.h>

static int SOVEXTDataAccessError(void);

@interface SOVEXTStartupPermissionAlert : NSAlert
@property BOOL dataAccessible;
@property BOOL reopening;
@end

@implementation SOVEXTStartupPermissionAlert
- (void)refreshPermission {
    if (self.reopening) return;
    BOOL accessible = SOVEXTDataAccessError() == 0;
    if (accessible == self.dataAccessible) return;
    self.dataAccessible = accessible;
    self.buttons.firstObject.title = accessible ? @"打开微信" : @"打开系统设置";
    self.messageText = accessible ? @"微信数据访问已恢复" : @"微信缺少数据访问权限";
    self.informativeText = accessible ? @"点击“打开微信”继续。" :
        @"1. 系统设置 → 隐私与安全 → 文件与文件夹，允许微信访问“微信”数据。\n\n"
         "2. 返回此窗口，点击“打开微信”。";
    os_log(OS_LOG_DEFAULT, "SOVEXT_STARTUP_PERMISSION: guidance access=%{public}s",
        accessible ? "accessible" : "denied");
}

- (void)openSettings:(id)sender {
    (void)sender;
    if (self.reopening) return;
    [self refreshPermission];
    if (self.dataAccessible) {
        self.reopening = YES;
        self.buttons.firstObject.enabled = NO;
        [self.window orderOut:nil];
        // A normal launch must wait for this early AppKit guide to leave.
        // Forcing a second instance while it is alive can split the Dock identity.
        NSTask *relauncher = [[NSTask alloc] init];
        relauncher.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
        NSString *script = @"attempt=0; while kill -0 \"$1\" 2>/dev/null; do "
            "attempt=$((attempt + 1)); [ \"$attempt\" -lt 300 ] || exit 1; "
            "/bin/sleep 0.1; done; /usr/bin/open \"$2\" || "
            "/usr/bin/logger -t SovietExtension 'Permission recovery: reopen failed; open WeChat manually'";
        relauncher.arguments = @[@"-c", script,
            @"sovext-permission-relaunch", [NSString stringWithFormat:@"%d", getpid()],
            NSBundle.mainBundle.bundlePath];
        relauncher.standardInput = NSFileHandle.fileHandleWithNullDevice;
        relauncher.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        relauncher.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSError *error = nil;
        if ([relauncher launchAndReturnError:&error]) _exit(0);
        os_log_error(OS_LOG_DEFAULT, "SOVEXT_STARTUP_PERMISSION: relaunch failed: %{public}@", error);
        self.reopening = NO;
        self.buttons.firstObject.enabled = YES;
        self.messageText = @"微信未能打开，请重试";
        [NSApp activate];
        [self.window makeKeyAndOrderFront:nil];
        return;
    }
    // Modal ordering must not keep this guide above another app's settings window.
    self.window.level = NSNormalWindowLevel;
    self.window.hidesOnDeactivate = NO;
    NSURL *url = [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"];
    if (![NSWorkspace.sharedWorkspace openURL:url]) {
        self.messageText = @"请手动打开系统设置";
    }
    // Keep this modal open while the user changes settings in the other app.
}
@end

static int SOVEXTDataAccessError(void) {
#if SOVEXT_PERMISSION_TESTING
    const char *path = getenv("SOVEXT_PERMISSION_TEST_PATH");
#else
    // ponytail: probes the observed startup failure on Build 269079, not all data/write access.
    // If a future build moves this file, keep unknown non-blocking and update from its trace.
    NSString *target = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/net/config.ini"];
    const char *path = target.fileSystemRepresentation;
#endif
    if (!path) return EINVAL;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return errno;
    struct stat info;
    int error = fstat(fd, &info) == 0 ? 0 : errno;
    if (!error && !S_ISREG(info.st_mode)) error = EINVAL;
    close(fd);
    return error;
}

void SOVEXTCheckStartupPermission(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            int error = SOVEXTDataAccessError();
            BOOL denied = error == EACCES || error == EPERM;
            os_log(OS_LOG_DEFAULT,
                "SOVEXT_STARTUP_PERMISSION: pid=%{public}d result=%{public}s errno=%{public}d",
                getpid(), !error ? "accessible" : denied ? "denied" : "unknown", error);
            // Leave AppKit initialization entirely to WeChat on the normal path.
            if (!denied) return;
            if (![NSThread isMainThread]) {
                os_log_error(OS_LOG_DEFAULT, "SOVEXT_STARTUP_PERMISSION: cannot show guidance off main thread");
                _exit(74);
            }

            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            SOVEXTStartupPermissionAlert *alert = [[SOVEXTStartupPermissionAlert alloc] init];
            alert.alertStyle = NSAlertStyleWarning;
            alert.messageText = @"微信缺少数据访问权限";
            alert.informativeText =
                @"1. 系统设置 → 隐私与安全 → 文件与文件夹，允许微信访问“微信”数据。\n\n"
                 "2. 返回此窗口，点击“打开微信”。";
            NSButton *settings = [alert addButtonWithTitle:@"打开系统设置"];
            settings.target = alert;
            settings.action = @selector(openSettings:);
            [alert addButtonWithTitle:@"退出微信"];
            NSTimer *timer = [NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
                (void)timer;
                [alert refreshPermission];
            }];
            [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
            [NSApp activate];
            [alert runModal];
            [timer invalidate];
            os_log(OS_LOG_DEFAULT, "SOVEXT_STARTUP_PERMISSION: guidance closed; exit before main");
            // Never continue host startup after creating an early AppKit application.
            _exit(0);
        }
    });
}

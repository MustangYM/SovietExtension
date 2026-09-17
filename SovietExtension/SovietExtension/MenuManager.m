//
//  MenuManager.m
//  SovietExtension
//
//  Created by MustangYM on 2026/6/13.
//

#import "MenuManager.h"
#import "NSMenuItem+Action.h"
#import "NSMenu+Action.h"
#import "RevokePatch.h"
#import "MistyModeSettingsWindowController.h"
#import "RevokeSettings.h"
#import <objc/runtime.h>

#ifndef kExitChatroomNickname
#define kExitChatroomNickname @"YMExitChatroomNickname"
#endif

static NSMenuItem *YMAssistantMenuItem;
static NSMenu *YMHostHelpMenu;
static NSMenu *YMHostWindowsMenu;

// 269079 在启动延迟回调中按末尾两项指定窗口/帮助；仅纠正助手插入造成的误指定。
static void YMProtectAssistantMenuRole(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSString *name in @[@"setHelpMenu:", @"setWindowsMenu:"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod(NSApplication.class, selector);
            void (*original)(id, SEL, NSMenu *) = (void (*)(id, SEL, NSMenu *))method_getImplementation(method);
            BOOL help = [name isEqualToString:@"setHelpMenu:"];
            IMP replacement = imp_implementationWithBlock(^(NSApplication *app, NSMenu *menu) {
                if (app == NSApp && YMAssistantMenuItem &&
                    app.mainMenu.itemArray.lastObject == YMAssistantMenuItem) {
                    if (help && menu == YMAssistantMenuItem.submenu) menu = YMHostHelpMenu;
                    else if (!help && YMHostWindowsMenu && menu == YMHostHelpMenu &&
                             app.mainMenu.numberOfItems >= 3 &&
                             [app.mainMenu itemAtIndex:app.mainMenu.numberOfItems - 2].submenu == menu) menu = YMHostWindowsMenu;
                }
                original(app, selector, menu);
            });
            method_setImplementation(method, replacement);
        }
    });
}

@interface MenuManager ()
@property (nonatomic, strong) NSMenuItem *ym_mistyModeMenuItem;
@property (nonatomic, strong) MistyModeSettingsWindowController *ym_mistySettingsWindowController;
@end

@implementation MenuManager

#pragma mark - Singleton
+ (instancetype)shareInstance
{
    static MenuManager *share = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        share = [[self alloc] init];
    });
    return share;
}

#pragma mark - Public

- (void)initAssistantMenuItems
{
    YMRegisterSelfRevokeDefault([NSUserDefaults standardUserDefaults]);
    [self ym_registerDefaultBool:NO forKey:kExitChatroomNick];
    [MistyModeSettingsWindowController registerDefaults];

    NSMenuItem *antiUpdateMenu = [self ym_toggleMenuItemWithTitle:@"阻止更新"
                                                              key:kAntiUpdate
                                                           action:@selector(onAntiUpdate:)];
    
    BOOL separateRevoke = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] isEqualToString:@"269079"];
    NSMenu *revokeGroupSub = [[NSMenu alloc] initWithTitle:@"消息撤回"];
    [revokeGroupSub addItem:[self ym_toggleMenuItemWithTitle:@"消息防撤回"
        key:separateRevoke ? kRevokeEnabled : kAntiRevoke action:@selector(onRevokeEnabled:)]];
    if (separateRevoke) {
        NSMenuItem *others = [self ym_toggleMenuItemWithTitle:@"他人" key:kAntiRevoke action:@selector(onAntiRevoke:)];
        NSMenuItem *own = [self ym_toggleMenuItemWithTitle:@"本人" key:kSelfAntiRevoke action:@selector(onSelfAntiRevoke:)];
        others.indentationLevel = own.indentationLevel = 1;
        [revokeGroupSub addItems:@[others, own]];
    }
    [revokeGroupSub addItem:NSMenuItem.separatorItem];
    NSMenuItem *forward = [self ym_toggleMenuItemWithTitle:@"同步到手机"
        key:kRevokeForwardToSelfRealSend action:@selector(onRevokeForwardToSelfRealSend:)];
    forward.toolTip = @"两组开关独立；需要开启防撤回及对应的本人或他人防撤回才会同步。";
    [revokeGroupSub addItem:forward];
    if (separateRevoke) {
        NSMenuItem *others = [self ym_toggleMenuItemWithTitle:@"他人" key:kRevokeForwardOthers action:@selector(onRevokeForwardOthers:)];
        NSMenuItem *own = [self ym_toggleMenuItemWithTitle:@"本人" key:kRevokeForwardSelf action:@selector(onRevokeForwardSelf:)];
        others.indentationLevel = own.indentationLevel = 1;
        [revokeGroupSub addItems:@[others, own]];
    }

    NSMenuItem *revokeGroup = [[NSMenuItem alloc] init];
    revokeGroup.title = @"消息撤回";
    revokeGroup.target = self;
    revokeGroup.enabled = YES;
    revokeGroup.submenu = revokeGroupSub;

    NSMenuItem *exitChatroomMenu = [self ym_toggleMenuItemWithTitle:@"退群监控"
                                                                key:kExitChatroom
                                                             action:@selector(onExitChatroom:)];
    
    NSMenuItem *exitChatroomNicknameMenu = [self ym_toggleMenuItemWithTitle:@"显示退群昵称(若闪退建议关闭)"
                                                                        key:kExitChatroomNick
                                                                     action:@selector(onExitChatroomNickname:)];
    
    exitChatroomNicknameMenu.toolTip = @"仅在退群监控开启时生效。";

    NSMenu *groupSubMenu = [[NSMenu alloc] initWithTitle:@"群相关"];
    [groupSubMenu addItems:@[
        exitChatroomMenu,
        exitChatroomNicknameMenu,
    ]];
    
    NSMenuItem *groupMenu = [[NSMenuItem alloc] init];
    groupMenu.title = @"群相关";
    groupMenu.target = self;
    groupMenu.enabled = YES;
    groupMenu.submenu = groupSubMenu;
    
    NSMenuItem *useSystemWebMenu = [self ym_toggleMenuItemWithTitle:@"使用系统浏览器(实验)"
                                                                key:kUseSystemWeb
                                                             action:@selector(onUseSystemWeb:)];
    
    NSMenuItem *autoLoginMenu = [self ym_toggleMenuItemWithTitle:@"自动登录（下次启动生效）"
                                                             key:kAutoLogin
                                                          action:@selector(onAutoLogin:)];
    
    NSMenuItem *newWeChatMenu = [NSMenuItem menuItemWithTitle:@"多开"
                                                       action:@selector(onNewWeChat:)
                                                       target:self
                                                keyEquivalent:@""
                                                        state:NO];
    
    NSMenuItem *themeMenu = [self ym_createThemeModeMenu];
   
    NSString *version = [NSString stringWithFormat:@"当前版本 %@", kCurrentVersion];
    NSMenuItem *currentVersionMenu = [NSMenuItem menuItemWithTitle:version
                                                            action:nil
                                                            target:self
                                                     keyEquivalent:@""
                                                             state:NO];
    currentVersionMenu.enabled = NO;
    
    NSMenu *subMenu = [[NSMenu alloc] initWithTitle:@"苏维埃助手"];
    [subMenu addItems:@[
        antiUpdateMenu,
        themeMenu,
        revokeGroup,
        groupMenu,
        autoLoginMenu,
        useSystemWebMenu,
        newWeChatMenu,
        currentVersionMenu
    ]];
    
    NSMenuItem *menuItem = [[NSMenuItem alloc] init];
    menuItem.title = @"苏维埃助手";
    menuItem.target = self;
    menuItem.enabled = YES;
    menuItem.submenu = subMenu;
    
    NSApplication *application = NSApplication.sharedApplication;
    NSMenu *mainMenu = application.mainMenu;
    if (!mainMenu) return;
    if (YMAssistantMenuItem.menu == mainMenu) [mainMenu removeItem:YMAssistantMenuItem];
    YMHostHelpMenu = mainMenu.itemArray.lastObject.submenu ?: [[NSMenu alloc] initWithTitle:@""];
    YMHostWindowsMenu = mainMenu.numberOfItems >= 2 ? [mainMenu itemAtIndex:mainMenu.numberOfItems - 2].submenu : nil;
    YMAssistantMenuItem = menuItem;
    YMProtectAssistantMenuRole();
    if (!application.helpMenu) {
        // helpMenu 为空时 AppKit 会自选菜单插入搜索；离屏菜单可关闭此行为。
        application.helpMenu = [[NSMenu alloc] initWithTitle:@""];
    }
    [mainMenu addItem:menuItem];
}

#pragma mark - Menu Actions

- (void)onAntiUpdate:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kAntiUpdate
                   informativeText:@"非必要情况千万不要关闭`禁止更新`,否则微信自动更新导致插件失效"];
}

- (void)onRevokeEnabled:(NSMenuItem *)item
{
    if (![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] isEqualToString:@"269079"]) {
        [self onAntiRevoke:item];
        return;
    }
    [self ym_confirmToggleMenuItem:item userDefaultsKey:kRevokeEnabled informativeText:nil];
}

- (void)onRevokeForwardOthers:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item userDefaultsKey:kRevokeForwardOthers informativeText:nil];
}

- (void)onRevokeForwardSelf:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item userDefaultsKey:kRevokeForwardSelf informativeText:nil];
}

- (void)onAntiRevoke:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item userDefaultsKey:kAntiRevoke informativeText:nil];
}

- (void)onSelfAntiRevoke:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item userDefaultsKey:kSelfAntiRevoke informativeText:nil];
}

- (void)onExitChatroom:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kExitChatroom
                   informativeText:nil];
}

- (void)onExitChatroomNickname:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kExitChatroomNick
                   informativeText:nil];
}

- (void)onAutoLogin:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kAutoLogin
                   informativeText:nil];
}

- (void)onRevokeForwardToSelfRealSend:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kRevokeForwardToSelfRealSend
                   informativeText:nil];
}

- (void)onUseSystemWeb:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kUseSystemWeb
                   informativeText:nil];
}

- (void)onNewWeChat:(NSMenuItem *)item
{
    [self executeShellCommand:@"open -n /Applications/WeChat.app"];
}

- (void)onMistyMode:(NSMenuItem *)item
{
    self.ym_mistyModeMenuItem = item;
    [self ym_showMistyModeSettingsWindow:item];
}

#pragma mark - 主题模式 Menu

- (NSMenuItem *)ym_createThemeModeMenu
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL mistyEnabled = [defaults boolForKey:kThemeMistyMode];
    
    NSMenuItem *mistyModeMenu = [NSMenuItem menuItemWithTitle:@"迷离模式  ▶"
                                                       action:@selector(onMistyMode:)
                                                       target:self
                                                keyEquivalent:@""
                                                        state:mistyEnabled];
    self.ym_mistyModeMenuItem = mistyModeMenu;
    
    NSMenu *themeSubMenu = [[NSMenu alloc] initWithTitle:@"主题模式"];
    [themeSubMenu addItem:mistyModeMenu];
    
    NSMenuItem *themeMenu = [[NSMenuItem alloc] init];
    themeMenu.title = @"主题模式";
    themeMenu.target = self;
    themeMenu.enabled = YES;
    themeMenu.submenu = themeSubMenu;
    
    return themeMenu;
}

- (void)ym_showMistyModeSettingsWindow:(NSMenuItem *)item
{
    if (!self.ym_mistySettingsWindowController) {
        self.ym_mistySettingsWindowController = [[MistyModeSettingsWindowController alloc] init];
        __weak typeof(self) weakSelf = self;
        self.ym_mistySettingsWindowController.confirmHandler = ^(BOOL isOpen) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            strongSelf.ym_mistyModeMenuItem.state = isOpen ? NSControlStateValueOn : NSControlStateValueOff;
        };
    }

    [self.ym_mistySettingsWindowController showWindowCentered];
}

#pragma mark - Menu Helpers

- (void)ym_registerDefaultBool:(BOOL)value forKey:(NSString *)key
{
    if (key.length == 0) {
        return;
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) {
        [defaults setBool:value forKey:key];
        [defaults synchronize];
    }
}

- (NSMenuItem *)ym_toggleMenuItemWithTitle:(NSString *)title
                                       key:(NSString *)key
                                    action:(SEL)action
{
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:key];
    
    NSMenuItem *item = [NSMenuItem menuItemWithTitle:title
                                  action:action
                                  target:self
                           keyEquivalent:@""
                                   state:enabled];
    item.representedObject = key;
    return item;
}

- (void)ym_confirmToggleMenuItem:(NSMenuItem *)item
                 userDefaultsKey:(NSString *)key
                 informativeText:(NSString *)informativeText
{
    BOOL enabled = ![[NSUserDefaults standardUserDefaults] boolForKey:key];
    YMFeatureApplyResult result = YMApplyFeatureSetting(key, enabled);
    if (result == YMFeatureUnavailable) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"设置未更改";
        alert.informativeText = @"当前版本或运行状态无法安全应用此配置，请稍后重试或查看插件日志。";
        [alert addButtonWithTitle:@"确定"];
        [alert runModal];
        return;
    }
    if (result == YMFeatureNeedsRestart) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"此设置需要重启微信";
        NSString *message = @"立即重启后生效；取消则保持原设置。";
        if (informativeText.length > 0) {
            message = [informativeText stringByAppendingFormat:@"\n%@\n关闭拦截不会自动开启微信的自动更新。", message];
        }
        alert.informativeText = message;
        [alert addButtonWithTitle:@"取消"];
        [alert addButtonWithTitle:@"立即重启"];
        if ([alert runModal] != NSAlertSecondButtonReturn) return;
    }
    [self ym_setMenuItem:item enabled:enabled userDefaultsKey:key];
    if (result == YMFeatureNeedsRestart) [self ym_restartWeChatAfterDelay:0.1];
}

- (void)ym_setMenuItem:(NSMenuItem *)item
               enabled:(BOOL)enabled
       userDefaultsKey:(NSString *)key
{
    item.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:key];
    if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] isEqualToString:@"269079"]) {
        for (NSArray<NSString *> *group in @[@[kRevokeEnabled, kAntiRevoke, kSelfAntiRevoke],
                                            @[kRevokeForwardToSelfRealSend, kRevokeForwardOthers, kRevokeForwardSelf]]) {
            if (![group containsObject:key]) continue;
            if ([key isEqualToString:group[0]]) {
                [defaults setBool:enabled forKey:group[1]];
                [defaults setBool:enabled forKey:group[2]];
            } else {
                [defaults setBool:([defaults boolForKey:group[1]] || [defaults boolForKey:group[2]]) forKey:group[0]];
            }
            for (NSMenuItem *sibling in item.menu.itemArray) {
                if (![group containsObject:sibling.representedObject]) continue;
                BOOL selected = [defaults boolForKey:sibling.representedObject];
                sibling.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
            }
            break;
        }
    }
    [defaults synchronize];
}

#pragma mark - WeChat

- (void)ym_restartWeChatAfterDelay:(NSTimeInterval)delay
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self restartWeChat];
    });
}

- (void)restartWeChat
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *cmd = @"killall WeChat; sleep 0.5; open /Applications/WeChat.app";
        [self executeShellCommand:cmd];
    });
}

#pragma mark - Shell

- (NSString *)executeShellCommand:(NSString *)cmd
{
    if (cmd.length == 0) {
        return @"";
    }
    
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/bash";
    task.arguments = @[@"-c", cmd];
    
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    
    NSFileHandle *fileHandle = [pipe fileHandleForReading];
    
    @try {
        [task launch];
    } @catch (NSException *exception) {
        return exception.reason ?: @"";
    }
    
    NSData *data = [fileHandle readDataToEndOfFile];
    [task waitUntilExit];
    
    NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return result ?: @"";
}

@end

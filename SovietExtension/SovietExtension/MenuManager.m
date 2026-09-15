//
//  MenuManager.m
//  SovietExtension
//
//  Created by MustangYM on 2026/6/13.
//

#import "MenuManager.h"
#import "NSMenuItem+Action.h"
#import "NSMenu+Action.h"
#import "YMSwizzledHelper.h"
#import "MistyModeSettingsWindowController.h"
#import "RevokeSettings.h"

#ifndef kExitChatroomNickname
#define kExitChatroomNickname @"YMExitChatroomNickname"
#endif

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
    NSMenuItem *antiRevokeMenu = [self ym_toggleMenuItemWithTitle:separateRevoke ? @"他人消息防撤回" : @"消息防撤回"
                                                              key:kAntiRevoke
                                                           action:@selector(onAntiRevoke:)];
    NSMenuItem *selfAntiRevokeMenu = [self ym_toggleMenuItemWithTitle:@"本人消息防撤回"
                                                              key:kSelfAntiRevoke
                                                           action:@selector(onSelfAntiRevoke:)];
    
    BOOL flag_forward = [[NSUserDefaults standardUserDefaults] boolForKey:kRevokeForwardToSelfRealSend];
    NSMenuItem *forwardMenu = [NSMenuItem menuItemWithTitle:@"撤回同步到手机(文字提醒)"
                                                     action:@selector(onRevokeForwardToSelfRealSend:)
                                                     target:self
                                              keyEquivalent:@""
                                                      state:flag_forward];
    
    NSMenu *revokeGroupSub = [[NSMenu alloc] initWithTitle:@"消息撤回"];
    [revokeGroupSub addItem:antiRevokeMenu];
    if (separateRevoke) [revokeGroupSub addItem:selfAntiRevokeMenu];
    [revokeGroupSub addItem:forwardMenu];
    
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
    
    NSMenuItem *autoLoginMenu = [self ym_toggleMenuItemWithTitle:@"自动登录"
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
    
    [[[NSApplication sharedApplication] mainMenu] addItem:menuItem];
}

#pragma mark - Menu Actions

- (void)onAntiUpdate:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kAntiUpdate
                   informativeText:@"非必要情况千万不要关闭`禁止更新`,否则微信自动更新导致插件失效" needSave:YES];
}

- (void)onAntiRevoke:(NSMenuItem *)item
{
    if (![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] isEqualToString:@"269079"]) {
        [self ym_confirmToggleMenuItem:item userDefaultsKey:kAntiRevoke
                       informativeText:@"重启微信生效" needSave:YES];
        return;
    }
    [self ym_setMenuItem:item enabled:item.state != NSControlStateValueOn userDefaultsKey:kAntiRevoke];
}

- (void)onSelfAntiRevoke:(NSMenuItem *)item
{
    [self ym_setMenuItem:item enabled:item.state != NSControlStateValueOn userDefaultsKey:kSelfAntiRevoke];
}

- (void)onExitChatroom:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kExitChatroom
                   informativeText:@"重启微信生效\n\n关闭后将完全关闭退群监控；退群昵称开关也不会生效。" needSave:YES];
}

- (void)onExitChatroomNickname:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kExitChatroomNick
                   informativeText:@"重启微信生效\n\n关闭后仍保留退群监控，但退群人可能只显示 wxid / memberID。\n部分用户偶发微信闪退，建议先关闭这个开关。" needSave:YES];
}

- (void)onAutoLogin:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kAutoLogin
                   informativeText:@"重启微信生效" needSave:YES];
}

- (void)onRevokeForwardToSelfRealSend:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kRevokeForwardToSelfRealSend
                   informativeText:@"开启后，撤回的消息将转发到自己的会话，全设备同步。\n无法获取群名时显示群 ID。\n重启微信生效。" needSave:YES];
}

- (void)onUseSystemWeb:(NSMenuItem *)item
{
    [self ym_confirmToggleMenuItem:item
                   userDefaultsKey:kUseSystemWeb
                   informativeText:@"重启微信生效" needSave:YES];
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
            strongSelf.ym_mistyModeMenuItem.state = NSControlStateValueOn;
            if (!strongSelf.hasLoadMistyHook || (strongSelf.hasLoadMistyHook && !isOpen)) {
                [strongSelf ym_confirmToggleMenuItem:nil
                               userDefaultsKey:nil
                                     informativeText:@"重启立即生效" needSave:NO];
            }
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
    
    return [NSMenuItem menuItemWithTitle:title
                                  action:action
                                  target:self
                           keyEquivalent:@""
                                   state:enabled];
}

- (void)ym_confirmToggleMenuItem:(NSMenuItem *)item
                 userDefaultsKey:(NSString *)key
                 informativeText:(NSString *)informativeText
                        needSave:(BOOL)needSave
{
    BOOL enabled = item.state != NSControlStateValueOn;
    
    NSAlert *alert = [NSAlert alertWithMessageText:@"警告"
                                     defaultButton:@"取消"
                                   alternateButton:@"确定重启"
                                       otherButton:nil
                         informativeTextWithFormat:@"%@", informativeText];
    
    NSUInteger action = [alert runModal];
    if (action != NSAlertAlternateReturn) {
        return;
    }
    
    if (needSave) {
        [self ym_setMenuItem:item enabled:enabled userDefaultsKey:key];
    }
    [self ym_restartWeChatAfterDelay:0.5];
}

- (void)ym_setMenuItem:(NSMenuItem *)item
               enabled:(BOOL)enabled
       userDefaultsKey:(NSString *)key
{
    item.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:key];
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

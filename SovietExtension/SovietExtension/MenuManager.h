//
//  MenuManager.m
//  SovietExtension
//
//  Created by MustangYM on 2026/6/13.
//


#import <Foundation/Foundation.h>
#import "MistyModeSettingsWindowController.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *kAntiUpdate = @"kAntiUpdate.SOVIET";
static NSString *kAntiRevoke = @"kAntiRevoke.SOVIET";
static NSString *kRevokeEnabled = @"kRevokeEnabled.SOVIET";
static NSString *kRevokeForwardOthers = @"kRevokeForwardOthers.SOVIET";
static NSString *kRevokeForwardSelf = @"kRevokeForwardSelf.SOVIET";
static NSString *kSelfAntiRevoke = @"kSelfAntiRevoke.SOVIET";
static NSString *kExitChatroom = @"kExitChatroom.SOVIET";
static NSString *kRevokeForwardToSelfRealSend = @"kRevokeForwardToSelfRealSend.SOVIET";
static NSString *kExitChatroomNick = @"kExitChatroomNick.SOVIET";
static NSString *kUseSystemWeb = @"kUseSystemWeb.SOVIET";
static NSString *kIsFirstLoad = @"kIsFirstLoad.SOVIET";
static NSString *kAutoLogin = @"kAutoLogin.SOVIET";
static NSString *kCurrentVersion = @"1.3.1";

@interface MenuManager : NSObject
@property (nonatomic, assign) BOOL hasLoadMistyHook;
+ (void)hook;
+ (instancetype)shareInstance;
- (void)initAssistantMenuItems;
- (void)ym_restartWeChatAfterDelay:(NSTimeInterval)delay;
@end

NS_ASSUME_NONNULL_END

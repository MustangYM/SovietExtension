//
//  RevokePatch.h
//  SovietExtension
//
//  Created by MustangYM on 2026/6/12.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
void YMLog(NSString *format, ...);
// 当前 /Applications/WeChat.app/Contents/Resources/wechat.dylib 的 ASLR slide。
// dyld 加载 wechat.dylib 后会赋值。
uintptr_t YMRuntimeAddress(uintptr_t staticVA);
uintptr_t getDylibSlide();

BOOL YMPatchARM64AbsoluteJump(uintptr_t address, uintptr_t targetAddress, const char *name);
// dyld 目标镜像加载后尝试安装；已安装或版本/ABI 不匹配时直接返回，不发送消息。
void YMInstallMessageMenuPatch(void);
// 只查询本账号已确认撤回的原消息；不受当前保留开关影响。
BOOL YMIsRetainedSelfMessage(uintptr_t messageData);

typedef NS_ENUM(NSInteger, YMFeatureApplyResult) {
    YMFeatureApplied,
    YMFeatureNeedsRestart,
    YMFeatureUnavailable,
};
// 主线程调用；成功后由菜单保存。失败不更改功能开关。
FOUNDATION_EXPORT YMFeatureApplyResult YMApplyFeatureSetting(NSString *key, BOOL enabled);

// 备注 → 当前群昵称 → 微信昵称；缓存缺失保留消息原名，最后回退成员 ID。
// capturedGroupName 仅用于退群前同群快照，调用方负责账号/群隔离。
NSString *YMResolveMemberDisplayName(NSString * _Nullable memberID, NSString * _Nullable roomID,
                                     NSString * _Nullable sourceName, NSString * _Nullable capturedGroupName);

NS_ASSUME_NONNULL_END

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const kYMRoundedAvatarRadiusPercent;

/// 0 为方形，50 为圆形。设置只影响头像绘制，不处理普通图片、表情或二维码。
FOUNDATION_EXPORT void YMRoundedAvatarRegisterDefaults(void);
FOUNDATION_EXPORT CGFloat YMRoundedAvatarRadiusPercent(void);
FOUNDATION_EXPORT NSImage *YMRoundedAvatarPreviewImage(void);
FOUNDATION_EXPORT void YMRoundedAvatarRefresh(void);
/// 合并同一批视图变化产生的刷新请求，设置保存仍可直接刷新。
FOUNDATION_EXPORT void YMScheduleRoundedAvatarRefresh(void);

@interface RoundedAvatarSettingsWindowController : NSWindowController
- (void)showWindowCentered;
@end

NS_ASSUME_NONNULL_END

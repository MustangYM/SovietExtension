#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YMGroupRoleBadgeEnabledKey;
FOUNDATION_EXPORT NSString * const YMGroupRoleBadgePositionKey;
FOUNDATION_EXPORT NSString * const YMGroupRoleBadgeFontSizeKey;
FOUNDATION_EXPORT NSString * const YMGroupRoleBadgeGapKey;
FOUNDATION_EXPORT NSString * const YMGroupRoleBadgeOwnerColorKey;
FOUNDATION_EXPORT NSString * const YMGroupRoleBadgeAdminColorKey;
FOUNDATION_EXPORT NSString * const YMGroupRoleBadgeOwnerTextKey;
FOUNDATION_EXPORT NSString * const YMGroupRoleBadgeAdminTextKey;

FOUNDATION_EXPORT void YMGroupRoleBadgeRegisterDefaults(void);
FOUNDATION_EXPORT BOOL YMGroupRoleBadgeEnabled(void);
FOUNDATION_EXPORT NSInteger YMGroupRoleBadgePosition(void);
FOUNDATION_EXPORT CGFloat YMGroupRoleBadgeFontSize(void);
FOUNDATION_EXPORT CGFloat YMGroupRoleBadgeGap(void);
FOUNDATION_EXPORT uint32_t YMGroupRoleBadgeColorRGB(NSString *identity);
FOUNDATION_EXPORT NSArray<NSString *> *YMGroupRoleBadgeLines(NSString *caption); // 至多一行，最长 48
FOUNDATION_EXPORT NSString *YMGroupRoleBadgeStoredText(NSString *raw, NSString *fallback);
FOUNDATION_EXPORT NSString *YMGroupRoleBadgeCaption(NSString *identity);
FOUNDATION_EXPORT NSString *_Nullable YMGroupRoleBadgeIdentity(NSString *group, NSString *sender);

FOUNDATION_EXPORT const CGFloat YMGroupRoleBadgeChatAvatarSize;
FOUNDATION_EXPORT const CGFloat YMGroupRoleBadgeCaptionPad;
FOUNDATION_EXPORT const CGFloat YMGroupRoleBadgeFontMin;
FOUNDATION_EXPORT const CGFloat YMGroupRoleBadgeFontMax;
FOUNDATION_EXPORT const CGFloat YMGroupRoleBadgeGapMin;
FOUNDATION_EXPORT const CGFloat YMGroupRoleBadgeGapMax;
FOUNDATION_EXPORT CGFloat YMGroupRoleBadgeLineHeight(CGFloat fontSize);
FOUNDATION_EXPORT CGFloat YMGroupRoleBadgeCaptionTopQt(CGFloat avatarY, CGFloat avatarHeight, CGFloat captionHeight, CGFloat gap, BOOL above);
FOUNDATION_EXPORT NSRect YMGroupRoleBadgePreviewCaptionFrame(NSRect avatar, CGFloat fontSize, CGFloat gap, BOOL above);

NS_ASSUME_NONNULL_END

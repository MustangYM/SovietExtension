#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YMSessionMarkEnabledKey;
FOUNDATION_EXPORT NSString * const YMSessionMarkScopeKey;
FOUNDATION_EXPORT NSString * const YMSessionMarkChangedNotification;
FOUNDATION_EXPORT NSString * const YMSessionMarkExceptAddedName;

FOUNDATION_EXPORT const NSInteger YMSessionMarkScopeAdded;
FOUNDATION_EXPORT const NSInteger YMSessionMarkScopeExceptAdded;
FOUNDATION_EXPORT const CGFloat YMSessionMarkPlaceholderSizeMin;
FOUNDATION_EXPORT const CGFloat YMSessionMarkPlaceholderSizeMax;
FOUNDATION_EXPORT const CGFloat YMSessionMarkPlaceholderSizeDefault;
FOUNDATION_EXPORT const CGFloat YMSessionMarkAlphaMin;
FOUNDATION_EXPORT const CGFloat YMSessionMarkAlphaMax;
FOUNDATION_EXPORT const CGFloat YMSessionMarkAlphaDefault;
FOUNDATION_EXPORT const CGFloat YMSessionMarkWashMin;
FOUNDATION_EXPORT const CGFloat YMSessionMarkWashMax;
FOUNDATION_EXPORT const CGFloat YMSessionMarkWashDefault;
FOUNDATION_EXPORT const NSUInteger YMSessionMarkNameMaxLength;
FOUNDATION_EXPORT const NSUInteger YMSessionMarkSetLimit;
FOUNDATION_EXPORT const NSUInteger YMSessionMarkSessionLimit;
FOUNDATION_EXPORT const uint32_t YMSessionMarkDefaultColorRGB;
FOUNDATION_EXPORT const uint32_t YMSessionMarkDefaultPlaceholderRGB;
FOUNDATION_EXPORT const CGFloat YMSessionMarkComposerFieldMinWidth;
FOUNDATION_EXPORT const CGFloat YMSessionMarkComposerFieldMinHeight;
FOUNDATION_EXPORT const CGFloat YMSessionMarkComposerFieldMaxHeight;
FOUNDATION_EXPORT const CGFloat YMSessionMarkComposerSurfaceMaxHeight;
FOUNDATION_EXPORT const CGFloat YMSessionMarkComposerOverlayMaxHeight;
FOUNDATION_EXPORT const CGFloat YMSessionMarkComposerToolbarMaxHeight;
FOUNDATION_EXPORT const CGFloat YMSessionMarkSessionInfoPanelMinWidth;
FOUNDATION_EXPORT const CGFloat YMSessionMarkSessionInfoPanelMaxWidth;
FOUNDATION_EXPORT const CGFloat YMSessionMarkSessionInfoPanelMinHeight;
FOUNDATION_EXPORT const CGFloat YMSessionMarkSessionListCellMinWidth;
FOUNDATION_EXPORT const CGFloat YMSessionMarkSessionListCellMaxWidth;
FOUNDATION_EXPORT const CGFloat YMSessionMarkSessionListCellMinHeight;
FOUNDATION_EXPORT const CGFloat YMSessionMarkSessionListCellMaxHeight;

FOUNDATION_EXPORT void YMSessionMarkRegisterDefaults(void);
FOUNDATION_EXPORT BOOL YMSessionMarkEnabled(void);
FOUNDATION_EXPORT NSInteger YMSessionMarkScope(void);
FOUNDATION_EXPORT void YMSessionMarkSetScope(NSInteger scope);
FOUNDATION_EXPORT NSString *YMSessionMarkSetsKey(NSString *_Nullable account);
FOUNDATION_EXPORT NSArray<NSDictionary *> *YMSessionMarkSets(NSString *_Nullable account);
FOUNDATION_EXPORT void YMSessionMarkSaveSets(NSString *_Nullable account, NSArray *sets);
FOUNDATION_EXPORT NSDictionary *_Nullable YMSessionMarkLookup(NSString *_Nullable account, NSString *_Nullable session);
FOUNDATION_EXPORT NSString *YMSessionMarkPlaceholderText(NSDictionary *mark);
FOUNDATION_EXPORT NSAttributedString *YMSessionMarkQuotedString(NSString *_Nullable text, CGFloat size, NSColor *color, NSTextAlignment align);
FOUNDATION_EXPORT uint32_t YMSessionMarkParseColor(NSString *_Nullable hex, uint32_t fallback);
FOUNDATION_EXPORT NSString *YMSessionMarkHexFromRGB(uint32_t rgb);
FOUNDATION_EXPORT CGFloat YMSessionMarkClampPlaceholderSize(CGFloat value);
FOUNDATION_EXPORT CGFloat YMSessionMarkClampAlpha(CGFloat value);
FOUNDATION_EXPORT CGFloat YMSessionMarkClampWash(CGFloat value);
FOUNDATION_EXPORT uint32_t YMSessionMarkFluorescentRGB(uint32_t rgb);
FOUNDATION_EXPORT NSInteger YMSessionMarkClampScope(NSInteger value);
FOUNDATION_EXPORT NSString *YMSessionMarkStoredName(NSString *_Nullable raw, NSString *fallback);
FOUNDATION_EXPORT NSArray<NSDictionary *> *YMSessionMarkNormalizedSets(NSArray *_Nullable sets);
FOUNDATION_EXPORT NSMutableDictionary *YMSessionMarkDefaultSet(NSString *_Nullable name);
FOUNDATION_EXPORT NSString *YMSessionMarkSessionTitle(NSDictionary *mark, NSString *session);
FOUNDATION_EXPORT NSString *_Nullable YMSessionMarkCanonicalSession(NSString *_Nullable session);
FOUNDATION_EXPORT BOOL YMSessionMarkIsSessionId(NSString *_Nullable session);
FOUNDATION_EXPORT BOOL YMSessionMarkAcceptsSession(NSString *_Nullable session, NSString *_Nullable account);
FOUNDATION_EXPORT BOOL YMSessionMarkSessionIsFolderHolder(NSString *_Nullable session);

typedef NS_ENUM(NSInteger, YMSessionMarkComposerCellAction) {
    YMSessionMarkComposerCellIgnore = 0,
    YMSessionMarkComposerCellBind = 1,
    YMSessionMarkComposerCellDrop = 2,
};

FOUNDATION_EXPORT YMSessionMarkComposerCellAction YMSessionMarkComposerActionForSelectedCell(
    NSString *_Nullable accepted, NSDictionary *_Nullable mark, NSString *_Nullable identity,
    NSString *_Nullable account, NSString *_Nullable openSession);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerShouldDropPending(
    NSString *_Nullable openSession, BOOL openMarked, NSString *_Nullable pendingDrop,
    BOOL selectedMarkedThisTurn);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerFieldSized(CGFloat width, CGFloat height);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerSurfaceSized(CGFloat width, CGFloat height);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerOverlaySized(CGFloat width, CGFloat height);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerCardSized(CGFloat cardWidth, CGFloat cardHeight,
    CGFloat fieldWidth, CGFloat fieldHeight);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerChromeWrapsField(NSRect chrome, NSRect field);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerOuterWrapsInner(NSRect outer, NSRect inner);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerChildIsTypingField(NSRect parent, NSRect child);
// childTop：子控件顶边到父顶边的距离（y=0 在上）。贴父底的输入卡不是消息列表。
FOUNDATION_EXPORT BOOL YMSessionMarkComposerMessageListChildSized(CGFloat parentWidth, CGFloat parentHeight,
    CGFloat childWidth, CGFloat childHeight, CGFloat childTop);
// 贴在聊天页列表区里的灰线尺寸控件（消息行，或挤矮后矮过灰线上限的消息区）不是输入栏；贴父底工具栏带里的才是。
FOUNDATION_EXPORT BOOL YMSessionMarkComposerFieldInMessageList(CGFloat parentWidth, CGFloat parentHeight,
    CGFloat childWidth, CGFloat childHeight, CGFloat childTop);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerCardWrapsTypingField(NSRect card, NSRect field);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerStripTypingSized(CGFloat width, CGFloat height);
// 带会话号的输入栏按 OverlaySized（24–1200）；没有会话号的仍排除约 160 的外卡。
FOUNDATION_EXPORT BOOL YMSessionMarkComposerTypingHitSized(BOOL hasSession, CGFloat width, CGFloat height);
FOUNDATION_EXPORT NSRect YMSessionMarkComposerTypingSurface(NSRect field, NSRect chrome, BOOL flipped);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerStripBand(NSRect windowLocal, CGFloat windowHeight);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerBottomAnchored(NSRect windowLocal, CGFloat windowHeight);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerNearWindowBottom(NSRect viewScreen, NSRect windowScreen);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerNearWindowBottomAnchored(NSRect viewScreen, NSRect windowScreen);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerNearWindowTop(NSRect viewScreen, NSRect windowScreen);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerInChatColumn(NSRect viewScreen, NSRect listColumnScreen);
FOUNDATION_EXPORT BOOL YMSessionMarkComposerStripPreferWider(NSRect current, NSRect challenger);
FOUNDATION_EXPORT BOOL YMSessionMarkSessionInfoPanelSized(CGFloat width, CGFloat height);
FOUNDATION_EXPORT NSRect YMSessionMarkClipComposerFrameAwayFromPanel(NSRect field, NSRect panel);
FOUNDATION_EXPORT BOOL YMSessionMarkSessionListCellSized(CGFloat width, CGFloat height);
FOUNDATION_EXPORT BOOL YMSessionMarkWindowTitleIsMain(NSString *_Nullable title);
FOUNDATION_EXPORT BOOL YMSessionMarkWindowTitleIsUtility(NSString *_Nullable title);
FOUNDATION_EXPORT BOOL YMSessionMarkWindowFrameInside(NSRect inner, NSRect outer);
FOUNDATION_EXPORT BOOL YMSessionMarkWindowFrameOverlapsMain(NSRect inner, NSRect outer);
FOUNDATION_EXPORT BOOL YMSessionMarkWindowSizeMatchesMain(CGFloat innerWidth, CGFloat innerHeight,
    CGFloat outerWidth, CGFloat outerHeight);
FOUNDATION_EXPORT BOOL YMSessionMarkWindowHostsSessionChrome(
    NSString *_Nullable title, BOOL insideMainChat, BOOL insideUtilityWindow);

NS_ASSUME_NONNULL_END

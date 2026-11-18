#import "AppearanceNative.h"
#import "SessionMark.h"
#import <math.h>

NSString * const YMSessionMarkEnabledKey = @"YMSessionMarkEnabled.SOVIET";
NSString * const YMSessionMarkScopeKey = @"YMSessionMarkScope.SOVIET";
NSString * const YMSessionMarkChangedNotification = @"YMSessionMarkChanged.SOVIET";
NSString * const YMSessionMarkExceptAddedName = @"未标记";

const NSInteger YMSessionMarkScopeAdded = 0;
const NSInteger YMSessionMarkScopeExceptAdded = 1;
const CGFloat YMSessionMarkPlaceholderSizeMin = 11;
const CGFloat YMSessionMarkPlaceholderSizeMax = 22;
const CGFloat YMSessionMarkPlaceholderSizeDefault = 14;
const CGFloat YMSessionMarkAlphaMin = 0.30;
const CGFloat YMSessionMarkAlphaMax = 1.00;
const CGFloat YMSessionMarkAlphaDefault = 0.80;
const CGFloat YMSessionMarkWashMin = 0.08;
const CGFloat YMSessionMarkWashMax = 0.40;
const CGFloat YMSessionMarkWashDefault = 0.14;
const NSUInteger YMSessionMarkNameMaxLength = 16;
const NSUInteger YMSessionMarkSetLimit = 12;
const NSUInteger YMSessionMarkSessionLimit = 64;
const uint32_t YMSessionMarkDefaultColorRGB = 0xE24B2C;
const uint32_t YMSessionMarkDefaultPlaceholderRGB = 0xE88A78;
const CGFloat YMSessionMarkComposerFieldMinWidth = 80;
const CGFloat YMSessionMarkComposerFieldMinHeight = 24;
const CGFloat YMSessionMarkComposerFieldMaxHeight = 140;
const CGFloat YMSessionMarkComposerSurfaceMaxHeight = 560;
const CGFloat YMSessionMarkComposerOverlayMaxHeight = 1200;
const CGFloat YMSessionMarkComposerToolbarMaxHeight = 72;
const CGFloat YMSessionMarkSessionInfoPanelMinWidth = 160;
const CGFloat YMSessionMarkSessionInfoPanelMaxWidth = 400;
const CGFloat YMSessionMarkSessionInfoPanelMinHeight = 200;
const CGFloat YMSessionMarkSessionListCellMinWidth = 160;
const CGFloat YMSessionMarkSessionListCellMaxWidth = 400;
const CGFloat YMSessionMarkSessionListCellMinHeight = 32;
const CGFloat YMSessionMarkSessionListCellMaxHeight = 160;

static NSString *YMSessionMarkTrim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

uint32_t YMSessionMarkParseColor(NSString *hex, uint32_t fallback) {
    if (hex.length == 7 && [hex hasPrefix:@"#"]) {
        unsigned value = 0;
        if ([[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&value]) return value;
    }
    return fallback;
}

NSString *YMSessionMarkHexFromRGB(uint32_t rgb) {
    return [NSString stringWithFormat:@"#%02X%02X%02X",
        (unsigned)((rgb >> 16) & 255), (unsigned)((rgb >> 8) & 255), (unsigned)(rgb & 255)];
}

CGFloat YMSessionMarkClampPlaceholderSize(CGFloat value) {
    if (value < YMSessionMarkPlaceholderSizeMin) return YMSessionMarkPlaceholderSizeMin;
    if (value > YMSessionMarkPlaceholderSizeMax) return YMSessionMarkPlaceholderSizeMax;
    return (CGFloat)lround(value);
}

NSInteger YMSessionMarkClampScope(NSInteger value) {
    return value == YMSessionMarkScopeExceptAdded ? YMSessionMarkScopeExceptAdded : YMSessionMarkScopeAdded;
}

CGFloat YMSessionMarkClampAlpha(CGFloat value) {
    if (value < YMSessionMarkAlphaMin) value = YMSessionMarkAlphaMin;
    if (value > YMSessionMarkAlphaMax) value = YMSessionMarkAlphaMax;
    return round(value * 20.0) / 20.0;
}

CGFloat YMSessionMarkClampWash(CGFloat value) {
    if (value < YMSessionMarkWashMin) value = YMSessionMarkWashMin;
    if (value > YMSessionMarkWashMax) value = YMSessionMarkWashMax;
    return round(value * 50.0) / 50.0;
}

BOOL YMSessionMarkComposerFieldSized(CGFloat width, CGFloat height) {
    return width >= YMSessionMarkComposerFieldMinWidth
        && height >= YMSessionMarkComposerFieldMinHeight
        && height <= YMSessionMarkComposerFieldMaxHeight;
}

BOOL YMSessionMarkComposerSurfaceSized(CGFloat width, CGFloat height) {
    return width >= YMSessionMarkComposerFieldMinWidth
        && height >= YMSessionMarkComposerFieldMinHeight
        && height <= YMSessionMarkComposerSurfaceMaxHeight;
}

BOOL YMSessionMarkComposerOverlaySized(CGFloat width, CGFloat height) {
    return width >= YMSessionMarkComposerFieldMinWidth
        && height >= YMSessionMarkComposerFieldMinHeight
        && height <= YMSessionMarkComposerOverlayMaxHeight;
}

BOOL YMSessionMarkComposerCardSized(CGFloat cardWidth, CGFloat cardHeight,
                                    CGFloat fieldWidth, CGFloat fieldHeight) {
    return cardHeight >= fieldHeight + 8
        && cardHeight <= YMSessionMarkComposerSurfaceMaxHeight
            + YMSessionMarkComposerToolbarMaxHeight
        && cardWidth + 8 >= fieldWidth
        && cardWidth <= fieldWidth + 48;
}

BOOL YMSessionMarkComposerOuterWrapsInner(NSRect outer, NSRect inner) {
    if (NSIsEmptyRect(outer) || NSIsEmptyRect(inner)) return NO;
    const CGFloat extra = NSHeight(outer) - NSHeight(inner);
    if (extra < 8) return NO;
    if (NSWidth(inner) < YMSessionMarkComposerFieldMinWidth) return NO;
    if (NSHeight(inner) < YMSessionMarkComposerFieldMinHeight) return NO;
    if (NSWidth(outer) < NSWidth(inner) + 8) return NO;
    if (NSWidth(outer) > NSWidth(inner) + 48) return NO;
    return YES;
}

BOOL YMSessionMarkComposerChromeWrapsField(NSRect chrome, NSRect field) {
    const CGFloat extra = NSHeight(chrome) - NSHeight(field);
    if (extra < 20 || extra > YMSessionMarkComposerToolbarMaxHeight) return NO;
    return YMSessionMarkComposerOuterWrapsInner(chrome, field);
}

BOOL YMSessionMarkComposerChildIsTypingField(NSRect parent, NSRect child) {
    if (!YMSessionMarkComposerSurfaceSized(NSWidth(child), NSHeight(child))) return NO;
    return YMSessionMarkComposerOuterWrapsInner(parent, child);
}

BOOL YMSessionMarkComposerMessageListChildSized(CGFloat parentWidth, CGFloat parentHeight,
                                               CGFloat childWidth, CGFloat childHeight,
                                               CGFloat childTop) {
    // 贴父顶、底下留得出工具栏以上的剩余区才是消息列表。贴父底的输入卡不是。
    if (childHeight <= YMSessionMarkComposerFieldMaxHeight) return NO;
    const CGFloat extra = parentHeight - childHeight;
    if (extra <= YMSessionMarkComposerToolbarMaxHeight) return NO;
    if (childWidth > parentWidth + 8) return NO;
    if (childWidth + 48 < parentWidth) return NO;
    const CGFloat below = parentHeight - childTop - childHeight;
    if (below <= YMSessionMarkComposerToolbarMaxHeight) return NO;
    if (childTop > extra + 8) return NO;
    return YES;
}

BOOL YMSessionMarkComposerFieldInMessageList(CGFloat parentWidth, CGFloat parentHeight,
                                            CGFloat childWidth, CGFloat childHeight,
                                            CGFloat childTop) {
    // 父控件高过输入栏+工具栏，子控件是灰线尺寸且底下还留得出工具栏以上：列表区里的消息行，或挤矮后矮过灰线上限的消息区。
    if (!YMSessionMarkComposerFieldSized(childWidth, childHeight)) return NO;
    if (parentHeight <= YMSessionMarkComposerFieldMaxHeight + YMSessionMarkComposerToolbarMaxHeight)
        return NO;
    if (childWidth > parentWidth + 8) return NO;
    const CGFloat below = parentHeight - childTop - childHeight;
    if (below <= YMSessionMarkComposerToolbarMaxHeight) return NO;
    return YES;
}

BOOL YMSessionMarkComposerCardWrapsTypingField(NSRect card, NSRect field) {
    if (YMSessionMarkComposerFieldSized(NSWidth(card), NSHeight(card))) return NO;
    if (!YMSessionMarkComposerFieldSized(NSWidth(field), NSHeight(field))) return NO;
    const CGFloat extra = NSHeight(card) - NSHeight(field);
    if (extra < 20) return NO;
    if (NSWidth(card) + 8 < NSWidth(field)) return NO;
    if (NSWidth(card) > NSWidth(field) + 48) return NO;
    const CGFloat gapLo = NSMinY(field) - NSMinY(card);
    const CGFloat gapHi = NSMaxY(card) - NSMaxY(field);
    if (gapLo < -8 || gapHi < -8) return NO;
    if (MIN(gapLo, gapHi) > YMSessionMarkComposerToolbarMaxHeight) return NO;
    return YES;
}

BOOL YMSessionMarkComposerStripTypingSized(CGFloat width, CGFloat height) {
    if (YMSessionMarkComposerFieldSized(width, height)) return YES;
    // 拉高后的输入面高于默认外卡（约 160），外卡本身不算输入条。
    return YMSessionMarkComposerSurfaceSized(width, height)
        && height > YMSessionMarkComposerFieldMaxHeight + 40;
}

BOOL YMSessionMarkComposerTypingHitSized(BOOL hasSession, CGFloat width, CGFloat height) {
    // 带会话号按 OverlaySized（24–1200）；没有会话号仍排除约 160 的外卡。
    if (hasSession) return YMSessionMarkComposerOverlaySized(width, height);
    return YMSessionMarkComposerStripTypingSized(width, height);
}

NSRect YMSessionMarkComposerTypingSurface(NSRect field, NSRect chrome, BOOL flipped) {
    if (NSIsEmptyRect(field) || NSIsEmptyRect(chrome)) return field;
    if (NSWidth(field) < YMSessionMarkComposerFieldMinWidth) return field;
    const CGFloat extra = NSHeight(chrome) - NSHeight(field);
    if (extra <= YMSessionMarkComposerToolbarMaxHeight) return field;
    if (!NSIntersectsRect(NSInsetRect(chrome, -8, -8), field)) return field;
    const CGFloat above = flipped
        ? (NSMinY(field) - NSMinY(chrome))
        : (NSMaxY(chrome) - NSMaxY(field));
    if (above <= 8) return field;
    NSRect surface = field;
    if (flipped) {
        surface.origin.y = NSMinY(chrome);
        surface.size.height = NSMaxY(field) - NSMinY(chrome);
    } else {
        surface.origin.y = NSMinY(field);
        surface.size.height = NSMaxY(chrome) - NSMinY(field);
    }
    surface.origin.x = NSMinX(field);
    surface.size.width = NSWidth(field);
    if (!YMSessionMarkComposerSurfaceSized(NSWidth(surface), NSHeight(surface))) return field;
    return surface;
}

BOOL YMSessionMarkComposerStripBand(NSRect windowLocal, CGFloat windowHeight) {
    const CGFloat width = NSWidth(windowLocal);
    const CGFloat height = NSHeight(windowLocal);
    if (width < YMSessionMarkComposerFieldMinWidth) return NO;
    if (height < 24 || height > YMSessionMarkComposerSurfaceMaxHeight) return NO;
    if (windowHeight < 1) return NO;
    const CGFloat maxTop = MIN(
        YMSessionMarkComposerSurfaceMaxHeight + YMSessionMarkComposerToolbarMaxHeight,
        windowHeight * (CGFloat)0.70);
    const CGFloat maxBottom = MIN((CGFloat)220, windowHeight * (CGFloat)0.40);
    return NSMinY(windowLocal) < maxBottom && NSMaxY(windowLocal) < maxTop;
}

BOOL YMSessionMarkComposerBottomAnchored(NSRect windowLocal, CGFloat windowHeight) {
    // 贴窗底的输入栏可以高过窗口 70%；70% 上限只挡矮条误贴到聊天页。
    const CGFloat width = NSWidth(windowLocal);
    const CGFloat height = NSHeight(windowLocal);
    if (width < YMSessionMarkComposerFieldMinWidth) return NO;
    if (height < 24 || height > YMSessionMarkComposerOverlayMaxHeight) return NO;
    if (windowHeight < 1) return NO;
    const CGFloat maxBottom = MIN((CGFloat)220, windowHeight * (CGFloat)0.40);
    return NSMinY(windowLocal) < maxBottom;
}

BOOL YMSessionMarkComposerNearWindowBottom(NSRect viewScreen, NSRect windowScreen) {
    if (NSIsEmptyRect(viewScreen) || NSIsEmptyRect(windowScreen)) return NO;
    const CGFloat width = NSWidth(viewScreen);
    const CGFloat height = NSHeight(viewScreen);
    if (width < YMSessionMarkComposerFieldMinWidth) return NO;
    if (height < 24 || height > YMSessionMarkComposerSurfaceMaxHeight) return NO;
    const CGFloat windowHeight = NSHeight(windowScreen);
    if (windowHeight < 1) return NO;
    const CGFloat fromBottom = NSMinY(viewScreen) - NSMinY(windowScreen);
    const CGFloat topFromBottom = NSMaxY(viewScreen) - NSMinY(windowScreen);
    const CGFloat maxTop = MIN(
        YMSessionMarkComposerSurfaceMaxHeight + YMSessionMarkComposerToolbarMaxHeight,
        windowHeight * (CGFloat)0.70);
    const CGFloat maxBottom = MIN((CGFloat)220, windowHeight * (CGFloat)0.40);
    return fromBottom > -40 && fromBottom < maxBottom && topFromBottom < maxTop;
}

BOOL YMSessionMarkComposerNearWindowBottomAnchored(NSRect viewScreen, NSRect windowScreen) {
    if (NSIsEmptyRect(viewScreen) || NSIsEmptyRect(windowScreen)) return NO;
    const CGFloat width = NSWidth(viewScreen);
    const CGFloat height = NSHeight(viewScreen);
    if (width < YMSessionMarkComposerFieldMinWidth) return NO;
    if (height < 24 || height > YMSessionMarkComposerOverlayMaxHeight) return NO;
    const CGFloat windowHeight = NSHeight(windowScreen);
    if (windowHeight < 1) return NO;
    const CGFloat fromBottom = NSMinY(viewScreen) - NSMinY(windowScreen);
    const CGFloat maxBottom = MIN((CGFloat)220, windowHeight * (CGFloat)0.40);
    return fromBottom > -40 && fromBottom < maxBottom;
}

BOOL YMSessionMarkComposerNearWindowTop(NSRect viewScreen, NSRect windowScreen) {
    if (NSIsEmptyRect(viewScreen) || NSIsEmptyRect(windowScreen)) return NO;
    const CGFloat height = NSHeight(viewScreen);
    if (height < 1 || height > 40) return NO;
    if (NSWidth(viewScreen) < YMSessionMarkComposerFieldMinWidth) return NO;
    const CGFloat fromTop = NSMaxY(windowScreen) - NSMaxY(viewScreen);
    return fromTop > -8 && fromTop < 80;
}

BOOL YMSessionMarkComposerInChatColumn(NSRect viewScreen, NSRect listColumnScreen) {
    if (NSIsEmptyRect(viewScreen)) return NO;
    if (NSIsEmptyRect(listColumnScreen)) return YES;
    // 整块都在会话列表列里才排除。列表列记宽时，输入条仍会伸到列右缘以外。
    if (NSMaxX(viewScreen) <= NSMaxX(listColumnScreen) + 8 &&
        NSMinX(viewScreen) < NSMaxX(listColumnScreen))
        return NO;
    return YES;
}

BOOL YMSessionMarkComposerStripPreferWider(NSRect current, NSRect challenger) {
    if (!YMSessionMarkComposerStripTypingSized(NSWidth(challenger), NSHeight(challenger))) return NO;
    if (NSIsEmptyRect(current)) return YES;
    return NSWidth(challenger) > NSWidth(current) + 0.5;
}

BOOL YMSessionMarkSessionInfoPanelSized(CGFloat width, CGFloat height) {
    return width >= YMSessionMarkSessionInfoPanelMinWidth
        && width <= YMSessionMarkSessionInfoPanelMaxWidth
        && height >= YMSessionMarkSessionInfoPanelMinHeight;
}

NSRect YMSessionMarkClipComposerFrameAwayFromPanel(NSRect field, NSRect panel) {
    if (NSWidth(field) < YMSessionMarkComposerFieldMinWidth) return NSZeroRect;
    const CGFloat width = NSWidth(panel);
    const CGFloat height = NSHeight(panel);
    const BOOL tall = YMSessionMarkSessionInfoPanelSized(width, height);
    const BOOL sameBand = width >= YMSessionMarkSessionInfoPanelMinWidth
        && width <= YMSessionMarkSessionInfoPanelMaxWidth
        && YMSessionMarkComposerFieldSized(width, height);
    if (!tall && !sameBand) return field;
    if (NSMinX(panel) <= NSMinX(field) + 8) return field;
    if (NSMinX(panel) >= NSMaxX(field) - 1) return field;
    if (NSMaxY(panel) <= NSMinY(field) + 4) return field;
    if (NSMinY(panel) >= NSMaxY(field) - 4) return field;
    // 宽 160–400 的右侧栏矩形裁输入框右缘；中间气泡/成员卡不裁。
    if (sameBand && !tall && NSMaxX(panel) < NSMaxX(field) - 16) return field;
    const CGFloat clippedWidth = NSMinX(panel) - NSMinX(field);
    if (clippedWidth < YMSessionMarkComposerFieldMinWidth) return NSZeroRect;
    NSRect clipped = field;
    clipped.size.width = clippedWidth;
    return clipped;
}

BOOL YMSessionMarkSessionListCellSized(CGFloat width, CGFloat height) {
    return width >= YMSessionMarkSessionListCellMinWidth
        && width <= YMSessionMarkSessionListCellMaxWidth
        && height >= YMSessionMarkSessionListCellMinHeight
        && height <= YMSessionMarkSessionListCellMaxHeight;
}

BOOL YMSessionMarkWindowTitleIsMain(NSString *title) {
    return [title isEqual:@"微信"] || [title isEqual:@"WeChat"];
}

BOOL YMSessionMarkWindowTitleIsUtility(NSString *title) {
    if (!title.length) return NO;
    return [title isEqual:@"定时群提醒"] || [title hasPrefix:@"定时群提醒"] ||
        [title isEqual:@"会话标识"] || [title isEqual:@"数据库连接信息"] ||
        [title isEqual:@"群身份角标"] ||
        [title hasSuffix:@"聊天记录"] ||
        [title isEqual:@"微信红包"] || [title hasPrefix:@"微信红包"];
}

BOOL YMSessionMarkWindowFrameInside(NSRect inner, NSRect outer) {
    if (NSIsEmptyRect(inner) || NSIsEmptyRect(outer)) return NO;
    return NSContainsRect(NSInsetRect(outer, -32, -32), inner);
}

BOOL YMSessionMarkWindowFrameOverlapsMain(NSRect inner, NSRect outer) {
    if (NSIsEmptyRect(inner) || NSIsEmptyRect(outer)) return NO;
    NSRect hit = NSIntersectionRect(inner, outer);
    return NSWidth(hit) >= YMSessionMarkSessionListCellMinWidth
        && NSHeight(hit) >= YMSessionMarkSessionListCellMinHeight;
}

BOOL YMSessionMarkWindowSizeMatchesMain(CGFloat innerWidth, CGFloat innerHeight,
    CGFloat outerWidth, CGFloat outerHeight) {
    return fabs(innerWidth - outerWidth) <= 48 && fabs(innerHeight - outerHeight) <= 80;
}

BOOL YMSessionMarkWindowHostsSessionChrome(NSString *title, BOOL insideMainChat, BOOL insideUtilityWindow) {
    if (YMSessionMarkWindowTitleIsUtility(title) || insideUtilityWindow) return NO;
    if (YMSessionMarkWindowTitleIsMain(title)) return YES;
    return insideMainChat;
}

static uint32_t YMSessionMarkMixWhite(uint32_t rgb, double mix) {
    unsigned red = (rgb >> 16) & 255;
    unsigned green = (rgb >> 8) & 255;
    unsigned blue = rgb & 255;
    red = (unsigned)lround(red + (255.0 - red) * mix);
    green = (unsigned)lround(green + (255.0 - green) * mix);
    blue = (unsigned)lround(blue + (255.0 - blue) * mix);
    return (red << 16) | (green << 8) | blue;
}

uint32_t YMSessionMarkFluorescentRGB(uint32_t rgb) {
    return YMSessionMarkMixWhite(rgb, 0.35);
}

NSString *YMSessionMarkStoredName(NSString *raw, NSString *fallback) {
    NSString *line = YMSessionMarkTrim(raw ?: @"");
    line = [[line stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSRange cut = [line rangeOfString:@"\n"];
    if (cut.location != NSNotFound) line = [line substringToIndex:cut.location];
    line = YMSessionMarkTrim(line);
    if (line.length > YMSessionMarkNameMaxLength) line = [line substringToIndex:YMSessionMarkNameMaxLength];
    if (line.length) return line;
    NSString *fallbackLine = YMSessionMarkTrim(fallback ?: @"");
    if (fallbackLine.length > YMSessionMarkNameMaxLength)
        fallbackLine = [fallbackLine substringToIndex:YMSessionMarkNameMaxLength];
    return fallbackLine.length ? fallbackLine : @"工作";
}

NSString *YMSessionMarkCanonicalSession(NSString *session) {
    NSString *value = YMSessionMarkTrim(session ?: @"");
    if (!value.length) return nil;
    static NSString *const imSuffix = @"@im.chatroom";
    if (value.length > imSuffix.length && [value hasSuffix:imSuffix]) {
        value = [[value substringToIndex:value.length - imSuffix.length]
            stringByAppendingString:@"@chatroom"];
    }
    return value;
}

BOOL YMSessionMarkIsSessionId(NSString *session) {
    NSString *value = YMSessionMarkCanonicalSession(session);
    return value.length && value.length <= 128 &&
        [value rangeOfString:@"^[A-Za-z0-9_-]+(@chatroom)?$" options:NSRegularExpressionSearch].location != NSNotFound;
}

BOOL YMSessionMarkAcceptsSession(NSString *session, NSString *account) {
    NSString *value = YMSessionMarkCanonicalSession(session);
    if (!YMAppearanceValidSession(value)) return NO;
    if (YMSessionMarkSessionIsFolderHolder(value)) return NO;
    if (account.length && [value isEqual:account]) return NO;
    return YES;
}

BOOL YMSessionMarkSessionIsFolderHolder(NSString *session) {
    NSString *value = YMSessionMarkCanonicalSession(session);
    return value.length &&
        [@[@"brandsessionholder", @"brandservicesessionholder", @"officialaccounts"] containsObject:value];
}

YMSessionMarkComposerCellAction YMSessionMarkComposerActionForSelectedCell(
    NSString *accepted, NSDictionary *mark, NSString *identity,
    NSString *account, NSString *openSession) {
    if (mark) return YMSessionMarkComposerCellBind;
    if (YMSessionMarkSessionIsFolderHolder(accepted) ||
        YMSessionMarkSessionIsFolderHolder(identity))
        return YMSessionMarkComposerCellDrop;
    if (accepted.length) return YMSessionMarkComposerCellDrop;
    (void)openSession;
    if (identity.length && YMSessionMarkIsSessionId(identity) &&
        !YMSessionMarkAcceptsSession(identity, account))
        return YMSessionMarkComposerCellDrop;
    return YMSessionMarkComposerCellIgnore;
}

BOOL YMSessionMarkComposerShouldDropPending(
    NSString *openSession, BOOL openMarked, NSString *pendingDrop, BOOL selectedMarkedThisTurn) {
    (void)openSession;
    (void)openMarked;
    if (selectedMarkedThisTurn) return NO;
    if (!pendingDrop.length) return NO;
    // 本轮选中的是未标记格，就拆叠层。打开会话号可能还停在上一群。
    return YES;
}

NSString *YMSessionMarkSetsKey(NSString *account) {
    NSString *owner = YMSessionMarkTrim(account ?: @"");
    if (!owner.length) owner = @"_";
    return [NSString stringWithFormat:@"YMSessionMarkSets.SOVIET.%@", owner];
}

void YMSessionMarkRegisterDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            YMSessionMarkEnabledKey: @NO,
            YMSessionMarkScopeKey: @(YMSessionMarkScopeAdded),
        }];
    });
}

BOOL YMSessionMarkEnabled(void) {
    YMSessionMarkRegisterDefaults();
    return [NSUserDefaults.standardUserDefaults boolForKey:YMSessionMarkEnabledKey];
}

static void YMSessionMarkInvalidateCache(void);

NSInteger YMSessionMarkScope(void) {
    YMSessionMarkRegisterDefaults();
    return YMSessionMarkClampScope([NSUserDefaults.standardUserDefaults integerForKey:YMSessionMarkScopeKey]);
}

void YMSessionMarkSetScope(NSInteger scope) {
    YMSessionMarkRegisterDefaults();
    [NSUserDefaults.standardUserDefaults setInteger:YMSessionMarkClampScope(scope) forKey:YMSessionMarkScopeKey];
    YMSessionMarkInvalidateCache();
    [[NSNotificationCenter defaultCenter] postNotificationName:YMSessionMarkChangedNotification object:nil];
}

NSMutableDictionary *YMSessionMarkDefaultSet(NSString *name) {
    return [@{
        @"id": [[NSUUID UUID] UUIDString],
        @"name": YMSessionMarkStoredName(name, @"工作"),
        @"color": YMSessionMarkHexFromRGB(YMSessionMarkDefaultColorRGB),
        @"border": @YES,
        @"placeholder": @"",
        @"placeholderSize": @(YMSessionMarkPlaceholderSizeDefault),
        @"placeholderColor": YMSessionMarkHexFromRGB(YMSessionMarkDefaultPlaceholderRGB),
        @"alpha": @(YMSessionMarkAlphaDefault),
        @"wash": @(YMSessionMarkWashDefault),
        @"sessions": @[],
        @"sessionTitles": @{},
    } mutableCopy];
}

static NSArray<NSString *> *YMSessionMarkCleanSessions(id value, NSString *account, NSMutableDictionary *titles) {
    NSMutableArray<NSString *> *sessions = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray *raw = [value isKindOfClass:NSArray.class] ? value : @[];
    for (id item in raw) {
        if (sessions.count >= YMSessionMarkSessionLimit) break;
        NSString *session = nil;
        NSString *title = nil;
        if ([item isKindOfClass:NSString.class]) session = item;
        else if ([item isKindOfClass:NSDictionary.class]) {
            session = item[@"id"];
            title = item[@"title"] ?: item[@"name"];
        }
        NSString *canonical = YMSessionMarkCanonicalSession(session);
        if (!YMSessionMarkAcceptsSession(canonical, account) || [seen containsObject:canonical]) continue;
        [seen addObject:canonical];
        [sessions addObject:canonical];
        NSString *trimmed = YMSessionMarkTrim(title ?: @"");
        if (trimmed.length) titles[canonical] = trimmed;
    }
    return sessions;
}

NSArray<NSDictionary *> *YMSessionMarkNormalizedSets(NSArray *sets) {
    NSString *account = YMAppearanceAccount();
    NSMutableArray<NSMutableDictionary *> *normalized = [NSMutableArray array];
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    for (id item in [sets isKindOfClass:NSArray.class] ? sets : @[]) {
        if (normalized.count >= YMSessionMarkSetLimit) break;
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *raw = item;
        NSMutableDictionary *mark = YMSessionMarkDefaultSet(raw[@"name"]);
        NSString *ident = YMSessionMarkTrim(raw[@"id"] ?: @"");
        if (!ident.length || [ids containsObject:ident]) ident = mark[@"id"];
        [ids addObject:ident];
        mark[@"id"] = ident;
        mark[@"name"] = YMSessionMarkStoredName(raw[@"name"], @"工作");
        mark[@"color"] = YMSessionMarkHexFromRGB(
            YMSessionMarkParseColor(raw[@"color"], YMSessionMarkDefaultColorRGB));
        mark[@"border"] = @([raw[@"border"] respondsToSelector:@selector(boolValue)] ? [raw[@"border"] boolValue] : YES);
        mark[@"placeholder"] = YMSessionMarkTrim(raw[@"placeholder"] ?: @"");
        if ([mark[@"placeholder"] length] > 80)
            mark[@"placeholder"] = [mark[@"placeholder"] substringToIndex:80];
        mark[@"placeholderSize"] = @(YMSessionMarkClampPlaceholderSize([raw[@"placeholderSize"] doubleValue]));
        mark[@"placeholderColor"] = YMSessionMarkHexFromRGB(
            YMSessionMarkParseColor(raw[@"placeholderColor"], YMSessionMarkDefaultPlaceholderRGB));
        mark[@"alpha"] = @(YMSessionMarkClampAlpha(
            [raw[@"alpha"] respondsToSelector:@selector(doubleValue)]
                ? [raw[@"alpha"] doubleValue] : YMSessionMarkAlphaDefault));
        mark[@"wash"] = @(YMSessionMarkClampWash(
            [raw[@"wash"] respondsToSelector:@selector(doubleValue)]
                ? [raw[@"wash"] doubleValue] : YMSessionMarkWashDefault));
        NSMutableDictionary *titles = [NSMutableDictionary dictionary];
        if ([raw[@"sessionTitles"] isKindOfClass:NSDictionary.class]) {
            [raw[@"sessionTitles"] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                (void)stop;
                if (![key isKindOfClass:NSString.class] || ![obj isKindOfClass:NSString.class]) return;
                NSString *canonical = YMSessionMarkCanonicalSession(key);
                NSString *title = YMSessionMarkTrim(obj);
                if (canonical.length && title.length) titles[canonical] = title;
            }];
        }
        mark[@"sessions"] = YMSessionMarkCleanSessions(raw[@"sessions"], account, titles);
        NSMutableDictionary *keptTitles = [NSMutableDictionary dictionary];
        for (NSString *session in mark[@"sessions"]) {
            if (titles[session]) keptTitles[session] = titles[session];
        }
        mark[@"sessionTitles"] = keptTitles;
        [normalized addObject:mark];
    }
    NSMutableSet<NSString *> *claimed = [NSMutableSet set];
    for (NSInteger index = (NSInteger)normalized.count - 1; index >= 0; --index) {
        NSMutableDictionary *mark = normalized[(NSUInteger)index];
        NSMutableArray *kept = [NSMutableArray array];
        NSMutableDictionary *titles = [mark[@"sessionTitles"] mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *session in mark[@"sessions"]) {
            if ([claimed containsObject:session]) {
                [titles removeObjectForKey:session];
                continue;
            }
            [claimed addObject:session];
            [kept addObject:session];
        }
        mark[@"sessions"] = kept;
        mark[@"sessionTitles"] = titles;
    }
    return normalized;
}

static NSString *gYMSessionMarkCacheAccount;
static NSArray<NSDictionary *> *gYMSessionMarkCacheSets;
static NSDictionary<NSString *, NSDictionary *> *gYMSessionMarkCacheBySession;
static BOOL gYMSessionMarkCacheValid;

static void YMSessionMarkInvalidateCache(void) {
    gYMSessionMarkCacheValid = NO;
    gYMSessionMarkCacheAccount = nil;
    gYMSessionMarkCacheSets = nil;
    gYMSessionMarkCacheBySession = nil;
}

static void YMSessionMarkLoadCache(NSString *account) {
    NSString *owner = YMSessionMarkTrim(account ?: @"");
    if (gYMSessionMarkCacheValid && [gYMSessionMarkCacheAccount isEqual:owner]) return;
    YMSessionMarkRegisterDefaults();
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:YMSessionMarkSetsKey(account)];
    NSArray<NSDictionary *> *sets = YMSessionMarkNormalizedSets(stored);
    NSMutableDictionary<NSString *, NSDictionary *> *map = [NSMutableDictionary dictionary];
    for (NSDictionary *mark in sets) {
        NSArray *sessions = [mark[@"sessions"] isKindOfClass:NSArray.class] ? mark[@"sessions"] : @[];
        for (id session in sessions) {
            if ([session isKindOfClass:NSString.class] && [session length]) map[session] = mark;
        }
    }
    gYMSessionMarkCacheAccount = owner;
    gYMSessionMarkCacheSets = sets;
    gYMSessionMarkCacheBySession = map;
    gYMSessionMarkCacheValid = YES;
}

NSArray<NSDictionary *> *YMSessionMarkSets(NSString *account) {
    YMSessionMarkLoadCache(account);
    return gYMSessionMarkCacheSets ?: @[];
}

void YMSessionMarkSaveSets(NSString *account, NSArray *sets) {
    YMSessionMarkRegisterDefaults();
    NSArray<NSDictionary *> *normalized = YMSessionMarkNormalizedSets(sets);
    [NSUserDefaults.standardUserDefaults setObject:normalized forKey:YMSessionMarkSetsKey(account)];
    [NSUserDefaults.standardUserDefaults synchronize];
    YMSessionMarkInvalidateCache();
    YMSessionMarkLoadCache(account);
    [[NSNotificationCenter defaultCenter] postNotificationName:YMSessionMarkChangedNotification object:nil];
}

NSDictionary *YMSessionMarkLookup(NSString *account, NSString *session) {
    NSString *key = YMSessionMarkCanonicalSession(session);
    if (!YMSessionMarkEnabled() || !YMSessionMarkAcceptsSession(key, account)) return nil;
    YMSessionMarkLoadCache(account);
    NSDictionary *hit = gYMSessionMarkCacheBySession[key];
    if (YMSessionMarkScope() != YMSessionMarkScopeExceptAdded) return hit;
    if (hit) return nil;
    NSDictionary *visual = gYMSessionMarkCacheSets.firstObject;
    if (!visual) return nil;
    NSMutableDictionary *mark = [visual mutableCopy];
    mark[@"name"] = YMSessionMarkExceptAddedName;
    mark[@"exceptAdded"] = @YES;
    return mark;
}

NSString *YMSessionMarkSessionTitle(NSDictionary *mark, NSString *session) {
    NSDictionary *titles = [mark[@"sessionTitles"] isKindOfClass:NSDictionary.class] ? mark[@"sessionTitles"] : @{};
    NSString *key = YMSessionMarkCanonicalSession(session) ?: @"";
    NSString *title = YMSessionMarkTrim(titles[key] ?: titles[session] ?: @"");
    return title;
}

NSString *YMSessionMarkPlaceholderText(NSDictionary *mark) {
    NSString *custom = YMSessionMarkTrim(mark[@"placeholder"] ?: @"");
    if (custom.length) return custom;
    NSString *name = [mark[@"exceptAdded"] boolValue] ? YMSessionMarkExceptAddedName
        : YMSessionMarkStoredName(mark[@"name"], @"工作");
    return [NSString stringWithFormat:@"当前是「%@」", name];
}

NSAttributedString *YMSessionMarkQuotedString(NSString *text, CGFloat size, NSColor *color, NSTextAlignment align) {
    NSString *line = text.length ? text : @"";
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = align;
    NSDictionary *base = @{
        NSFontAttributeName: [NSFont systemFontOfSize:size],
        NSForegroundColorAttributeName: color ?: NSColor.labelColor,
        NSParagraphStyleAttributeName: style
    };
    NSMutableAttributedString *value = [[NSMutableAttributedString alloc] initWithString:line attributes:base];
    CGFloat inner = YMSessionMarkClampPlaceholderSize(size + 2);
    NSUInteger loc = 0;
    while (loc < line.length) {
        NSRange open = [line rangeOfString:@"「" options:0 range:NSMakeRange(loc, line.length - loc)];
        if (open.location == NSNotFound) break;
        NSRange close = [line rangeOfString:@"」" options:0
            range:NSMakeRange(open.location + 1, line.length - open.location - 1)];
        if (close.location == NSNotFound) break;
        NSRange innerRange = NSMakeRange(open.location + 1, close.location - open.location - 1);
        if (innerRange.length)
            [value addAttribute:NSFontAttributeName
                value:[NSFont systemFontOfSize:inner weight:NSFontWeightSemibold]
                range:innerRange];
        loc = close.location + 1;
    }
    return value;
}

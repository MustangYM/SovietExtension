#import "AppearanceNative.h"
#import "GroupRoleBadge.h"
#import "GroupRoleNative.h"
#import <AppKit/AppKit.h>
#import <math.h>

const CGFloat YMGroupRoleBadgeChatAvatarSize = 40;
const CGFloat YMGroupRoleBadgeCaptionPad = 16;
const CGFloat YMGroupRoleBadgeFontMin = 4;
const CGFloat YMGroupRoleBadgeFontMax = 12;
const CGFloat YMGroupRoleBadgeGapMin = -4;
const CGFloat YMGroupRoleBadgeGapMax = 4;

CGFloat YMGroupRoleBadgeLineHeight(CGFloat fontSize) {
    if (fontSize < 1) fontSize = 1;
    static NSLayoutManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [NSLayoutManager new]; });
    NSFont *font = [NSFont systemFontOfSize:fontSize weight:NSFontWeightMedium];
    return fmax(5.0, ceil([manager defaultLineHeightForFont:font] + 1.0));
}

CGFloat YMGroupRoleBadgeCaptionTopQt(CGFloat avatarY, CGFloat avatarHeight, CGFloat captionHeight, CGFloat gap, BOOL above) {
    return above ? avatarY - gap - captionHeight : avatarY + avatarHeight + gap;
}

NSRect YMGroupRoleBadgePreviewCaptionFrame(NSRect avatar, CGFloat fontSize, CGFloat gap, BOOL above) {
    CGFloat height = YMGroupRoleBadgeLineHeight(fontSize);
    CGFloat y = above
        ? NSMaxY(avatar) + gap
        : NSMinY(avatar) - gap - height;
    return NSMakeRect(NSMinX(avatar) - YMGroupRoleBadgeCaptionPad, y,
                      NSWidth(avatar) + YMGroupRoleBadgeCaptionPad * 2, height);
}

NSString * const YMGroupRoleBadgeEnabledKey = @"YMGroupRoleBadgeEnabled.SOVIET";
NSString * const YMGroupRoleBadgePositionKey = @"YMGroupRoleBadgePosition.SOVIET";
NSString * const YMGroupRoleBadgeFontSizeKey = @"YMGroupRoleBadgeFontSize.SOVIET";
NSString * const YMGroupRoleBadgeGapKey = @"YMGroupRoleBadgeGap.SOVIET";
NSString * const YMGroupRoleBadgeOwnerColorKey = @"YMGroupRoleBadgeOwnerColor.SOVIET";
NSString * const YMGroupRoleBadgeAdminColorKey = @"YMGroupRoleBadgeAdminColor.SOVIET";
NSString * const YMGroupRoleBadgeOwnerTextKey = @"YMGroupRoleBadgeOwnerText.SOVIET";
NSString * const YMGroupRoleBadgeAdminTextKey = @"YMGroupRoleBadgeAdminText.SOVIET";

void YMGroupRoleBadgeRegisterDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            YMGroupRoleBadgeEnabledKey: @NO,
            YMGroupRoleBadgePositionKey: @0,
            YMGroupRoleBadgeFontSizeKey: @8,
            YMGroupRoleBadgeGapKey: @0,
            YMGroupRoleBadgeOwnerColorKey: @"#C47A12",
            YMGroupRoleBadgeAdminColorKey: @"#2F6FED",
            YMGroupRoleBadgeOwnerTextKey: @"群主",
            YMGroupRoleBadgeAdminTextKey: @"管理员",
        }];
    });
}

BOOL YMGroupRoleBadgeEnabled(void) {
    YMGroupRoleBadgeRegisterDefaults();
    return [NSUserDefaults.standardUserDefaults boolForKey:YMGroupRoleBadgeEnabledKey];
}

NSInteger YMGroupRoleBadgePosition(void) {
    YMGroupRoleBadgeRegisterDefaults();
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:YMGroupRoleBadgePositionKey];
    return value == 1 ? 1 : 0;
}

static CGFloat YMGroupRoleBadgeClampPt(CGFloat value, CGFloat min, CGFloat max) {
    if (value < min) return min;
    if (value > max) return max;
    return (CGFloat)lround(value);
}

CGFloat YMGroupRoleBadgeFontSize(void) {
    YMGroupRoleBadgeRegisterDefaults();
    return YMGroupRoleBadgeClampPt(
        [NSUserDefaults.standardUserDefaults doubleForKey:YMGroupRoleBadgeFontSizeKey],
        YMGroupRoleBadgeFontMin, YMGroupRoleBadgeFontMax);
}

CGFloat YMGroupRoleBadgeGap(void) {
    YMGroupRoleBadgeRegisterDefaults();
    return YMGroupRoleBadgeClampPt(
        [NSUserDefaults.standardUserDefaults doubleForKey:YMGroupRoleBadgeGapKey],
        YMGroupRoleBadgeGapMin, YMGroupRoleBadgeGapMax);
}

static uint32_t YMGroupRoleBadgeParseColor(NSString *hex, uint32_t fallback) {
    if (hex.length == 7 && [hex hasPrefix:@"#"]) {
        unsigned value = 0;
        if ([[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&value]) return value;
    }
    return fallback;
}

uint32_t YMGroupRoleBadgeColorRGB(NSString *identity) {
    YMGroupRoleBadgeRegisterDefaults();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([identity isEqual:@"群主"])
        return YMGroupRoleBadgeParseColor([defaults stringForKey:YMGroupRoleBadgeOwnerColorKey], 0xC47A12);
    return YMGroupRoleBadgeParseColor([defaults stringForKey:YMGroupRoleBadgeAdminColorKey], 0x2F6FED);
}

NSArray<NSString *> *YMGroupRoleBadgeLines(NSString *caption) {
    if (!caption.length) return @[];
    NSString *normalized = [[caption stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *part in [normalized componentsSeparatedByString:@"\n"]) {
        NSString *line = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length) continue;
        if (line.length > 48) line = [line substringToIndex:48];
        [lines addObject:line];
        break; // 只保留第一行非空
    }
    return lines;
}

NSString *YMGroupRoleBadgeStoredText(NSString *raw, NSString *fallback) {
    NSArray<NSString *> *lines = YMGroupRoleBadgeLines(raw);
    if (lines.count) return lines.firstObject;
    NSArray<NSString *> *fallbackLines = YMGroupRoleBadgeLines(fallback);
    if (fallbackLines.count) return fallbackLines.firstObject;
    return fallback.length ? fallback : @"";
}

NSString *YMGroupRoleBadgeCaption(NSString *identity) {
    YMGroupRoleBadgeRegisterDefaults();
    if (!identity.length) return @"";
    const BOOL owner = [identity isEqual:@"群主"];
    NSString *fallback = owner ? @"群主" : @"管理员";
    NSString *raw = [NSUserDefaults.standardUserDefaults stringForKey:
        owner ? YMGroupRoleBadgeOwnerTextKey : YMGroupRoleBadgeAdminTextKey];
    return YMGroupRoleBadgeStoredText(raw, fallback);
}

NSString *YMGroupRoleBadgeIdentity(NSString *group, NSString *sender) {
    if (!NSThread.isMainThread || !group.UTF8String || !sender.UTF8String) return nil;
    const std::string room = group.UTF8String;
    const std::string member = sender.UTF8String;
    if (!ym::group_info::native_source::groupID(room) || !ym::group_info::profileMemberID(member)) return nil;
    NSString *account = YMAppearanceAccount();
    if (!account.UTF8String || !ym::group_info::profileMemberID(account.UTF8String)) return nil;
    static std::string cachedAccount, cachedGroup, cachedOwner;
    static std::set<std::string> cachedAdmins;
    static CFAbsoluteTime cachedAt = 0;
    static bool cached = false;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!(cached && cachedAccount == account.UTF8String && cachedGroup == room && now - cachedAt < 2.0)) {
        ym::group_info::NativeRoomSources snap;
        if (!YMCopyCachedGroupRoles(room, account.UTF8String, snap)) {
            cached = false;
            return nil;
        }
        cached = true;
        cachedAt = now;
        cachedAccount = account.UTF8String;
        cachedGroup = snap.group;
        cachedOwner = snap.owner;
        cachedAdmins = snap.admins;
    }
    if (!cachedOwner.empty() && member == cachedOwner) return @"群主";
    if (cachedAdmins.contains(member)) return @"管理员";
    return nil;
}

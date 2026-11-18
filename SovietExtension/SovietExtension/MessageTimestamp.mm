#import "MessageTimestamp.h"
#import "RevokePatch.h"
#import "WeChatCompatibility.h"
#import "GroupRoleBadge.h"
#import "ChatPaneClip.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach_vm.h>
#import <libkern/OSCacheControl.h>
#import <sys/mman.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <initializer_list>
#include <string>
#include <unordered_map>
#include <unistd.h>

NSString *const YMMessageTimestampEnabledKey = @"YMMessageTimestampEnabled.SOVIET";
NSString *const YMMessageTimestampFormatKey = @"YMMessageTimestampFormat.SOVIET";
NSString *const YMMessageTimestampColorKey = @"YMMessageTimestampColor.SOVIET";

@interface YMRoleBadgeLiveCaption : NSView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSFont *font;
@property (nonatomic, strong) NSColor *textColor;
@end
@implementation YMRoleBadgeLiveCaption
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; } // 不挡消息格点击
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (!self.text.length || !self.font) return;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    [self.text drawInRect:self.bounds withAttributes:@{
        NSFontAttributeName: self.font,
        NSForegroundColorAttributeName: self.textColor ?: NSColor.labelColor,
        NSParagraphStyleAttributeName: style
    }];
}
@end

@interface YMRoleBadgeJob : NSObject
@property (nonatomic, assign) void *widget;
@property (nonatomic, strong) NSView *host;
@property (nonatomic, assign) NSRect frame;
@property (nonatomic, copy) NSString *line;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) uint32_t rgb;
@end
@implementation YMRoleBadgeJob
@end

#if defined(__aarch64__)
namespace {
struct NativeLayout {
    uintptr_t messageTable, widgetEvent, painterConstruct, painterDestruct;
    uintptr_t painterSetPen, painterScale, painterDrawText, qStringUTF8, qStringDestruct;
    size_t timestampOffset, paintSlotOffset;
};
constexpr NativeLayout layout270353 = {
    0xa006478, 0x6b75a14, 0x6f9f5b8, 0x6f9fe34,
    0x6fa4c30, 0x6fa047c, 0x6fa9cd4, 0x7069338, 0xadba4, 0xa8, 0x100
};
const NativeLayout *native = nullptr;

bool roleBadgeEnabled() {
    return native && YMGroupRoleBadgeEnabled();
}

using Event = bool (*)(void *, void *);
using Paint = void (*)(void *, void *);
Event originalEvent = nullptr;
std::unordered_map<uintptr_t, Paint> originalPaint;
bool installed = false;

bool readBytes(uintptr_t address, void *out, size_t size) {
    mach_vm_size_t copied = 0;
    return address && size && address <= UINTPTR_MAX - size &&
        mach_vm_read_overwrite(mach_task_self(), address, size,
            reinterpret_cast<mach_vm_address_t>(out), &copied) == KERN_SUCCESS && copied == size;
}
template <typename T> bool read(uintptr_t address, T &out) { return readBytes(address, &out, sizeof out); }

uintptr_t messageData(uintptr_t widget) {
    uintptr_t model = 0, table = 0;
    if (!native || !read(widget + 0x230, model) || !model) return 0;
    // 文字/图片等消息与语音视图的 MessageData 嵌入偏移不同。
    for (uintptr_t offset : {uintptr_t(0x120), uintptr_t(0x130)})
        if (read(model + offset, table) && table == YMRuntimeAddress(native->messageTable))
            return model + offset;
    return 0;
}

bool isA(uintptr_t object, const char *name) {
    uintptr_t table = 0, cast = 0;
    if (!read(object, table) || !table || !read(table + 8, cast) || !cast) return false;
    return ((void *(*)(void *, const char *))cast)((void *)object, name) != nullptr;
}

struct Rect { int x = 0, y = 0, width = 0, height = 0; };
bool widgetRect(uintptr_t object, Rect &out) {
    uintptr_t data = 0;
    int bounds[4] = {};
    // QWidgetData+0x14：父坐标 x1,y1,x2,y2。QWidgetData+0 是原生 WId（QNSView*）。
    if (!read(object + 0x28, data) || !data || !readBytes(data + 0x14, bounds, sizeof bounds)) return false;
    out = {bounds[0], bounds[1], bounds[2] - bounds[0] + 1, bounds[3] - bounds[1] + 1};
    return out.width > 0 && out.height > 0 && out.width < 10000 && out.height < 10000;
}

bool findAvatar(uintptr_t node, int depth, int x, int y, Rect &out, unsigned &visits) {
    struct Candidate { uintptr_t node; int depth, x, y; };
    Candidate pending[128];
    pending[0] = {node, depth, x, y};
    size_t count = 1;
    // 先找消息行的主头像，避免先进入引用内容并取到其嵌套头像。
    for (size_t index = 0; index < count && visits < 128; ++index) {
        Candidate item = pending[index];
        ++visits;
        if (!item.node || item.depth > 8) continue;
        if (item.depth) {
            if (!isA(item.node, "QWidget")) continue;
            Rect r;
            if (!widgetRect(item.node, r)) continue;
            item.x += r.x; item.y += r.y;
        }
        if (isA(item.node, "mmui::ContactHeadView")) {
            Rect r;
            if (!widgetRect(item.node, r)) continue;
            out = {item.x, item.y, r.width, r.height};
            return true;
        }
        if (item.depth == 8) continue;
        uintptr_t priv = 0, children = 0;
        int begin = 0, end = 0;
        if (!read(item.node + 8, priv) || !priv || !read(priv + 24, children) || !children ||
            !read(children + 8, begin) || !read(children + 12, end) ||
            begin < 0 || end < begin || end - begin > 128) continue;
        for (int i = begin; i < end && count < 128; ++i) {
            uintptr_t child = 0;
            if (read(children + 16 + uintptr_t(i) * 8, child) && child)
                pending[count++] = {child, item.depth + 1, item.x, item.y};
        }
    }
    return false;
}

bool nativeString(uintptr_t address, std::string &out) {
    uint8_t bytes[24] = {};
    if (!readBytes(address, bytes, sizeof bytes)) return false;
    uintptr_t source = address;
    size_t length = bytes[23];
    if (bytes[23] & 0x80) {
        std::memcpy(&source, bytes, 8);
        std::memcpy(&length, bytes + 8, 8);
    }
    if (!length || length > 128) return false;
    out.resize(length);
    return readBytes(source, out.data(), length);
}

struct NativeColor {
    int32_t spec = 1;
    uint16_t alpha = 0xffff, red = 0, green = 0, blue = 0, padding = 0;
};
static_assert(sizeof(NativeColor) == 16);
NativeColor colorFromRGB(uint32_t rgb) {
    NativeColor value;
    value.red = ((rgb >> 16) & 255) * 257;
    value.green = ((rgb >> 8) & 255) * 257;
    value.blue = (rgb & 255) * 257;
    return value;
}
// Keep the bubble's hue while giving the small timestamp enough contrast on the chat background.
bool darkAppearance() {
    return [[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
}
uint32_t colorForMessage(uintptr_t data) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    const bool dark = darkAppearance();
    NSString *hex = [defaults stringForKey:YMMessageTimestampColorKey] ?: @"#8F98A8";
    unsigned value = 0;
    if (hex.length == 7 && [hex hasPrefix:@"#"] &&
        [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&value]) return value;
    return dark ? 0xA6AEBB : 0x647083;
}

void formatTimestamp(uint32_t epoch, NSString **first, NSString **second) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:epoch];
    static NSDateFormatter *full, *clock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        full = [NSDateFormatter new]; full.dateFormat = @"yyyy/MM/dd";
        clock = [NSDateFormatter new]; clock.dateFormat = @"HH:mm";
    });
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger format = [defaults integerForKey:YMMessageTimestampFormatKey];
    *second = [clock stringFromDate:date];
    if (format == 2) { *first = nil; return; }
    if (format == 0) {
        NSCalendar *calendar = NSCalendar.currentCalendar;
        NSDate *today = [calendar startOfDayForDate:NSDate.date];
        NSDate *day = [calendar startOfDayForDate:date];
        NSInteger difference = [calendar components:NSCalendarUnitDay fromDate:day toDate:today options:0].day;
        if (difference == 0) { *first = @"今天"; return; }
        if (difference == 1) { *first = @"昨天"; return; }
        if (difference == 2) { *first = @"前天"; return; }
    }
    *first = [full stringFromDate:date];
}

void drawLine(void *painter, NSString *line, int left, int top, int width, int height, double scale) {
    if (!line.length) return;
    const char *utf8 = line.UTF8String;
    const int length = (int)strlen(utf8);
    uintptr_t string = ((uintptr_t (*)(const char *, int))YMRuntimeAddress(native->qStringUTF8))(utf8, length);
    if (!string) return;
    const int rect[4] = {(int)std::floor(left / scale), (int)std::floor(top / scale),
        (int)std::ceil((left + width - 1) / scale), (int)std::ceil((top + height - 1) / scale)};
    ((void (*)(void *, const int *, int, const uintptr_t *, void *))YMRuntimeAddress(native->painterDrawText))
        (painter, rect, 0x84, &string, nullptr); // Qt::AlignHCenter | Qt::AlignVCenter
    ((void (*)(void *))YMRuntimeAddress(native->qStringDestruct))(&string);
}

uintptr_t qobjectParent(uintptr_t object) {
    uintptr_t data = 0, parent = 0;
    if (!read(object + 8, data) || !data || !read(data + 0x10, parent)) return 0;
    return parent;
}

NSMutableDictionary<NSValue *, YMRoleBadgeLiveCaption *> *badgeOverlays() {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary new]; });
    return map;
}

NSMutableDictionary<NSValue *, YMRoleBadgeJob *> *badgeJobs() {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary new]; });
    return map;
}

BOOL badgeFrameOpen = NO;
BOOL badgeClearAll = NO;
BOOL badgeTabSuspended = NO;
uintptr_t badgeSuspendWidget = 0;
std::string badgeSession;
constexpr NSUInteger kBadgeListRefreshPainted = 4; // 划过进出 1–2 格；≥4 才当整屏刷新

NSMutableSet<NSValue *> *badgePaintedKeys() {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet new]; });
    return set;
}
NSTimer *badgeFollowTimer = nil;
id badgeScrollMonitor = nil;
id badgeWindowObserver = nil;
uint64_t badgeGeometrySyncUntil = 0;
BOOL badgeFollowQueued = NO;
BOOL badgeRefreshing = NO;
BOOL badgeHostHooked = NO;
void (*origQNSViewViewWillDraw)(NSView *, SEL) = nullptr;

uint64_t badgeNow() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void startBadgeFollow();
void stopBadgeFollow();
void refreshBadgeFrames(bool allowAttach = true);

struct BadgeNoAnimation {
    BadgeNoAnimation() {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [NSAnimationContext beginGrouping];
        NSAnimationContext.currentContext.duration = 0;
        NSAnimationContext.currentContext.allowsImplicitAnimation = NO;
    }
    ~BadgeNoAnimation() {
        [NSAnimationContext endGrouping];
        [CATransaction commit];
    }
};

NSView *findNativeView(uintptr_t ident, NSView *root, unsigned depth) {
    if (!root || !ident || depth > 32) return nil;
    if ((uintptr_t)(__bridge void *)root == ident) return root;
    for (NSView *child in root.subviews) {
        NSView *found = findNativeView(ident, child, depth + 1);
        if (found) return found;
    }
    return nil;
}

NSView *findNativeView(uintptr_t ident) {
    if (!ident) return nil;
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible || window.miniaturized) continue;
        NSView *found = findNativeView(ident, window.contentView, 0);
        if (found) return found;
    }
    return nil;
}

bool mapCaptionToHost(uintptr_t widget, int x, int y, int width, int height,
                      NSView **hostOut, NSRect *frameOut) {
    if (!widget || width < 1 || height < 1 || !hostOut || !frameOut) return false;
    NSRect caption = NSMakeRect(x, y, width, height);
    NSRect cell = NSZeroRect;
    NSRect clip = NSZeroRect;
    bool haveClip = false;
    uintptr_t child = 0;
    // QWidgetData+0 是原生 WId。depth>0 时格子若已滚出祖先，映射失败。
    // 时戳画在格子里，格子 clip 裁住；上方角标格子裁不到，须整段落在列表祖先框内，
    // 否则会画到群名/会话列表上。左右自己发的消息同一套。
    // 右侧群资料是聊天页后出现的同级抽屉，祖先 clip 看不到；YMChatPaneDrawerClip
    // 与语音气泡、会话标识同一套，盖住则不挂。
    for (int depth = 0; widget && depth < 32; ++depth) {
        uintptr_t data = 0, native = 0;
        if (!read(widget + 0x28, data) || !data || !read(data, native)) return false;
        Rect rect;
        if (!widgetRect(widget, rect)) return false;
        const NSRect bounds = NSMakeRect(0, 0, rect.width, rect.height);
        if (depth == 0) cell = bounds;
        if (depth > 0) {
            if (!NSIntersectsRect(cell, bounds)) return false;
            NSRect allowed = NSZeroRect;
            BOOL hasDrawer = NO;
            if (child && YMChatPaneDrawerClip(widget, child, bounds, &allowed, &hasDrawer)
                && hasDrawer) {
                clip = haveClip ? NSIntersectionRect(clip, allowed) : allowed;
                haveClip = true;
                if (!NSContainsRect(clip, caption)) return false;
            }
            if (rect.height >= cell.size.height + caption.size.height &&
                rect.height > cell.size.height + 8) {
                clip = haveClip ? NSIntersectionRect(clip, bounds) : bounds;
                haveClip = true;
                if (!NSContainsRect(clip, caption)) return false;
            }
        }
        if (native && haveClip) {
            NSView *host = findNativeView(native);
            if (!host) return false;
            NSRect frame = caption;
            if (!host.isFlipped)
                frame.origin.y = NSHeight(host.bounds) - caption.origin.y - caption.size.height;
            *hostOut = host;
            *frameOut = frame;
            return true;
        }
        caption = NSOffsetRect(caption, rect.x, rect.y);
        cell = NSOffsetRect(cell, rect.x, rect.y);
        if (haveClip) clip = NSOffsetRect(clip, rect.x, rect.y);
        child = widget;
        widget = qobjectParent(widget);
    }
    return false;
}

void hideBadgeOverlay(void *widget) {
    if (!widget) return;
    NSValue *key = [NSValue valueWithPointer:widget];
    [badgeJobs() removeObjectForKey:key];
    badgeOverlays()[key].hidden = YES;
}

void clearBadgeOverlays() {
    for (YMRoleBadgeLiveCaption *view in badgeOverlays().allValues) [view removeFromSuperview];
    [badgeOverlays() removeAllObjects];
    [badgeJobs() removeAllObjects];
    stopBadgeFollow();
}

NSColor *badgeNSColor(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                               green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0
                               alpha:1];
}

void applyBadgeJob(YMRoleBadgeJob *job, bool allowAttach = true) {
    if (badgeTabSuspended || !job.widget || !job.host || !job.line.length) return;
    NSValue *key = [NSValue valueWithPointer:job.widget];
    YMRoleBadgeLiveCaption *view = badgeOverlays()[key];
    if (!view) {
        if (!allowAttach) return;
        view = [[YMRoleBadgeLiveCaption alloc] initWithFrame:job.frame];
        view.wantsLayer = YES;
        // 关掉 position/bounds 隐式动画，否则滚动时字拖在格子后面。
        view.layer.actions = @{
            @"position": NSNull.null,
            @"bounds": NSNull.null,
            @"hidden": NSNull.null,
            @"onOrderIn": NSNull.null,
            @"onOrderOut": NSNull.null
        };
        badgeOverlays()[key] = view;
    }
    BadgeNoAnimation noAnimation;
    if (view.superview != job.host) {
        if (!allowAttach) return;
        [view removeFromSuperview];
        [job.host addSubview:view];
    }
    if (!NSEqualRects(view.frame, job.frame)) view.frame = job.frame;
    view.text = job.line;
    view.font = [NSFont systemFontOfSize:job.fontSize weight:NSFontWeightMedium];
    view.textColor = badgeNSColor(job.rgb);
    view.hidden = NO;
    startBadgeFollow();
}

bool syncBadgeOverlay(void *widget);

void flushBadgeJobs() {
    if (badgeTabSuspended) {
        [badgeJobs() removeAllObjects];
        [badgePaintedKeys() removeAllObjects];
        return;
    }
    const NSUInteger paintedCount = badgePaintedKeys().count;
    [badgePaintedKeys() removeAllObjects];
    // 划过一条会重画进出两格；整屏刷新（换会话、滚到最底）才会一次画很多格。
    const bool dropUnpainted = badgeClearAll || paintedCount >= kBadgeListRefreshPainted;
    if (badgeClearAll) {
        badgeClearAll = NO;
        for (YMRoleBadgeLiveCaption *view in badgeOverlays().allValues) [view removeFromSuperview];
        [badgeOverlays() removeAllObjects];
    }
    static BOOL loggedOverlay = NO;
    NSMutableSet<NSValue *> *painted = [NSMutableSet set];
    for (YMRoleBadgeJob *job in badgeJobs().allValues) {
        applyBadgeJob(job);
        [painted addObject:[NSValue valueWithPointer:job.widget]];
        if (!loggedOverlay && job.host) {
            loggedOverlay = YES;
            YMLog(@"[MessageTimestamp] role overlay host=%@ flipped=%d frame=%@",
                  NSStringFromClass(job.host.class), job.host.isFlipped, NSStringFromRect(job.frame));
        }
    }
    [badgeJobs() removeAllObjects];
    NSMutableArray<NSValue *> *stale = [NSMutableArray array];
    [badgeOverlays() enumerateKeysAndObjectsUsingBlock:^(NSValue *key, YMRoleBadgeLiveCaption *view, BOOL *stop) {
        (void)view;
        (void)stop;
        if ([painted containsObject:key]) return;
        if (dropUnpainted || !syncBadgeOverlay(key.pointerValue)) [stale addObject:key];
    }];
    for (NSValue *key in stale) {
        [badgeOverlays()[key] removeFromSuperview];
        [badgeOverlays() removeObjectForKey:key];
    }
    if (!badgeOverlays().count) stopBadgeFollow();
}

void touchBadgeFrame() {
    if (badgeFrameOpen) return;
    badgeFrameOpen = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        flushBadgeJobs();
        badgeFrameOpen = NO;
    });
}

bool badgeWidgetChainContains(uintptr_t start, uintptr_t target) {
    for (int depth = 0; start && depth < 64; ++depth) {
        if (start == target) return true;
        uintptr_t parent = qobjectParent(start);
        if (!parent || parent == start) return false;
        start = parent;
    }
    return false;
}

// 切到通讯录/收藏/发现时，微信的 QStackedWidget 会隐藏聊天页，聊天页下所有消息格
// 都会收到 QEvent::Hide。角标叠层挂在主窗口级 QNSView 上，不在这棵页面子树里，
// 所以不会跟着消失；这里按 Qt 父链判断被隐藏的控件是消息格的祖先，主动暂停叠层。
// 回到聊天页时 Show 或消息格重新 Paint 都能恢复。
void suspendBadgeForHiddenPage(uintptr_t hidden) {
    if (badgeTabSuspended || !hidden) return;
    if (!badgeOverlays().count && !badgeJobs().count) return;
    bool matched = false;
    for (NSValue *key in badgeOverlays().allKeys) {
        const uintptr_t widget = (uintptr_t)key.pointerValue;
        if (widget != hidden && badgeWidgetChainContains(widget, hidden)) { matched = true; break; }
    }
    if (!matched) return;
    badgeTabSuspended = YES;
    badgeSuspendWidget = hidden;
    [badgeJobs() removeAllObjects];
    for (YMRoleBadgeLiveCaption *view in badgeOverlays().allValues) view.hidden = YES;
    stopBadgeFollow();
    YMLog(@"[MessageTimestamp] role badge pause hiddenPage=%p kept=%lu",
          (void *)hidden, (unsigned long)badgeOverlays().count);
}

void resumeBadgeForShownPage(uintptr_t shown, bool fromPaint) {
    if (!badgeTabSuspended) return;
    // Show 事件只有聊天页本身可信；ShowToParent 会发给祖先控件，不能用来恢复。
    // Paint 只在消息格重画时调用（fromPaint），说明聊天页确实已重新可见。
    if (!fromPaint && shown != badgeSuspendWidget) return;
    badgeTabSuspended = NO;
    badgeSuspendWidget = 0;
    if (!roleBadgeEnabled()) {
        clearBadgeOverlays();
        return;
    }
    for (YMRoleBadgeLiveCaption *view in badgeOverlays().allValues)
        if (view.superview) view.hidden = NO;
    YMLog(@"[MessageTimestamp] role badge resume shownPage=%p kept=%lu",
          (void *)shown, (unsigned long)badgeOverlays().count);
}

void noteBadgeSession(const std::string &session) {
    if (session.empty() || session == badgeSession) return;
    badgeSession = session;
    if (badgeOverlays().count || badgeJobs().count) {
        badgeClearAll = YES;
        touchBadgeFrame();
    }
}

YMRoleBadgeJob *makeBadgeJob(void *widget) {
    if (!roleBadgeEnabled() || !widget || YMGroupRoleBadgePosition() != 0) return nil;
    const uintptr_t data = messageData((uintptr_t)widget);
    if (!data) return nil;
    std::string session, sender;
    if (!nativeString(data + 0x58, session) || session != badgeSession ||
        session.size() < 9 || session.compare(session.size() - 9, 9, "@chatroom") != 0 ||
        !nativeString(data + 0x40, sender)) return nil;
    NSString *identity = YMGroupRoleBadgeIdentity(
        [NSString stringWithUTF8String:session.c_str()],
        [NSString stringWithUTF8String:sender.c_str()]);
    NSArray<NSString *> *lines = YMGroupRoleBadgeLines(YMGroupRoleBadgeCaption(identity));
    if (!lines.count) return nil;
    Rect avatar;
    unsigned visits = 0;
    if (!findAvatar((uintptr_t)widget, 0, 0, 0, avatar, visits)) return nil;
    const int pad = (int)std::lround(YMGroupRoleBadgeCaptionPad);
    const CGFloat fontSize = YMGroupRoleBadgeFontSize();
    const CGFloat gap = YMGroupRoleBadgeGap();
    const int height = (int)std::lround(YMGroupRoleBadgeLineHeight(fontSize));
    const int top = (int)std::lround(YMGroupRoleBadgeCaptionTopQt(
        avatar.y, avatar.height, height, gap, YES));
    const int left = avatar.x - pad;
    const int width = avatar.width + pad * 2;
    NSView *host = nil;
    NSRect frame = NSZeroRect;
    if (!mapCaptionToHost((uintptr_t)widget, left, top, width, height, &host, &frame) || !host)
        return nil;
    YMRoleBadgeJob *job = [YMRoleBadgeJob new];
    job.widget = widget;
    job.host = host;
    job.frame = frame;
    job.line = lines.firstObject;
    job.fontSize = fontSize;
    job.rgb = YMGroupRoleBadgeColorRGB(identity);
    return job;
}

bool syncBadgeOverlay(void *widget) {
    YMRoleBadgeJob *job = makeBadgeJob(widget);
    if (!job) return false;
    applyBadgeJob(job);
    return true;
}

void refreshBadgeFrames(bool allowAttach) {
    if (badgeTabSuspended || badgeRefreshing) return;
    if (!badgeOverlays().count) {
        stopBadgeFollow();
        return;
    }
    badgeRefreshing = YES;
    BadgeNoAnimation noAnimation;
    for (NSValue *key in badgeOverlays().allKeys) {
        YMRoleBadgeJob *job = makeBadgeJob(key.pointerValue);
        if (job) applyBadgeJob(job, allowAttach);
        else hideBadgeOverlay(key.pointerValue);
    }
    badgeRefreshing = NO;
}

void ymQNSViewViewWillDraw(NSView *self, SEL sel) {
    if (origQNSViewViewWillDraw) origQNSViewViewWillDraw(self, sel);
    if (badgeTabSuspended || !badgeOverlays().count) return;
    for (YMRoleBadgeLiveCaption *view in badgeOverlays().allValues) {
        if (view.superview == self) {
            refreshBadgeFrames(false); // 与这一帧 Qt 绘制同一拍；drawRect 里不能 addSubview
            break;
        }
    }
}

void installBadgeHostHook() {
    if (badgeHostHooked) return;
    Class cls = NSClassFromString(@"QNSView");
    if (!cls) return;
    const SEL sel = @selector(viewWillDraw);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    origQNSViewViewWillDraw = (void (*)(NSView *, SEL))method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, sel, (IMP)ymQNSViewViewWillDraw, types)) {
        origQNSViewViewWillDraw = (void (*)(NSView *, SEL))method_setImplementation(
            class_getInstanceMethod(cls, sel), (IMP)ymQNSViewViewWillDraw);
    }
    badgeHostHooked = YES;
    YMLog(@"[MessageTimestamp] role overlay follow viewWillDraw");
}

void queueBadgeFollow() {
    if (badgeFollowQueued) return;
    badgeFollowQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        badgeFollowQueued = NO;
        refreshBadgeFrames();
    });
}

void stopBadgeFollow() {
    [badgeFollowTimer invalidate];
    badgeFollowTimer = nil;
    if (badgeScrollMonitor) {
        [NSEvent removeMonitor:badgeScrollMonitor];
        badgeScrollMonitor = nil;
    }
    if (badgeWindowObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:badgeWindowObserver];
        badgeWindowObserver = nil;
    }
}

void startBadgeFollow() {
    if (badgeTabSuspended) return;
    installBadgeHostHook();
    if (badgeFollowTimer) return;
    YMLog(@"[MessageTimestamp] role overlay follow 60Hz");
    badgeFollowTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES
        block:^(NSTimer *) { refreshBadgeFrames(true); }];
    [NSRunLoop.mainRunLoop addTimer:badgeFollowTimer forMode:NSRunLoopCommonModes];
    if (!badgeScrollMonitor)
        badgeScrollMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
            handler:^NSEvent *(NSEvent *event) {
                badgeGeometrySyncUntil = badgeNow() + 150000000ULL;
                queueBadgeFollow();
                return event;
            }];
    if (!badgeWindowObserver)
        badgeWindowObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSWindowDidUpdateNotification object:nil queue:nil
            usingBlock:^(NSNotification *note) {
                if (badgeNow() > badgeGeometrySyncUntil) return;
                NSWindow *window = note.object;
                for (YMRoleBadgeLiveCaption *view in badgeOverlays().allValues) {
                    if (view.window == window) {
                        refreshBadgeFrames();
                        break;
                    }
                }
            }];
}

void recordBadgeOverlay(void *widget) {
    YMRoleBadgeJob *job = makeBadgeJob(widget);
    if (!job) {
        static int mapFail = 0;
        if (mapFail < 5) {
            ++mapFail;
            YMLog(@"[MessageTimestamp] role overlay map fail widget=%p", widget);
        }
        hideBadgeOverlay(widget);
        return;
    }
    touchBadgeFrame();
    badgeJobs()[[NSValue valueWithPointer:widget]] = job;
}

void paintBadgeLine(void *device, NSString *line, int left, int top, int width, int height,
                    double scale, uint32_t rgb) {
    if (!device || !line.length) return;
    alignas(16) uint8_t painter[16] = {};
    ((void (*)(void *, void *))YMRuntimeAddress(native->painterConstruct))(painter, (uint8_t *)device + 0x10);
    const NativeColor color = colorFromRGB(rgb);
    ((void (*)(void *, const NativeColor *))YMRuntimeAddress(native->painterSetPen))(painter, &color);
    ((void (*)(void *, double, double))YMRuntimeAddress(native->painterScale))(painter, scale, scale);
    drawLine(painter, line, left, top, width, height, scale);
    ((void (*)(void *))YMRuntimeAddress(native->painterDestruct))(painter);
}

int paintRoleBadge(void *widget, uintptr_t data, const Rect &avatar) {
    if (!roleBadgeEnabled()) {
        hideBadgeOverlay(widget);
        return 0;
    }
    std::string session, sender;
    if (!nativeString(data + 0x58, session) || session.size() < 9 ||
        session.compare(session.size() - 9, 9, "@chatroom") != 0 ||
        !nativeString(data + 0x40, sender)) {
        hideBadgeOverlay(widget);
        return 0;
    }
    NSString *identity = YMGroupRoleBadgeIdentity(
        [NSString stringWithUTF8String:session.c_str()],
        [NSString stringWithUTF8String:sender.c_str()]);
    NSArray<NSString *> *lines = YMGroupRoleBadgeLines(YMGroupRoleBadgeCaption(identity));
    if (!lines.count) {
        hideBadgeOverlay(widget);
        return 0;
    }
    NSString *line = lines.firstObject;
    const int pad = (int)std::lround(YMGroupRoleBadgeCaptionPad);
    const CGFloat fontSize = YMGroupRoleBadgeFontSize();
    const CGFloat gap = YMGroupRoleBadgeGap();
    const int height = (int)std::lround(YMGroupRoleBadgeLineHeight(fontSize));
    const bool above = YMGroupRoleBadgePosition() == 0;
    const int top = (int)std::lround(YMGroupRoleBadgeCaptionTopQt(
        avatar.y, avatar.height, height, gap, above));
    const double scale = std::clamp(fontSize / 18.0, 0.40, 0.90);
    const int left = avatar.x - pad;
    const int width = avatar.width + pad * 2;
    const uint32_t rgb = YMGroupRoleBadgeColorRGB(identity);
    if (!above) {
        hideBadgeOverlay(widget);
        if (badgeOverlays().count || badgeJobs().count) {
            badgeClearAll = YES;
            touchBadgeFrame();
        }
        paintBadgeLine(widget, line, left, top, width, height, scale, rgb);
        return height + (int)std::lround(gap);
    }
    recordBadgeOverlay(widget); // 格子 clip 盖不住头像上方；下一圈主队列再挂 NSView
    return 0;
}

void paintTimestamp(void *widget, void *event) {
    const uintptr_t table = *reinterpret_cast<const uintptr_t *>(widget);
    const auto found = originalPaint.find(table);
    if (found != originalPaint.end()) found->second(widget, event);
    const bool showTime = [NSUserDefaults.standardUserDefaults boolForKey:YMMessageTimestampEnabledKey];
    const bool showBadge = roleBadgeEnabled();
    if (!showBadge && (badgeOverlays().count || badgeJobs().count)) {
        badgeClearAll = YES;
        touchBadgeFrame();
    }
    if (!showTime && !showBadge) return;
    const uintptr_t data = messageData((uintptr_t)widget);
    if (!data) return;
    if (showBadge) {
        [badgePaintedKeys() addObject:[NSValue valueWithPointer:widget]];
        std::string session;
        if (nativeString(data + 0x58, session)) noteBadgeSession(session);
        touchBadgeFrame();
    }
    Rect avatar;
    unsigned visits = 0;
    if (!findAvatar((uintptr_t)widget, 0, 0, 0, avatar, visits)) return;
    Rect item;
    if (!widgetRect((uintptr_t)widget, item)) return;
    const int badgeBelow = showBadge ? paintRoleBadge(widget, data, avatar) : 0;
    if (!showTime) return;
    uint32_t epoch = 0;
    if (!read(data + native->timestampOffset, epoch) || epoch < 946684800 || epoch > NSDate.date.timeIntervalSince1970 + 86400) return;
    const int available = item.height - (avatar.y + avatar.height) - badgeBelow;
    if (available < 9) return;
    NSString *first = nil, *second = nil;
    formatTimestamp(epoch, &first, &second);
    alignas(16) uint8_t painter[16] = {};
    ((void (*)(void *, void *))YMRuntimeAddress(native->painterConstruct))(painter, (uint8_t *)widget + 0x10);
    const NativeColor color = colorFromRGB(colorForMessage(data));
    ((void (*)(void *, const NativeColor *))YMRuntimeAddress(native->painterSetPen))(painter, &color);
    // Use the same single-line caption for private and group messages. Row
    // height (including group nicknames/media) must not change the format.
    const bool hasDate = first.length > 0;
    const double scale = hasDate ? (first.length > 4 ? 0.43 : 0.55) : 0.68;
    ((void (*)(void *, double, double))YMRuntimeAddress(native->painterScale))(painter, scale, scale);
    const int left = avatar.x - (hasDate ? 13 : 11);
    const int top = avatar.y + avatar.height + 1 + badgeBelow;
    NSString *caption = hasDate ? [NSString stringWithFormat:@"%@ %@", first, second] : second;
    drawLine(painter, caption, left, top, avatar.width + (hasDate ? 26 : 22),
             std::min(available - 1, hasDate ? 12 : 14), scale);
    ((void (*)(void *))YMRuntimeAddress(native->painterDestruct))(painter);
}

bool hookPaint(uintptr_t widget) {
    // QWidget::event(Paint) dispatches through +0xf0 in 269079 and +0x100 in 270353.
    uintptr_t table = 0, original = 0;
    if (!read(widget, table) || !table || originalPaint.count(table) ||
        !read(table + native->paintSlotOffset, original) || !original) return false;
    const size_t page = (size_t)getpagesize();
    void *base = (void *)( (table + native->paintSlotOffset) & ~(page - 1));
    if (mprotect(base, page, PROT_READ | PROT_WRITE) != 0) return false;
    originalPaint[table] = (Paint)original;
    *reinterpret_cast<uintptr_t *>(table + native->paintSlotOffset) = (uintptr_t)&paintTimestamp;
    mprotect(base, page, PROT_READ);
    return true;
}

bool eventHook(void *widget, void *event) {
    if (widget && event && NSThread.isMainThread) {
        uint16_t type = 0;
        if (read((uintptr_t)event + 0x10, type)) {
            if (type == 12) { // QEvent::Paint
                if ([NSUserDefaults.standardUserDefaults boolForKey:YMMessageTimestampEnabledKey] ||
                    roleBadgeEnabled()) {
                    const bool isMessageCell = messageData((uintptr_t)widget) != 0;
                    if (isMessageCell) hookPaint((uintptr_t)widget);
                    // 聊天页重新可见才会重画消息格，用它作为恢复信号。
                    if (isMessageCell && badgeTabSuspended)
                        resumeBadgeForShownPage((uintptr_t)widget, true);
                }
            } else if (type == 18) { // QEvent::Hide
                if ((badgeOverlays().count || badgeJobs().count) && roleBadgeEnabled())
                    suspendBadgeForHiddenPage((uintptr_t)widget);
            } else if (type == 17) { // QEvent::Show
                if (badgeTabSuspended) resumeBadgeForShownPage((uintptr_t)widget, false);
            }
        }
    }
    return originalEvent ? originalEvent(widget, event) : false;
}

bool matches(uintptr_t address, std::initializer_list<uint8_t> expected, const char *name) {
    if (!address) {
        YMLog(@"[MessageTimestamp] %s 地址为 0", name);
        return false;
    }
    if (std::memcmp((const void *)address, expected.begin(), expected.size()) == 0) return true;
    const uint8_t *bytes = reinterpret_cast<const uint8_t *>(address);
    NSMutableString *got = [NSMutableString string];
    NSMutableString *want = [NSMutableString string];
    for (uint8_t b : expected) {
        if (want.length) [want appendString:@" "];
        [want appendFormat:@"%02x", b];
    }
    for (size_t i = 0; i < expected.size(); ++i) {
        if (got.length) [got appendString:@" "];
        [got appendFormat:@"%02x", bytes[i]];
    }
    YMLog(@"[MessageTimestamp] %s 字节不匹配 want=%@ got=%@", name, want, got);
    return false;
}
} // namespace

void YMInstallMessageTimestamp(void) {
    if (installed) return;
    if (YMMatchesWeChat270353Dylib()) native = &layout270353;
    else return;
    if (!matches(YMRuntimeAddress(native->widgetEvent), {0xff,0x43,0x02,0xd1,0xf8,0x5f,0x05,0xa9,0xf6,0x57,0x06,0xa9,0xf4,0x4f,0x07,0xa9}, "QWidget.event") ||
        !matches(YMRuntimeAddress(native->painterSetPen), {0xff,0x03,0x01,0xd1,0xf4,0x4f,0x02,0xa9}, "QPainter.setPen") ||
        !matches(YMRuntimeAddress(native->painterScale), {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9}, "QPainter.scale") ||
        !matches(YMRuntimeAddress(native->painterDrawText), {0xff,0x83,0x02,0xd1,0xfa,0x67,0x05,0xa9}, "QPainter.drawText") ||
        !matches(YMRuntimeAddress(native->qStringUTF8), {0xff,0xc3,0x00,0xd1,0xf4,0x4f,0x01,0xa9}, "QString.fromUtf8")) return;
    uint8_t trampoline[32] = {};
    std::memcpy(trampoline, (const void *)YMRuntimeAddress(native->widgetEvent), 16);
    const uint32_t load = 0x58000050, jump = 0xd61f0200;
    const uintptr_t continuation = YMRuntimeAddress(native->widgetEvent) + 16;
    std::memcpy(trampoline + 16, &load, 4);
    std::memcpy(trampoline + 20, &jump, 4);
    std::memcpy(trampoline + 24, &continuation, 8);
    void *mapping = mmap(nullptr, sizeof trampoline, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapping == MAP_FAILED) {
        YMLog(@"[MessageTimestamp] trampoline mmap 失败");
        return;
    }
    std::memcpy(mapping, trampoline, sizeof trampoline);
    if (mprotect(mapping, sizeof trampoline, PROT_READ | PROT_EXEC) != 0) {
        YMLog(@"[MessageTimestamp] trampoline mprotect 失败");
        munmap(mapping, sizeof trampoline);
        return;
    }
    sys_icache_invalidate(mapping, sizeof trampoline);
    originalEvent = (Event)mapping;
    installed = YMPatchARM64AbsoluteJump(YMRuntimeAddress(native->widgetEvent), (uintptr_t)&eventHook,
        "message timestamp widget paint");
    if (!installed) {
        originalEvent = nullptr;
        munmap(mapping, sizeof trampoline);
        YMLog(@"[MessageTimestamp] 绘制入口跳转未写入");
    } else YMLog(@"[MessageTimestamp] 原生消息时间绘制已安装");
}
BOOL YMMessageTimestampAvailable(void) { return installed; }
#else
void YMInstallMessageTimestamp(void) {}
BOOL YMMessageTimestampAvailable(void) { return NO; }
#endif

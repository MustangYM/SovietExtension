#import "AppearanceNative.h"
#import "SessionMarkOverlay.h"
#import "SessionMark.h"
#import "ChatPaneClip.h"
#import "RevokePatch.h"
#import "WeChatCompatibility.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach_vm.h>
#include <algorithm>
#include <cstdarg>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <functional>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <vector>

#if defined(__aarch64__)
namespace {

bool installed = false;
bool cellPaintReady = false;
CFAbsoluteTime lastHostMiss = 0;
CFAbsoluteTime lastComposerLog = 0;
CFAbsoluteTime lastDropLog = 0;
CFAbsoluteTime lastStripMiss = 0;
CFAbsoluteTime lastFieldSearchLog = 0;
NSView *sessionListView = nil;
uintptr_t cachedListCell = 0;
uintptr_t freshSelectedCell = 0;
NSString *freshSelectedAccount = nil;
bool selectedMarkedThisTurn = false;
bool selectedFolderThisTurn = false;
NSString *pendingDropSession = nil;
uintptr_t cachedNativeIdent = 0;
NSView *cachedNativeView = nil;
CFAbsoluteTime cachedNativeAt = 0;
struct NativeLayout {
    uintptr_t painterConstruct, painterDestruct, painterFillRectColor;
    uintptr_t textControlPlain, textDocumentPlain, stringDestruct, widgetUpdate;
    uintptr_t fieldSession, fieldControl, headTable, headSession;
    uint8_t textControlBytes[12];
};
constexpr NativeLayout layout270353 = {
    0x6f9f5b8, 0x6f9fe34, 0x6fac96c, 0x6cab2d8, 0x6e90c38, 0xadba4, 0x6b63e94,
    0x280, 0x280, 0x9cca4b8, 0x260,
    {0x09,0x04,0x40,0xf9,0x20,0x2d,0x40,0xf9,0x56,0x96,0x07,0x14}
};
const NativeLayout *native = nullptr;
// 两版 ChatSessionCell 的 setSelected/style 都写读 +0x1f0。
// 已着色选中跳过绿底、与未选中同一浅罩，再画四角「」，不加深。未标记选中走原生绿底。
// 两版会话行 paintEvent 多种格子共用；色罩只画主聊天窗里宽度落在会话列表列的格子。
// 宿主：标题「微信」，或无标题窗与「微信」重叠至少一格（宽≥160、高≥32）。
// QWidgetData+0 经常不是带窗的 NSView：按指针在 NSApp.windows 里找，跳过空框/过小窗，向上走 64 层。
// 仍没有可用窗时，顶层 Qt 尺寸对上「微信」窗才算。聊天记录 / 红包 / 会话标识工具窗不画。
// 641×702 无标题聊天窗会比「微信」窗多出一截，整框包含过不去，按重叠判定。输入条可能在两层下沿，都要扫。
// 输入叠层贴 ChatInputField 灰线（会话字段按版本读取）；拉高铺到外卡顶、停在工具栏上方。带会话号的输入栏高 24–1200，不算消息列表。
// 聊天页子树里贴顶的消息列表（含挤矮后的短消息区）不是输入面，不走进列表子树。
// 输入叠层只在会话列表里当前选中格为已着色时画。发现页、公众号文件夹、未标记选中即拆。
// 聊天记录滚动不重扫发现页和会话列表；选中变化立即重算。输入栏矩形和抽屉宽度没变则不重贴图层。
// 公众号文件夹 brandsessionholder 不加进标识组、不铺列表色罩；格子和直接子级扫文件夹号。
// 空草稿：输入框私有 control 字段按版本读取，control.d_ptr+0x58 在两版都指向文档。
// 读到非空才藏占位符和色罩；找不到输入栏或读失败仍当空。Qt 可见位为 0 仍可贴。
// 右侧群资料：YMChatPaneDrawerClip 同级抽屉，宽≥48 起裁，每帧跟打开动画。查找从输入条/根走。
constexpr uintptr_t kCellSelectedFlag = 0x1F0;
constexpr uint8_t kTextDocumentPlainBytes[] = {
    0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91,
    0xf3, 0x03, 0x08, 0xaa, 0x00, 0x04, 0x40, 0xf9
};
constexpr uint8_t kQStringDestructBytes[] = {
    0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91,
    0xe8, 0x03, 0x00, 0xaa
};
constexpr uint8_t kWidgetUpdateBytes[] = {
    0x08,0x14,0x40,0xf9,0x09,0xa9,0x43,0x29,0x0b,0xa1,0x42,0x29,
    0x29,0x01,0x0b,0x4b,0x48,0x01,0x08,0x4b,0x22,0x81,0x08,0xaa,
    0x00,0x04,0x40,0xf9,0x01,0x00,0x80,0xd2,0x81,0x50,0x00,0x14
};
bool readBytes(uintptr_t address, void *out, size_t size) {
    mach_vm_size_t copied = 0;
    return address && size && address <= std::numeric_limits<uintptr_t>::max() - size &&
        mach_vm_read_overwrite(mach_task_self(), address, size,
            reinterpret_cast<mach_vm_address_t>(out), &copied) == KERN_SUCCESS && copied == size;
}
template <class T> bool read(uintptr_t address, T &out) { return readBytes(address, &out, sizeof out); }

bool nativeString(uintptr_t address, std::string &out, size_t maxLength) {
    uint8_t raw[24] = {};
    if (!readBytes(address, raw, sizeof raw)) return false;
    uintptr_t source = address;
    size_t length = raw[23];
    if (raw[23] & 0x80) {
        std::memcpy(&source, raw, 8);
        std::memcpy(&length, raw + 8, 8);
    } else if (length > 22) return false;
    if (!length || length > maxLength) return false;
    out.resize(length);
    return readBytes(source, out.data(), length);
}

// 这份 wechat.dylib 的 QObject：[0] 析构，[1] metaObject，[2] qt_metacast，[3] qt_metacall。
// [1] 忽略额外参数且对任意 QObject 都非空，按类型名分流会恒真。
// [3] 是 qt_metacall，按 (object, className) 调用会在 0x8 空读崩掉。
// 会话 ID、输入框、主窗口一律不按 qt_metacast 选类型。

uintptr_t parentWidget(uintptr_t widget) {
    // QObject d_ptr +8，QObjectData::parent +0x10。
    uintptr_t priv = 0, parent = 0;
    if (!read(widget + 8, priv) || !priv || !read(priv + 0x10, parent)) return 0;
    return parent;
}

bool widgetChildren(uintptr_t widget, std::vector<uintptr_t> &children) {
    // QWidgetPrivate 子女：priv+0x18 header，begin/end 在 +8/+0xc，元素在 header+0x10。
    uintptr_t priv = 0, header = 0;
    int32_t begin = 0, end = 0;
    if (!read(widget + 8, priv) || !priv || !read(priv + 0x18, header) || !header ||
        !read(header + 8, begin) || !read(header + 12, end) ||
        begin < 0 || end < begin || end - begin > 256) return false;
    children.resize(end - begin);
    return children.empty() || readBytes(header + 16 + uintptr_t(begin) * 8,
        children.data(), children.size() * sizeof(uintptr_t));
}

struct Rect { int x = 0, y = 0, width = 0, height = 0; };
bool widgetRect(uintptr_t object, Rect &out) {
    // QWidget +0x28 → QWidgetData，+0x14 为 x0,y0,x1,y1 闭区间。
    uintptr_t data = 0;
    int bounds[4] = {};
    if (!read(object + 0x28, data) || !data || !readBytes(data + 0x14, bounds, sizeof bounds)) return false;
    out = {bounds[0], bounds[1], bounds[2] - bounds[0] + 1, bounds[3] - bounds[1] + 1};
    return out.width > 0 && out.height > 0 && out.width < 10000 && out.height < 10000;
}

bool widgetVisible(uintptr_t widget) {
    // QWidgetData+8 标志位 0x8000 为可见。
    uintptr_t data = 0;
    uint32_t flags = 0;
    return read(widget + 0x28, data) && data && read(data + 8, flags) && (flags & 0x8000);
}

NSString *nsString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
}

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
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (ident == cachedNativeIdent && now - cachedNativeAt < 1.0) {
        @try { return cachedNativeView; } @catch (NSException *) {}
    }
    NSView *found = nil;
    for (NSWindow *window in NSApp.windows) {
        if (window.miniaturized) continue;
        NSView *root = window.contentView;
        if (!root) continue;
        while (root.superview) root = root.superview;
        found = findNativeView(ident, root, 0);
        if (found) break;
    }
    cachedNativeIdent = ident;
    cachedNativeView = found;
    cachedNativeAt = now;
    return found;
}

NSView *viewFromNativeIdent(uintptr_t native) {
    if (!native) return nil;
    if (NSView *found = findNativeView(native)) return found;
    NSView *view = (__bridge NSView *)(void *)native;
    @try {
        if ([view isKindOfClass:NSView.class]) return view;
    } @catch (NSException *) {}
    return nil;
}

bool hostWindowLooksUsable(NSWindow *window) {
    if (!window || window.miniaturized) return false;
    return NSWidth(window.frame) >= YMSessionMarkSessionListCellMinWidth
        && NSHeight(window.frame) >= YMSessionMarkSessionListCellMinHeight;
}

Rect qtOuterRect(uintptr_t widget) {
    Rect best = {};
    uintptr_t current = widget;
    for (int depth = 0; current && depth < 64; ++depth) {
        Rect rect;
        if (widgetRect(current, rect) &&
            (CGFloat)rect.width * rect.height > (CGFloat)best.width * best.height)
            best = rect;
        current = parentWidget(current);
    }
    return best;
}

uintptr_t widgetNative(uintptr_t widget) {
    uintptr_t data = 0, native = 0;
    if (!widget || !read(widget + 0x28, data) || !data || !read(data, native)) return 0;
    return native;
}

bool mapSelf(uintptr_t widget, NSView **hostOut, NSRect *frameOut) {
    Rect local;
    if (!widget || !hostOut || !frameOut || !widgetRect(widget, local)) return false;
    NSRect frame = NSMakeRect(0, 0, local.width, local.height);
    uintptr_t current = widget;
    uintptr_t lastNative = 0;
    NSRect lastFrame = frame;
    for (int depth = 0; current && depth < 32; ++depth) {
        Rect rect;
        const bool haveRect = widgetRect(current, rect);
        uintptr_t native = widgetNative(current);
        uintptr_t parent = parentWidget(current);
        if (native) {
            lastNative = native;
            lastFrame = frame;
        }
        if (native && (!parent || native != widgetNative(parent))) {
            if (NSView *host = findNativeView(native)) {
                if (!host.isFlipped)
                    frame.origin.y = NSHeight(host.bounds) - frame.origin.y - frame.size.height;
                *hostOut = host;
                *frameOut = frame;
                return true;
            }
        }
        if (haveRect) {
            frame.origin.x += rect.x;
            frame.origin.y += rect.y;
        }
        current = parent;
    }
    if (lastNative) {
        if (NSView *host = findNativeView(lastNative)) {
            if (!host.isFlipped)
                lastFrame.origin.y = NSHeight(host.bounds) - lastFrame.origin.y - lastFrame.size.height;
            *hostOut = host;
            *frameOut = lastFrame;
            return true;
        }
    }
    return false;
}

NSString *acceptedSession(NSString *raw) {
    NSString *value = YMSessionMarkCanonicalSession(raw);
    return YMSessionMarkAcceptsSession(value, YMAppearanceAccount()) ? value : nil;
}

NSString *identitySession(NSString *raw) {
    NSString *value = YMSessionMarkCanonicalSession(raw);
    return YMSessionMarkIsSessionId(value) ? value : nil;
}

NSString *sessionFromHead(uintptr_t head, bool acceptedOnly);

bool fieldSession(uintptr_t object, NSString **sessionOut) {
    // 新版输入框用长度为 32 位的字节串，复用艾特功能已验证的读取方式。
    if (!object || !native) return false;
    std::string text;
    const bool valid = native == &layout270353
        ? YMReadAppearanceSession(object + native->fieldSession, text)
        : nativeString(object + native->fieldSession, text, 128);
    if (!valid) return false;
    NSString *value = identitySession(nsString(text));
    if (!value.length) return false;
    if (sessionOut) *sessionOut = value;
    return true;
}

NSString *sessionFromField(uintptr_t field) {
    NSString *session = nil;
    return fieldSession(field, &session) ? session : sessionFromHead(field, false);
}

// ContactHeadView::UserName 两版都是 string*；先确认主虚表，不能当内嵌字符串读取。
// 其它旧版容器保留唯一会话号查找，不调用未确认的 qt_metacast。
NSString *sessionFromHead(uintptr_t head, bool acceptedOnly) {
    if (!head || !native) return nil;
    uintptr_t table = 0, string = 0;
    if (read(head, table) && table == YMRuntimeAddress(native->headTable)) {
        std::string text;
        if (!read(head + native->headSession, string) ||
            !nativeString(string, text, 128)) return nil;
        return acceptedOnly ? acceptedSession(nsString(text)) : identitySession(nsString(text));
    }
    NSString *found = nil;
    for (uintptr_t offset = 0x30; offset <= 0x280; offset += 8) {
        std::string text;
        if (!nativeString(head + offset, text, 128)) continue;
        NSString *value = acceptedOnly ? acceptedSession(nsString(text))
                                      : identitySession(nsString(text));
        if (!value.length) continue;
        if (found && ![found isEqual:value]) return nil;
        found = value;
    }
    return found;
}

NSString *sessionFromHeadTree(uintptr_t start, unsigned depth, bool acceptedOnly) {
    if (!start || depth > 4) return nil;
    if (NSString *found = sessionFromHead(start, acceptedOnly)) return found;
    std::vector<uintptr_t> kids;
    if (!widgetChildren(start, kids)) return nil;
    for (uintptr_t child : kids) {
        if (!child) continue;
        if (NSString *found = sessionFromHeadTree(child, depth + 1, acceptedOnly)) return found;
    }
    return nil;
}

bool objectHasFolderHolder(uintptr_t object) {
    if (!object) return false;
    uintptr_t table = 0;
    if (native && read(object, table) && table == YMRuntimeAddress(native->headTable))
        return YMSessionMarkSessionIsFolderHolder(sessionFromHead(object, false));
    for (uintptr_t offset = 0x30; offset <= 0x280; offset += 8) {
        std::string text;
        if (!nativeString(object + offset, text, 128)) continue;
        if (YMSessionMarkSessionIsFolderHolder(identitySession(nsString(text)))) return true;
    }
    return false;
}

bool cellLooksLikeFolderHolder(uintptr_t cell) {
    if (objectHasFolderHolder(cell)) return true;
    std::vector<uintptr_t> kids;
    if (!widgetChildren(cell, kids)) return false;
    unsigned n = 0;
    for (uintptr_t child : kids) {
        if (!child) continue;
        if (objectHasFolderHolder(child)) return true;
        if (++n >= 16) break;
    }
    return false;
}

NSString *sessionFromCell(uintptr_t cell) {
    // 公众号文件夹号在格子或直接子级上；有则本格不着色。
    if (cellLooksLikeFolderHolder(cell)) return nil;
    NSString *identity = sessionFromHeadTree(cell, 0, false);
    if (YMSessionMarkSessionIsFolderHolder(identity)) return nil;
    return acceptedSession(identity) ? identity : sessionFromHeadTree(cell, 0, true);
}

bool composerSized(uintptr_t object) {
    Rect rect;
    return widgetRect(object, rect) && rect.width >= 160
        && YMSessionMarkComposerOverlaySized(rect.width, rect.height);
}

CGFloat sessionListColumnWidth(void) {
    if (!sessionListView) return 0;
    @try { return NSWidth(sessionListView.bounds); }
    @catch (NSException *) { return 0; }
}

bool looksLikeSessionListColumn(CGFloat width, CGFloat height) {
    if (height < 200 || width < YMSessionMarkSessionListCellMinWidth) return false;
    const CGFloat listW = sessionListColumnWidth();
    if (listW < YMSessionMarkSessionListCellMinWidth) return false;
    return std::fabs(width - listW) <= 8 && height >= width * 2.0;
}

bool inComposerStrip(uintptr_t object);
uintptr_t innerTypingField(uintptr_t chrome);
NSView *innerComposerField(NSView *strip);
bool composerHasMessageListChild(uintptr_t parent);
bool composerOnMessageList(uintptr_t widget);
bool wrapsTypingField(NSRect outer, NSRect inner);

bool geometryComposerCandidate(uintptr_t widget) {
    Rect rect;
    if (!widget || !widgetRect(widget, rect)) return false;
    if (!YMSessionMarkComposerStripTypingSized(rect.width, rect.height)) return false;
    if (composerHasMessageListChild(widget) || composerOnMessageList(widget)) return false;
    if (innerTypingField(widget)) return false;
    const CGFloat listW = sessionListColumnWidth();
    if (listW >= YMSessionMarkSessionListCellMinWidth) {
        if (rect.width <= listW + 8) return false;
    } else if (rect.height <= 72 && rect.width <= YMSessionMarkSessionListCellMaxWidth) {
        return false;
    }
    return inComposerStrip(widget);
}

CGFloat windowMinY(uintptr_t object) {
    NSView *host = nil;
    NSRect frame = NSZeroRect;
    if (!mapSelf(object, &host, &frame) || !host.window) return 9999;
    @try { return NSMinY([host convertRect:frame toView:nil]); }
    @catch (NSException *) { return 9999; }
}

bool inComposerStrip(uintptr_t object) {
    if (!composerSized(object)) return false;
    NSView *host = nil;
    NSRect frame = NSZeroRect;
    if (!mapSelf(object, &host, &frame) || !host.window) return false;
    @try {
        NSRect win = [host convertRect:frame toView:nil];
        NSRect screen = [host.window convertRectToScreen:win];
        if (YMSessionMarkComposerNearWindowTop(screen, host.window.frame)) return false;
        if (YMSessionMarkComposerStripBand(win, NSHeight(host.window.frame))
            || YMSessionMarkComposerNearWindowBottom(screen, host.window.frame))
            return true;
        if (!fieldSession(object, nullptr)) return false;
        return YMSessionMarkComposerBottomAnchored(win, NSHeight(host.window.frame))
            || YMSessionMarkComposerNearWindowBottomAnchored(screen, host.window.frame);
    } @catch (NSException *) {
        return false;
    }
}

bool mayContainComposer(const Rect &rect) {
    if (rect.width < YMSessionMarkComposerFieldMinWidth || rect.height < 24) return false;
    // 整块等于会话列表列宽的高列才跳过。聊天列被拉窄时也会变成竖长，不能按 ≤400 一刀切。
    if (looksLikeSessionListColumn(rect.width, rect.height)) return false;
    return true;
}

bool looksLikeQWidget(uintptr_t object) {
    if (!object) return false;
    uintptr_t table = 0, data = 0;
    if (!read(object, table) || !table || !read(object + 0x28, data) || !data) return false;
    Dl_info info = {};
    if (!dladdr(reinterpret_cast<const void *>(table), &info) || !info.dli_fname ||
        !std::strstr(info.dli_fname, "wechat.dylib")) return false;
    Rect rect;
    return widgetRect(object, rect);
}

bool cellNativeSelected(uintptr_t widget) {
    uint8_t flag = 0;
    return widget && read(widget + kCellSelectedFlag, flag) && flag == 1;
}

std::map<uintptr_t, uintptr_t> nativeOwner;

void rememberNative(uintptr_t widget) {
    const uintptr_t native = widgetNative(widget);
    Rect rect;
    if (!native || !widgetRect(widget, rect)) return;
    NSView *view = (__bridge NSView *)(void *)native;
    @try {
        if (![view isKindOfClass:NSView.class] || !view.window) return;
        if (std::fabs(rect.width - NSWidth(view.bounds)) <= 8 &&
            std::fabs(rect.height - NSHeight(view.bounds)) <= 8) {
            nativeOwner[native] = widget;
        }
    } @catch (NSException *) {}
}

void clearNativeOwner(void) { nativeOwner.clear(); }
uintptr_t widgetFromNativeView(NSView *view);

uintptr_t wideAncestor(uintptr_t widget) {
    // 这份 wechat.dylib 的 isA(MainWindow) 恒真，不能当停点。
    // 消息列表会够「宽」，停在那里就走不到旁边的输入框。聊天列被拉窄时没有 400 宽。
    uintptr_t bestWide = 0;
    CGFloat bestWideArea = 0;
    uintptr_t bestAny = 0;
    CGFloat bestAnyArea = 0;
    uintptr_t current = widget;
    for (int depth = 0; current && depth < 32; ++depth) {
        Rect rect;
        if (widgetRect(current, rect) && rect.height >= 200 &&
            !looksLikeSessionListColumn(rect.width, rect.height)) {
            const CGFloat area = (CGFloat)rect.width * (CGFloat)rect.height;
            if (rect.width >= 400 && area > bestWideArea) {
                bestWide = current;
                bestWideArea = area;
            }
            if (rect.width >= YMSessionMarkComposerFieldMinWidth && area > bestAnyArea) {
                bestAny = current;
                bestAnyArea = area;
            }
        }
        current = parentWidget(current);
    }
    return bestWide ? bestWide : bestAny;
}

uintptr_t treeRootFrom(uintptr_t widget) {
    if (!widget) widget = cachedListCell;
    if (!widget) return 0;
    uintptr_t best = 0;
    CGFloat bestArea = 0;
    uintptr_t current = widget;
    for (int depth = 0; current && depth < 32; ++depth) {
        Rect rect;
        if (widgetRect(current, rect) && rect.width >= 400 && rect.height >= 200) {
            const CGFloat area = (CGFloat)rect.width * (CGFloat)rect.height;
            if (area > bestArea) {
                best = current;
                bestArea = area;
            }
        }
        current = parentWidget(current);
    }
    return best ? best : wideAncestor(widget);
}

bool isChatMainTitle(NSString *title) {
    return YMSessionMarkWindowTitleIsMain(title);
}

bool isUtilityChatTitle(NSString *title) {
    return YMSessionMarkWindowTitleIsUtility(title);
}

NSWindow *mainChatWindow(void);

bool windowInsideUtility(NSWindow *window) {
    if (!window) return false;
    if (YMSessionMarkWindowTitleIsUtility(window.title)) return true;
    NSWindow *parent = window.parentWindow;
    return parent && YMSessionMarkWindowTitleIsUtility(parent.title);
}

NSView *widgetNativeView(uintptr_t widget) {
    uintptr_t current = widget;
    for (int depth = 0; current && depth < 64; ++depth) {
        NSView *view = viewFromNativeIdent(widgetNative(current));
        if (view && hostWindowLooksUsable(view.window)) return view;
        current = parentWidget(current);
    }
    return nil;
}

NSWindow *widgetWindow(uintptr_t widget) {
    NSView *view = widgetNativeView(widget);
    return view.window;
}

bool windowAttachedToMain(NSWindow *window, NSWindow *main) {
    if (!window || !main) return false;
    if (window == main || window.parentWindow == main) return true;
    for (NSWindow *child in main.childWindows) {
        if (child == window) return true;
    }
    for (NSWindow *parent = window.parentWindow; parent; parent = parent.parentWindow) {
        if (parent == main) return true;
    }
    return false;
}

bool inMainChatWindow(uintptr_t widget) {
    NSView *view = widgetNativeView(widget);
    NSWindow *window = view.window;
    const bool insideUtility = windowInsideUtility(window);
    if (window && YMSessionMarkWindowTitleIsMain(window.title))
        return YMSessionMarkWindowHostsSessionChrome(window.title, YES, insideUtility);
    NSWindow *main = mainChatWindow();
    bool insideMain = windowAttachedToMain(window, main);
    if (!insideMain && main && view && window) {
        NSRect screen = [window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
        insideMain = YMSessionMarkWindowFrameOverlapsMain(screen, main.frame);
    }
    if (!insideMain && main && window)
        insideMain = YMSessionMarkWindowFrameOverlapsMain(window.frame, main.frame);
    if (!insideMain && main && !hostWindowLooksUsable(window)) {
        const Rect outer = qtOuterRect(widget);
        insideMain = YMSessionMarkWindowSizeMatchesMain(
            outer.width, outer.height, NSWidth(main.frame), NSHeight(main.frame));
    }
    return YMSessionMarkWindowHostsSessionChrome(window.title, insideMain, insideUtility);
}

bool sessionListCell(uintptr_t widget) {
    Rect item;
    if (!widgetRect(widget, item) ||
        !YMSessionMarkSessionListCellSized(item.width, item.height))
        return false;
    return inMainChatWindow(widget);
}

void logHostMiss(uintptr_t widget, const Rect &item) {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastHostMiss < 2.0) return;
    lastHostMiss = now;
    NSView *view = widgetNativeView(widget);
    NSWindow *window = view.window;
    NSWindow *main = mainChatWindow();
    NSRect screen = NSZeroRect;
    NSRect winFrame = window ? window.frame : NSZeroRect;
    NSRect mainFrame = main ? main.frame : NSZeroRect;
    if (window && view) {
        @try {
            screen = [window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
        } @catch (NSException *) {}
    }
    const Rect outer = qtOuterRect(widget);
    YMLog(@"[SessionMark] skip host size=%.0fx%.0f outer=%.0fx%.0f native=%p view=%@ title=%@ parent=%@ win=%.0f,%.0f %.0fx%.0f view=%.0f,%.0f %.0fx%.0f main=%.0f,%.0f %.0fx%.0f enabled=%d",
        (CGFloat)item.width, (CGFloat)item.height,
        (CGFloat)outer.width, (CGFloat)outer.height,
        (void *)widgetNative(widget), view ? NSStringFromClass(view.class) : @"",
        window.title.length ? window.title : @"",
        window.parentWindow.title.length ? window.parentWindow.title : @"",
        winFrame.origin.x, winFrame.origin.y, NSWidth(winFrame), NSHeight(winFrame),
        screen.origin.x, screen.origin.y, NSWidth(screen), NSHeight(screen),
        mainFrame.origin.x, mainFrame.origin.y, NSWidth(mainFrame), NSHeight(mainFrame),
        (int)YMSessionMarkEnabled());
}

NSWindow *mainChatWindow(void) {
    // 输入叠层和标题栏只认「微信」窗。聊天记录、图片/视频预览等大窗不能顶替。
    NSWindow *named = nil;
    CGFloat namedArea = 0;
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible || window.miniaturized) continue;
        const CGFloat width = NSWidth(window.frame);
        const CGFloat height = NSHeight(window.frame);
        if (width < 600 || height < 400) continue;
        NSString *title = window.title ?: @"";
        if (isUtilityChatTitle(title) || !isChatMainTitle(title)) continue;
        const CGFloat area = width * height;
        if (area > namedArea) {
            named = window;
            namedArea = area;
        }
    }
    return named;
}

bool hostWindowIsMainChat(NSWindow *window) {
    if (!window) return false;
    const bool insideUtility = windowInsideUtility(window);
    if (YMSessionMarkWindowTitleIsMain(window.title))
        return YMSessionMarkWindowHostsSessionChrome(window.title, YES, insideUtility);
    NSWindow *main = mainChatWindow();
    bool insideMain = windowAttachedToMain(window, main);
    if (!insideMain && main)
        insideMain = YMSessionMarkWindowFrameOverlapsMain(window.frame, main.frame);
    return YMSessionMarkWindowHostsSessionChrome(window.title, insideMain, insideUtility);
}

NSView *cachedStrip = nil;
NSSize cachedStripSize = NSZeroSize;
NSSize cachedStripWindowSize = NSZeroSize;
CFAbsoluteTime cachedStripAt = 0;
NSWindow *viewHostWindow(NSView *view) {
    if (!view) return nil;
    @try {
        if (view.window) return view.window;
        for (NSView *parent = view.superview; parent; parent = parent.superview) {
            if (parent.window) return parent.window;
        }
    } @catch (NSException *) {}
    return nil;
}

NSRect listColumnScreenRect(void) {
    if (!sessionListView) return NSZeroRect;
    @try {
        NSWindow *window = viewHostWindow(sessionListView);
        if (!window) return NSZeroRect;
        NSRect win = [sessionListView convertRect:sessionListView.bounds toView:nil];
        return [window convertRectToScreen:win];
    } @catch (NSException *) {
        return NSZeroRect;
    }
}

NSView *composerStripView(void) {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cachedStrip) {
        @try {
            NSWindow *window = viewHostWindow(cachedStrip);
            NSRect win = [cachedStrip convertRect:cachedStrip.bounds toView:nil];
            NSRect screen = window ? [window convertRectToScreen:win] : NSZeroRect;
            const bool inBand = YMSessionMarkComposerStripBand(win, NSHeight(window.frame))
                || YMSessionMarkComposerNearWindowBottom(screen, window.frame);
            if (window && hostWindowIsMainChat(window) &&
                NSEqualSizes(cachedStrip.bounds.size, cachedStripSize) &&
                NSEqualSizes(window.frame.size, cachedStripWindowSize) &&
                inBand && now - cachedStripAt < 2.0)
                return cachedStrip;
        } @catch (NSException *) {}
        cachedStrip = nil;
    }
    Class qns = NSClassFromString(@"QNSView");
    NSWindow *main = mainChatWindow();
    if (!qns || !main) return nil;
    const NSRect listScreen = listColumnScreenRect();
    NSView *bestChat = nil;
    NSRect bestChatRect = NSZeroRect;
    NSView *bestBand = nil;
    NSRect bestBandRect = NSZeroRect;
    NSView *bestStrip = nil;
    CGFloat bestStripWidth = 0;
    int sawField = 0, sawBand = 0, sawChat = 0;
    std::function<void(NSView *, unsigned)> walk = [&](NSView *view, unsigned depth) {
        if (!view || depth > 24) return;
        if ([view isKindOfClass:qns]) {
            @try {
                NSWindow *window = viewHostWindow(view);
                if (!window) {
                    for (NSView *child in view.subviews) walk(child, depth + 1);
                    return;
                }
                NSRect win = [view convertRect:view.bounds toView:nil];
                NSView *typed = innerComposerField(view);
                if (!typed) {
                    for (NSView *child in view.subviews) walk(child, depth + 1);
                    return;
                }
                NSRect typedWin = typed == view ? win
                    : [typed convertRect:typed.bounds toView:nil];
                NSRect typedScreen = [window convertRectToScreen:typedWin];
                const bool inBand = YMSessionMarkComposerStripBand(typedWin, NSHeight(window.frame))
                    || YMSessionMarkComposerNearWindowBottom(typedScreen, window.frame);
                const bool typedStrip = YMSessionMarkComposerStripTypingSized(
                    NSWidth(typedWin), NSHeight(typedWin));
                if (typedStrip) sawField++;
                if (inBand) {
                    if (typedStrip) {
                        sawBand++;
                        if (YMSessionMarkComposerStripPreferWider(bestBandRect, typedWin)) {
                            bestBand = typed;
                            bestBandRect = typedWin;
                        }
                        if (YMSessionMarkComposerInChatColumn(typedScreen, listScreen)) {
                            sawChat++;
                            if (YMSessionMarkComposerStripPreferWider(bestChatRect, typedWin)) {
                                bestChat = typed;
                                bestChatRect = typedWin;
                            }
                        }
                    } else if (NSWidth(typedWin) > bestStripWidth) {
                        bestStrip = typed;
                        bestStripWidth = NSWidth(typedWin);
                    }
                }
            } @catch (NSException *) {}
        }
        for (NSView *child in view.subviews) walk(child, depth + 1);
    };
    auto consider = [&](NSWindow *window) {
        if (!window || window.miniaturized) return;
        if (!hostWindowIsMainChat(window)) return;
        NSView *root = window.contentView;
        if (!root) return;
        while (root.superview) root = root.superview;
        walk(root, 0);
    };
    consider(main);
    for (NSWindow *window in NSApp.windows) {
        if (window == main) continue;
        consider(window);
    }
    cachedStrip = bestChat ?: bestBand ?: bestStrip;
    if (!cachedStrip && now - lastStripMiss >= 0.25) {
        lastStripMiss = now;
        YMLog(@"[SessionMark] strip miss field=%d band=%d chat=%d list=%.0fx%.0f",
            sawField, sawBand, sawChat, NSWidth(listScreen), NSHeight(listScreen));
    }
    cachedStripSize = cachedStrip ? cachedStrip.bounds.size : NSZeroSize;
    cachedStripWindowSize = cachedStrip.window ? cachedStrip.window.frame.size : NSZeroSize;
    cachedStripAt = now;
    return cachedStrip;
}

NSView *largestQNSView(NSWindow *window) {
    Class qns = NSClassFromString(@"QNSView");
    if (!qns || !window) return nil;
    NSView *bestWide = nil;
    CGFloat bestWideArea = 0;
    NSView *bestAny = nil;
    CGFloat bestAnyArea = 0;
    std::function<void(NSView *, unsigned)> walk = [&](NSView *view, unsigned depth) {
        if (!view || depth > 24) return;
        if ([view isKindOfClass:qns]) {
            const CGFloat width = NSWidth(view.bounds);
            const CGFloat height = NSHeight(view.bounds);
            const CGFloat area = width * height;
            if (height >= 200 && !looksLikeSessionListColumn(width, height)) {
                if (width >= 400 && area > bestWideArea) {
                    bestWide = view;
                    bestWideArea = area;
                }
                if (width >= YMSessionMarkComposerFieldMinWidth && area > bestAnyArea) {
                    bestAny = view;
                    bestAnyArea = area;
                }
            }
        }
        for (NSView *child in view.subviews) walk(child, depth + 1);
    };
    NSView *root = window.contentView;
    while (root.superview) root = root.superview;
    walk(root, 0);
    return bestWide ? bestWide : bestAny;
}

uintptr_t lastClipWidget = 0;
NSRect lastClipIn = NSZeroRect;
NSSize lastClipWin = NSZeroSize;
CGFloat lastClipDrawer = -1;
NSRect lastClipOut = NSZeroRect;

CGFloat sampleDrawerAllowed(uintptr_t fieldWidget) {
    if (!fieldWidget) return -1;
    uintptr_t child = fieldWidget;
    uintptr_t page = parentWidget(child);
    for (int depth = 0; page && depth < 8; ++depth) {
        Rect pageRect;
        if (!widgetRect(page, pageRect)) break;
        NSRect pageBounds = NSMakeRect(0, 0, pageRect.width, pageRect.height);
        NSRect clip = NSZeroRect;
        BOOL hasDrawer = NO;
        if (YMChatPaneDrawerClip(page, child, pageBounds, &clip, &hasDrawer) && hasDrawer)
            return NSWidth(clip);
        child = page;
        page = parentWidget(page);
    }
    return -1;
}

void invalidateClipCache(void) {
    lastClipWidget = 0;
    lastClipOut = NSZeroRect;
}

// 抽屉宽≥48 起认。输入栏矩形和抽屉宽度没变则复用上一帧右缘，打开动画仍每帧跟。
NSRect clipComposerFrame(NSView *host, NSRect fieldFrame, uintptr_t fieldWidget) {
    if (!host) return fieldFrame;
    NSWindow *window = viewHostWindow(host);
    if (!window) window = host.window;
    auto applyRight = [&](CGFloat right) -> NSRect {
        if (!window) {
            if (right >= NSMaxX(fieldFrame) - 1) return fieldFrame;
            NSRect clipped = fieldFrame;
            clipped.size.width = right - NSMinX(fieldFrame);
            if (NSWidth(clipped) < YMSessionMarkComposerFieldMinWidth) return NSZeroRect;
            return clipped;
        }
        NSRect fieldWin = [host convertRect:fieldFrame toView:nil];
        NSRect fieldScreen = [window convertRectToScreen:fieldWin];
        if (right >= NSMaxX(fieldScreen) - 1) return fieldFrame;
        NSRect clippedScreen = fieldScreen;
        clippedScreen.size.width = right - NSMinX(fieldScreen);
        if (NSWidth(clippedScreen) < YMSessionMarkComposerFieldMinWidth) return NSZeroRect;
        NSRect clippedWin = [window convertRectFromScreen:clippedScreen];
        return [host convertRect:clippedWin fromView:nil];
    };
    NSRect fieldScreen = NSZeroRect;
    if (window) {
        @try {
            NSRect fieldWin = [host convertRect:fieldFrame toView:nil];
            fieldScreen = [window convertRectToScreen:fieldWin];
        } @catch (NSException *) {}
    }
    CGFloat right = window ? NSMaxX(fieldScreen) : NSMaxX(fieldFrame);
    const CGFloat drawer = sampleDrawerAllowed(fieldWidget);
    const NSSize winSize = window ? window.frame.size : NSZeroSize;
    if (fieldWidget && fieldWidget == lastClipWidget
        && NSEqualRects(fieldFrame, lastClipIn)
        && fabs(drawer - lastClipDrawer) < 0.5
        && NSEqualSizes(winSize, lastClipWin)
        && !NSIsEmptyRect(lastClipOut))
        return lastClipOut;
    if (fieldWidget) {
        uintptr_t child = fieldWidget;
        uintptr_t page = parentWidget(child);
        for (int depth = 0; page && depth < 24; ++depth) {
            Rect pageRect;
            if (!widgetRect(page, pageRect)) break;
            NSRect pageBounds = NSMakeRect(0, 0, pageRect.width, pageRect.height);
            NSRect clip = NSZeroRect;
            BOOL hasDrawer = NO;
            if (YMChatPaneDrawerClip(page, child, pageBounds, &clip, &hasDrawer) && hasDrawer) {
                NSView *pageHost = nil;
                NSRect pageFrame = NSZeroRect;
                if (mapSelf(page, &pageHost, &pageFrame) && pageHost && NSWidth(pageBounds) > 0) {
                    const CGFloat scale = NSWidth(pageFrame) / NSWidth(pageBounds);
                    NSRect allowedInPage = pageFrame;
                    allowedInPage.size.width = NSWidth(clip) * scale;
                    @try {
                        NSRect allowedInHost = pageHost == host ? allowedInPage
                            : [host convertRect:allowedInPage fromView:pageHost];
                        CGFloat allowedRight = NSMaxX(allowedInHost);
                        if (window) {
                            NSRect winRect = [host convertRect:allowedInHost toView:nil];
                            allowedRight = NSMaxX([window convertRectToScreen:winRect]);
                        }
                        if (allowedRight < right) right = allowedRight;
                    } @catch (NSException *) {}
                }
            }
            child = page;
            page = parentWidget(page);
        }
    }
    NSRect out = applyRight(right);
    lastClipWidget = fieldWidget;
    lastClipIn = fieldFrame;
    lastClipWin = winSize;
    lastClipDrawer = drawer;
    lastClipOut = out;
    return out;
}

CGFloat composerChildTop(NSView *parent, NSView *child) {
    if (!parent || !child) return 0;
    if (parent.isFlipped) return NSMinY(child.frame);
    return NSHeight(parent.bounds) - NSMaxY(child.frame);
}

NSView *innerComposerField(NSView *strip) {
    if (!strip) return nil;
    Class qns = NSClassFromString(@"QNSView");
    NSView *best = nil;
    CGFloat bestMinX = CGFLOAT_MAX;
    CGFloat bestW = 0;
    CGFloat bestH = 0;
    const CGFloat stripW = NSWidth(strip.bounds);
    const CGFloat stripH = NSHeight(strip.bounds);
    bool hasMessageList = false;
    NSView *parent = strip.superview;
    NSView *grand = parent.superview;
    if (parent && YMSessionMarkComposerMessageListChildSized(
            NSWidth(parent.bounds), NSHeight(parent.bounds), stripW, stripH,
            composerChildTop(parent, strip)))
        return nil;
    if (parent && grand && YMSessionMarkComposerMessageListChildSized(
            NSWidth(grand.bounds), NSHeight(grand.bounds),
            NSWidth(parent.bounds), NSHeight(parent.bounds),
            composerChildTop(grand, parent)))
        return nil;
    if (parent && YMSessionMarkComposerFieldInMessageList(
            NSWidth(parent.bounds), NSHeight(parent.bounds), stripW, stripH,
            composerChildTop(parent, strip)))
        return nil;
    for (NSView *child in strip.subviews) {
        if (qns && ![child isKindOfClass:qns]) continue;
        if (YMSessionMarkComposerMessageListChildSized(
                stripW, stripH, NSWidth(child.bounds), NSHeight(child.bounds),
                composerChildTop(strip, child)))
            hasMessageList = true;
        if (!YMSessionMarkComposerChildIsTypingField(strip.bounds, child.bounds)
            && !YMSessionMarkComposerCardWrapsTypingField(strip.bounds, child.bounds)) continue;
        const CGFloat x = NSMinX(child.frame);
        const CGFloat w = NSWidth(child.bounds);
        const CGFloat h = NSHeight(child.bounds);
        if (x < bestMinX - 0.5 || (fabs(x - bestMinX) < 0.5 && (w > bestW || (fabs(w - bestW) < 0.5 && h > bestH)))) {
            best = child;
            bestMinX = x;
            bestW = w;
            bestH = h;
        }
    }
    if (best) return best;
    if (hasMessageList) return nil;
    if (YMSessionMarkComposerFieldSized(stripW, stripH)) return strip;
    return nil;
}

uintptr_t followPlatformWindow(NSView *view) {
    if (!view) return 0;
    Ivar ivar = class_getInstanceVariable(object_getClass(view), "m_platformWindow");
    if (!ivar) return 0;
    uintptr_t platform = 0;
    std::memcpy(&platform, (uint8_t *)(__bridge void *)view + ivar_getOffset(ivar), sizeof platform);
    if (!platform) return 0;
    for (uintptr_t offset = 0; offset <= 0x40; offset += 8) {
        uintptr_t candidate = 0;
        Rect rect;
        if (!read(platform + offset, candidate) || !candidate) continue;
        if (widgetRect(candidate, rect) && rect.width >= 160 && rect.height >= 24) return candidate;
    }
    return 0;
}

uintptr_t widgetFromLargest(NSWindow *window) {
    NSView *native = largestQNSView(window);
    if (uintptr_t widget = widgetFromNativeView(native)) return widget;
    if (native.superview) {
        if (uintptr_t widget = widgetFromNativeView(native.superview)) return widget;
    }
    Class qns = NSClassFromString(@"QNSView");
    if (!qns || !window) return 0;
    uintptr_t best = 0;
    CGFloat bestArea = 0;
    std::function<void(NSView *, unsigned)> walk = [&](NSView *view, unsigned depth) {
        if (!view || depth > 24) return;
        if ([view isKindOfClass:qns]) {
            if (uintptr_t widget = widgetFromNativeView(view)) {
                Rect rect;
                if (widgetRect(widget, rect) && rect.width >= 400 && rect.height >= 200) {
                    const CGFloat area = (CGFloat)rect.width * rect.height;
                    if (area > bestArea) {
                        best = widget;
                        bestArea = area;
                    }
                }
            }
        }
        for (NSView *child in view.subviews) walk(child, depth + 1);
    };
    NSView *root = window.contentView;
    if (!root) return 0;
    while (root.superview) root = root.superview;
    walk(root, 0);
    return best;
}

void forEachChatRoot(const std::function<bool(uintptr_t)> &fn) {
    NSWindow *main = mainChatWindow();
    std::vector<std::pair<CGFloat, uintptr_t>> untitled;
    auto add = [&](NSWindow *window) {
        if (!window || window.miniaturized) return;
        if (!hostWindowIsMainChat(window)) return;
        uintptr_t widget = widgetFromLargest(window);
        Rect rect;
        if (!widget || !widgetRect(widget, rect)) return;
        untitled.push_back({(CGFloat)rect.width * (CGFloat)rect.height, widget});
    };
    for (NSWindow *window in NSApp.windows) {
        if (window == main) continue;
        add(window);
    }
    std::sort(untitled.begin(), untitled.end(),
        [](const std::pair<CGFloat, uintptr_t> &a, const std::pair<CGFloat, uintptr_t> &b) {
            return a.first > b.first;
        });
    for (const auto &item : untitled) {
        if (fn(item.second)) return;
    }
    if (uintptr_t widget = widgetFromLargest(main)) {
        if (fn(widget)) return;
    }
    if (uintptr_t fromCell = treeRootFrom(0)) fn(fromCell);
}

uintptr_t rootWidget(void) {
    uintptr_t found = 0;
    forEachChatRoot([&](uintptr_t widget) {
        found = widget;
        return true;
    });
    return found;
}

NSString *sessionFromTitle(void) {
    NSWindow *window = mainChatWindow();
    if (!window) return nil;
    NSString *found = nil;
    Class qns = NSClassFromString(@"QNSView");
    const CGFloat top = NSHeight(window.frame);
    std::function<void(NSView *, unsigned)> walk = [&](NSView *view, unsigned depth) {
        if (!view || depth > 24 || found.length) return;
        if (qns && [view isKindOfClass:qns]) {
            NSRect win = [view convertRect:view.bounds toView:nil];
            if (NSWidth(win) >= 160 && NSHeight(win) >= 180) {
                const bool list = NSMinX(win) < 320 && NSWidth(win) <= 400;
                const bool body = NSMinX(win) > 200 && NSHeight(win) > 200 && NSMinY(win) < top - 180;
                if (list || body) return;
            }
            if (NSWidth(win) >= 24 && NSWidth(win) <= 96 &&
                NSHeight(win) >= 24 && NSHeight(win) <= 72 &&
                NSMinX(win) > 220 && NSMaxY(win) > top - 140) {
                if (uintptr_t widget = widgetFromNativeView(view)) {
                    NSString *session = sessionFromHeadTree(widget, 0, false);
                    if (YMSessionMarkIsSessionId(session)) found = session;
                }
            }
        }
        for (NSView *child in view.subviews) walk(child, depth + 1);
    };
    NSView *nsRoot = window.contentView;
    while (nsRoot.superview) nsRoot = nsRoot.superview;
    walk(nsRoot, 0);
    return found;
}

bool childIsMessageListArea(const Rect &ancestor, const Rect &child, int childAbsY,
                            uintptr_t childWidget) {
    // 先看尺寸。拉高后的输入栏相对输入卡也会高过 140、底下剩工具栏，必须排除带会话号的灰线。
    const bool listSized = YMSessionMarkComposerMessageListChildSized(
            ancestor.width, ancestor.height, child.width, child.height, childAbsY)
        || YMSessionMarkComposerFieldInMessageList(
            ancestor.width, ancestor.height, child.width, child.height, childAbsY);
    if (!listSized) return false;
    return !fieldSession(childWidget, nullptr);
}

bool isComposerToolbar(uintptr_t widget) {
    if (fieldSession(widget, nullptr)) return false;
    Rect rect, parentRect;
    if (!widgetRect(widget, rect)) return false;
    if (rect.height < 24 || rect.height > YMSessionMarkComposerToolbarMaxHeight) return false;
    if (!YMSessionMarkComposerFieldSized(rect.width, rect.height)) return false;
    uintptr_t parent = parentWidget(widget);
    if (!parent || !widgetRect(parent, parentRect)) return false;
    if (parentRect.height < rect.height + 20) return false;
    return parentRect.height - rect.y - rect.height <= 8;
}

bool haveComposerHit(const std::vector<uintptr_t> &hits) {
    for (uintptr_t hit : hits) {
        Rect rect;
        if (!widgetRect(hit, rect) || rect.width < 160) continue;
        if (isComposerToolbar(hit)) continue;
        if (!YMSessionMarkComposerTypingHitSized(fieldSession(hit, nullptr), rect.width, rect.height)) continue;
        if (composerHasMessageListChild(hit) || composerOnMessageList(hit)) continue;
        if (innerTypingField(hit)) continue;
        if (!inComposerStrip(hit) && !fieldSession(hit, nullptr)) continue;
        if (fieldSession(hit, nullptr)) return true;
    }
    return false;
}

void collectComposerFields(uintptr_t start, std::vector<uintptr_t> &hits,
                           std::set<uintptr_t> &seen, unsigned &visits,
                           uintptr_t wantNative) {
    if (!start || seen.count(start) || ++visits > 4096) return;
    if (haveComposerHit(hits)) return;
    seen.insert(start);
    Rect rect;
    const bool haveRect = widgetRect(start, rect);
    if (haveRect && !mayContainComposer(rect) &&
        !(wantNative && widgetNative(start) == wantNative)) return;
    if (fieldSession(start, nullptr)) hits.push_back(start);
    else if (haveRect && !isComposerToolbar(start) && geometryComposerCandidate(start)) hits.push_back(start);
    // 消息列表是聊天页下贴顶的兄弟，不走进列表子树；挤矮后的短消息区、灰线尺寸行也不是输入栏。
    auto skipMessageList = [&](uintptr_t child) -> bool {
        Rect childRect;
        if (!haveRect || !widgetRect(child, childRect)) return false;
        return childIsMessageListArea(rect, childRect, childRect.y, child);
    };
    if (composerOnMessageList(start) && !fieldSession(start, nullptr)) return;
    if (wantNative && widgetNative(start) == wantNative) {
        std::vector<uintptr_t> kids;
        if (widgetChildren(start, kids)) {
            for (uintptr_t child : kids) {
                if (skipMessageList(child)) continue;
                collectComposerFields(child, hits, seen, visits, wantNative);
            }
        }
        return;
    }
    std::vector<uintptr_t> kids;
    if (!widgetChildren(start, kids)) return;
    const bool tall = haveRect && rect.height > YMSessionMarkComposerSurfaceMaxHeight;
    std::vector<uintptr_t> shortKids, tallKids;
    for (uintptr_t child : kids) {
        if (skipMessageList(child)) continue;
        Rect childRect;
        if (tall && widgetRect(child, childRect)
            && childRect.height > YMSessionMarkComposerSurfaceMaxHeight) tallKids.push_back(child);
        else shortKids.push_back(child);
    }
    for (uintptr_t child : shortKids) {
        collectComposerFields(child, hits, seen, visits, wantNative);
        if (haveComposerHit(hits)) return;
    }
    if (haveComposerHit(hits)) return;
    for (uintptr_t child : tallKids) {
        Rect childRect;
        if (widgetRect(child, childRect) && childRect.height < rect.height * 0.90) continue;
        collectComposerFields(child, hits, seen, visits, wantNative);
        if (haveComposerHit(hits)) return;
    }
}

uintptr_t findWidgetWithNative(uintptr_t start, uintptr_t native,
                               std::set<uintptr_t> &seen, unsigned &visits) {
    if (!start || !native || seen.count(start) || ++visits > 4096) return 0;
    seen.insert(start);
    if (widgetNative(start) == native) return start;
    Rect rect;
    if (widgetRect(start, rect) && looksLikeSessionListColumn(rect.width, rect.height)) return 0;
    std::vector<uintptr_t> kids;
    if (!widgetChildren(start, kids)) return 0;
    for (uintptr_t child : kids) {
        if (uintptr_t found = findWidgetWithNative(child, native, seen, visits)) return found;
    }
    return 0;
}

uintptr_t pickField(const std::vector<uintptr_t> &hits) {
    uintptr_t best = 0;
    Rect bestRect;
    bool bestSession = false;
    bool bestStrip = false;
    for (uintptr_t hit : hits) {
        Rect rect;
        if (!widgetRect(hit, rect)) continue;
        if (composerHasMessageListChild(hit) || composerOnMessageList(hit)) continue;
        if (isComposerToolbar(hit)) continue;
        const bool hasSession = fieldSession(hit, nullptr);
        if (!YMSessionMarkComposerTypingHitSized(hasSession, rect.width, rect.height)) continue;
        if (!hasSession && !geometryComposerCandidate(hit)) continue;
        const bool strip = inComposerStrip(hit);
        if (!strip && !hasSession) continue;
        if (!best) {
            best = hit;
            bestRect = rect;
            bestSession = hasSession;
            bestStrip = strip;
            continue;
        }
        if (strip && !bestStrip) {
            best = hit;
            bestRect = rect;
            bestSession = hasSession;
            bestStrip = true;
            continue;
        }
        if (!strip && bestStrip) continue;
        if (hasSession && !bestSession) {
            best = hit;
            bestRect = rect;
            bestSession = true;
            bestStrip = strip;
            continue;
        }
        if (!hasSession && bestSession) continue;
        const bool shown = widgetVisible(hit);
        const bool bestShown = widgetVisible(best);
        if (shown && !bestShown) {
            best = hit;
            bestRect = rect;
            bestStrip = strip;
            continue;
        }
        if (!shown && bestShown) continue;
        NSRect hitSize = NSMakeRect(0, 0, rect.width, rect.height);
        NSRect bestSize = NSMakeRect(0, 0, bestRect.width, bestRect.height);
        if (wrapsTypingField(hitSize, bestSize)) continue;
        if (wrapsTypingField(bestSize, hitSize)) {
            best = hit;
            bestRect = rect;
            bestSession = hasSession;
            bestStrip = strip;
            continue;
        }
        if (strip && bestStrip) {
            const CGFloat hitY = windowMinY(hit);
            const CGFloat bestY = windowMinY(best);
            if (hitY + 8 < bestY || (fabs(hitY - bestY) <= 8 && rect.width > bestRect.width)) {
                best = hit;
                bestRect = rect;
                bestStrip = true;
            }
            continue;
        }
        const bool hitTyped = YMSessionMarkComposerTypingHitSized(hasSession, rect.width, rect.height);
        const bool bestTyped = YMSessionMarkComposerTypingHitSized(bestSession, bestRect.width, bestRect.height);
        const bool betterSize = hitTyped && !bestTyped;
        const bool taller = hitTyped && bestTyped && rect.height > bestRect.height + 8;
        const bool wider = hitTyped && bestTyped && !taller &&
            rect.width > bestRect.width && rect.height >= bestRect.height - 8;
        if (betterSize || taller || wider) {
            best = hit;
            bestRect = rect;
            bestStrip = strip;
        }
    }
    return best;
}

uintptr_t widgetFromNativeView(NSView *view) {
    if (!view) return 0;
    const uintptr_t ident = (uintptr_t)(__bridge void *)view;
    auto owned = nativeOwner.find(ident);
    if (owned != nativeOwner.end() && widgetNative(owned->second) == ident) return owned->second;
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(view), &count);
    uintptr_t found = 0;
    for (unsigned i = 0; i < count && !found; ++i) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '^') continue;
        uintptr_t value = 0;
        std::memcpy(&value, (uint8_t *)(__bridge void *)view + ivar_getOffset(ivars[i]), sizeof value);
        if (!value || !looksLikeQWidget(value)) continue;
        Rect rect;
        if (widgetRect(value, rect) && rect.width >= 16 && rect.height >= 16) found = value;
    }
    free(ivars);
    if (found) return found;
    return followPlatformWindow(view);
}

uintptr_t composerField(uintptr_t widget) {
    NSView *strip = composerStripView();
    const uintptr_t stripNative = strip ? (uintptr_t)(__bridge void *)strip : 0;
    uintptr_t from = treeRootFrom(widget);
    uintptr_t root = rootWidget();
    if (!root) root = from;
    if (!root && strip) root = widgetFromNativeView(strip);
    if (!root && strip.superview) root = widgetFromNativeView(strip.superview);
    std::vector<uintptr_t> hits;
    std::set<uintptr_t> seen;
    unsigned visits = 0;
    auto search = [&](uintptr_t start, uintptr_t native) -> uintptr_t {
        if (!start) return 0;
        collectComposerFields(start, hits, seen, visits, native);
        return pickField(hits);
    };
    if (root && stripNative) {
        std::set<uintptr_t> nativeSeen;
        unsigned nativeVisits = 0;
        if (uintptr_t host = findWidgetWithNative(root, stripNative, nativeSeen, nativeVisits)) {
            if (uintptr_t found = search(host, stripNative)) return found;
            if (fieldSession(host, nullptr)) return host;
            hits.clear();
            seen.clear();
            visits = 0;
        }
    }
    if (strip) {
        if (uintptr_t host = widgetFromNativeView(strip)) {
            if (uintptr_t found = search(host, stripNative)) return found;
            if (fieldSession(host, nullptr)) return host;
        }
    }
    if (uintptr_t picked = pickField(hits)) return picked;
    uintptr_t fromRoots = 0;
    unsigned totalVisits = 0;
    int rootCount = 0;
    size_t hitCount = 0;
    forEachChatRoot([&](uintptr_t chatRoot) {
        rootCount++;
        hits.clear();
        seen.clear();
        visits = 0;
        fromRoots = search(chatRoot, 0);
        totalVisits += visits;
        hitCount += hits.size();
        return fromRoots != 0;
    });
    if (!fromRoots) {
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastFieldSearchLog >= 0.25) {
            lastFieldSearchLog = now;
            Rect treeRect{};
            widgetRect(treeRootFrom(widget ? widget : cachedListCell), treeRect);
            YMLog(@"[SessionMark] field search roots=%d visits=%u hits=%zu cell=%d tree=%.0fx%.0f",
                rootCount, totalVisits, hitCount, cachedListCell ? 1 : 0,
                (CGFloat)treeRect.width, (CGFloat)treeRect.height);
        }
    }
    if (fromRoots) return fromRoots;
    hits.clear();
    seen.clear();
    visits = 0;
    uintptr_t start = from ? from : root;
    if (!start) start = widget;
    if (start) {
        if (uintptr_t again = search(start, 0)) return again;
    }
    return 0;
}

uintptr_t inputChrome(uintptr_t field) {
    Rect fieldRect;
    if (!widgetRect(field, fieldRect)) return field;
    uintptr_t current = parentWidget(field);
    for (int depth = 0; current && depth < 6; ++depth) {
        Rect rect;
        if (widgetRect(current, rect) &&
            YMSessionMarkComposerChromeWrapsField(
                NSMakeRect(0, 0, rect.width, rect.height),
                NSMakeRect(0, 0, fieldRect.width, fieldRect.height))) {
            return current;
        }
        current = parentWidget(current);
    }
    return field;
}

bool wrapsTypingField(NSRect outer, NSRect inner) {
    return YMSessionMarkComposerOuterWrapsInner(outer, inner)
        || YMSessionMarkComposerCardWrapsTypingField(outer, inner);
}

uintptr_t innerTypingField(uintptr_t chrome) {
    Rect chromeRect;
    if (!chrome || !widgetRect(chrome, chromeRect)) return 0;
    std::vector<uintptr_t> kids;
    if (!widgetChildren(chrome, kids)) return 0;
    uintptr_t best = 0;
    CGFloat bestHeight = 0;
    const NSRect chromeSize = NSMakeRect(0, 0, chromeRect.width, chromeRect.height);
    for (uintptr_t child : kids) {
        Rect rect;
        if (!child || !widgetRect(child, rect)) continue;
        if (!wrapsTypingField(chromeSize, NSMakeRect(0, 0, rect.width, rect.height))) continue;
        if (!best || rect.height > bestHeight) {
            best = child;
            bestHeight = rect.height;
        }
    }
    return best;
}

bool composerOnMessageList(uintptr_t widget) {
    if (!widget || fieldSession(widget, nullptr)) return false;
    Rect selfRect;
    if (!widgetRect(widget, selfRect)) return false;
    uintptr_t parent = parentWidget(widget);
    Rect parentRect;
    if (parent && widgetRect(parent, parentRect) &&
        YMSessionMarkComposerMessageListChildSized(
            parentRect.width, parentRect.height, selfRect.width, selfRect.height, selfRect.y))
        return true;
    uintptr_t grand = parent ? parentWidget(parent) : 0;
    Rect grandRect;
    if (parent && grand && widgetRect(grand, grandRect) &&
        YMSessionMarkComposerMessageListChildSized(
            grandRect.width, grandRect.height, parentRect.width, parentRect.height, parentRect.y))
        return true;
    if (parent && widgetRect(parent, parentRect) &&
        YMSessionMarkComposerFieldInMessageList(
            parentRect.width, parentRect.height, selfRect.width, selfRect.height, selfRect.y))
        return true;
    return false;
}

bool composerHasMessageListDescendant(uintptr_t ancestor, const Rect &ancestorRect,
                                     uintptr_t node, int absY, int depth, unsigned &visits) {
    // 列表相对聊天页贴顶即可，中间可隔标题/内容层。挤矮后消息区矮过灰线上限也算列表，不当输入卡。
    if (!node || depth > 6 || ++visits > 32) return false;
    std::vector<uintptr_t> kids;
    if (!widgetChildren(node, kids)) return false;
    for (uintptr_t child : kids) {
        Rect childRect;
        if (!child || !widgetRect(child, childRect)) continue;
        const int childAbsY = absY + childRect.y;
        if (childIsMessageListArea(ancestorRect, childRect, childAbsY, child))
            return true;
        if (childRect.height <= YMSessionMarkComposerFieldMaxHeight) continue;
        if (composerHasMessageListDescendant(
                ancestor, ancestorRect, child, childAbsY, depth + 1, visits))
            return true;
    }
    return false;
}

bool composerHasMessageListChild(uintptr_t parent) {
    Rect parentRect;
    if (!parent || !widgetRect(parent, parentRect)) return false;
    unsigned visits = 0;
    return composerHasMessageListDescendant(parent, parentRect, parent, 0, 0, visits);
}

bool composerCardHasMessageList(uintptr_t parent, uintptr_t field) {
    (void)field;
    return composerHasMessageListChild(parent);
}

uintptr_t composerCard(uintptr_t field) {
    Rect fieldRect;
    if (!widgetRect(field, fieldRect)) return 0;
    uintptr_t current = parentWidget(field);
    uintptr_t best = 0;
    CGFloat bestHeight = 0;
    for (int depth = 0; current && depth < 6; ++depth) {
        Rect rect;
        if (widgetRect(current, rect) &&
            YMSessionMarkComposerCardSized(rect.width, rect.height,
                fieldRect.width, fieldRect.height) &&
            !composerCardHasMessageList(current, field)) {
            if (!best || rect.height > bestHeight) {
                best = current;
                bestHeight = rect.height;
            }
        }
        current = parentWidget(current);
    }
    return best;
}

bool mapComposerSurface(uintptr_t widget, NSView **hostOut, NSRect *frameOut) {
    if (!widget || !hostOut || !frameOut) return false;
    const bool typed = fieldSession(widget, nullptr);
    if (!typed && (composerHasMessageListChild(widget) || composerOnMessageList(widget)))
        return false;
    uintptr_t field = widget;
    uintptr_t card = 0;
    if (uintptr_t inner = innerTypingField(widget)) {
        field = inner;
        card = widget;
    } else {
        card = composerCard(widget);
    }
    NSView *host = nil;
    NSRect frame = NSZeroRect;
    if (!mapSelf(field, &host, &frame) || !host) return false;
    if (!YMSessionMarkComposerOverlaySized(NSWidth(frame), NSHeight(frame))) return false;
    NSWindow *win = viewHostWindow(host);
    if (!win || !hostWindowIsMainChat(win)) return false;
    @try {
        NSRect winRect = [host convertRect:frame toView:nil];
        NSRect screen = [win convertRectToScreen:winRect];
        if (YMSessionMarkComposerNearWindowTop(screen, win.frame)) return false;
        bool band = typed
            || YMSessionMarkComposerStripBand(winRect, NSHeight(win.frame))
            || YMSessionMarkComposerNearWindowBottom(screen, win.frame);
        if (!band && fieldSession(field, nullptr))
            band = YMSessionMarkComposerBottomAnchored(winRect, NSHeight(win.frame))
                || YMSessionMarkComposerNearWindowBottomAnchored(screen, win.frame);
        if (!band) return false;
    } @catch (NSException *) {
        return false;
    }
    if (!card) card = composerCard(field);
    if (card && card != field) {
        NSView *cardHost = nil;
        NSRect cardFrame = NSZeroRect;
        if (mapSelf(card, &cardHost, &cardFrame) && cardHost) {
            @try {
                if (cardHost == host) {
                    frame = YMSessionMarkComposerTypingSurface(frame, cardFrame, host.isFlipped);
                } else {
                    NSRect fieldInCard = [cardHost convertRect:frame fromView:host];
                    NSRect surface = YMSessionMarkComposerTypingSurface(
                        fieldInCard, cardFrame, cardHost.isFlipped);
                    if (!NSEqualRects(surface, fieldInCard)) {
                        host = cardHost;
                        frame = surface;
                    }
                }
            } @catch (NSException *) {}
        }
    }
    if (!YMSessionMarkComposerOverlaySized(NSWidth(frame), NSHeight(frame))) return false;
    *hostOut = host;
    *frameOut = frame;
    return true;
}

bool matchPrologue(uintptr_t offset, const uint8_t *bytes, size_t count) {
    const uintptr_t addr = YMRuntimeAddress(offset);
    return addr && bytes && count && std::memcmp(reinterpret_cast<const void *>(addr), bytes, count) == 0;
}

struct NativeColor {
    int32_t spec = 1;
    uint16_t alpha = 0xffff, red = 0, green = 0, blue = 0, padding = 0;
};
static_assert(sizeof(NativeColor) == 16);

NativeColor colorFromRGB(uint32_t rgb, CGFloat alpha) {
    NativeColor value;
    value.alpha = (uint16_t)std::lround(std::clamp((double)alpha, 0.0, 1.0) * 65535.0);
    value.red = ((rgb >> 16) & 255) * 257;
    value.green = ((rgb >> 8) & 255) * 257;
    value.blue = (rgb & 255) * 257;
    return value;
}

void fillColor(void *painter, int x1, int y1, int x2, int y2, uint32_t rgb, CGFloat alpha) {
    if (!painter || x2 < x1 || y2 < y1) return;
    const NativeColor color = colorFromRGB(rgb, alpha);
    const int rect[4] = {x1, y1, x2, y2};
    ((void (*)(void *, const int *, const NativeColor *))YMRuntimeAddress(native->painterFillRectColor))
        (painter, rect, &color);
}

// 已着色选中格四角 L「」：线宽 4、臂 14，外缘倒 2px。未选中不画。
void paintSelectedCorners(void *painter, int width, int height, uint32_t rgb) {
    if (!painter || width < 36 || height < 28) return;
    const int t = 4;
    const int arm = 14;
    const int m = 2;
    const int round = 2;
    const CGFloat alpha = 0.95;
    const int right = width - 1 - m;
    const int bottom = height - 1 - m;
    fillColor(painter, m + round, m, m + arm, m + t - 1, rgb, alpha);
    fillColor(painter, m, m + round, m + t - 1, m + arm, rgb, alpha);
    fillColor(painter, right - arm, m, right - round, m + t - 1, rgb, alpha);
    fillColor(painter, right - t + 1, m + round, right, m + arm, rgb, alpha);
    fillColor(painter, m + round, bottom - t + 1, m + arm, bottom, rgb, alpha);
    fillColor(painter, m, bottom - arm, m + t - 1, bottom - round, rgb, alpha);
    fillColor(painter, right - arm, bottom - t + 1, right - round, bottom, rgb, alpha);
    fillColor(painter, right - t + 1, bottom - arm, right, bottom - round, rgb, alpha);
}

bool nsTextHasContent(NSView *view, NSView *host, NSRect clip, unsigned depth) {
    if (!view || !host || depth > 8) return false;
    NSRect inHost = [view convertRect:view.bounds toView:host];
    if (!NSIntersectsRect(inHost, clip)) return false;
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if ([view isKindOfClass:NSTextView.class] &&
        [[((NSTextView *)view).string stringByTrimmingCharactersInSet:space] length]) return true;
    if ([view isKindOfClass:NSTextField.class] && ((NSTextField *)view).stringValue.length &&
        !((NSTextField *)view).editable) {
        for (NSView *child in view.subviews) {
            if (nsTextHasContent(child, host, clip, depth + 1)) return true;
        }
        return false;
    }
    if ([view isKindOfClass:NSTextField.class] &&
        [[((NSTextField *)view).stringValue stringByTrimmingCharactersInSet:space] length]) return true;
    for (NSView *child in view.subviews) {
        if (nsTextHasContent(child, host, clip, depth + 1)) return true;
    }
    return false;
}

NSString *qstringAt(uintptr_t handle) {
    uintptr_t data = 0;
    struct { int32_t ref, size; uint64_t allocation; intptr_t offset; } header{};
    if (!read(handle, data) || !data) return @"";
    if (!readBytes(data, &header, sizeof header) || header.size < 0 || header.size > 32 * 1024 ||
        header.offset < 24) return nil;
    if (!header.size) return @"";
    std::u16string buffer(static_cast<size_t>(header.size), 0);
    if (!readBytes(data + static_cast<uintptr_t>(header.offset), buffer.data(), buffer.size() * 2))
        return nil;
    return [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(buffer.data())
                                         length:buffer.size()];
}

NSString *callQString(uintptr_t fn, uintptr_t object) {
    if (!native || !fn || !object || !matchPrologue(native->stringDestruct, kQStringDestructBytes, sizeof kQStringDestructBytes))
        return nil;
    uintptr_t dtor = YMRuntimeAddress(native->stringDestruct);
    uint64_t handle = 0;
    register uintptr_t x0 asm("x0") = object;
    register uintptr_t x8 asm("x8") = reinterpret_cast<uintptr_t>(&handle);
    register uintptr_t x9 asm("x9") = fn;
    asm volatile("blr x9" : "+r"(x0), "+r"(x8), "+r"(x9) :
        : "x1", "x2", "x3", "x4", "x5", "x6", "x7",
          "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
          "x30", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15",
          "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
          "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31", "cc", "memory");
    NSString *text = qstringAt(reinterpret_cast<uintptr_t>(&handle));
    ((void (*)(void *))dtor)(&handle);
    return text;
}

uintptr_t textDocumentControl(uintptr_t field) {
    // 两版 toPlainText 都从 control.d_ptr+0x58 取文档；先确认输入框会话字段。
    if (!field || !fieldSession(field, nullptr)) return 0;
    uintptr_t priv = 0, control = 0, controlPriv = 0, document = 0, docPriv = 0, table = 0;
    if (!read(field + 8, priv) || !priv) return 0;
    if (!read(priv + native->fieldControl, control) || !control) return 0;
    if (!read(control + 8, controlPriv) || !controlPriv) return 0;
    if (!read(controlPriv + 0x58, document) || !document) return 0;
    if (!read(document + 8, docPriv) || !docPriv) return 0;
    if (!read(document, table) || !table) return 0;
    Dl_info info = {};
    if (!dladdr(reinterpret_cast<const void *>(table), &info) || !info.dli_fname ||
        !std::strstr(info.dli_fname, "wechat.dylib")) return 0;
    return control;
}

NSString *fieldPlainText(uintptr_t field) {
    // 使用 toPlainText 的 x8 返回槽，不能改调文档布局或 toHtml。
    if (!native || !field ||
        !matchPrologue(native->textControlPlain, native->textControlBytes, sizeof native->textControlBytes) ||
        !matchPrologue(native->textDocumentPlain, kTextDocumentPlainBytes, sizeof kTextDocumentPlainBytes))
        return nil;
    uintptr_t control = textDocumentControl(field);
    if (!control) return nil;
    return callQString(YMRuntimeAddress(native->textControlPlain), control);
}

bool trimmedHasContent(NSString *text) {
    if (!text.length) return false;
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    return [text stringByTrimmingCharactersInSet:space].length > 0;
}

bool composerEmpty(uintptr_t field) {
    return !trimmedHasContent(fieldPlainText(field));
}

int emptyIfField(uintptr_t widget) {
    NSString *text = fieldPlainText(widget);
    if (!text) return -1;
    return trimmedHasContent(text) ? 0 : 1;
}

bool composerTextFieldUsable(uintptr_t widget) {
    if (!widget || !fieldSession(widget, nullptr) || !textDocumentControl(widget)) return false;
    Rect rect;
    if (!widgetRect(widget, rect)) return false;
    return YMSessionMarkComposerOverlaySized(rect.width, rect.height);
}

uintptr_t composerTextField(uintptr_t widget) {
    if (!widget) return 0;
    if (composerTextFieldUsable(widget)) return widget;
    if (uintptr_t inner = innerTypingField(widget)) {
        if (composerTextFieldUsable(inner)) return inner;
    }
    uintptr_t current = parentWidget(widget);
    for (int depth = 0; current && depth < 8; ++depth) {
        if (composerTextFieldUsable(current)) return current;
        current = parentWidget(current);
    }
    std::vector<uintptr_t> queue;
    std::set<uintptr_t> seen;
    queue.push_back(widget);
    for (size_t i = 0; i < queue.size() && i < 64; ++i) {
        uintptr_t node = queue[i];
        if (!node || seen.count(node)) continue;
        seen.insert(node);
        if (composerTextFieldUsable(node)) return node;
        if (node != widget && composerOnMessageList(node)) continue;
        std::vector<uintptr_t> kids;
        if (!widgetChildren(node, kids)) continue;
        for (uintptr_t child : kids) queue.push_back(child);
    }
    return 0;
}

bool composerIsEmpty(uintptr_t widget) {
    // 读到非空才藏；找不到输入栏或读失败仍当空。
    uintptr_t field = composerTextField(widget);
    if (!field) return true;
    int found = emptyIfField(field);
    if (found >= 0) return found == 1;
    return true;
}

struct NoAnimation {
    NoAnimation() {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [NSAnimationContext beginGrouping];
        NSAnimationContext.currentContext.duration = 0;
        NSAnimationContext.currentContext.allowsImplicitAnimation = NO;
    }
    ~NoAnimation() {
        [NSAnimationContext endGrouping];
        [CATransaction commit];
    }
};

} // namespace

static NSColor *ymSessionMarkColor(uint32_t rgb, CGFloat alpha = 1) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                               green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0
                               alpha:alpha];
}

@interface YMSessionMarkLayer : NSView
@property (nonatomic, assign) uint32_t rgb;
@property (nonatomic, assign) NSInteger kind; // 0 border, 1 placeholder
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) uint32_t textRGB;
@property (nonatomic, assign) CGFloat chromeAlpha;
@property (nonatomic, assign) CGFloat washAlpha;
@property (nonatomic, assign) CGFloat cornerRadius;
@end

@implementation YMSessionMarkLayer
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect bounds = self.bounds;
    const CGFloat chrome = self.chromeAlpha > 0 ? self.chromeAlpha : YMSessionMarkAlphaDefault;
    const CGFloat radius = self.cornerRadius > 0 ? self.cornerRadius : 8;
    if (self.kind == 0) {
        [ymSessionMarkColor(self.rgb, chrome) setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5)
            xRadius:radius yRadius:radius];
        path.lineWidth = 1;
        path.lineCapStyle = NSLineCapStyleRound;
        path.lineJoinStyle = NSLineJoinStyleRound;
        [path stroke];
        return;
    }
    const CGFloat wash = self.washAlpha > 0 ? self.washAlpha : YMSessionMarkWashDefault;
    NSBezierPath *veil = [NSBezierPath bezierPathWithRoundedRect:bounds
        xRadius:radius yRadius:radius];
    [ymSessionMarkColor(self.rgb, wash) setFill];
    [veil fill];
    if (self.text.length) {
        CGFloat size = self.fontSize > 0 ? self.fontSize : 14;
        [YMSessionMarkQuotedString(self.text, size, ymSessionMarkColor(self.textRGB), NSTextAlignmentLeft)
            drawInRect:NSInsetRect(bounds, 10, 8)];
    }
}
@end

namespace {

struct OverlaySet {
    YMSessionMarkLayer *border;
    YMSessionMarkLayer *placeholder;
    NSString *session;
    bool composer = false;
};

struct Job {
    uintptr_t widget = 0;
    bool composer = false;
    NSString *session;
    NSDictionary *mark;
};

std::map<uintptr_t, OverlaySet> overlays;
std::map<uintptr_t, Job> jobs;
NSString *openSession = nil;
NSString *cachedTitleSession = nil;
CFAbsoluteTime cachedTitleAt = 0;
uintptr_t cachedComposer = 0;
uintptr_t boundSelectedCell = 0; // 本轮已着色选中格；列表指针空时仍能判断当前选中是否已着色。
bool composerClosed = false;
bool cachedComposerOpen = false;
CFAbsoluteTime cachedComposerOpenAt = 0;
uintptr_t cachedComposerOpenOrigin = 0;
uintptr_t lastFollowWidget = 0;
Rect lastFollowRect = {};
CGFloat lastFollowDrawer = -1;
uintptr_t cachedEmptyField = 0;
CFAbsoluteTime cachedEmptyAt = 0;
bool cachedEmpty = true;
CFAbsoluteTime lastDiscover = 0;
NSTimer *followTimer;
id scrollMonitor;
id windowObserver;
void (*origViewWillDraw)(NSView *, SEL) = nullptr;
bool hostHooked = false;
bool flushOpen = false;
bool followQueued = false;
bool refreshing = false;
CFAbsoluteTime geometryUntil = 0;


void stopFollow();
void startFollow();
void refreshFrames(bool allowAttach);
void touchFlush();
void rememberSessionList(uintptr_t cell);
void invalidateSessionList(void);
NSString *titleSessionCached(void);

bool live(void) {
    return installed && NSThread.isMainThread && YMSessionMarkEnabled();
}

bool hostUsable(NSView *host) {
    if (!host || host.hidden) return false;
    NSWindow *window = viewHostWindow(host);
    if (!window) window = host.window;
    if (!window || window.miniaturized) return false;
    if (window.visible) return true;
    return hostWindowIsMainChat(window);
}

bool windowShowsDiscoverPage(void) {
    NSWindow *window = mainChatWindow();
    if (!window) return false;
    bool found = false;
    std::function<void(NSView *, unsigned)> walk = [&](NSView *view, unsigned depth) {
        if (!view || depth > 20 || found) return;
        NSRect win = [view convertRect:view.bounds toView:nil];
        if (NSMinX(win) < 360 && NSMinX(win) > 40) {
            NSString *text = nil;
            if ([view respondsToSelector:@selector(stringValue)])
                text = [(id)view stringValue];
            if (!text.length && [view respondsToSelector:@selector(title)])
                text = [(id)view title];
            if ([text isEqual:@"发现"] || [text isEqual:@"视频号"] || [text isEqual:@"搜一搜"])
                found = true;
        }
        for (NSView *child in view.subviews) walk(child, depth + 1);
    };
    NSView *root = window.contentView;
    while (root.superview) root = root.superview;
    walk(root, 0);
    return found;
}

std::vector<uintptr_t> visibleSessionCells(void) {
    uintptr_t origin = cachedListCell ? cachedListCell : boundSelectedCell;
    if (!origin || !looksLikeQWidget(origin) || !sessionListCell(origin)) return {};
    uintptr_t node = origin;
    for (int up = 0; up < 10; ++up) {
        uintptr_t parent = parentWidget(node);
        if (!parent) break;
        std::vector<uintptr_t> kids;
        if (!widgetChildren(parent, kids) || kids.size() < 2) {
            node = parent;
            continue;
        }
        std::vector<uintptr_t> cells;
        for (uintptr_t kid : kids) {
            Rect rect;
            if (!looksLikeQWidget(kid) || !widgetRect(kid, rect)) continue;
            if (!YMSessionMarkSessionListCellSized(rect.width, rect.height)) continue;
            if (!widgetVisible(kid)) continue;
            NSView *host = nil;
            NSRect frame = NSZeroRect;
            if (!mapSelf(kid, &host, &frame) || !host.window) continue;
            NSRect win = NSZeroRect;
            @try { win = [host convertRect:frame toView:nil]; }
            @catch (NSException *) { continue; }
            if (NSWidth(win) < 160 || NSMinX(win) >= 420) continue;
            cells.push_back(kid);
        }
        if (cells.size() >= 2) return cells;
        node = parent;
    }
    return widgetVisible(origin) ? std::vector<uintptr_t>{origin} : std::vector<uintptr_t>{};
}

// 当前选中必须已着色，且不是文件夹。
bool listShowsSelectedMarkedChat(void) {
    const auto cells = visibleSessionCells();
    if (cells.size() < 2) return false;
    bool marked = false;
    bool other = false;
    for (uintptr_t cell : cells) {
        if (!cellNativeSelected(cell)) continue;
        if (cellLooksLikeFolderHolder(cell)) {
            other = true;
            continue;
        }
        NSString *session = sessionFromCell(cell);
        if (session.length && YMSessionMarkLookup(YMAppearanceAccount(), session))
            marked = true;
        else
            other = true;
    }
    return marked && !other;
}

void invalidateComposerOpenCache(void) {
    cachedComposerOpenAt = 0;
    lastFollowWidget = 0;
    invalidateClipCache();
}

bool composerChatOpen(void) {
    // 已拆、发现页、未着色选中、公众号文件夹都不画输入叠层。
    // 选中格没变时复用 0.2 秒，聊天记录滚动不重扫发现页和会话列表。
    if (composerClosed) return false;
    const uintptr_t origin = cachedListCell ? cachedListCell : boundSelectedCell;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cachedComposerOpenAt > 0 && origin == cachedComposerOpenOrigin
        && now - cachedComposerOpenAt < 0.20)
        return cachedComposerOpen;
    cachedComposerOpen = !windowShowsDiscoverPage() && listShowsSelectedMarkedChat();
    cachedComposerOpenAt = now;
    cachedComposerOpenOrigin = origin;
    return cachedComposerOpen;
}

void logComposer(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void logComposer(NSString *format, ...) {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastComposerLog < 2.0) return;
    lastComposerLog = now;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    YMLog(@"[SessionMark] %@", line);
}

void logDrop(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void logDrop(NSString *format, ...) {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastDropLog < 2.0) return;
    lastDropLog = now;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    YMLog(@"[SessionMark] %@", line);
}

YMSessionMarkLayer *ensureLayer(YMSessionMarkLayer *__strong &slot, NSInteger kind) {
    if (!slot) {
        slot = [[YMSessionMarkLayer alloc] initWithFrame:NSZeroRect];
        slot.kind = kind;
        slot.wantsLayer = YES;
        slot.layer.actions = @{
            @"position": NSNull.null,
            @"bounds": NSNull.null,
            @"hidden": NSNull.null,
            @"sublayers": NSNull.null,
            @"contents": NSNull.null,
            @"onOrderIn": NSNull.null,
            @"onOrderOut": NSNull.null
        };
    }
    return slot;
}

void attach(YMSessionMarkLayer *layer, NSView *host, NSRect frame, bool allowAttach) {
    if (!layer || !host) return;
    NoAnimation silent;
    if (layer.superview != host) {
        if (!allowAttach) return;
        [host addSubview:layer positioned:NSWindowAbove relativeTo:nil];
    }
    if (!NSEqualRects(layer.frame, frame)) layer.frame = frame;
    layer.hidden = NO;
}

void hideLayer(YMSessionMarkLayer *layer) {
    if (!layer) return;
    NoAnimation silent;
    layer.hidden = YES;
}

void detachSet(OverlaySet &set) {
    auto detach = [](YMSessionMarkLayer *layer) {
        if (!layer) return;
        NoAnimation silent;
        [layer removeFromSuperview];
        layer.hidden = YES;
    };
    detach(set.border);
    detach(set.placeholder);
    set.session = nil;
}

void drop(uintptr_t widget) {
    auto it = overlays.find(widget);
    if (it == overlays.end()) return;
    detachSet(it->second);
    overlays.erase(it);
}

void dropOtherComposerKeys(uintptr_t keep) {
    std::vector<uintptr_t> dead;
    for (const auto &entry : overlays) {
        if (entry.first == keep || !entry.second.composer) continue;
        dead.push_back(entry.first);
    }
    for (uintptr_t widget : dead) drop(widget);
}

void paintCell(uintptr_t widget) {
    if (!cellPaintReady || !widgetVisible(widget) || !sessionListCell(widget)) return;
    NSString *session = sessionFromCell(widget);
    NSDictionary *mark = YMSessionMarkLookup(YMAppearanceAccount(), session);
    const bool selected = cellNativeSelected(widget);
    if (!mark) return;
    Rect item;
    if (!widgetRect(widget, item) || item.height < 20 || item.width < 40) return;
    alignas(16) uint8_t painter[16] = {};
    ((void (*)(void *, void *))YMRuntimeAddress(native->painterConstruct))(painter, (uint8_t *)widget + 0x10);
    if (selected) {
        const BOOL dark = [NSApp.effectiveAppearance.name containsString:@"Dark"];
        fillColor(painter, 0, 0, item.width - 1, item.height - 1, dark ? 0x2C2C2C : 0xF5F5F5, 1.0);
    }
    uint32_t rgb = YMSessionMarkParseColor(mark[@"color"], YMSessionMarkDefaultColorRGB);
    const CGFloat wash = YMSessionMarkClampWash(
        [mark[@"wash"] respondsToSelector:@selector(doubleValue)]
            ? [mark[@"wash"] doubleValue] : YMSessionMarkWashDefault);
    const uint32_t glow = YMSessionMarkFluorescentRGB(rgb);
    fillColor(painter, 0, 0, item.width - 1, item.height - 1, glow, wash);
    if (selected) paintSelectedCorners(painter, item.width, item.height, glow);
    ((void (*)(void *))YMRuntimeAddress(native->painterDestruct))(painter);
}

NSView *nativeListView(uintptr_t widget) {
    const uintptr_t native = widgetNative(widget);
    if (!native) return nil;
    NSView *view = (__bridge NSView *)(void *)native;
    @try {
        if (![view isKindOfClass:NSView.class] || !viewHostWindow(view)) return nil;
        if (NSWidth(view.bounds) < 160 || NSHeight(view.bounds) < 200) return nil;
        return view;
    } @catch (NSException *) { return nil; }
}

NSView *sessionListFallback(void) {
    Class qns = NSClassFromString(@"QNSView");
    NSWindow *window = mainChatWindow();
    if (!qns || !window) return nil;
    NSView *best = nil;
    CGFloat bestHeight = 0;
    std::function<void(NSView *, unsigned)> walk = [&](NSView *view, unsigned depth) {
        if (!view || depth > 24) return;
        if ([view isKindOfClass:qns]) {
            NSRect win = [view convertRect:view.bounds toView:nil];
            if (NSMinX(win) < 320 && NSWidth(win) >= 160 && NSWidth(win) <= 400 &&
                NSHeight(win) >= 200 && NSHeight(win) > bestHeight) {
                best = view;
                bestHeight = NSHeight(win);
            }
        }
        for (NSView *child in view.subviews) walk(child, depth + 1);
    };
    NSView *root = window.contentView;
    while (root.superview) root = root.superview;
    walk(root, 0);
    return best;
}

void rememberSessionList(uintptr_t cell) {
    if (sessionListView) {
        @try { if (sessionListView.window) return; } @catch (NSException *) {}
        sessionListView = nil;
    }
    uintptr_t current = cell;
    NSView *sized = nil;
    for (int depth = 0; current && depth < 16; ++depth) {
        Rect rect{};
        if (!sized && widgetRect(current, rect) &&
            rect.width >= 160 && rect.width <= 400 && rect.height >= 200) {
            sized = nativeListView(current);
        }
        current = parentWidget(current);
    }
    if (sized) {
        sessionListView = sized;
        return;
    }
    if (NSView *view = nativeListView(cell)) {
        if (NSWidth(view.bounds) <= 400) sessionListView = view;
    }
}

void markViewDirty(NSView *view) {
    if (!view) return;
    view.needsDisplay = YES;
    if (view.layer) [view.layer setNeedsDisplay];
}

void invalidateSessionList(void) {
    if (!NSThread.isMainThread) return;
    // QNSView 重绘可能复用旧画面；让每个可见 Qt 行重新执行 paintEvent。
    if (native) {
        auto update = (void (*)(void *))YMRuntimeAddress(native->widgetUpdate);
        for (uintptr_t cell : visibleSessionCells()) update((void *)cell);
    }
    NSView *view = sessionListView;
    @try {
        if (!view || !view.window) {
            sessionListView = sessionListFallback();
            view = sessionListView;
        }
    } @catch (NSException *) {
        sessionListView = nil;
        view = nil;
    }
    if (!view) return;
    @try {
        markViewDirty(view);
        if (view.superview) markViewDirty(view.superview);
        for (NSView *child in view.subviews) markViewDirty(child);
        [view displayIfNeeded];
    } @catch (NSException *) {}
}

void dropComposerOverlays(void) {
    std::vector<uintptr_t> keys;
    keys.reserve(overlays.size());
    for (const auto &entry : overlays) keys.push_back(entry.first);
    for (uintptr_t key : keys) drop(key);
    jobs.clear();
    openSession = nil;
    cachedTitleSession = nil;
    cachedTitleAt = 0;
    cachedComposer = 0;
    boundSelectedCell = 0;
    cachedEmptyField = 0;
    cachedEmptyAt = 0;
    cachedEmpty = true;
    cachedStrip = nil;
    cachedStripSize = NSZeroSize;
    cachedStripWindowSize = NSZeroSize;
    cachedStripAt = 0;
    lastDiscover = 0;
    selectedMarkedThisTurn = false;
    selectedFolderThisTurn = false;
    pendingDropSession = nil;
    composerClosed = true;
    invalidateComposerOpenCache();
    stopFollow();
}

void flushComposerDecision(void) {
    const BOOL bind = selectedMarkedThisTurn;
    const BOOL folder = selectedFolderThisTurn;
    const BOOL openMarked = openSession.length &&
        YMSessionMarkLookup(YMAppearanceAccount(), openSession) != nil;
    NSString *session = pendingDropSession;
    selectedMarkedThisTurn = false;
    selectedFolderThisTurn = false;
    pendingDropSession = nil;
    // 本轮已着色选中格优先于拆；只选中文件夹或未标记格才拆。
    if (bind) return;
    const BOOL dropPending = folder || YMSessionMarkComposerShouldDropPending(
        openSession, openMarked, session, NO);
    if (!dropPending) return;
    logDrop(@"drop composer selected session=%@", session);
    dropComposerOverlays();
}

void hideAll(void) {
    dropComposerOverlays();
    lastDiscover = 0;
    clearNativeOwner();
}

bool composerEmptyCached(uintptr_t field) {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (field && field == cachedEmptyField && now - cachedEmptyAt < 0.25) return cachedEmpty;
    cachedEmptyField = field;
    cachedEmptyAt = now;
    cachedEmpty = composerIsEmpty(field);
    return cachedEmpty;
}

bool applyComposer(uintptr_t widget, NSDictionary *mark, NSString *session, bool allowAttach) {
    if (!composerChatOpen()) return false;
    NSView *strip = composerStripView();
    const bool qt = looksLikeQWidget(widget);
    uintptr_t chromeWidget = qt ? inputChrome(widget) : 0;
    NSView *fieldHost = nil;
    NSRect fieldFrame = NSZeroRect;
    OverlaySet *existing = overlays.count(widget) ? &overlays[widget] : nullptr;
    auto keepHidden = [&]() {
        if (!existing) return false;
        hideLayer(existing->border);
        hideLayer(existing->placeholder);
        return true;
    };
    bool vis = qt ? (widgetVisible(widget) || widgetVisible(chromeWidget)) : strip != nil;
    bool mapped = qt && mapComposerSurface(widget, &fieldHost, &fieldFrame);
    if (mapped && hostUsable(fieldHost)
        && YMSessionMarkComposerOverlaySized(NSWidth(fieldFrame), NSHeight(fieldFrame)))
        vis = true;
    if (qt && (!inComposerStrip(widget) && !inComposerStrip(chromeWidget))) {
        Rect identityRect{};
        bool identity = fieldSession(widget, nullptr)
            && widgetRect(widget, identityRect)
            && YMSessionMarkComposerOverlaySized(identityRect.width, identityRect.height);
        if (!identity && geometryComposerCandidate(widget))
            identity = true;
        if (!identity && chromeWidget && geometryComposerCandidate(chromeWidget))
            identity = true;
        if (!identity) {
            mapped = false;
            fieldHost = nil;
        }
    }
    if (mapped && !YMSessionMarkComposerOverlaySized(NSWidth(fieldFrame), NSHeight(fieldFrame))) {
        mapped = false;
        fieldHost = nil;
    }
    if (mapped && fieldHost) {
        NSWindow *mappedWindow = viewHostWindow(fieldHost);
        if (!mappedWindow) mappedWindow = fieldHost.window;
        if (mappedWindow && !hostWindowIsMainChat(mappedWindow)) {
            mapped = false;
            fieldHost = nil;
        }
    }
    if (!mapped || !hostUsable(fieldHost)) {
        NSView *inner = innerComposerField(strip);
        if (inner && hostUsable(inner)
            && YMSessionMarkComposerStripTypingSized(NSWidth(inner.bounds), NSHeight(inner.bounds)) &&
            (!inner.window || hostWindowIsMainChat(inner.window))) {
            fieldHost = inner;
            fieldFrame = inner.bounds;
            mapped = true;
            vis = true;
        }
    }
    if (!vis) {
        Rect hideRect{};
        widgetRect(widget, hideRect);
        logComposer(@"apply hide vis=0 qt=%d size=%.0fx%.0f mapped=%d strip=%@ title=%@",
            (int)qt, (CGFloat)hideRect.width, (CGFloat)hideRect.height, (int)mapped,
            strip ? NSStringFromSize(strip.bounds.size) : @"",
            fieldHost.window.title.length ? fieldHost.window.title
                : (strip.window.title.length ? strip.window.title : @""));
        return keepHidden();
    }
    if (!mapped || !hostUsable(fieldHost)
        || !YMSessionMarkComposerOverlaySized(NSWidth(fieldFrame), NSHeight(fieldFrame))) {
        logComposer(@"apply miss mapped=%d host=%@ visWin=%d frame=%.0fx%.0f strip=%@ title=%@",
            (int)mapped, fieldHost ? NSStringFromClass(fieldHost.class) : @"",
            fieldHost.window.visible ? 1 : 0,
            fieldFrame.size.width, fieldFrame.size.height,
            strip ? NSStringFromSize(strip.bounds.size) : @"",
            fieldHost.window.title.length ? fieldHost.window.title
                : (strip.window.title.length ? strip.window.title : @""));
        return keepHidden();
    }
    const NSRect mappedFrame = fieldFrame;
    fieldFrame = clipComposerFrame(fieldHost, fieldFrame, qt ? widget : 0);
    if (!YMSessionMarkComposerOverlaySized(NSWidth(fieldFrame), NSHeight(fieldFrame))) {
        logComposer(@"apply clip session-info panel mapped=%.0fx%.0f",
            mappedFrame.size.width, mappedFrame.size.height);
        return keepHidden();
    }
    OverlaySet &set = overlays[widget];
    set.composer = true;
    set.session = session;
    uint32_t rgb = YMSessionMarkParseColor(mark[@"color"], YMSessionMarkDefaultColorRGB);
    const CGFloat chrome = YMSessionMarkClampAlpha(
        [mark[@"alpha"] respondsToSelector:@selector(doubleValue)]
            ? [mark[@"alpha"] doubleValue] : YMSessionMarkAlphaDefault);
    const CGFloat wash = YMSessionMarkClampWash(
        [mark[@"wash"] respondsToSelector:@selector(doubleValue)]
            ? [mark[@"wash"] doubleValue] : YMSessionMarkWashDefault);
    CGFloat radius = fieldHost.layer.cornerRadius > 1 ? fieldHost.layer.cornerRadius : 8;
    if ([mark[@"border"] boolValue]) {
        YMSessionMarkLayer *border = ensureLayer(set.border, 0);
        const bool restyle = border.rgb != rgb || border.chromeAlpha != chrome
            || border.cornerRadius != radius || border.hidden;
        border.rgb = rgb;
        border.chromeAlpha = chrome;
        border.clipsToBounds = NO;
        border.cornerRadius = radius;
        attach(border, fieldHost, fieldFrame, allowAttach);
        if (restyle) border.needsDisplay = YES;
    } else hideLayer(set.border);
    const bool empty = qt ? composerEmptyCached(widget)
        : !nsTextHasContent(fieldHost, fieldHost, fieldFrame, 0);
    if (empty) {
        YMSessionMarkLayer *placeholder = ensureLayer(set.placeholder, 1);
        NSString *text = YMSessionMarkPlaceholderText(mark);
        const CGFloat fontSize = YMSessionMarkClampPlaceholderSize([mark[@"placeholderSize"] doubleValue]);
        const uint32_t textRGB = YMSessionMarkParseColor(mark[@"placeholderColor"], YMSessionMarkDefaultPlaceholderRGB);
        const uint32_t glowRgb = YMSessionMarkFluorescentRGB(rgb);
        const bool restyle = placeholder.hidden || placeholder.rgb != glowRgb
            || placeholder.washAlpha != wash || placeholder.cornerRadius != radius
            || placeholder.fontSize != fontSize || placeholder.textRGB != textRGB
            || ![placeholder.text isEqual:text];
        placeholder.text = text;
        placeholder.fontSize = fontSize;
        placeholder.textRGB = textRGB;
        placeholder.rgb = glowRgb;
        placeholder.washAlpha = wash;
        placeholder.cornerRadius = radius;
        placeholder.clipsToBounds = YES;
        attach(placeholder, fieldHost, NSInsetRect(fieldFrame, 2, 2), allowAttach);
        if (restyle) placeholder.needsDisplay = YES;
    } else hideLayer(set.placeholder);
    if (fabs(NSWidth(mappedFrame) - NSWidth(fieldFrame)) > 0.5) {
        logComposer(@"apply ok session=%@ host=%.0fx%.0f mapped=%.0fx%.0f clip title=%@ empty=%d",
            session, fieldFrame.size.width, fieldFrame.size.height,
            mappedFrame.size.width, mappedFrame.size.height,
            fieldHost.window.title.length ? fieldHost.window.title : @"",
            (int)empty);
    } else {
        logComposer(@"apply ok session=%@ host=%.0fx%.0f title=%@ empty=%d",
            session, fieldFrame.size.width, fieldFrame.size.height,
            fieldHost.window.title.length ? fieldHost.window.title : @"",
            (int)empty);
    }
    return true;
}

bool syncWidget(uintptr_t widget, bool composer, bool allowAttach) {
    NSString *session = nil;
    if (composer) {
        if (looksLikeQWidget(widget)) session = sessionFromField(widget);
        if (!session.length && overlays.count(widget)) session = overlays[widget].session;
        if (!session.length) session = openSession;
    } else {
        session = sessionFromCell(widget);
    }
    NSDictionary *mark = YMSessionMarkLookup(YMAppearanceAccount(), session);
    if (!mark) return false;
    if (!composer) {
        drop(widget);
        return false;
    }
    return applyComposer(widget, mark, session, allowAttach);
}

void stopFollow() {
    [followTimer invalidate];
    followTimer = nil;
    if (scrollMonitor) {
        [NSEvent removeMonitor:scrollMonitor];
        scrollMonitor = nil;
    }
    if (windowObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:windowObserver];
        windowObserver = nil;
    }
}

void ymViewWillDraw(NSView *self, SEL sel) {
    if (origViewWillDraw) origViewWillDraw(self, sel);
    if (overlays.empty()) return;
    for (auto &entry : overlays) {
        OverlaySet &set = entry.second;
        auto hosted = [&](YMSessionMarkLayer *layer) { return layer && layer.superview == self; };
        if (hosted(set.border) || hosted(set.placeholder)) {
            refreshFrames(false);
            break;
        }
    }
}

void installHostHook() {
    if (hostHooked) return;
    Class cls = NSClassFromString(@"QNSView");
    if (!cls) return;
    const SEL sel = @selector(viewWillDraw);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    origViewWillDraw = (void (*)(NSView *, SEL))method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, sel, (IMP)ymViewWillDraw, types)) {
        origViewWillDraw = (void (*)(NSView *, SEL))method_setImplementation(
            class_getInstanceMethod(cls, sel), (IMP)ymViewWillDraw);
    }
    hostHooked = YES;
}

void queueFollow() {
    if (followQueued) return;
    followQueued = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        followQueued = false;
        refreshFrames(true);
    });
}

void startFollow() {
    if (!live() || overlays.empty()) return;
    installHostHook();
    if (followTimer) return;
    followTimer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (!NSApp.isActive) return;
        refreshFrames(true);
    }];
    followTimer.tolerance = 0.05;
    [[NSRunLoop mainRunLoop] addTimer:followTimer forMode:NSRunLoopCommonModes];
    if (!scrollMonitor)
        scrollMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
            handler:^NSEvent *(NSEvent *event) {
                geometryUntil = CFAbsoluteTimeGetCurrent() + 0.15;
                queueFollow();
                return event;
            }];
    if (!windowObserver)
        windowObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSWindowDidUpdateNotification object:nil queue:nil
            usingBlock:^(NSNotification *note) {
                if (CFAbsoluteTimeGetCurrent() > geometryUntil) return;
                NSWindow *window = note.object;
                for (auto &entry : overlays) {
                    OverlaySet &set = entry.second;
                    NSView *any = set.border ?: set.placeholder;
                    if (any.window == window) {
                        refreshFrames(true);
                        break;
                    }
                }
            }];
}

void refreshFrames(bool allowAttach) {
    if (!NSThread.isMainThread || refreshing) return;
    if (!live() || !composerChatOpen()) {
        hideAll();
        invalidateSessionList();
        return;
    }
    if (overlays.empty()) {
        stopFollow();
        return;
    }
    refreshing = YES;
    std::vector<uintptr_t> keys;
    keys.reserve(overlays.size());
    for (auto &entry : overlays) keys.push_back(entry.first);
    std::vector<uintptr_t> dead;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (uintptr_t widget : keys) {
        auto it = overlays.find(widget);
        if (it == overlays.end()) continue;
        Rect rect{};
        const bool haveRect = widgetRect(widget, rect);
        const CGFloat drawer = sampleDrawerAllowed(widget);
        const bool emptyDue = widget != cachedEmptyField || now - cachedEmptyAt >= 0.25;
        if (haveRect && widget == lastFollowWidget && !emptyDue
            && rect.x == lastFollowRect.x && rect.y == lastFollowRect.y
            && rect.width == lastFollowRect.width && rect.height == lastFollowRect.height
            && fabs(drawer - lastFollowDrawer) < 0.5)
            continue;
        if (!syncWidget(widget, it->second.composer, allowAttach)) {
            dead.push_back(widget);
            continue;
        }
        if (haveRect) {
            lastFollowWidget = widget;
            lastFollowRect = rect;
            lastFollowDrawer = drawer;
        }
    }
    for (uintptr_t widget : dead) drop(widget);
    refreshing = NO;
    if (overlays.empty()) stopFollow();
    else startFollow();
}

void flushJobs() {
    if (!NSThread.isMainThread) return;
    if (!live()) {
        hideAll();
        return;
    }
    flushComposerDecision();
    if (!live()) return;
    std::map<uintptr_t, Job> pending;
    pending.swap(jobs);
    for (auto &entry : pending) {
        Job &job = entry.second;
        if (!job.mark || !job.composer) {
            drop(job.widget);
            continue;
        }
        if (!applyComposer(job.widget, job.mark, job.session, true)) drop(job.widget);
    }
    if (overlays.empty()) stopFollow();
    else startFollow();
}

void touchFlush() {
    if (flushOpen) return;
    flushOpen = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            flushJobs();
        } @catch (NSException *) {
        } @finally {
            flushOpen = NO;
        }
    });
}

bool composerCacheValid(void) {
    if (!cachedComposer) return false;
    if (fieldSession(cachedComposer, nullptr)) return true;
    return openSession.length
        && YMSessionMarkLookup(YMAppearanceAccount(), openSession) != nil
        && composerSized(cachedComposer);
}

void bindOpenSession(NSString *session, uintptr_t field);

NSString *titleSessionCached(void) {
    NSString *session = sessionFromTitle();
    cachedTitleSession = YMSessionMarkIsSessionId(session) ? [session copy] : nil;
    cachedTitleAt = CFAbsoluteTimeGetCurrent();
    return cachedTitleSession;
}

void refreshOpenSession(void) {
    if (!cachedComposer || !widgetVisible(cachedComposer)) return;
    NSString *session = sessionFromField(cachedComposer);
    if (!session.length) return;
    if (cachedTitleSession.length && CFAbsoluteTimeGetCurrent() - cachedTitleAt < 0.25 &&
        ![cachedTitleSession isEqual:session])
        return;
    if (openSession.length && [openSession isEqual:session]) return;
    if (selectedMarkedThisTurn && openSession.length &&
        YMSessionMarkLookup(YMAppearanceAccount(), openSession) &&
        !YMSessionMarkLookup(YMAppearanceAccount(), session))
        return;
    bindOpenSession(session, cachedComposer);
}

void bindOpenSession(NSString *session, uintptr_t field) {
    if (!session.length) return;
    if (composerClosed || selectedFolderThisTurn) return;
    const bool sessionChanged = !openSession.length || ![openSession isEqual:session];
    openSession = [session copy];
    if (sessionChanged) {
        dispatch_async(dispatch_get_main_queue(), ^{ invalidateSessionList(); });
    }
    if (field && looksLikeQWidget(field)) cachedComposer = field;
    NSDictionary *mark = YMSessionMarkLookup(YMAppearanceAccount(), session);
    if (mark) composerClosed = false;
    NSView *strip = composerStripView();
    uintptr_t key = (field && looksLikeQWidget(field)) ? field
        : (strip ? (uintptr_t)(__bridge void *)strip : 0);
    if (!key) return;
    if (!mark) {
        if (selectedMarkedThisTurn) return;
        drop(key);
        return;
    }
    if (field && looksLikeQWidget(field)) dropOtherComposerKeys(key);
    if (!overlays.count(key) || sessionChanged) {
        jobs[key] = Job{key, true, session, mark};
        touchFlush();
    }
}

void bindComposer(uintptr_t field) {
    if (!field || !looksLikeQWidget(field)) return;
    NSString *session = sessionFromField(field);
    if (!session.length) session = openSession;
    if (!session.length) return;
    if (selectedMarkedThisTurn && openSession.length &&
        YMSessionMarkLookup(YMAppearanceAccount(), openSession) &&
        !YMSessionMarkLookup(YMAppearanceAccount(), session))
        return;
    bindOpenSession(session, field);
}

void ensureComposer(uintptr_t from) {
    if (selectedFolderThisTurn || !composerChatOpen()) return;
    if (composerCacheValid()) {
        bindComposer(cachedComposer);
        return;
    }
    NSView *strip = composerStripView();
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    const bool markedOpen = selectedMarkedThisTurn ||
        (openSession.length && YMSessionMarkLookup(YMAppearanceAccount(), openSession) != nil);
    const CFTimeInterval gap = (strip || markedOpen) ? 0.05 : 2.0;
    if (now - lastDiscover < gap) return;
    lastDiscover = now;
    if (from && inComposerStrip(from)) rememberNative(from);
    uintptr_t found = composerField(0);
    if (found) {
        NSString *fromField = sessionFromField(found);
        NSString *session = fromField.length ? fromField : openSession;
        if (!session.length) session = titleSessionCached();
        if (session.length && YMSessionMarkLookup(YMAppearanceAccount(), session)) {
            bindOpenSession(session, found);
            return;
        }
    }
    if (composerCacheValid()) {
        bindComposer(cachedComposer);
        return;
    }
    NSString *session = titleSessionCached();
    if (session.length && found) bindOpenSession(session, found);
}

void noteCell(uintptr_t widget) {
    Rect item;
    if (!widgetRect(widget, item) ||
        !YMSessionMarkSessionListCellSized(item.width, item.height))
        return;
    if (!inMainChatWindow(widget)) {
        logHostMiss(widget, item);
        return;
    }
    rememberSessionList(widget);
    cachedListCell = widget;
    if (cellNativeSelected(widget)) {
        freshSelectedCell=widget;freshSelectedAccount=YMAppearanceAccount();
        NSString *account = YMAppearanceAccount();
        NSString *accepted = sessionFromCell(widget);
        NSDictionary *mark = YMSessionMarkLookup(account, accepted);
        NSString *identity = mark ? nil : sessionFromHeadTree(widget, 0, false);
        if (cellLooksLikeFolderHolder(widget)) {
            identity = identity.length ? identity : @"brandsessionholder";
            mark = nil;
            accepted = nil;
        }
        switch (YMSessionMarkComposerActionForSelectedCell(
                    accepted, mark, identity, account, openSession)) {
            case YMSessionMarkComposerCellBind:
                if (selectedFolderThisTurn) break;
                selectedMarkedThisTurn = true;
                pendingDropSession = nil;
                composerClosed = false;
                invalidateComposerOpenCache();
                boundSelectedCell = widget;
                bindOpenSession(accepted, cachedComposer);
                ensureComposer(widget);
                break;
            case YMSessionMarkComposerCellDrop:
                invalidateComposerOpenCache();
                if (YMSessionMarkSessionIsFolderHolder(accepted)
                    || YMSessionMarkSessionIsFolderHolder(identity)) {
                    selectedFolderThisTurn = true;
                    if (!selectedMarkedThisTurn) {
                        composerClosed = true;
                        dropComposerOverlays();
                        selectedFolderThisTurn = true;
                    }
                }
                if (!selectedMarkedThisTurn && !pendingDropSession.length)
                    pendingDropSession = [(accepted.length ? accepted : identity) copy];
                touchFlush();
                break;
            default:
                break;
        }
    }
    paintCell(widget);
}

void notePanel(uintptr_t widget) {
    Rect rect;
    if (!widgetRect(widget, rect) || rect.width < 400) return;
    if (selectedFolderThisTurn || !composerChatOpen()) return;
    if (cachedComposer && overlays.count(cachedComposer)) return;
    if (!inMainChatWindow(widget)) {
        if (mainChatWindow()) ensureComposer(0);
        return;
    }
    if (composerCacheValid()) {
        bindComposer(cachedComposer);
        return;
    }
    if (NSString *title = titleSessionCached()) {
        if (cachedComposer && widgetVisible(cachedComposer)) {
            NSString *field = sessionFromField(cachedComposer);
            if (field.length && ![field isEqual:title]) cachedComposer = 0;
        }
        if (!openSession.length || ![openSession isEqual:title])
            bindOpenSession(title, cachedComposer);
    }
    ensureComposer(widget);
}

void note(uintptr_t widget, bool panel) {
    if (!installed || !widget || !NSThread.isMainThread) return;
    if (!YMSessionMarkEnabled()) {
        // 首次启用时也需要定位已显示的会话行。
        if (!panel && sessionListCell(widget)) cachedListCell = widget;
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastHostMiss >= 2.0) {
            lastHostMiss = now;
            YMLog(@"[SessionMark] skip gate enabled=%d",
                (int)YMSessionMarkEnabled());
        }
        if (!overlays.empty() || followTimer) hideAll();
        return;
    }
    if (panel) notePanel(widget);
    else noteCell(widget);
}

} // namespace

BOOL YMSessionMarkSkipNativeCellPaint(void *widget) {
    // 已着色选中才跳过原生绿底；未标记选中走微信绿底和字体。
    @try {
        if (!installed || !widget || !YMSessionMarkEnabled()) return NO;
        if (!sessionListCell((uintptr_t)widget)) return NO;
        if (!cellNativeSelected((uintptr_t)widget)) return NO;
        NSString *session = sessionFromCell((uintptr_t)widget);
        if (!session.length) return NO;
        return YMSessionMarkLookup(YMAppearanceAccount(), session) != nil;
    } @catch (NSException *) { return NO; }
}

BOOL YMSessionMarkCellNativeSelected(void *widget) {
    @try { return installed && cellNativeSelected((uintptr_t)widget); }
    @catch (NSException *) { return NO; }
}

void YMSessionMarkNoteWidget(void *widget) {
    @try { note((uintptr_t)widget, false); }
    @catch (NSException *) {}
}

void YMSessionMarkNotePanelWidget(void *widget) {
    @try { note((uintptr_t)widget, true); }
    @catch (NSException *) {}
}

void YMInstallSessionMark(void) {
    if (installed) return;
    if (YMMatchesWeChat270353Dylib()) native = &layout270353;
    else return;
    static const uint8_t fillRectColor[20] = {
        0xff, 0x03, 0x01, 0xd1, 0xf4, 0x4f, 0x02, 0xa9,
        0xfd, 0x7b, 0x03, 0xa9, 0xfd, 0xc3, 0x00, 0x91,
        0x08, 0x00, 0x40, 0xf9
    };
    static const uint8_t constructBytes[] = {0xde,0x06,0x00,0x14};
    static const uint8_t destructBytes[] = {0x88,0x06,0x00,0x14};
    cellPaintReady = matchPrologue(native->painterConstruct, constructBytes, sizeof constructBytes) &&
        matchPrologue(native->painterDestruct, destructBytes, sizeof destructBytes) &&
        matchPrologue(native->painterFillRectColor, fillRectColor, sizeof fillRectColor);
    if (!cellPaintReady ||
        !matchPrologue(native->textControlPlain, native->textControlBytes, sizeof native->textControlBytes) ||
        !matchPrologue(native->textDocumentPlain, kTextDocumentPlainBytes, sizeof kTextDocumentPlainBytes) ||
        !matchPrologue(native->stringDestruct, kQStringDestructBytes, sizeof kQStringDestructBytes) ||
        !matchPrologue(native->widgetUpdate, kWidgetUpdateBytes, sizeof kWidgetUpdateBytes)) {
        native = nullptr;
        cellPaintReady = false;
        YMLog(@"[SessionMark] 原生接口校验失败，保留微信原生显示");
        return;
    }
    installed = true;
    YMSessionMarkRegisterDefaults();
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:YMSessionMarkChangedNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            (void)notification;
            invalidateComposerOpenCache();
            refreshFrames(true);
            invalidateSessionList();
        }];
    YMLog(@"[SessionMark] 会话标识叠层已安装");
}

NSString *YMSessionMarkReadOpenSession(void) {
    if(!NSThread.isMainThread || !installed || !native) return nil;
    @try { try {
        NSWindow *main=mainChatWindow();
        if(!main || !NSApp.keyWindow || (NSApp.keyWindow!=main && !hostWindowIsMainChat(NSApp.keyWindow)) || !main.visible || main.miniaturized || main.attachedSheet) return nil;
        NSString *title=sessionFromTitle(),*fieldSessionID=nil;
        uintptr_t field=cachedComposer;
        if(!field || !widgetVisible(field) || !inMainChatWindow(field) || !fieldSession(field,&fieldSessionID)) {
            field=composerField(0);fieldSessionID=nil;
            if(!field || !widgetVisible(field) || !inMainChatWindow(field) || !fieldSession(field,&fieldSessionID))fieldSessionID=nil;
        }
        // Read the live input field; never trust a previously selected session.
        if(title.length && fieldSessionID.length && ![title isEqual:fieldSessionID])return nil;
        if(fieldSessionID.length || title.length)return fieldSessionID.length ? fieldSessionID:title;
        // Revalidate the native selection bit and identity on every read; no cached session string.
        if([freshSelectedAccount isEqual:YMAppearanceAccount()] && looksLikeQWidget(freshSelectedCell) &&
            widgetVisible(freshSelectedCell) && cellNativeSelected(freshSelectedCell) && inMainChatWindow(freshSelectedCell) && !cellLooksLikeFolderHolder(freshSelectedCell))
            return sessionFromCell(freshSelectedCell);
        return nil;
    } catch (...) { return nil; } } @catch(NSException *) { return nil; }
}
NSRect YMSessionMarkChatPaneBounds(NSWindow *window){
    NSRect area=window.contentView.bounds;
    if(!NSThread.isMainThread || !installed || !window)return area;
    @try {try{
        if(![freshSelectedAccount isEqual:YMAppearanceAccount()] || !looksLikeQWidget(freshSelectedCell) || !widgetVisible(freshSelectedCell) || !cellNativeSelected(freshSelectedCell))return area;
        NSView *host=nil;NSRect frame=NSZeroRect;
        if(!mapSelf(freshSelectedCell,&host,&frame) || !host.window)return area;
        NSRect screen=[host.window convertRectToScreen:[host convertRect:frame toView:nil]];
        NSRect local=[window.contentView convertRect:[window convertRectFromScreen:screen] fromView:nil];
        CGFloat left=NSMaxX(local);
        if(NSMinX(local)>=NSMinX(area)-1 && NSWidth(local)>=100 && NSWidth(local)<=450 && left>NSMinX(area) && NSMaxX(area)-left>=260){area.origin.x=left;area.size.width=NSMaxX(window.contentView.bounds)-left;}
    }catch(...){}}@catch(NSException *){}
    return area;
}
BOOL YMSessionMarkAvailable(void) { return installed; }

#else
void YMSessionMarkNoteWidget(void *widget) { (void)widget; }
void YMSessionMarkNotePanelWidget(void *widget) { (void)widget; }
void YMInstallSessionMark(void) {}
NSRect YMSessionMarkChatPaneBounds(NSWindow *window){return window.contentView.bounds;}
BOOL YMSessionMarkAvailable(void) { return NO; }
NSString *YMSessionMarkReadOpenSession(void) { return nil; }
BOOL YMSessionMarkSkipNativeCellPaint(void *widget) { (void)widget; return NO; }
BOOL YMSessionMarkCellNativeSelected(void *widget) { (void)widget; return NO; }
#endif

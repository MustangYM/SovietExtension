#import "ChatPaneClip.h"
#import <mach/mach.h>
#import <mach/mach_vm.h>
#include <algorithm>
#include <cstdlib>
#include <vector>

namespace {

bool readBytes(uintptr_t address, void *out, size_t size) {
    mach_vm_size_t copied = 0;
    return address && size && address <= UINTPTR_MAX - size &&
        mach_vm_read_overwrite(mach_task_self(), address, size,
            reinterpret_cast<mach_vm_address_t>(out), &copied) == KERN_SUCCESS && copied == size;
}

template <class T>
bool read(uintptr_t address, T &out) {
    return readBytes(address, &out, sizeof out);
}

bool widgetChildren(uintptr_t widget, std::vector<uintptr_t> &children) {
    // ARM 4.1.11/269079 and 4.2.0/270353: QWidget +8 -> QWidgetPrivate, +0x18 -> children
    // vector header, begin/end at +8/+0xc, entries at +0x10. ARM private +0x10
    // is QObjectData::parent; do not apply Intel's QWidgetPrivate self/owner
    // check here or every non-root child is lost.
    uintptr_t priv = 0, header = 0;
    int32_t begin = 0, end = 0;
    if (!read(widget + 8, priv) || !read(priv + 0x18, header) ||
        !read(header + 8, begin) || !read(header + 12, end) ||
        begin < 0 || end < begin || end - begin > 256 || end > 65536) return false;
    children.resize(end - begin);
    return children.empty() || readBytes(header + 16 + uintptr_t(begin) * 8,
        children.data(), children.size() * sizeof(uintptr_t));
}

bool visibleWidgetRect(uintptr_t widget, uintptr_t parent, NSRect &rect) {
    uintptr_t priv = 0, actualParent = 0, data = 0;
    uint32_t flags = 0;
    int32_t bounds[4] = {};
    if (!read(widget + 8, priv) || !read(priv + 0x10, actualParent) || actualParent != parent ||
        !read(widget + 0x28, data) || !read(data + 8, flags) || !(flags & 0x8000) ||
        !readBytes(data + 0x14, bounds, sizeof bounds)) return false;
    const int64_t width = int64_t(bounds[2]) - bounds[0] + 1;
    const int64_t height = int64_t(bounds[3]) - bounds[1] + 1;
    if (width < 1 || height < 1 || width > 32768 || height > 32768 ||
        std::llabs(int64_t(bounds[0])) > 65536 || std::llabs(int64_t(bounds[1])) > 65536)
        return false;
    rect = NSMakeRect(bounds[0], bounds[1], width, height);
    return true;
}

} // namespace

BOOL YMChatPaneDrawerLayerSized(CGFloat width, CGFloat height) {
    // 打开动画中宽度从 0 涨到约 280，160 才认会整段盖住抽屉再突然收缩。
    return width >= 48 && height >= 250;
}

BOOL YMChatPaneDrawerPanelFitsLayer(NSRect panel, NSRect layer) {
    if (NSWidth(panel) < 120) return NO;
    if (NSMinX(panel) <= 0 || NSMinY(panel) > 8) return NO;
    if (NSMaxX(panel) < NSWidth(layer) - 2) return NO;
    if (NSMaxY(panel) < NSHeight(layer) - 8) return NO;
    return YES;
}

BOOL YMChatPaneDrawerDividerFits(NSRect line, CGFloat edge, NSRect panel) {
    return NSWidth(line) <= 8
        && NSMaxX(line) >= edge
        && NSMinX(line) <= edge
        && NSHeight(line) >= NSHeight(panel) - 1;
}

CGFloat YMChatPaneDrawerAllowedWidth(NSRect layer, CGFloat edge) {
    return NSMinX(layer) + edge;
}

NSRect YMChatPaneDrawerClipBounds(NSRect pageBounds, CGFloat allowedWidth) {
    return NSIntersectionRect(pageBounds, NSMakeRect(0, 0, allowedWidth, NSHeight(pageBounds)));
}

BOOL YMChatPaneDrawerClip(uintptr_t page, uintptr_t branch, NSRect pageBounds,
                          NSRect *clip, BOOL *hasDrawer) {
    if (!clip || !hasDrawer) return NO;
    *clip = pageBounds;
    *hasDrawer = NO;
    std::vector<uintptr_t> siblings;
    if (!widgetChildren(page, siblings)) return NO;
    const auto position = std::find(siblings.begin(), siblings.end(), branch);
    if (position == siblings.end()) return NO;
    for (auto next = position + 1; next != siblings.end(); ++next) {
        NSRect layer;
        if (!visibleWidgetRect(*next, page, layer) ||
            !YMChatPaneDrawerLayerSized(NSWidth(layer), NSHeight(layer))) continue;
        std::vector<uintptr_t> panels;
        if (!widgetChildren(*next, panels)) continue;
        for (const auto panel : panels) {
            NSRect bounds;
            if (!visibleWidgetRect(panel, *next, bounds) ||
                !YMChatPaneDrawerPanelFitsLayer(bounds, layer)) continue;
            CGFloat edge = NSMinX(bounds);
            for (const auto border : panels) {
                NSRect line;
                if (visibleWidgetRect(border, *next, line) &&
                    YMChatPaneDrawerDividerFits(line, edge, bounds))
                    edge = MIN(edge, NSMinX(line));
            }
            const CGFloat allowedWidth = YMChatPaneDrawerAllowedWidth(layer, edge);
            if (allowedWidth <= 0 || allowedWidth > NSWidth(pageBounds) + 2) continue;
            *clip = YMChatPaneDrawerClipBounds(*clip, allowedWidth);
            *hasDrawer = YES;
        }
    }
    return YES;
}

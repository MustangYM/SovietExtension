#import <AppKit/AppKit.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// 聊天页右侧群资料抽屉：后出现的同级图层，宽≥48、高≥250（含打开动画），
// 里面有贴满高度的内栏和 ≤8pt 竖线。祖先裁切和 QWidget::visibleRegion 看不到这一层。
// 语音气泡、会话标识输入叠层、群身份角标共用这一套，不按 160–400 猜面板。

FOUNDATION_EXPORT BOOL YMChatPaneDrawerLayerSized(CGFloat width, CGFloat height);
FOUNDATION_EXPORT BOOL YMChatPaneDrawerPanelFitsLayer(NSRect panel, NSRect layer);
FOUNDATION_EXPORT BOOL YMChatPaneDrawerDividerFits(NSRect line, CGFloat edge, NSRect panel);
FOUNDATION_EXPORT CGFloat YMChatPaneDrawerAllowedWidth(NSRect layer, CGFloat edge);
FOUNDATION_EXPORT NSRect YMChatPaneDrawerClipBounds(NSRect pageBounds, CGFloat allowedWidth);
FOUNDATION_EXPORT BOOL YMChatPaneDrawerClip(uintptr_t page, uintptr_t branch, NSRect pageBounds,
    NSRect *clip, BOOL *hasDrawer);

NS_ASSUME_NONNULL_END

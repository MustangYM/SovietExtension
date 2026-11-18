#import <AppKit/AppKit.h>

FOUNDATION_EXPORT void YMInstallSessionMark(void);
FOUNDATION_EXPORT BOOL YMSessionMarkAvailable(void);
FOUNDATION_EXPORT void YMSessionMarkNoteWidget(void *widget);
FOUNDATION_EXPORT void YMSessionMarkNotePanelWidget(void *widget);
FOUNDATION_EXPORT BOOL YMSessionMarkSkipNativeCellPaint(void *widget);
FOUNDATION_EXPORT BOOL YMSessionMarkCellNativeSelected(void *widget);

// Main-thread, current main chat only. Unknown/utility/independent windows return nil.
FOUNDATION_EXPORT NSString *YMSessionMarkReadOpenSession(void);

// In content-view coordinates; excludes the native session list when its geometry is available.
FOUNDATION_EXPORT NSRect YMSessionMarkChatPaneBounds(NSWindow *window);

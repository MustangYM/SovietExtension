#import <AppKit/AppKit.h>

// Presentation only. These components never read or write plugin preferences.
@interface YMAssistantSurface : NSView
@property BOOL separatorOnly;
@property BOOL hoverEnabled;
@end
FOUNDATION_EXPORT NSTextField *YMUIlabel(NSString *text, CGFloat size, BOOL secondary, NSRect frame);
FOUNDATION_EXPORT void YMUIConfigureWindow(NSWindow *window);
FOUNDATION_EXPORT NSButton *YMUIButton(NSString *title, id target, SEL action, NSRect frame, BOOL primary);

@interface YMUITimestampEditor : NSView
@property NSButton *enabled;
@property NSPopUpButton *format;
@property NSColorWell *colorWell;
- (void)refreshPreview:(id)sender;
@end

// Apply only to assistant-owned views/windows at their explicit presentation sites.
FOUNDATION_EXPORT void YMUIApplyView(NSView *view);
FOUNDATION_EXPORT void YMUIApplyWindow(NSWindow *window);
FOUNDATION_EXPORT YMAssistantSurface *YMUIAddSurface(NSView *parent, NSRect frame);
@interface YMAssistantFloatingView : NSVisualEffectView
@end

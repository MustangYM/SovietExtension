//  ThemeHook.m
//  SovietExtension
//
//  Created by MustangYM on 2026/6/20.
//

#import "ModernThemeHook.h"
#import "WeChatCompatibility.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <math.h>
#import <sys/mman.h>
#import "RevokePatch.h"
#import "MistyModeSettingsWindowController.h"
#import "YMColorfulBlurBackgroundView.h"
#import "YMThemeImageStore.h"
#import "RoundedAvatarSettingsWindowController.h"
#import "SessionMarkOverlay.h"
#include <atomic>
#include <cstring>

#pragma mark - 默认值
static const BOOL kYMDefaultMistyModeEnabled = NO;
static const CGFloat kYMDefaultBackgroundTransparency = 0.90f;
static const BOOL kYMDefaultWindowBackgroundBlurEnabled = YES;
static const int kYMDefaultWindowBackgroundBlurRadius = 10;

static const NSTimeInterval kYMBlurKeepAliveInterval = 10.0;

/// 流光氛围默认参数。
/// ColorfulOpacity 的深色/浅色现在统一使用一个值。
static const CGFloat kYMDefaultColorfulOpacity = 0.42f;
static const CGFloat kYMDefaultColorfulInternalBlurRadius = 70.0f;
static const CGFloat kYMMinColorfulInternalBlurRadius = 40.0f;
static const CGFloat kYMMaxColorfulInternalBlurRadius = 160.0f;
static const NSTimeInterval kYMDefaultColorfulAnimationDuration = 10.0;
static char kYMImagePatternCacheKey;
static char kYMImagePatternColorKey;

#pragma mark - 私有 CGS 接口声明

/// 这里不直接链接私有符号，而是运行时 dlsym，避免链接阶段报错。
typedef int YMCGSConnectionID;
typedef int YMCGSWindowID;
typedef int (*YMCGSMainConnectionIDFunc)(void);
typedef CGError (*YMCGSSetWindowBackgroundBlurRadiusFunc)(YMCGSConnectionID cid,
                                                          YMCGSWindowID wid,
                                                          int radius);

static YMCGSMainConnectionIDFunc gYMCGSMainConnectionID = NULL;
static YMCGSSetWindowBackgroundBlurRadiusFunc gYMCGSSetWindowBackgroundBlurRadius = NULL;
static BOOL gYMCGSBlurResolved = NO;
static BOOL gYMCGSBlurResolveFailedLogged = NO;

#pragma mark - 原始 IMP

typedef BOOL (*YMIsOpaqueIMP)(id self, SEL _cmd);
typedef void (*YMVoidIMP)(id self, SEL _cmd);
typedef void (*YMOneObjectIMP)(id self, SEL _cmd, id arg);

static YMIsOpaqueIMP gOrig_QNSView_isOpaque = NULL;
static YMVoidIMP gOrig_QNSView_viewDidMoveToWindow = NULL;
static YMVoidIMP gOrig_QNSView_viewDidMoveToSuperview = NULL;
static YMOneObjectIMP gOrig_QNSView_setLayer = NULL;

#pragma mark - 状态

static BOOL gYMStarted = NO;
static BOOL gYMQNSViewHookInstalled = NO;
static BOOL gYMQtBackgroundHookInstalled = NO;
static unsigned gYMQtLastRedrawHookMask = 0;
static NSString *gYMQtLastThemeSignature = nil;
static std::atomic_bool gYMQtBackgroundEnabled(false);
using YMQtPaintBackgroundIMP = void (*)(void *, void *, const void *, unsigned int);
static YMQtPaintBackgroundIMP gYMOriginalQtPaintBackground = nullptr;
using YMQtPainterCompositionModeIMP = int (*)(const void *);
using YMQtPainterSetCompositionModeIMP = void (*)(void *, int);
static YMQtPainterCompositionModeIMP gYMQtPainterCompositionMode = nullptr;
static YMQtPainterSetCompositionModeIMP gYMQtPainterSetCompositionMode = nullptr;
using YMQtPaintEventIMP = void (*)(void *, void *);
static YMQtPaintEventIMP gYMOriginalPanelPaintEvent = nullptr;
static YMQtPaintEventIMP gYMOriginalSessionCellPaintEvent = nullptr;
static YMQtPaintEventIMP gYMOriginalSearchFieldPaintEvent = nullptr;
static YMQtPaintEventIMP gYMOriginalXImageDraw = nullptr;
using YMQtOverlayPrepareIMP = void (*)(void *);
static YMQtOverlayPrepareIMP gYMOriginalImageGroupOverlay = nullptr;
using YMQtSetRoundTypeIMP = void (*)(void *, int);
using YMQtSetRadiusIMP = void (*)(void *, float);
static YMQtSetRoundTypeIMP gYMQtSetRoundType = nullptr;
static YMQtSetRadiusIMP gYMQtSetXRad = nullptr;
static YMQtSetRadiusIMP gYMQtSetYRad = nullptr;
using YMQtPainterConstructIMP = void (*)(void *, void *);
using YMQtPainterDestructIMP = void (*)(void *);
using YMQtPaletteBrushIMP = const void *(*)(const void *, int, int);
using YMQtPainterFillRectIMP = void (*)(void *, const void *, const void *);
static YMQtPainterConstructIMP gYMQtPainterConstruct = nullptr;
static YMQtPainterDestructIMP gYMQtPainterDestruct = nullptr;
static YMQtPaletteBrushIMP gYMQtPaletteBrush = nullptr;
static YMQtPainterFillRectIMP gYMQtPainterFillRect = nullptr;
static NSTimer *gYMBlurKeepAliveTimer = nil;
static NSHashTable *gYMModifiedThemeObjects;
static char kYMOriginalThemeStateKey;
static void YMRestoreThemeObject(id object);

/// 防止处理背景过程中触发 setLayer / view move 后递归。
static BOOL gYMApplyingBlurBackground = NO;

/// 用于记录窗口上一次应用的 blur radius，避免重复刷日志。
static char kYMAppliedBlurRadiusAssociatedKey;
static char kYMAppliedBlurWindowNumberAssociatedKey;

#pragma mark - 配置读取

static void YMRegisterMistyThemeDefaults(void) {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kThemeMistyMode: @(kYMDefaultMistyModeEnabled),
        kThemeMistyQNSAlpha: @(kYMDefaultBackgroundTransparency),
        kThemeMistyWindowBlurEnabled: @(kYMDefaultWindowBackgroundBlurEnabled),
        kThemeMistyWindowBlurRadius: @(kYMDefaultWindowBackgroundBlurRadius),
        kThemeMistyColorful: @(NO),
        kThemeMistyColorfulOpacity: @(kYMDefaultColorfulOpacity),
        kThemeMistyColorfulBlurRadius: @(kYMDefaultColorfulInternalBlurRadius),
        kThemeMistyColorfulAnimationDuration: @(kYMDefaultColorfulAnimationDuration),
        kThemeAppearanceMode: kThemeAppearanceMisty,
        kThemeBackgroundImageOpacity: @(0.88),
    }];
}

static BOOL YMBoolSetting(NSString *key, BOOL defaultValue) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) {
        return defaultValue;
    }
    return [defaults boolForKey:key];
}

static CGFloat YMFloatSetting(NSString *key, CGFloat defaultValue) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) {
        return defaultValue;
    }
    return (CGFloat)[defaults doubleForKey:key];
}

static NSInteger YMIntegerSetting(NSString *key, NSInteger defaultValue) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) {
        return defaultValue;
    }
    return [defaults integerForKey:key];
}

static BOOL YMMistyModeEnabled(void) {
    return YMBoolSetting(kThemeMistyMode, kYMDefaultMistyModeEnabled);
}

static NSString *YMThemeAppearanceMode(void) {
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:kThemeAppearanceMode];
    if ([@[kThemeAppearancePink, kThemeAppearanceImage] containsObject:mode]) return mode;
    return kThemeAppearanceMisty;
}

static BOOL YMWindowBackgroundBlurEnabled(void) {
    if (!YMMistyModeEnabled()) return NO;
    if (![YMThemeAppearanceMode() isEqualToString:kThemeAppearanceMisty]) return NO;
    return YMBoolSetting(kThemeMistyWindowBlurEnabled, kYMDefaultWindowBackgroundBlurEnabled);
}

static CGFloat YMBackgroundTransparency(void) {
    CGFloat transparency = YMFloatSetting(kThemeMistyQNSAlpha, kYMDefaultBackgroundTransparency);
    return MAX(0.0f, MIN(1.0f, transparency));
}

static int YMWindowBackgroundBlurRadius(void) {
    if (!YMWindowBackgroundBlurEnabled()) {
        return 0;
    }

    NSInteger radius = YMIntegerSetting(kThemeMistyWindowBlurRadius, kYMDefaultWindowBackgroundBlurRadius);
    radius = MAX(0, MIN(100, radius));
    return (int)radius;
}

static BOOL YMIsAppearanceDark(NSAppearance *appearance) {
    if (!appearance) {
        appearance = NSApp.effectiveAppearance ?: NSAppearance.currentAppearance;
    }

    NSString *bestMatch = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua,
        NSAppearanceNameDarkAqua
    ]];

    return [bestMatch isEqualToString:NSAppearanceNameDarkAqua];
}

BOOL YMModernCarrierStyleIsDark(void) {
    // 自动跟随当前微信 / AppKit 的有效外观，不再依赖手动“深色 / 浅色”配置。
    if (![NSThread isMainThread]) {
        __block BOOL dark = YES;
        dispatch_sync(dispatch_get_main_queue(), ^{
            dark = YMModernCarrierStyleIsDark();
        });
        return dark;
    }

    NSWindow *keyWindow = NSApp.keyWindow;
    if (keyWindow) {
        return YMIsAppearanceDark(keyWindow.effectiveAppearance);
    }

    NSWindow *mainWindow = NSApp.mainWindow;
    if (mainWindow) {
        return YMIsAppearanceDark(mainWindow.effectiveAppearance);
    }

    return YMIsAppearanceDark(NSApp.effectiveAppearance);
}

#pragma mark - Colorful 风格动态渐变背景

BOOL YMModernColorfulBlurBackgroundEnabled(void) {
    if (!YMMistyModeEnabled()) return NO;
    if (![YMThemeAppearanceMode() isEqualToString:kThemeAppearanceMisty]) return NO;
    if (!YMBoolSetting(kThemeMistyColorful, NO)) return NO;
    if (!YMWindowBackgroundBlurEnabled()) return NO;
    if (YMWindowBackgroundBlurRadius() <= 0) return NO;
    return YES;
}

CGFloat YMModernColorfulBlurBackgroundOpacity(void) {
    CGFloat opacity = YMFloatSetting(kThemeMistyColorfulOpacity, kYMDefaultColorfulOpacity);
    return MAX(0.0f, MIN(1.0f, opacity));
}

CGFloat YMModernColorfulBlurInternalBlurRadius(void) {
    CGFloat radius = YMFloatSetting(kThemeMistyColorfulBlurRadius, kYMDefaultColorfulInternalBlurRadius);
    return MAX(kYMMinColorfulInternalBlurRadius, MIN(kYMMaxColorfulInternalBlurRadius, radius));
}

NSTimeInterval YMModernColorfulAnimationDuration(void) {
    CGFloat duration = YMFloatSetting(kThemeMistyColorfulAnimationDuration, kYMDefaultColorfulAnimationDuration);
    return MAX(2.0f, MIN(60.0f, duration));
}

static YMColorfulBlurBackgroundView *YMFindColorfulBlurBackgroundViewInContainer(NSView *container) {
    if (!container) return nil;

    for (NSView *subview in container.subviews) {
        if ([subview.identifier isEqualToString:kYMColorfulBlurBackgroundViewIdentifier] &&
            [subview isKindOfClass:[YMColorfulBlurBackgroundView class]]) {
            return (YMColorfulBlurBackgroundView *)subview;
        }
    }

    return nil;
}

static void YMEnsureColorfulBlurBackgroundInContainer(NSView *container, NSView *qnsView) {
    if (!container || !qnsView) return;

    //过滤掉鼠标放到输入框右上角会开启狂暴模式彩蛋,哈哈哈
    if ([container.description containsString:@"FramelessMainWindowClassWindow"]) {
        return;
    }
    
    YMColorfulBlurBackgroundView *colorfulView = YMFindColorfulBlurBackgroundViewInContainer(container);

    if (!YMModernColorfulBlurBackgroundEnabled()) {
        if (colorfulView) {
            [colorfulView removeFromSuperview];
        }
        return;
    }

    if (!colorfulView) {
        colorfulView = [[YMColorfulBlurBackgroundView alloc] initWithFrame:container.bounds];
        [container addSubview:colorfulView positioned:NSWindowBelow relativeTo:qnsView];
        YMLog(@"已插入 Colorful 动态渐变背景 view：%@", colorfulView);
    } else {
        colorfulView.frame = container.bounds;
        if (colorfulView.superview != container) {
            [colorfulView removeFromSuperview];
            [container addSubview:colorfulView positioned:NSWindowBelow relativeTo:qnsView];
        } else {
            [container addSubview:colorfulView positioned:NSWindowBelow relativeTo:qnsView];
        }
    }

    [colorfulView ym_updateColorfulBackgroundIfNeeded];
}

#pragma mark - 工具：判断 QNSView

static BOOL YMIsQNSView(NSView *view) {
    if (!view) return NO;

    Class qnsClass = NSClassFromString(@"QNSView");
    if (!qnsClass) return NO;

    return [view isKindOfClass:qnsClass];
}

static BOOL YMViewTreeContainsQNSView(NSView *view) {
    if (!view) return NO;
    if (YMIsQNSView(view)) return YES;
    for (NSView *subview in view.subviews) {
        if (YMViewTreeContainsQNSView(subview)) return YES;
    }
    return NO;
}

static void YMRestoreQNSViewForSkippedWindow(NSView *view) {
    YMRestoreThemeObject(view.layer);
    YMRestoreThemeObject(view);
}

static void YMRemoveColorfulBlurBackgroundViewsInTree(NSView *view) {
    if (!view) return;

    NSArray<NSView *> *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        if ([subview.identifier isEqualToString:kYMColorfulBlurBackgroundViewIdentifier]) {
            [subview removeFromSuperview];
            continue;
        }

        YMRemoveColorfulBlurBackgroundViewsInTree(subview);
    }
}

static void YMRestoreQNSViewsForSkippedWindowInTree(NSView *view) {
    if (!view) return;

    YMRestoreQNSViewForSkippedWindow(view);

    NSArray<NSView *> *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        YMRestoreQNSViewsForSkippedWindowInTree(subview);
    }
}

static void YMCleanupMistyArtifactsForSkippedWindow(NSWindow *window) {
    if (!window) return;

    YMRemoveColorfulBlurBackgroundViewsInTree(window.contentView);
    YMRestoreQNSViewsForSkippedWindowInTree(window.contentView);
    YMRestoreThemeObject(window);
}


#pragma mark - 工具：窗口过滤

static BOOL YMTextContainsAnyKeyword(NSString *text, NSArray<NSString *> *keywords) {
    if (text.length == 0 || keywords.count == 0) {
        return NO;
    }

    for (NSString *keyword in keywords) {
        if (keyword.length == 0) {
            continue;
        }

        if ([text rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }

    return NO;
}

static NSString *YMWindowInspectionText(NSWindow *window) {
    if (!window) {
        return @"";
    }

    NSMutableString *text = [NSMutableString string];

    NSString *className = NSStringFromClass(window.class);
    if (className.length > 0) {
        [text appendFormat:@"%@ ", className];
    }

    if (window.title.length > 0) {
        [text appendFormat:@"%@ ", window.title];
    }

    // QNSWindow 的 description 里会带出 Qt 的 QWidgetWindow name，
    // 例如：name="PreviewWindow_xxxWindow"。这是过滤图片预览窗口最稳定的特征。
    NSString *windowDescription = window.description;
    if (windowDescription.length > 0) {
        [text appendFormat:@"%@ ", windowDescription];
    }

    NSString *contentViewDescription = window.contentView.description;
    if (contentViewDescription.length > 0) {
        [text appendFormat:@"%@ ", contentViewDescription];
    }

    return text;
}

static BOOL YMShouldSkipMistyEffectForWindow(NSWindow *window) {
    if (!window) {
        return YES;
    }

    NSString *className = NSStringFromClass(window.class);
    NSArray<NSString *> *blockedKeywords = @[
        @"Status",
        @"Menu",
        @"Popover",
        @"Tooltip",
        @"TouchBar",
        @"QNSPanel"
    ];
    
    for (NSString *keyword in blockedKeywords) {
        if ([className rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }

    NSString *inspectionText = YMWindowInspectionText(window);
    NSArray<NSString *> *blockedQtWindowNameKeywords = @[
        // 聊天图片预览窗口
        @"PreviewWindow",
        //个人资料
        @"ProfileUniquePopClassWindow",
        //表情包
        @"EmoticonPopoverWindow",
    ];

    if (YMTextContainsAnyKeyword(inspectionText, blockedQtWindowNameKeywords)) {
        return YES;
    }

    // AppKit 的菜单 / 状态栏相关窗口常见窗口层级。
    // 不用“非 NSNormalWindowLevel 一律跳过”，因为微信登录窗口在某些状态下可能不是普通 level。
    NSInteger level = window.level;
    if (level == NSMainMenuWindowLevel ||
        level == NSStatusWindowLevel ||
        level == NSPopUpMenuWindowLevel) {
        return YES;
    }

    NSRect frame = window.frame;

    // 顶部状态栏图标、菜单承载窗口一般非常小。
    // 这里阈值故意放低，避免把微信登录窗口误判掉。
    if (frame.size.width < 220.0 || frame.size.height < 120.0) {
        return YES;
    }

    return NO;
}

static BOOL YMShouldApplyMistyEffectForWindow(NSWindow *window) {
    return !YMShouldSkipMistyEffectForWindow(window) && YMViewTreeContainsQNSView(window.contentView);
}

#pragma mark - Qt 控件背景绘制

// Qt 5.15 的 QObject::d_ptr 位于 +8；QObjectData::parent 位于 +16。
// QWidgetPrivate::q_ptr 也位于 +8。仅在已校验的微信二进制中读取这些私有布局。
static bool YMQtObjectIsA(const void *object, const char *className) {
    if (!object) return false;
    auto vtable = *reinterpret_cast<void *const *const *>(object);
    if (!vtable) return false;
    using MetaCast = void *(*)(const void *, const char *);
    auto metaCast = reinterpret_cast<MetaCast>(vtable[1]);
    return metaCast && metaCast(object, className) != nullptr;
}

static const void *YMQtObjectParent(const void *object) {
    if (!object) return nullptr;
    const void *privateData = *reinterpret_cast<void *const *>(
        reinterpret_cast<const uint8_t *>(object) + 8);
    return privateData ? *reinterpret_cast<void *const *>(
        reinterpret_cast<const uint8_t *>(privateData) + 16) : nullptr;
}

static bool YMQtShouldClearWidgetBackground(const void *widget) {
    if (!widget) return false;

    bool inMainWindow = false;
    bool inPanel = false;
    bool protectedContent = false;
    const void *current = widget;
    for (int depth = 0; current && depth < 64; ++depth) {
        if (YMQtObjectIsA(current, "mmui::FramelessMainWindow") ||
            YMQtObjectIsA(current, "mmui::MainWindow")) inMainWindow = true;
        if (YMQtObjectIsA(current, "mmui::ChatMasterView") ||
            YMQtObjectIsA(current, "mmui::ChatSessionList") ||
            YMQtObjectIsA(current, "mmui::TitleBar") ||
            YMQtObjectIsA(current, "mmui::ChatDetailView") ||
            YMQtObjectIsA(current, "mmui::ChatPage") ||
            YMQtObjectIsA(current, "mmui::ChatMessagePage") ||
            YMQtObjectIsA(current, "mmui::ChatTitleBarMasterView") ||
            YMQtObjectIsA(current, "mmui::ChatTitleBarBaseView") ||
            YMQtObjectIsA(current, "mmui::ChatInputView") ||
            YMQtObjectIsA(current, "mmui::ChatInputField") ||
            YMQtObjectIsA(current, "mmui::ChatInputSendView")) inPanel = true;
        if (YMQtObjectIsA(current, "mmui::ChatItemView") ||
            YMQtObjectIsA(current, "mmui::ChatBubbleFrame") ||
            YMQtObjectIsA(current, "QAbstractButton")) protectedContent = true;
        current = YMQtObjectParent(current);
    }
    return inMainWindow && inPanel && !protectedContent;
}

static bool YMQtShouldClearPanelBackground(const void *widgetPrivate) {
    if (!widgetPrivate) return false;
    const void *widget = *reinterpret_cast<void *const *>(
        reinterpret_cast<const uint8_t *>(widgetPrivate) + 8);
    return YMQtShouldClearWidgetBackground(widget);
}

static bool YMQtIsInMainWindow(const void *widget) {
    const void *current = widget;
    for (int depth = 0; current && depth < 64; ++depth) {
        if (YMQtObjectIsA(current, "mmui::FramelessMainWindow") ||
            YMQtObjectIsA(current, "mmui::MainWindow")) return true;
        current = YMQtObjectParent(current);
    }
    return false;
}

static bool YMQtIsSessionSearchField(const void *widget) {
    if (!YMQtObjectIsA(widget, "mmui::XSearchField")) return false;
    bool inSessionList = false;
    bool inMainWindow = false;
    const void *current = widget;
    for (int depth = 0; current && depth < 64; ++depth) {
        if (YMQtObjectIsA(current, "mmui::ChatMasterView") ||
            YMQtObjectIsA(current, "mmui::ChatSessionList")) inSessionList = true;
        if (YMQtObjectIsA(current, "mmui::FramelessMainWindow") ||
            YMQtObjectIsA(current, "mmui::MainWindow")) inMainWindow = true;
        current = YMQtObjectParent(current);
        if (inSessionList && inMainWindow) return true;
    }
    return false;
}

static bool YMQtContainsSessionSearchField(const void *widget, int depth) {
    if (!widget || depth > 8) return false;
    if (YMQtIsSessionSearchField(widget)) return true;

    const void *privateData = *reinterpret_cast<void *const *>(
        reinterpret_cast<const uint8_t *>(widget) + 8);
    const void *children = privateData ? *reinterpret_cast<void *const *>(
        reinterpret_cast<const uint8_t *>(privateData) + 24) : nullptr;
    if (!children) return false;

    const uint8_t *list = reinterpret_cast<const uint8_t *>(children);
    const int begin = *reinterpret_cast<const int *>(list + 8);
    const int end = *reinterpret_cast<const int *>(list + 12);
    if (begin < 0 || end < begin || end - begin > 64) return false;
    const auto items = reinterpret_cast<void *const *>(list + 16);
    for (int index = begin; index < end; ++index) {
        if (YMQtContainsSessionSearchField(items[index], depth + 1)) return true;
    }
    return false;
}

static bool YMQtIsSessionSearchHeader(const void *widget) {
    if (!YMQtObjectIsA(widget, "mmui::XView") &&
        !YMQtObjectIsA(widget, "mmui::XVBoxView")) return false;

    bool inSessionList = false;
    const void *current = widget;
    for (int depth = 0; current && depth < 64; ++depth) {
        if (YMQtObjectIsA(current, "mmui::ChatMasterView") ||
            YMQtObjectIsA(current, "mmui::ChatSessionList")) {
            inSessionList = true;
            break;
        }
        current = YMQtObjectParent(current);
    }
    if (!inSessionList) return false;
    return YMQtContainsSessionSearchField(widget, 0);
}

static void YMQtClearSessionSearchHeader(void *widget) {
    if (!gYMQtPainterConstruct || !gYMQtPainterDestruct ||
        !gYMQtPaletteBrush || !gYMQtPainterFillRect ||
        !gYMQtPainterSetCompositionMode) return;
    const auto bytes = reinterpret_cast<uint8_t *>(widget);
    const auto data = *reinterpret_cast<const uint8_t *const *>(bytes + 0x28);
    if (!data) return;
    const int *bounds = reinterpret_cast<const int *>(data + 0x14);
    const int width = bounds[2] - bounds[0] + 1;
    const int height = bounds[3] - bounds[1] + 1;
    if (width <= 0 || height <= 0) return;

    const int rect[4] = {0, 0, width - 1, height - 1};
    const void *brush = gYMQtPaletteBrush(data + 0x28, 4, 10);
    if (!brush) return;
    alignas(16) uint8_t painter[16] = {};
    gYMQtPainterConstruct(painter, bytes + 0x10);
    gYMQtPainterSetCompositionMode(painter, 2); // QPainter::CompositionMode_Clear
    gYMQtPainterFillRect(painter, rect, brush);
    gYMQtPainterDestruct(painter);
}

static void YMQtPaintBackgroundHook(void *widgetPrivate, void *painter,
                                    const void *region, unsigned int flags) {
    if (gYMQtBackgroundEnabled.load(std::memory_order_relaxed) &&
        YMQtShouldClearPanelBackground(widgetPrivate) &&
        gYMQtPainterCompositionMode && gYMQtPainterSetCompositionMode) {
        const int oldMode = gYMQtPainterCompositionMode(painter);
        gYMQtPainterSetCompositionMode(painter, 2); // QPainter::CompositionMode_Clear
        // Qt 的 DrawAsRoot 分支原本会强制改为 Source；0x80 保持当前 Clear 模式。
        gYMOriginalQtPaintBackground(widgetPrivate, painter, region, flags | 0x80);
        gYMQtPainterSetCompositionMode(painter, oldMode);
        return;
    }
    if (gYMOriginalQtPaintBackground)
        gYMOriginalQtPaintBackground(widgetPrivate, painter, region, flags);
}

static void YMQtPanelPaintEventHook(void *widget, void *event) {
    if (gYMQtBackgroundEnabled.load(std::memory_order_relaxed) &&
        YMQtShouldClearWidgetBackground(widget)) {
        if (YMQtIsSessionSearchHeader(widget)) YMQtClearSessionSearchHeader(widget);
        YMSessionMarkNotePanelWidget(widget);
        return;
    }
    if (gYMOriginalPanelPaintEvent) gYMOriginalPanelPaintEvent(widget, event);
    YMSessionMarkNotePanelWidget(widget);
}

static void YMQtSessionCellPaintEventHook(void *widget, void *event) {
    const bool skipNativePaint =
        YMSessionMarkSkipNativeCellPaint(widget) ||
        (gYMQtBackgroundEnabled.load(std::memory_order_relaxed) &&
            YMQtObjectIsA(widget, "mmui::ChatSessionCell") && YMQtIsInMainWindow(widget) &&
            !YMSessionMarkCellNativeSelected(widget));
    if (!skipNativePaint && gYMOriginalSessionCellPaintEvent)
        gYMOriginalSessionCellPaintEvent(widget, event);
    YMSessionMarkNoteWidget(widget);
}

static void YMQtSearchFieldPaintEventHook(void *widget, void *event) {
    if (gYMQtBackgroundEnabled.load(std::memory_order_relaxed) &&
        YMQtIsSessionSearchField(widget)) return;
    if (gYMOriginalSearchFieldPaintEvent)
        gYMOriginalSearchFieldPaintEvent(widget, event);
}

static void YMQtXImageDrawHook(void *image, void *canvas) {
    if (YMQtObjectIsA(image, "mmui::XAvatarImage")) {
        const auto data = *reinterpret_cast<const uint8_t *const *>(
            reinterpret_cast<const uint8_t *>(image) + 0x28);
        if (data) {
            const int *bounds = reinterpret_cast<const int *>(data + 0x14);
            const int width = bounds[2] - bounds[0] + 1;
            const int height = bounds[3] - bounds[1] + 1;
            if (width > 0 && height > 0 && width <= 512 && height <= 512) {
                const float percent = static_cast<float>(YMRoundedAvatarRadiusPercent());
                // 两个已校验版本的 XImage::draw 都使用 RoundType/XRad/YRad 裁切头像。
                if (percent >= 50.0f) gYMQtSetRoundType(image, 2); // kRound
                else if (percent <= 0.0f) gYMQtSetRoundType(image, 0); // kNone
                else {
                    const float radius = (width < height ? width : height) * percent / 100.0f;
                    gYMQtSetXRad(image, radius);
                    gYMQtSetYRad(image, radius);
                    gYMQtSetRoundType(image, 1); // kRRect
                }
                static std::atomic_uint logged(0);
                if (logged.fetch_add(1, std::memory_order_relaxed) < 5)
                    YMLog(@"头像原生绘制命中：%dx%d，圆角 %.0f%%", width, height, percent);
            }
        }
    }
    if (gYMOriginalXImageDraw) gYMOriginalXImageDraw(image, canvas);
}

static void YMQtImageGroupOverlayHook(void *animator) {
    if (!gYMOriginalImageGroupOverlay) return;
    if (!animator || !gYMQtBackgroundEnabled.load(std::memory_order_relaxed)) {
        gYMOriginalImageGroupOverlay(animator);
        return;
    }
    void *color = static_cast<uint8_t *>(animator) + 0xb0;
    uint32_t saved[4];
    std::memcpy(saved, color, sizeof saved);
    const uint32_t transparent[4] = {1, 0, 0, 0}; // QColor::Rgb，透明黑，无指针字段。
    std::memcpy(color, transparent, sizeof transparent);
    @try {
        // 原生同时设置 scene 和 viewport 的底色；透明时沿用下方的主题背景。
        gYMOriginalImageGroupOverlay(animator);
    } @finally {
        std::memcpy(color, saved, sizeof saved);
    }
}

template <typename Function>
static bool YMInstallQtPaintEventHook(uintptr_t staticVA,
                                      const uint8_t expected[16],
                                      Function replacement,
                                      Function *original,
                                      const char *name) {
    const uintptr_t target = YMRuntimeAddress(staticVA);
    if (!target || std::memcmp(reinterpret_cast<const void *>(target), expected, 16) != 0)
        return false;

    uint8_t trampoline[32] = {};
    std::memcpy(trampoline, expected, 16);
    const uint32_t loadTarget = 0x58000050;
    const uint32_t jumpTarget = 0xD61F0200;
    const uintptr_t continuation = target + 16;
    std::memcpy(trampoline + 16, &loadTarget, sizeof(loadTarget));
    std::memcpy(trampoline + 20, &jumpTarget, sizeof(jumpTarget));
    std::memcpy(trampoline + 24, &continuation, sizeof(continuation));

    void *mapping = mmap(nullptr, sizeof(trampoline), PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapping == MAP_FAILED) return false;
    std::memcpy(mapping, trampoline, sizeof(trampoline));
    if (mprotect(mapping, sizeof(trampoline), PROT_READ | PROT_EXEC) != 0) {
        munmap(mapping, sizeof(trampoline));
        return false;
    }
    sys_icache_invalidate(mapping, sizeof(trampoline));
    *original = reinterpret_cast<Function>(mapping);
    if (!YMPatchARM64AbsoluteJump(target, reinterpret_cast<uintptr_t>(replacement), name)) {
        *original = nullptr;
        munmap(mapping, sizeof(trampoline));
        return false;
    }
    return true;
}

void YMInstallQtCustomBackgroundHooks(void) {
#if defined(__aarch64__)
    if (!YMMatchesWeChat270353Dylib()) return;

    if (!gYMOriginalImageGroupOverlay) {
        static const uint8_t overlayPrologue[16] = {
            0xff, 0x03, 0x02, 0xd1, 0xe9, 0x23, 0x04, 0x6d,
            0xf6, 0x57, 0x05, 0xa9, 0xf4, 0x4f, 0x06, 0xa9
        };
        if (!YMInstallQtPaintEventHook(0x4c5f58, overlayPrologue, &YMQtImageGroupOverlayHook,
                                       &gYMOriginalImageGroupOverlay, "Qt image group animation background"))
            YMLog(@"Qt 组图动画背景入口校验或安装失败");
    }

    static const uint8_t roundTypeBytes[8] = {0x01, 0xD4, 0x01, 0xB9, 0xC0, 0x03, 0x5F, 0xD6};
    static const uint8_t xRadBytes[8] = {0x00, 0xD8, 0x01, 0xBD, 0xC0, 0x03, 0x5F, 0xD6};
    static const uint8_t yRadBytes[8] = {0x00, 0xDC, 0x01, 0xBD, 0xC0, 0x03, 0x5F, 0xD6};
    static const uint8_t newDrawPrologue[16] = {
        0xFF, 0xC3, 0x04, 0xD1, 0xEB, 0x2B, 0x0C, 0x6D,
        0xE9, 0x23, 0x0D, 0x6D, 0xFA, 0x67, 0x0E, 0xA9
    };
    // 270353 的 Qt 属性分派在 0x1F63BBC 跳到合并后的 RoundType setter。
    // 相邻 0x1FAEFFC 是 bool getter，不能按地址差推算 setter。
    const uintptr_t setRoundType = YMRuntimeAddress(0xd20c10);
    const uintptr_t setXRad = YMRuntimeAddress(0x1faf00c);
    const uintptr_t setYRad = YMRuntimeAddress(0x1faf01c);
    if (!gYMOriginalXImageDraw) {
        if (setRoundType && setXRad && setYRad &&
            !std::memcmp(reinterpret_cast<const void *>(setRoundType), roundTypeBytes, 8) &&
            !std::memcmp(reinterpret_cast<const void *>(setXRad), xRadBytes, 8) &&
            !std::memcmp(reinterpret_cast<const void *>(setYRad), yRadBytes, 8)) {
            gYMQtSetRoundType = reinterpret_cast<YMQtSetRoundTypeIMP>(setRoundType);
            gYMQtSetXRad = reinterpret_cast<YMQtSetRadiusIMP>(setXRad);
            gYMQtSetYRad = reinterpret_cast<YMQtSetRadiusIMP>(setYRad);
            if (!YMInstallQtPaintEventHook(0x1faf0e0,
                                           newDrawPrologue,
                                           &YMQtXImageDrawHook, &gYMOriginalXImageDraw,
                                           "Qt avatar XImage draw"))
                YMLog(@"Qt 头像原生绘制入口校验或安装失败");
        } else YMLog(@"Qt 头像圆角属性入口校验失败，保留微信原生绘制");
    }

    const uintptr_t painterConstruct = YMRuntimeAddress(0x6f9f5b8);
    const uintptr_t painterDestruct = YMRuntimeAddress(0x6f9fe34);
    const uintptr_t paletteBrush = YMRuntimeAddress(0x6df02c0);
    const uintptr_t painterFillRect = YMRuntimeAddress(0x6fac698);
    // 两版同形的入口；ctor/dtor 是尾跳，栈上 QPainter 仍由这对原生函数管理。
    static const uint8_t constructBytes[4] = {0xDE, 0x06, 0x00, 0x14};
    static const uint8_t destructBytes[4] = {0x88, 0x06, 0x00, 0x14};
    static const uint8_t brushBytes[16] = {
        0xFF, 0x43, 0x01, 0xD1, 0xF4, 0x4F, 0x03, 0xA9,
        0xFD, 0x7B, 0x04, 0xA9, 0xFD, 0x03, 0x01, 0x91
    };
    static const uint8_t fillRectBytes[16] = {
        0xFF, 0xC3, 0x01, 0xD1, 0xF8, 0x5F, 0x03, 0xA9,
        0xF6, 0x57, 0x04, 0xA9, 0xF4, 0x4F, 0x05, 0xA9
    };
    if (!painterConstruct || !painterDestruct || !paletteBrush || !painterFillRect ||
        std::memcmp(reinterpret_cast<const void *>(painterConstruct), constructBytes, 4) ||
        std::memcmp(reinterpret_cast<const void *>(painterDestruct), destructBytes, 4) ||
        std::memcmp(reinterpret_cast<const void *>(paletteBrush), brushBytes, 16) ||
        std::memcmp(reinterpret_cast<const void *>(painterFillRect), fillRectBytes, 16)) {
        YMLog(@"Qt 自绘背景辅助入口校验失败");
        return;
    }
    gYMQtPainterConstruct = reinterpret_cast<YMQtPainterConstructIMP>(painterConstruct);
    gYMQtPainterDestruct = reinterpret_cast<YMQtPainterDestructIMP>(painterDestruct);
    gYMQtPaletteBrush = reinterpret_cast<YMQtPaletteBrushIMP>(paletteBrush);
    gYMQtPainterFillRect = reinterpret_cast<YMQtPainterFillRectIMP>(painterFillRect);

    // 面板、会话行和搜索框各自的 paintEvent；270353 增加了 painter device 检查。
    // 这些入口只调用控件样式绘制，富文本输入控件的绘制不受影响。
    static const uint8_t newPanelPrologue[16] = {
        0xFF, 0x43, 0x01, 0xD1, 0xF8, 0x5F, 0x01, 0xA9,
        0xF6, 0x57, 0x02, 0xA9, 0xF4, 0x4F, 0x03, 0xA9
    };
    if (!gYMOriginalPanelPaintEvent &&
        !YMInstallQtPaintEventHook(0x20d8d10, newPanelPrologue,
                                   &YMQtPanelPaintEventHook,
                                   &gYMOriginalPanelPaintEvent,
                                   "Qt panel paintEvent"))
        YMLog(@"Qt 面板自绘底色入口校验或安装失败");
    if (!gYMOriginalSessionCellPaintEvent &&
        !YMInstallQtPaintEventHook(0x203c53c, newPanelPrologue,
                                   &YMQtSessionCellPaintEventHook,
                                   &gYMOriginalSessionCellPaintEvent,
                                   "Qt session cell paintEvent"))
        YMLog(@"Qt 会话行自绘底色入口校验或安装失败");
    if (!gYMOriginalSearchFieldPaintEvent &&
        !YMInstallQtPaintEventHook(0x2050450, newPanelPrologue,
                                   &YMQtSearchFieldPaintEventHook,
                                   &gYMOriginalSearchFieldPaintEvent,
                                   "Qt session search paintEvent"))
        YMLog(@"Qt 会话搜索框自绘底色入口校验或安装失败");
#endif
}

static void YMInstallQtBackgroundHook(void) {
#if defined(__aarch64__)
    if (gYMQtBackgroundHookInstalled || !YMMatchesWeChat270353Dylib()) return;

    // 两版均为 QWidgetPrivate::paintBackground(QPainter *, QRegion const &, flags)。
    // drawWidget 先绘制容器背景，再派发控件自己的 paintEvent。
    const uintptr_t target = YMRuntimeAddress(0x6b6a7f0);
    static const uint8_t expected[16] = {
        0xFF, 0x83, 0x02, 0xD1, 0xFA, 0x67, 0x05, 0xA9,
        0xF8, 0x5F, 0x06, 0xA9, 0xF6, 0x57, 0x07, 0xA9
    };
    if (!target || std::memcmp(reinterpret_cast<const void *>(target), expected,
                                sizeof(expected)) != 0) {
        YMLog(@"Qt 背景绘制入口校验失败，保留微信原始绘制");
        return;
    }
    const uintptr_t setComposition = YMRuntimeAddress(0x6fa1b54);
    const uintptr_t getComposition = YMRuntimeAddress(0x6fa1c0c);
    static const uint8_t expectedSetComposition[16] = {
        0xFD, 0x7B, 0xBF, 0xA9, 0xFD, 0x03, 0x00, 0x91,
        0x0A, 0x00, 0x40, 0xF9, 0x49, 0x79, 0x40, 0xF9
    };
    static const uint8_t expectedGetComposition[16] = {
        0xFD, 0x7B, 0xBF, 0xA9, 0xFD, 0x03, 0x00, 0x91,
        0x08, 0x00, 0x40, 0xF9, 0x09, 0x79, 0x40, 0xF9
    };
    if (!setComposition || !getComposition ||
        std::memcmp(reinterpret_cast<const void *>(setComposition),
                    expectedSetComposition, sizeof(expectedSetComposition)) != 0 ||
        std::memcmp(reinterpret_cast<const void *>(getComposition),
                    expectedGetComposition, sizeof(expectedGetComposition)) != 0) {
        YMLog(@"Qt Painter 合成模式入口校验失败，保留微信原始绘制");
        return;
    }

    uint8_t trampoline[32] = {};
    std::memcpy(trampoline, expected, sizeof(expected));
    const uint32_t loadTarget = 0x58000050;
    const uint32_t jumpTarget = 0xD61F0200;
    const uintptr_t continuation = target + sizeof(expected);
    std::memcpy(trampoline + 16, &loadTarget, sizeof(loadTarget));
    std::memcpy(trampoline + 20, &jumpTarget, sizeof(jumpTarget));
    std::memcpy(trampoline + 24, &continuation, sizeof(continuation));

    void *mapping = mmap(nullptr, sizeof(trampoline), PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapping == MAP_FAILED) return;
    std::memcpy(mapping, trampoline, sizeof(trampoline));
    if (mprotect(mapping, sizeof(trampoline), PROT_READ | PROT_EXEC) != 0) {
        munmap(mapping, sizeof(trampoline));
        return;
    }
    sys_icache_invalidate(mapping, sizeof(trampoline));
    gYMOriginalQtPaintBackground = reinterpret_cast<YMQtPaintBackgroundIMP>(mapping);
    gYMQtPainterCompositionMode = reinterpret_cast<YMQtPainterCompositionModeIMP>(getComposition);
    gYMQtPainterSetCompositionMode = reinterpret_cast<YMQtPainterSetCompositionModeIMP>(setComposition);
    if (!YMPatchARM64AbsoluteJump(target, reinterpret_cast<uintptr_t>(&YMQtPaintBackgroundHook),
                                  "Qt panel background")) {
        gYMOriginalQtPaintBackground = nullptr;
        gYMQtPainterCompositionMode = nullptr;
        gYMQtPainterSetCompositionMode = nullptr;
        munmap(mapping, sizeof(trampoline));
        return;
    }
    gYMQtBackgroundHookInstalled = YES;
    YMLog(@"已安装 Qt 主窗口背景绘制钩子");
#endif
}

#pragma mark - 工具：CGS 背景模糊

static BOOL YMResolveCGSBlurSymbolsIfNeeded(void) {
    if (gYMCGSBlurResolved) {
        return gYMCGSMainConnectionID && gYMCGSSetWindowBackgroundBlurRadius;
    }

    gYMCGSBlurResolved = YES;

    // 通常这两个符号可以从当前进程已经加载的 CoreGraphics / ApplicationServices 里找到。
    gYMCGSMainConnectionID = (YMCGSMainConnectionIDFunc)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    gYMCGSSetWindowBackgroundBlurRadius = (YMCGSSetWindowBackgroundBlurRadiusFunc)dlsym(RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius");

    if (!gYMCGSMainConnectionID || !gYMCGSSetWindowBackgroundBlurRadius) {
        void *handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
        if (handle) {
            if (!gYMCGSMainConnectionID) {
                gYMCGSMainConnectionID = (YMCGSMainConnectionIDFunc)dlsym(handle, "CGSMainConnectionID");
            }
            if (!gYMCGSSetWindowBackgroundBlurRadius) {
                gYMCGSSetWindowBackgroundBlurRadius = (YMCGSSetWindowBackgroundBlurRadiusFunc)dlsym(handle, "CGSSetWindowBackgroundBlurRadius");
            }
        }
    }

    if (!gYMCGSMainConnectionID || !gYMCGSSetWindowBackgroundBlurRadius) {
        void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        if (handle) {
            if (!gYMCGSMainConnectionID) {
                gYMCGSMainConnectionID = (YMCGSMainConnectionIDFunc)dlsym(handle, "CGSMainConnectionID");
            }
            if (!gYMCGSSetWindowBackgroundBlurRadius) {
                gYMCGSSetWindowBackgroundBlurRadius = (YMCGSSetWindowBackgroundBlurRadiusFunc)dlsym(handle, "CGSSetWindowBackgroundBlurRadius");
            }
        }
    }

    BOOL ok = gYMCGSMainConnectionID && gYMCGSSetWindowBackgroundBlurRadius;
    if (!ok && !gYMCGSBlurResolveFailedLogged) {
        gYMCGSBlurResolveFailedLogged = YES;
        YMLog(@"CGS 背景模糊接口解析失败，当前系统可能不可用：CGSMainConnectionID=%p CGSSetWindowBackgroundBlurRadius=%p",
              gYMCGSMainConnectionID,
              gYMCGSSetWindowBackgroundBlurRadius);
    }

    return ok;
}

static void YMApplyWindowBackgroundBlur(NSWindow *window, int radius) {
    if (!window) return;

    NSInteger windowNumber = window.windowNumber;
    if (windowNumber <= 0) {
        // windowNumber 为 0 通常说明窗口还没真正进入 WindowServer，稍后 refresh 会再应用。
        return;
    }

    // 如果 radius 为 0，也要调用一次 CGS，把旧 blur 关掉。
    if (!YMResolveCGSBlurSymbolsIfNeeded()) {
        return;
    }

    NSNumber *oldRadius = objc_getAssociatedObject(window, &kYMAppliedBlurRadiusAssociatedKey);
    NSNumber *oldWindowNumber = objc_getAssociatedObject(window, &kYMAppliedBlurWindowNumberAssociatedKey);
    if (oldRadius && oldWindowNumber &&
        oldRadius.intValue == radius &&
        oldWindowNumber.integerValue == windowNumber) {
        return;
    }

    YMCGSConnectionID cid = gYMCGSMainConnectionID();
    CGError err = gYMCGSSetWindowBackgroundBlurRadius(cid, (YMCGSWindowID)windowNumber, radius);
    if (err != kCGErrorSuccess) {
        YMLog(@"窗口背景模糊应用失败：radius=%d err=%d", radius, err);
        return;
    }

    objc_setAssociatedObject(window,
                             &kYMAppliedBlurRadiusAssociatedKey,
                             @(radius),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window,
                             &kYMAppliedBlurWindowNumberAssociatedKey,
                             @(windowNumber),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    YMLog(@"已应用窗口背景模糊：window=%@ windowNumber=%ld radius=%d err=%d",
          window,
          (long)windowNumber,
          radius,
          err);
}

// 快照只记录插件首次改写前的值；layer 独立记录，兼容 Qt 运行中替换 layer。
static void YMSaveThemeObject(id object) {
    if (!object || objc_getAssociatedObject(object, &kYMOriginalThemeStateKey)) return;
    NSDictionary *state;
    if ([object isKindOfClass:NSWindow.class]) {
        NSWindow *window = object;
        state = @{ @"opaque": @(window.opaque), @"color": window.backgroundColor ?: NSNull.null };
    } else if ([object isKindOfClass:NSView.class]) {
        NSView *view = object;
        state = @{ @"alpha": @(view.alphaValue), @"wantsLayer": @(view.wantsLayer) };
    } else {
        CALayer *layer = object;
        state = @{ @"opaque": @(layer.opaque), @"color": (__bridge id)layer.backgroundColor ?: NSNull.null };
    }
    objc_setAssociatedObject(object, &kYMOriginalThemeStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gYMModifiedThemeObjects) gYMModifiedThemeObjects = [NSHashTable weakObjectsHashTable];
    [gYMModifiedThemeObjects addObject:object];
}

static void YMRestoreThemeObject(id object) {
    NSDictionary *state = objc_getAssociatedObject(object, &kYMOriginalThemeStateKey);
    if (!state) return;
    // 先消费快照，避免 AppKit 属性 setter 触发回调时重复还原。
    objc_setAssociatedObject(object, &kYMOriginalThemeStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gYMModifiedThemeObjects removeObject:object];
    id color = state[@"color"] == NSNull.null ? nil : state[@"color"];
    if ([object isKindOfClass:NSWindow.class]) {
        NSWindow *window = object;
        YMApplyWindowBackgroundBlur(window, 0);
        window.opaque = [state[@"opaque"] boolValue];
        window.backgroundColor = color;
    } else if ([object isKindOfClass:NSView.class]) {
        NSView *view = object;
        YMRemoveColorfulBlurBackgroundViewsInTree(view);
        view.alphaValue = [state[@"alpha"] doubleValue];
        view.wantsLayer = [state[@"wantsLayer"] boolValue];
        view.needsDisplay = YES;
    } else {
        CALayer *layer = object;
        layer.opaque = [state[@"opaque"] boolValue];
        layer.backgroundColor = (__bridge CGColorRef)color;
    }
}

#pragma mark - Cocoa 层：窗口与 View 透明 / blur carrier

static NSColor *YMWindowBackgroundTintColor(void) {
    NSString *mode = YMThemeAppearanceMode();
    if ([mode isEqualToString:kThemeAppearancePink]) {
        return YMModernCarrierStyleIsDark()
            ? [NSColor colorWithCalibratedRed:0.43 green:0.16 blue:0.29 alpha:1.0]
            : [NSColor colorWithCalibratedRed:229.0/255.0 green:173.0/255.0 blue:177.0/255.0 alpha:1.0];
    }
    if ([mode isEqualToString:kThemeAppearanceImage]) {
        return YMModernCarrierStyleIsDark()
            ? [NSColor colorWithCalibratedWhite:0.08 alpha:1.0]
            : [NSColor colorWithCalibratedWhite:0.94 alpha:1.0];
    }
    CGFloat alpha = 1.0f - YMBackgroundTransparency();
    CGFloat white = YMModernCarrierStyleIsDark() ? 0.0 : 1.0;

    return [NSColor colorWithCalibratedWhite:white alpha:alpha];
}

static NSColor *YMWindowImageBackgroundColor(NSWindow *window) {
    NSURL *url = [YMThemeImageStore selectedImageURL];
    if (!url) return YMWindowBackgroundTintColor();
    NSSize size = window.contentView.bounds.size;
    if (size.width < 1 || size.height < 1) return YMWindowBackgroundTintColor();
    CGFloat opacity = MAX(0.2, MIN(1.0,
        [[NSUserDefaults standardUserDefaults] doubleForKey:kThemeBackgroundImageOpacity]));
    NSString *cacheKey = [NSString stringWithFormat:@"%@:%0.0f:%0.0f:%.3f:%d", url.path,
        ceil(size.width), ceil(size.height), opacity, YMModernCarrierStyleIsDark()];
    NSString *previousKey = objc_getAssociatedObject(window, &kYMImagePatternCacheKey);
    NSColor *cachedColor = objc_getAssociatedObject(window, &kYMImagePatternColorKey);
    if ([cacheKey isEqualToString:previousKey] && cachedColor) return cachedColor;

    NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
    if (!image || image.size.width < 1 || image.size.height < 1) return YMWindowBackgroundTintColor();
    NSSize patternSize = NSMakeSize(ceil(size.width), ceil(size.height));
    NSImage *pattern = [[NSImage alloc] initWithSize:patternSize];
    [pattern lockFocus];
    [YMWindowBackgroundTintColor() setFill];
    NSRectFill(NSMakeRect(0, 0, patternSize.width, patternSize.height));
    CGFloat scale = MAX(patternSize.width / image.size.width, patternSize.height / image.size.height);
    NSSize crop = NSMakeSize(patternSize.width / scale, patternSize.height / scale);
    NSRect source = NSMakeRect((image.size.width - crop.width) / 2.0,
                               (image.size.height - crop.height) / 2.0, crop.width, crop.height);
    [image drawInRect:NSMakeRect(0, 0, patternSize.width, patternSize.height)
            fromRect:source operation:NSCompositingOperationSourceOver
            fraction:opacity respectFlipped:NO hints:nil];
    [pattern unlockFocus];
    NSColor *color = [NSColor colorWithPatternImage:pattern];
    objc_setAssociatedObject(window, &kYMImagePatternCacheKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(window, &kYMImagePatternColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return color;
}

static void YMMakeWindowTransparent(NSWindow *window) {
    if (!window) return;

    YMSaveThemeObject(window);
    window.opaque = NO;

    // 只在窗口底色上应用透明度，避免多层 carrier 叠加改变实际强度。
    window.backgroundColor = [YMThemeAppearanceMode() isEqualToString:kThemeAppearanceImage]
        ? YMWindowImageBackgroundColor(window) : YMWindowBackgroundTintColor();

    // 保留阴影，整体观感更像系统窗口。
    // window.hasShadow = YES;

    YMApplyWindowBackgroundBlur(window, YMWindowBackgroundBlurRadius());
}

static void YMMakeViewTransparent(NSView *view) {
    if (!view) return;

    YMSaveThemeObject(view);
    view.wantsLayer = YES;
    YMSaveThemeObject(view.layer);
    view.layer.opaque = NO;
    view.layer.backgroundColor = NSColor.clearColor.CGColor;

    // 旧版本把滑块值设到整个 QNSView，导致文字、图片和气泡一起变淡。
    view.alphaValue = 1.0f;
}

static void YMMakeContainerTransparent(NSView *container) {
    if (!container) return;

    YMSaveThemeObject(container);
    container.wantsLayer = YES;
    YMSaveThemeObject(container.layer);
    container.layer.opaque = NO;

    // 承载容器必须透明，窗口底色才是唯一可调的背景层。
    container.layer.backgroundColor = NSColor.clearColor.CGColor;
}

static void YMInstallBlurBackgroundBehindQNSView(NSView *qnsView) {
    if (!YMIsQNSView(qnsView)) return;
    if (gYMApplyingBlurBackground || !YMMistyModeEnabled()) return;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YMInstallBlurBackgroundBehindQNSView(qnsView);
        });
        return;
    }

    gYMApplyingBlurBackground = YES;

    @try {
        NSWindow *window = qnsView.window;
        if (!window) return;

        // 只跳过 macOS 顶部状态栏图标、菜单、popover 等附属窗口。
        // 不跳过登录窗口，避免登录界面的迷离效果失效。
        if (!YMShouldApplyMistyEffectForWindow(window)) {
            YMCleanupMistyArtifactsForSkippedWindow(window);
            YMRestoreQNSViewForSkippedWindow(qnsView);
            return;
        }

        NSView *container = qnsView.superview ?: window.contentView;
        if (!container) return;

        // QNSView 必须已经是 container 的直接子 view，否则不要强行处理。
        if (qnsView.superview != container) {
            return;
        }

        YMMakeWindowTransparent(window);
        YMMakeContainerTransparent(container);
        YMEnsureColorfulBlurBackgroundInContainer(container, qnsView);
        YMMakeViewTransparent(qnsView);
    }
    @finally {
        gYMApplyingBlurBackground = NO;
    }
}

static void YMInstallBlurBackgroundBehindQNSViewAsync(NSView *qnsView) {
    if (!qnsView) return;

    __weak NSView *weakView = qnsView;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *strongView = weakView;
        if (!strongView) return;

        YMInstallBlurBackgroundBehindQNSView(strongView);
    });
}

static void YMRefreshViewTree(NSView *view, BOOL requestRedraw) {
    if (!view) return;

    if (YMIsQNSView(view)) {
        YMInstallBlurBackgroundBehindQNSView(view);
        if (requestRedraw) view.needsDisplay = YES;
    }

    // Qt 的原生子窗口可能各自带有 QNSView，不能在第一个 QNSView 处停止。
    NSArray<NSView *> *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        YMRefreshViewTree(subview, requestRedraw);
    }
}

static void YMRefreshAllWindows(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YMRefreshAllWindows();
        });
        return;
    }

    YMRegisterMistyThemeDefaults();
    YMRoundedAvatarRegisterDefaults();
    const BOOL enabled = YMMistyModeEnabled();
    gYMQtBackgroundEnabled.store(enabled, std::memory_order_relaxed);
    if (!enabled) {
        gYMQtLastRedrawHookMask = 0;
        gYMQtLastThemeSignature = nil;
        [gYMBlurKeepAliveTimer invalidate];
        gYMBlurKeepAliveTimer = nil;
        BOOL wasApplying = gYMApplyingBlurBackground;
        gYMApplyingBlurBackground = YES;
        for (id object in gYMModifiedThemeObjects.allObjects) {
            YMRestoreThemeObject(object);
        }
        gYMApplyingBlurBackground = wasApplying;
        return;
    }

    const unsigned hookMask = (gYMQtBackgroundHookInstalled ? 1u : 0u) |
        (gYMOriginalPanelPaintEvent ? 2u : 0u) |
        (gYMOriginalSessionCellPaintEvent ? 4u : 0u) |
        (gYMOriginalSearchFieldPaintEvent ? 8u : 0u);
    NSString *mode = YMThemeAppearanceMode();
    NSString *imagePath = [mode isEqualToString:kThemeAppearanceImage]
        ? [YMThemeImageStore selectedImageURL].path : @"";
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%.3f", mode, imagePath ?: @"",
        YMFloatSetting(kThemeBackgroundImageOpacity, 0.88)];
    BOOL requestRedraw = hookMask != gYMQtLastRedrawHookMask ||
        ![signature isEqualToString:gYMQtLastThemeSignature];
    gYMQtLastRedrawHookMask = hookMask;
    gYMQtLastThemeSignature = signature;
    for (NSWindow *window in NSApp.windows) {
        if (!YMShouldApplyMistyEffectForWindow(window)) {
            YMCleanupMistyArtifactsForSkippedWindow(window);
            continue;
        }
        if (!window.isVisible || window.isMiniaturized) continue;

        YMMakeWindowTransparent(window);

        YMMakeContainerTransparent(window.contentView);

        YMRefreshViewTree(window.contentView, requestRedraw);
    }
    // New views already schedule avatar updates through the QNSView hooks.
    if (requestRedraw) YMScheduleRoundedAvatarRefresh();
}

static void YMStartBlurKeepAliveIfNeeded(void) {
    if (!YMMistyModeEnabled() || gYMBlurKeepAliveTimer) return;
    gYMBlurKeepAliveTimer = [NSTimer timerWithTimeInterval:kYMBlurKeepAliveInterval repeats:YES block:^(NSTimer *timer) {
        if (NSApp.isActive) YMRefreshAllWindows();
    }];
    gYMBlurKeepAliveTimer.tolerance = 1.0;
    [[NSRunLoop mainRunLoop] addTimer:gYMBlurKeepAliveTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - Runtime Hook：QNSView

static BOOL YM_QNSView_isOpaque(id self, SEL _cmd) {
    if (!YMMistyModeEnabled()) {
        return gOrig_QNSView_isOpaque ? gOrig_QNSView_isOpaque(self, _cmd) : YES;
    }
    if ([self isKindOfClass:[NSView class]]) {
        NSWindow *window = ((NSView *)self).window;
        if (window && !YMShouldApplyMistyEffectForWindow(window)) {
            if (gOrig_QNSView_isOpaque) {
                return gOrig_QNSView_isOpaque(self, _cmd);
            }
            return YES;
        }
    }

    return NO;
}

static void YM_QNSView_viewDidMoveToWindow(id self, SEL _cmd) {
    if (gOrig_QNSView_viewDidMoveToWindow) {
        gOrig_QNSView_viewDidMoveToWindow(self, _cmd);
    }

    if ([self isKindOfClass:[NSView class]]) {
        YMInstallBlurBackgroundBehindQNSViewAsync((NSView *)self);
        YMScheduleRoundedAvatarRefresh();
    }
}

static void YM_QNSView_viewDidMoveToSuperview(id self, SEL _cmd) {
    if (gOrig_QNSView_viewDidMoveToSuperview) {
        gOrig_QNSView_viewDidMoveToSuperview(self, _cmd);
    }

    if ([self isKindOfClass:[NSView class]]) {
        YMInstallBlurBackgroundBehindQNSViewAsync((NSView *)self);
        YMScheduleRoundedAvatarRefresh();
    }
}

static void YM_QNSView_setLayer(id self, SEL _cmd, id layer) {
    if (gOrig_QNSView_setLayer) {
        gOrig_QNSView_setLayer(self, _cmd, layer);
    }

    if (YMMistyModeEnabled() && !gYMApplyingBlurBackground && [self isKindOfClass:[NSView class]]) {
        NSView *view = (NSView *)self;
        NSWindow *window = view.window;

        // window 还没绑定时不要提前改透明度。
        // 图片预览窗口的 QNSView 可能先 setLayer、后绑定到 PreviewWindow；
        // 如果这里在 window == nil 时先改 alpha，后面即使过滤 PreviewWindow，也会造成图片预览发虚。
        if (window && YMShouldApplyMistyEffectForWindow(window)) {
            YMMakeViewTransparent(view);
            YMInstallBlurBackgroundBehindQNSViewAsync(view);
        } else if (window) {
            YMRestoreQNSViewForSkippedWindow(view);
        }
    }
}

/// 只替换一次，避免 oldImp 被覆盖成自己的 hook，导致无限递归。
static void YMReplaceInstanceMethodOnce(Class cls, SEL sel, IMP newImp, IMP *oldImpStorage) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        YMLog(@"找不到方法：%@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }

    IMP currentImp = method_getImplementation(method);

    if (currentImp == newImp) {
        YMLog(@"方法已经 hook，跳过：%@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }

    // 继承的方法应添加到 QNSView，不能改写 NSView 的实现。
    IMP oldImp = currentImp;
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(method))) {
        oldImp = method_setImplementation(method, newImp);
    }

    // 只在第一次保存原始 IMP。
    if (oldImpStorage && *oldImpStorage == NULL) {
        *oldImpStorage = oldImp;
    }

    YMLog(@"已 hook 方法：%@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void YMInstallQNSViewHooks(void) {
    if (gYMQNSViewHookInstalled) {
        return;
    }

    Class qnsClass = NSClassFromString(@"QNSView");
    if (!qnsClass) {
        YMLog(@"QNSView 类不存在，稍后重试");
        return;
    }

    gYMQNSViewHookInstalled = YES;

    YMReplaceInstanceMethodOnce(qnsClass,
                                @selector(isOpaque),
                                (IMP)YM_QNSView_isOpaque,
                                (IMP *)&gOrig_QNSView_isOpaque);

    YMReplaceInstanceMethodOnce(qnsClass,
                                @selector(viewDidMoveToWindow),
                                (IMP)YM_QNSView_viewDidMoveToWindow,
                                (IMP *)&gOrig_QNSView_viewDidMoveToWindow);

    YMReplaceInstanceMethodOnce(qnsClass,
                                @selector(viewDidMoveToSuperview),
                                (IMP)YM_QNSView_viewDidMoveToSuperview,
                                (IMP *)&gOrig_QNSView_viewDidMoveToSuperview);

    YMReplaceInstanceMethodOnce(qnsClass,
                                @selector(setLayer:),
                                (IMP)YM_QNSView_setLayer,
                                (IMP *)&gOrig_QNSView_setLayer);
}

#pragma mark - 启动入口

@implementation ModernThemeHook

+ (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    YMRegisterMistyThemeDefaults();
    gYMQtBackgroundEnabled.store(YMMistyModeEnabled(), std::memory_order_relaxed);
    YMRoundedAvatarRegisterDefaults();
    YMRoundedAvatarRefresh();
    // Avatar drawing is independent of the optional misty background feature.
    YMInstallQtCustomBackgroundHooks();
    if (!YMMistyModeEnabled()) {
        YMRefreshAllWindows();
        return;
    }

    YMInstallQNSViewHooks();
    YMInstallQtBackgroundHook();
    YMInstallQtCustomBackgroundHooks();
    YMRefreshAllWindows();
    YMStartBlurKeepAliveIfNeeded();
    if (gYMStarted) return;
    gYMStarted = YES;

    // Qt 可能延迟注册 QNSView；重试只安装一次，关闭后不重新应用主题。
    for (NSNumber *delay in @[@1, @3]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YMInstallQtCustomBackgroundHooks();
            YMRoundedAvatarRefresh();
            if (!YMMistyModeEnabled()) return;
            YMInstallQNSViewHooks();
            YMInstallQtBackgroundHook();
            YMInstallQtCustomBackgroundHooks();
            YMRefreshAllWindows();
        });
    }
}

+ (void)setBackgroundImagePath:(NSString *)path {
    // 当前版本已经从背景图 / NSVisualEffectView 切换为 WindowServer 可调背景模糊。
    // 保留这个接口只是为了兼容旧调用，避免外部代码调用时报错。
    (void)path;
    [self refreshAllQNSViews];
}

+ (void)refreshAllQNSViews {
    [self start];
}

@end


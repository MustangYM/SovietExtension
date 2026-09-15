//
//  MistyModeSettingsWindowController.m
//  SovietExtension
//
//  Created by MustangYM on 2026/7/2.
//

#import "MistyModeSettingsWindowController.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "MenuManager.h"

static const CGFloat kYMColorfulBlurRadiusMinValue = 40.0f;
static const CGFloat kYMColorfulBlurRadiusMaxValue = 160.0f;
static const NSInteger kYMMistySettingsLabelRoleTitle = 9101;
static const NSInteger kYMMistySettingsLabelRolePrimary = 9102;
static const NSInteger kYMMistySettingsLabelRoleValue = 9103;
static const NSInteger kYMMistySettingsLabelRoleSubtitle = 9104;
static const NSInteger kYMMistySettingsLabelRoleSecondary = 9105;

/// 设置窗口外观直接跟随当前微信 / AppKit 的有效外观。
/// 不再暴露“深色 / 浅色”手动选择，避免用户误解。
static BOOL YMMistySettingsUseLightAppearanceFromCurrentAppearance(void) {
    NSAppearance *appearance = NSApp.effectiveAppearance ?: NSAppearance.currentAppearance;
    NSString *bestMatch = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua,
        NSAppearanceNameDarkAqua
    ]];

    return ![bestMatch isEqualToString:NSAppearanceNameDarkAqua];
}


@interface MistyModeSettingsWindowController ()
@property (nonatomic, strong) NSSlider *alphaSlider;
@property (nonatomic, strong) NSTextField *alphaValueLabel;
@property (nonatomic, strong) NSSlider *blurRadiusSlider;
@property (nonatomic, strong) NSTextField *blurRadiusValueLabel;
@property (nonatomic, strong) NSButton *enableBlurCheckbox;
@property (nonatomic, strong) NSButton *colorfulCheckbox;
@property (nonatomic, strong) NSSlider *colorfulOpacitySlider;
@property (nonatomic, strong) NSTextField *colorfulOpacityValueLabel;
@property (nonatomic, strong) NSSlider *colorfulBlurRadiusSlider;
@property (nonatomic, strong) NSTextField *colorfulBlurRadiusValueLabel;
@property (nonatomic, strong) NSSlider *colorfulAnimationDurationSlider;
@property (nonatomic, strong) NSTextField *colorfulAnimationDurationValueLabel;
@property (nonatomic, strong) NSView *rootContentView;
@property (nonatomic, strong) NSVisualEffectView *backgroundEffectView;
@property (nonatomic, strong) NSView *colorfulCard;
@property (nonatomic, strong) NSView *basicCard;
@end

@implementation MistyModeSettingsWindowController

#pragma mark - Defaults

+ (void)registerDefaults
{
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kThemeMistyMode: @(NO),
        kThemeMistyQNSAlpha: @(0.90),
        kThemeMistyWindowBlurEnabled: @(YES),
        kThemeMistyWindowBlurRadius: @(10),
        kThemeMistyColorful: @(NO),
        kThemeMistyColorfulOpacity: @(0.42),
        kThemeMistyColorfulBlurRadius: @(70.0),
        kThemeMistyColorfulAnimationDuration: @(10.0),
    }];
}

#pragma mark - Init

- (instancetype)init
{
    NSPanel *panel = [MistyModeSettingsWindowController ym_createPanel];
    self = [super initWithWindow:panel];
    if (self) {
        [self ym_buildInterfaceInView:panel.contentView];
        [self loadSettingsToControls];
    }
    return self;
}

+ (NSPanel *)ym_createPanel
{
    NSRect frame = NSMakeRect(0, 0, 560, 820);
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                 styleMask:styleMask
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    panel.title = @"迷离模式";
    panel.releasedWhenClosed = NO;
    panel.movableByWindowBackground = YES;
    panel.level = NSFloatingWindowLevel;
    BOOL light = YMMistySettingsUseLightAppearanceFromCurrentAppearance();
    panel.appearance = [NSAppearance appearanceNamed:(light ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua)];
    panel.backgroundColor = light ? [NSColor colorWithCalibratedWhite:0.96 alpha:0.98] : [NSColor colorWithCalibratedWhite:0.08 alpha:0.96];
    panel.opaque = NO;

    NSView *contentView = [[NSView alloc] initWithFrame:frame];
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = (light ? [NSColor colorWithCalibratedWhite:0.94 alpha:0.98] : [NSColor colorWithCalibratedWhite:0.06 alpha:0.96]).CGColor;
    panel.contentView = contentView;

    return panel;
}

#pragma mark - Public

- (void)showWindowCentered
{
    [MistyModeSettingsWindowController registerDefaults];
    [self loadSettingsToControls];

    if (!self.window.isVisible) {
        [self.window center];
    }

    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

#pragma mark - UI

- (void)ym_buildInterfaceInView:(NSView *)contentView
{
    self.rootContentView = contentView;

    NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:contentView.bounds];
    effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    effect.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    effect.material = NSVisualEffectMaterialUnderWindowBackground;
    effect.state = NSVisualEffectStateActive;
    self.backgroundEffectView = effect;
    [contentView addSubview:effect];

    NSTextField *titleLabel = [self ym_labelWithFrame:NSMakeRect(32, 764, 300, 28)
                                                text:@"迷离模式"
                                                font:[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]
                                               color:[NSColor colorWithCalibratedWhite:0.98 alpha:1.0]];
    [contentView addSubview:titleLabel];

    NSTextField *subtitleLabel = [self ym_labelWithFrame:NSMakeRect(32, 736, 460, 20)
                                                   text:@"调节透明、模糊与流光氛围，自动跟随微信深浅外观"
                                                   font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]
                                                  color:[NSColor colorWithCalibratedWhite:0.72 alpha:1.0]];
    [contentView addSubview:subtitleLabel];

    self.colorfulCard = [self ym_cardViewWithFrame:NSMakeRect(24, 424, 512, 292)];
    NSView *colorfulCard = self.colorfulCard;
    [contentView addSubview:colorfulCard];

    self.colorfulCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(26, 248, 220, 24)];
    self.colorfulCheckbox.buttonType = NSSwitchButton;
    self.colorfulCheckbox.title = @"启用流光氛围";
    self.colorfulCheckbox.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    self.colorfulCheckbox.target = self;
    self.colorfulCheckbox.action = @selector(liveThemeControlChanged:);
    [colorfulCard addSubview:self.colorfulCheckbox];
    [colorfulCard addSubview:[self ym_labelWithFrame:NSMakeRect(48, 226, 420, 18)
                                                text:@"在玻璃模糊层中加入缓慢流动的柔和彩色光晕，增强空间层次。"
                                                font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                               color:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]]];

    [colorfulCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 190, 160, 20)
                                                text:@"流光强度"
                                                font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                               color:[NSColor colorWithCalibratedWhite:0.92 alpha:1.0]]];
    self.colorfulOpacityValueLabel = [self ym_labelWithFrame:NSMakeRect(430, 190, 52, 20)
                                                       text:@"42%"
                                                       font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
                                                      color:[NSColor colorWithCalibratedWhite:0.86 alpha:1.0]];
    self.colorfulOpacityValueLabel.alignment = NSTextAlignmentRight;
    [colorfulCard addSubview:self.colorfulOpacityValueLabel];

    self.colorfulOpacitySlider = [[NSSlider alloc] initWithFrame:NSMakeRect(26, 164, 456, 24)];
    self.colorfulOpacitySlider.minValue = 0.0;
    self.colorfulOpacitySlider.maxValue = 1.0;
    self.colorfulOpacitySlider.target = self;
    self.colorfulOpacitySlider.action = @selector(colorfulSliderChanged:);
    [colorfulCard addSubview:self.colorfulOpacitySlider];
    [self ym_addCupHintLabelsForSlider:self.colorfulOpacitySlider inView:colorfulCard];
    [colorfulCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 130, 456, 18)
                                                text:@"控制流光背景的整体存在感；数值越高，彩色光晕越明显。"
                                                font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                               color:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]]];

    [colorfulCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 98, 160, 20)
                                                text:@"流光大小"
                                                font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                               color:[NSColor colorWithCalibratedWhite:0.92 alpha:1.0]]];
    self.colorfulBlurRadiusValueLabel = [self ym_labelWithFrame:NSMakeRect(430, 98, 52, 20)
                                                          text:@"70"
                                                          font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
                                                         color:[NSColor colorWithCalibratedWhite:0.86 alpha:1.0]];
    self.colorfulBlurRadiusValueLabel.alignment = NSTextAlignmentRight;
    [colorfulCard addSubview:self.colorfulBlurRadiusValueLabel];

    self.colorfulBlurRadiusSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(26, 72, 456, 24)];
    self.colorfulBlurRadiusSlider.minValue = kYMColorfulBlurRadiusMinValue;
    self.colorfulBlurRadiusSlider.maxValue = kYMColorfulBlurRadiusMaxValue;
    self.colorfulBlurRadiusSlider.target = self;
    self.colorfulBlurRadiusSlider.action = @selector(colorfulSliderChanged:);
    [colorfulCard addSubview:self.colorfulBlurRadiusSlider];
    [self ym_addCupHintLabelsForSlider:self.colorfulBlurRadiusSlider inView:colorfulCard];

    [colorfulCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 28, 160, 20)
                                                text:@"流动速度"
                                                font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                               color:[NSColor colorWithCalibratedWhite:0.92 alpha:1.0]]];
    self.colorfulAnimationDurationValueLabel = [self ym_labelWithFrame:NSMakeRect(430, 28, 52, 20)
                                                                 text:@"10s"
                                                                 font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
                                                                color:[NSColor colorWithCalibratedWhite:0.86 alpha:1.0]];
    self.colorfulAnimationDurationValueLabel.alignment = NSTextAlignmentRight;
    [colorfulCard addSubview:self.colorfulAnimationDurationValueLabel];

    self.colorfulAnimationDurationSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(150, 24, 270, 24)];
    self.colorfulAnimationDurationSlider.minValue = 2.0;
    self.colorfulAnimationDurationSlider.maxValue = 60.0;
    self.colorfulAnimationDurationSlider.target = self;
    self.colorfulAnimationDurationSlider.action = @selector(colorfulSliderChanged:);
    [colorfulCard addSubview:self.colorfulAnimationDurationSlider];
    [self ym_addCupHintLabelsForSlider:self.colorfulAnimationDurationSlider inView:colorfulCard];

    self.basicCard = [self ym_cardViewWithFrame:NSMakeRect(24, 76, 512, 328)];
    NSView *basicCard = self.basicCard;
    [contentView addSubview:basicCard];

    self.enableBlurCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(26, 284, 220, 24)];
    self.enableBlurCheckbox.buttonType = NSSwitchButton;
    self.enableBlurCheckbox.title = @"启用背景模糊";
    self.enableBlurCheckbox.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    self.enableBlurCheckbox.target = self;
    self.enableBlurCheckbox.action = @selector(liveThemeControlChanged:);
    [basicCard addSubview:self.enableBlurCheckbox];
    [basicCard addSubview:[self ym_labelWithFrame:NSMakeRect(48, 262, 420, 18)
                                            text:@"开启后让窗口背后的桌面产生柔和虚化；关闭后仅保留界面透明。"
                                            font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                           color:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]]];

    [basicCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 224, 120, 20)
                                            text:@"界面透明度"
                                            font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                           color:[NSColor colorWithCalibratedWhite:0.92 alpha:1.0]]];
    self.alphaValueLabel = [self ym_labelWithFrame:NSMakeRect(430, 224, 52, 20)
                                             text:@"90%"
                                             font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
                                            color:[NSColor colorWithCalibratedWhite:0.86 alpha:1.0]];
    self.alphaValueLabel.alignment = NSTextAlignmentRight;
    [basicCard addSubview:self.alphaValueLabel];

    self.alphaSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(26, 198, 456, 24)];
    self.alphaSlider.minValue = 0.60;
    self.alphaSlider.maxValue = 1.00;
    self.alphaSlider.target = self;
    self.alphaSlider.action = @selector(alphaSliderChanged:);
    [basicCard addSubview:self.alphaSlider];
    [self ym_addCupHintLabelsForSlider:self.alphaSlider inView:basicCard];
    [basicCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 164, 456, 18)
                                            text:@"数值越低，底部模糊与流光越明显；推荐 85% ~ 95%。"
                                            font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                           color:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]]];

    [basicCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 116, 120, 20)
                                            text:@"桌面模糊"
                                            font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                           color:[NSColor colorWithCalibratedWhite:0.92 alpha:1.0]]];
    self.blurRadiusValueLabel = [self ym_labelWithFrame:NSMakeRect(430, 116, 52, 20)
                                                  text:@"10"
                                                  font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
                                                 color:[NSColor colorWithCalibratedWhite:0.86 alpha:1.0]];
    self.blurRadiusValueLabel.alignment = NSTextAlignmentRight;
    [basicCard addSubview:self.blurRadiusValueLabel];

    self.blurRadiusSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(26, 90, 456, 24)];
    self.blurRadiusSlider.minValue = 0;
    self.blurRadiusSlider.maxValue = 80;
    self.blurRadiusSlider.target = self;
    self.blurRadiusSlider.action = @selector(blurRadiusSliderChanged:);
    [basicCard addSubview:self.blurRadiusSlider];
    [self ym_addCupHintLabelsForSlider:self.blurRadiusSlider inView:basicCard];
    [basicCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 56, 456, 18)
                                            text:@"控制真实桌面背景的虚化程度；推荐 10，过高会丢失背景细节。"
                                            font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                           color:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]]];
    
    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(326, 28, 88, 34)];
    cancelButton.title = @"关闭主题";
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.target = self;
    cancelButton.action = @selector(cancelMistySettings:);
    [contentView addSubview:cancelButton];

    NSButton *confirmButton = [[NSButton alloc] initWithFrame:NSMakeRect(424, 28, 88, 34)];
    confirmButton.title = @"确定配置";
    confirmButton.bezelStyle = NSBezelStyleRounded;
    confirmButton.keyEquivalent = @"\r";
    confirmButton.target = self;
    confirmButton.action = @selector(confirmMistySettings:);
    [contentView addSubview:confirmButton];

    [self ym_applyAdaptiveAppearance];
}

- (NSView *)ym_cardViewWithFrame:(NSRect)frame
{
    NSView *view = [[NSView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    view.layer.cornerRadius = 18.0;
    view.layer.masksToBounds = YES;
    view.layer.borderWidth = 1.0;
    BOOL light = [self ym_shouldUseLightAppearance];
    view.layer.borderColor = [self ym_cardBorderColorForLight:light].CGColor;
    view.layer.backgroundColor = [self ym_cardBackgroundColorForLight:light].CGColor;
    return view;
}

- (NSTextField *)ym_labelWithFrame:(NSRect)frame
                              text:(NSString *)text
                              font:(NSFont *)font
                             color:(NSColor *)color
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text ?: @"";
    label.font = font;
    label.tag = [self ym_labelRoleForReferenceColor:color];
    label.textColor = [self ym_labelColorForRole:label.tag light:[self ym_shouldUseLightAppearance]];
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)ym_addCupHintLabelsForSlider:(NSSlider *)slider
                              inView:(NSView *)containerView
{
    if (!slider || !containerView) {
        return;
    }

    static NSArray<NSString *> *cupHints = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cupHints = @[@"中杯", @"大杯", @"特大杯"];
    });

    CGFloat labelWidth = 64.0;
    CGFloat labelHeight = 12.0;
    CGFloat labelY = NSMinY(slider.frame) - labelHeight;

    NSArray<NSNumber *> *labelXValues = @[
        @(NSMinX(slider.frame)),
        @(NSMidX(slider.frame) - labelWidth * 0.5),
        @(NSMaxX(slider.frame) - labelWidth)
    ];

    for (NSInteger index = 0; index < cupHints.count; index++) {
        NSNumber *labelXValue = labelXValues[index];
        NSString *hintText = cupHints[index];

        NSTextField *hintLabel = [self ym_labelWithFrame:NSMakeRect(labelXValue.doubleValue,
                                                                    labelY,
                                                                    labelWidth,
                                                                    labelHeight)
                                                    text:hintText
                                                    font:[NSFont systemFontOfSize:10 weight:NSFontWeightRegular]
                                                   color:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]];

        if (index == 0) {
            hintLabel.alignment = NSTextAlignmentLeft;
        } else if (index == 1) {
            hintLabel.alignment = NSTextAlignmentCenter;
        } else {
            hintLabel.alignment = NSTextAlignmentRight;
        }

        [containerView addSubview:hintLabel];
    }
}

#pragma mark - Adaptive Appearance

- (BOOL)ym_shouldUseLightAppearance
{
    return YMMistySettingsUseLightAppearanceFromCurrentAppearance();
}

- (NSColor *)ym_windowBackgroundColorForLight:(BOOL)light
{
    return light ? [NSColor colorWithCalibratedWhite:0.96 alpha:0.98] : [NSColor colorWithCalibratedWhite:0.08 alpha:0.96];
}

- (NSColor *)ym_contentBackgroundColorForLight:(BOOL)light
{
    return light ? [NSColor colorWithCalibratedWhite:0.94 alpha:0.98] : [NSColor colorWithCalibratedWhite:0.06 alpha:0.96];
}

- (NSColor *)ym_cardBackgroundColorForLight:(BOOL)light
{
    return light ? [NSColor colorWithCalibratedWhite:1.00 alpha:0.82] : [NSColor colorWithCalibratedWhite:0.12 alpha:0.78];
}

- (NSColor *)ym_cardBorderColorForLight:(BOOL)light
{
    return light ? [NSColor colorWithCalibratedWhite:0.0 alpha:0.08] : [NSColor colorWithCalibratedWhite:1.0 alpha:0.10];
}

- (NSInteger)ym_labelRoleForReferenceColor:(NSColor *)color
{
    NSColor *rgbColor = [color colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]] ?: color;
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    [rgbColor getRed:&r green:&g blue:&b alpha:&a];
    CGFloat brightness = (r + g + b) / 3.0;

    if (brightness >= 0.95) {
        return kYMMistySettingsLabelRoleTitle;
    }
    if (brightness >= 0.88) {
        return kYMMistySettingsLabelRolePrimary;
    }
    if (brightness >= 0.80) {
        return kYMMistySettingsLabelRoleValue;
    }
    if (brightness >= 0.68) {
        return kYMMistySettingsLabelRoleSubtitle;
    }
    return kYMMistySettingsLabelRoleSecondary;
}

- (NSColor *)ym_labelColorForRole:(NSInteger)role light:(BOOL)light
{
    if (light) {
        switch (role) {
            case kYMMistySettingsLabelRoleTitle:
                return [NSColor colorWithCalibratedWhite:0.08 alpha:1.0];
            case kYMMistySettingsLabelRolePrimary:
                return [NSColor colorWithCalibratedWhite:0.16 alpha:1.0];
            case kYMMistySettingsLabelRoleValue:
                return [NSColor colorWithCalibratedWhite:0.24 alpha:1.0];
            case kYMMistySettingsLabelRoleSubtitle:
                return [NSColor colorWithCalibratedWhite:0.46 alpha:1.0];
            case kYMMistySettingsLabelRoleSecondary:
            default:
                return [NSColor colorWithCalibratedWhite:0.52 alpha:1.0];
        }
    }

    switch (role) {
        case kYMMistySettingsLabelRoleTitle:
            return [NSColor colorWithCalibratedWhite:0.98 alpha:1.0];
        case kYMMistySettingsLabelRolePrimary:
            return [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
        case kYMMistySettingsLabelRoleValue:
            return [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
        case kYMMistySettingsLabelRoleSubtitle:
            return [NSColor colorWithCalibratedWhite:0.72 alpha:1.0];
        case kYMMistySettingsLabelRoleSecondary:
        default:
            return [NSColor colorWithCalibratedWhite:0.62 alpha:1.0];
    }
}

- (void)ym_applyLabelColorsInView:(NSView *)view light:(BOOL)light
{
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:[NSTextField class]]) {
            NSTextField *label = (NSTextField *)subview;
            if (label.tag >= kYMMistySettingsLabelRoleTitle &&
                label.tag <= kYMMistySettingsLabelRoleSecondary) {
                label.textColor = [self ym_labelColorForRole:label.tag light:light];
            }
        }
        [self ym_applyLabelColorsInView:subview light:light];
    }
}

- (void)ym_applyAdaptiveAppearance
{
    BOOL light = [self ym_shouldUseLightAppearance];

    self.window.appearance = [NSAppearance appearanceNamed:(light ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua)];
    self.window.backgroundColor = [self ym_windowBackgroundColorForLight:light];

    self.rootContentView.layer.backgroundColor = [self ym_contentBackgroundColorForLight:light].CGColor;

    NSArray<NSView *> *cards = @[self.colorfulCard ?: [NSView new], self.basicCard ?: [NSView new]];
    for (NSView *card in cards) {
        if (!card.superview) {
            continue;
        }
        card.layer.backgroundColor = [self ym_cardBackgroundColorForLight:light].CGColor;
        card.layer.borderColor = [self ym_cardBorderColorForLight:light].CGColor;
    }

    [self ym_applyLabelColorsInView:self.rootContentView light:light];
}

#pragma mark - Settings

- (void)loadSettingsToControls
{
    [MistyModeSettingsWindowController registerDefaults];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    self.enableBlurCheckbox.state = [defaults boolForKey:kThemeMistyWindowBlurEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    self.colorfulCheckbox.state = [defaults boolForKey:kThemeMistyColorful] ? NSControlStateValueOn : NSControlStateValueOff;
    self.alphaSlider.doubleValue = [defaults doubleForKey:kThemeMistyQNSAlpha];
    self.blurRadiusSlider.integerValue = [defaults integerForKey:kThemeMistyWindowBlurRadius];
    self.colorfulOpacitySlider.doubleValue = [defaults doubleForKey:kThemeMistyColorfulOpacity];
    CGFloat colorfulBlurRadius = [defaults doubleForKey:kThemeMistyColorfulBlurRadius];
    colorfulBlurRadius = MAX(kYMColorfulBlurRadiusMinValue, MIN(kYMColorfulBlurRadiusMaxValue, colorfulBlurRadius));
    self.colorfulBlurRadiusSlider.doubleValue = colorfulBlurRadius;
    self.colorfulAnimationDurationSlider.doubleValue = [defaults doubleForKey:kThemeMistyColorfulAnimationDuration];

    [self updateValueLabels];
    [self ym_applyAdaptiveAppearance];
}

- (void)saveSettings:(BOOL)isOpen
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // 点击确定后即认为用户启用迷离模式，菜单打勾。
    [defaults setBool:isOpen forKey:kThemeMistyMode];
    [defaults setDouble:self.alphaSlider.doubleValue forKey:kThemeMistyQNSAlpha];
    [defaults setBool:(self.enableBlurCheckbox.state == NSControlStateValueOn) forKey:kThemeMistyWindowBlurEnabled];
    [defaults setInteger:self.blurRadiusSlider.integerValue forKey:kThemeMistyWindowBlurRadius];
    [defaults setBool:(self.colorfulCheckbox.state == NSControlStateValueOn) forKey:kThemeMistyColorful];
    [defaults setDouble:self.colorfulOpacitySlider.doubleValue forKey:kThemeMistyColorfulOpacity];
    CGFloat colorfulBlurRadius = MAX(kYMColorfulBlurRadiusMinValue, MIN(kYMColorfulBlurRadiusMaxValue, self.colorfulBlurRadiusSlider.doubleValue));
    [defaults setDouble:colorfulBlurRadius forKey:kThemeMistyColorfulBlurRadius];
    [defaults setDouble:self.colorfulAnimationDurationSlider.doubleValue forKey:kThemeMistyColorfulAnimationDuration];
    [defaults synchronize];
}

- (void)applyThemeSettingsImmediately
{
    Class themeHookClass = NSClassFromString(@"ThemeHook");

    SEL refreshSelector = @selector(refreshAllQNSViews);
    if (themeHookClass && [themeHookClass respondsToSelector:refreshSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [themeHookClass performSelector:refreshSelector];
#pragma clang diagnostic pop
    }
}

- (void)saveOpenSettingsAndApplyImmediately
{
    [self saveSettings:YES];
    [self applyThemeSettingsImmediately];
    if (self.confirmHandler) self.confirmHandler(YES);
}

#pragma mark - Actions

- (void)updateValueLabels
{
    NSInteger alphaPercent = (NSInteger)lround(self.alphaSlider.doubleValue * 100.0);
    self.alphaValueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)alphaPercent];
    self.blurRadiusValueLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)self.blurRadiusSlider.integerValue];

    NSInteger colorfulOpacityPercent = (NSInteger)lround(self.colorfulOpacitySlider.doubleValue * 100.0);
    self.colorfulOpacityValueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)colorfulOpacityPercent];
    self.colorfulBlurRadiusValueLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)lround(self.colorfulBlurRadiusSlider.doubleValue)];
    self.colorfulAnimationDurationValueLabel.stringValue = [NSString stringWithFormat:@"%.0fs", self.colorfulAnimationDurationSlider.doubleValue];
}

- (void)alphaSliderChanged:(NSSlider *)sender
{
    (void)sender;
    [self updateValueLabels];
    [self saveOpenSettingsAndApplyImmediately];
}

- (void)blurRadiusSliderChanged:(NSSlider *)sender
{
    (void)sender;
    [self updateValueLabels];
    [self saveOpenSettingsAndApplyImmediately];
}

- (void)colorfulSliderChanged:(NSSlider *)sender
{
    if (sender == self.colorfulBlurRadiusSlider) {
        sender.doubleValue = MAX(kYMColorfulBlurRadiusMinValue, MIN(kYMColorfulBlurRadiusMaxValue, sender.doubleValue));
    }
    [self updateValueLabels];
    [self saveOpenSettingsAndApplyImmediately];
}

- (void)liveThemeControlChanged:(id)sender
{
    (void)sender;
    [self updateValueLabels];
    [self ym_applyAdaptiveAppearance];
    [self saveOpenSettingsAndApplyImmediately];
}

- (void)themeCheckboxChanged:(NSButton *)sender
{
    (void)sender;
    [self liveThemeControlChanged:sender];
}

- (void)cancelMistySettings:(id)sender
{
    (void)sender;
    [self saveSettings:NO];
    [self applyThemeSettingsImmediately];
    if (self.confirmHandler) {
        self.confirmHandler(NO);
    }
    [self.window close];
}

- (void)confirmMistySettings:(id)sender
{
    (void)sender;

    [self saveSettings:YES];
    [self applyThemeSettingsImmediately];

    if (self.confirmHandler) {
        self.confirmHandler(YES);
    }

    [self.window close];
}

@end

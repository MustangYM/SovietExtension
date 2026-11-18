#import "AssistantUI.h"
//
//  SkinSettingsWindowController.m
//  SovietExtension
//
//  Created by MustangYM on 2026/7/2.
//

#import "SkinSettingsWindowController.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "MenuManager.h"
#import "YMThemeImageStore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const CGFloat kYMColorfulBlurRadiusMinValue = 40.0f;
static const CGFloat kYMColorfulBlurRadiusMaxValue = 160.0f;
static const CGFloat kYMThemeCompactWindowWidth = 560.0f;
static const CGFloat kYMThemeImageWindowWidth = 960.0f;
static const NSInteger kYMMistySettingsLabelRoleTitle = 9101;
static const NSInteger kYMMistySettingsLabelRolePrimary = 9102;
static const NSInteger kYMMistySettingsLabelRoleValue = 9103;
static const NSInteger kYMMistySettingsLabelRoleSubtitle = 9104;
static const NSInteger kYMMistySettingsLabelRoleSecondary = 9105;

@interface YMThemeGalleryItem : NSCollectionViewItem
@property (nonatomic, copy) NSString *imageAddress;
@end

@implementation YMThemeGalleryItem
- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 270, 205)];
    self.view.wantsLayer = YES;
    self.view.layer.cornerRadius = 7;
    self.view.layer.borderWidth = 2;
    self.view.layer.masksToBounds = YES;

    NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(4, 28, 262, 173)];
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    imageView.wantsLayer = YES;
    imageView.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.12].CGColor;
    [self.view addSubview:imageView];
    self.imageView = imageView;

    NSTextField *caption = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 5, 254, 18)];
    caption.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    caption.bezeled = NO;
    caption.editable = NO;
    caption.drawsBackground = NO;
    caption.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    caption.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:caption];
    self.textField = caption;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    self.view.layer.borderColor = (selected ? NSColor.controlAccentColor : NSColor.clearColor).CGColor;
}
@end

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


@interface SkinSettingsWindowController () <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property (nonatomic, strong) NSSegmentedControl *modeControl;
@property (nonatomic, strong) NSView *pinkCard;
@property (nonatomic, strong) NSView *imageCard;
@property (nonatomic, strong) NSImageView *selectedImagePreview;
@property (nonatomic, strong) NSTextField *selectedImageLabel;
@property (nonatomic, strong) NSTextField *imageStatusLabel;
@property (nonatomic, strong) NSSlider *imageOpacitySlider;
@property (nonatomic, strong) NSTextField *imageOpacityValueLabel;
@property (nonatomic, strong) NSCollectionView *galleryView;
@property (nonatomic, strong) NSScrollView *galleryScrollView;
@property (nonatomic, strong) NSButton *imageChooseButton;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *galleryEntries;
@property (nonatomic, copy) NSString *pendingGalleryAddress;
@property (nonatomic, strong) NSButton *themeToggleButton;
@property (nonatomic, strong) NSTextField *themeStatusLabel;
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

@implementation SkinSettingsWindowController

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
        kThemeAppearanceMode: kThemeAppearanceMisty,
        kThemeBackgroundImageOpacity: @(0.88),
    }];
}

#pragma mark - Init

- (instancetype)init
{
    NSPanel *panel = [SkinSettingsWindowController ym_createPanel];
    self = [super initWithWindow:panel];
    if (self) {
        [self ym_buildInterfaceInView:panel.contentView];
        [self loadSettingsToControls];
    }
    return self;
}

+ (NSPanel *)ym_createPanel
{
    NSRect frame = NSMakeRect(0, 0, kYMThemeCompactWindowWidth, 820);
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                 styleMask:styleMask
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    panel.title = @"主题模式";
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
    [SkinSettingsWindowController registerDefaults];
    [self loadSettingsToControls];

    if (!self.window.isVisible) {
        [self.window center];
    }

    [NSApp activateIgnoringOtherApps:YES];
    YMUIApplyWindow(self.window); [self.window makeKeyAndOrderFront:nil];
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
                                                text:@"主题模式"
                                                font:[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]
                                               color:[NSColor colorWithCalibratedWhite:0.98 alpha:1.0]];
    [contentView addSubview:titleLabel];

    self.modeControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(24, 729, 512, 30)];
    self.modeControl.segmentCount = 3;
    [self.modeControl setLabel:@"迷离" forSegment:0];
    [self.modeControl setLabel:@"猛男粉" forSegment:1];
    [self.modeControl setLabel:@"背景图片" forSegment:2];
    self.modeControl.segmentStyle = NSSegmentStyleRounded;
    self.modeControl.target = self;
    self.modeControl.action = @selector(modeChanged:);
    [contentView addSubview:self.modeControl];

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
                                            text:@"开启后让窗口背后的桌面产生柔和虚化；关闭后仅保留背景透明。"
                                            font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                           color:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]]];

    [basicCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 224, 120, 20)
                                            text:@"背景透明度"
                                            font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                           color:[NSColor colorWithCalibratedWhite:0.92 alpha:1.0]]];
    self.alphaValueLabel = [self ym_labelWithFrame:NSMakeRect(430, 224, 52, 20)
                                             text:@"90%"
                                             font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
                                            color:[NSColor colorWithCalibratedWhite:0.86 alpha:1.0]];
    self.alphaValueLabel.alignment = NSTextAlignmentRight;
    [basicCard addSubview:self.alphaValueLabel];

    self.alphaSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(26, 198, 456, 24)];
    self.alphaSlider.minValue = 0.0;
    self.alphaSlider.maxValue = 1.00;
    self.alphaSlider.target = self;
    self.alphaSlider.action = @selector(alphaSliderChanged:);
    [basicCard addSubview:self.alphaSlider];
    [self ym_addCupHintLabelsForSlider:self.alphaSlider inView:basicCard];
    [basicCard addSubview:[self ym_labelWithFrame:NSMakeRect(26, 164, 456, 18)
                                            text:@"仅调节窗口底色；文字、按钮和图片保持原有清晰度。"
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

    [self ym_buildPinkCardInView:contentView];
    [self ym_buildImageCardInView:contentView];
    
    self.themeStatusLabel = [self ym_labelWithFrame:NSMakeRect(32, 35, 270, 20)
                                               text:@""
                                               font:[NSFont systemFontOfSize:12]
                                              color:[NSColor colorWithCalibratedWhite:0.72 alpha:1.0]];
    [contentView addSubview:self.themeStatusLabel];

    self.themeToggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(424, 28, 88, 34)];
    self.themeToggleButton.bezelStyle = NSBezelStyleRounded;
    self.themeToggleButton.target = self;
    self.themeToggleButton.action = @selector(toggleMistyMode:);
    [contentView addSubview:self.themeToggleButton];

    [self ym_applyAdaptiveAppearance];
}

- (void)ym_buildPinkCardInView:(NSView *)contentView
{
    NSView *card = [self ym_cardViewWithFrame:NSMakeRect(24, 76, 512, 640)];
    self.pinkCard = card;
    [contentView addSubview:card];

    [card addSubview:[self ym_labelWithFrame:NSMakeRect(28, 580, 440, 28)
                                        text:@"猛男粉"
                                        font:[NSFont systemFontOfSize:19 weight:NSFontWeightSemibold]
                                       color:NSColor.whiteColor]];
    [card addSubview:[self ym_labelWithFrame:NSMakeRect(28, 550, 440, 20)
                                        text:@"经典粉色铺满微信背景，消息和控件保持清晰。"
                                        font:[NSFont systemFontOfSize:12]
                                       color:NSColor.secondaryLabelColor]];

    NSView *sample = [[NSView alloc] initWithFrame:NSMakeRect(28, 292, 456, 226)];
    sample.wantsLayer = YES;
    sample.layer.cornerRadius = 12;
    sample.layer.masksToBounds = YES;
    sample.layer.backgroundColor = [NSColor colorWithCalibratedRed:229.0/255.0 green:173.0/255.0 blue:177.0/255.0 alpha:1].CGColor;
    [card addSubview:sample];

    NSView *sidebar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 70, 226)];
    sidebar.wantsLayer = YES;
    sidebar.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.18].CGColor;
    [sample addSubview:sidebar];
    for (NSInteger index = 0; index < 4; index++) {
        NSView *dot = [[NSView alloc] initWithFrame:NSMakeRect(25, 174 - index * 42, 20, 20)];
        dot.wantsLayer = YES;
        dot.layer.cornerRadius = 10;
        dot.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:index == 0 ? 0.9 : 0.48].CGColor;
        [sidebar addSubview:dot];
    }
    for (NSInteger index = 0; index < 3; index++) {
        NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(90, 172 - index * 49, 150 + index * 26, 28)];
        line.wantsLayer = YES;
        line.layer.cornerRadius = 10;
        line.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.62].CGColor;
        [sample addSubview:line];
    }
    [card addSubview:[self ym_labelWithFrame:NSMakeRect(28, 260, 456, 20)
                                        text:@"沿用旧版的 RGB 229 · 173 · 177"
                                        font:[NSFont systemFontOfSize:12]
                                       color:NSColor.secondaryLabelColor]];
}

- (void)ym_buildImageCardInView:(NSView *)contentView
{
    NSView *card = [self ym_cardViewWithFrame:NSMakeRect(24, 76, 512, 640)];
    self.imageCard = card;
    [contentView addSubview:card];

    [card addSubview:[self ym_labelWithFrame:NSMakeRect(24, 598, 280, 24)
                                        text:@"背景图片"
                                        font:[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold]
                                       color:NSColor.whiteColor]];
    NSButton *chooseButton = [[NSButton alloc] initWithFrame:NSMakeRect(354, 590, 134, 30)];
    self.imageChooseButton = chooseButton;
    chooseButton.title = @"选择本机图片…";
    chooseButton.bezelStyle = NSBezelStyleRounded;
    chooseButton.target = self;
    chooseButton.action = @selector(chooseLocalImage:);
    [card addSubview:chooseButton];

    self.selectedImagePreview = [[NSImageView alloc] initWithFrame:NSMakeRect(24, 466, 154, 108)];
    self.selectedImagePreview.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.selectedImagePreview.wantsLayer = YES;
    self.selectedImagePreview.layer.cornerRadius = 8;
    self.selectedImagePreview.layer.masksToBounds = YES;
    self.selectedImagePreview.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.12].CGColor;
    [card addSubview:self.selectedImagePreview];

    self.selectedImageLabel = [self ym_labelWithFrame:NSMakeRect(192, 530, 290, 20)
                                                text:@"尚未选择图片"
                                                font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                               color:NSColor.whiteColor];
    [card addSubview:self.selectedImageLabel];
    self.imageStatusLabel = [self ym_labelWithFrame:NSMakeRect(192, 492, 290, 34)
                                              text:@"从图库或本机选一张图片"
                                              font:[NSFont systemFontOfSize:11]
                                             color:NSColor.secondaryLabelColor];
    self.imageStatusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.imageStatusLabel.maximumNumberOfLines = 2;
    [card addSubview:self.imageStatusLabel];

    [card addSubview:[self ym_labelWithFrame:NSMakeRect(24, 431, 120, 20)
                                        text:@"图片强度"
                                        font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                       color:NSColor.whiteColor]];
    self.imageOpacityValueLabel = [self ym_labelWithFrame:NSMakeRect(431, 431, 55, 20)
                                                    text:@"88%"
                                                    font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
                                                   color:NSColor.secondaryLabelColor];
    self.imageOpacityValueLabel.alignment = NSTextAlignmentRight;
    [card addSubview:self.imageOpacityValueLabel];
    self.imageOpacitySlider = [[NSSlider alloc] initWithFrame:NSMakeRect(24, 402, 464, 24)];
    self.imageOpacitySlider.minValue = 0.2;
    self.imageOpacitySlider.maxValue = 1.0;
    self.imageOpacitySlider.target = self;
    self.imageOpacitySlider.action = @selector(imageOpacityChanged:);
    [card addSubview:self.imageOpacitySlider];

    [card addSubview:[self ym_labelWithFrame:NSMakeRect(24, 365, 460, 20)
                                        text:@"内置图库"
                                        font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                       color:NSColor.whiteColor]];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 20, 464, 338)];
    self.galleryScrollView = scroll;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    NSCollectionViewFlowLayout *layout = [NSCollectionViewFlowLayout new];
    layout.itemSize = NSMakeSize(270, 205);
    layout.minimumInteritemSpacing = 10;
    layout.minimumLineSpacing = 10;
    layout.sectionInset = NSEdgeInsetsMake(6, 4, 6, 4);
    self.galleryView = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 448, 338)];
    self.galleryView.collectionViewLayout = layout;
    self.galleryView.dataSource = self;
    self.galleryView.delegate = self;
    self.galleryView.selectable = YES;
    self.galleryView.backgroundColors = @[[NSColor clearColor]];
    [self.galleryView registerClass:YMThemeGalleryItem.class forItemWithIdentifier:@"ThemeGalleryItem"];
    scroll.documentView = self.galleryView;
    [card addSubview:scroll];
    self.galleryEntries = [YMThemeImageStore galleryEntries];
    [self.galleryView reloadData];
}

- (NSView *)ym_cardViewWithFrame:(NSRect)frame
{
    NSView *view = [[NSView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    view.layer.cornerRadius = 8.0;
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

    NSArray<NSView *> *cards = @[self.colorfulCard, self.basicCard, self.pinkCard, self.imageCard];
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
    [SkinSettingsWindowController registerDefaults];

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
    self.imageOpacitySlider.doubleValue = MAX(0.2, MIN(1.0, [defaults doubleForKey:kThemeBackgroundImageOpacity]));
    NSString *mode = [defaults stringForKey:kThemeAppearanceMode];
    self.modeControl.selectedSegment = [mode isEqualToString:kThemeAppearancePink] ? 1 :
        ([mode isEqualToString:kThemeAppearanceImage] ? 2 : 0);
    [self ym_updateWindowForMode];
    [self ym_updateSelectedImage];

    [self updateValueLabels];
    [self updateThemeStateControls];
    [self ym_applyAdaptiveAppearance];
}

- (void)updateThemeStateControls
{
    BOOL misty = self.modeControl.selectedSegment == 0;
    self.basicCard.hidden = !misty;
    self.colorfulCard.hidden = !misty;
    self.pinkCard.hidden = self.modeControl.selectedSegment != 1;
    self.imageCard.hidden = self.modeControl.selectedSegment != 2;
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kThemeMistyMode];
    self.themeToggleButton.title = enabled ? @"关闭主题" : @"开启主题";
    self.themeStatusLabel.stringValue = enabled ? @"主题已开启 · 调整即时生效" : @"主题已关闭 · 调整仅保存配置";
    if (self.confirmHandler) self.confirmHandler(enabled);
}

- (void)ym_updateWindowForMode
{
    BOOL imageMode = self.modeControl.selectedSegment == 2;
    NSRect visibleFrame = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
    CGFloat width = imageMode ? MIN(kYMThemeImageWindowWidth, NSWidth(visibleFrame) - 32.0)
                              : kYMThemeCompactWindowWidth;
    width = MAX(kYMThemeCompactWindowWidth, width);
    NSRect frame = self.window.frame;
    if (fabs(NSWidth(frame) - width) > 1.0) {
        frame.origin.x -= (width - NSWidth(frame)) / 2.0;
        frame.size.width = width;
        frame.origin.x = MAX(NSMinX(visibleFrame), MIN(frame.origin.x, NSMaxX(visibleFrame) - width));
        [self.window setFrame:frame display:YES animate:self.window.isVisible];
    }

    CGFloat cardWidth = width - 48.0;
    self.modeControl.frame = NSMakeRect(24, 729, cardWidth, 30);
    self.imageCard.frame = NSMakeRect(24, 76, cardWidth, 640);
    self.imageChooseButton.frame = NSMakeRect(cardWidth - 158, 590, 134, 30);
    self.selectedImageLabel.frame = NSMakeRect(192, 530, cardWidth - 216, 20);
    self.imageStatusLabel.frame = NSMakeRect(192, 492, cardWidth - 216, 34);
    self.imageOpacitySlider.frame = NSMakeRect(24, 402, cardWidth - 48, 24);
    self.imageOpacityValueLabel.frame = NSMakeRect(cardWidth - 81, 431, 55, 20);
    CGFloat galleryWidth = cardWidth - 48;
    self.galleryScrollView.frame = NSMakeRect(24, 20, galleryWidth, 338);
    NSCollectionViewFlowLayout *layout = (NSCollectionViewFlowLayout *)self.galleryView.collectionViewLayout;
    CGFloat cellWidth = MIN(270, floor((galleryWidth - 50) / 3.0));
    layout.itemSize = NSMakeSize(cellWidth, 205);
    [layout invalidateLayout];
    self.themeToggleButton.frame = NSMakeRect(width - 136, 28, 88, 34);
}

- (void)saveSettings:(BOOL)isOpen
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    [defaults setBool:isOpen forKey:kThemeMistyMode];
    [defaults setDouble:self.alphaSlider.doubleValue forKey:kThemeMistyQNSAlpha];
    [defaults setBool:(self.enableBlurCheckbox.state == NSControlStateValueOn) forKey:kThemeMistyWindowBlurEnabled];
    [defaults setInteger:self.blurRadiusSlider.integerValue forKey:kThemeMistyWindowBlurRadius];
    [defaults setBool:(self.colorfulCheckbox.state == NSControlStateValueOn) forKey:kThemeMistyColorful];
    [defaults setDouble:self.colorfulOpacitySlider.doubleValue forKey:kThemeMistyColorfulOpacity];
    CGFloat colorfulBlurRadius = MAX(kYMColorfulBlurRadiusMinValue, MIN(kYMColorfulBlurRadiusMaxValue, self.colorfulBlurRadiusSlider.doubleValue));
    [defaults setDouble:colorfulBlurRadius forKey:kThemeMistyColorfulBlurRadius];
    [defaults setDouble:self.colorfulAnimationDurationSlider.doubleValue forKey:kThemeMistyColorfulAnimationDuration];
    NSArray<NSString *> *modes = @[kThemeAppearanceMisty, kThemeAppearancePink, kThemeAppearanceImage];
    NSInteger segment = MAX(0, MIN((NSInteger)modes.count - 1, self.modeControl.selectedSegment));
    [defaults setObject:modes[segment] forKey:kThemeAppearanceMode];
    [defaults setDouble:self.imageOpacitySlider.doubleValue forKey:kThemeBackgroundImageOpacity];
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

- (void)saveCurrentSettingsAndApplyImmediately
{
    [self saveSettings:[[NSUserDefaults standardUserDefaults] boolForKey:kThemeMistyMode]];
    [self applyThemeSettingsImmediately];
    [self updateThemeStateControls];
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
    self.imageOpacityValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", self.imageOpacitySlider.doubleValue * 100];
}

- (void)ym_updateSelectedImage
{
    NSURL *url = [YMThemeImageStore selectedImageURL];
    self.selectedImagePreview.image = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    NSString *source = [[NSUserDefaults standardUserDefaults] stringForKey:kThemeBackgroundImageSourceURL];
    self.selectedImageLabel.stringValue = url ? (source.length ? @"内置图库" : url.lastPathComponent) : @"尚未选择图片";
    if (!self.pendingGalleryAddress.length) {
        self.imageStatusLabel.stringValue = url ? @"已保存到本机 · 切换模式即时生效" : @"从图库或本机选一张图片";
    }
}

- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView *)collectionView
{
    return 1;
}

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return self.galleryEntries.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
                   itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath
{
    YMThemeGalleryItem *item = [collectionView makeItemWithIdentifier:@"ThemeGalleryItem" forIndexPath:indexPath];
    NSDictionary *entry = self.galleryEntries[indexPath.item];
    NSString *address = entry[@"pic"];
    item.imageAddress = address;
    NSString *caption = entry[@"desc"];
    item.textField.stringValue = caption.length ? caption : [NSString stringWithFormat:@"背景 %ld", (long)indexPath.item + 1];
    item.imageView.image = nil;
    NSURL *url = [NSURL URLWithString:address];
    __weak YMThemeGalleryItem *weakItem = item;
    [YMThemeImageStore fetchGalleryImage:url completion:^(NSURL *localURL, NSError *error) {
        YMThemeGalleryItem *currentItem = weakItem;
        if ([currentItem.imageAddress isEqualToString:address] && localURL) {
            currentItem.imageView.image = [[NSImage alloc] initWithContentsOfURL:localURL];
        }
    }];
    return item;
}

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths
{
    NSIndexPath *indexPath = indexPaths.anyObject;
    if (!indexPath || indexPath.item >= self.galleryEntries.count) return;
    NSString *address = self.galleryEntries[indexPath.item][@"pic"];
    self.pendingGalleryAddress = address;
    self.imageStatusLabel.stringValue = @"正在下载所选图片…";
    [YMThemeImageStore fetchGalleryImage:[NSURL URLWithString:address]
                              completion:^(NSURL *localURL, NSError *error) {
        if (![self.pendingGalleryAddress isEqualToString:address]) return;
        self.pendingGalleryAddress = nil;
        if (!localURL) {
            self.imageStatusLabel.stringValue = error.localizedDescription ?: @"图片下载失败，请选另一张";
            return;
        }
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setObject:localURL.path forKey:kThemeBackgroundImagePath];
        [defaults setObject:address forKey:kThemeBackgroundImageSourceURL];
        [defaults setBool:YES forKey:kThemeMistyMode];
        [self ym_updateSelectedImage];
        [self saveCurrentSettingsAndApplyImmediately];
    }];
}

- (void)chooseLocalImage:(id)sender
{
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeImage];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        NSURL *url = [YMThemeImageStore saveLocalImageAtURL:panel.URL error:&error];
        if (!url) {
            self.imageStatusLabel.stringValue = error.localizedDescription ?: @"图片导入失败";
            return;
        }
        self.pendingGalleryAddress = nil;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setObject:url.path forKey:kThemeBackgroundImagePath];
        [defaults removeObjectForKey:kThemeBackgroundImageSourceURL];
        [defaults setBool:YES forKey:kThemeMistyMode];
        [self ym_updateSelectedImage];
        [self saveCurrentSettingsAndApplyImmediately];
    }];
}

- (void)modeChanged:(id)sender
{
    (void)sender;
    [self ym_updateWindowForMode];
    if (self.modeControl.selectedSegment == 2 && ![YMThemeImageStore selectedImageURL]) {
        self.imageStatusLabel.stringValue = @"请选择一张背景图片";
    } else {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kThemeMistyMode];
    }
    [self saveCurrentSettingsAndApplyImmediately];
}

- (void)imageOpacityChanged:(id)sender
{
    (void)sender;
    [self updateValueLabels];
    [self saveCurrentSettingsAndApplyImmediately];
}

- (void)alphaSliderChanged:(NSSlider *)sender
{
    (void)sender;
    [self updateValueLabels];
    [self saveCurrentSettingsAndApplyImmediately];
}

- (void)blurRadiusSliderChanged:(NSSlider *)sender
{
    (void)sender;
    [self updateValueLabels];
    [self saveCurrentSettingsAndApplyImmediately];
}

- (void)colorfulSliderChanged:(NSSlider *)sender
{
    if (sender == self.colorfulBlurRadiusSlider) {
        sender.doubleValue = MAX(kYMColorfulBlurRadiusMinValue, MIN(kYMColorfulBlurRadiusMaxValue, sender.doubleValue));
    }
    [self updateValueLabels];
    [self saveCurrentSettingsAndApplyImmediately];
}

- (void)liveThemeControlChanged:(id)sender
{
    (void)sender;
    [self updateValueLabels];
    [self ym_applyAdaptiveAppearance];
    [self saveCurrentSettingsAndApplyImmediately];
}

- (void)themeCheckboxChanged:(NSButton *)sender
{
    (void)sender;
    [self liveThemeControlChanged:sender];
}

- (void)toggleMistyMode:(id)sender
{
    (void)sender;
    BOOL enabled = ![[NSUserDefaults standardUserDefaults] boolForKey:kThemeMistyMode];
    [self saveSettings:enabled];
    [self applyThemeSettingsImmediately];
    [self updateThemeStateControls];
}

@end

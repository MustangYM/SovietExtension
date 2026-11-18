#import "AssistantUI.h"
#import "GroupRoleBadgeSettingsWindowController.h"
#import "GroupRoleBadge.h"
#import "RoundedAvatarSettingsWindowController.h"
#import "ThemeHook.h"
#include <math.h>

static NSColor *YMRoleBadgeColorFromRGB(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                               green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0
                               alpha:1];
}

static NSString *YMRoleBadgeHexFromColor(NSColor *color) {
    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!srgb) return @"#000000";
    return [NSString stringWithFormat:@"#%02X%02X%02X",
        (unsigned)lrint(srgb.redComponent * 255),
        (unsigned)lrint(srgb.greenComponent * 255),
        (unsigned)lrint(srgb.blueComponent * 255)];
}

static NSInteger YMRoleBadgeSliderPt(NSSlider *slider) {
    return lround(slider.doubleValue);
}

static NSString *YMRoleBadgePtLabel(NSInteger pt) {
    return [NSString stringWithFormat:@"%ldpt", (long)pt];
}

static void YMRoleBadgeIntegerSlider(NSSlider *slider, CGFloat min, CGFloat max) {
    slider.minValue = min;
    slider.maxValue = max;
    slider.numberOfTickMarks = (NSInteger)(max - min) + 1;
    slider.allowsTickMarkValuesOnly = YES;
    slider.continuous = YES;
}

static NSTextField *YMRoleBadgeLineField(NSRect frame, id target) {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.font = [NSFont systemFontOfSize:13];
    field.maximumNumberOfLines = 1;
    field.cell.wraps = NO;
    field.cell.scrollable = YES;
    field.target = target;
    field.action = @selector(previewChanged:);
    return field;
}

@interface YMRoleBadgePreviewCaption : NSView
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, strong) NSFont *font;
@property (nonatomic, strong) NSColor *textColor;
@end

@implementation YMRoleBadgePreviewCaption
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (void)setStringValue:(NSString *)stringValue {
    _stringValue = [stringValue copy];
    self.needsDisplay = YES;
}
- (void)setFont:(NSFont *)font {
    _font = font;
    self.needsDisplay = YES;
}
- (void)setTextColor:(NSColor *)textColor {
    _textColor = textColor;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (!self.stringValue.length || !self.font) return;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    CGFloat lineHeight = YMGroupRoleBadgeLineHeight(self.font.pointSize);
    style.minimumLineHeight = lineHeight;
    style.maximumLineHeight = lineHeight;
    NSDictionary *attrs = @{
        NSFontAttributeName: self.font,
        NSForegroundColorAttributeName: self.textColor ?: NSColor.labelColor,
        NSParagraphStyleAttributeName: style
    };
    NSString *line = YMGroupRoleBadgeLines(self.stringValue).firstObject;
    if (!line.length) return;
    NSRect bounds = self.bounds;
    NSRect slot = NSMakeRect(0, 0, bounds.size.width, lineHeight);
    NSRect text = [line boundingRectWithSize:slot.size
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:attrs];
    text.origin.x = 0;
    text.size.width = slot.size.width;
    text.origin.y = slot.origin.y + (slot.size.height - text.size.height) / 2;
    [line drawWithRect:text
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:attrs];
}
@end

@interface GroupRoleBadgeSettingsWindowController () <NSTextFieldDelegate>
@property (nonatomic, strong) NSButton *enabledBox;
@property (nonatomic, strong) NSPopUpButton *positionPopup;
@property (nonatomic, strong) NSSlider *fontSlider;
@property (nonatomic, strong) NSTextField *fontValue;
@property (nonatomic, strong) NSSlider *gapSlider;
@property (nonatomic, strong) NSTextField *gapValue;
@property (nonatomic, strong) NSColorWell *ownerColor;
@property (nonatomic, strong) NSColorWell *adminColor;
@property (nonatomic, strong) NSTextField *ownerField;
@property (nonatomic, strong) NSTextField *adminField;
@property (nonatomic, strong) NSImageView *ownerPreview;
@property (nonatomic, strong) NSImageView *adminPreview;
@property (nonatomic, strong) YMRoleBadgePreviewCaption *ownerCaption;
@property (nonatomic, strong) YMRoleBadgePreviewCaption *adminCaption;
@property (nonatomic, assign) BOOL updatingPreview;
@end

@implementation GroupRoleBadgeSettingsWindowController

- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 700, 600)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"群身份角标";
    panel.releasedWhenClosed = NO;
    self = [super initWithWindow:panel];
    if (self) {
        NSView *content = panel.contentView;
        NSTextField *title = [NSTextField labelWithString:@"群身份角标设置"];
        title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
        title.frame = NSMakeRect(370, 530, 280, 28);
        [content addSubview:title];
        NSTextField *previewTitle = [NSTextField labelWithString:@"实时预览"];
        previewTitle.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
        previewTitle.frame = NSMakeRect(40, 530, 240, 24);
        [content addSubview:previewTitle];
        NSTextField *previewHint = [NSTextField labelWithString:@"与群聊消息头像同尺寸、字号、间距"];
        previewHint.font = [NSFont systemFontOfSize:11];
        previewHint.textColor = NSColor.secondaryLabelColor;
        previewHint.frame = NSMakeRect(40, 508, 280, 16);
        [content addSubview:previewHint];

        const CGFloat avatar = YMGroupRoleBadgeChatAvatarSize;
        self.ownerPreview = [[NSImageView alloc] initWithFrame:NSMakeRect(48, 318, avatar, avatar)];
        self.adminPreview = [[NSImageView alloc] initWithFrame:NSMakeRect(128, 318, avatar, avatar)];
        for (NSImageView *imageView in @[self.ownerPreview, self.adminPreview]) {
            imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
            imageView.wantsLayer = YES;
            imageView.layer.masksToBounds = YES;
            [content addSubview:imageView];
        }
        self.ownerCaption = [[YMRoleBadgePreviewCaption alloc] initWithFrame:NSZeroRect];
        self.adminCaption = [[YMRoleBadgePreviewCaption alloc] initWithFrame:NSZeroRect];
        [content addSubview:self.ownerCaption];
        [content addSubview:self.adminCaption];

        NSTextField *scope = [NSTextField labelWithString:@"预览用当前账号头像和圆角。只叠在群聊消息头像上，不改气泡排版。群主优先于管理员。自己发的消息同样显示。"];
        scope.frame = NSMakeRect(40, 42, 310, 70);
        scope.maximumNumberOfLines = 4;
        scope.textColor = NSColor.secondaryLabelColor;
        [content addSubview:scope];

        self.enabledBox = [NSButton checkboxWithTitle:@"在群聊头像上显示身份" target:self action:@selector(previewChanged:)];
        self.enabledBox.frame = NSMakeRect(370, 490, 280, 24);
        [content addSubview:self.enabledBox];

        NSTextField *positionLabel = [NSTextField labelWithString:@"位置"];
        positionLabel.frame = NSMakeRect(370, 454, 60, 22);
        [content addSubview:positionLabel];
        self.positionPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(440, 450, 200, 28) pullsDown:NO];
        [self.positionPopup addItemWithTitle:@"头像上方"];
        [self.positionPopup addItemWithTitle:@"头像下方"];
        self.positionPopup.target = self;
        self.positionPopup.action = @selector(previewChanged:);
        [content addSubview:self.positionPopup];

        NSTextField *fontLabel = [NSTextField labelWithString:@"字号"];
        fontLabel.frame = NSMakeRect(370, 414, 60, 22);
        [content addSubview:fontLabel];
        self.fontSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(440, 414, 150, 24)];
        YMRoleBadgeIntegerSlider(self.fontSlider, YMGroupRoleBadgeFontMin, YMGroupRoleBadgeFontMax);
        self.fontSlider.target = self;
        self.fontSlider.action = @selector(previewChanged:);
        [content addSubview:self.fontSlider];
        self.fontValue = [NSTextField labelWithString:@"8pt"];
        self.fontValue.frame = NSMakeRect(600, 414, 50, 22);
        [content addSubview:self.fontValue];

        NSTextField *gapLabel = [NSTextField labelWithString:@"间距"];
        gapLabel.frame = NSMakeRect(370, 374, 60, 22);
        [content addSubview:gapLabel];
        self.gapSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(440, 374, 150, 24)];
        YMRoleBadgeIntegerSlider(self.gapSlider, YMGroupRoleBadgeGapMin, YMGroupRoleBadgeGapMax);
        self.gapSlider.target = self;
        self.gapSlider.action = @selector(previewChanged:);
        [content addSubview:self.gapSlider];
        self.gapValue = [NSTextField labelWithString:@"0pt"];
        self.gapValue.frame = NSMakeRect(600, 374, 50, 22);
        [content addSubview:self.gapValue];

        NSTextField *ownerColorLabel = [NSTextField labelWithString:@"群主颜色"];
        ownerColorLabel.frame = NSMakeRect(370, 334, 80, 22);
        [content addSubview:ownerColorLabel];
        self.ownerColor = [[NSColorWell alloc] initWithFrame:NSMakeRect(460, 330, 80, 28)];
        self.ownerColor.target = self;
        self.ownerColor.action = @selector(previewChanged:);
        [content addSubview:self.ownerColor];

        NSTextField *adminColorLabel = [NSTextField labelWithString:@"管理员颜色"];
        adminColorLabel.frame = NSMakeRect(370, 294, 90, 22);
        [content addSubview:adminColorLabel];
        self.adminColor = [[NSColorWell alloc] initWithFrame:NSMakeRect(460, 290, 80, 28)];
        self.adminColor.target = self;
        self.adminColor.action = @selector(previewChanged:);
        [content addSubview:self.adminColor];

        NSTextField *ownerTextLabel = [NSTextField labelWithString:@"群主标识"];
        ownerTextLabel.frame = NSMakeRect(370, 254, 80, 22);
        [content addSubview:ownerTextLabel];
        self.ownerField = YMRoleBadgeLineField(NSMakeRect(440, 252, 200, 24), self);
        self.ownerField.delegate = self;
        [content addSubview:self.ownerField];

        NSTextField *adminTextLabel = [NSTextField labelWithString:@"管理员标识"];
        adminTextLabel.frame = NSMakeRect(370, 214, 90, 22);
        [content addSubview:adminTextLabel];
        self.adminField = YMRoleBadgeLineField(NSMakeRect(440, 212, 200, 24), self);
        self.adminField.delegate = self;
        [content addSubview:self.adminField];

        NSTextField *textHint = [NSTextField labelWithString:@"一行居中。文字与头像间距可调。"];
        textHint.frame = NSMakeRect(370, 176, 280, 22);
        textHint.font = [NSFont systemFontOfSize:11];
        textHint.textColor = NSColor.secondaryLabelColor;
        [content addSubview:textHint];

        NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];
        cancel.frame = NSMakeRect(480, 36, 82, 30);
        [content addSubview:cancel];
        NSButton *save = [NSButton buttonWithTitle:@"保存" target:self action:@selector(save:)];
        save.frame = NSMakeRect(570, 36, 82, 30);
        save.keyEquivalent = @"\r";
        [content addSubview:save];
        [self loadControls];
    }
    return self;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    (void)notification;
    [self previewChanged:nil];
}

- (void)refreshPreviewAvatars {
    NSImage *avatar = YMRoundedAvatarPreviewImage();
    CGFloat radius = YMGroupRoleBadgeChatAvatarSize * YMRoundedAvatarRadiusPercent() / 100.0;
    for (NSImageView *imageView in @[self.ownerPreview, self.adminPreview]) {
        imageView.image = avatar;
        imageView.layer.cornerRadius = radius;
    }
}

- (void)loadControls {
    YMGroupRoleBadgeRegisterDefaults();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.enabledBox.state = [defaults boolForKey:YMGroupRoleBadgeEnabledKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    [self.positionPopup selectItemAtIndex:YMGroupRoleBadgePosition()];
    self.fontSlider.doubleValue = YMGroupRoleBadgeFontSize();
    self.gapSlider.doubleValue = YMGroupRoleBadgeGap();
    self.ownerColor.color = YMRoleBadgeColorFromRGB(YMGroupRoleBadgeColorRGB(@"群主"));
    self.adminColor.color = YMRoleBadgeColorFromRGB(YMGroupRoleBadgeColorRGB(@"管理员"));
    self.ownerField.stringValue = YMGroupRoleBadgeStoredText(
        [defaults stringForKey:YMGroupRoleBadgeOwnerTextKey], @"群主");
    self.adminField.stringValue = YMGroupRoleBadgeStoredText(
        [defaults stringForKey:YMGroupRoleBadgeAdminTextKey], @"管理员");
    [self refreshPreviewAvatars];
    [self previewChanged:nil];
}

- (NSString *)storedCaption:(NSTextField *)field fallback:(NSString *)fallback {
    return YMGroupRoleBadgeStoredText(field.stringValue, fallback);
}

- (void)previewChanged:(id)sender {
    (void)sender;
    if (self.updatingPreview) return;
    self.updatingPreview = YES;
    const NSInteger size = YMRoleBadgeSliderPt(self.fontSlider);
    const NSInteger gap = YMRoleBadgeSliderPt(self.gapSlider);
    self.fontValue.stringValue = YMRoleBadgePtLabel(size);
    self.gapValue.stringValue = YMRoleBadgePtLabel(gap);
    BOOL above = self.positionPopup.indexOfSelectedItem == 0;
    NSFont *font = [NSFont systemFontOfSize:(CGFloat)size weight:NSFontWeightMedium];
    NSString *ownerStored = [self storedCaption:self.ownerField fallback:@"群主"];
    NSString *adminStored = [self storedCaption:self.adminField fallback:@"管理员"];
    self.ownerCaption.stringValue = ownerStored;
    self.adminCaption.stringValue = adminStored;
    self.ownerCaption.frame = YMGroupRoleBadgePreviewCaptionFrame(
        self.ownerPreview.frame, (CGFloat)size, (CGFloat)gap, above);
    self.adminCaption.frame = YMGroupRoleBadgePreviewCaptionFrame(
        self.adminPreview.frame, (CGFloat)size, (CGFloat)gap, above);
    self.ownerCaption.font = font;
    self.adminCaption.font = font;
    self.ownerCaption.textColor = self.ownerColor.color;
    self.adminCaption.textColor = self.adminColor.color;
    CGFloat alpha = self.enabledBox.state == NSControlStateValueOn ? 1 : 0.35;
    self.ownerCaption.alphaValue = alpha;
    self.adminCaption.alphaValue = alpha;
    self.updatingPreview = NO;
}

- (void)cancel:(id)sender {
    (void)sender;
    [self loadControls];
    [self.window close];
}

- (void)save:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:self.enabledBox.state == NSControlStateValueOn forKey:YMGroupRoleBadgeEnabledKey];
    [defaults setInteger:self.positionPopup.indexOfSelectedItem == 1 ? 1 : 0 forKey:YMGroupRoleBadgePositionKey];
    [defaults setDouble:YMRoleBadgeSliderPt(self.fontSlider) forKey:YMGroupRoleBadgeFontSizeKey];
    [defaults setDouble:YMRoleBadgeSliderPt(self.gapSlider) forKey:YMGroupRoleBadgeGapKey];
    [defaults setObject:YMRoleBadgeHexFromColor(self.ownerColor.color) forKey:YMGroupRoleBadgeOwnerColorKey];
    [defaults setObject:YMRoleBadgeHexFromColor(self.adminColor.color) forKey:YMGroupRoleBadgeAdminColorKey];
    [defaults setObject:[self storedCaption:self.ownerField fallback:@"群主"] forKey:YMGroupRoleBadgeOwnerTextKey];
    [defaults setObject:[self storedCaption:self.adminField fallback:@"管理员"] forKey:YMGroupRoleBadgeAdminTextKey];
    [defaults synchronize];
    [ThemeHook refreshAllQNSViews];
}

- (void)showWindowCentered {
    [self loadControls];
    [self.window center];
    [NSApp activateIgnoringOtherApps:YES];
    YMUIApplyWindow(self.window); [self.window makeKeyAndOrderFront:nil];
}

@end

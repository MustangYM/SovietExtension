#import "AppearanceNative.h"
#import "AssistantUI.h"
#import "SessionMarkSettingsWindowController.h"
#import "SessionMark.h"
#import "ThemeHook.h"
#include <math.h>

static NSColor *YMSessionMarkColorFromRGB(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                               green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0
                               alpha:1];
}

static NSString *YMSessionMarkHexFromColor(NSColor *color) {
    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!srgb) return YMSessionMarkHexFromRGB(YMSessionMarkDefaultColorRGB);
    return [NSString stringWithFormat:@"#%02X%02X%02X",
        (unsigned)lrint(srgb.redComponent * 255),
        (unsigned)lrint(srgb.greenComponent * 255),
        (unsigned)lrint(srgb.blueComponent * 255)];
}

static NSColor *YMSessionMarkStoredColor(NSColor *color, uint32_t fallback) {
    return YMSessionMarkColorFromRGB(YMSessionMarkParseColor(YMSessionMarkHexFromColor(color), fallback));
}

static NSColor *YMSessionMarkListBaseColor(BOOL selected) {
    if (selected) {
        return [NSColor colorWithSRGBRed:0xF5 / 255.0 green:0xF5 / 255.0 blue:0xF5 / 255.0 alpha:1];
    }
    return [NSColor colorWithWhite:0.97 alpha:1];
}

static NSInteger YMSessionMarkSliderPt(NSSlider *slider) {
    return lround(slider.doubleValue);
}

@interface YMSessionMarkPreview : NSView
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, strong) NSColor *accent;
@property (nonatomic, strong) NSColor *placeholderColor;
@property (nonatomic, assign) CGFloat placeholderSize;
@property (nonatomic, assign) CGFloat chromeAlpha;
@property (nonatomic, assign) CGFloat washAlpha;
@property (nonatomic, copy) NSString *rowTitle;
@property (nonatomic, assign) BOOL showBorder;
@property (nonatomic, assign) BOOL enabledLook;
@end

static void YMSessionMarkDrawCorners(NSRect row, NSColor *color) {
    const CGFloat t = 4, arm = 14, m = 2, round = 2;
    [color setFill];
    NSRectFill(NSMakeRect(NSMinX(row) + m + round, NSMinY(row) + m, arm - round + 1, t));
    NSRectFill(NSMakeRect(NSMinX(row) + m, NSMinY(row) + m + round, t, arm - round + 1));
    NSRectFill(NSMakeRect(NSMaxX(row) - m - arm, NSMinY(row) + m, arm - round + 1, t));
    NSRectFill(NSMakeRect(NSMaxX(row) - m - t, NSMinY(row) + m + round, t, arm - round + 1));
    NSRectFill(NSMakeRect(NSMinX(row) + m + round, NSMaxY(row) - m - t, arm - round + 1, t));
    NSRectFill(NSMakeRect(NSMinX(row) + m, NSMaxY(row) - m - arm, t, arm - round + 1));
    NSRectFill(NSMakeRect(NSMaxX(row) - m - arm, NSMaxY(row) - m - t, arm - round + 1, t));
    NSRectFill(NSMakeRect(NSMaxX(row) - m - t, NSMaxY(row) - m - arm, t, arm - round + 1));
}

static void YMSessionMarkStrokeIcon(NSBezierPath *path) {
    path.lineWidth = 1.15;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    [[NSColor colorWithWhite:0.42 alpha:1] setStroke];
    [path stroke];
}

static void YMSessionMarkDrawToolIcon(NSRect box, NSInteger kind) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    const CGFloat x = NSMinX(box), y = NSMinY(box), w = NSWidth(box), h = NSHeight(box);
    if (kind == 0) {
        [path appendBezierPathWithOvalInRect:box];
        [path moveToPoint:NSMakePoint(x + w * 0.32, y + h * 0.40)];
        [path appendBezierPathWithOvalInRect:NSMakeRect(x + w * 0.28, y + h * 0.36, 1.6, 1.6)];
        [path moveToPoint:NSMakePoint(x + w * 0.68, y + h * 0.40)];
        [path appendBezierPathWithOvalInRect:NSMakeRect(x + w * 0.64, y + h * 0.36, 1.6, 1.6)];
        [path moveToPoint:NSMakePoint(x + w * 0.30, y + h * 0.62)];
        [path curveToPoint:NSMakePoint(x + w * 0.70, y + h * 0.62)
             controlPoint1:NSMakePoint(x + w * 0.38, y + h * 0.76)
             controlPoint2:NSMakePoint(x + w * 0.62, y + h * 0.76)];
    } else if (kind == 1) {
        [path appendBezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:2 yRadius:2];
        [path moveToPoint:NSMakePoint(x + w * 0.5, y + 2)];
        [path lineToPoint:NSMakePoint(x + w * 0.5, y + h - 2)];
        [path moveToPoint:NSMakePoint(x + 2, y + h * 0.5)];
        [path lineToPoint:NSMakePoint(x + w - 2, y + h * 0.5)];
    } else if (kind == 2) {
        [path moveToPoint:NSMakePoint(x + 1, y + h - 1.5)];
        [path lineToPoint:NSMakePoint(x + 1, y + 3.5)];
        [path lineToPoint:NSMakePoint(x + w * 0.38, y + 3.5)];
        [path lineToPoint:NSMakePoint(x + w * 0.48, y + 1.5)];
        [path lineToPoint:NSMakePoint(x + w - 1, y + 1.5)];
        [path lineToPoint:NSMakePoint(x + w - 1, y + h - 1.5)];
        [path closePath];
    } else if (kind == 3) {
        [path moveToPoint:NSMakePoint(x + 1.5, y + 1.5)];
        [path lineToPoint:NSMakePoint(x + w - 1.5, y + h - 1.5)];
        [path moveToPoint:NSMakePoint(x + w - 1.5, y + 1.5)];
        [path lineToPoint:NSMakePoint(x + 1.5, y + h - 1.5)];
    } else {
        [path appendBezierPathWithRoundedRect:NSMakeRect(x + w * 0.32, y + 1.2, w * 0.36, h * 0.58)
                                     xRadius:w * 0.18 yRadius:w * 0.18];
        [path moveToPoint:NSMakePoint(x + w * 0.22, y + h * 0.55)];
        [path curveToPoint:NSMakePoint(x + w * 0.78, y + h * 0.55)
             controlPoint1:NSMakePoint(x + w * 0.22, y + h * 0.88)
             controlPoint2:NSMakePoint(x + w * 0.78, y + h * 0.88)];
        [path moveToPoint:NSMakePoint(x + w * 0.5, y + h * 0.88)];
        [path lineToPoint:NSMakePoint(x + w * 0.5, y + h - 1)];
    }
    YMSessionMarkStrokeIcon(path);
}

static void YMSessionMarkDrawRow(NSRect row, NSString *title, NSString *time, BOOL selected,
                                NSColor *glow, NSColor *corner, CGFloat wash) {
    [YMSessionMarkListBaseColor(selected) setFill];
    NSRectFill(row);
    [[glow colorWithAlphaComponent:wash] setFill];
    NSRectFillUsingOperation(row, NSCompositingOperationSourceOver);
    NSBezierPath *avatar = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(row) + 12, NSMinY(row) + 8, 36, 36) xRadius:8 yRadius:8];
    [[NSColor colorWithWhite:0.82 alpha:1] setFill];
    [avatar fill];
    NSMutableParagraphStyle *nameStyle = [NSMutableParagraphStyle new];
    nameStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    [title drawInRect:NSMakeRect(NSMinX(row) + 56, NSMinY(row) + 10, MAX(36, NSWidth(row) - 108), 16) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.12 alpha:1],
        NSParagraphStyleAttributeName: nameStyle
    }];
    NSMutableParagraphStyle *timeStyle = [NSMutableParagraphStyle new];
    timeStyle.alignment = NSTextAlignmentRight;
    [time drawInRect:NSMakeRect(NSMaxX(row) - 48, NSMinY(row) + 11, 40, 14) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.48 alpha:1],
        NSParagraphStyleAttributeName: timeStyle
    }];
    [@"最后一条消息预览" drawInRect:NSMakeRect(NSMinX(row) + 56, NSMinY(row) + 28, MAX(36, NSWidth(row) - 70), 14) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.48 alpha:1],
        NSParagraphStyleAttributeName: nameStyle
    }];
    [[NSColor colorWithWhite:0.90 alpha:1] setFill];
    NSRectFill(NSMakeRect(NSMinX(row) + 56, NSMaxY(row) - 1, NSWidth(row) - 56, 1));
    if (selected) YMSessionMarkDrawCorners(row, [corner colorWithAlphaComponent:0.92]);
}

@implementation YMSessionMarkPreview
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect bounds = self.bounds;
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:8 yRadius:8];
    [clip addClip];
    [[NSColor colorWithWhite:0.96 alpha:1] setFill];
    NSRectFill(bounds);
    const CGFloat chrome = self.chromeAlpha > 0 ? self.chromeAlpha : YMSessionMarkAlphaDefault;
    const CGFloat wash = self.washAlpha > 0 ? self.washAlpha : YMSessionMarkWashDefault;
    NSColor *accent = self.accent ?: YMSessionMarkColorFromRGB(YMSessionMarkDefaultColorRGB);
    NSColor *srgb = [accent colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: accent;
    uint32_t rgb = ((unsigned)lrint(srgb.redComponent * 255) << 16) |
        ((unsigned)lrint(srgb.greenComponent * 255) << 8) |
        (unsigned)lrint(srgb.blueComponent * 255);
    NSColor *glow = YMSessionMarkColorFromRGB(YMSessionMarkFluorescentRGB(rgb));
    NSString *title = self.rowTitle.length ? self.rowTitle : @"会话";
    const CGFloat listW = 228;
    const CGFloat rowH = 52;
    [[NSColor colorWithWhite:0.97 alpha:1] setFill];
    NSRectFill(NSMakeRect(0, 0, listW, bounds.size.height));
    YMSessionMarkDrawRow(NSMakeRect(0, 0, listW, rowH), title, @"15:46", NO, glow, glow, wash);
    YMSessionMarkDrawRow(NSMakeRect(0, rowH, listW, rowH), title, @"15:47", YES, glow, glow, wash);
    [[NSColor colorWithWhite:0.88 alpha:1] setFill];
    NSRectFill(NSMakeRect(listW, 0, 1, bounds.size.height));
    NSRect pane = NSMakeRect(listW + 1, 0, bounds.size.width - listW - 1, bounds.size.height);
    [[NSColor colorWithWhite:0.99 alpha:1] setFill];
    NSRectFill(pane);
    NSRect bubble = NSMakeRect(NSMinX(pane) + 16, 16, MIN(220, NSWidth(pane) - 48), 28);
    [[NSColor colorWithWhite:0.93 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bubble xRadius:8 yRadius:8] fill];
    [@"最后一条消息预览" drawInRect:NSInsetRect(bubble, 10, 6) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.35 alpha:1]
    }];
    NSRect card = NSMakeRect(NSMinX(pane) + 8, NSMaxY(pane) - 70, NSWidth(pane) - 16, 62);
    [[NSColor colorWithWhite:0.97 alpha:1] setFill];
    NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:card xRadius:10 yRadius:10];
    [cardPath fill];
    NSRect inner = NSMakeRect(NSMinX(card) + 8, NSMinY(card) + 6, NSWidth(card) - 16, 28);
    [[NSColor whiteColor] setFill];
    NSBezierPath *innerPath = [NSBezierPath bezierPathWithRoundedRect:inner xRadius:8 yRadius:8];
    [innerPath fill];
    [NSGraphicsContext saveGraphicsState];
    [innerPath addClip];
    [[glow colorWithAlphaComponent:wash] setFill];
    NSRectFillUsingOperation(inner, NSCompositingOperationSourceOver);
    [NSGraphicsContext restoreGraphicsState];
    if (self.placeholder.length) {
        [YMSessionMarkQuotedString(self.placeholder,
            self.placeholderSize > 0 ? self.placeholderSize : 14,
            self.placeholderColor ?: NSColor.secondaryLabelColor, NSTextAlignmentLeft)
            drawInRect:NSMakeRect(NSMinX(inner) + 10, NSMinY(inner) + 5, NSWidth(inner) - 20, 18)];
    }
    if (self.showBorder) {
        NSBezierPath *stroke = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(inner, 0.5, 0.5)
            xRadius:8 yRadius:8];
        [[accent colorWithAlphaComponent:chrome] setStroke];
        stroke.lineWidth = 1;
        stroke.lineCapStyle = NSLineCapStyleRound;
        stroke.lineJoinStyle = NSLineJoinStyleRound;
        [stroke stroke];
    }
    const CGFloat iconY = NSMaxY(card) - 22;
    for (NSInteger i = 0; i < 5; ++i) {
        YMSessionMarkDrawToolIcon(NSMakeRect(NSMinX(card) + 12 + i * 22, iconY, 13, 13), i);
    }
    if (!self.enabledLook) {
        [[NSColor colorWithWhite:1 alpha:0.45] setFill];
        NSRectFillUsingOperation(bounds, NSCompositingOperationSourceOver);
    }
}
@end

@interface SessionMarkSettingsWindowController () <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSButton *enabledBox;
@property (nonatomic, strong) NSButton *scopeAdded;
@property (nonatomic, strong) NSButton *scopeExcept;
@property (nonatomic, strong) NSTableView *markTable;
@property (nonatomic, strong) NSButton *addMarkButton;
@property (nonatomic, strong) NSButton *removeMarkButton;
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSColorWell *colorWell;
@property (nonatomic, strong) NSButton *borderBox;
@property (nonatomic, strong) NSSlider *washSlider;
@property (nonatomic, strong) NSTextField *washValue;
@property (nonatomic, strong) NSSlider *alphaSlider;
@property (nonatomic, strong) NSTextField *alphaValue;
@property (nonatomic, strong) NSTextField *placeholderField;
@property (nonatomic, strong) NSSlider *placeholderSlider;
@property (nonatomic, strong) NSTextField *placeholderValue;
@property (nonatomic, strong) NSColorWell *placeholderColor;
@property (nonatomic, strong) NSTextField *sessionLabel;
@property (nonatomic, strong) NSTableView *sessionTable;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) YMSessionMarkPreview *preview;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *drafts;
@property (nonatomic, assign) NSInteger selected;
@property (nonatomic, copy) NSString *editingAccount;
@property (nonatomic, assign) BOOL updating;
@end

static NSTableCellView *YMSessionMarkLabelCell(NSTableView *tableView) {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"label" owner:nil];
    if (cell) return cell;
    cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
    cell.identifier = @"label";
    NSTextField *field = [NSTextField labelWithString:@""];
    field.drawsBackground = NO;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.font = [NSFont systemFontOfSize:13];
    [cell addSubview:field];
    cell.textField = field;
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
        [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
        [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
    ]];
    return cell;
}

@implementation SessionMarkSettingsWindowController

- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 760, 680)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"会话标识";
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    self = [super initWithWindow:panel];
    if (self) {
        NSView *content = panel.contentView;
        NSTextField *title = [NSTextField labelWithString:@"会话标识"];
        title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
        title.frame = NSMakeRect(24, 640, 280, 28);
        [content addSubview:title];
        NSTextField *hint = [NSTextField labelWithString:@"按会话着色，防止发错。不影响通知。"];
        hint.font = [NSFont systemFontOfSize:11];
        hint.textColor = NSColor.secondaryLabelColor;
        hint.frame = NSMakeRect(24, 618, 500, 18);
        [content addSubview:hint];

        self.enabledBox = [NSButton checkboxWithTitle:@"启用会话标识" target:self action:@selector(previewChanged:)];
        self.enabledBox.frame = NSMakeRect(560, 644, 180, 24);
        [content addSubview:self.enabledBox];

        NSTextField *scopeLabel = [NSTextField labelWithString:@"范围"];
        scopeLabel.frame = NSMakeRect(240, 588, 60, 22);
        [content addSubview:scopeLabel];
        NSView *scopeBox = [[NSView alloc] initWithFrame:NSMakeRect(310, 586, 250, 28)];
        [content addSubview:scopeBox];
        self.scopeAdded = [NSButton radioButtonWithTitle:@"仅已标记"
            target:self action:@selector(scopeChanged:)];
        self.scopeAdded.frame = NSMakeRect(0, 2, 108, 24);
        self.scopeAdded.toolTip = @"只着色已加入标识组的会话。";
        [scopeBox addSubview:self.scopeAdded];
        self.scopeExcept = [NSButton radioButtonWithTitle:@"仅未标记"
            target:self action:@selector(scopeChanged:)];
        self.scopeExcept.frame = NSMakeRect(118, 2, 108, 24);
        self.scopeExcept.toolTip = @"已加入标识组的不着色，其余用第一组。";
        [scopeBox addSubview:self.scopeExcept];

        NSScrollView *markScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 280, 196, 332)];
        markScroll.hasVerticalScroller = YES;
        markScroll.borderType = NSBezelBorder;
        self.markTable = [[NSTableView alloc] initWithFrame:markScroll.bounds];
        NSTableColumn *markColumn = [[NSTableColumn alloc] initWithIdentifier:@"mark"];
        markColumn.width = 170;
        NSTextFieldCell *markDataCell = [[NSTextFieldCell alloc] initTextCell:@""];
        markDataCell.lineBreakMode = NSLineBreakByTruncatingTail;
        markColumn.dataCell = markDataCell;
        [self.markTable addTableColumn:markColumn];
        self.markTable.headerView = nil;
        self.markTable.rowHeight = 22;
        self.markTable.allowsEmptySelection = NO;
        self.markTable.delegate = self;
        self.markTable.dataSource = self;
        self.markTable.target = self;
        self.markTable.action = @selector(selectMark:);
        markScroll.documentView = self.markTable;
        [content addSubview:markScroll];

        self.addMarkButton = [NSButton buttonWithTitle:@"新增组" target:self action:@selector(addMark:)];
        self.addMarkButton.frame = NSMakeRect(24, 244, 92, 28);
        [content addSubview:self.addMarkButton];
        self.removeMarkButton = [NSButton buttonWithTitle:@"删除组" target:self action:@selector(removeMark:)];
        self.removeMarkButton.frame = NSMakeRect(128, 244, 92, 28);
        [content addSubview:self.removeMarkButton];

        NSTextField *nameLabel = [NSTextField labelWithString:@"名称"];
        nameLabel.frame = NSMakeRect(240, 552, 60, 22);
        [content addSubview:nameLabel];
        self.nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(310, 550, 220, 24)];
        self.nameField.delegate = self;
        [content addSubview:self.nameField];

        NSTextField *colorLabel = [NSTextField labelWithString:@"颜色"];
        colorLabel.frame = NSMakeRect(548, 552, 36, 22);
        [content addSubview:colorLabel];
        self.colorWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(588, 546, 44, 28)];
        self.colorWell.target = self;
        self.colorWell.action = @selector(previewChanged:);
        self.colorWell.continuous = YES;
        [content addSubview:self.colorWell];

        NSTextField *washLabel = [NSTextField labelWithString:@"色罩"];
        washLabel.frame = NSMakeRect(240, 516, 60, 22);
        [content addSubview:washLabel];
        self.washSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(310, 516, 220, 24)];
        self.washSlider.minValue = YMSessionMarkWashMin;
        self.washSlider.maxValue = YMSessionMarkWashMax;
        self.washSlider.numberOfTickMarks = 17;
        self.washSlider.allowsTickMarkValuesOnly = YES;
        self.washSlider.continuous = YES;
        self.washSlider.target = self;
        self.washSlider.action = @selector(previewChanged:);
        self.washSlider.toolTip = @"列表与空输入的着色强度。";
        [content addSubview:self.washSlider];
        self.washValue = [NSTextField labelWithString:@"14%"];
        self.washValue.frame = NSMakeRect(540, 516, 48, 22);
        [content addSubview:self.washValue];

        self.borderBox = [NSButton checkboxWithTitle:@"描边" target:self action:@selector(previewChanged:)];
        self.borderBox.frame = NSMakeRect(240, 476, 60, 24);
        self.borderBox.toolTip = @"输入区彩色描边。";
        [content addSubview:self.borderBox];
        self.alphaSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(310, 478, 220, 24)];
        self.alphaSlider.minValue = YMSessionMarkAlphaMin;
        self.alphaSlider.maxValue = YMSessionMarkAlphaMax;
        self.alphaSlider.numberOfTickMarks = 15;
        self.alphaSlider.allowsTickMarkValuesOnly = YES;
        self.alphaSlider.continuous = YES;
        self.alphaSlider.target = self;
        self.alphaSlider.action = @selector(previewChanged:);
        self.alphaSlider.toolTip = @"描边不透明度。";
        [content addSubview:self.alphaSlider];
        self.alphaValue = [NSTextField labelWithString:@"80%"];
        self.alphaValue.frame = NSMakeRect(540, 478, 48, 22);
        [content addSubview:self.alphaValue];

        NSTextField *placeholderLabel = [NSTextField labelWithString:@"占位符"];
        placeholderLabel.frame = NSMakeRect(240, 444, 60, 22);
        [content addSubview:placeholderLabel];
        self.placeholderField = [[NSTextField alloc] initWithFrame:NSMakeRect(310, 442, 220, 24)];
        self.placeholderField.placeholderString = @"留空则按名称生成";
        self.placeholderField.delegate = self;
        [content addSubview:self.placeholderField];
        self.placeholderColor = [[NSColorWell alloc] initWithFrame:NSMakeRect(588, 438, 44, 28)];
        self.placeholderColor.toolTip = @"占位符颜色。";
        self.placeholderColor.target = self;
        self.placeholderColor.action = @selector(previewChanged:);
        self.placeholderColor.continuous = YES;
        [content addSubview:self.placeholderColor];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(colorPanelChanged:)
                                                     name:NSColorPanelColorDidChangeNotification
                                                   object:nil];

        NSTextField *sizeLabel = [NSTextField labelWithString:@"字号"];
        sizeLabel.frame = NSMakeRect(240, 408, 60, 22);
        [content addSubview:sizeLabel];
        self.placeholderSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(310, 408, 220, 24)];
        self.placeholderSlider.minValue = YMSessionMarkPlaceholderSizeMin;
        self.placeholderSlider.maxValue = YMSessionMarkPlaceholderSizeMax;
        self.placeholderSlider.numberOfTickMarks = (NSInteger)(YMSessionMarkPlaceholderSizeMax - YMSessionMarkPlaceholderSizeMin) + 1;
        self.placeholderSlider.allowsTickMarkValuesOnly = YES;
        self.placeholderSlider.continuous = YES;
        self.placeholderSlider.target = self;
        self.placeholderSlider.action = @selector(previewChanged:);
        [content addSubview:self.placeholderSlider];
        self.placeholderValue = [NSTextField labelWithString:@"14pt"];
        self.placeholderValue.frame = NSMakeRect(540, 408, 48, 22);
        [content addSubview:self.placeholderValue];

        self.sessionLabel = [NSTextField labelWithString:@"会话"];
        self.sessionLabel.frame = NSMakeRect(240, 372, 60, 22);
        [content addSubview:self.sessionLabel];
        NSScrollView *sessionScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(310, 280, 426, 88)];
        sessionScroll.hasVerticalScroller = YES;
        sessionScroll.borderType = NSBezelBorder;
        self.sessionTable = [[NSTableView alloc] initWithFrame:sessionScroll.bounds];
        NSTableColumn *sessionColumn = [[NSTableColumn alloc] initWithIdentifier:@"session"];
        sessionColumn.width = 400;
        NSTextFieldCell *sessionDataCell = [[NSTextFieldCell alloc] initTextCell:@""];
        sessionDataCell.lineBreakMode = NSLineBreakByTruncatingTail;
        sessionColumn.dataCell = sessionDataCell;
        [self.sessionTable addTableColumn:sessionColumn];
        self.sessionTable.headerView = nil;
        self.sessionTable.rowHeight = 22;
        self.sessionTable.delegate = self;
        self.sessionTable.dataSource = self;
        sessionScroll.documentView = self.sessionTable;
        [content addSubview:sessionScroll];
        NSButton *choose = [NSButton buttonWithTitle:@"添加会话…" target:self action:@selector(chooseSessions:)];
        choose.frame = NSMakeRect(310, 244, 110, 28);
        [content addSubview:choose];
        NSButton *removeSession = [NSButton buttonWithTitle:@"移除会话" target:self action:@selector(removeSession:)];
        removeSession.frame = NSMakeRect(428, 244, 110, 28);
        [content addSubview:removeSession];

        NSTextField *previewTitle = [NSTextField labelWithString:@"预览"];
        previewTitle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        previewTitle.frame = NSMakeRect(24, 220, 80, 16);
        [content addSubview:previewTitle];
        self.preview = [[YMSessionMarkPreview alloc] initWithFrame:NSMakeRect(24, 48, 712, 168)];
        self.preview.wantsLayer = YES;
        self.preview.layer.cornerRadius = 8;
        [content addSubview:self.preview];

        self.statusLabel = [NSTextField labelWithString:@"取消不保存。保存后立即生效，窗口不关。"];
        self.statusLabel.font = [NSFont systemFontOfSize:11];
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
        self.statusLabel.frame = NSMakeRect(24, 16, 520, 22);
        [content addSubview:self.statusLabel];

        NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];
        cancel.frame = NSMakeRect(564, 12, 82, 30);
        [content addSubview:cancel];
        NSButton *save = [NSButton buttonWithTitle:@"保存" target:self action:@selector(save:)];
        save.frame = NSMakeRect(656, 12, 82, 30);
        save.keyEquivalent = @"\r";
        [content addSubview:save];
        [self loadControls];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)colorPanelChanged:(NSNotification *)note {
    (void)note;
    if (self.updating) return;
    if (self.colorWell.active || self.placeholderColor.active)
        [self previewChanged:nil];
}

- (NSMutableDictionary *)currentMark {
    if (self.selected < 0 || self.selected >= (NSInteger)self.drafts.count) return nil;
    return self.drafts[(NSUInteger)self.selected];
}

- (NSArray *)currentSessions {
    return self.currentMark[@"sessions"] ?: @[];
}

- (BOOL)exceptAddedMode {
    return self.scopeExcept.state == NSControlStateValueOn;
}

- (void)applyScopeUI {
    BOOL except = self.exceptAddedMode;
    self.addMarkButton.enabled = !except;
    self.removeMarkButton.enabled = !except && self.drafts.count > 1;
    self.nameField.enabled = !except;
    self.sessionLabel.stringValue = except ? @"排除" : @"会话";
}

- (void)scopeChanged:(id)sender {
    (void)sender;
    [self applyScopeUI];
    [self previewChanged:nil];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    (void)notification;
    [self previewChanged:nil];
}

- (void)loadControls {
    YMSessionMarkRegisterDefaults();
    self.editingAccount = YMAppearanceAccount() ?: @"";
    self.enabledBox.state = YMSessionMarkEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL except = YMSessionMarkScope() == YMSessionMarkScopeExceptAdded;
    self.scopeAdded.state = except ? NSControlStateValueOff : NSControlStateValueOn;
    self.scopeExcept.state = except ? NSControlStateValueOn : NSControlStateValueOff;
    NSArray *stored = YMSessionMarkSets(self.editingAccount);
    self.drafts = [NSMutableArray array];
    for (NSDictionary *item in stored) [self.drafts addObject:[item mutableCopy]];
    if (!self.drafts.count) [self.drafts addObject:YMSessionMarkDefaultSet(@"工作")];
    self.selected = 0;
    [self.markTable reloadData];
    [self.markTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self loadMarkToControls];
}

- (void)loadMarkToControls {
    self.updating = YES;
    NSDictionary *mark = self.currentMark ?: YMSessionMarkDefaultSet(@"工作");
    self.nameField.stringValue = mark[@"name"] ?: @"工作";
    self.colorWell.color = YMSessionMarkColorFromRGB(YMSessionMarkParseColor(mark[@"color"], YMSessionMarkDefaultColorRGB));
    self.borderBox.state = [mark[@"border"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.washSlider.doubleValue = YMSessionMarkClampWash(
        [mark[@"wash"] respondsToSelector:@selector(doubleValue)]
            ? [mark[@"wash"] doubleValue] : YMSessionMarkWashDefault);
    self.placeholderField.stringValue = mark[@"placeholder"] ?: @"";
    self.placeholderSlider.doubleValue = YMSessionMarkClampPlaceholderSize([mark[@"placeholderSize"] doubleValue]);
    self.placeholderColor.color = YMSessionMarkColorFromRGB(
        YMSessionMarkParseColor(mark[@"placeholderColor"], YMSessionMarkDefaultPlaceholderRGB));
    self.alphaSlider.doubleValue = YMSessionMarkClampAlpha(
        [mark[@"alpha"] respondsToSelector:@selector(doubleValue)]
            ? [mark[@"alpha"] doubleValue] : YMSessionMarkAlphaDefault);
    [self.sessionTable reloadData];
    self.updating = NO;
    [self applyScopeUI];
    [self previewChanged:nil];
}

- (void)storeControlsToMark {
    NSMutableDictionary *mark = self.currentMark;
    if (!mark || self.updating) return;
    mark[@"name"] = YMSessionMarkStoredName(self.nameField.stringValue, @"工作");
    mark[@"color"] = YMSessionMarkHexFromColor(self.colorWell.color);
    mark[@"border"] = @(self.borderBox.state == NSControlStateValueOn);
    mark[@"placeholder"] = self.placeholderField.stringValue ?: @"";
    mark[@"placeholderSize"] = @(YMSessionMarkSliderPt(self.placeholderSlider));
    mark[@"placeholderColor"] = YMSessionMarkHexFromColor(self.placeholderColor.color);
    mark[@"alpha"] = @(YMSessionMarkClampAlpha(self.alphaSlider.doubleValue));
    mark[@"wash"] = @(YMSessionMarkClampWash(self.washSlider.doubleValue));
}

- (void)previewChanged:(id)sender {
    (void)sender;
    if (self.updating) return;
    [self storeControlsToMark];
    NSInteger pt = YMSessionMarkSliderPt(self.placeholderSlider);
    self.placeholderValue.stringValue = [NSString stringWithFormat:@"%ldpt", (long)pt];
    CGFloat alpha = YMSessionMarkClampAlpha(self.alphaSlider.doubleValue);
    self.alphaValue.stringValue = [NSString stringWithFormat:@"%.0f%%", alpha * 100.0];
    CGFloat wash = YMSessionMarkClampWash(self.washSlider.doubleValue);
    self.washValue.stringValue = [NSString stringWithFormat:@"%.0f%%", wash * 100.0];
    NSDictionary *mark = self.currentMark ?: YMSessionMarkDefaultSet(@"工作");
    NSMutableDictionary *shown = [mark mutableCopy];
    if (self.exceptAddedMode) shown[@"exceptAdded"] = @YES;
    self.preview.placeholder = YMSessionMarkPlaceholderText(shown);
    self.preview.accent = YMSessionMarkStoredColor(self.colorWell.color, YMSessionMarkDefaultColorRGB);
    self.preview.placeholderColor = YMSessionMarkStoredColor(
        self.placeholderColor.color, YMSessionMarkDefaultPlaceholderRGB);
    self.preview.placeholderSize = pt;
    self.preview.chromeAlpha = alpha;
    self.preview.washAlpha = wash;
    self.preview.rowTitle = self.exceptAddedMode ? YMSessionMarkExceptAddedName : (mark[@"name"] ?: @"会话");
    self.preview.showBorder = self.borderBox.state == NSControlStateValueOn;
    self.preview.enabledLook = self.enabledBox.state == NSControlStateValueOn;
    self.alphaSlider.enabled = self.borderBox.state == NSControlStateValueOn;
    self.preview.needsDisplay = YES;
    [self.markTable reloadData];
    if (self.selected >= 0)
        [self.markTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)self.selected] byExtendingSelection:NO];
}

- (void)selectMark:(id)sender {
    (void)sender;
    [self storeControlsToMark];
    self.selected = self.markTable.selectedRow;
    if (self.selected < 0) self.selected = 0;
    [self loadMarkToControls];
}

- (void)addMark:(id)sender {
    (void)sender;
    if (self.exceptAddedMode) return;
    if (self.drafts.count >= YMSessionMarkSetLimit) {
        self.statusLabel.stringValue = @"最多 12 组标识";
        return;
    }
    [self storeControlsToMark];
    [self.drafts addObject:YMSessionMarkDefaultSet(@"客户")];
    self.selected = (NSInteger)self.drafts.count - 1;
    [self.markTable reloadData];
    [self.markTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)self.selected] byExtendingSelection:NO];
    [self loadMarkToControls];
}

- (void)removeMark:(id)sender {
    (void)sender;
    if (self.exceptAddedMode) return;
    if (self.drafts.count <= 1) {
        self.statusLabel.stringValue = @"至少保留一组标识";
        return;
    }
    if (self.selected >= 0 && self.selected < (NSInteger)self.drafts.count)
        [self.drafts removeObjectAtIndex:(NSUInteger)self.selected];
    self.selected = MIN(self.selected, (NSInteger)self.drafts.count - 1);
    [self.markTable reloadData];
    [self.markTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)self.selected] byExtendingSelection:NO];
    [self loadMarkToControls];
}

- (void)chooseSessions:(id)sender {
    (void)sender;
    [self storeControlsToMark];
    NSString *account = self.editingAccount;
    NSMutableDictionary *mark = self.currentMark;
    if (!mark) return;
    BOOL opened = YMAppearanceChooseConversations(^(NSArray<NSString *> *ids) {
        if (![account isEqual:YMAppearanceAccount() ?: @""]) return;
        NSMutableArray *sessions = [mark[@"sessions"] mutableCopy] ?: [NSMutableArray array];
        NSMutableDictionary *titles = [mark[@"sessionTitles"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSUInteger added = 0;
        for (NSString *session in ids) {
            NSString *canonical = YMSessionMarkCanonicalSession(session);
            if (!YMSessionMarkAcceptsSession(canonical, account) || sessions.count >= YMSessionMarkSessionLimit) continue;
            if ([sessions containsObject:canonical]) continue;
            [sessions addObject:canonical];
            NSString *name = nil;
            @try { name = YMAppearanceSessionName(canonical); } @catch (NSException *exception) { (void)exception; }
            if (name.length) titles[canonical] = name;
            added++;
        }
        mark[@"sessions"] = sessions;
        mark[@"sessionTitles"] = titles;
        [self.sessionTable reloadData];
        [self previewChanged:nil];
        YMUIApplyWindow(self.window); [self.window makeKeyAndOrderFront:nil];
        self.statusLabel.stringValue = added
            ? [NSString stringWithFormat:@"已添加 %lu 个会话", (unsigned long)added]
            : @"所选会话是公众号、自己或不支持的类型，未添加";
    });
    if (!opened) self.statusLabel.stringValue = @"暂时无法打开联系人选择器";
}

- (void)removeSession:(id)sender {
    (void)sender;
    NSMutableDictionary *mark = self.currentMark;
    if (!mark) return;
    NSInteger row = self.sessionTable.selectedRow;
    NSMutableArray *sessions = [mark[@"sessions"] mutableCopy] ?: [NSMutableArray array];
    if (row < 0 || row >= (NSInteger)sessions.count) return;
    NSString *session = sessions[(NSUInteger)row];
    [sessions removeObjectAtIndex:(NSUInteger)row];
    NSMutableDictionary *titles = [mark[@"sessionTitles"] mutableCopy] ?: [NSMutableDictionary dictionary];
    [titles removeObjectForKey:session];
    mark[@"sessions"] = sessions;
    mark[@"sessionTitles"] = titles;
    [self.sessionTable reloadData];
    [self previewChanged:nil];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.markTable) return (NSInteger)self.drafts.count;
    return (NSInteger)self.currentSessions.count;
}

- (NSString *)textForTableView:(NSTableView *)tableView row:(NSInteger)row {
    if (tableView == self.markTable) {
        NSDictionary *mark = (row >= 0 && row < (NSInteger)self.drafts.count) ? self.drafts[(NSUInteger)row] : nil;
        return mark[@"name"] ?: @"工作";
    }
    NSArray *sessions = self.currentSessions;
    NSString *session = (row >= 0 && row < (NSInteger)sessions.count) ? sessions[(NSUInteger)row] : @"";
    NSString *title = YMSessionMarkSessionTitle(self.currentMark, session);
    if (!title.length) {
        @try { title = YMAppearanceSessionName(session); } @catch (NSException *exception) { (void)exception; }
    }
    return title.length ? [NSString stringWithFormat:@"%@  %@", title, session] : session;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)column;
    return [self textForTableView:tableView row:row];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)column;
    NSTableCellView *cell = YMSessionMarkLabelCell(tableView);
    cell.textField.stringValue = [self textForTableView:tableView row:row];
    return cell;
}

- (void)cancel:(id)sender {
    (void)sender;
    [self loadControls];
    [self.window close];
}

- (void)save:(id)sender {
    (void)sender;
    if (![self.editingAccount isEqual:YMAppearanceAccount() ?: @""]) {
        [self loadControls];
        self.statusLabel.stringValue = @"账号已切换，请重新编辑后保存";
        return;
    }
    [self storeControlsToMark];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:self.enabledBox.state == NSControlStateValueOn forKey:YMSessionMarkEnabledKey];
    YMSessionMarkSetScope(self.exceptAddedMode ? YMSessionMarkScopeExceptAdded : YMSessionMarkScopeAdded);
    YMSessionMarkSaveSets(self.editingAccount, self.drafts);
    [ThemeHook refreshAllQNSViews];
    self.statusLabel.stringValue = @"已保存";
    [self.window makeKeyAndOrderFront:nil];
}

- (void)showWindowCentered {
    [self loadControls];
    [self.window center];
    [NSApp activateIgnoringOtherApps:YES];
    YMUIApplyWindow(self.window); [self.window makeKeyAndOrderFront:nil];
}

@end

#import "AssistantUI.h"
@interface YMAssistantSurface ()
@property NSTrackingArea *hoverArea;
@property BOOL hovered;
@end
@implementation YMAssistantSurface
- (void)updateTrackingAreas {
    [super updateTrackingAreas];if(self.hoverArea)[self removeTrackingArea:self.hoverArea];
    self.hoverArea=nil;
    if(self.hoverEnabled){self.hoverArea=[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];[self addTrackingArea:self.hoverArea];}
}
- (void)mouseEntered:(NSEvent *)event {self.hovered=YES;self.needsDisplay=YES;}
- (void)mouseExited:(NSEvent *)event {self.hovered=NO;self.needsDisplay=YES;}
- (void)drawRect:(NSRect)dirty {
    if(self.separatorOnly){
        if(self.hoverEnabled && self.hovered){[[NSColor.controlAccentColor colorWithAlphaComponent:.07] setFill];[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,4,2) xRadius:7 yRadius:7] fill];}
        [[NSColor.separatorColor colorWithAlphaComponent:.4] setFill];NSRectFill(NSMakeRect(16,0,MAX(0,self.bounds.size.width-32),.5));
    } else {
        NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:10 yRadius:10];
        [NSColor.controlBackgroundColor setFill];[shape fill];
        [[NSColor.separatorColor colorWithAlphaComponent:.25] setStroke];shape.lineWidth=.5;[shape stroke];
    }
}
- (void)viewDidChangeEffectiveAppearance {[super viewDidChangeEffectiveAppearance];self.needsDisplay=YES;}
@end
NSTextField *YMUIlabel(NSString *text,CGFloat size,BOOL secondary,NSRect frame){
    NSTextField *label=[NSTextField wrappingLabelWithString:text];label.font=[NSFont systemFontOfSize:size weight:secondary?NSFontWeightRegular:NSFontWeightMedium];label.textColor=secondary?NSColor.secondaryLabelColor:NSColor.labelColor;label.frame=frame;return label;
}
void YMUIConfigureWindow(NSWindow *window){window.backgroundColor=NSColor.windowBackgroundColor;window.titlebarAppearsTransparent=YES;window.movableByWindowBackground=NO;}
NSButton *YMUIButton(NSString *title,id target,SEL action,NSRect frame,BOOL primary){NSButton *button=[NSButton buttonWithTitle:title target:target action:action];button.bezelStyle=NSBezelStyleRounded;button.frame=frame;if(primary)button.keyEquivalent=@"\r";return button;}
@interface YMUITimestampEditor ()
@property NSTextField *sampleTime;
@end
@implementation YMUITimestampEditor
- (instancetype)initWithFrame:(NSRect)frame {
    if(!(self=[super initWithFrame:frame]))return nil;
    YMAssistantSurface *preview=[[YMAssistantSurface alloc]initWithFrame:NSMakeRect(0,164,460,96)];[self addSubview:preview];
    [preview addSubview:YMUIlabel(@"时间样式预览",11,YES,NSMakeRect(16,66,200,16))];
    NSImageView *avatar=[[NSImageView alloc]initWithFrame:NSMakeRect(18,28,30,30)];avatar.image=[NSImage imageWithSystemSymbolName:@"person.crop.circle.fill" accessibilityDescription:@"模拟头像"];avatar.contentTintColor=NSColor.secondaryLabelColor;[preview addSubview:avatar];
    [preview addSubview:YMUIlabel(@"把日常聊成故事。",13,NO,NSMakeRect(72,36,320,24))];
    self.sampleTime=YMUIlabel(@"",11,YES,NSMakeRect(16,8,420,18));[preview addSubview:self.sampleTime];
    self.enabled=[NSButton checkboxWithTitle:@"显示每条消息的时间" target:self action:@selector(refreshPreview:)];self.enabled.frame=NSMakeRect(0,122,450,26);[self addSubview:self.enabled];
    [self addSubview:YMUIlabel(@"显示格式",13,NO,NSMakeRect(0,87,110,22))];
    self.format=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(128,82,332,28) pullsDown:NO];[self.format addItemsWithTitles:@[@"智能日期 · 今天 / 昨天 / 前天",@"完整日期 · 年 / 月 / 日",@"仅显示时分"]];self.format.target=self;self.format.action=@selector(refreshPreview:);[self addSubview:self.format];
    [self addSubview:YMUIlabel(@"自定义颜色",13,NO,NSMakeRect(0,43,110,22))];
    self.colorWell=[[NSColorWell alloc]initWithFrame:NSMakeRect(128,38,88,28)];self.colorWell.target=self;self.colorWell.action=@selector(refreshPreview:);[self addSubview:self.colorWell];
    return self;
}
- (void)refreshPreview:(id)sender {
    NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateFormat=self.format.indexOfSelectedItem==1?@"yyyy/MM/dd HH:mm":@"HH:mm";
    NSString *text=[formatter stringFromDate:NSDate.date];if(self.format.indexOfSelectedItem==0)text=[@"今天 " stringByAppendingString:text];
    self.sampleTime.stringValue=self.enabled.state==NSControlStateValueOn?text:@"时间显示已关闭";
    self.sampleTime.textColor=self.enabled.state==NSControlStateValueOn?self.colorWell.color:NSColor.secondaryLabelColor;
}
@end

YMAssistantSurface *YMUIAddSurface(NSView *parent, NSRect frame){
    YMAssistantSurface *surface=[[YMAssistantSurface alloc]initWithFrame:frame];
    NSView *first=parent.subviews.firstObject;
    [parent addSubview:surface positioned:[first isKindOfClass:NSVisualEffectView.class]?NSWindowAbove:NSWindowBelow relativeTo:first];return surface;
}
void YMUIApplyView(NSView *view){
    // Never rebuild controls, change target/action, values, visibility or enabled state.
    if([view isKindOfClass:NSTextField.class]){
        NSTextField *field=(NSTextField *)view;
        BOOL mono=(field.font.fontDescriptor.symbolicTraits & NSFontDescriptorTraitMonoSpace)!=0;
        if(!mono && field.font.pointSize>=18)field.font=[NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
        else if(!mono && field.font.pointSize>15 && field.font.pointSize<18)field.font=[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
        if(field.editable && ![field isKindOfClass:NSSearchField.class]){field.bezelStyle=NSTextFieldRoundedBezel;field.backgroundColor=NSColor.textBackgroundColor;if(!mono)field.font=[NSFont systemFontOfSize:13];}
    } else if([view isKindOfClass:NSButton.class]){
        NSButton *button=(NSButton *)view;
        if((!button.image || button.imagePosition!=NSImageOnly) && button.font.pointSize>13)button.font=[NSFont systemFontOfSize:13];
    } else if([view isKindOfClass:NSScrollView.class]){
        NSScrollView *scroll=(NSScrollView *)view;scroll.scrollerStyle=NSScrollerStyleOverlay;
        if(scroll.borderType==NSBezelBorder)scroll.borderType=NSLineBorder;
    }
    // A document's individual rows/previews own their formatting. Do not touch them.
    if([view isKindOfClass:NSTableView.class] || [view isKindOfClass:NSTextView.class] || [view isKindOfClass:NSControl.class])return;
    if([view isKindOfClass:NSScrollView.class]){NSView *document=[(NSScrollView *)view documentView];if(document)YMUIApplyView(document);return;}
    for(NSView *child in view.subviews)YMUIApplyView(child);
}
void YMUIApplyWindow(NSWindow *window){if(!window)return;YMUIConfigureWindow(window);YMUIApplyView(window.contentView);}
@implementation YMAssistantFloatingView
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{self.layer.borderColor=[NSColor.separatorColor colorWithAlphaComponent:.55].CGColor;}];
}
@end

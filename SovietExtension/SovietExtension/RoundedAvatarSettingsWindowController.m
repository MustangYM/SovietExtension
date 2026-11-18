#import "AssistantUI.h"
#import "RoundedAvatarSettingsWindowController.h"
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>

#import <objc/runtime.h>
#import <math.h>

NSString * const kYMRoundedAvatarRadiusPercent = @"YMRoundedAvatarRadiusPercent.SOVIET";
static const void *kYMRoundedAvatarSavedCorner = &kYMRoundedAvatarSavedCorner;
static const void *kYMRoundedAvatarSavedMask = &kYMRoundedAvatarSavedMask;
static const void *kYMRoundedAvatarApplied = &kYMRoundedAvatarApplied;

void YMRoundedAvatarRegisterDefaults(void) {
    // 默认值只注册一次，避免刷新视图时反复触发偏好合并和 KVO 通知。
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{kYMRoundedAvatarRadiusPercent: @0}];
    });
}

CGFloat YMRoundedAvatarRadiusPercent(void) {
    YMRoundedAvatarRegisterDefaults();
    return MAX(0.0, MIN(50.0, [NSUserDefaults.standardUserDefaults doubleForKey:kYMRoundedAvatarRadiusPercent]));
}

static BOOL YMAvatarCandidate(NSView *view) {
    if (![view isKindOfClass:NSImageView.class] &&
        ![view isKindOfClass:NSButton.class]) return NO;
    NSSize size = view.bounds.size;
    if (size.width < 16 || size.height < 16 || fabs(size.width - size.height) > 2.0) return NO;
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@ %@ %@ %@",
        NSStringFromClass(view.class), view.identifier ?: @"", view.accessibilityIdentifier ?: @"",
        view.toolTip ?: @"", view.description ?: @""];
    NSString *lower = text.lowercaseString;
    NSArray *avatarWords = @[@"avatar", @"head", @"contact", @"profile", @"sns", @"头像", @"headview"];
    NSArray *excludedWords = @[@"emoji", @"emoticon", @"qr", @"preview", @"sticker"];
    for (NSString *word in excludedWords) if ([lower containsString:word]) return NO;
    for (NSString *word in avatarWords) if ([lower containsString:word]) return YES;
    return NO;
}

static void YMApplyAvatarCorner(NSView *view, CGFloat percent) {
    if (!YMAvatarCandidate(view)) return;
    if (!view.wantsLayer) view.wantsLayer = YES;
    CALayer *layer = view.layer;
    if (!objc_getAssociatedObject(layer, kYMRoundedAvatarApplied)) {
        objc_setAssociatedObject(layer, kYMRoundedAvatarSavedCorner, @(layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, kYMRoundedAvatarSavedMask, @(layer.masksToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, kYMRoundedAvatarApplied, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat radius = MIN(view.bounds.size.width, view.bounds.size.height) * percent / 100.0;
    if (layer.cornerRadius != radius || !layer.masksToBounds) {
        layer.cornerRadius = radius;
        layer.masksToBounds = YES;
        view.needsDisplay = YES;
    }
}

static void YMRestoreAvatarCorner(NSView *view) {
    CALayer *layer = view.layer;
    if (!objc_getAssociatedObject(layer, kYMRoundedAvatarApplied)) return;
    NSNumber *corner = objc_getAssociatedObject(layer, kYMRoundedAvatarSavedCorner);
    NSNumber *mask = objc_getAssociatedObject(layer, kYMRoundedAvatarSavedMask);
    if (!corner || !mask) return;
    if (layer.cornerRadius != corner.doubleValue || layer.masksToBounds != mask.boolValue) {
        layer.cornerRadius = corner.doubleValue;
        layer.masksToBounds = mask.boolValue;
        view.needsDisplay = YES;
    }
    objc_setAssociatedObject(layer, kYMRoundedAvatarApplied, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(layer, kYMRoundedAvatarSavedCorner, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(layer, kYMRoundedAvatarSavedMask, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void YMRefreshAvatarTree(NSView *view, CGFloat percent) {
    if (!view) return;
    if (percent > 0) YMApplyAvatarCorner(view, percent);
    else YMRestoreAvatarCorner(view);
    // 未变化的普通视图无需重绘；Qt 头像仍由设置保存时的原生刷新处理。
    for (NSView *child in [view.subviews copy]) YMRefreshAvatarTree(child, percent);
}

void YMRoundedAvatarRefresh(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ YMRoundedAvatarRefresh(); });
        return;
    }
    CGFloat percent = YMRoundedAvatarRadiusPercent();
    for (NSWindow *window in NSApp.windows) {
        YMRefreshAvatarTree(window.contentView, percent);
    }
}

void YMScheduleRoundedAvatarRefresh(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ YMScheduleRoundedAvatarRefresh(); });
        return;
    }
    // Qt 创建图片窗口会连续移动多个视图，只需在这批变化结束后遍历一次。
    static BOOL pending = NO;
    if (pending) return;
    pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        YMRoundedAvatarRefresh();
        pending = NO;
    });
}

static void YMRefreshQtAvatarPaint(void) {
    // shortcut: WeChat's zoom actions refresh observed Qt avatar surfaces; replace
    // this pair with a verified Qt update entry when its private ABI is known.
    for (NSMenuItem *section in NSApp.mainMenu.itemArray) {
        NSMenu *menu = section.submenu;
        NSMenuItem *zoomIn = nil, *zoomOut = nil;
        for (NSMenuItem *item in menu.itemArray) {
            if (![NSStringFromSelector(item.action) isEqualToString:@"qt_itemFired:"]) continue;
            if ([@[@"Zoom In", @"放大"] containsObject:item.title]) zoomIn = item;
            if ([@[@"Zoom Out", @"缩小"] containsObject:item.title]) zoomOut = item;
        }
        if (!zoomIn || !zoomOut || (!zoomIn.isEnabled && !zoomOut.isEnabled)) continue;
        NSMenuItem *first = zoomIn.isEnabled ? zoomIn : zoomOut;
        NSMenuItem *second = first == zoomIn ? zoomOut : zoomIn;
        // Qt menu items use nil targets; send both before the next screen update.
        if ([NSApp sendAction:first.action to:nil from:first])
            [NSApp sendAction:second.action to:nil from:second];
        return;
    }
}

static NSString *YMAvatarCacheRoot(void) {
    NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat"];
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:support error:nil];
    entries = [entries sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDictionary *aa = [[NSFileManager defaultManager] attributesOfItemAtPath:[support stringByAppendingPathComponent:a] error:nil];
        NSDictionary *bb = [[NSFileManager defaultManager] attributesOfItemAtPath:[support stringByAppendingPathComponent:b] error:nil];
        return [bb[NSFileModificationDate] compare:aa[NSFileModificationDate]];
    }];
    for (NSString *entry in entries) {
        NSString *root = [support stringByAppendingPathComponent:entry];
        BOOL directory = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&directory] && directory &&
            [[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"topinfo.data"]] &&
            [[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"Avatar"]]) return root;
    }
    return nil;
}

static NSString *YMTopInfoAvatarURL(NSString *root) {
    if (!root.length) return nil;
    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"topinfo.data"]
                                          options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *bytes = data.bytes; const size_t length = data.length;
    if (!bytes || !length) return nil;
    const char *prefix = "https://wx.qlogo.";
    const size_t prefixLength = strlen(prefix);
    for (size_t start = 0; start + prefixLength < length; ++start) {
        if (memcmp(bytes + start, prefix, prefixLength)) continue;
        // topinfo.data is protobuf-like; use the preceding length-delimited
        // field so the trailing field tag is never mistaken for URL text.
        for (size_t tag = start > 5 ? start - 5 : 0; tag < start; ++tag) {
            if ((bytes[tag] & 7) != 2) continue;
            size_t cursor = tag + 1, valueLength = 0, shift = 0;
            while (cursor < start && shift <= 28) {
                uint8_t value = bytes[cursor++]; valueLength |= (size_t)(value & 0x7f) << shift;
                if (!(value & 0x80)) break; shift += 7;
            }
            if (cursor != start || valueLength > length - start) continue;
            NSString *url = [[NSString alloc] initWithBytes:bytes + start length:valueLength encoding:NSUTF8StringEncoding];
            if ([url hasPrefix:@"https://wx.qlogo."]) return url;
        }
    }
    return nil;
}

static NSImage *YMAvatarImageFromCache(void) {
    NSString *root = YMAvatarCacheRoot();
    NSString *url = YMTopInfoAvatarURL(root);
    if (!url.length) return nil;
    unsigned char digest[CC_MD5_DIGEST_LENGTH] = {};
    NSData *urlData = [url dataUsingEncoding:NSUTF8StringEncoding];
    // WeChat uses the URL MD5 as the local Avatar cache key; this is not a security hash.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(urlData.bytes, (CC_LONG)urlData.length, digest);
#pragma clang diagnostic pop
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    NSString *path = [[root stringByAppendingPathComponent:@"Avatar"] stringByAppendingPathComponent:
        [hex stringByAppendingPathExtension:@"jpg"]];
    return [[NSImage alloc] initWithContentsOfFile:path];
}

// 普通递归避免 block 在初始化时捕获尚未赋值的自身，缓存缺失也能安全查找。
static NSImage *YMAvatarImageInView(NSView *view) {
    if (!view) return nil;
    if (YMAvatarCandidate(view)) {
        NSImage *image = [view isKindOfClass:NSImageView.class] ? [(NSImageView *)view image] : [(NSButton *)view image];
        if (image) return image;
    }
    for (NSView *child in [view.subviews copy]) {
        NSImage *image = YMAvatarImageInView(child);
        if (image) return image;
    }
    return nil;
}

NSImage *YMRoundedAvatarPreviewImage(void) {
    NSImage *cached = YMAvatarImageFromCache();
    if (cached) return cached;
    // Menu tracking windows are transient and may change while the action is being dismissed.
    return YMAvatarImageInView(NSApp.mainWindow.contentView) ?: [NSImage imageNamed:NSImageNameUser];
}

@interface RoundedAvatarSettingsWindowController ()
@property(nonatomic,strong) NSSlider *slider;
@property(nonatomic,strong) NSTextField *valueLabel;
@property(nonatomic,strong) NSImageView *preview;
@property(nonatomic,strong) NSArray<NSImageView *> *examplePreviews;
@end

@implementation RoundedAvatarSettingsWindowController

- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 700, 430)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"头像圆角";
    panel.releasedWhenClosed = NO;
    self = [super initWithWindow:panel];
    if (self) {
        YMUIConfigureWindow(panel);
        NSView *content=panel.contentView;
        [content addSubview:YMUIlabel(@"头像圆角",20,NO,NSMakeRect(24,374,652,28))];
        [content addSubview:YMUIlabel(@"调整头像形状，保存后应用于微信。",12,YES,NSMakeRect(24,344,652,22))];
        YMAssistantSurface *surface=[[YMAssistantSurface alloc]initWithFrame:NSMakeRect(24,142,652,184)];[content addSubview:surface];
        [surface addSubview:YMUIlabel(@"效果对照",11,YES,NSMakeRect(20,150,400,18))];
        NSImage *avatar=YMRoundedAvatarPreviewImage();
        NSImageView *square=[[NSImageView alloc]initWithFrame:NSMakeRect(116,52,72,72)];
        self.preview=[[NSImageView alloc]initWithFrame:NSMakeRect(290,52,72,72)];
        NSImageView *circle=[[NSImageView alloc]initWithFrame:NSMakeRect(464,52,72,72)];
        self.examplePreviews=@[square,self.preview,circle];
        for(NSImageView *imageView in self.examplePreviews){imageView.image=avatar;imageView.imageScaling=NSImageScaleProportionallyUpOrDown;imageView.wantsLayer=YES;imageView.layer.masksToBounds=YES;[surface addSubview:imageView];}
        [@[@"方形 · 0%",@"当前设置",@"圆形 · 50%"] enumerateObjectsUsingBlock:^(NSString *text,NSUInteger i,BOOL *stop){NSTextField *caption=YMUIlabel(text,12,YES,NSMakeRect(92+i*174,22,120,20));caption.alignment=NSTextAlignmentCenter;[surface addSubview:caption];}];
        [content addSubview:YMUIlabel(@"圆角程度",13,NO,NSMakeRect(24,100,100,22))];
        self.slider=[[NSSlider alloc]initWithFrame:NSMakeRect(140,100,456,24)];self.slider.minValue=0;self.slider.maxValue=50;self.slider.target=self;self.slider.action=@selector(sliderChanged:);[self.slider setAccessibilityLabel:@"头像圆角程度"];[content addSubview:self.slider];
        self.valueLabel=YMUIlabel(@"0%",13,NO,NSMakeRect(610,100,66,24));self.valueLabel.alignment=NSTextAlignmentRight;[content addSubview:self.valueLabel];
        [content addSubview:YMUIlabel(@"预览使用当前账号头像；取消会保留原设置。",11,YES,NSMakeRect(24,65,652,20))];
        NSButton *cancel=YMUIButton(@"取消",self,@selector(cancel:),NSMakeRect(474,20,94,32),NO);cancel.keyEquivalent=@"\e";[content addSubview:cancel];
        [content addSubview:YMUIButton(@"保存设置",self,@selector(save:),NSMakeRect(576,20,100,32),YES)];
        [self loadControls];
    }
    return self;
}

- (void)loadControls { self.slider.doubleValue = YMRoundedAvatarRadiusPercent(); [self sliderChanged:self.slider]; }
- (void)sliderChanged:(NSSlider *)sender {
    self.valueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", sender.doubleValue];
    self.preview.layer.cornerRadius = MIN(self.preview.bounds.size.width, self.preview.bounds.size.height) * sender.doubleValue / 100.0;
    self.examplePreviews.firstObject.layer.cornerRadius = 0;
    self.examplePreviews.lastObject.layer.cornerRadius = MIN(self.examplePreviews.lastObject.bounds.size.width, self.examplePreviews.lastObject.bounds.size.height) / 2.0;
}
- (void)cancel:(id)sender { [self loadControls]; [self.window close]; }
- (void)save:(id)sender {
    if (self.slider.doubleValue == YMRoundedAvatarRadiusPercent()) {
        [self.window close];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setDouble:self.slider.doubleValue forKey:kYMRoundedAvatarRadiusPercent];
    [[NSUserDefaults standardUserDefaults] synchronize];
    YMRoundedAvatarRefresh();
    [self.window close];
    dispatch_async(dispatch_get_main_queue(), ^{ YMRefreshQtAvatarPaint(); });
}
- (void)showWindowCentered { [self loadControls]; [self.window center]; [NSApp activateIgnoringOtherApps:YES]; YMUIApplyWindow(self.window); [self.window makeKeyAndOrderFront:nil]; }
@end

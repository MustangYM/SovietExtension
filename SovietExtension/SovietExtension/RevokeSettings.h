#ifndef YMRevokeSettings_h
#define YMRevokeSettings_h

#import <Foundation/Foundation.h>

typedef struct {
    BOOL enabled;
    BOOL others;
    BOOL self;
    BOOL forward;
    BOOL forwardOthers;
    BOOL forwardSelf;
} YMRevokeSettings;

static inline void YMRegisterSelfRevokeDefault(NSUserDefaults *defaults)
{
    if ([defaults objectForKey:@"kSelfAntiRevoke.SOVIET"] == nil) {
        [defaults setBool:[defaults boolForKey:@"kAntiRevoke.SOVIET"]
                  forKey:@"kSelfAntiRevoke.SOVIET"];
    }
    if ([defaults objectForKey:@"kRevokeEnabled.SOVIET"] == nil) {
        [defaults setBool:([defaults boolForKey:@"kAntiRevoke.SOVIET"] ||
                           [defaults boolForKey:@"kSelfAntiRevoke.SOVIET"])
                  forKey:@"kRevokeEnabled.SOVIET"];
    }
    for (NSString *key in @[@"kRevokeForwardOthers.SOVIET", @"kRevokeForwardSelf.SOVIET"]) {
        if ([defaults objectForKey:key] == nil) [defaults setBool:YES forKey:key];
    }
    if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] isEqualToString:@"269079"]) {
        // 兼容旧版“总开关关闭但子项仍选中”的配置，保持关闭状态而非重新启用。
        for (NSArray<NSString *> *group in @[@[@"kRevokeEnabled.SOVIET", @"kAntiRevoke.SOVIET", @"kSelfAntiRevoke.SOVIET"],
                                            @[@"kRevokeForwardToSelfRealSend.SOVIET", @"kRevokeForwardOthers.SOVIET", @"kRevokeForwardSelf.SOVIET"]]) {
            if (![defaults boolForKey:group[0]]) {
                [defaults setBool:NO forKey:group[1]];
                [defaults setBool:NO forKey:group[2]];
            } else if (![defaults boolForKey:group[1]] && ![defaults boolForKey:group[2]]) {
                [defaults setBool:NO forKey:group[0]];
            }
        }
    }
    [defaults synchronize];
}

static inline YMRevokeSettings YMReadRevokeSettings(NSUserDefaults *defaults)
{
    YMRevokeSettings settings = {
        [defaults boolForKey:@"kRevokeEnabled.SOVIET"],
        [defaults boolForKey:@"kAntiRevoke.SOVIET"],
        [defaults boolForKey:@"kSelfAntiRevoke.SOVIET"],
        [defaults boolForKey:@"kRevokeForwardToSelfRealSend.SOVIET"],
        [defaults boolForKey:@"kRevokeForwardOthers.SOVIET"],
        [defaults boolForKey:@"kRevokeForwardSelf.SOVIET"],
    };
    return settings;
}

#endif

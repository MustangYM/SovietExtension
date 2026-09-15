#ifndef YMRevokeSettings_h
#define YMRevokeSettings_h

#import <Foundation/Foundation.h>

typedef struct {
    BOOL others;
    BOOL self;
} YMRevokeSettings;

static inline void YMRegisterSelfRevokeDefault(NSUserDefaults *defaults)
{
    if ([defaults objectForKey:@"kSelfAntiRevoke.SOVIET"] == nil) {
        [defaults setBool:[defaults boolForKey:@"kAntiRevoke.SOVIET"]
                  forKey:@"kSelfAntiRevoke.SOVIET"];
        [defaults synchronize];
    }
}

static inline YMRevokeSettings YMReadRevokeSettings(NSUserDefaults *defaults)
{
    YMRevokeSettings settings = {
        [defaults boolForKey:@"kAntiRevoke.SOVIET"],
        [defaults boolForKey:@"kSelfAntiRevoke.SOVIET"],
    };
    return settings;
}

#endif

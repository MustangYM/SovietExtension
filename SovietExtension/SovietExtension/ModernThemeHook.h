#pragma once
#import <Foundation/Foundation.h>

@interface ModernThemeHook : NSObject
+ (void)start;
@end
BOOL YMModernCarrierStyleIsDark(void);
BOOL YMModernColorfulBlurBackgroundEnabled(void);
CGFloat YMModernColorfulBlurBackgroundOpacity(void);
CGFloat YMModernColorfulBlurInternalBlurRadius(void);
NSTimeInterval YMModernColorfulAnimationDuration(void);

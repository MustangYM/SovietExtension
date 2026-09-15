#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

// 只支持逐点校验过的 Build269079 arm64；失败不启用任何新撤回行为。
bool YMInstallSelfRevokePatch(void);
bool YMIsOwnRevokeWrap(uintptr_t originalWrap);
bool YMPrepareSelfRevoke(uintptr_t originalSP, bool retain);
NSString *YMSelfRevokeAccount(void);
NSString *YMSelfRevokeSession(uintptr_t wrap);

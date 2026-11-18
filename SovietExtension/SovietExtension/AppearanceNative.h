#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
#include <string>
bool YMReadAppearanceSession(uintptr_t address, std::string &out) noexcept;
#endif
FOUNDATION_EXPORT NSString *YMAppearanceAccount(void);
FOUNDATION_EXPORT BOOL YMAppearanceValidSession(NSString *value);
FOUNDATION_EXPORT NSString *YMAppearanceSessionName(NSString *session);
FOUNDATION_EXPORT BOOL YMAppearanceChooseConversations(void (^completion)(NSArray<NSString *> *));

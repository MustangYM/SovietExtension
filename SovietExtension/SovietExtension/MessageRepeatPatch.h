#pragma once
#import "MessageMenuPatch.h"
#if defined(__aarch64__)
// 主线程创建/触发；session须对应快照原会话。每个返回动作最多提交一次，不表示已送达。
std::function<void()> YMMessageRepeatAction(std::shared_ptr<YMMessageSnapshot> message, NSString *session);
#endif

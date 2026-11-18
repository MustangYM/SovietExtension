#pragma once
#import <Foundation/Foundation.h>
#include <functional>
#include <cstdint>

void YMInstallForwardNoticeNavigation(void);
// 原生发送入口可保持原样，或使用本模块已安装且仍完整的透传桥。
bool YMForwardNoticeSendEntryCompatible(void);
// 作用域仅覆盖插件通知的同步提交；目标信息不写入 MessageData。
class YMForwardNoticeScope {
    NSDictionary *previous;
    NSDictionary *current;
public:
    explicit YMForwardNoticeScope(NSDictionary *target);
    ~YMForwardNoticeScope();
    YMForwardNoticeScope(const YMForwardNoticeScope &) = delete;
};
std::function<void()> YMForwardNoticeOriginalAction(uintptr_t messageData);

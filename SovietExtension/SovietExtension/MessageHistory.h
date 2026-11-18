#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

FOUNDATION_EXPORT NSNotificationName const YMMessageHistoryDeletedNotification;
// 服务端 ID 优先；仅本地消息须同时具备 localID、sortSeq、createSec，避免 ID 重用误删。
FOUNDATION_EXPORT NSDictionary *YMMessageHistoryIdentity(NSString *session, uint32_t localID, uint64_t serverID, uint64_t sortSeq, uint32_t createSec);
FOUNDATION_EXPORT NSString *YMMessageHistoryStorageKey(NSDictionary *message);
FOUNDATION_EXPORT BOOL YMMessageHistoryDeletionMatches(NSDictionary *deletion, NSString *account, NSDictionary *message);
// nil session 表示账号全部，nil messages 表示会话全部；非 nil 空数组不发布。
// 立即复制信息后异步发到主队列，原生数据库回调不等待主线程。
FOUNDATION_EXPORT void YMPostMessageHistoryDeletion(NSString *account, NSString *session, NSArray<NSDictionary *> *messages);

#import <Foundation/Foundation.h>
#include <stdint.h>
#ifdef __cplusplus
#include <vector>
#endif

NS_ASSUME_NONNULL_BEGIN

// 只记录本机生成的转发提醒；完整载体标识匹配后才允许定位原文。
BOOL YMStoreForwardNotice(NSString *account, NSString *session, uint32_t localID,
    uint64_t sortSeq, uint32_t createSec, NSString *sourceSession, uint64_t sourceServerID);
NSDictionary * _Nullable YMLoadForwardNotice(NSString *account, NSString *session,
    uint32_t localID, uint64_t sortSeq, uint32_t createSec);

// 仅清理插件定位记录；调用方应在微信确认删除成功后调用。
BOOL YMClearForwardNoticesForSession(NSString *account, NSString *session);
BOOL YMClearForwardNoticesForAccount(NSString *account);
#ifdef __cplusplus
struct YMForwardNoticeMessageIdentity {
    uint32_t localID = 0;
    uint64_t sortSeq = 0;
    uint32_t createSec = 0;
    uint64_t serverID = 0;
};
BOOL YMDeleteForwardNoticesForMessages(NSString *account, NSString *session,
    const std::vector<YMForwardNoticeMessageIdentity> &messages);
#endif

NS_ASSUME_NONNULL_END

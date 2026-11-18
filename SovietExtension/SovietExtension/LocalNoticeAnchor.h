#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
// 临时构造 token/account/session/originalServerID，全部随系统消息 XML 入库。
NSDictionary * _Nullable YMCreateLocalNoticeAnchor(NSString *account, NSString *session,
                                                  uint64_t originalServerID);
NSString * _Nullable YMAddLocalNoticeAnchorToXML(NSString *xml, NSDictionary *anchor);
// 仅识别同账号、同会话的本地系统提示；不读取旧版关联文件。
NSDictionary * _Nullable YMResolveLocalNoticeAnchor(NSString *xml, NSString *account,
    NSString *session, uint32_t type, uint64_t serverID);
NS_ASSUME_NONNULL_END

#pragma once
#import <Foundation/Foundation.h>

// 仅记录已确认撤回的身份和提示 localId，不保存正文或借用微信对象。
static inline NSString *YMSelfRevokeIdentity(NSString *account, NSString *session,
                                          uint64_t serverID, uint32_t localID) {
    if (!account.length || !session.length || !serverID || !localID) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[account, session,
        [NSString stringWithFormat:@"%llu", (unsigned long long)serverID], @(localID)]
                                                  options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static inline void YMRecordSelfRevoke(NSUserDefaults *defaults, NSString *identity,
                                     uint32_t noticeLocalID = 0) {
    if (!identity.length) return;
    @synchronized(defaults) {
        NSMutableDictionary *records = [[defaults dictionaryForKey:@"kSelfRevokedMessages.SOVIET"] mutableCopy];
        if (!records) records = [NSMutableDictionary dictionary];
        // 0 表示保留成功但提示未插入。失败回调不能覆盖已成功的提示。
        if ([records[identity] unsignedIntValue] != 0) return;
        records[identity] = @(noticeLocalID);
        [defaults setObject:records forKey:@"kSelfRevokedMessages.SOVIET"];
    }
}

static inline BOOL YMHasSelfRevoke(NSUserDefaults *defaults, NSString *identity) {
    if (!identity.length) return NO;
    @synchronized(defaults) {
        return [defaults dictionaryForKey:@"kSelfRevokedMessages.SOVIET"][identity] != nil;
    }
}

static inline uint32_t YMSelfRevokeNoticeLocalID(NSUserDefaults *defaults, NSString *identity) {
    if (!identity.length) return 0;
    @synchronized(defaults) {
        return [[defaults dictionaryForKey:@"kSelfRevokedMessages.SOVIET"][identity] unsignedIntValue];
    }
}

static inline uint64_t YMSelfRevokeOriginalID(NSUserDefaults *defaults, NSString *account,
                                            NSString *session, uint32_t noticeLocalID) {
    if (!account.length || !session.length || !noticeLocalID) return 0;
    @synchronized(defaults) {
        NSDictionary *records = [defaults dictionaryForKey:@"kSelfRevokedMessages.SOVIET"];
        uint64_t result = 0;
        // ponytail: 按提示查找线性扫描身份账本；量大时再加持久反向索引。
        for (NSString *identity in records) {
            if (![identity isKindOfClass:NSString.class] ||
                ![records[identity] isKindOfClass:NSNumber.class] ||
                [records[identity] unsignedIntValue] != noticeLocalID) continue;
            NSArray *parts = [NSJSONSerialization JSONObjectWithData:[identity dataUsingEncoding:NSUTF8StringEncoding]
                                                           options:0 error:nil];
            if (![parts isKindOfClass:NSArray.class] || parts.count != 4 ||
                ![parts[0] isEqual:account] || ![parts[1] isEqual:session] ||
                ![parts[2] isKindOfClass:NSString.class]) continue;
            NSScanner *scanner = [NSScanner scannerWithString:parts[2]];
            scanner.charactersToBeSkipped = nil;
            unsigned long long identifier = 0;
            if (![scanner scanUnsignedLongLong:&identifier] || !scanner.isAtEnd || !identifier ||
                ![parts[2] isEqual:[NSString stringWithFormat:@"%llu", identifier]]) continue;
            if (result) return 0; // 同账号/会话/localId 映射有歧义时拒绝绑定。
            result = identifier;
        }
        return result;
    }
}

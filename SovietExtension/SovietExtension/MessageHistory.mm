#import "MessageHistory.h"
#include <cerrno>
#include <cstdlib>

NSNotificationName const YMMessageHistoryDeletedNotification = @"YMMessageHistoryDeleted";
static BOOL historyName(id value) {
    return [value isKindOfClass:NSString.class] && [value length] &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static uint64_t historyNumber(id value, uint64_t maximum = UINT64_MAX) {
    if (![value isKindOfClass:NSNumber.class]) return 0;
    NSString *text = [value stringValue];
    if (!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return 0;
    errno = 0; char *end = nullptr;
    uint64_t number = strtoull(text.UTF8String, &end, 10);
    return errno || !end || *end || number > maximum ? 0 : number;
}
NSDictionary *YMMessageHistoryIdentity(NSString *session, uint32_t localID, uint64_t serverID, uint64_t sortSeq, uint32_t createSec) {
    if (!historyName(session) || (!serverID && !(localID && sortSeq && createSec))) return nil;
    return @{@"session":[session copy], @"localID":@(localID), @"serverID":@(serverID), @"sortSeq":@(sortSeq), @"createSec":@(createSec)};
}
NSString *YMMessageHistoryStorageKey(NSDictionary *message) {
    if (![message isKindOfClass:NSDictionary.class] || !historyName(message[@"session"])) return nil;
    uint64_t server = historyNumber(message[@"serverID"]);
    if (server) return [NSString stringWithFormat:@"s%llu", (unsigned long long)server];
    uint64_t local = historyNumber(message[@"localID"], UINT32_MAX), seq = historyNumber(message[@"sortSeq"]), sec = historyNumber(message[@"createSec"], UINT32_MAX);
    return local && seq && sec ? [NSString stringWithFormat:@"l%llu-%llu-%llu", (unsigned long long)local, (unsigned long long)seq, (unsigned long long)sec] : nil;
}
BOOL YMMessageHistoryDeletionMatches(NSDictionary *deletion, NSString *account, NSDictionary *message) {
    if (![deletion isKindOfClass:NSDictionary.class] || !historyName(account) || ![deletion[@"account"] isEqual:account] || !YMMessageHistoryStorageKey(message)) return NO;
    id session = deletion[@"session"], messages = deletion[@"messages"];
    if (messages && (![messages isKindOfClass:NSArray.class] || ![messages count])) return NO;
    if (!session) return messages == nil;
    if (!historyName(session) || ![session isEqual:message[@"session"]]) return NO;
    if (!messages) return YES;
    for (NSDictionary *candidate in messages) {
        if (![candidate isKindOfClass:NSDictionary.class] || ![candidate[@"session"] isEqual:session] || !YMMessageHistoryStorageKey(candidate)) continue;
        uint64_t left = historyNumber(candidate[@"serverID"]), right = historyNumber(message[@"serverID"]);
        if (left && right) { if (left == right) return YES; continue; }
        // 已发送后 serverID 可能从 0 更新；完整本地三元组仍能对应同一条消息。
        uint64_t local = historyNumber(candidate[@"localID"], UINT32_MAX), seq = historyNumber(candidate[@"sortSeq"]), sec = historyNumber(candidate[@"createSec"], UINT32_MAX);
        if (local && seq && sec && local == historyNumber(message[@"localID"], UINT32_MAX) &&
            seq == historyNumber(message[@"sortSeq"]) && sec == historyNumber(message[@"createSec"], UINT32_MAX)) return YES;
    }
    return NO;
}
void YMPostMessageHistoryDeletion(NSString *account, NSString *session, NSArray<NSDictionary *> *messages) {
    if (!historyName(account) || (session && !historyName(session)) || (messages && (!session || ![messages isKindOfClass:NSArray.class] || !messages.count))) return;
    NSMutableDictionary *copied = [NSMutableDictionary dictionaryWithObject:[account copy] forKey:@"account"];
    if (session) copied[@"session"] = [session copy];
    if (messages) {
        NSMutableArray *identities = [NSMutableArray new];
        for (NSDictionary *message in messages) {
            if (![message isKindOfClass:NSDictionary.class] || ![message[@"session"] isEqual:session]) continue;
            NSDictionary *identity = YMMessageHistoryIdentity(session, (uint32_t)historyNumber(message[@"localID"],UINT32_MAX),
                historyNumber(message[@"serverID"]), historyNumber(message[@"sortSeq"]), (uint32_t)historyNumber(message[@"createSec"],UINT32_MAX));
            if (identity) [identities addObject:identity];
        }
        if (!identities.count) return;
        copied[@"messages"] = [identities copy];
    }
    NSDictionary *info = [copied copy];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:YMMessageHistoryDeletedNotification object:nil userInfo:info]; });
}

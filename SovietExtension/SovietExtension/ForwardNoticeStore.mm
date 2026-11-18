#import "ForwardNoticeStore.h"
#include <sqlite3.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <memory>
#include <mutex>
#include <string>
#include <limits.h>
#include <errno.h>

namespace {
std::mutex forwardNoticeMutex;
using Database = std::unique_ptr<sqlite3, decltype(&sqlite3_close)>;
using Statement = std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)>;

bool validNoticeSession(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > 128) return false;
    return NSEqualRanges([value rangeOfString:@"^(?:[A-Za-z0-9_-]{1,128}|[0-9]+@chatroom)$"
        options:NSRegularExpressionSearch], NSMakeRange(0, value.length));
}

bool validNoticeKey(NSString *account, NSString *session, uint32_t localID,
                    uint64_t sortSeq, uint32_t createSec) {
    return validNoticeSession(account) && [session isEqualToString:account] &&
        localID && sortSeq && createSec;
}

NSString *noticeDecimal(uint64_t value) {
    return [NSString stringWithFormat:@"%llu", (unsigned long long)value];
}

bool validNoticeID(NSString *value) {
    if (!value.length) return false;
    uint64_t result = 0;
    for (NSUInteger i = 0; i < value.length; ++i) {
        unichar digit = [value characterAtIndex:i];
        if (digit < '0' || digit > '9' || result > (UINT64_MAX - (digit - '0')) / 10) return false;
        result = result * 10 + digit - '0';
    }
    return result && [noticeDecimal(result) isEqualToString:value];
}

NSString *forwardNoticePath() {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return base ? [base stringByAppendingPathComponent:@"PrivateSoviet/forward-notices.sqlite3"] : nil;
}

Database openNoticeDatabase(NSString *path, bool create, bool writable = false) {
    Database db(nullptr, sqlite3_close);
    if (!path.length) return db;
    if (create) {
        NSString *directory = path.stringByDeletingLastPathComponent;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:nil]) return db;
        struct stat info{};
        if (lstat(directory.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) ||
            chmod(directory.fileSystemRepresentation, 0700)) return db;
        int descriptor = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
        if (descriptor < 0) return db;
        bool privateFile = !fstat(descriptor, &info) && S_ISREG(info.st_mode) && !fchmod(descriptor, 0600);
        close(descriptor);
        if (!privateFile) return db;
    }
    // macOS 的 /var 等父目录本身可以是系统软链接；只禁止数据库文件成为软链接。
    char resolvedDirectory[PATH_MAX];
    if (!realpath(path.stringByDeletingLastPathComponent.fileSystemRepresentation, resolvedDirectory)) return db;
    std::string resolvedPath = std::string(resolvedDirectory) + "/" + path.lastPathComponent.fileSystemRepresentation;
    sqlite3 *raw = nullptr;
    int flags = create || writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY;
    int result = sqlite3_open_v2(resolvedPath.c_str(), &raw, flags | SQLITE_OPEN_NOFOLLOW, nullptr);
    db.reset(raw);
    if (result != SQLITE_OK) { db.reset(); return db; }
    sqlite3_busy_timeout(db.get(), 100);
    if (create && sqlite3_exec(db.get(),
        "CREATE TABLE IF NOT EXISTS forward_notices ("
        "account TEXT NOT NULL, session TEXT NOT NULL, local_id INTEGER NOT NULL, "
        "sort_seq TEXT NOT NULL, create_sec INTEGER NOT NULL, source_session TEXT NOT NULL, "
        "source_server_id TEXT NOT NULL, PRIMARY KEY(account,session,local_id,sort_seq,create_sec)) "
        "WITHOUT ROWID", nullptr, nullptr, nullptr) != SQLITE_OK) db.reset();
    return db;
}

Statement prepareNoticeStatement(sqlite3 *db, const char *sql) {
    sqlite3_stmt *raw = nullptr;
    int result = sqlite3_prepare_v2(db, sql, -1, &raw, nullptr);
    Statement statement(raw, sqlite3_finalize);
    if (result != SQLITE_OK) statement.reset();
    return statement;
}

bool bindNoticeText(sqlite3_stmt *statement, int index, NSString *value) {
    return sqlite3_bind_text(statement, index, value.UTF8String, -1, SQLITE_TRANSIENT) == SQLITE_OK;
}

bool bindNoticeKey(sqlite3_stmt *statement, NSString *account, NSString *session,
                   uint32_t localID, uint64_t sortSeq, uint32_t createSec) {
    return bindNoticeText(statement, 1, account) && bindNoticeText(statement, 2, session) &&
        sqlite3_bind_int64(statement, 3, localID) == SQLITE_OK &&
        bindNoticeText(statement, 4, noticeDecimal(sortSeq)) &&
        sqlite3_bind_int64(statement, 5, createSec) == SQLITE_OK;
}

NSDictionary *readNoticeRecord(sqlite3 *db, NSString *account, NSString *session,
                              uint32_t localID, uint64_t sortSeq, uint32_t createSec) {
    auto statement = prepareNoticeStatement(db,
        "SELECT source_session,source_server_id FROM forward_notices "
        "WHERE account=?1 AND session=?2 AND local_id=?3 AND sort_seq=?4 AND create_sec=?5");
    if (!statement || !bindNoticeKey(statement.get(), account, session, localID, sortSeq, createSec) ||
        sqlite3_step(statement.get()) != SQLITE_ROW) return nil;
    const char *source = reinterpret_cast<const char *>(sqlite3_column_text(statement.get(), 0));
    const char *serverID = reinterpret_cast<const char *>(sqlite3_column_text(statement.get(), 1));
    NSString *sourceSession = source ? [NSString stringWithUTF8String:source] : nil;
    NSString *sourceServerID = serverID ? [NSString stringWithUTF8String:serverID] : nil;
    if (!validNoticeSession(sourceSession) || !validNoticeID(sourceServerID)) return nil;
    return @{@"account": account, @"session": sourceSession, @"serverID": sourceServerID};
}

BOOL storeForwardNoticeAtPath(NSString *path, NSString *account, NSString *session,
                             uint32_t localID, uint64_t sortSeq, uint32_t createSec,
                             NSString *sourceSession, uint64_t sourceServerID) {
    if (!validNoticeKey(account, session, localID, sortSeq, createSec) ||
        !validNoticeSession(sourceSession) || !sourceServerID) return NO;
    std::lock_guard<std::mutex> lock(forwardNoticeMutex);
    auto db = openNoticeDatabase(path, true);
    if (!db) return NO;
    // 重复回调可重复记录；同一载体已关联其他原文时拒绝覆盖，避免误跳。
    auto statement = prepareNoticeStatement(db.get(),
        "INSERT OR IGNORE INTO forward_notices VALUES(?1,?2,?3,?4,?5,?6,?7)");
    if (!statement || !bindNoticeKey(statement.get(), account, session, localID, sortSeq, createSec) ||
        !bindNoticeText(statement.get(), 6, sourceSession) ||
        !bindNoticeText(statement.get(), 7, noticeDecimal(sourceServerID)) ||
        sqlite3_step(statement.get()) != SQLITE_DONE) return NO;
    NSDictionary *saved = readNoticeRecord(db.get(), account, session, localID, sortSeq, createSec);
    return [saved[@"session"] isEqualToString:sourceSession] &&
        [saved[@"serverID"] isEqualToString:noticeDecimal(sourceServerID)];
}

NSDictionary *loadForwardNoticeAtPath(NSString *path, NSString *account, NSString *session,
                                     uint32_t localID, uint64_t sortSeq, uint32_t createSec) {
    if (!validNoticeKey(account, session, localID, sortSeq, createSec)) return nil;
    std::lock_guard<std::mutex> lock(forwardNoticeMutex);
    auto db = openNoticeDatabase(path, false);
    return db ? readNoticeRecord(db.get(), account, session, localID, sortSeq, createSec) : nil;
}

enum class NoticeCleanup { Messages, Session, Account };
struct NoticeCleanupTransaction {
    sqlite3 *db;
    bool active = false;
    explicit NoticeCleanupTransaction(sqlite3 *database) : db(database) {
        active = sqlite3_exec(db, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr) == SQLITE_OK;
    }
    ~NoticeCleanupTransaction() {
        if (active) sqlite3_exec(db, "ROLLBACK", nullptr, nullptr, nullptr);
    }
    bool commit() {
        if (sqlite3_exec(db, "COMMIT", nullptr, nullptr, nullptr) != SQLITE_OK) return false;
        active = false;
        return true;
    }
};

BOOL cleanupForwardNoticesAtPath(NSString *path, NSString *account, NSString *session,
    NoticeCleanup mode, const std::vector<YMForwardNoticeMessageIdentity> &messages = {}) {
    if (!path.length || !validNoticeSession(account) ||
        (mode != NoticeCleanup::Account && !validNoticeSession(session))) return NO;
    if (mode == NoticeCleanup::Messages) {
        if (messages.empty()) return NO;
        // 缺少任一侧完整身份时，不能退化为按会话或本地 ID 批量清理。
        for (const auto &message : messages)
            if (!message.serverID && !(message.localID && message.sortSeq && message.createSec)) return NO;
    }
    std::lock_guard<std::mutex> lock(forwardNoticeMutex);
    struct stat info{};
    if (lstat(path.fileSystemRepresentation, &info)) return errno == ENOENT;
    auto db = openNoticeDatabase(path, false, true);
    if (!db) return NO;
    NoticeCleanupTransaction transaction(db.get());
    if (!transaction.active) return NO;
    if (mode == NoticeCleanup::Messages) {
        auto statement = prepareNoticeStatement(db.get(),
            "DELETE FROM forward_notices WHERE account=?1 AND ("
            "(?3!='0' AND source_session=?2 AND source_server_id=?3) OR "
            "(?4>0 AND ?5!='0' AND ?6>0 AND session=?2 AND local_id=?4 AND sort_seq=?5 AND create_sec=?6))");
        if (!statement) return NO;
        for (const auto &message : messages) {
            if (sqlite3_reset(statement.get()) != SQLITE_OK ||
                !bindNoticeText(statement.get(), 1, account) || !bindNoticeText(statement.get(), 2, session) ||
                !bindNoticeText(statement.get(), 3, noticeDecimal(message.serverID)) ||
                sqlite3_bind_int64(statement.get(), 4, message.localID) != SQLITE_OK ||
                !bindNoticeText(statement.get(), 5, noticeDecimal(message.sortSeq)) ||
                sqlite3_bind_int64(statement.get(), 6, message.createSec) != SQLITE_OK ||
                sqlite3_step(statement.get()) != SQLITE_DONE) return NO;
        }
    } else {
        auto statement = prepareNoticeStatement(db.get(), mode == NoticeCleanup::Session ?
            "DELETE FROM forward_notices WHERE account=?1 AND (source_session=?2 OR session=?2)" :
            "DELETE FROM forward_notices WHERE account=?1");
        if (!statement || !bindNoticeText(statement.get(), 1, account) ||
            (mode == NoticeCleanup::Session && !bindNoticeText(statement.get(), 2, session)) ||
            sqlite3_step(statement.get()) != SQLITE_DONE) return NO;
    }
    return transaction.commit();
}

BOOL cleanupForwardNotices(NSString *account, NSString *session, NoticeCleanup mode,
    const std::vector<YMForwardNoticeMessageIdentity> &messages = {}) {
    try {
        @try {
            return cleanupForwardNoticesAtPath(forwardNoticePath(), account, session, mode, messages);
        } @catch (__unused NSException *exception) { return NO; }
    } catch (...) { return NO; }
}
}

BOOL YMStoreForwardNotice(NSString *account, NSString *session, uint32_t localID,
    uint64_t sortSeq, uint32_t createSec, NSString *sourceSession, uint64_t sourceServerID) {
    try {
        @try {
            return storeForwardNoticeAtPath(forwardNoticePath(), account, session, localID,
                sortSeq, createSec, sourceSession, sourceServerID);
        } @catch (__unused NSException *exception) { return NO; }
    } catch (...) { return NO; }
}

NSDictionary *YMLoadForwardNotice(NSString *account, NSString *session, uint32_t localID,
    uint64_t sortSeq, uint32_t createSec) {
    try {
        @try {
            return loadForwardNoticeAtPath(forwardNoticePath(), account, session, localID, sortSeq, createSec);
        } @catch (__unused NSException *exception) { return nil; }
    } catch (...) { return nil; }
}

BOOL YMDeleteForwardNoticesForMessages(NSString *account, NSString *session,
    const std::vector<YMForwardNoticeMessageIdentity> &messages) {
    return cleanupForwardNotices(account, session, NoticeCleanup::Messages, messages);
}

BOOL YMClearForwardNoticesForSession(NSString *account, NSString *session) {
    return cleanupForwardNotices(account, session, NoticeCleanup::Session);
}

BOOL YMClearForwardNoticesForAccount(NSString *account) {
    return cleanupForwardNotices(account, nil, NoticeCleanup::Account);
}

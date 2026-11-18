#import "LocalNoticeCursor.h"
#import "RevokePatch.h"
#import "SelfRevokePatch.h"
#import "WeChatCompatibility.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <tuple>
#include <vector>
#include <mach/mach_vm.h>

#if defined(__aarch64__)
namespace noticeCursor {
static std::atomic_bool installed{false};
static bool v420 = false;
static uintptr_t versioned(uintptr_t old, uintptr_t newer) { return v420 ? newer : old; }
template<class T> T read(const void *p, size_t offset) {
    T result; memcpy(&result, static_cast<const uint8_t *>(p) + offset, sizeof result); return result;
}
static NSString *text(const void *p, size_t offset) {
    const auto &s = *reinterpret_cast<const std::string *>(static_cast<const uint8_t *>(p) + offset);
    if (s.empty() || s.size() > 128) return nil;
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}
struct Boundary {
    uint64_t seconds = 0, sequence = 0, localID = 0;
    bool operator<(const Boundary &other) const {
        return std::tie(sequence, localID) < std::tie(other.sequence, other.localID);
    }
};
static_assert(sizeof(Boundary) == 24);
using Models = std::vector<std::shared_ptr<void>>;
static void *cast(void *model, uintptr_t target) {
    return model ? reinterpret_cast<void *(*)(void *, void *, void *, ptrdiff_t)>(YMRuntimeAddress(versioned(0x63f23f4, 0x72b0e58)))(
        model, (void *)YMRuntimeAddress(versioned(0x8b9b0a8, 0x9d7b498)), (void *)YMRuntimeAddress(target), 0) : nullptr;
}
static std::optional<Boundary> boundary(uintptr_t context, int direction, NSString *session) {
    std::optional<Boundary> result;
    auto include = [&](const std::shared_ptr<void> &model) {
        void *message = cast(model.get(), versioned(0x8b9bac0, 0x9d7bee0));
        if (!message) return true; // 原生日期头等非消息行不参与数据库分页。
        const auto *data = reinterpret_cast<const uint8_t *>(message) + 0x120;
        Boundary key{read<uint32_t>(data, versioned(0xa0, 0xa8)), read<uint64_t>(data, versioned(0x98, 0xa0)), read<uint32_t>(data, 0x74)};
        if (!key.seconds || !key.sequence || !key.localID || ![text(data, 0x58) isEqual:session]) return false;
        if (!result || (direction == 1 ? key < *result : *result < key)) result = key;
        return true;
    };
    // 显示重排后，列表首尾不一定是数据库排序首尾；按 (sort_seq, localID) 取查询边界。
    // 这是位置调整的配套适配；微信仍负责执行分页，结果不跨调用缓存。
    for (const auto &model : *reinterpret_cast<const Models *>(context + versioned(0x68, 0x80))) {
        if (void *folded = cast(model.get(), versioned(0x8ba72e0, 0x9d88568))) {
            const auto *children = reinterpret_cast<const Models *(*)(void *)>(YMRuntimeAddress(versioned(0x50c8a4, 0x62670c)))(folded);
            if (!children) return {};
            for (const auto &child : *children) if (!include(child)) return {};
        } else if (!include(model)) return {};
    }
    return result;
}
struct Request {
    uintptr_t context;
    NSString *account;
    NSString *session;
    std::optional<Boundary> key;
    Request *previous;
};
static thread_local Request *request = nullptr;
struct RequestScope {
    Request value;
    RequestScope(uintptr_t context, int direction) : value{context, nil, nil, {}, request} {
        request = &value;
        if (!installed.load() || !NSThread.isMainThread || !context) return;
        @try { try {
            value.account = YMSelfRevokeAccount();
            value.session = text((const void *)context, versioned(0x2b0, 0x330));
            if (value.account.length && value.session.length)
                value.key = boundary(context, direction, value.session);
        } catch (...) { value.key.reset(); } } @catch (NSException *) { value.key.reset(); }
    }
    ~RequestScope() { request = value.previous; }
};
}
extern "C" {
void YMLocalNoticeCursorOriginalLoadPrevious(void *, uintptr_t);
void YMLocalNoticeCursorOriginalLoadNext(void *, uintptr_t);
void YMLocalNoticeCursorLoadPrevious(void *context, uintptr_t count) {
    noticeCursor::RequestScope scope((uintptr_t)context, 1);
    YMLocalNoticeCursorOriginalLoadPrevious(context, count);
}
void YMLocalNoticeCursorLoadNext(void *context, uintptr_t count) {
    noticeCursor::RequestScope scope((uintptr_t)context, 2);
    YMLocalNoticeCursorOriginalLoadNext(context, count);
}
bool YMLocalNoticeCursorKey(noticeCursor::Boundary *out) {
    auto *current = noticeCursor::request;
    if (!current || !current->key) return false;
    @try { try {
        if (![current->account isEqual:YMSelfRevokeAccount()] ||
            ![current->session isEqual:noticeCursor::text((const void *)current->context, noticeCursor::versioned(0x2b0, 0x330))]) return false;
        *out = *current->key; return true;
    } catch (...) { return false; } } @catch (NSException *) { return false; }
}
}

#ifndef YM_LOCAL_NOTICE_CURSOR_TEST
extern "C" {
void YMLocalNoticeCursorKeyPrevious(void);
void YMLocalNoticeCursorKeyNext(void);
uintptr_t YMLocalNoticeCursorVersion420 = 0;
uintptr_t YMLocalNoticeCursorTimeOffset = 0xa0;
uintptr_t YMLocalNoticeCursorPreviousReadyAddress = 0;
uintptr_t YMLocalNoticeCursorNextReadyAddress = 0;
uintptr_t YMLocalNoticeCursorPreviousKeyContinueAddress = 0;
uintptr_t YMLocalNoticeCursorNextKeyContinueAddress = 0;
uintptr_t YMLocalNoticeCursorGetDataAddress = 0;
uintptr_t YMLocalNoticeCursorLoadPreviousContinueAddress = 0;
uintptr_t YMLocalNoticeCursorLoadNextContinueAddress = 0;
}
#define YM_CURSOR_SAVE \
    "sub sp, sp, #0x2c0\n" \
    "stp x0, x1, [sp, #0x0]\n" \
    "stp x2, x3, [sp, #0x10]\n" \
    "stp x4, x5, [sp, #0x20]\n" \
    "stp x6, x7, [sp, #0x30]\n" \
    "stp x8, x9, [sp, #0x40]\n" \
    "stp x10, x11, [sp, #0x50]\n" \
    "stp x12, x13, [sp, #0x60]\n" \
    "stp x14, x15, [sp, #0x70]\n" \
    "stp x16, x17, [sp, #0x80]\n" \
    "stp x18, x30, [sp, #0x90]\n" \
    "stp q0, q1, [sp, #0xa0]\n" \
    "stp q2, q3, [sp, #0xc0]\n" \
    "stp q4, q5, [sp, #0xe0]\n" \
    "stp q6, q7, [sp, #0x100]\n" \
    "stp q8, q9, [sp, #0x120]\n" \
    "stp q10, q11, [sp, #0x140]\n" \
    "stp q12, q13, [sp, #0x160]\n" \
    "stp q14, q15, [sp, #0x180]\n" \
    "stp q16, q17, [sp, #0x1a0]\n" \
    "stp q18, q19, [sp, #0x1c0]\n" \
    "stp q20, q21, [sp, #0x1e0]\n" \
    "stp q22, q23, [sp, #0x200]\n" \
    "stp q24, q25, [sp, #0x220]\n" \
    "stp q26, q27, [sp, #0x240]\n" \
    "stp q28, q29, [sp, #0x260]\n" \
    "stp q30, q31, [sp, #0x280]\n"
#define YM_CURSOR_RESTORE \
    "ldp q0, q1, [sp, #0xa0]\n" \
    "ldp q2, q3, [sp, #0xc0]\n" \
    "ldp q4, q5, [sp, #0xe0]\n" \
    "ldp q6, q7, [sp, #0x100]\n" \
    "ldp q8, q9, [sp, #0x120]\n" \
    "ldp q10, q11, [sp, #0x140]\n" \
    "ldp q12, q13, [sp, #0x160]\n" \
    "ldp q14, q15, [sp, #0x180]\n" \
    "ldp q16, q17, [sp, #0x1a0]\n" \
    "ldp q18, q19, [sp, #0x1c0]\n" \
    "ldp q20, q21, [sp, #0x1e0]\n" \
    "ldp q22, q23, [sp, #0x200]\n" \
    "ldp q24, q25, [sp, #0x220]\n" \
    "ldp q26, q27, [sp, #0x240]\n" \
    "ldp q28, q29, [sp, #0x260]\n" \
    "ldp q30, q31, [sp, #0x280]\n" \
    "ldp x0, x1, [sp, #0x0]\n" \
    "ldp x2, x3, [sp, #0x10]\n" \
    "ldp x4, x5, [sp, #0x20]\n" \
    "ldp x6, x7, [sp, #0x30]\n" \
    "ldp x8, x9, [sp, #0x40]\n" \
    "ldp x10, x11, [sp, #0x50]\n" \
    "ldp x12, x13, [sp, #0x60]\n" \
    "ldp x14, x15, [sp, #0x70]\n" \
    "ldp x16, x17, [sp, #0x80]\n" \
    "ldp x18, x30, [sp, #0x90]\n"
#define YM_CURSOR_JUMP(name) "adrp x16, _YMLocalNoticeCursor" name "Address@PAGE\nldr x16, [x16, _YMLocalNoticeCursor" name "Address@PAGEOFF]\nbr x16\n"
#define YM_CURSOR_CALL(name) "adrp x16, _YMLocalNoticeCursor" name "Address@PAGE\nldr x16, [x16, _YMLocalNoticeCursor" name "Address@PAGEOFF]\nblr x16\n"
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMLocalNoticeCursorOriginalLoadPrevious\n"
    "_YMLocalNoticeCursorOriginalLoadPrevious:\n"
    "adrp x16, _YMLocalNoticeCursorVersion420@PAGE\nldr x16, [x16, _YMLocalNoticeCursorVersion420@PAGEOFF]\ncbnz x16, 1f\n"
    "stp x26, x25, [sp, #-0x50]!\n"
    "stp x24, x23, [sp, #0x10]\n"
    "stp x22, x21, [sp, #0x20]\n"
    "stp x20, x19, [sp, #0x30]\n"
    YM_CURSOR_JUMP("LoadPreviousContinue")
    "1:\nstp x28, x27, [sp, #-0x60]!\nstp x26, x25, [sp, #0x10]\nstp x24, x23, [sp, #0x20]\nstp x22, x21, [sp, #0x30]\n"
    YM_CURSOR_JUMP("LoadPreviousContinue")
    ".align 2\n"
    ".globl _YMLocalNoticeCursorOriginalLoadNext\n"
    "_YMLocalNoticeCursorOriginalLoadNext:\n"
    "stp x28, x27, [sp, #-0x60]!\n"
    "stp x26, x25, [sp, #0x10]\n"
    "stp x24, x23, [sp, #0x20]\n"
    "stp x22, x21, [sp, #0x30]\n"
    YM_CURSOR_JUMP("LoadNextContinue")
    ".align 2\n"
    ".globl _YMLocalNoticeCursorKeyPrevious\n"
    "_YMLocalNoticeCursorKeyPrevious:\n"
    YM_CURSOR_SAVE
    "add x0, sp, #0x2a0\n"
    "bl _YMLocalNoticeCursorKey\n"
    "cbz w0, 1f\n"
    YM_CURSOR_RESTORE
    "ldr w23, [sp, #0x2a0]\n"
    "ldr x24, [sp, #0x2a8]\n"
    "ldr w8, [sp, #0x2b0]\n"
    "add sp, sp, #0x2c0\n"
    YM_CURSOR_JUMP("PreviousReady")
    "1:\n"
    YM_CURSOR_RESTORE
    "add sp, sp, #0x2c0\n"
    "ldr x22, [sp, #0x70]\n"
    "mov x0, x22\n"
    YM_CURSOR_CALL("GetData")
    "adrp x16, _YMLocalNoticeCursorTimeOffset@PAGE\nldr x16, [x16, _YMLocalNoticeCursorTimeOffset@PAGEOFF]\nldr w23, [x0, x16]\n"
    YM_CURSOR_JUMP("PreviousKeyContinue")
    ".align 2\n"
    ".globl _YMLocalNoticeCursorKeyNext\n"
    "_YMLocalNoticeCursorKeyNext:\n"
    YM_CURSOR_SAVE
    "add x0, sp, #0x2a0\n"
    "bl _YMLocalNoticeCursorKey\n"
    "cbz w0, 1f\n"
    YM_CURSOR_RESTORE
    "ldr w24, [sp, #0x2a0]\n"
    "ldr x25, [sp, #0x2a8]\n"
    "ldr w8, [sp, #0x2b0]\n"
    "add sp, sp, #0x2c0\n"
    YM_CURSOR_JUMP("NextReady")
    "1:\n"
    YM_CURSOR_RESTORE
    "add sp, sp, #0x2c0\n"
    "ldr x22, [sp, #0x58]\n"
    "mov x0, x22\n"
    YM_CURSOR_CALL("GetData")
    "adrp x16, _YMLocalNoticeCursorTimeOffset@PAGE\nldr x16, [x16, _YMLocalNoticeCursorTimeOffset@PAGEOFF]\nldr w24, [x0, x16]\n"
    YM_CURSOR_JUMP("NextKeyContinue")
);

#undef YM_CURSOR_SAVE
#undef YM_CURSOR_RESTORE
#undef YM_CURSOR_JUMP
#undef YM_CURSOR_CALL

BOOL YMInstallLocalNoticeCursorHooks(void) {
    if (noticeCursor::installed.load()) return YES;
    const bool v420 = YMMatchesWeChat270353Dylib();
    if (!v420 && !YMMatchesWeChatLegacyNativeDylib()) return NO;
    struct Entry { uintptr_t address, target; uint8_t bytes[16]; };
    const Entry oldEntries[] = {
        {0x7c5c6c, reinterpret_cast<uintptr_t>(&YMLocalNoticeCursorLoadPrevious), {0xfa,0x67,0xbb,0xa9,0xf8,0x5f,0x01,0xa9,0xf6,0x57,0x02,0xa9,0xf4,0x4f,0x03,0xa9}},
        {0x7c6ebc, reinterpret_cast<uintptr_t>(&YMLocalNoticeCursorLoadNext), {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
        {0x7c68d4, reinterpret_cast<uintptr_t>(&YMLocalNoticeCursorKeyPrevious), {0xf6,0x3b,0x40,0xf9,0xe0,0x03,0x16,0xaa,0xb3,0x36,0xf5,0x97,0x17,0xa0,0x40,0xb9}},
        {0x7c7b2c, reinterpret_cast<uintptr_t>(&YMLocalNoticeCursorKeyNext), {0xf6,0x2f,0x40,0xf9,0xe0,0x03,0x16,0xaa,0x1d,0x32,0xf5,0x97,0x18,0xa0,0x40,0xb9}},
        {0x50c8a4, 0, {0x00,0x60,0x04,0x91,0xc0,0x03,0x5f,0xd6,0x09,0xa8,0x51,0xa9,0x3f,0x01,0x0a,0xeb}},
        {0x63f23f4, 0, {0xf0,0x36,0x01,0x90,0x10,0xb2,0x45,0xf9,0x00,0x02,0x1f,0xd6,0xf0,0x36,0x01,0x90}},
        {0x5143a8, 0, {0x00,0x80,0x04,0x91,0xc0,0x03,0x5f,0xd6,0xff,0x03,0x02,0xd1,0xf6,0x57,0x05,0xa9}},
    };
    const Entry newEntries[] = {
        {0x97c8e8, reinterpret_cast<uintptr_t>(&YMLocalNoticeCursorLoadPrevious), {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
        {0x97db4c, reinterpret_cast<uintptr_t>(&YMLocalNoticeCursorLoadNext), {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
        {0x97d564, reinterpret_cast<uintptr_t>(&YMLocalNoticeCursorKeyPrevious), {0xf6,0x3b,0x40,0xf9,0xe0,0x03,0x16,0xaa,0x37,0xc3,0xf2,0x97,0x17,0xa8,0x40,0xb9}},
        {0x97e7c8, reinterpret_cast<uintptr_t>(&YMLocalNoticeCursorKeyNext), {0xf6,0x2f,0x40,0xf9,0xe0,0x03,0x16,0xaa,0x9e,0xbe,0xf2,0x97,0x18,0xa8,0x40,0xb9}},
        {0x62670c, 0, {0x00,0x60,0x04,0x91,0xc0,0x03,0x5f,0xd6,0x09,0xa8,0x51,0xa9,0x3f,0x01,0x0a,0xeb}},
        {0x72b0e58, 0, {0x70,0x4e,0x01,0xd0,0x10,0x02,0x46,0xf9,0x00,0x02,0x1f,0xd6,0x70,0x4e,0x01,0xd0}},
        {0x62e248, 0, {0x00,0x80,0x04,0x91,0xc0,0x03,0x5f,0xd6,0xff,0x03,0x02,0xd1,0xf6,0x57,0x05,0xa9}},
    };
    const auto &entries = v420 ? newEntries : oldEntries;
    static bool patched[4]{};
    for (size_t i = 0; i < sizeof entries / sizeof *entries; ++i) {
        if (i < 4 && patched[i]) continue;
        const auto &entry = entries[i];
        uint8_t actual[16]; mach_vm_size_t copied = 0;
        if (mach_vm_read_overwrite(mach_task_self(), YMRuntimeAddress(entry.address), sizeof actual,
            reinterpret_cast<mach_vm_address_t>(actual), &copied) != KERN_SUCCESS || copied != sizeof actual ||
            memcmp(actual, entry.bytes, sizeof actual)) return NO;
    }
    noticeCursor::v420 = v420;
    YMLocalNoticeCursorVersion420 = v420;
    YMLocalNoticeCursorTimeOffset = v420 ? 0xa8 : 0xa0;
    YMLocalNoticeCursorPreviousReadyAddress = YMRuntimeAddress(v420 ? 0x97d58c : 0x7c68fc);
    YMLocalNoticeCursorNextReadyAddress = YMRuntimeAddress(v420 ? 0x97e7f0 : 0x7c7b54);
    YMLocalNoticeCursorPreviousKeyContinueAddress = YMRuntimeAddress(v420 ? 0x97d574 : 0x7c68e4);
    YMLocalNoticeCursorNextKeyContinueAddress = YMRuntimeAddress(v420 ? 0x97e7d8 : 0x7c7b3c);
    YMLocalNoticeCursorGetDataAddress = YMRuntimeAddress(v420 ? 0x62e248 : 0x5143a8);
    YMLocalNoticeCursorLoadPreviousContinueAddress = YMRuntimeAddress(v420 ? 0x97c8f8 : 0x7c5c7c);
    YMLocalNoticeCursorLoadNextContinueAddress = YMRuntimeAddress(v420 ? 0x97db5c : 0x7c6ecc);
    for (size_t i = 0; i < 4; ++i) {
        if (patched[i]) continue;
        patched[i] = YMPatchARM64AbsoluteJump(YMRuntimeAddress(entries[i].address), entries[i].target, "local notice pagination");
        if (!patched[i]) return NO;
    }
    noticeCursor::installed.store(true);
    return YES;
}
#else
BOOL YMInstallLocalNoticeCursorHooks(void) { noticeCursor::installed.store(true); return YES; }
#endif
#else
BOOL YMInstallLocalNoticeCursorHooks(void) { return NO; }
#endif

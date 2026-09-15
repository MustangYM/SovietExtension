// SOVEXT-13: retain the original row; let a separate native revokemsg own re-edit.
#import "SelfRevokePatch.h"
#import "RevokePatch.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <libkern/OSCacheControl.h>

NSString *YMSelfRevokeWrapIdentity(uintptr_t originalWrap);
bool YMWasSelfRevokeNoticeInserted(NSString *identity);
void YMRecordRetainedSelfRevoke(NSString *identity, uint32_t noticeLocalId);
bool YMIsSelfRevokeNotice(uintptr_t systemWrap);
uint64_t YMRetainedSelfRevokeOriginalID(uintptr_t systemWrap);
NSString *YMBuildSelfRevokeNotice(uintptr_t originalWrap, uintptr_t revokeExt);

namespace {
std::atomic_bool installed(false);
std::mutex stateMutex;
template<class T> T field(uintptr_t p, size_t offset) {
    T result;
    memcpy(&result, (const void *)(p + offset), sizeof(result));
    return result;
}
template<class T> void put(uintptr_t p, size_t offset, T value) {
    memcpy((void *)(p + offset), &value, sizeof(value));
}
template<class F> F native(uintptr_t address) { return (F)YMRuntimeAddress(address); }

struct Event {
    NSString *__strong identity;
    std::string account;
    std::string key;
    std::string noticeText;
    bool duplicate = false;
    bool inserted = false;
};
// A coroutine may resume on another thread. The native frame remains its identity.
std::unordered_map<uintptr_t, std::shared_ptr<Event>> events;
// Reservations also quarantine ambiguous native insertion results until process exit.
std::unordered_set<std::string> reservations;

NSString *stringValue(const std::string *s) {
    if (!s || s->empty()) return nil;
    return [[NSString alloc] initWithBytes:s->data() length:s->size() encoding:NSUTF8StringEncoding];
}
std::shared_ptr<Event> eventAt(uintptr_t sp) {
    std::lock_guard<std::mutex> lock(stateMutex);
    auto it = events.find(sp);
    return it == events.end() ? nullptr : it->second;
}

// Non-trivial destructor makes the native 16-byte shared_ptr return use x8.
struct Shared {
    uintptr_t object = 0, control = 0;
    ~Shared() { if (control) native<void (*)(void *)>(0xAE194)(this); }
    Shared() = default;
#ifdef YM_SELF_REVOKE_TEST
    Shared(uintptr_t p, uintptr_t c) : object(p), control(c) {}
#endif
    Shared(const Shared &) = delete;
    Shared &operator=(const Shared &) = delete;
};
static_assert(sizeof(Shared) == 16, "native shared_ptr ABI");
struct Wrap {
    alignas(8) uint8_t bytes[0x268];
    explicit Wrap(uintptr_t source) { native<void *(*)(void *, uintptr_t)>(0xB5F950)(this, source); }
    ~Wrap() { native<void *(*)(void *)>(0x215B27C)(this); }
};
static_assert(sizeof(Wrap) == 0x268, "lower MessageWrap, not upper MessageData");
struct Notice {
    std::shared_ptr<Wrap> wrap;
    std::shared_ptr<Shared> manager;
    std::string account;
    std::string text;
};
std::unordered_map<uintptr_t, std::shared_ptr<Notice>> notices;

std::shared_ptr<Shared> currentManager() {
    Shared service = native<Shared (*)()>(0x428E5D4)();
    if (!service.object) return nullptr;
    Shared context = native<Shared (*)(uintptr_t)>(0x13AAE84)(service.object);
    if (!context.object) return nullptr;
    Shared manager = native<Shared (*)(uintptr_t)>(0x2151AEC)(context.object);
    if (!manager.object) return nullptr;
    auto result = std::make_shared<Shared>();
    result->object = manager.object;
    result->control = manager.control;
    manager.object = manager.control = 0;
    return result;
}

void rememberNotice(uintptr_t wrap, uintptr_t ext) {
    {
        std::lock_guard<std::mutex> lock(stateMutex);
        if (notices.count(ext)) return;
    }
    const std::string account(YMSelfRevokeAccount().UTF8String ?: "");
    if (account.empty()) return;
    auto notice = std::make_shared<Notice>();
    // The inserted XML owns the detailed text across reloads; native attach/expiry
    // only replace rendered ext strings. Do not persist another copy of message text.
    NSString *xml = stringValue((const std::string *)(wrap + 0x130));
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithXMLString:xml ?: @""
        options:NSXMLNodeLoadExternalEntitiesNever error:nil];
    NSXMLElement *revoke = [[document.rootElement elementsForName:@"revokemsg"] firstObject];
    NSString *text = [[[revoke elementsForName:@"content"] firstObject] stringValue];
    if (![text hasPrefix:@"⚠️苏维埃已拦截撤回消息⚠️\n"]) return;
    notice->text = text.UTF8String ?: "";
    notice->wrap = std::make_shared<Wrap>(wrap);
    notice->manager = currentManager();
    notice->account = YMSelfRevokeAccount().UTF8String ?: "";
    if (!notice->manager || notice->account != account || !YMIsSelfRevokeNotice(wrap)) return;
    {
        std::lock_guard<std::mutex> lock(stateMutex);
        if (!notices.count(ext)) notices.emplace(ext, notice);
    }
}

// These are the native rendered text fields. Anchor elements and re-edit payload
// remain native-owned. Both native attach and native expiry regenerate these strings.
void markRetainedNotice(uintptr_t ext, const std::string &body) {
    for (size_t offset : {size_t(0x170), size_t(0x1B8)}) {
        auto *text = (std::string *)(ext + offset);
        std::string replacement = body;
        // Keep only the native re-edit anchor, including its localized label/style.
        // Native link elements match the complete anchor, not a stored text offset.
        const size_t href = text->find("href=\"xwechat://reedit\"");
        if (field<uintptr_t>(ext, 0x218) && href != std::string::npos) {
            const size_t start = text->rfind("<a ", href), end = text->find("</a>", href);
            if (start != std::string::npos && end != std::string::npos &&
                text->find('>', start) > href && text->find('>', start) < end)
                replacement += "\n" + text->substr(start, end + 4 - start);
        }
        native<std::string &(*)(std::string *, const std::string *)>(0x63F1B78)(text, &replacement);
    }
}

void markNoticeBeforeInsert(uintptr_t wrap, const std::string &body) {
    const uintptr_t rawExt = field<uintptr_t>(wrap, 0x210);
    if (field<uint32_t>(wrap, 0x0C) != 10000 || !rawExt) throw std::runtime_error("missing revoke ext");
    const uintptr_t ext = native<uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, int64_t)>(0x63F23F4)(
        rawExt, YMRuntimeAddress(0x8E1B500), YMRuntimeAddress(0x8E1FE48), 0);
    if (!ext || *(const std::string *)(ext + 0x148) != "revokemsg") throw std::runtime_error("unexpected revoke ext");
    markRetainedNotice(ext, body);
    // CoReplace itself uses this serializer: replacemsg + native revoke time, no
    // fabricated original ID. Persist the marker in the independent sysmsg XML.
    std::string xml = native<std::string (*)(uintptr_t)>(0x48B5580)(ext);
    native<std::string &(*)(std::string *, const std::string *)>(0x63F1B78)(
        (std::string *)(wrap + 0x130), &xml);
}

void refreshNotice(uintptr_t ext, bool expired) noexcept {
    @try {
    try {
        std::shared_ptr<Notice> notice;
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            auto it = notices.find(ext);
            if (it == notices.end()) return;
            notice = it->second;
            if (expired) notices.erase(it);
        }
        if (notice->account != (YMSelfRevokeAccount().UTF8String ?: "")) return;
        markRetainedNotice(ext, notice->text);
        // Existing-ext mutation signal, not the insertion/unread notification path.
        // Native subscribers receive the full wrap including its independent localId.
        native<void (*)(uintptr_t, uint64_t, const void *)>(0x278E828)(
            notice->manager->object + 0x228, UINT64_C(0x800000000), notice->wrap.get());
    } catch (...) { YMLog(@"[SelfRevoke] native change notification failed"); }
    } @catch (NSException *) { return; }
}
} // namespace

NSString *YMSelfRevokeAccount(void) {
    @try { try {

    if (!installed.load()) return nil;
    uintptr_t account = native<uintptr_t (*)()>(0x428D0BC)();
    if (!account) return nil;
    auto getter = (const std::string *(*)(uintptr_t))field<uintptr_t>(field<uintptr_t>(account, 0), 0x28);
    return stringValue(getter(account));

    } catch (...) { return nil; } } @catch (NSException *) { return nil; }
}
NSString *YMSelfRevokeSession(uintptr_t wrap) {
    @try { try {

    if (!installed.load() || !wrap) return nil;
    return stringValue(native<const std::string *(*)(uintptr_t)>(0x484CAF0)(wrap));

    } catch (...) { return nil; } } @catch (NSException *) { return nil; }
}
bool YMIsOwnRevokeWrap(uintptr_t wrap) {
    @try { try {

    return installed.load() && wrap && native<bool (*)(uintptr_t)>(0x484CC14)(wrap);

    } catch (...) { return false; } } @catch (NSException *) { return false; }
}
bool YMPrepareSelfRevoke(uintptr_t sp, bool retain) {
    @try {
    if (!installed.load()) return false;
    try {
    if (!retain) {
        std::lock_guard<std::mutex> lock(stateMutex);
        events.erase(sp);
        return true;
    }
        const uintptr_t wrap = sp + 0x18;
        const uint64_t identifier = field<uint64_t>(wrap, 0xF8);
        NSString *account = YMSelfRevokeAccount(), *session = YMSelfRevokeSession(wrap);
        const uint32_t localID = field<uint32_t>(wrap, 0xF4);
        if (!identifier || !localID || !account.length || !session.length || !field<uint8_t>(sp, 0x280)) return false;
        auto event = std::make_shared<Event>();
        event->identity = [YMSelfRevokeWrapIdentity(wrap) copy];
        event->account = account.UTF8String;
        if (!event->identity.length || event->account != (YMSelfRevokeAccount().UTF8String ?: "")) return false;
        event->key = event->identity.UTF8String;
        NSMutableString *text = [YMBuildSelfRevokeNotice(wrap, field<uintptr_t>(sp, 0x2C0)) mutableCopy];
        if (!text.length) return false;
        // Plain message/name text must not become clickable markup in the system notice.
        for (NSArray<NSString *> *pair in @[@[@"&", @"&amp;"], @[@"<", @"&lt;"], @[@">", @"&gt;"],
                                             @[@"\"", @"&quot;"], @[@"'", @"&#39;"]])
            [text replaceOccurrencesOfString:pair[0] withString:pair[1] options:0 range:NSMakeRange(0, text.length)];
        const char *utf8 = text.UTF8String;
        if (!utf8) return false;
        event->noticeText = utf8;
        bool reserved;
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            // Reserve before reading persistent state: a completed concurrent insertion
            // must not fall between a stale ledger read and acquiring its reservation.
            reserved = reservations.insert(event->key).second;
        }
        event->duplicate = !reserved || YMWasSelfRevokeNoticeInserted(event->identity);
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            events.erase(sp);
            events.emplace(sp, std::move(event));
        }
        return true;
    } catch (...) { return false; }
    } @catch (NSException *) { return false; }
}

extern "C" void YMRevokeOriginCallsiteHelper(uintptr_t sp, uintptr_t savedRegisters);
extern "C" void YMSelfOrigin(uintptr_t sp, uintptr_t savedRegisters) noexcept {
    @try { try {
        if (!YMPrepareSelfRevoke(sp, false)) return;
        YMRevokeOriginCallsiteHelper(sp, savedRegisters);
    } catch (...) {
        // Fail closed before any destructive native operation; no fake re-edit payload.
        put<uint8_t>(sp, 0x280, 0);
        YMLog(@"[SelfRevoke] origin policy failed; original retained");
    } } @catch (NSException *) {
        put<uint8_t>(sp, 0x280, 0);
        YMLog(@"[SelfRevoke] origin policy failed; original retained");
    }
}

extern "C" bool YMSelfDelete(uintptr_t sp) noexcept {
    @try {
    try {
        auto event = eventAt(sp);
        if (!event) return false;
        YMRecordRetainedSelfRevoke(event->identity, 0);
        return true;
    } catch (...) {
        // A prepared retained frame must never fall through to deletion on ledger failure.
        YMLog(@"[SelfRevoke] retention ledger failed; original row stays protected");
        return true;
    }
    } @catch (NSException *) { return true; }
}
extern "C" bool YMSelfReplace(uintptr_t sp, uintptr_t fp) noexcept {
    @try {
    try {
    auto event = eventAt(sp);
    if (!event) return false;
    const uintptr_t wrap = sp + 0x5E8;
    put<uint32_t>(wrap, 0xF4, 0);
    put<uint64_t>(wrap, 0xF8, 0);
    if (event->duplicate || event->account != (YMSelfRevokeAccount().UTF8String ?: "")) return true;
        markNoticeBeforeInsert(wrap, event->noticeText);
        // x0 is a shared_ptr holder (not the manager itself); caller owns it throughout.
        const bool ok = native<bool (*)(uintptr_t, uintptr_t)>(0x2897FC0)(fp - 0xD0, wrap);
        const uint32_t localID = field<uint32_t>(wrap, 0xF4);
        if (!ok || !localID || localID == field<uint32_t>(sp + 0x18, 0xF4) || field<uint64_t>(wrap, 0xF8)) {
            if (!ok && !localID) {
                // Native false is result.localId==0; no successful inserted row was returned.
                std::lock_guard<std::mutex> lock(stateMutex);
                reservations.erase(event->key);
            }
            YMLog(@"[SelfRevoke] independent native notice insertion failed; original retained");
            return true;
        }
        event->inserted = true;
        YMRecordRetainedSelfRevoke(event->identity, localID);
        std::lock_guard<std::mutex> lock(stateMutex);
        reservations.erase(event->key);
    } catch (...) {
        // The DB may already have committed. Do not blindly reinsert this identity.
        YMLog(@"[SelfRevoke] ambiguous notice insertion; retry quarantined for this process");
    }
    return true;
    } @catch (NSException *) { return true; }
}
extern "C" bool YMSelfSuppressResult(uintptr_t sp, uintptr_t output) noexcept {
    @try { try {

    auto event = eventAt(sp);
    if (!event || event->inserted) return false;
    // Native localId-zero path still constructs an engaged optional. Suppress explicitly.
    put<uint8_t>(output, 0, 0);
    put<uint8_t>(output, 0x268, 0);
    return true;

    } catch (...) { put<uint8_t>(output, 0x268, 0); return true; } } @catch (NSException *) { put<uint8_t>(output, 0x268, 0); return true; }
}
extern "C" void YMSelfEnd(uintptr_t sp) noexcept {
    @try { try {

    std::shared_ptr<Event> event;
    {
        std::lock_guard<std::mutex> lock(stateMutex);
        auto it = events.find(sp);
        if (it == events.end()) return;
        event = std::move(it->second);
        events.erase(it);
    }

    } catch (...) { return; } } @catch (NSException *) { return; }
}
extern "C" uint64_t YMSelfRecordID(uintptr_t wrap) noexcept {
    @try {
    const uint64_t nativeID = field<uint64_t>(wrap, 0xF8);
    try {
        if (nativeID || field<uint32_t>(wrap, 0x0C) != 10000 || !YMIsSelfRevokeNotice(wrap)) return nativeID;
        // Check the exact native ext type without rechecking time between query and expiry.
        // The enclosing native enrichment already owns the time/type eligibility decision.
        const uintptr_t rawExt = field<uintptr_t>(wrap, 0x210);
        if (!rawExt) return nativeID;
        const uintptr_t ext = native<uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, int64_t)>(0x63F23F4)(
            rawExt, YMRuntimeAddress(0x8E1B500), YMRuntimeAddress(0x8E1FE48), 0);
        if (!ext) return nativeID;
        // Native sysmsg serialization omits ext.originalID; join through our persisted
        // account/session/localId ledger, not the receive-event-only ext+0x168 field.
        const uint64_t originalID = YMRetainedSelfRevokeOriginalID(wrap);
        if (!originalID) return nativeID;
        return originalID;
    } catch (...) { return nativeID; }
    } @catch (NSException *) { return field<uint64_t>(wrap, 0xF8); }
}

extern "C" uintptr_t YMSelfSessionPointer(uintptr_t wrap) noexcept {
    @try { try {
        return native<uintptr_t (*)(uintptr_t)>(0x484CAF0)(wrap);
    } catch (...) { return 0; } } @catch (NSException *) { return 0; }
}

extern "C" uint64_t YMSelfExpiryRecordID(uintptr_t wrap) noexcept {
    @try {
    const uint64_t identifier = YMSelfRecordID(wrap);
    try {
        if (identifier && field<uint64_t>(wrap, 0xF8) == 0 && YMIsSelfRevokeNotice(wrap)) {
            // This callsite is reached only after a native record was successfully attached.
            const uintptr_t ext = field<uintptr_t>(wrap, 0x210);
            rememberNotice(wrap, ext);
            refreshNotice(ext, false);
        }
    } catch (...) { YMLog(@"[SelfRevoke] native notice binding failed"); }
    return identifier;
    } @catch (NSException *) { return field<uint64_t>(wrap, 0xF8); }
}
extern "C" void YMSelfOriginalExpire(uintptr_t ext);
extern "C" void YMSelfExpire(uintptr_t ext) {
    YMSelfOriginalExpire(ext);
    refreshNotice(ext, true);
}

// Each mid-function helper preserves every GPR, SIMD register and NZCV.
// Continuations replay all four displaced instructions, including relative calls.
#if defined(__aarch64__) && (!defined(YM_SELF_REVOKE_TEST) || defined(YM_SELF_REVOKE_ASSEMBLY_TEST))
extern "C" uintptr_t YMSelfOriginAfter;
uintptr_t YMSelfOriginAfter = 0;
extern "C" uintptr_t YMSelfOriginZero;
uintptr_t YMSelfOriginZero = 0;
extern "C" uintptr_t YMSelfDeleteAfter;
uintptr_t YMSelfDeleteAfter = 0;
extern "C" uintptr_t YMSelfDeleteNative;
uintptr_t YMSelfDeleteNative = 0;
extern "C" uintptr_t YMSelfReplaceDone;
uintptr_t YMSelfReplaceDone = 0;
extern "C" uintptr_t YMSelfReplaceAfter;
uintptr_t YMSelfReplaceAfter = 0;
extern "C" uintptr_t YMSelfReplaceNative;
uintptr_t YMSelfReplaceNative = 0;
extern "C" uintptr_t YMSelfResultEmpty;
uintptr_t YMSelfResultEmpty = 0;
extern "C" uintptr_t YMSelfResultAfter;
uintptr_t YMSelfResultAfter = 0;
extern "C" uintptr_t YMSelfResultZero;
uintptr_t YMSelfResultZero = 0;
extern "C" uintptr_t YMSelfCanaryPointer;
uintptr_t YMSelfCanaryPointer = 0;
extern "C" uintptr_t YMSelfEndAfter;
uintptr_t YMSelfEndAfter = 0;
extern "C" uintptr_t YMSelfQueryAfter;
uintptr_t YMSelfQueryAfter = 0;
extern "C" uintptr_t YMSelfKeySkip;
uintptr_t YMSelfKeySkip = 0;
extern "C" uintptr_t YMSelfKeyAfter;
uintptr_t YMSelfKeyAfter = 0;
extern "C" uintptr_t YMSelfExpiryIDAfter;
uintptr_t YMSelfExpiryIDAfter = 0;
extern "C" uintptr_t YMSelfExpiryIDNull;
uintptr_t YMSelfExpiryIDNull = 0;
extern "C" uintptr_t YMSelfExpireAfter;
uintptr_t YMSelfExpireAfter = 0;
__asm__(
    ".macro YMSelfSave\n"
    "sub sp, sp, #0x310\n"
    "stp x0, x1, [sp, #0]\n"
    "stp x2, x3, [sp, #16]\n"
    "stp x4, x5, [sp, #32]\n"
    "stp x6, x7, [sp, #48]\n"
    "stp x8, x9, [sp, #64]\n"
    "stp x10, x11, [sp, #80]\n"
    "stp x12, x13, [sp, #96]\n"
    "stp x14, x15, [sp, #112]\n"
    "stp x16, x17, [sp, #128]\n"
    "stp x18, x19, [sp, #144]\n"
    "stp x20, x21, [sp, #160]\n"
    "stp x22, x23, [sp, #176]\n"
    "stp x24, x25, [sp, #192]\n"
    "stp x26, x27, [sp, #208]\n"
    "stp x28, x29, [sp, #224]\n"
    "str x30, [sp, #240]\n"
    "mrs x16, nzcv\n"
    "str x16, [sp, #248]\n"
    "stp q0, q1, [sp, #256]\n"
    "stp q2, q3, [sp, #288]\n"
    "stp q4, q5, [sp, #320]\n"
    "stp q6, q7, [sp, #352]\n"
    "stp q8, q9, [sp, #384]\n"
    "stp q10, q11, [sp, #416]\n"
    "stp q12, q13, [sp, #448]\n"
    "stp q14, q15, [sp, #480]\n"
    "stp q16, q17, [sp, #512]\n"
    "stp q18, q19, [sp, #544]\n"
    "stp q20, q21, [sp, #576]\n"
    "stp q22, q23, [sp, #608]\n"
    "stp q24, q25, [sp, #640]\n"
    "stp q26, q27, [sp, #672]\n"
    "stp q28, q29, [sp, #704]\n"
    "stp q30, q31, [sp, #736]\n"
    ".endmacro\n"
    ".macro YMSelfRestore\n"
    "ldp q0, q1, [sp, #256]\n"
    "ldp q2, q3, [sp, #288]\n"
    "ldp q4, q5, [sp, #320]\n"
    "ldp q6, q7, [sp, #352]\n"
    "ldp q8, q9, [sp, #384]\n"
    "ldp q10, q11, [sp, #416]\n"
    "ldp q12, q13, [sp, #448]\n"
    "ldp q14, q15, [sp, #480]\n"
    "ldp q16, q17, [sp, #512]\n"
    "ldp q18, q19, [sp, #544]\n"
    "ldp q20, q21, [sp, #576]\n"
    "ldp q22, q23, [sp, #608]\n"
    "ldp q24, q25, [sp, #640]\n"
    "ldp q26, q27, [sp, #672]\n"
    "ldp q28, q29, [sp, #704]\n"
    "ldp q30, q31, [sp, #736]\n"
    "ldr x16, [sp, #248]\n"
    "msr nzcv, x16\n"
    "ldp x0, x1, [sp, #0]\n"
    "ldp x2, x3, [sp, #16]\n"
    "ldp x4, x5, [sp, #32]\n"
    "ldp x6, x7, [sp, #48]\n"
    "ldp x8, x9, [sp, #64]\n"
    "ldp x10, x11, [sp, #80]\n"
    "ldp x12, x13, [sp, #96]\n"
    "ldp x14, x15, [sp, #112]\n"
    "ldp x16, x17, [sp, #128]\n"
    "ldp x18, x19, [sp, #144]\n"
    "ldp x20, x21, [sp, #160]\n"
    "ldp x22, x23, [sp, #176]\n"
    "ldp x24, x25, [sp, #192]\n"
    "ldp x26, x27, [sp, #208]\n"
    "ldp x28, x29, [sp, #224]\n"
    "ldr x30, [sp, #240]\n"
    "add sp, sp, #0x310\n"
    ".endmacro\n"
);
extern "C" void YMSelfOriginStub(void);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfOriginStub\n"
    "_YMSelfOriginStub:\n"
    "YMSelfSave\n"
    "add x0, sp, #0x310\n"
    "mov x1, sp\n"
    "bl _YMSelfOrigin\n"
    "YMSelfRestore\n"
    "ldr x22, [sp, #0x2D8]\n"
    "cbz x22, 1f\n"
    "add x8, x22, #8\n"
    "mov x9, #-1\n"
    "adrp x16, _YMSelfOriginAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfOriginAfter@PAGEOFF]\n"
    "br x16\n"
    "1:\n"
    "adrp x16, _YMSelfOriginZero@PAGE\n"
    "ldr x16, [x16, _YMSelfOriginZero@PAGEOFF]\n"
    "br x16\n"
);
extern "C" void YMSelfDeleteStub(void);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfDeleteStub\n"
    "_YMSelfDeleteStub:\n"
    "YMSelfSave\n"
    "add x0, sp, #0x310\n"
    "bl _YMSelfDelete\n"
    "cbz w0, 1f\n"
    "YMSelfRestore\n"
    "adrp x16, _YMSelfDeleteAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfDeleteAfter@PAGEOFF]\n"
    "br x16\n"
    "1:\n"
    "YMSelfRestore\n"
    "ldr x0, [sp, #0x2D0]\n"
    "add x1, sp, #0x18\n"
    "mov w2, #0\n"
    "adrp x16, _YMSelfDeleteAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfDeleteAfter@PAGEOFF]\n"
    "mov x30, x16\n"
    "adrp x16, _YMSelfDeleteNative@PAGE\n"
    "ldr x16, [x16, _YMSelfDeleteNative@PAGEOFF]\n"
    "br x16\n"
);
extern "C" void YMSelfReplaceStub(void);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfReplaceStub\n"
    "_YMSelfReplaceStub:\n"
    "YMSelfSave\n"
    "add x0, sp, #0x310\n"
    "mov x1, x29\n"
    "bl _YMSelfReplace\n"
    "cbz w0, 1f\n"
    "YMSelfRestore\n"
    "adrp x16, _YMSelfReplaceDone@PAGE\n"
    "ldr x16, [x16, _YMSelfReplaceDone@PAGEOFF]\n"
    "br x16\n"
    "1:\n"
    "YMSelfRestore\n"
    "ldur x0, [x29, #-0xD0]\n"
    "add x8, sp, #0x2D0\n"
    "add x1, sp, #0x5E8\n"
    "adrp x16, _YMSelfReplaceAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfReplaceAfter@PAGEOFF]\n"
    "mov x30, x16\n"
    "adrp x16, _YMSelfReplaceNative@PAGE\n"
    "ldr x16, [x16, _YMSelfReplaceNative@PAGEOFF]\n"
    "br x16\n"
);
extern "C" void YMSelfResultStub(void);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfResultStub\n"
    "_YMSelfResultStub:\n"
    "YMSelfSave\n"
    "add x0, sp, #0x310\n"
    "mov x1, x19\n"
    "bl _YMSelfSuppressResult\n"
    "cbz w0, 1f\n"
    "YMSelfRestore\n"
    "adrp x16, _YMSelfResultEmpty@PAGE\n"
    "ldr x16, [x16, _YMSelfResultEmpty@PAGEOFF]\n"
    "br x16\n"
    "1:\n"
    "YMSelfRestore\n"
    "ldr w8, [sp, #0x6DC]\n"
    "cbz w8, 2f\n"
    "add x1, sp, #0x5E8\n"
    "mov x0, x19\n"
    "adrp x16, _YMSelfResultAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfResultAfter@PAGEOFF]\n"
    "br x16\n"
    "2:\n"
    "adrp x16, _YMSelfResultZero@PAGE\n"
    "ldr x16, [x16, _YMSelfResultZero@PAGEOFF]\n"
    "br x16\n"
);
extern "C" void YMSelfEndStub(void);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfEndStub\n"
    "_YMSelfEndStub:\n"
    "YMSelfSave\n"
    "add x0, sp, #0x310\n"
    "bl _YMSelfEnd\n"
    "YMSelfRestore\n"
    "ldur x8, [x29, #-0x48]\n"
    "adrp x16, _YMSelfCanaryPointer@PAGE\n"
    "ldr x16, [x16, _YMSelfCanaryPointer@PAGEOFF]\n"
    "ldr x9, [x16]\n"
    "ldr x9, [x9]\n"
    "adrp x16, _YMSelfEndAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfEndAfter@PAGEOFF]\n"
    "br x16\n"
);
extern "C" void YMSelfQueryStub(void);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfQueryStub\n"
    "_YMSelfQueryStub:\n"
    "YMSelfSave\n"
    "mov x0, x20\n"
    "bl _YMSelfRecordID\n"
    "str x0, [sp, #152]\n"
    "YMSelfRestore\n"
    "ldr x28, [sp, #0x310]\n"
    "ldr x8, [sp, #0x318]\n"
    "cmp x28, x8\n"
    "adrp x16, _YMSelfQueryAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfQueryAfter@PAGEOFF]\n"
    "br x16\n"
);
extern "C" void YMSelfKeyStub(void);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfKeyStub\n"
    "_YMSelfKeyStub:\n"
    "YMSelfSave\n"
    "mov x0, x20\n"
    "bl _YMSelfRecordID\n"
    "str x0, [sp, #8]\n"
    "mov x0, x20\n"
    "bl _YMSelfSessionPointer\n"
    "cbz x0, 1f\n"
    "str x0, [sp]\n"
    "YMSelfRestore\n"
    "add x8, sp, #0x30\n"
    "adrp x16, _YMSelfKeyAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfKeyAfter@PAGEOFF]\n"
    "br x16\n"
    "1:\n"
    "YMSelfRestore\n"
    "adrp x16, _YMSelfKeySkip@PAGE\n"
    "ldr x16, [x16, _YMSelfKeySkip@PAGEOFF]\n"
    "br x16\n"
);
extern "C" void YMSelfExpiryIDStub(void);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfExpiryIDStub\n"
    "_YMSelfExpiryIDStub:\n"
    "YMSelfSave\n"
    "add x0, sp, #0x340\n"
    "bl _YMSelfExpiryRecordID\n"
    "str x0, [sp, #16]\n"
    "YMSelfRestore\n"
    "ldp x8, x24, [x29, #-0xE0]\n"
    "stp x8, x24, [sp, #0x10]\n"
    "cbz x24, 1f\n"
    "adrp x16, _YMSelfExpiryIDAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfExpiryIDAfter@PAGEOFF]\n"
    "br x16\n"
    "1:\n"
    "adrp x16, _YMSelfExpiryIDNull@PAGE\n"
    "ldr x16, [x16, _YMSelfExpiryIDNull@PAGEOFF]\n"
    "br x16\n"
);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMSelfOriginalExpire\n"
    "_YMSelfOriginalExpire:\n"
    ".cfi_startproc\n"
    "stp x28, x27, [sp, #-0x30]!\n"
    "stp x20, x19, [sp, #0x10]\n"
    "stp x29, x30, [sp, #0x20]\n"
    "add x29, sp, #0x20\n"
    "adrp x16, _YMSelfExpireAfter@PAGE\n"
    "ldr x16, [x16, _YMSelfExpireAfter@PAGEOFF]\n"
    "br x16\n"
    ".cfi_endproc\n"
);
#endif

namespace {
struct Fingerprint { uintptr_t address; uint8_t bytes[16]; };
// Exact Build269079 instructions, including native callees and continuation paths.
const Fingerprint fingerprints[] = {
    {0x2BBBE44, {0xe0, 0x6b, 0x41, 0xf9, 0xe1, 0x63, 0x00, 0x91, 0x02, 0x00, 0x80, 0x52, 0xf0, 0x7d, 0xf2, 0x97}},
    {0x2BBBF04, {0xa0, 0x03, 0x53, 0xf8, 0xe8, 0x43, 0x0b, 0x91, 0xe1, 0xa3, 0x17, 0x91, 0xd0, 0x44, 0xf3, 0x97}},
    {0x2BBC918, {0xe8, 0xdf, 0x46, 0xb9, 0xc8, 0x02, 0x00, 0x34, 0xe1, 0xa3, 0x17, 0x91, 0xe0, 0x03, 0x13, 0xaa}},
    {0x2BBAC58, {0xa8, 0x83, 0x5b, 0xf8, 0xa9, 0xf8, 0x02, 0x90, 0x29, 0xe5, 0x45, 0xf9, 0x29, 0x01, 0x40, 0xf9}},
    {0x2BBF534, {0x93, 0x7e, 0x40, 0xf9, 0xfc, 0x8b, 0x41, 0xf9, 0xe8, 0x8f, 0x41, 0xf9, 0x9f, 0x03, 0x08, 0xeb}},
    {0x2BBF6D8, {0xe0, 0x03, 0x14, 0xaa, 0x05, 0x35, 0x72, 0x94, 0x81, 0x7e, 0x40, 0xf9, 0xe8, 0xc3, 0x00, 0x91}},
    {0x2BBFD48, {0xe2, 0x97, 0x40, 0xf9, 0xa8, 0x63, 0x72, 0xa9, 0xe8, 0x63, 0x01, 0xa9, 0x78, 0x00, 0x00, 0xb4}},
    {0x48B5454, {0xfc, 0x6f, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
    {0x2BBB1A8, {0xf6, 0x6f, 0x41, 0xf9, 0x76, 0x01, 0x00, 0xb4, 0xc8, 0x22, 0x00, 0x91, 0x09, 0x00, 0x80, 0x92}},
    {0x2897FC0, {0xf8, 0x5f, 0xbc, 0xa9, 0xf6, 0x57, 0x01, 0xa9, 0xf4, 0x4f, 0x02, 0xa9, 0xfd, 0x7b, 0x03, 0xa9}},
    {0xB5F950, {0xf8, 0x5f, 0xbc, 0xa9, 0xf6, 0x57, 0x01, 0xa9, 0xf4, 0x4f, 0x02, 0xa9, 0xfd, 0x7b, 0x03, 0xa9}},
    {0x215B27C, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa}},
    {0xAE194, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0x13, 0x04, 0x40, 0xf9}},
    {0x428E5D4, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
    {0x13AAE84, {0x0a, 0xa4, 0x42, 0xa9, 0x0a, 0x25, 0x00, 0xa9, 0x89, 0x00, 0x00, 0xb4, 0x28, 0x21, 0x00, 0x91}},
    {0x2151AEC, {0xff, 0xc3, 0x01, 0xd1, 0xf4, 0x4f, 0x05, 0xa9, 0xfd, 0x7b, 0x06, 0xa9, 0xfd, 0x83, 0x01, 0x91}},
    {0x278E828, {0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9, 0xf8, 0x5f, 0x02, 0xa9, 0xf6, 0x57, 0x03, 0xa9}},
    {0x428D0BC, {0x28, 0x84, 0x02, 0xb0, 0x00, 0xb5, 0x42, 0xf9, 0xc0, 0x03, 0x5f, 0xd6, 0xff, 0xc3, 0x00, 0xd1}},
    {0x484CAF0, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa}},
    {0x484CC14, {0x08, 0x0c, 0x40, 0xb9, 0x09, 0xe2, 0x84, 0x52, 0x1f, 0x01, 0x09, 0x6b, 0x60, 0x05, 0x00, 0x54}},
    {0x46028A8, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
    {0x2BC008C, {0xff, 0x83, 0x05, 0xd1, 0xfc, 0x6f, 0x12, 0xa9, 0xf6, 0x57, 0x13, 0xa9, 0xf4, 0x4f, 0x14, 0xa9}},
    {0x285B610, {0xf8, 0x5f, 0xbc, 0xa9, 0xf6, 0x57, 0x01, 0xa9, 0xf4, 0x4f, 0x02, 0xa9, 0xfd, 0x7b, 0x03, 0xa9}},
    {0x288D250, {0xff, 0x43, 0x01, 0xd1, 0xf6, 0x57, 0x02, 0xa9, 0xf4, 0x4f, 0x03, 0xa9, 0xfd, 0x7b, 0x04, 0xa9}},
    {0x2BBBF14, {0xe0, 0xa3, 0x17, 0x91, 0xe1, 0x43, 0x0b, 0x91, 0xe3, 0x0a, 0xd7, 0x97, 0xe0, 0x43, 0x0b, 0x91}},
    {0x2BBF6EC, {0xe0, 0x03, 0x0b, 0x91, 0xe1, 0xc3, 0x00, 0x91, 0xe2, 0xc3, 0x00, 0x91, 0xe3, 0x03, 0x14, 0xaa}},
    {0x2BBC934, {0xe0, 0xa3, 0x17, 0x91, 0x51, 0x7a, 0xd6, 0x97, 0xe8, 0x03, 0x4a, 0x39, 0x1f, 0x05, 0x00, 0x71}},
    {0x63F23F4, {0xf0, 0x36, 0x01, 0x90, 0x10, 0xb2, 0x45, 0xf9, 0x00, 0x02, 0x1f, 0xd6, 0xf0, 0x36, 0x01, 0x90}},
    {0x63F1AC4, {0xf0, 0x36, 0x01, 0xb0, 0x10, 0xc2, 0x41, 0xf9, 0x00, 0x02, 0x1f, 0xd6, 0xf0, 0x36, 0x01, 0xb0}},
    {0x63F1B78, {0xf0, 0x36, 0x01, 0xb0, 0x10, 0xfe, 0x41, 0xf9, 0x00, 0x02, 0x1f, 0xd6, 0xf0, 0x36, 0x01, 0xb0}},
    {0x48B5580, {0xfc, 0x6f, 0xbb, 0xa9, 0xf8, 0x5f, 0x01, 0xa9, 0xf6, 0x57, 0x02, 0xa9, 0xf4, 0x4f, 0x03, 0xa9}},
};
bool readMemory(uintptr_t address, void *out, size_t count) {
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), address, count,
        (mach_vm_address_t)out, &copied) == KERN_SUCCESS && copied == count;
}
bool matchingImage(uintptr_t base) {
    mach_header_64 header{};
    if (!readMemory(base, &header, sizeof(header)) || header.magic != MH_MAGIC_64 ||
        header.cputype != CPU_TYPE_ARM64 || header.sizeofcmds > 1024 * 1024) return false;
    const uint8_t expected[16] = {0x58,0x02,0x94,0xa4,0x5a,0xf5,0x31,0x0d,0x9a,0x9a,0xc3,0x63,0x9b,0xee,0x0a,0x28};
    size_t offset = sizeof(header), end = offset + header.sizeofcmds;
    bool uuidMatches = false;
    for (uint32_t i = 0; i < header.ncmds; ++i) {
        load_command command{};
        if (offset + sizeof(command) > end || !readMemory(base + offset, &command, sizeof(command)) ||
            command.cmdsize < sizeof(command) || command.cmdsize > end - offset) return false;
        if (command.cmd == LC_UUID) {
            uuid_command uuid{};
            if (command.cmdsize < sizeof(uuid) || !readMemory(base + offset, &uuid, sizeof(uuid))) return false;
            uuidMatches = memcmp(uuid.uuid, expected, sizeof(expected)) == 0;
        }
        offset += command.cmdsize;
    }
    return uuidMatches;
}
bool writeCode(uintptr_t address, const void *bytes) {
    const uintptr_t page = address & ~(uintptr_t)(vm_page_size - 1);
    const size_t length = ((address + 16 - page + vm_page_size - 1) / vm_page_size) * vm_page_size;
    if (mach_vm_protect(mach_task_self(), page, length, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return false;
    memcpy((void *)address, bytes, 16);
    sys_icache_invalidate((void *)address, 16);
    return mach_vm_protect(mach_task_self(), page, length, false, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS;
}
bool applyPatches(uintptr_t base, const uintptr_t *hooks, size_t count,
                  bool (*writer)(uintptr_t, const void *) = writeCode) {
    for (size_t i = 0; i < count; ++i) {
        uint8_t patch[16];
        const uint32_t instructions[2] = {0x58000050, 0xD61F0200};
        memcpy(patch, instructions, 8);
        memcpy(patch + 8, &hooks[i], 8);
        if (!writer(base + fingerprints[i].address, patch)) {
            bool rolledBack = true;
            for (size_t n = i + 1; n > 0; --n)
                rolledBack = writer(base + fingerprints[n - 1].address, fingerprints[n - 1].bytes) && rolledBack;
            YMLog(@"[SelfRevoke] install failed, rollback=%@", rolledBack ? @"OK" : @"FAILED");
            return false;
        }
    }
    return true;
}

}
bool YMInstallSelfRevokePatch(void) {
#if defined(__aarch64__) && !defined(YM_SELF_REVOKE_TEST)
    static std::mutex installMutex;
    std::lock_guard<std::mutex> lock(installMutex);
    if (installed.load()) return true;
    const uintptr_t base = getDylibSlide();
    if (!base || !matchingImage(base)) return false;
    for (const auto &fingerprint : fingerprints) {
        uint8_t actual[16];
        if (!readMemory(base + fingerprint.address, actual, sizeof(actual)) ||
            memcmp(actual, fingerprint.bytes, sizeof(actual))) {
            YMLog(@"[SelfRevoke] unsupported instruction fingerprint at 0x%lx", fingerprint.address);
            return false;
        }
    }
    YMSelfOriginAfter = base + 0x2BBB1B8;
    YMSelfOriginZero = base + 0x2BBB1D8;
    YMSelfDeleteAfter = base + 0x2BBBE54;
    YMSelfDeleteNative = base + 0x285B610;
    YMSelfReplaceDone = base + 0x2BBBF28;
    YMSelfReplaceAfter = base + 0x2BBBF14;
    YMSelfReplaceNative = base + 0x288D250;
    YMSelfResultEmpty = base + 0x2BBC934;
    YMSelfResultAfter = base + 0x2BBC928;
    YMSelfResultZero = base + 0x2BBC974;
    YMSelfCanaryPointer = base + 0x8ACEBC8;
    YMSelfEndAfter = base + 0x2BBAC68;
    YMSelfQueryAfter = base + 0x2BBF544;
    YMSelfKeySkip = base + 0x2BBF51C;
    YMSelfKeyAfter = base + 0x2BBF6E8;
    YMSelfExpiryIDAfter = base + 0x2BBFD58;
    YMSelfExpiryIDNull = base + 0x2BBFD60;
    YMSelfExpireAfter = base + 0x48B5464;
    const uintptr_t hooks[] = {
        (uintptr_t)&YMSelfDeleteStub,
        (uintptr_t)&YMSelfReplaceStub,
        (uintptr_t)&YMSelfResultStub,
        (uintptr_t)&YMSelfEndStub,
        (uintptr_t)&YMSelfQueryStub,
        (uintptr_t)&YMSelfKeyStub,
        (uintptr_t)&YMSelfExpiryIDStub,
        (uintptr_t)&YMSelfExpire,
        (uintptr_t)&YMSelfOriginStub
    };
    // Called from the dyld image-load installation boundary before revoke handling.
    // Validate every site first, then rollback *including* a failed write (RX restore can fail).
    if (!applyPatches(base, hooks, sizeof(hooks) / sizeof(*hooks))) return false;
    installed.store(true);
    return true;
#else
    return false;
#endif
}

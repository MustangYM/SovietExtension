#import "MessageNavigation.h"
#import "RevokePatch.h"
#import "SelfRevokePatch.h"
#import "WeChatCompatibility.h"
#import <AppKit/AppKit.h>
#include <atomic>
#include <cstring>
#include <string>
#include <mach/mach_vm.h>

#if defined(__aarch64__)
namespace {

NSString *const recordsKey = @"YMOriginalMessageLinks.v1";
NSString *const linkPrefix = @"https://soviet.invalid/message/";
std::atomic_bool systemInstalled{false}, textInstalled{false};
struct Entry { uintptr_t address; uint8_t bytes[16]; };
struct NativeLayout {
    uintptr_t manager;
    Entry system, text, convert, navigate;
};
const NativeLayout layout269079{
    0x93b7b90,
    {0x609420, {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
    {0x62a0e0, {0xff,0xc3,0x01,0xd1,0xf8,0x5f,0x03,0xa9,0xf6,0x57,0x04,0xa9,0xf4,0x4f,0x05,0xa9}},
    {0x16c8c8, {0xff,0x43,0x01,0xd1,0xf8,0x5f,0x01,0xa9,0xf6,0x57,0x02,0xa9,0xf4,0x4f,0x03,0xa9}},
    {0x1fe9c4, {0xff,0x43,0x02,0xd1,0xfa,0x67,0x04,0xa9,0xf8,0x5f,0x05,0xa9,0xf6,0x57,0x06,0xa9}},
};
const NativeLayout layout270353{
    0xa68a740,
    {0x74c40c, {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
    {0x77b2c4, {0xff,0xc3,0x01,0xd1,0xf8,0x5f,0x03,0xa9,0xf6,0x57,0x04,0xa9,0xf4,0x4f,0x05,0xa9}},
    {0x20f820, {0xff,0x43,0x01,0xd1,0xf8,0x5f,0x01,0xa9,0xf6,0x57,0x02,0xa9,0xf4,0x4f,0x03,0xa9}},
    {0x15f0330, {0xff,0x83,0x07,0xd1,0xfc,0x6f,0x1b,0xa9,0xf4,0x4f,0x1c,0xa9,0xfd,0x7b,0x1d,0xa9}},
};
const NativeLayout &layout() { return YMMatchesWeChat270353Dylib() ? layout270353 : layout269079; }
// 4.2.0 原生“跳转消息”入口使用 request variant，不能沿用旧七参数调用。
struct NavigationRequest {
    uint64_t reserved = 0;
    std::string session;
    uint32_t mode = 0, padding = 0;
    uint64_t serverID = 0;
    uint32_t seconds = 0, timePadding = 0;
    uint64_t sequence = 0;
    uint32_t localID = 0;
    uint8_t highlight = 1, anchorPadding[3]{}, hasAnchor = 1, tailPadding[7]{};
    int32_t variant = 0;
};
static_assert(offsetof(NavigationRequest, session) == 8);
static_assert(offsetof(NavigationRequest, serverID) == 0x28);
static_assert(offsetof(NavigationRequest, hasAnchor) == 0x48);
static_assert(offsetof(NavigationRequest, variant) == 0x50 && sizeof(NavigationRequest) == 0x58);
bool readMemory(uintptr_t address, void *out, size_t length) {
    mach_vm_size_t copied = 0;
    return address && mach_vm_read_overwrite(mach_task_self(), address, length,
        reinterpret_cast<mach_vm_address_t>(out), &copied) == KERN_SUCCESS && copied == length;
}
bool matches(const Entry &entry) {
    uint8_t bytes[16];
    return readMemory(YMRuntimeAddress(entry.address), bytes, sizeof bytes) &&
        !memcmp(bytes, entry.bytes, sizeof bytes);
}
bool compatible() {
    const bool newer = YMMatchesWeChat270353Dylib();
    return (newer || YMMatchesWeChatLegacyNativeDylib()) &&
        [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:newer ? @"270353" : @"269079"] &&
        [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:newer ? @"4.2.0" : @"4.1.11"] &&
        matches(layout().convert) && matches(layout().navigate);
}
bool validSession(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > 128) return false;
    return NSEqualRanges([value rangeOfString:@"^(?:[A-Za-z0-9_-]{1,128}|[0-9]+@chatroom)$"
        options:NSRegularExpressionSearch], NSMakeRange(0, value.length));
}
uint64_t identifier(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return 0;
    const char *text = [value UTF8String];
    uint64_t result = 0;
    for (const char *cursor = text; *cursor; ++cursor) {
        if (*cursor < '0' || *cursor > '9' || result > (UINT64_MAX - (*cursor - '0')) / 10) return 0;
        result = result * 10 + (*cursor - '0');
    }
    return result;
}
NSDictionary *loadRecord(NSString *token) {
    id records = [NSUserDefaults.standardUserDefaults objectForKey:recordsKey];
    id record = [records isKindOfClass:NSDictionary.class] ? records[token] : nil;
    return [record isKindOfClass:NSDictionary.class] ? record : nil;
}
NSString *createLink(NSString *account, NSString *session, uint64_t serverID,
                     uint32_t sec, uint64_t seq, uint32_t localID, BOOL forwarded) {
    if (!(forwarded ? textInstalled.load() : systemInstalled.load()) ||
        !validSession(account) || !validSession(session) || !serverID ||
        ![account isEqualToString:YMSelfRevokeAccount()]) return nil;
    NSString *token = NSUUID.UUID.UUIDString;
    NSDictionary *record = @{@"account": account, @"session": session,
        @"serverID": [NSString stringWithFormat:@"%llu", (unsigned long long)serverID],
        @"seconds": @(sec), @"sortSeq": [NSString stringWithFormat:@"%llu", (unsigned long long)seq],
        @"localID": @(localID), @"forwarded": @(forwarded)};
    // 仅保存不透明 token；正文链接不携带账号、群名或原消息 ID。
    @synchronized(NSUserDefaults.standardUserDefaults) {
        id saved = [NSUserDefaults.standardUserDefaults objectForKey:recordsKey];
        NSMutableDictionary *records = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
        records[token] = record;
        [NSUserDefaults.standardUserDefaults setObject:records forKey:recordsKey];
    }
    return [linkPrefix stringByAppendingString:token];
}
struct Carrier {
    uint32_t type = 0;
    uint64_t serverID = 0;
    NSString *session = nil;
    NSString *from = nil;
    NSString *to = nil;
    NSString *content = nil;
};
enum class Route { Pass, Invalid, Navigate };
Route resolve(NSString *url, const Carrier &carrier, bool forwarded, NSDictionary **target) {
    if (target) *target = nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:url];
    if (![parts.host.lowercaseString isEqualToString:@"soviet.invalid"]) return Route::Pass;
    // 本地专用域名即使 token 丢失或格式损坏，也不能送往浏览器。
    if (![url hasPrefix:linkPrefix] || parts.query || parts.fragment || parts.user || parts.password || parts.port) return Route::Invalid;
    NSString *token = [url substringFromIndex:linkPrefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:token];
    if (!uuid || ![uuid.UUIDString isEqualToString:token]) return Route::Invalid;
    NSDictionary *record = loadRecord(token);
    NSString *account = YMSelfRevokeAccount();
    if (!record || !validSession(account) || ![record[@"account"] isEqual:account] ||
        !validSession(record[@"session"]) || !identifier(record[@"serverID"]) ||
        ![record[@"forwarded"] isKindOfClass:NSNumber.class] ||
        [record[@"forwarded"] boolValue] != forwarded || ![carrier.content containsString:url]) return Route::Invalid;
    NSString *expectedSession = forwarded ? account : record[@"session"];
    if (![carrier.session isEqual:expectedSession]) return Route::Invalid;
    if (forwarded) {
        if (carrier.type != 1 || ![carrier.from isEqual:account] || ![carrier.to isEqual:account]) return Route::Invalid;
    } else if (carrier.type != 10000 || carrier.serverID != 0) return Route::Invalid;
    if (target) *target = record;
    return Route::Navigate;
}
template<class T> const T &field(const void *object, size_t offset) {
    return *reinterpret_cast<const T *>(static_cast<const uint8_t *>(object) + offset);
}
NSString *stringField(const void *data, size_t offset) {
    const auto &text = field<std::string>(data, offset);
    return [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
}
Carrier carrierFromModel(void *model, bool forwarded) {
    const auto *data = static_cast<const uint8_t *>(model) + (forwarded ? 0x130 : 0x120);
    return {field<uint32_t>(data, 8), field<uint64_t>(data, 0x90), stringField(data, 0x58),
        stringField(data, 0x10), stringField(data, 0x28), stringField(data, YMMatchesWeChat270353Dylib() ? 0xb8 : 0xb0)};
}
void failure() {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"暂时无法定位原消息";
        alert.informativeText = @"请确认当前账号和本机聊天记录。";
        [alert addButtonWithTitle:@"好"];
        [alert runModal];
    });
}
bool navigate(NSDictionary *record) {
    if (!NSThread.isMainThread || !compatible() ||
        ![record[@"account"] isEqual:YMSelfRevokeAccount()]) return false;
    void *manager = nullptr;
    if (!readMemory(YMRuntimeAddress(layout().manager), &manager, sizeof manager) || !manager) return false;
    std::string session([record[@"session"] UTF8String]);
    // 本地 ID 会随数据库变化；持久链接只用服务端 ID，禁止降级误定位到另一条消息。
    if (YMMatchesWeChat270353Dylib()) {
        NavigationRequest request;
        request.session = session;
        request.serverID = identifier(record[@"serverID"]);
        return reinterpret_cast<bool (*)(const NavigationRequest *)>(YMRuntimeAddress(layout().navigate.address))(&request);
    }
    reinterpret_cast<void (*)(void *, const std::string *, uint64_t, uint32_t, uint64_t, uint32_t, bool)>(
        YMRuntimeAddress(layout().navigate.address))(manager, &session, identifier(record[@"serverID"]), 0, 0, 0, true);
    return true;
}
bool handle(void *model, const void *qString, bool forwarded) {
    bool local = false;
    @try { try {
        std::string nativeURL = reinterpret_cast<std::string (*)(const void *)>(YMRuntimeAddress(layout().convert.address))(qString);
        NSString *url = [[NSString alloc] initWithBytes:nativeURL.data() length:nativeURL.size() encoding:NSUTF8StringEncoding];
        NSURLComponents *parts = [NSURLComponents componentsWithString:url];
        if (![parts.host.lowercaseString isEqualToString:@"soviet.invalid"]) return false;
        local = true;
        if (!model || !NSThread.isMainThread) { failure(); return true; }
        NSDictionary *record = nil;
        if (resolve(url, carrierFromModel(model, forwarded), forwarded, &record) != Route::Navigate || !navigate(record)) failure();
        return true;
    } catch (...) { if (local) failure(); return local; } }
    @catch (NSException *) { if (local) failure(); return local; }
}
}
extern "C" {
uintptr_t YMSystemMessageLinkContinue = 0, YMTextMessageLinkContinue = 0;
void YMOriginalSystemMessageLink(void *, const void *, uintptr_t, void *);
void YMOriginalTextMessageLink(void *, const void *, uintptr_t);
void YMSystemMessageLinkHook(void *model, const void *url, uintptr_t flag, void *context) {
    if (!handle(model, url, false)) YMOriginalSystemMessageLink(model, url, flag, context);
}
void YMTextMessageLinkHook(void *model, const void *url, uintptr_t context) {
    if (!handle(model, url, true)) YMOriginalTextMessageLink(model, url, context);
}
}
// 每个 trampoline 原样重放入口的 16 字节，保留原参数和返回地址。
__asm__(
    ".text\n.align 2\n.globl _YMOriginalSystemMessageLink\n_YMOriginalSystemMessageLink:\n"
    "stp x28, x27, [sp, #-0x60]!\nstp x26, x25, [sp, #0x10]\n"
    "stp x24, x23, [sp, #0x20]\nstp x22, x21, [sp, #0x30]\n"
    "adrp x16, _YMSystemMessageLinkContinue@PAGE\nldr x16, [x16, _YMSystemMessageLinkContinue@PAGEOFF]\nbr x16\n"
    ".align 2\n.globl _YMOriginalTextMessageLink\n_YMOriginalTextMessageLink:\n"
    "sub sp, sp, #0x70\nstp x24, x23, [sp, #0x30]\n"
    "stp x22, x21, [sp, #0x40]\nstp x20, x19, [sp, #0x50]\n"
    "adrp x16, _YMTextMessageLinkContinue@PAGE\nldr x16, [x16, _YMTextMessageLinkContinue@PAGEOFF]\nbr x16\n"
);
void YMInstallMessageNavigationPatch(void) {
    if (!compatible()) return;
    if (!systemInstalled.load() && matches(layout().system)) {
        YMSystemMessageLinkContinue = YMRuntimeAddress(layout().system.address + 16);
        systemInstalled.store(YMPatchARM64AbsoluteJump(YMRuntimeAddress(layout().system.address),
            reinterpret_cast<uintptr_t>(&YMSystemMessageLinkHook), "system message link"));
    }
    if (!textInstalled.load() && matches(layout().text)) {
        YMTextMessageLinkContinue = YMRuntimeAddress(layout().text.address + 16);
        textInstalled.store(YMPatchARM64AbsoluteJump(YMRuntimeAddress(layout().text.address),
            reinterpret_cast<uintptr_t>(&YMTextMessageLinkHook), "text message link"));
    }
}
void YMNavigateOriginalMessage(NSDictionary *record) {
    @try { try { if (!navigate(record)) failure(); } catch (...) { failure(); } }
    @catch(NSException *) { failure(); }
}
NSString *YMOriginalMessageLink(NSString *account, NSString *session, uint64_t serverID,
    uint32_t sec, uint64_t seq, uint32_t localID, BOOL forwarded) {
    @try { return createLink(account, session, serverID, sec, seq, localID, forwarded); }
    @catch (NSException *) { return nil; }
}
#else
void YMInstallMessageNavigationPatch(void) {}
void YMNavigateOriginalMessage(NSDictionary *) {}
NSString *YMOriginalMessageLink(NSString *, NSString *, uint64_t, uint32_t, uint64_t, uint32_t, BOOL) { return nil; }
#endif

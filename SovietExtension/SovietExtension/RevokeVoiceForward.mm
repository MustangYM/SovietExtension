#import "VoiceUploadPatch.h"
#import "VoiceLimits.h"
#import "ForwardToSelfPatch.h"
#import "SelfRevokePatch.h"
#import "RevokeSettings.h"
#import "RevokePatch.h"
#import "WeChatCompatibility.h"
#include <atomic>
#include <chrono>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <mach/mach_vm.h>

#if defined(__aarch64__)
namespace {
using Shared = std::shared_ptr<void>;
using Clock = std::chrono::steady_clock;
constexpr size_t MaxAudio = YMVoiceMaxEncodedBytes;
constexpr unsigned MaxOutstanding = 8;
std::mutex admission;
unsigned outstanding = 0;
bool fused = false; // 进程级熔断：原生任务未返回终态就被释放后，不再尝试发送。
std::atomic<uintptr_t> lazyDestructor{0};
void note(NSString *reason) noexcept {
    @autoreleasepool { @try { try { YMLog(@"[VoiceForward] %@", reason); } catch (...) {} }
    @catch (NSException *) {} }
}

template<class T> T call(uintptr_t address) {
    if (!address) throw std::runtime_error("missing voice address");
    return reinterpret_cast<T>(address);
}
void readMemory(uintptr_t p, void *dst, size_t n) {
    if (!p || n > MaxAudio || p + n < p) throw std::runtime_error("bad voice range");
    mach_vm_size_t copied = 0;
    if (mach_vm_read_overwrite(mach_task_self(), p, n,
            reinterpret_cast<mach_vm_address_t>(dst), &copied) != KERN_SUCCESS || copied != n)
        throw std::runtime_error("unreadable voice data");
}
template<class T> T read(uintptr_t p, size_t offset = 0) {
    if (p + offset < p) throw std::runtime_error("voice offset overflow");
    T value{}; readMemory(p + offset, &value, sizeof value); return value;
}
std::string readString(uintptr_t p, size_t maximum) {
    uint8_t raw[24]; readMemory(p, raw, sizeof raw);
    if (!(raw[23] & 0x80)) {
        const size_t n = raw[23];
        if (n > 22 || n > maximum || raw[n]) throw std::runtime_error("bad voice short string");
        return std::string(reinterpret_cast<const char *>(raw), n);
    }
    uintptr_t data; uint64_t length, capacity;
    memcpy(&data, raw, 8); memcpy(&length, raw + 8, 8); memcpy(&capacity, raw + 16, 8);
    capacity &= UINT64_C(0x7fffffffffffffff);
    if (length > maximum || capacity <= length || !data) throw std::runtime_error("bad voice long string");
    std::string value(static_cast<size_t>(length), '\0');
    if (length) readMemory(data, &value[0], static_cast<size_t>(length));
    if (read<uint8_t>(data, static_cast<size_t>(length))) throw std::runtime_error("unterminated voice string");
    return value;
}
std::string text(NSString *value) {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes.length || bytes.length > 128) return {};
    return std::string(static_cast<const char *>(bytes.bytes), bytes.length);
}
bool identifier(const std::string &value) {
    return !value.empty() && value.size() <= 128 && value.find('\0') == std::string::npos;
}
bool selfIdentifier(NSString *value) {
    if (!value.length || value.length > 128 || [value isEqualToString:@"filehelper"] ||
        [value containsString:@"@chatroom"] || [value containsString:@"\n"] ||
        [value containsString:@" "] || [value containsString:@"<"] || [value containsString:@">"]) return false;
    if ([value hasPrefix:@"wxid_"]) return true;
    return [value rangeOfString:@"^[A-Za-z0-9_\\-]{5,128}$" options:NSRegularExpressionSearch].location != NSNotFound;
}
struct Key {
    std::string session;
    uint32_t createTime = 0, localID = 0;
    uint64_t nativeScalar = 0; // 对应 Wrap+0x100，与 serverID 是不同字段。
    std::string extra;
};
struct SourceLocation {
    const char *label, *file;
    uint32_t line, padding;
    uintptr_t caller;
};
struct Await { Shared future; uint64_t reserved = 0; };
struct Metadata {
    uint32_t format = 4, mode = 3, sampleRate = 30000, zero = 0;
    uint64_t flags = 0;
    std::string extra;
};
struct Lazy {
    alignas(8) uint8_t storage[56];
    ~Lazy() { call<void (*)(void *)>(lazyDestructor.load())(this); }
    Lazy(const Lazy &) = delete;
    Lazy &operator=(const Lazy &) = delete;
};
// 按成员声明的逆序正常析构，对应 0x17a070，不能使用 0x5b78d0。
struct Subscription { uint64_t id; Shared cancellation, owner; };
using Error = std::function<void(const std::exception_ptr &)>;
static_assert(sizeof(std::string) == 24 && sizeof(std::function<void()>) == 32 && sizeof(Error) == 32);
static_assert(sizeof(Shared) == 16 && sizeof(Await) == 24);
static_assert(sizeof(Key) == 64 && offsetof(Key, createTime) == 24 && offsetof(Key, extra) == 40);
static_assert(sizeof(SourceLocation) == 32 && offsetof(SourceLocation, caller) == 24);
static_assert(sizeof(Metadata) == 48 && offsetof(Metadata, extra) == 24);
static_assert(sizeof(Lazy) == 56 && sizeof(Subscription) == 40);
static_assert(offsetof(Subscription, cancellation) == 8 && offsetof(Subscription, owner) == 24);

// 原生发送复制载荷后，仅保留这个小型状态对象。即使任务已经返回终态，
// 并发名额也由最后一个回调副本持有，直到该副本析构才释放。
struct Attempt {
    bool reserved = false;
    std::atomic_bool attempted{false};
    std::atomic<unsigned> terminal{0};
    ~Attempt() {
        if (!reserved) return;
        const bool missingTerminal = attempted.load() && !terminal.load();
        {
            std::lock_guard<std::mutex> lock(admission);
            if (missingTerminal) fused = true;
            --outstanding;
        }
        if (missingTerminal) note(@"native-drop; voice-fuse-closed");
    }
};

struct Job {
    YMVoiceForwardAddresses f{};
    Key key;
    std::string accountID, destination, audio;
    uintptr_t accountObject = 0;
    uint64_t serverID = 0;
    uint32_t length = 0, duration = 0;
    bool own = false;
    Clock::time_point expires;
    std::shared_ptr<Attempt> attempt = std::make_shared<Attempt>();
};
void failed(const Job &, NSString *reason) noexcept { note(reason); }
bool abiOK() {
    std::string small("voice"), large(80, 'x');
    uint8_t raw[24]; memcpy(raw, &small, 24);
    if (raw[23] != 5 || memcmp(raw, "voice", 5)) return false;
    memcpy(raw, &large, 24);
    uintptr_t ptr; uint64_t size; memcpy(&ptr, raw, 8); memcpy(&size, raw + 8, 8);
    if (!(raw[23] & 0x80) || ptr != reinterpret_cast<uintptr_t>(large.data()) || size != 80) return false;
    std::function<void()> empty;
    uintptr_t target; memcpy(&target, reinterpret_cast<const uint8_t *>(&empty) + 24, 8);
    if (target) return false;
    auto owned = std::make_shared<int>(7); Shared shared = owned;
    uintptr_t pair[2]; memcpy(pair, &shared, sizeof pair);
    return pair[0] == reinterpret_cast<uintptr_t>(owned.get()) && pair[1] != 0;
}
bool addressesOK(const YMVoiceForwardAddresses &f) {
    return f.account && f.accountLauncher && f.service && f.context && f.manager &&
        f.launch && f.query && f.await && f.result && f.makeVoice && f.subscribe &&
        f.destroyLazy && f.dynamicCast && f.messageExtRTTI && f.voiceExtRTTI;
}

bool reserve(Job &job) {
    std::lock_guard<std::mutex> lock(admission);
    const auto destructor = lazyDestructor.load();
    if (fused || outstanding >= MaxOutstanding || (destructor && destructor != job.f.destroyLazy)) return false;
    lazyDestructor.store(job.f.destroyLazy);
    ++outstanding;
    job.attempt->reserved = true;
    return true;
}
bool current(const Job &job) {
    if (Clock::now() >= job.expires || !YMRevokeRealSendForwardEnabled() ||
        job.destination != job.accountID) return false;
    const auto policy = YMReadRevokeSettings(NSUserDefaults.standardUserDefaults);
    if (!policy.enabled || !policy.forward ||
        !(job.own ? policy.self && policy.forwardSelf : policy.others && policy.forwardOthers)) return false;
    { std::lock_guard<std::mutex> lock(admission); if (fused) return false; }
    // 读取账号 ID 前后都校验账号对象指针，拦截期间发生的账号切换。
    const auto before = call<uintptr_t (*)()>(job.f.account)();
    const auto id = text(YMSelfRevokeAccount());
    return before == job.accountObject && id == job.accountID &&
        call<uintptr_t (*)()>(job.f.account)() == job.accountObject && Clock::now() < job.expires;
}
bool silk(const std::string &audio, uint32_t expected) {
    return audio.size() == expected && audio.size() >= 10 &&
        !memcmp(audio.data() + 1, "#!SILK_V3", 9);
}
void sendOne(const std::shared_ptr<Job> &job, const std::string &target,
             const std::shared_ptr<Attempt> &token) noexcept {
    @autoreleasepool { @try { try {
        if (!current(*job)) { failed(*job, @"send-gate-closed"); return; }
        if (!silk(job->audio, job->length)) { failed(*job, @"send-audio-invalid"); return; }
        Metadata metadata;
        // 此版本会直接覆盖 x0，不读取其原值。自动同步的目标始终是本人；
        // 手动转发的目标来自用户本次确认的选择。
        auto lazy = call<Lazy (*)(void *, const std::string *, const std::string *, uint32_t,
            const Metadata *)>(job->f.makeVoice)(reinterpret_cast<void *>(job->accountObject),
            &job->audio, &target, job->duration, &metadata);
        std::function<void()> value;
        Error error = [token](const std::exception_ptr &) noexcept {
            token->terminal.store(2);
            note(@"native-error");
        };
        std::function<void()> complete = [token]() noexcept {
            unsigned none = 0; token->terminal.compare_exchange_strong(none, 1);
        };
        static const SourceLocation location{"VoiceForwardToSelf", "VoiceForwardToSelf.mm", 1, 0,
            reinterpret_cast<uintptr_t>(&YMForwardVoiceToSelf)};
        if (!current(*job)) { failed(*job, @"send-gate-closed"); return; }
        // 调用原生接口时不持有名额锁，避免同步回调或析构重入导致死锁。
        // 每个目标各持有一个已预留名额的状态对象。
        token->attempted.store(true);
        auto subscription = call<Subscription (*)(Lazy *, std::function<void()> *, Error *,
            std::function<void()> *, const SourceLocation *)>(job->f.subscribe)(
                &lazy, &value, &error, &complete, &location);
        if (!subscription.id || !subscription.cancellation) failed(*job, @"subscription-invalid");
        // 原生请求已持有自己的副本；此处不重试、不取消，也不保留订阅。
        // 未收到终态就释放回调时，最后一个状态对象析构会触发熔断。
    } catch (...) { failed(*job, @"send-exception"); } }
    @catch (NSException *) { failed(*job, @"send-objc-exception"); } }
}
void send(std::shared_ptr<Job> job) noexcept {
    sendOne(job, job->destination, job->attempt);
}

NSString *readChatAudio(const Job &source, const std::function<bool()> &isCurrent, std::string &audio) {
    const Job *job = &source;
    audio.clear();
    if (!isCurrent()) return @"query-gate-closed";
    auto service = call<Shared (*)()>(job->f.service)();
    if (!service) return @"query-service-missing";
    auto context = call<Shared (*)(void *)>(job->f.context)(service.get());
    if (!context) return @"query-context-missing";
    auto manager = call<Shared (*)(void *)>(job->f.manager)(context.get());
    if (!manager) return @"query-manager-missing";
    if (!isCurrent()) return @"query-gate-closed";
    const auto receiver = read<uintptr_t>(reinterpret_cast<uintptr_t>(manager.get()), 0xb78);
    if (!receiver) return @"query-receiver-missing";
    // Outgoing one-to-one voice cache rows use receiver "1" while
    // incoming and group rows use "0". Try the source direction first,
    // then the other native bucket without weakening identity checks.
    const char *indices[] = {job->own ? "1" : "0", job->own ? "0" : "1"};
    bool copied = false;
    for (const char *value : indices) {
        const std::string index(value);
        auto future = call<Shared (*)(void *, const Key *, const std::string *)>(job->f.query)(
            reinterpret_cast<void *>(receiver), &job->key, &index);
        if (!future) continue;
        Await awaiting{future, 0};
        call<void (*)(Await *)>(job->f.await)(&awaiting);
        const auto *borrowed = call<const Shared *(*)(Await *)>(job->f.result)(&awaiting);
        if (!borrowed || !*borrowed) continue;
        Shared result = *borrowed;
        if (!isCurrent()) return @"query-gate-closed";
        const auto p = reinterpret_cast<uintptr_t>(result.get());
        const auto cachedServerID = read<uint64_t>(p, 0x10);
        if (read<uint32_t>(p, 4) != job->key.createTime || read<uint32_t>(p, 8) != job->key.localID ||
            (cachedServerID && cachedServerID != job->serverID) || readString(p + 0x48, 128) != job->key.session ||
            readString(p + 0x30, 128) != index) continue;
        const auto vector = read<uintptr_t>(p, 0x60);
        if (!vector) continue;
        const auto begin = read<uintptr_t>(vector), end = read<uintptr_t>(vector, 8), cap = read<uintptr_t>(vector, 16);
        if (!begin || end < begin || cap < end || cap - begin > MaxAudio || end - begin != job->length) continue;
        audio.resize(job->length);
        readMemory(begin, &audio[0], audio.size());
        copied = true;
        break;
    }
    if (!copied) return @"query-identity-mismatch";
    return silk(audio, job->length) ? nil : @"query-audio-invalid";
}
void query(std::shared_ptr<Job> job) noexcept {
    @autoreleasepool { @try { try {
        NSString *problem = readChatAudio(*job, [job] { return current(*job); }, job->audio);
        if (problem) { failed(*job, problem); return; }
        if (!silk(job->audio, job->length)) { failed(*job, @"query-audio-invalid"); return; }
        // 时长直接使用原始语音扩展中的毫秒值，不根据音频字节数推算。
        dispatch_async(dispatch_get_main_queue(), ^{ send(job); });
    } catch (...) { failed(*job, @"query-exception"); } } @catch (NSException *) { failed(*job, @"query-objc-exception"); } }
}

void launch(std::shared_ptr<Job> job) noexcept {
    @autoreleasepool { @try { try {
        if (!current(*job)) { failed(*job, @"launch-gate-closed"); return; }
        auto launcher = call<Shared (*)(void *)>(job->f.accountLauncher)(reinterpret_cast<void *>(job->accountObject));
        if (!launcher) { failed(*job, @"launcher-missing"); return; }
        if (!current(*job)) { failed(*job, @"launch-gate-closed"); return; }
        static const SourceLocation location{"VoiceForwardLocalQuery", "VoiceForwardToSelf.mm", 1, 0,
            reinterpret_cast<uintptr_t>(&YMForwardVoiceToSelf)};
        std::function<void()> body = [job] { query(job); };
        auto task = call<Shared (*)(void *, const SourceLocation *, std::function<void()> *, int)>(job->f.launch)(
            launcher.get(), &location, &body, 1);
        if (!task) failed(*job, @"query-task-empty");
        // 原生调度器持有回调副本，任务和回调之间不存在循环持有。
    } catch (...) { failed(*job, @"launch-exception"); } } @catch (NSException *) { failed(*job, @"launch-objc-exception"); } }
}
bool captureWrapVoice(Job &job, uintptr_t wrap, const std::string &session) {
    if (read<uint32_t>(wrap, 0xc) != 34) { note(@"capture-not-voice"); return false; }
    if (!identifier(session) || !identifier(readString(wrap + 0x18, 128)) || !identifier(readString(wrap + 0x30, 128))) {
        note(@"capture-participants-invalid"); return false;
    }
    job.key.session = session;
    job.key.createTime = read<uint32_t>(wrap, 0x114);
    job.key.localID = read<uint32_t>(wrap, 0xf4);
    job.key.nativeScalar = read<uint64_t>(wrap, 0x100);
    job.key.extra = readString(wrap + (YMMatchesWeChat270353Dylib() ? 0x260 : 0x250), 4096);
    job.serverID = read<uint64_t>(wrap, 0xf8);
    const auto raw = read<uintptr_t>(wrap, YMMatchesWeChat270353Dylib() ? 0x220 : 0x210);
    if (!raw) { note(@"capture-ext-missing"); return false; }
    const auto ext = reinterpret_cast<uintptr_t>(call<void *(*)(void *, const void *, const void *, ptrdiff_t)>(
        job.f.dynamicCast)(reinterpret_cast<void *>(raw), reinterpret_cast<const void *>(job.f.messageExtRTTI),
        reinterpret_cast<const void *>(job.f.voiceExtRTTI), 0));
    if (!ext) { note(@"capture-ext-type-mismatch"); return false; }
    const size_t metadata = YMMatchesWeChat270353Dylib() ? 0x1a8 : 0x148;
    job.length = read<uint32_t>(ext, metadata);
    job.duration = read<uint32_t>(ext, metadata + 4);
    if (!job.key.createTime || !job.key.localID || !job.serverID || job.length < 1 || job.length > MaxAudio ||
        job.duration < 1 || job.duration > 60000 || read<uint32_t>(ext, metadata + 8) != 4) {
        note(@"capture-metadata-invalid"); return false;
    }
    return true;
}

}

BOOL YMForwardVoiceToSelf(uintptr_t wrap, NSString *sourceSession, NSString *selfID) {
    @autoreleasepool { @try { try {
        if (!wrap || !YMRevokeRealSendForwardEnabled()) return NO;
        static const bool compatible = abiOK();
        if (!compatible) { note(@"unsupported-abi"); return NO; }
        auto job = std::make_shared<Job>();
        if (!YMGetVoiceForwardAddresses(&job->f) || !addressesOK(job->f)) { note(@"unsupported-build"); return NO; }
        const auto source = text(sourceSession), destination = text(selfID);
        if (!identifier(source) || !identifier(destination) || !selfIdentifier(selfID) ||
            destination != text(YMSelfRevokeAccount()) || source != text(YMSelfRevokeSession(wrap))) {
            note(@"capture-identity-mismatch"); return NO;
        }
        job->accountObject = call<uintptr_t (*)()>(job->f.account)();
        if (!job->accountObject) { note(@"capture-account-missing"); return NO; }
        job->accountID = destination; job->destination = destination;
        job->own = YMIsOwnRevokeWrap(wrap);
        if (!captureWrapVoice(*job, wrap, source)) return NO;
        job->expires = Clock::now() + std::chrono::seconds(60);
        if (!current(*job) || source != text(YMSelfRevokeSession(wrap))) { note(@"capture-gate-closed"); return NO; }
        if (!reserve(*job)) { note(@"voice-fused-or-busy"); return NO; }
        dispatch_async(dispatch_get_main_queue(), ^{ launch(job); });
        return YES;
    } catch (...) { note(@"capture-exception"); return NO; } }
    @catch (NSException *) { note(@"capture-objc-exception"); return NO; } }
}

#else
BOOL YMForwardVoiceToSelf(uintptr_t, NSString *, NSString *) { return NO; }
#endif

#import "LocalNoticePlacement.h"
#import "LocalNoticeAnchor.h"
#import "LocalNoticeCursor.h"
#import "RevokePatch.h"
#import "SelfRevokePatch.h"
#import "WeChatCompatibility.h"
#include <atomic>
#include <map>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if defined(__aarch64__)
namespace localNotices {
static std::atomic_bool installed{false};
static bool v420 = false;
static uintptr_t versioned(uintptr_t old, uintptr_t newer) { return v420 ? newer : old; }
template<class F> F native(uintptr_t address) { return reinterpret_cast<F>(YMRuntimeAddress(address)); }
template<class T> T &field(void *p, size_t offset) {
    return *reinterpret_cast<T *>(static_cast<uint8_t *>(p) + offset);
}
template<class T> const T &field(const void *p, size_t offset) {
    return *reinterpret_cast<const T *>(static_cast<const uint8_t *>(p) + offset);
}
static NSString *text(const void *p, size_t offset) {
    const auto &s = field<std::string>(p, offset);
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}
// Native vectors must retain their version-specific element stride.
template<size_t Size> struct NativeData {
    alignas(16) uint8_t bytes[Size];
    explicit NativeData(const void *other) { native<void (*)(void *, const void *)>(Size == 0x350 ? 0x399694 : 0x2e0e10)(this, other); }
    NativeData(const NativeData &other) : NativeData(other.bytes) {}
    ~NativeData() { native<void (*)(void *)>(Size == 0x350 ? 0x39a888 : 0x2e1ff8)(this); }
};
using Models = std::vector<std::shared_ptr<void>>;
using Data = NativeData<0x340>;
using Messages = std::vector<Data>;
using Messages420 = std::vector<NativeData<0x350>>;
static_assert(sizeof(NativeData<0x350>) == 0x350);
using Builder = Models (*)(void *, const void *);
static_assert(sizeof(Data) == 0x340 && sizeof(Models) == 24 && sizeof(std::shared_ptr<void>) == 16);

static NSDictionary *anchor(const void *data, NSString *account) {
    if (field<uint32_t>(data, 8) != 10000 || field<uint64_t>(data, 0x90)) return nil;
    NSString *xml = text(data, versioned(0xb0, 0xb8)), *session = text(data, 0x58);
    NSDictionary *record = YMResolveLocalNoticeAnchor(xml, account, session, 10000, 0);
    if (!record) return nil;
    const auto localID = field<uint32_t>(data, 0x74);
    const auto seconds = field<uint32_t>(data, versioned(0xa0, 0xa8));
    const auto sequence = field<uint64_t>(data, versioned(0x98, 0xa0));
    if (!localID || !seconds || !sequence) return nil;
    return record;
}

static void *castModel(const std::shared_ptr<void> &model, uintptr_t target) {
    if (!model) return nullptr;
    return native<void *(*)(void *, void *, void *, ptrdiff_t)>(versioned(0x63f23f4, 0x72b0e58))(model.get(),
        reinterpret_cast<void *>(YMRuntimeAddress(versioned(0x8b9b0a8, 0x9d7b498))),
        reinterpret_cast<void *>(YMRuntimeAddress(target)), 0);
}
static const void *modelData(const std::shared_ptr<void> &model) {
    // 日期头等行没有 MessageData；与原生列表一致，先通过 MessageModel RTTI。
    void *message = castModel(model, versioned(0x8b9bac0, 0x9d7bee0));
    return message ? native<const void *(*)(void *)>(versioned(0x5143a8, 0x62e248))(message) : nullptr;
}

static void publish(void *context, void *event) {
    void *signal = field<void *>(context, versioned(0x1d0, 0x1f8));
    if (!signal) return;
    // 本次通知没有取消登记；同步锁住原生 subscriber，不跨队列保存 Context。
    auto subscriber = field<std::weak_ptr<void>>(signal, 8).lock();
    if (!subscriber) return;
    auto table = *reinterpret_cast<uintptr_t **>(subscriber.get());
    reinterpret_cast<void (*)(void *, const void *)>(table[0x18 / 8])(subscriber.get(), event);
}
}

// C 名称仅供汇编 trampoline 定位；返回值刻意保留原生 C++ vector 的 x8 ABI。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreturn-type-c-linkage"
extern "C" {
localNotices::Models YMLocalNoticeOriginalFull(void *, const void *);
localNotices::Models YMLocalNoticeOriginalPrevious(void *, const void *);
localNotices::Models YMLocalNoticeOriginalNext(void *, const void *);
localNotices::Models YMLocalNoticeOriginalPlain(void *, const void *);
bool YMLocalNoticeOriginalLate(void *, const void *, void *);
uintptr_t YMLocalNoticeVersion420 = 0;
uintptr_t YMLocalNoticeFullContinue = 0, YMLocalNoticePreviousContinue = 0,
    YMLocalNoticeNextContinue = 0, YMLocalNoticePlainContinue = 0, YMLocalNoticeLateContinue = 0;
}
#pragma clang diagnostic pop

namespace localNotices {
template<class NativeMessages> static Models buildOne(void *context, const void *data) {
    NativeMessages one; one.emplace_back(data);
    return YMLocalNoticeOriginalPlain(context, &one);
}
static bool insert(void *context, const void *data, void *event, NSDictionary *record, NSString *account) {
    auto &models = field<Models>(context, versioned(0x68, 0x80));
    size_t position = models.size();
    bool found = false;
    const uint64_t originalID = strtoull([record[@"originalServerID"] UTF8String], nullptr, 10);
    const uint32_t localID = field<uint32_t>(data, 0x74);
    // 跨页自然加载后，提示可能已在其他位置；重复通知不能再创建第二行。
    for (const auto &model : models) {
        const void *candidate = modelData(model);
        if (candidate && field<uint32_t>(candidate, 0x74) == localID &&
            [anchor(candidate, account)[@"token"] isEqual:record[@"token"]]) return true;
    }
    auto matches = [&](const std::shared_ptr<void> &model) {
        const void *candidate = modelData(model);
        return candidate && field<uint64_t>(candidate, 0x90) == originalID &&
            [text(candidate, 0x58) isEqual:record[@"session"]];
    };
    auto locate = [&] {
        for (size_t i = 0; i < models.size(); ++i)
            if (matches(models[i])) { position = i + 1; return true; }
        return false;
    };
    found = locate();
    if (!found) {
        std::shared_ptr<void> group;
        for (const auto &model : models) {
            void *folded = castModel(model, versioned(0x8ba72e0, 0x9d88568));
            if (!folded) continue;
            const auto *children = native<const Models *(*)(void *)>(versioned(0x50c8a4, 0x62670c))(folded);
            for (const auto &child : *children) if (matches(child)) { group = {model, folded}; break; }
            if (group) break;
        }
        if (group) {
            // 目标消息被原生折叠时，仅展开该组，再按真实消息 ID 重新定位。
            native<void (*)(void *)>(versioned(0x5bce88, 0x6de814))(group.get());
            found = locate();
        }
    }
    if (!found) return false;
    // 同一原消息的多条提示按真实本地 ID 稳定排列，不与其他消息的时间戳比较。
    while (position < models.size()) {
        const void *candidate = modelData(models[position]);
        NSDictionary *other = candidate ? anchor(candidate, account) : nil;
        if (!other || ![other[@"originalServerID"] isEqual:record[@"originalServerID"]] ||
            ![other[@"session"] isEqual:record[@"session"]]) break;
        const uint32_t otherID = field<uint32_t>(candidate, 0x74);
        if (otherID == localID) return true;
        if (otherID > localID) break;
        ++position;
    }
    auto added = v420 ? buildOne<Messages420>(context, data) : buildOne<Messages>(context, data);
    if (added.empty() || position > UINT32_MAX || added.size() > UINT32_MAX - position) return false;
    auto &indices = field<std::vector<uint32_t>>(event, versioned(0x40, 0x50));
    indices.clear();
    indices.reserve(added.size());
    models.reserve(models.size() + added.size());
    for (size_t i = 0; i < added.size(); ++i) indices.push_back(uint32_t(position + i));
    models.insert(models.begin() + position, added.begin(), added.end());
    field<uint8_t>(event, versioned(0x30, 0x40)) = 1;
    field<uint8_t>(event, versioned(0x58, 0x68)) = 1;
    return true;
}

template<class NativeMessages> static Models build(void *context, const NativeMessages *input, Builder original) {
    using NativeMessage = typename NativeMessages::value_type;
    if (!installed.load() || !input || input->empty()) return original(context, input);
    NSString *account = YMSelfRevokeAccount();
    using SourceKey = std::pair<std::string, uint64_t>;
    std::map<SourceKey, size_t> sources;
    for (size_t i = 0; i < input->size(); ++i) {
        const auto &data = (*input)[i];
        if (auto server = field<uint64_t>(data.bytes, 0x90))
            sources.emplace(SourceKey{field<std::string>(data.bytes, 0x58), server}, i);
    }
    std::map<size_t, std::map<uint32_t, const NativeMessage *>> after;
    std::vector<bool> moved(input->size(), false);
    for (size_t i = 0; i < input->size(); ++i) {
        const auto &data = (*input)[i];
        NSDictionary *record = anchor(data.bytes, account);
        if (!record) continue;
        auto source = sources.find({[record[@"session"] UTF8String],
            strtoull([record[@"originalServerID"] UTF8String], nullptr, 10)});
        // 仅整理本次输入的同一批消息；原消息不在其中时保留提示原位置，不跨页查找或重排。
        if (source == sources.end()) continue;
        after[source->second].emplace(field<uint32_t>(data.bytes, 0x74), &data);
        moved[i] = true;
    }
    if (after.empty()) return original(context, input);
    NativeMessages ordered;
    ordered.reserve(input->size());
    for (size_t i = 0; i < input->size(); ++i) {
        if (moved[i]) continue;
        ordered.emplace_back((*input)[i]);
        auto found = after.find(i);
        if (found != after.end())
            for (const auto &notice : found->second) ordered.emplace_back(*notice.second);
    }
    // 将排好顺序的 Data 交给微信统一构建消息行、日期头及折叠组。
    return original(context, &ordered);
}
static Models buildForVersion(void *context, const void *input, Builder original) {
    return v420 ? build(context, static_cast<const Messages420 *>(input), original)
                : build(context, static_cast<const Messages *>(input), original);
}
}

localNotices::Models YMLocalNoticeFull(void *context, const void *data) {
    return localNotices::buildForVersion(context, data, YMLocalNoticeOriginalFull);
}
localNotices::Models YMLocalNoticePrevious(void *context, const void *data) {
    return localNotices::buildForVersion(context, data, YMLocalNoticeOriginalPrevious);
}
localNotices::Models YMLocalNoticeNext(void *context, const void *data) {
    return localNotices::buildForVersion(context, data, YMLocalNoticeOriginalNext);
}
localNotices::Models YMLocalNoticePlain(void *context, const void *data) {
    return localNotices::buildForVersion(context, data, YMLocalNoticeOriginalPlain);
}
extern "C" bool YMLocalNoticeLate(void *context, const void *data, void *event) {
    using namespace localNotices;
    if (!installed.load()) return YMLocalNoticeOriginalLate(context, data, event);
    NSDictionary *record = nil;
    @try { try {
        NSString *account = YMSelfRevokeAccount();
        record = anchor(data, account);
        if (!record) return YMLocalNoticeOriginalLate(context, data, event);
        field<uint8_t>(event, versioned(0x30, 0x40)) = 0;
        if (!NSThread.isMainThread || !insert(context, data, event, record, account))
            return YMLocalNoticeOriginalLate(context, data, event);
        publish(context, event);
        return true;
    } catch (...) {} } @catch (NSException *) {}
    // 发布失败可能发生在插入完成之后，不能再次调用原生导致重复插入。
    return record ? true : YMLocalNoticeOriginalLate(context, data, event);
}

BOOL YMLocalNoticePlacementAvailable(void) { return localNotices::installed.load(); }
#ifndef YM_LOCAL_NOTICE_PLACEMENT_TEST
__asm__(
    ".text\n.align 2\n.globl _YMLocalNoticeOriginalFull\n_YMLocalNoticeOriginalFull:\n"
    "adrp x16, _YMLocalNoticeVersion420@PAGE\nldr x16, [x16, _YMLocalNoticeVersion420@PAGEOFF]\ncbnz x16, 1f\n"
    "sub sp, sp, #0xb0\nstp x28, x27, [sp, #0x50]\nstp x26, x25, [sp, #0x60]\nstp x24, x23, [sp, #0x70]\n"
    "adrp x16, _YMLocalNoticeFullContinue@PAGE\nldr x16, [x16, _YMLocalNoticeFullContinue@PAGEOFF]\nbr x16\n"
    "1:\nsub sp, sp, #0xd0\nstp x28, x27, [sp, #0x70]\nstp x26, x25, [sp, #0x80]\nstp x24, x23, [sp, #0x90]\n"
    "adrp x16, _YMLocalNoticeFullContinue@PAGE\nldr x16, [x16, _YMLocalNoticeFullContinue@PAGEOFF]\nbr x16\n"
    ".align 2\n.globl _YMLocalNoticeOriginalPrevious\n_YMLocalNoticeOriginalPrevious:\n"
    "adrp x16, _YMLocalNoticeVersion420@PAGE\nldr x16, [x16, _YMLocalNoticeVersion420@PAGEOFF]\ncbnz x16, 1f\n"
    "sub sp, sp, #0xd0\nstp x28, x27, [sp, #0x70]\nstp x26, x25, [sp, #0x80]\nstp x24, x23, [sp, #0x90]\n"
    "adrp x16, _YMLocalNoticePreviousContinue@PAGE\nldr x16, [x16, _YMLocalNoticePreviousContinue@PAGEOFF]\nbr x16\n"
    "1:\nsub sp, sp, #0x110\nstp x28, x27, [sp, #0xb0]\nstp x26, x25, [sp, #0xc0]\nstp x24, x23, [sp, #0xd0]\n"
    "adrp x16, _YMLocalNoticePreviousContinue@PAGE\nldr x16, [x16, _YMLocalNoticePreviousContinue@PAGEOFF]\nbr x16\n"
    ".align 2\n.globl _YMLocalNoticeOriginalNext\n_YMLocalNoticeOriginalNext:\n"
    "adrp x16, _YMLocalNoticeVersion420@PAGE\nldr x16, [x16, _YMLocalNoticeVersion420@PAGEOFF]\ncbnz x16, 1f\n"
    "sub sp, sp, #0xe0\nstp x28, x27, [sp, #0x80]\nstp x26, x25, [sp, #0x90]\nstp x24, x23, [sp, #0xa0]\n"
    "adrp x16, _YMLocalNoticeNextContinue@PAGE\nldr x16, [x16, _YMLocalNoticeNextContinue@PAGEOFF]\nbr x16\n"
    "1:\nsub sp, sp, #0x120\nstp x28, x27, [sp, #0xc0]\nstp x26, x25, [sp, #0xd0]\nstp x24, x23, [sp, #0xe0]\n"
    "adrp x16, _YMLocalNoticeNextContinue@PAGE\nldr x16, [x16, _YMLocalNoticeNextContinue@PAGEOFF]\nbr x16\n"
    ".align 2\n.globl _YMLocalNoticeOriginalPlain\n_YMLocalNoticeOriginalPlain:\n"
    "sub sp, sp, #0x90\nstp x28, x27, [sp, #0x30]\nstp x26, x25, [sp, #0x40]\nstp x24, x23, [sp, #0x50]\n"
    "adrp x16, _YMLocalNoticePlainContinue@PAGE\nldr x16, [x16, _YMLocalNoticePlainContinue@PAGEOFF]\nbr x16\n"
    ".align 2\n.globl _YMLocalNoticeOriginalLate\n_YMLocalNoticeOriginalLate:\n"
    "stp x28, x27, [sp, #-0x60]!\nstp x26, x25, [sp, #0x10]\nstp x24, x23, [sp, #0x20]\nstp x22, x21, [sp, #0x30]\n"
    "adrp x16, _YMLocalNoticeLateContinue@PAGE\nldr x16, [x16, _YMLocalNoticeLateContinue@PAGEOFF]\nbr x16\n"
);
#endif

// 显示重排可能改变列表首尾；位置调整和查询边界适配均就绪后才启用。
void YMInstallLocalNoticePlacement(void) {
    using namespace localNotices;
    static std::mutex installMutex;
    std::lock_guard<std::mutex> lock(installMutex);
    if (installed.load()) return;
    const bool newer = YMMatchesWeChat270353Dylib();
    if (!newer && !YMMatchesWeChatLegacyNativeDylib()) return;
    struct Entry { uintptr_t address; uint8_t bytes[16]; };
    static const Entry oldEntries[] = {
        {0x7cb168, {0xff,0xc3,0x02,0xd1,0xfc,0x6f,0x05,0xa9,0xfa,0x67,0x06,0xa9,0xf8,0x5f,0x07,0xa9}},
        {0x7cb574, {0xff,0x43,0x03,0xd1,0xfc,0x6f,0x07,0xa9,0xfa,0x67,0x08,0xa9,0xf8,0x5f,0x09,0xa9}},
        {0x7cb984, {0xff,0x83,0x03,0xd1,0xfc,0x6f,0x08,0xa9,0xfa,0x67,0x09,0xa9,0xf8,0x5f,0x0a,0xa9}},
        {0x7cc080, {0xff,0x43,0x02,0xd1,0xfc,0x6f,0x03,0xa9,0xfa,0x67,0x04,0xa9,0xf8,0x5f,0x05,0xa9}},
        {0x7d3be4, {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
        {0x2e0e10, {0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}},
        {0x2e1ff8, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf3,0x03,0x00,0xaa}},
        {0x63f23f4, {0xf0,0x36,0x01,0x90,0x10,0xb2,0x45,0xf9,0x00,0x02,0x1f,0xd6,0xf0,0x36,0x01,0x90}},
        {0x5143a8, {0x00,0x80,0x04,0x91,0xc0,0x03,0x5f,0xd6,0xff,0x03,0x02,0xd1,0xf6,0x57,0x05,0xa9}},
        {0x50c8a4, {0x00,0x60,0x04,0x91,0xc0,0x03,0x5f,0xd6,0x09,0xa8,0x51,0xa9,0x3f,0x01,0x0a,0xeb}},
        {0x5bce88, {0xff,0x43,0x01,0xd1,0xf6,0x57,0x02,0xa9,0xf4,0x4f,0x03,0xa9,0xfd,0x7b,0x04,0xa9}},
    };
    static const Entry newEntries[] = {
        {0x980f10, {0xff,0x43,0x03,0xd1,0xfc,0x6f,0x07,0xa9,0xfa,0x67,0x08,0xa9,0xf8,0x5f,0x09,0xa9}},
        {0x981408, {0xff,0x43,0x04,0xd1,0xfc,0x6f,0x0b,0xa9,0xfa,0x67,0x0c,0xa9,0xf8,0x5f,0x0d,0xa9}},
        {0x981904, {0xff,0x83,0x04,0xd1,0xfc,0x6f,0x0c,0xa9,0xfa,0x67,0x0d,0xa9,0xf8,0x5f,0x0e,0xa9}},
        {0x982b7c, {0xff,0x43,0x02,0xd1,0xfc,0x6f,0x03,0xa9,0xfa,0x67,0x04,0xa9,0xf8,0x5f,0x05,0xa9}},
        {0x98f42c, {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
        {0x399694, {0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}},
        {0x39a888, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf3,0x03,0x00,0xaa}},
        {0x72b0e58, {0x70,0x4e,0x01,0xd0,0x10,0x02,0x46,0xf9,0x00,0x02,0x1f,0xd6,0x70,0x4e,0x01,0xd0}},
        {0x62e248, {0x00,0x80,0x04,0x91,0xc0,0x03,0x5f,0xd6,0xff,0x03,0x02,0xd1,0xf6,0x57,0x05,0xa9}},
        {0x62670c, {0x00,0x60,0x04,0x91,0xc0,0x03,0x5f,0xd6,0x09,0xa8,0x51,0xa9,0x3f,0x01,0x0a,0xeb}},
        {0x6de814, {0xff,0x43,0x01,0xd1,0xf6,0x57,0x02,0xa9,0xf4,0x4f,0x03,0xa9,0xfd,0x7b,0x04,0xa9}},
    };
    const auto &entries = newer ? newEntries : oldEntries;
    static bool patched[5]{};
    const uintptr_t hooks[] = {reinterpret_cast<uintptr_t>(&YMLocalNoticeFull),
        reinterpret_cast<uintptr_t>(&YMLocalNoticePrevious), reinterpret_cast<uintptr_t>(&YMLocalNoticeNext),
        reinterpret_cast<uintptr_t>(&YMLocalNoticePlain), reinterpret_cast<uintptr_t>(&YMLocalNoticeLate)};
    uintptr_t *continuations[] = {&YMLocalNoticeFullContinue, &YMLocalNoticePreviousContinue,
        &YMLocalNoticeNextContinue, &YMLocalNoticePlainContinue, &YMLocalNoticeLateContinue};
    for (size_t i = 0; i < sizeof entries / sizeof *entries; ++i) {
        if (i < 5 && patched[i]) continue;
        if (memcmp(reinterpret_cast<const void *>(YMRuntimeAddress(entries[i].address)), entries[i].bytes, 16)) return;
    }
    if (!YMInstallLocalNoticeCursorHooks()) return;
    v420 = newer;
    YMLocalNoticeVersion420 = newer;
    for (size_t i = 0; i < 5; ++i) {
        if (patched[i]) continue;
        *continuations[i] = YMRuntimeAddress(entries[i].address + 16);
        patched[i] = YMPatchARM64AbsoluteJump(YMRuntimeAddress(entries[i].address), hooks[i], "anchored local notices");
        // 尚未全部安装时，已安装入口仅调用原生 trampoline，允许后续初始化重试。
        if (!patched[i]) return;
    }
    installed.store(true);
    YMLog(@"[LocalNotice] message-ID placement enabled");
}
#else
void YMInstallLocalNoticePlacement(void) {}
BOOL YMLocalNoticePlacementAvailable(void) { return NO; }
#endif

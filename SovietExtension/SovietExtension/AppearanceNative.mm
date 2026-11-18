#import "AppearanceNative.h"
#import "WeChatCompatibility.h"
#import "RevokePatch.h"
#import "ForwardToSelfPatch.h"
#include "GroupRoleNative.h"
#include <functional>
#include <limits>
#include <memory>
#include <optional>

namespace {
using ym::group_info::native_source::bytes;
using ym::group_info::native_source::read;
template<class F> F native(uintptr_t address) {
    return reinterpret_cast<F>(YMRuntimeAddress(address));
}
struct Entry { uintptr_t address; uint8_t bytes[16]; };
template<size_t N> bool matchesEntries(const Entry (&entries)[N]) {
    if (!YMMatchesWeChat270353Dylib()) return false;
    for (const auto &entry : entries) {
        uint8_t actual[16];
        if (!bytes(YMRuntimeAddress(entry.address), actual, sizeof actual) ||
            memcmp(actual, entry.bytes, sizeof actual)) return false;
    }
    return true;
}
struct PickerBuilder {
    alignas(8) uint8_t storage[0xd8];
    PickerBuilder() { native<void (*)(void *)>(0x18c6b0c)(this); }
    ~PickerBuilder() { native<void (*)(void *)>(0x6451f8)(this); }
    PickerBuilder(const PickerBuilder &) = delete;
    PickerBuilder &operator=(const PickerBuilder &) = delete;
};
struct Recipient;
using Chosen = std::function<void(const Recipient &)>;
static_assert(sizeof(PickerBuilder) == 0xd8 && sizeof(Chosen) == 0x20);

bool pickerABI() {
        static const Entry entries270353[] = {
            {0x18c6b0c, {0x00,0xe4,0x00,0x6f,0x00,0x80,0x00,0xad,0x00,0x00,0x80,0x3d,0x08,0xf0,0xa7,0x52}}, // builder constructor
            {0x18c6b4c, {0xe8,0x03,0x00,0xaa,0x1f,0x0d,0x0c,0xf8,0x08,0x5c,0x00,0xf9,0x1f,0x40,0x03,0x39}}, // builder tail tree and flag
            {0x6451f8, {0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}}, // builder destructor
            {0x18c73c4, {0xff,0x43,0x01,0xd1,0xf4,0x4f,0x03,0xa9,0xfd,0x7b,0x04,0xa9,0xfd,0x03,0x01,0x91}}, // chosen callback copy
            {0x18c7430, {0xe0,0x23,0x00,0x91,0x61,0xa2,0x01,0x91,0x79,0x05,0x00,0x94,0xe0,0x13,0x40,0xf9}}, // callback destination +68
            {0x18c7574, {0xfc,0x6f,0xbc,0xa9,0xf6,0x57,0x01,0xa9,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9}}, // build dialog
            {0x18c76d0, {0x85,0x42,0x00,0x91,0xe0,0x03,0x13,0xaa,0xe1,0x03,0x15,0xaa,0x73,0x4b,0xff,0x97}}, // dialog constructor call with copied callbacks
            {0x18b9044, {0xff,0x83,0x00,0xd1,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xff,0x07,0x00,0xf9}}, // show dialog
            {0x18b9054, {0x08,0x00,0x40,0xf9,0x08,0xe9,0x40,0xf9,0xe1,0x23,0x00,0x91,0x00,0x01,0x3f,0xd6}}, // show virtual slot +1d0
            {0x1810240, {0xff,0x43,0x01,0xd1,0xf6,0x57,0x02,0xa9,0xf4,0x4f,0x03,0xa9,0xfd,0x7b,0x04,0xa9}}, // borrowed recipient to owned set
            {0x189a6a4, {0xfd,0x7b,0xbf,0xa9,0xfd,0x03,0x00,0x91,0x84,0xff,0xff,0x97,0x01,0xa6,0x80,0x52}}, // unshown dialog deleting destructor
        };
    return matchesEntries(entries270353);
}
}

BOOL YMAppearanceChooseConversations(void (^completion)(NSArray<NSString *> *)) {
    if (!completion || !NSThread.isMainThread || !pickerABI()) return NO;
    @try { try {
        PickerBuilder builder;
        Chosen chosen = [completion](const Recipient &recipient) {
            @autoreleasepool { @try { try {
                auto targets = native<std::set<std::string> (*)(const Recipient *, int)>(0x1810240)(&recipient, 2);
                NSMutableArray<NSString *> *ids = [NSMutableArray new];
                for (const auto &target : targets) {
                    NSString *value = [[NSString alloc] initWithBytes:target.data()
                        length:target.size() encoding:NSUTF8StringEncoding];
                    if (value.length) [ids addObject:value];
                }
                completion(ids);
            } catch (...) { completion(@[]); } } @catch (NSException *) { completion(@[]); } }
        };
        native<void (*)(void *, Chosen *)>(0x18c73c4)(&builder, &chosen);
        uintptr_t dialog = native<uintptr_t (*)(void *)>(0x18c7574)(&builder);
        if (!dialog) return NO;
        native<void (*)(uintptr_t)>(0x18b9044)(dialog);
        return YES;
    } catch (...) { return NO; } } @catch (NSException *) { return NO; }
}

NSString *YMAppearanceAccount(void) {
    if (!NSThread.isMainThread) return nil;
    static const Entry entries[] = {
        {0x47990b4, {0x08,0xf1,0x02,0x90,0x00,0x35,0x45,0xf9,0xc0,0x03,0x5f,0xd6,0xff,0xc3,0x00,0xd1}},
    };
    if (!matchesEntries(entries)) return nil;
    uintptr_t object = native<uintptr_t (*)()>(0x47990b4)();
    uintptr_t table = 0, getter = 0;
    if (!read(object, table) || !table || !read(table + 0x28, getter) || !getter) return nil;
    const auto *value = reinterpret_cast<const std::string *(*)(uintptr_t)>(getter)(object);
    std::string account;
    if (!ym::group_info::native_source::text(reinterpret_cast<uintptr_t>(value), 128, account)) return nil;
    return [[NSString alloc] initWithBytes:account.data() length:account.size() encoding:NSUTF8StringEncoding];
}

NSString *YMAppearanceSessionName(NSString *session) {
    NSString *room = YMQueryRoomName(session);
    return room.length ? room : YMResolveMemberDisplayName(session, nil, nil, nil);
}
BOOL YMAppearanceValidSession(NSString *value) {
    return value.length && value.length <= 128 &&
        [value rangeOfString:@"^[A-Za-z0-9_-]+(@chatroom)?$" options:NSRegularExpressionSearch].location != NSNotFound &&
        ![value hasPrefix:@"gh_"] && ![@[@"filehelper", @"newsapp", @"fmessage", @"weixin"] containsObject:value];
}
bool YMReadAppearanceSession(uintptr_t p, std::string &out) noexcept {
    try {
        // 4.2.0.17 consumes this shape at 0x851e38: ptr/length plus a
        // signed inline-length marker at +0x17.
        if (!p || p > std::numeric_limits<uintptr_t>::max() - 0x18) return false;
        uintptr_t data = 0;
        uint32_t length = 0;
        int8_t marker = 0;
        if (!read(p, data) || !read(p + 8, length) ||
            !read(p + 0x17, marker)) return false;
        const size_t size = marker < 0 ? static_cast<size_t>(length)
                                       : static_cast<size_t>(static_cast<uint8_t>(marker));
        if (size > 128 || (marker >= 0 && size > 23)) return false;
        const uintptr_t storage = marker < 0 ? data : p;
        if (!storage) return false;
        out.resize(size);
        return size == 0 || bytes(storage, out.data(), size);
    } catch (...) { return false; }
}

bool YMCopyCachedGroupRoles(const std::string &group, const std::string &self,
                                   ym::group_info::NativeRoomSources &out) {
    out = {};
    if (!NSThread.isMainThread || !ym::group_info::native_source::groupID(group) ||
        !ym::group_info::profileMemberID(self)) return false;
    uintptr_t functions[6] = {};
    static const Entry entries[] = {
        {0x479a5e8, {0xff,0xc3,0x00,0xd1,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}},
        {0x24dc4dc, {0xff,0x03,0x01,0xd1,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9,0xfd,0xc3,0x00,0x91}},
        {0x462a490, {0xff,0x03,0x01,0xd1,0xf6,0x57,0x01,0xa9,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9}},
        {0x462de64, {0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}},
        {0x2aed2b4, {0xff,0x03,0x01,0xd1,0xf6,0x57,0x01,0xa9,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9}},
    };
    if (!matchesEntries(entries)) return false;
    functions[0] = YMRuntimeAddress(entries[0].address);
    functions[1] = YMRuntimeAddress(entries[1].address);
    functions[2] = YMRuntimeAddress(entries[2].address);
    functions[4] = YMRuntimeAddress(entries[3].address);
    functions[5] = YMRuntimeAddress(entries[4].address);
    using Shared = std::shared_ptr<void>;
    using Optional = std::optional<Shared>;
    using GetService = Shared (*)(void *);
    auto context = reinterpret_cast<Shared (*)()>(functions[0])();
    if (!context) return false;
    uintptr_t vtable = 0, getter = 0;
    if (!read(reinterpret_cast<uintptr_t>(context.get()), vtable) || !vtable ||
        !read(vtable + 0x38, getter) || !getter) return false;
    auto registry = reinterpret_cast<GetService>(getter)(context.get());
    if (!registry) return false;
    const std::string cacheName = "ChatroomCache";
    auto cache = reinterpret_cast<Shared (*)(void *, const std::string *)>(functions[4])(registry.get(), &cacheName);
    if (!cache) return false;
    auto room = reinterpret_cast<Optional (*)(void *, const std::string *)>(functions[5])(
        static_cast<uint8_t *>(cache.get()) + 0x30, &group);
    if (!room || !*room) return false;
    if (!ym::group_info::native_source::copyRoom(reinterpret_cast<uintptr_t>(room->get()), group, self, out))
        return false;
    auto contactCache = reinterpret_cast<GetService>(functions[1])(registry.get());
    if (!contactCache) return true;
    auto contact = reinterpret_cast<Shared (*)(void *, const std::string *)>(functions[2])(
        contactCache.get(), &group);
    if (contact && out.admins.empty())
        ym::group_info::native_source::copyGroupAdmins(reinterpret_cast<uintptr_t>(contact.get()), out);
    return true;
}


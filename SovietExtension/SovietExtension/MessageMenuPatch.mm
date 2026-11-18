// 消息右键菜单：媒体操作沿用原生区域，“+1”独立分组放在撤回/删除组前。
// 此处统一管理Qt Hook、消息快照和菜单布局；业务回调由Repeat/Media模块提供。
#import "RevokePatch.h"
#import "WeChatCompatibility.h"
#include <mach/mach_vm.h>
#import "ForwardToSelfPatch.h"
#import "MessageMenuPatch.h"
#import "MessageRepeatPatch.h"
#import "MessageMediaActions.h"
#import "ForwardNoticeNavigation.h"
#import <AppKit/AppKit.h>
#include <algorithm>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#if defined(__aarch64__)
// 两个 ARM 版本分别校验菜单入口、模型和原生快照布局。
static uintptr_t YMMenuAddress(uintptr_t oldAddress, uintptr_t currentAddress) {
    return YMRuntimeAddress(YMMatchesWeChat270353Dylib() ? currentAddress : oldAddress);
}
static bool YMMessageMenuInstalled = false;

YMMessageSnapshot::YMMessageSnapshot(uintptr_t source) {
    ((void (*)(void *, uintptr_t))YMMenuAddress(0x2e0e10, 0x399694))(this, source);
}
YMMessageSnapshot::~YMMessageSnapshot() {
    ((void (*)(void *))YMMenuAddress(0x2e1ff8, 0x39a888))(this);
}

struct YMMessageMenuQString {
    // 该版本 QString 是 8 字节数据句柄；用微信自己的 UTF-8 构造和析构，不能伪造布局。
    uintptr_t data;
    explicit YMMessageMenuQString(const char *text)
        : data(((uintptr_t (*)(const char *, int))YMMenuAddress(0x61bddf4, 0x7069338))(text, (int)strlen(text))) {}
    ~YMMessageMenuQString() { ((void (*)(void *))YMMenuAddress(0xab660, 0xadba4))(this); }
};

static bool YMMessageMenuRead(uintptr_t address, void *out, size_t size) {
    mach_vm_size_t copied = 0;
    return address && mach_vm_read_overwrite(mach_task_self(), address, size,
        (mach_vm_address_t)out, &copied) == KERN_SUCCESS && copied == size;
}
static uintptr_t YMMessageMenuData(uintptr_t model, std::shared_ptr<void> *coverModel = nullptr) {
    if (coverModel) coverModel->reset();
    if (!model) return 0;
    const uintptr_t table = YMMenuAddress(0x8e20548, 0xa006478);
    // Only a verified inline MessageData can supply single-message actions.
    for (uintptr_t offset : {uintptr_t(0x120), uintptr_t(0x130)}) {
        uintptr_t candidate = 0;
        if (YMMessageMenuRead(model + offset, &candidate, sizeof(candidate)) && candidate == table) return model + offset;
    }
    uintptr_t modelTable = 0;
    int32_t index = -1;
    if (!coverModel || !YMMatchesWeChat270353Dylib() ||
        !YMMessageMenuRead(model, &modelTable, sizeof(modelTable)) || modelTable != YMRuntimeAddress(0x9d88ea0) ||
        !YMMessageMenuRead(model + 0x1d4, &index, sizeof(index)) || index < 0) return 0;
    try {
        // The cover index addresses the native filtered image list, not raw children with system rows.
        using Models = std::vector<std::shared_ptr<void>>;
        static_assert(sizeof(Models) == 24 && sizeof(std::shared_ptr<void>) == 16);
        const auto images = reinterpret_cast<Models (*)(uintptr_t)>(YMRuntimeAddress(0x6f0000))(model);
        if (static_cast<size_t>(index) >= images.size()) return 0;
        const auto &selected = images[index];
        const uintptr_t source = YMMessageMenuData(reinterpret_cast<uintptr_t>(selected.get()));
        uint32_t type = 0;
        if (!source || !YMMessageMenuRead(source + 8, &type, sizeof(type)) || (type != 3 && type != 43)) return 0;
        *coverModel = selected;
        return source;
    } catch (...) { return 0; }
}
struct YMMessageMenuItem {
    // Qt 按原生对象大小执行 sized delete；两版须分别分配，不能用最大容量冒充。
    void *storage = nullptr;
    YMMessageMenuItem(const YMMessageMenuQString &title, uintptr_t style) {
        storage = ::operator new(YMMatchesWeChat270353Dylib() ? 0x3e8 : 0x3c0);
        try {
            ((void (*)(void *, const void *, uintptr_t, uintptr_t))YMMenuAddress(0x19e08c8, 0x1fa1c90))(storage, &title, style, 0);
        } catch (...) {
            ::operator delete(storage);
            throw;
        }
    }
    ~YMMessageMenuItem() {
        if (!storage) return;
        ((void (*)(void *))YMMenuAddress(0x19e08cc, 0x1fa1c94))(storage);
        ::operator delete(storage);
    }
    void release() { storage = nullptr; }
};

struct YMMessageMenuConnection {
    uintptr_t data;
    // 非平凡析构保证 arm64 返回句柄走 x8；不可简化为 uintptr_t 返回值。
    // 释放此局部连接句柄不会断开信号，连接及捕获的消息快照由 Qt 管理。
    ~YMMessageMenuConnection() { ((void (*)(void *))YMMenuAddress(0x629d564, 0x7148ac4))(this); }
};

struct YMMessageMenuActions {
    // QWidget::actions() 返回的 QList 句柄。数据头为 ref/alloc/begin/end，指针数组从 +16 开始。
    // begin 可能非零；取得的快照仅用于定位/核对顺序，重排通过原生 insertAction 完成。
    uintptr_t data;
    ~YMMessageMenuActions() { ((void (*)(void *))YMMenuAddress(0x857fbc, 0x20ed94))(this); }
    uintptr_t at(int index) const {
        const auto *bounds = (const int32_t *)(data + 8);
        if (index < 0 || index >= bounds[1] - bounds[0]) return 0;
        return ((const uintptr_t *)(data + 16))[bounds[0] + index];
    }
    uintptr_t last() const {
        const auto *bounds = (const int32_t *)(data + 8);
        return at(bounds[1] - bounds[0] - 1);
    }
};
static_assert(sizeof(YMMessageMenuQString) == 8);
static_assert(sizeof(YMMessageMenuConnection) == 8);
static_assert(sizeof(YMMessageMenuActions) == 8);
static_assert(sizeof(std::function<void()>) == 0x20);

extern "C" uintptr_t YMMessageMenuBuilderContinue;
uintptr_t YMMessageMenuBuilderContinue = 0;
extern "C" void YMMessageMenuOriginalBuilder(uintptr_t model, uintptr_t menu, bool fillNames);

// 被覆盖的四条指令不含 PC 相对寻址；完整重放后跳回原函数，避免反复卸载/安装 Hook 的竞态。
__asm__(
    ".text\n.align 2\n.globl _YMMessageMenuOriginalBuilder\n"
    "_YMMessageMenuOriginalBuilder:\n"
    "stp x28, x27, [sp, #-0x60]!\n"
    "stp x26, x25, [sp, #0x10]\n"
    "stp x24, x23, [sp, #0x20]\n"
    "stp x22, x21, [sp, #0x30]\n"
    "adrp x16, _YMMessageMenuBuilderContinue@PAGE\n"
    "ldr x16, [x16, _YMMessageMenuBuilderContinue@PAGEOFF]\n"
    "br x16\n"
);

__attribute__((noinline))
static void YMMessageMenuBuilder(uintptr_t model, uintptr_t menu, bool fillNames) {
    const bool current = YMMatchesWeChat270353Dylib();
    const size_t entrySize = current ? 0x190 : 0x170;
    const size_t styleOffset = current ? 0x68 : 0x48;
    std::shared_ptr<void> coverModel;
    const uintptr_t source = NSThread.isMainThread ? YMMessageMenuData(model, &coverModel) : 0;
    if (!source) {
        YMMessageMenuOriginalBuilder(model, menu, fillNames);
        return;
    }
    struct Pending {
        std::unique_ptr<YMMessageMenuItem> item;
        std::function<void()> callback;
        bool repeat = false;
    };
    std::vector<Pending> pending;
    std::vector<int32_t> nativeKeys;
    std::vector<uintptr_t> priorActions;
    bool hideRevoke = false;
    {
        try {
            uintptr_t begin = 0, end = 0, vtable = 0;
            memcpy(&begin, (void *)(model + 8), 8);
            memcpy(&end, (void *)(model + 16), 8);
            memcpy(&vtable, (void *)source, 8);
            uint32_t type = 0;
            uint64_t identifier = 0;
            memcpy(&type, (void *)(source + 8), 4);
            memcpy(&identifier, (void *)(source + 0x90), 8);
            const bool validEntries = begin && end > begin && end - begin <= 64 * entrySize &&
                (end - begin) % entrySize == 0 && vtable == YMMenuAddress(0x8e20548, 0xa006478);
            if (validEntries) {
                hideRevoke = YMIsRetainedSelfMessage(source);
                if (auto original = YMForwardNoticeOriginalAction(source)) {
                    YMMessageMenuQString title("定位到原文位置");
                    pending.push_back({std::make_unique<YMMessageMenuItem>(title, begin + styleOffset),
                                       std::move(original), true});
                }
                for (uintptr_t entry = begin; entry < end; entry += entrySize)
                    nativeKeys.push_back(*(const int32_t *)entry);
            }
            // 模型菜单条目跨度为 0x170；首项 +0x48 提供原生样式，消息快照位于 model+0x120。
            // +0x58 是按消息方向解析的原会话；文字/图片/视频/表情包/应用消息共用类型门控。
            if (begin && end > begin && end - begin <= 64 * entrySize && (end - begin) % entrySize == 0 &&
                vtable == YMMenuAddress(0x8e20548, 0xa006478) && identifier &&
                YMForwardSupportsMessageType(type)) {
                const auto &nativeSession = *(const std::string *)(source + 0x58);
                if (!nativeSession.empty() && nativeSession.size() <= 128) {
                    NSString *session = [[NSString alloc] initWithBytes:nativeSession.data()
                                                               length:nativeSession.size() encoding:NSUTF8StringEncoding];
                    if (session.length) {
                        auto message = std::make_shared<YMMessageSnapshot>(source);
                        auto repeat = YMMessageRepeatAction(message, session);
                        YMMessageMenuQString title(coverModel ? "+1（当前封面）" : "+1");
                        pending.push_back({std::make_unique<YMMessageMenuItem>(title, begin + styleOffset), std::move(repeat), true});
                        // 原生entry首4字节为key：0xbbf=Finder，0xbc1=另存为，0xfa3=删除。
                        // 用key去重和定位，不依赖本地化标题。
                        bool hasFinder = false, hasSave = false;
                        for (uintptr_t entry = begin; entry < end; entry += entrySize) {
                            if (*(const uint32_t *)entry == 0xbbf) hasFinder = true;
                            if (*(const uint32_t *)entry == 0xbc1) hasSave = true;
                        }
                        if (!hasFinder) {
                            auto reveal = YMMessageMediaActions::revealAction(message);
                            if (reveal) {
                                YMMessageMenuQString finderTitle(coverModel ? "在「访达」中显示（当前封面）" : "在「访达」中显示");
                                pending.push_back({std::make_unique<YMMessageMenuItem>(finderTitle, begin + styleOffset), std::move(reveal)});
                            }
                        }
                        if (!hasSave) {
                            auto save = YMMessageMediaActions::saveAction(message);
                            if (save) {
                                YMMessageMenuQString saveTitle(coverModel ? "另存为（当前封面）" : "另存为");
                                pending.push_back({std::make_unique<YMMessageMenuItem>(saveTitle, begin + styleOffset), std::move(save)});
                            }
                        }
                        YMLog(@"[MessageMenu] prepared native snapshot and menu item; type=%u", type);
                    }
                }
            }
        } catch (...) {
            YMLog(@"[MessageMenu] preparation failed; keeping native menu");
        }
    }

    // 原构建器在 0x951128..0x951144 销毁模型条目，所以样式复制和消息快照必须提前完成。
    // 返回后只使用自己构造的 item 和 callback，不能再读取 begin/end 指向的旧条目。
    if (!pending.empty() || hideRevoke) {
        auto prior = ((YMMessageMenuActions (*)(uintptr_t))YMMenuAddress(0x5cc1e08, 0x6b6c200))(menu);
        for (int i = 0; uintptr_t action = prior.at(i); ++i) priorActions.push_back(action);
    }
    YMMessageMenuOriginalBuilder(model, menu, fillNames);
    if (pending.empty() && !hideRevoke) return;
    try {
        using GetActions = YMMessageMenuActions (*)(uintptr_t);
        using InsertAction = void (*)(uintptr_t, uintptr_t, uintptr_t);
        auto original = ((GetActions)YMMenuAddress(0x5cc1e08, 0x6b6c200))(menu);
        // 9508e8/951268按有符号key排序，950bac..950bdc在key/1000递增时插分隔符。
        // 构建前只复制key；原条目已析构。数量或原有前缀不符时不猜测动作身份。
        // 映射失败或缺少锚点时追加到末尾；不把任意原生动作当成删除。
        std::sort(nativeKeys.begin(), nativeKeys.end());
        std::vector<int32_t> layout;
        int32_t previousGroup = -1;
        for (int32_t key : nativeKeys) {
            const int32_t group = key / 1000;
            if (previousGroup >= 0 && group > previousGroup) layout.push_back(-1);
            layout.push_back(key);
            previousGroup = group;
        }
        bool matched = original.at((int)(priorActions.size() + layout.size())) == 0;
        for (size_t i = 0; i < priorActions.size(); ++i)
            matched = matched && original.at((int)i) == priorActions[i];
        for (size_t i = 0; i < layout.size(); ++i)
            matched = matched && original.at((int)(priorActions.size() + i)) != 0;
        uintptr_t save = 0, destructive = 0;
        std::vector<uintptr_t> separators;
        if (matched) {
            for (size_t i = 0; i < layout.size(); ++i) {
                uintptr_t action = original.at((int)(priorActions.size() + i));
                if (layout[i] == 0xbc1) save = action;
                if (hideRevoke && (layout[i] == 4001 || layout[i] == 4002)) {
                    ((void (*)(uintptr_t, bool))YMMenuAddress(0x5c916b8, 0x6b3bc48))(action, false);
                    continue;
                }
                // 原生4000组含撤回(4001/4002)、删除(4003)，取首项，不能只锚定删除。
                if (!destructive && layout[i] / 1000 == 4) destructive = action;
                if (layout[i] == -1) separators.push_back(action);
            }
        }
        auto separatorBefore = [&](uintptr_t before) {
            auto current = ((GetActions)YMMenuAddress(0x5cc1e08, 0x6b6c200))(menu);
            uintptr_t previous = 0;
            for (int i = 0; uintptr_t action = current.at(i); ++i) {
                if (action == before) break;
                previous = action;
            }
            if (!previous || std::find(separators.begin(), separators.end(), previous) != separators.end()) return;
            ((void (*)(uintptr_t))YMMenuAddress(0x19dc280, 0x1f9d2b8))(menu);
            auto updated = ((GetActions)YMMenuAddress(0x5cc1e08, 0x6b6c200))(menu);
            if (uintptr_t separator = updated.last()) {
                separators.push_back(separator);
                if (before) ((InsertAction)YMMenuAddress(0x5cc1aec, 0x6b6bee4))(menu, before, separator);
            }
        };
        // 媒体优先放在保存前；无保存时与+1依次放在红字组前，不拆散撤回/删除。
        std::stable_partition(pending.begin(), pending.end(), [](const Pending &entry) { return !entry.repeat; });
        for (auto &entry : pending) {
            uintptr_t action = ((uintptr_t (*)(uintptr_t, void *))YMMenuAddress(0x19dbd20, 0x1f9cd50))(menu, entry.item->storage);
            if (!action) continue;
            entry.item->release(); // 业务项和QAction已由Qt接管。
            using Connect = YMMessageMenuConnection (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, std::function<void()> *, int);
            auto connection = ((Connect)YMMenuAddress(0x9539b8, 0xd37d60))(
                action, YMMenuAddress(0x5c91aa0, 0x6b3c030), 0, action, &entry.callback, 1);
            if (!connection.data) {
                ((void (*)(uintptr_t, bool))YMMenuAddress(0x5c915c4, 0x6b3bb54))(action, false);
                YMLog(@"[MessageMenu] native callback connection failed; action disabled");
            }
            const uintptr_t before = entry.repeat ? destructive : (save ? save : destructive);
            if (before) ((InsertAction)YMMenuAddress(0x5cc1aec, 0x6b6bee4))(menu, before, action);
            if (entry.repeat) {
                separatorBefore(action);
                if (before) separatorBefore(before);
            }
        }
    } catch (...) {
        YMLog(@"[MessageMenu] menu connection failed");
    }
}

void YMInstallMessageMenuPatch(void) {
    if (YMMessageMenuInstalled) return;
    YMMediaForwardAddresses addresses = {};
    // 先复用转发层的版本/Resources 镜像 UUID 校验，再核对菜单辅助函数和调用点指纹。
    // 微信升级后必须重新定位并验证，不能仅替换版本号或沿用 QAction/QString 的尺寸假设。
    if (!YMGetMediaForwardAddresses(&addresses)) return;
    struct Entry { uintptr_t offset; uint8_t bytes[16]; };
    static const Entry entries[] = {
        {0x5c916b8, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xe8, 0x03, 0x01, 0xaa}},
        {0x51b288, {0x48, 0xf4, 0x81, 0x52, 0xe8, 0x43, 0x00, 0xb9, 0x37, 0x50, 0x11, 0x95, 0x20, 0x15, 0x00, 0xb4}},
        {0x951268, {0x08, 0x00, 0x40, 0xb9, 0x29, 0x00, 0x40, 0xb9, 0x1f, 0x01, 0x09, 0x6b, 0xe0, 0xa7, 0x9f, 0x1a}},
        {0x950bac, {0xe9, 0x22, 0x05, 0xd1, 0x29, 0x01, 0x80, 0xb9, 0x6a, 0xba, 0x89, 0x52, 0x4a, 0x0c, 0xa2, 0x72}},
        {0x950bcc, {0xa8, 0x00, 0xf8, 0x37, 0x7f, 0x03, 0x08, 0x6b, 0x6d, 0x00, 0x00, 0x54, 0xe0, 0x03, 0x14, 0xaa}},
        {0x51b2e8, {0x68, 0xf4, 0x81, 0x52, 0xe8, 0x43, 0x00, 0xb9, 0x37, 0xa4, 0x11, 0x95, 0xc0, 0x00, 0x00, 0xb4}},
        {0x19dc280, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
        {0x5cc1e08, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x08, 0xaa}},
        {0x5cc1aec, {0xff, 0x03, 0x02, 0xd1, 0xfa, 0x67, 0x03, 0xa9, 0xf8, 0x5f, 0x04, 0xa9, 0xf6, 0x57, 0x05, 0xa9}},
        {0x857fbc, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa}},
        {0x530330, {0x60, 0x12, 0x40, 0xf9, 0xe8, 0x23, 0x00, 0x91, 0xb4, 0x46, 0x5e, 0x95, 0xe0, 0x07, 0x40, 0xf9}},
        {0x950868, {0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9, 0xf8, 0x5f, 0x02, 0xa9, 0xf6, 0x57, 0x03, 0xa9}},
        {0x19e08c8, {0x37, 0xff, 0xff, 0x17, 0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91}},
        {0x19e08cc, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa}},
        {0x19e05a4, {0xfa, 0x67, 0xbb, 0xa9, 0xf8, 0x5f, 0x01, 0xa9, 0xf6, 0x57, 0x02, 0xa9, 0xf4, 0x4f, 0x03, 0xa9}},
        {0x19dbd20, {0xff, 0x43, 0x01, 0xd1, 0xf8, 0x5f, 0x01, 0xa9, 0xf6, 0x57, 0x02, 0xa9, 0xf4, 0x4f, 0x03, 0xa9}},
        {0x61bddf4, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
        {0xab660, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xe8, 0x03, 0x00, 0xaa}},
        {0x2e0e10, {0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
        {0x9539b8, {0xff, 0x43, 0x02, 0xd1, 0xfa, 0x67, 0x04, 0xa9, 0xf8, 0x5f, 0x05, 0xa9, 0xf6, 0x57, 0x06, 0xa9}},
        {0x629d564, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa}},
        {0x5c91aa0, {0xff, 0xc3, 0x00, 0xd1, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91, 0xe8, 0x71, 0x01, 0xb0}},
        {0x5c915c4, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf4, 0x03, 0x01, 0xaa}},
    };
    static const Entry entries270353[] = {
        {0x64dda4, {0x60,0x12,0x40,0xf9,0xe8,0x23,0x00,0x91,0x15,0x79,0x94,0x95,0xe0,0x07,0x40,0xf9}},
        {0x6b3bc48, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xe8,0x03,0x01,0xaa}},
        {0x636884, {0x48,0xf4,0x81,0x52,0xe8,0x43,0x00,0xb9,0xb2,0x71,0x24,0x95,0x60,0x15,0x00,0xb4}},
        {0xd35a48, {0x08,0x00,0x40,0xb9,0x29,0x00,0x40,0xb9,0x1f,0x01,0x09,0x6b,0xe0,0xa7,0x9f,0x1a}},
        {0xd35330, {0xe9,0xa2,0x05,0xd1,0x29,0x01,0x80,0xb9,0x6a,0xba,0x89,0x52,0x4a,0x0c,0xa2,0x72}},
        {0xd35350, {0xa8,0x00,0xf8,0x37,0x7f,0x03,0x08,0x6b,0x6d,0x00,0x00,0x54,0xe0,0x03,0x14,0xaa}},
        {0x6368e8, {0x68,0xf4,0x81,0x52,0xe8,0x43,0x00,0xb9,0x69,0xcb,0x24,0x95,0xc0,0x00,0x00,0xb4}},
        {0x1f9d2b8, {0xff,0xc3,0x00,0xd1,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}},
        {0x6b6c200, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf3,0x03,0x08,0xaa}},
        {0x6b6bee4, {0xff,0x03,0x02,0xd1,0xfa,0x67,0x03,0xa9,0xf8,0x5f,0x04,0xa9,0xf6,0x57,0x05,0xa9}},
        {0x6b6c184, {0xff,0x43,0x01,0xd1,0xf4,0x4f,0x03,0xa9,0xfd,0x7b,0x04,0xa9,0xfd,0x03,0x01,0x91}},
        {0x20ed94, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf3,0x03,0x00,0xaa}},
        {0xd34fec, {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
        {0x1fa1c90, {0x23,0xff,0xff,0x17,0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91}},
        {0x1fa1c94, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf3,0x03,0x00,0xaa}},
        {0x1fa191c, {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9}},
        {0x1f9cd50, {0xff,0x43,0x01,0xd1,0xf8,0x5f,0x01,0xa9,0xf6,0x57,0x02,0xa9,0xf4,0x4f,0x03,0xa9}},
        {0x7069338, {0xff,0xc3,0x00,0xd1,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}},
        {0xadba4, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xe8,0x03,0x00,0xaa}},
        {0x399694, {0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}},
        {0xd37d60, {0xff,0x43,0x02,0xd1,0xfa,0x67,0x04,0xa9,0xf8,0x5f,0x05,0xa9,0xf6,0x57,0x06,0xa9}},
        {0x7148ac4, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf3,0x03,0x00,0xaa}},
        {0x6b3c030, {0xff,0xc3,0x00,0xd1,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91,0x08,0x8a,0x01,0xd0}},
        {0x6b3bb54, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf4,0x03,0x01,0xaa}},
        {0x6f0000, {0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91}},
        {0x6f06ac, {0x00,0xa4,0x40,0xb9,0xc0,0x03,0x5f,0xd6,0x01,0xd4,0x01,0xb9,0xc0,0x03,0x5f,0xd6}},
    };
    const bool current = YMMatchesWeChat270353Dylib();
    const Entry *selected = current ? entries270353 : entries;
    const size_t count = current ? sizeof(entries270353) / sizeof(Entry) : sizeof(entries) / sizeof(Entry);
    for (size_t index = 0; index < count; ++index) {
        const auto &entry = selected[index];

        if (memcmp((void *)YMRuntimeAddress(entry.offset), entry.bytes, sizeof(entry.bytes)) != 0) {
            YMLog(@"[MessageMenu] ABI fingerprint mismatch at 0x%lx; skip", entry.offset);
            return;
        }
    }
    YMMessageMediaActions::validateABI();
    YMMessageMenuBuilderContinue = YMMenuAddress(0x950878, 0xd34ffc);
    YMMessageMenuInstalled = YMPatchARM64AbsoluteJump(YMMenuAddress(0x950868, 0xd34fec), (uintptr_t)&YMMessageMenuBuilder, "message menu builder");
}
#else
void YMInstallMessageMenuPatch(void) {}
#endif

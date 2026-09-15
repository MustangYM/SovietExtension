// 消息右键菜单：顶部“+1”与分隔线独立成组，点击后将原消息发回原会话。
// 菜单层只负责原生对象生命周期及点击回调；发送复用 ForwardToSelfPatch 的统一入口。
#import "RevokePatch.h"
#import "ForwardToSelfPatch.h"

#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <ptrauth.h>

#if defined(__aarch64__)
// 私有 ABI 仅适用于 WeChat 269079 / arm64，UUID 580294a45af5310d9a9ac3639bee0a28。
// 0x530330 的消息菜单调用点 → 0x950868 构建器；其他菜单调用不插入 +1。
// 原生“转发”在 0x51bdac 复制相同的 model+0x120，作为消息来源的对照锚点。
static bool YMRepeatInstalled = false;

struct YMRepeatQString {
    // 该版本 QString 是 8 字节数据句柄；用微信自己的 UTF-8 构造和析构，不能伪造布局。
    uintptr_t data;
    YMRepeatQString() : data(((uintptr_t (*)(const char *, int))YMRuntimeAddress(0x61bddf4))("+1", 2)) {}
    ~YMRepeatQString() { ((void (*)(void *))YMRuntimeAddress(0xab660))(this); }
};

struct YMRepeatItem {
    // 原生业务菜单项，不是 QAction；构造时复制标题和样式，插入成功后由菜单接管。
    alignas(16) uint8_t storage[0x3c0];
    YMRepeatItem(const YMRepeatQString &title, uintptr_t style) {
        ((void (*)(void *, const void *, uintptr_t, uintptr_t))YMRuntimeAddress(0x19e08c8))(this, &title, style, 0);
    }
    ~YMRepeatItem() { ((void (*)(void *))YMRuntimeAddress(0x19e08cc))(this); }
};

struct YMRepeatMessage {
    // 原生复制构造保留媒体扩展及共享资源；随 Qt 保存的回调一起释放，不能 memcpy 原对象。
    alignas(16) uint8_t storage[0x340];
    explicit YMRepeatMessage(uintptr_t source) {
        ((void (*)(void *, uintptr_t))YMRuntimeAddress(0x2e0e10))(this, source);
    }
    ~YMRepeatMessage() { ((void (*)(void *))YMRuntimeAddress(0x2e1ff8))(this); }
};

struct YMRepeatConnection {
    uintptr_t data;
    // 非平凡析构保证 arm64 返回句柄走 x8；不可简化为 uintptr_t 返回值。
    // 释放此局部连接句柄不会断开信号，连接及捕获的消息快照由 Qt 管理。
    ~YMRepeatConnection() { ((void (*)(void *))YMRuntimeAddress(0x629d564))(this); }
};

struct YMRepeatActions {
    // QWidget::actions() 返回的 QList 句柄。数据头为 ref/alloc/begin/end，指针数组从 +16 开始。
    // begin 可能非零；取得的快照仅用于定位/核对顺序，重排通过原生 insertAction 完成。
    uintptr_t data;
    ~YMRepeatActions() { ((void (*)(void *))YMRuntimeAddress(0x857fbc))(this); }
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
static_assert(sizeof(YMRepeatQString) == 8);
static_assert(sizeof(YMRepeatItem) == 0x3c0);
static_assert(sizeof(YMRepeatMessage) == 0x340);
static_assert(sizeof(YMRepeatConnection) == 8);
static_assert(sizeof(YMRepeatActions) == 8);
static_assert(sizeof(std::function<void()>) == 0x20);

extern "C" uintptr_t YMRepeatBuilderContinue;
uintptr_t YMRepeatBuilderContinue = 0;
extern "C" void YMRepeatOriginalBuilder(uintptr_t model, uintptr_t menu, bool fillNames);

// 被覆盖的四条指令不含 PC 相对寻址；完整重放后跳回原函数，避免反复卸载/安装 Hook 的竞态。
__asm__(
    ".text\n.align 2\n.globl _YMRepeatOriginalBuilder\n"
    "_YMRepeatOriginalBuilder:\n"
    "stp x28, x27, [sp, #-0x60]!\n"
    "stp x26, x25, [sp, #0x10]\n"
    "stp x24, x23, [sp, #0x20]\n"
    "stp x22, x21, [sp, #0x30]\n"
    "adrp x16, _YMRepeatBuilderContinue@PAGE\n"
    "ldr x16, [x16, _YMRepeatBuilderContinue@PAGEOFF]\n"
    "br x16\n"
);

__attribute__((noinline))
static void YMRepeatBuilder(uintptr_t model, uintptr_t menu, bool fillNames) {
    const uintptr_t caller = (uintptr_t)ptrauth_strip(__builtin_return_address(0), ptrauth_key_return_address);
    std::unique_ptr<YMRepeatItem> item;
    std::function<void()> callback;
    if (caller == YMRuntimeAddress(0x530330) && [NSThread isMainThread]) {
        try {
            uintptr_t begin = 0, end = 0, vtable = 0;
            memcpy(&begin, (void *)(model + 8), 8);
            memcpy(&end, (void *)(model + 16), 8);
            const uintptr_t source = model + 0x120;
            memcpy(&vtable, (void *)source, 8);
            uint32_t type = 0;
            uint64_t identifier = 0;
            memcpy(&type, (void *)(source + 8), 4);
            memcpy(&identifier, (void *)(source + 0x90), 8);
            // 模型菜单条目跨度为 0x170；首项 +0x48 提供原生样式，消息快照位于 model+0x120。
            // +0x58 是按消息方向解析的原会话；文字/图片/视频/表情包/应用消息共用类型门控。
            if (begin && end > begin && end - begin <= 64 * 0x170 && (end - begin) % 0x170 == 0 &&
                vtable == YMRuntimeAddress(0x8e20548) && identifier &&
                YMForwardSupportsMessageType(type)) {
                const auto &nativeSession = *(const std::string *)(source + 0x58);
                if (!nativeSession.empty() && nativeSession.size() <= 128) {
                    NSString *session = [[NSString alloc] initWithBytes:nativeSession.data()
                                                               length:nativeSession.size() encoding:NSUTF8StringEncoding];
                    if (session.length) {
                        auto message = std::make_shared<YMRepeatMessage>(source);
                        callback = [message, session, used = false]() mutable {
                            // 每次打开菜单持有独立快照；同一个 QAction 最多提交一次，防止重复触发。
                            if (used) return;
                            used = true;
                            @autoreleasepool {
                                BOOL submitted = YMForwardMessageDataToSession((uintptr_t)message.get(), session);
                                YMLog(@"[MessageRepeat] clicked; submitted=%@ (delivery pending)", submitted ? @"YES" : @"NO");
                            }
                        };
                        YMRepeatQString title;
                        item = std::make_unique<YMRepeatItem>(title, begin + 0x48);
                        YMLog(@"[MessageRepeat] prepared native snapshot and menu item; type=%u", type);
                    }
                }
            }
        } catch (...) {
            YMLog(@"[MessageRepeat] preparation failed; keeping native menu");
        }
    }

    // 原构建器在 0x951128..0x951144 销毁模型条目，所以样式复制和消息快照必须提前完成。
    // 返回后只使用自己构造的 item 和 callback，不能再读取 begin/end 指向的旧条目。
    YMRepeatOriginalBuilder(model, menu, fillNames);
    if (!item || !callback) return;
    try {
        uintptr_t action = ((uintptr_t (*)(uintptr_t, void *))YMRuntimeAddress(0x19dbd20))(menu, item.get());
        if (!action) return;
        item.release(); // 0x19dbd20 已将业务项和 QAction 挂到菜单，之后由 Qt 负责销毁。
        // 0x9539b8 原生创建 slot-object 并复制 std::function，避免手工模拟其私有布局。
        // context=action、DirectConnection=1，点击在主线程提交；弹出菜单时微信自动创建显示 wrapper。
        using Connect = YMRepeatConnection (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, std::function<void()> *, int);
        auto connection = ((Connect)YMRuntimeAddress(0x9539b8))(
            action, YMRuntimeAddress(0x5c91aa0), 0, action, &callback, 1);
        if (!connection.data) {
            ((void (*)(uintptr_t, bool))YMRuntimeAddress(0x5c915c4))(action, false);
            YMLog(@"[MessageRepeat] native callback connection failed; action disabled");
        } else {
            YMLog(@"[MessageRepeat] +1 inserted and native callback connected");
        }
        // 先追加原生分隔线，再把 +1 和分隔线依次移到原首项之前，形成独立的顶部区域。
        // insertAction 移动已有 QAction，保留 Qt 所有权、原菜单顺序和标题到业务项的映射。
        ((void (*)(uintptr_t))YMRuntimeAddress(0x19dc280))(menu);
        using GetActions = YMRepeatActions (*)(uintptr_t);
        using InsertAction = void (*)(uintptr_t, uintptr_t, uintptr_t);
        auto actions = ((GetActions)YMRuntimeAddress(0x5cc1e08))(menu);
        const uintptr_t first = actions.at(0), separator = actions.last();
        if (first && separator && first != action && separator != action) {
            auto insert = (InsertAction)YMRuntimeAddress(0x5cc1aec);
            insert(menu, first, action);
            insert(menu, first, separator);
            auto reordered = ((GetActions)YMRuntimeAddress(0x5cc1e08))(menu);
            YMLog(@"[MessageRepeat] top group order=%@",
                  reordered.at(0) == action && reordered.at(1) == separator ? @"OK" : @"FAIL");
        }
    } catch (...) {
        YMLog(@"[MessageRepeat] menu connection failed");
    }
}

void YMInstallMessageRepeatPatch(void) {
    if (YMRepeatInstalled) return;
    YMMediaForwardAddresses addresses = {};
    // 先复用转发层的版本/Resources 镜像 UUID 校验，再核对菜单辅助函数和调用点指纹。
    // 微信升级后必须重新定位并验证，不能仅替换版本号或沿用 QAction/QString 的尺寸假设。
    if (!YMGetMediaForwardAddresses(&addresses)) return;
    struct Entry { uintptr_t offset; uint8_t bytes[16]; };
    static const Entry entries[] = {
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
    for (const auto &entry : entries) {
        if (memcmp((void *)YMRuntimeAddress(entry.offset), entry.bytes, sizeof(entry.bytes)) != 0) {
            YMLog(@"[MessageRepeat] ABI fingerprint mismatch at 0x%lx; skip", entry.offset);
            return;
        }
    }
    YMRepeatBuilderContinue = YMRuntimeAddress(0x950878);
    YMRepeatInstalled = YMPatchARM64AbsoluteJump(YMRuntimeAddress(0x950868), (uintptr_t)&YMRepeatBuilder, "message +1 builder");
}
#else
void YMInstallMessageRepeatPatch(void) {}
#endif

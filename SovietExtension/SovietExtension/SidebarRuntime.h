#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <atomic>
#include <optional>
#include <utility>
#include <span>
#include <string_view>

#include "SidebarModel.h"

// ---- SidebarManagerInternals -----------------------------------

#define YM_NAVIGATION_SIDEBAR_PROFILE_HAS_TITLE_UUID 1

enum class YMNavigationSidebarApplyTrigger : uint8_t {
    entriesPopulated,
    preferencesChanged,
    defaultsReloaded,
};

static constexpr uintptr_t kYMNavigationSidebarPrimaryControllerOffset = 0x190;
static constexpr uintptr_t kYMNavigationSidebarSecondaryControllerOffset = 0x1A0;
static constexpr uintptr_t kYMNavigationSidebarOverflowOffset = 0x218;
static constexpr uintptr_t kYMNavigationSidebarVisibilityVtableOffset = 0x68;
static constexpr uintptr_t kYMNavigationSidebarItemTypeOffset = 0x118;

// 选中条带：行数组 begin 在 +0x10、end 在 +0x18（8 字节指针）；functor 的
// strip 在 +0x10，绑定值在 argBox+0x10 指向的 int。取自 0x1A6CC00 的反编译。
static constexpr uintptr_t kYMNavigationSidebarRowsBeginOffset = 0x10;
static constexpr uintptr_t kYMNavigationSidebarFunctorStripOffset = 0x10;
static constexpr std::size_t kYMNavigationSidebarMaxRowCount = 16;


using YMNavigationSidebarReadableRange =
    bool (*)(void *, uintptr_t, std::size_t);

static constexpr bool YMNavigationSidebarNativeItemTypeIsKnown(int type) {
    switch (type) {
        case 0:
        case 1:
        case 2:
        case 3:
        case 5:
        case 6:
        case 7:
        case 8:
            return true;
        default:
            return false;
    }
}

static inline int YMNavigationSidebarReadNativeItemType(
    const void *item,
    YMNavigationSidebarReadableRange readable,
    void *context) noexcept {
    const int unavailable = std::numeric_limits<int>::min();
    const uintptr_t base = reinterpret_cast<uintptr_t>(item);
    if (item == nullptr || readable == nullptr ||
        base % alignof(std::uintptr_t) != 0 ||
        base > std::numeric_limits<uintptr_t>::max() -
                   kYMNavigationSidebarItemTypeOffset) {
        return unavailable;
    }
    const uintptr_t address = base + kYMNavigationSidebarItemTypeOffset;
    if (address > std::numeric_limits<uintptr_t>::max() - sizeof(int) ||
        !readable(context, address, sizeof(int))) {
        return unavailable;
    }
    int type = unavailable;
    std::memcpy(&type, reinterpret_cast<const void *>(address), sizeof(type));
    return YMNavigationSidebarNativeItemTypeIsKnown(type) ? type : unavailable;
}

// Order-getter results and the overflow holder do NOT hold sidebar items. For
// each entry WeChat allocates a bare four-byte cell and stores only the type in
// it, then puts that pointer in the slot (append at 0xE59D08:
// `mov w0,#4; bl operator new; ldr w8,[x20]; str w8,[x0]; str x0,[x21]`).
// The type therefore sits at offset 0, and reading the *item* layout's 0x118
// from one of these runs 276 bytes past a four-byte allocation. The known-type
// guard rejects whatever it finds, so a reorder driven by the item reader fails
// silently rather than crashing -- which is exactly how ordering appeared to do
// nothing while every Save reported success.
static constexpr uintptr_t kYMNavigationSidebarOrderSlotTypeOffset = 0x0;

static inline int YMNavigationSidebarReadNativeOrderSlotType(
    const void *slot,
    YMNavigationSidebarReadableRange readable,
    void *context) noexcept {
    const int unavailable = std::numeric_limits<int>::min();
    const uintptr_t base = reinterpret_cast<uintptr_t>(slot);
    if (slot == nullptr || readable == nullptr ||
        base % alignof(int) != 0) {
        return unavailable;
    }
    const uintptr_t address = base + kYMNavigationSidebarOrderSlotTypeOffset;
    if (address > std::numeric_limits<uintptr_t>::max() - sizeof(int) ||
        !readable(context, address, sizeof(int))) {
        return unavailable;
    }
    int type = unavailable;
    std::memcpy(&type, reinterpret_cast<const void *>(address), sizeof(type));
    return YMNavigationSidebarNativeItemTypeIsKnown(type) ? type : unavailable;
}

static constexpr std::array<int, 5> kYMNavigationSidebarSecondarySortableTypes = {
    2, 3, 5, 7, 6,
};
static constexpr int kYMNavigationSidebarPrimaryDiscoverType = 3;
static constexpr uintptr_t YMNavigationSidebarAvailabilityFlagOffset(int type, uintptr_t base = 0x211) {
    switch (type) {
        case 2:
            return base + 0;
        case 3:
            return base + 1;
        case 5:
            return base + 2;
        case 6:
            return base + 3;
        case 7:
            return base + 4;
        default:
            return 0;
    }
}

// WeChat renders its sidebar in one of two mutually exclusive layout modes, selected
// by a single byte at owner+0x210. The byte is decided once during owner init and is
// never persisted, so it is recomputed on every launch.
//
//   expanded (0):  primary   = {Chats, Contacts, Favorites}
//                  secondary = {Moments, Channels, Search, GameCenter, MiniPrograms,
//                               More} -- the 发现与服务 group, as real sidebar items
//                               with native visibility, ordering and More-overflow.
//   collapsed (1): primary   = {Chats, Contacts, Favorites, Discover}
//                  secondary = EMPTY. The secondary strip view is hidden, the
//                  secondary order getter returns an empty list, the responsive
//                  layout pass early-returns, and all five availability bytes are
//                  force-zeroed by the collapsed-mode init.
//
// Only the expanded mode gives the 发现与服务 entries a sidebar representation, which
// is the representation this feature manages. Observed in wechat.dylib arm64
// 580294A4 (4.1.11.23 / 269079): primary order getter 0xE55970 appends Discover only
// when the byte == 1; secondary order getter 0xE55ABC returns empty when bit 0 is
// set; responsive layout 0xE55108 bails when bit 0 is set.
static constexpr uintptr_t kYMNavigationSidebarLayoutModeOffset = 0x210;
static constexpr uint8_t kYMNavigationSidebarLayoutModeExpanded = 0;
static constexpr uint8_t kYMNavigationSidebarLayoutModeCollapsed = 1;

// WeChat's own owner constructor (0xE548D8) seeds availability with 0x01010101 across
// owner+0x211..0x214 and a zero at owner+0x215, i.e. Moments/Channels/Search/
// MiniPrograms available and Game Center not. The collapsed-mode init then zeroes all
// five. Restoring exactly these values is what re-arms the expanded strip; we
// deliberately do not invent availability WeChat did not grant.
static constexpr uint8_t YMNavigationSidebarNativeAvailabilityDefaultForType(
    int type) {
    switch (type) {
        case 2:
        case 3:
        case 5:
        case 6:
            return 1;
        case 7:
            return 0;
        default:
            return 0;
    }
}

enum class YMNavigationSidebarLayoutModeAction : uint8_t {
    // Already expanded: WeChat is natively showing the secondary strip, so leave
    // every byte alone.
    none,
    // Collapsed: flip the mode byte to expanded and re-arm the availability bytes
    // that the collapsed-mode init zeroed.
    forceExpanded,
    // Unrecognised mode byte: this build does not match the profiled layout, so make
    // no writes at all.
    unsupported,
};

static constexpr YMNavigationSidebarLayoutModeAction
YMNavigationSidebarLayoutModeActionForMode(uint8_t mode) {
    if (mode == kYMNavigationSidebarLayoutModeExpanded) {
        return YMNavigationSidebarLayoutModeAction::none;
    }
    if (mode == kYMNavigationSidebarLayoutModeCollapsed) {
        return YMNavigationSidebarLayoutModeAction::forceExpanded;
    }
    return YMNavigationSidebarLayoutModeAction::unsupported;
}

static constexpr bool YMNavigationSidebarLayoutModeActionWrites(
    YMNavigationSidebarLayoutModeAction action) {
    return action == YMNavigationSidebarLayoutModeAction::forceExpanded;
}

static constexpr bool YMNavigationSidebarApplyShouldSchedule(
    YMNavigationSidebarApplyTrigger trigger) {
    switch (trigger) {
        case YMNavigationSidebarApplyTrigger::entriesPopulated:
            return true;
        case YMNavigationSidebarApplyTrigger::preferencesChanged:
        case YMNavigationSidebarApplyTrigger::defaultsReloaded:
            return true;
    }
}

static constexpr bool YMNavigationSidebarApplyShouldDefer(
    YMNavigationSidebarApplyTrigger trigger) {
    switch (trigger) {
        case YMNavigationSidebarApplyTrigger::entriesPopulated:
        case YMNavigationSidebarApplyTrigger::preferencesChanged:
        case YMNavigationSidebarApplyTrigger::defaultsReloaded:
            return true;
    }
}

struct YMNavigationSidebarBuildProfile {
    const char *bundleIdentifier;
    const char *shortVersion;
    const char *buildVersion;
    const char *architecture;
    uint8_t expectedMachOUUID[16];
    uintptr_t responsiveLayoutVA;
    uint8_t expectedResponsiveLayoutBytes[16];
    uintptr_t primaryOrderGetterVA;
    uint8_t expectedPrimaryOrderGetterBytes[16];
    uintptr_t secondaryOrderGetterVA;
    uint8_t expectedSecondaryOrderGetterBytes[16];
    uintptr_t populateSecondaryEntriesVA;
    uint8_t expectedPopulateSecondaryEntriesBytes[16];
    uintptr_t mainWindowDestructorVA;
    uint8_t expectedMainWindowDestructorBytes[16];
    uintptr_t primarySelectorVA;
    uint8_t expectedPrimarySelectorBytes[16];
    uintptr_t selectedPrimaryTypeGetterVA;
    uint8_t expectedSelectedPrimaryTypeGetterBytes[16];
    uintptr_t secondaryActivationVA;
    uint8_t expectedSecondaryActivationBytes[16];
    uintptr_t findSecondaryItemVA;
    uint8_t expectedFindSecondaryItemBytes[16];
    uintptr_t lookupItemVA;
    uint8_t expectedLookupItemBytes[16];
    uintptr_t overflowClearVA;
    uint8_t expectedOverflowClearBytes[16];
    uintptr_t overflowAppendVA;
    uint8_t expectedOverflowAppendBytes[16];
    uintptr_t moreSetVisibleVA;
    uint8_t expectedMoreSetVisibleBytes[16];
    uintptr_t moreSetBadgeVA;
    uint8_t expectedMoreSetBadgeBytes[16];
    uintptr_t moreCountGetterVA;
    uint8_t expectedMoreCountGetterBytes[16];
    uintptr_t nativeTitleFromUtf8VA;
    uint8_t expectedNativeTitleFromUtf8Bytes[16];
    uintptr_t moreTitleFormatGetterVA;
    uint8_t expectedMoreTitleFormatGetterBytes[16];
    uintptr_t nativeTitleFormatterVA;
    uint8_t expectedNativeTitleFormatterBytes[16];
    uintptr_t nativeTitleDeallocateVA;
    uint8_t expectedNativeTitleDeallocateBytes[16];
    uintptr_t moreTitleSetterVA;
    uint8_t expectedMoreTitleSetterBytes[16];
    uintptr_t postLayoutVA;
    uint8_t expectedPostLayoutBytes[16];
    // 点击选中：这是那个 lambda 的 std::function invoker/manager（0x1A6CC00，
    // 188 字节，经存储的函数指针调用，所以静态零调用者）。它把入口类型存进
    // strip+0x28，却拿同一个值当行下标挑高亮行（0x1A6CC9C 的 cmp w19, w21）。
    // 第一个参数是判别位：0 表示析构路径，此时不能做任何纠正。
    uintptr_t clickSelectionInvokerVA;
    uint8_t expectedClickSelectionInvokerBytes[16];
    uintptr_t rowSelectVA;
    uint8_t expectedRowSelectBytes[16];
    uintptr_t rowDeselectVA;
    uint8_t expectedRowDeselectBytes[16];
    uintptr_t primaryControllerOffset = 0x190;
    uintptr_t secondaryControllerOffset = 0x1a0;
    uintptr_t overflowOffset = 0x218;
    uintptr_t layoutModeOffset = 0x210;
    uintptr_t availabilityFlagBase = 0x211;
    uintptr_t mainWindowOwnerOffset = 0x2a0;
    uintptr_t componentSurfaceOffset = 0x180;
};

// 补丁点清单（wechat.dylib arm64，Build 269079 / 4.1.11.23）
//
// 以下 VA 均为静态地址，运行时需加模块基址。安装前逐个校验前 16 字节指纹，
// 任一不匹配即放弃安装、不改写内存（见 SidebarPatchIntegrity）。
//
//   布局与生命周期
//     0xE55108  responsiveLayout           响应式布局，折叠模式下提前返回
//     0x5CCA020 postLayout                 布局结束回调
//     0xE6D3CC  mainWindowDestructor       主窗口析构，用于撤销 owner 绑定
//
//   主导航
//     0xE55970  primaryOrderGetter         主组顺序；byte==1 时在末尾追加「发现」
//     0xE587B4  primarySelector            选中某个主入口
//     0xCDD234  selectedPrimaryTypeGetter  读取当前选中的入口类型
//     0x1A6C9B0 lookupItem                 按类型取原生 item（与 findSecondaryItem 同址）
//
//   发现与服务
//     0xE55ABC  secondaryOrderGetter       二级组顺序；折叠模式下返回空
//     0xE56588  populateSecondaryEntries   构建二级组条目
//     0xE5B1B4  secondaryActivation        二级入口激活
//     0x1A6C9B0 findSecondaryItem          按类型取二级 item
//
//   「更多」溢出项
//     0xE59D08  overflowAppend             向溢出表追加条目
//     0xE59BF4  overflowClear              清空溢出表
//     0x1A6DDD4 moreSetVisible             更多项显隐
//     0x1A6DCFC moreSetBadge               更多项角标
//     0x1A6DDC4 moreCountGetter            更多项计数
//     0x5CCE318 moreTitleSetter            更多项标题写入
//     0x4969EAC moreTitleFormatGetter      更多项标题格式串
//
//   原生标题构造（更多项标题需按微信自己的方式构造，否则释放时会出错）
//     0x61BDDF4 nativeTitleFromUtf8        UTF-8 → 原生字符串
//     0x61C1280 nativeTitleFormatter       格式化器实例
//     0x6167298 nativeTitleDeallocate      原生字符串释放
//
// 适配新版本时：这些函数在二进制里都可以按字节特征唯一定位 —— 从函数入口起
// 取 32~64 字节，把其中 B/BL/ADRP/ADR/LDR-literal 这类含地址的指令整条通配后，
// 21 个里有 17 个仍然全局唯一；其余 4 个（overflowAppend/overflowClear/
// moreSetVisible/moreSetBadge）体积小且过于通用，需要借助相邻函数或调用点定位。

static constexpr YMNavigationSidebarBuildProfile
    YMNavigationSidebarWeChat411BuildProfile = {
        "com.tencent.xinWeChat",
        "4.1.11",
        "269079",
        "arm64",
        {
            0x58, 0x02, 0x94, 0xa4,
            0x5a, 0xf5, 0x31, 0x0d,
            0x9a, 0x9a, 0xc3, 0x63,
            0x9b, 0xee, 0x0a, 0x28,
        },
        0x00E55108,
        {
            0xff, 0xc3, 0x02, 0xd1,
            0xeb, 0x2b, 0x03, 0x6d,
            0xe9, 0x23, 0x04, 0x6d,
            0xfc, 0x6f, 0x05, 0xa9,
        },
        0x00E55970,
        {
            0xff, 0xc3, 0x00, 0xd1,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x00E55ABC,
        {
            0xff, 0xc3, 0x00, 0xd1,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x00E56588,
        {
            0xfc, 0x6f, 0xba, 0xa9,
            0xfa, 0x67, 0x01, 0xa9,
            0xf8, 0x5f, 0x02, 0xa9,
            0xf6, 0x57, 0x03, 0xa9,
        },
        0x00E6D3CC,
        {
            0xff, 0xc3, 0x05, 0xd1,
            0xfc, 0x6f, 0x14, 0xa9,
            0xf4, 0x4f, 0x15, 0xa9,
            0xfd, 0x7b, 0x16, 0xa9,
        },
        0x00E587B4,
        {
            0xf4, 0x4f, 0xbe, 0xa9,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0xf4, 0x03, 0x01, 0xaa,
        },
        0x00CDD234,
        {
            0x00, 0x28, 0x40, 0xb9,
            0xc0, 0x03, 0x5f, 0xd6,
            0x4c, 0x01, 0x09, 0x8b,
            0x8c, 0x09, 0x42, 0x39,
        },
        0x00E5B1B4,
        {
            0xff, 0x83, 0x06, 0xd1,
            0xfc, 0x6f, 0x14, 0xa9,
            0xfa, 0x67, 0x15, 0xa9,
            0xf8, 0x5f, 0x16, 0xa9,
        },
        0x01A6C9B0,
        {
            0xf6, 0x57, 0xbd, 0xa9,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x01A6C9B0,
        {
            0xf6, 0x57, 0xbd, 0xa9,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x00E59BF4,
        {
            0xf6, 0x57, 0xbd, 0xa9,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x00E59D08,
        {
            0xf6, 0x57, 0xbd, 0xa9,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x01A6DDD4,
        {
            0xff, 0xc3, 0x00, 0xd1,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x01A6DCFC,
        {
            0xff, 0xc3, 0x00, 0xd1,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x01A6DDC4,
        {
            0x00, 0x28, 0x41, 0xf9,
            0x40, 0x00, 0x00, 0xb4,
            0x87, 0x6d, 0xfd, 0x17,
            0xc0, 0x03, 0x5f, 0xd6,
        },
        0x061BDDF4,
        {
            0xff, 0xc3, 0x00, 0xd1,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x04969EAC,
        {
            0x68, 0x35, 0x02, 0x90,
            0x09, 0x15, 0x42, 0xf9,
            0x28, 0x01, 0x40, 0xb9,
            0x1f, 0x5d, 0x01, 0x71,
        },
        0x061C1280,
        {
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0xa9, 0x43, 0x00, 0x91,
        },
        0x06167298,
        {
            0x08, 0x7e, 0x01, 0x90,
            0x08, 0xe1, 0x13, 0x91,
            0x1f, 0x00, 0x08, 0xeb,
            0x40, 0x00, 0x00, 0x54,
        },
        0x05CCE318,
        {
            0xff, 0x03, 0x01, 0xd1,
            0xf4, 0x4f, 0x02, 0xa9,
            0xfd, 0x7b, 0x03, 0xa9,
            0xfd, 0xc3, 0x00, 0x91,
        },
        0x05CCA020,
        {
            0x00, 0x04, 0x40, 0xf9,
            0x01, 0x00, 0x80, 0x52,
            0x67, 0xe3, 0xff, 0x17,
            0xf6, 0x57, 0xbd, 0xa9,
        },
        0x01A6CC00,
        {
            0xf6, 0x57, 0xbd, 0xa9,
            0xf4, 0x4f, 0x01, 0xa9,
            0xfd, 0x7b, 0x02, 0xa9,
            0xfd, 0x83, 0x00, 0x91,
        },
        0x01A6D9F0,
        {
            0xf4, 0x4f, 0xbe, 0xa9,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0xf3, 0x03, 0x00, 0xaa,
        },
        0x01A6DCD4,
        {
            0xf4, 0x4f, 0xbe, 0xa9,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0xf3, 0x03, 0x00, 0xaa,
        },
        };

// 4.2.0 的 owner 字段与主窗口继承布局不同；析构还接收隐藏 VTT 参数。
static constexpr YMNavigationSidebarBuildProfile YMNavigationSidebarWeChat420BuildProfile = {
    "com.tencent.xinWeChat", "4.2.0", "270353", "arm64",
    {0x8c, 0xb5, 0xf2, 0x9e, 0xfc, 0x1d, 0x3d, 0x47, 0x89, 0x7a, 0x27, 0x2a, 0x46, 0x51, 0xe9, 0x16},
    0x126242c, {0xff, 0xc3, 0x02, 0xd1, 0xeb, 0x2b, 0x03, 0x6d, 0xe9, 0x23, 0x04, 0x6d, 0xfc, 0x6f, 0x05, 0xa9},
    0x1262de0, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x1262f2c, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x1263a7c, {0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9, 0xf8, 0x5f, 0x02, 0xa9, 0xf6, 0x57, 0x03, 0xa9},
    0x127ea50, {0xff, 0xc3, 0x05, 0xd1, 0xfc, 0x6f, 0x14, 0xa9, 0xf4, 0x4f, 0x15, 0xa9, 0xfd, 0x7b, 0x16, 0xa9},
    0x1265f00, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa},
    0x11391f0, {0x00, 0x28, 0x40, 0xb9, 0xc0, 0x03, 0x5f, 0xd6, 0x4c, 0x01, 0x09, 0x8b, 0x8c, 0x09, 0x42, 0x39},
    0x1268e58, {0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9, 0xf8, 0x5f, 0x02, 0xa9, 0xf6, 0x57, 0x03, 0xa9},
    0x20345f8, {0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x20345f8, {0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x1267370, {0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x1267484, {0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x2035790, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x20356c8, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0xeb2224, {0x00, 0x20, 0x41, 0xf9, 0x40, 0x00, 0x00, 0xb4, 0x04, 0x61, 0x43, 0x14, 0xc0, 0x03, 0x5f, 0xd6},
    0x7069338, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x4f4b394, {0x28, 0x99, 0x02, 0xd0, 0x09, 0xe1, 0x47, 0xf9, 0x28, 0x01, 0x40, 0xb9, 0x1f, 0x71, 0x01, 0x71},
    0x706c7c4, {0xff, 0x83, 0x00, 0xd1, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xa9, 0x43, 0x00, 0x91},
    0x70127dc, {0x88, 0x9b, 0x01, 0xb0, 0x08, 0xe1, 0x24, 0x91, 0x1f, 0x00, 0x08, 0xeb, 0x40, 0x00, 0x00, 0x54},
    0x6b78710, {0xff, 0x03, 0x01, 0xd1, 0xf4, 0x4f, 0x02, 0xa9, 0xfd, 0x7b, 0x03, 0xa9, 0xfd, 0xc3, 0x00, 0x91},
    0x6b74418, {0x00, 0x04, 0x40, 0xf9, 0x01, 0x00, 0x80, 0x52, 0x67, 0xe3, 0xff, 0x17, 0xf6, 0x57, 0xbd, 0xa9},
    0x2034848, {0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91},
    0x2035410, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa},
    0x20356a0, {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa},
    0x180, 0x190, 0x210, 0x208, 0x209, 0x338, 0x170,
};

static constexpr std::size_t kYMNavigationSidebarBuildProfileTargetCount = 24;

struct YMNavigationSidebarProfileTarget {
    const char *label;
    uintptr_t address;
    const uint8_t *expectedBytes;
};

static inline bool YMNavigationSidebarVerifyMachOUUID(
    const YMNavigationSidebarBuildProfile &profile,
    const uint8_t *image,
    std::size_t imageSize) noexcept {
    constexpr std::uint32_t kMachMagic64 = 0xfeedfacf;
    constexpr std::int32_t kCpuTypeArm64 = 0x0100000c;
    constexpr std::uint32_t kMachDylib = 0x6;
    constexpr std::uint32_t kLoadCommandUUID = 0x1b;
    constexpr std::size_t kHeaderSize = 32;
    constexpr std::size_t kLoadCommandSize = 8;
    constexpr std::size_t kUUIDCommandSize = 24;
    if (image == nullptr || imageSize < kHeaderSize) {
        return false;
    }

    std::uint32_t magic = 0;
    std::int32_t cpuType = 0;
    std::uint32_t fileType = 0;
    std::uint32_t commandCount = 0;
    std::uint32_t commandBytes = 0;
    std::memcpy(&magic, image, sizeof(magic));
    std::memcpy(&cpuType, image + 4, sizeof(cpuType));
    std::memcpy(&fileType, image + 12, sizeof(fileType));
    std::memcpy(&commandCount, image + 16, sizeof(commandCount));
    std::memcpy(&commandBytes, image + 20, sizeof(commandBytes));
    if (magic != kMachMagic64 || cpuType != kCpuTypeArm64 ||
        fileType != kMachDylib || commandBytes > imageSize - kHeaderSize ||
        commandCount > commandBytes / kLoadCommandSize) {
        return false;
    }

    const std::size_t commandsEnd = kHeaderSize + commandBytes;
    std::size_t cursor = kHeaderSize;
    bool foundUUID = false;
    bool uuidMatches = false;
    for (std::uint32_t index = 0; index < commandCount; ++index) {
        if (cursor > commandsEnd ||
            commandsEnd - cursor < kLoadCommandSize) {
            return false;
        }
        std::uint32_t command = 0;
        std::uint32_t commandSize = 0;
        std::memcpy(&command, image + cursor, sizeof(command));
        std::memcpy(&commandSize,
                    image + cursor + sizeof(command),
                    sizeof(commandSize));
        if (commandSize < kLoadCommandSize ||
            commandSize > commandsEnd - cursor) {
            return false;
        }
        if (command == kLoadCommandUUID) {
            if (foundUUID || commandSize < kUUIDCommandSize) {
                return false;
            }
            foundUUID = true;
            uuidMatches = std::memcmp(
                image + cursor + kLoadCommandSize,
                profile.expectedMachOUUID,
                sizeof(profile.expectedMachOUUID)) == 0;
        }
        cursor += commandSize;
    }
    return cursor == commandsEnd && foundUUID && uuidMatches;
}

static inline std::array<YMNavigationSidebarProfileTarget,
                          kYMNavigationSidebarBuildProfileTargetCount>
YMNavigationSidebarProfileTargets(
    const YMNavigationSidebarBuildProfile &profile) noexcept {
    return {{
        {"responsiveLayout", profile.responsiveLayoutVA,
         profile.expectedResponsiveLayoutBytes},
        {"primaryOrderGetter", profile.primaryOrderGetterVA,
         profile.expectedPrimaryOrderGetterBytes},
        {"secondaryOrderGetter", profile.secondaryOrderGetterVA,
         profile.expectedSecondaryOrderGetterBytes},
        {"populateSecondaryEntries", profile.populateSecondaryEntriesVA,
         profile.expectedPopulateSecondaryEntriesBytes},
        {"mainWindowDestructor", profile.mainWindowDestructorVA,
         profile.expectedMainWindowDestructorBytes},
        {"primarySelector", profile.primarySelectorVA,
         profile.expectedPrimarySelectorBytes},
        {"selectedPrimaryTypeGetter", profile.selectedPrimaryTypeGetterVA,
         profile.expectedSelectedPrimaryTypeGetterBytes},
        {"secondaryActivation", profile.secondaryActivationVA,
         profile.expectedSecondaryActivationBytes},
        {"findSecondaryItem", profile.findSecondaryItemVA,
         profile.expectedFindSecondaryItemBytes},
        {"lookupItem", profile.lookupItemVA, profile.expectedLookupItemBytes},
        {"overflowClear", profile.overflowClearVA,
         profile.expectedOverflowClearBytes},
        {"overflowAppend", profile.overflowAppendVA,
         profile.expectedOverflowAppendBytes},
        {"moreSetVisible", profile.moreSetVisibleVA,
         profile.expectedMoreSetVisibleBytes},
        {"moreSetBadge", profile.moreSetBadgeVA,
         profile.expectedMoreSetBadgeBytes},
        {"moreCountGetter", profile.moreCountGetterVA,
         profile.expectedMoreCountGetterBytes},
        {"nativeTitleFromUtf8", profile.nativeTitleFromUtf8VA,
         profile.expectedNativeTitleFromUtf8Bytes},
        {"moreTitleFormatGetter", profile.moreTitleFormatGetterVA,
         profile.expectedMoreTitleFormatGetterBytes},
        {"nativeTitleFormatter", profile.nativeTitleFormatterVA,
         profile.expectedNativeTitleFormatterBytes},
        {"nativeTitleDeallocate", profile.nativeTitleDeallocateVA,
         profile.expectedNativeTitleDeallocateBytes},
        {"moreTitleSetter", profile.moreTitleSetterVA,
         profile.expectedMoreTitleSetterBytes},
        {"postLayout", profile.postLayoutVA, profile.expectedPostLayoutBytes},
        {"clickSelectionInvoker", profile.clickSelectionInvokerVA,
         profile.expectedClickSelectionInvokerBytes},
        {"rowSelect", profile.rowSelectVA, profile.expectedRowSelectBytes},
        {"rowDeselect", profile.rowDeselectVA,
         profile.expectedRowDeselectBytes},
    }};
}

using YMNavigationSidebarProfileByteReader = bool (*)(
    void *context,
    uintptr_t address,
    uint8_t *destination,
    std::size_t length) noexcept;
using YMNavigationSidebarProfilePublishCallback = bool (*)(
    void *context) noexcept;

static inline bool YMNavigationSidebarVerifyProfileBytes(
    const YMNavigationSidebarBuildProfile &profile,
    YMNavigationSidebarProfileByteReader reader,
    void *readerContext) noexcept {
    if (!reader) {
        return false;
    }

    const auto targets = YMNavigationSidebarProfileTargets(profile);
    for (const YMNavigationSidebarProfileTarget &target : targets) {
        if (target.address == 0 || target.expectedBytes == nullptr) {
            return false;
        }

        std::array<uint8_t, 16> actualBytes{};
        if (!reader(readerContext,
                    target.address,
                    actualBytes.data(),
                    actualBytes.size())) {
            return false;
        }
        if (std::memcmp(actualBytes.data(),
                        target.expectedBytes,
                        actualBytes.size()) != 0) {
            return false;
        }
    }
    return true;
}

static inline bool YMNavigationSidebarVerifyProfileBytesAndPublish(
    const YMNavigationSidebarBuildProfile &profile,
    YMNavigationSidebarProfileByteReader reader,
    void *readerContext,
    YMNavigationSidebarProfilePublishCallback publish,
    void *publishContext) noexcept {
    if (!YMNavigationSidebarVerifyProfileBytes(profile, reader, readerContext)) {
        return false;
    }
    return publish == nullptr || publish(publishContext);
}

static inline bool YMNavigationSidebarProfileMatches(
    const YMNavigationSidebarBuildProfile &profile,
    const char *bundleIdentifier,
    const char *shortVersion,
    const char *buildVersion,
    const char *architecture) {
    if (!profile.bundleIdentifier || !profile.shortVersion ||
        !profile.buildVersion || !profile.architecture || !bundleIdentifier ||
        !shortVersion || !buildVersion || !architecture) {
        return false;
    }

    return std::strcmp(profile.bundleIdentifier, bundleIdentifier) == 0 &&
           std::strcmp(profile.shortVersion, shortVersion) == 0 &&
           std::strcmp(profile.buildVersion, buildVersion) == 0 &&
           std::strcmp(profile.architecture, architecture) == 0;
}

static inline bool YMNavigationSidebarProfileMatches(
    const YMNavigationSidebarBuildProfile &profile,
    const char *bundleIdentifier,
    const char *shortVersion,
    const char *buildVersion) {
    return YMNavigationSidebarProfileMatches(profile,
                                              bundleIdentifier,
                                              shortVersion,
                                              buildVersion,
                                              profile.architecture);
}

static inline void YMNavigationSidebarBuildAbsoluteJump(uintptr_t targetAddress,
                                                        uint8_t jump[16]) {
    const uint32_t loadTarget = 0x58000050;
    const uint32_t jumpTarget = 0xD61F0200;

    std::memcpy(jump, &loadTarget, sizeof(loadTarget));
    std::memcpy(jump + 4, &jumpTarget, sizeof(jumpTarget));
    std::memcpy(jump + 8, &targetAddress, sizeof(targetAddress));
}

static inline void YMNavigationSidebarBuildTrampoline(
    const uint8_t originalPrologue[16],
    uintptr_t continuationAddress,
    uint8_t trampoline[32]) {
    std::memcpy(trampoline, originalPrologue, 16);
    YMNavigationSidebarBuildAbsoluteJump(continuationAddress, trampoline + 16);
}

// ---- SidebarPatchTargetProfile ---------------------------------

struct YMSidebarPatchTargetProfile {
    const YMNavigationSidebarBuildProfile *sidebarProfile;
    uint8_t expectedSHA256[32];
    uintptr_t mainWindowOwnerOffset;
    uintptr_t componentSurfaceOffset;
};

struct YMSidebarPatchIdentity {
    const char *bundleIdentifier;
    const char *shortVersion;
    const char *buildVersion;
    const char *architecture;
};

static constexpr std::size_t kYMSidebarPatchInstallTargetCount = 6;
static constexpr std::size_t kYMSidebarPatchCallTargetCount =
    kYMNavigationSidebarBuildProfileTargetCount -
    kYMSidebarPatchInstallTargetCount;

static constexpr YMSidebarPatchTargetProfile
    YMSidebarPatchWeChat411TargetProfile = {
        &YMNavigationSidebarWeChat411BuildProfile,
        {
            // SidebarPatchIntegrity hashes the complete universal file.
            0x05, 0xc1, 0xa8, 0x8b, 0xa5, 0xc0, 0x2c, 0xcf,
            0x37, 0x0b, 0xc0, 0x1c, 0x0c, 0xc0, 0xeb, 0xc9,
            0xce, 0x4a, 0x72, 0x7f, 0x09, 0xe2, 0x94, 0x07,
            0xc7, 0x3e, 0x70, 0x4f, 0x8f, 0x8b, 0x2d, 0xf4,
        },
        0x2A0,
        0x180,
};

static constexpr YMSidebarPatchTargetProfile YMSidebarPatchWeChat420TargetProfile = {
    &YMNavigationSidebarWeChat420BuildProfile,
    {0xd6, 0x1e, 0xab, 0x4f, 0x61, 0x52, 0x39, 0x36, 0xf8, 0x4e, 0x3c, 0x98, 0xf5, 0x73, 0x95, 0xed, 0xb1, 0x5e, 0x45, 0xd3, 0xcd, 0x42, 0x91, 0xad, 0xb3, 0x63, 0xe4, 0x4e, 0x63, 0x37, 0x5c, 0x98},
    0x338, 0x170,
};

static inline bool YMSidebarPatchIdentityMatches(
    const YMSidebarPatchTargetProfile &profile,
    const YMSidebarPatchIdentity &identity) noexcept {
    return profile.sidebarProfile != nullptr &&
           YMNavigationSidebarProfileMatches(*profile.sidebarProfile,
                                             identity.bundleIdentifier,
                                             identity.shortVersion,
                                             identity.buildVersion,
                                             identity.architecture);
}

static inline const YMSidebarPatchTargetProfile *YMSidebarPatchProfileForIdentity(
    const YMSidebarPatchIdentity &identity) noexcept {
    for (const auto *profile : {&YMSidebarPatchWeChat411TargetProfile,
                               &YMSidebarPatchWeChat420TargetProfile}) {
        if (YMSidebarPatchIdentityMatches(*profile, identity)) return profile;
    }
    return nullptr;
}

static inline bool YMSidebarPatchDigestMatches(
    const YMSidebarPatchTargetProfile &profile,
    const uint8_t *digest,
    std::size_t digestSize) noexcept {
    return digest != nullptr && digestSize == sizeof(profile.expectedSHA256) &&
           std::memcmp(profile.expectedSHA256, digest, digestSize) == 0;
}

// ---- SidebarNativeTitle ----------------------------------------

namespace ym::sidebar::native_title {

struct alignas(8) Temporary final {
    void *data{nullptr};
};

static_assert(sizeof(Temporary) == 8);
static_assert(alignof(Temporary) == 8);

using FromUtf8 = void *(*)(const char *, std::size_t);
using FormatGetter = const char *(*)();
using Format = void (*)(Temporary *, const char *, std::uint64_t, void *);
using Deallocate = void (*)(void *, std::size_t, std::size_t);

struct Primitives {
    FromUtf8 fromUtf8{nullptr};
    FormatGetter formatGetter{nullptr};
    Format format{nullptr};
    void *formatter{nullptr};
    Deallocate deallocate{nullptr};

    [[nodiscard]] bool usable() const noexcept {
        return fromUtf8 != nullptr && formatGetter != nullptr &&
               format != nullptr && formatter != nullptr &&
               deallocate != nullptr;
    }
};

enum class PrepareError : std::uint8_t {
    none,
    missingPrimitive,
    constructionFailure,
    unshareableReference,
};

class PrepareResult;

class PreparedTitle final {
public:
    PreparedTitle(const PreparedTitle &) = delete;
    PreparedTitle &operator=(const PreparedTitle &) = delete;
    PreparedTitle &operator=(PreparedTitle &&) = delete;

    PreparedTitle(PreparedTitle &&other) noexcept
        : temporary_{std::exchange(other.temporary_.data, nullptr)},
          deallocate_(std::exchange(other.deallocate_, nullptr)),
          released_(std::exchange(other.released_, true)) {}

    ~PreparedTitle() { Release(); }

    [[nodiscard]] const Temporary &temporary() const noexcept {
        return temporary_;
    }

    [[nodiscard]] bool shareable() const noexcept {
        if (temporary_.data == nullptr || released_) {
            return false;
        }
        auto &refcount = *static_cast<std::int32_t *>(temporary_.data);
        const std::int32_t value =
            std::atomic_ref<std::int32_t>(refcount).load(
                std::memory_order_acquire);
        return value == -1 || value > 0;
    }

    [[nodiscard]] bool released() const noexcept { return released_; }

    void Release() noexcept {
        if (released_ || temporary_.data == nullptr) {
            released_ = true;
            temporary_.data = nullptr;
            return;
        }

        void *const data = temporary_.data;
        auto &refcount = *static_cast<std::int32_t *>(data);
        const std::int32_t observed =
            std::atomic_ref<std::int32_t>(refcount).load(
                std::memory_order_acquire);
        if (observed == 0) {
            deallocate_(data, 2, 8);
        } else if (observed != -1) {
            const std::int32_t previous =
                std::atomic_ref<std::int32_t>(refcount).fetch_sub(
                    1, std::memory_order_acq_rel);
            if (previous == 1) {
                deallocate_(data, 2, 8);
            }
        }
        temporary_.data = nullptr;
        released_ = true;
    }

private:
    PreparedTitle(Temporary temporary, Deallocate deallocate) noexcept
        : temporary_(temporary), deallocate_(deallocate) {}

    Temporary temporary_{};
    Deallocate deallocate_{nullptr};
    bool released_{false};

    friend class PrepareResult;
    friend PrepareResult Prepare(std::uint64_t, const Primitives &);
};

class PrepareResult final {
public:
    PrepareResult(const PrepareResult &) = delete;
    PrepareResult &operator=(const PrepareResult &) = delete;
    PrepareResult(PrepareResult &&) noexcept = default;
    PrepareResult &operator=(PrepareResult &&) = delete;

    [[nodiscard]] static PrepareResult Failure(PrepareError error) noexcept {
        return PrepareResult(error, std::nullopt);
    }

    [[nodiscard]] static PrepareResult Success(PreparedTitle title) noexcept {
        return PrepareResult(
            PrepareError::none,
            std::optional<PreparedTitle>(std::move(title)));
    }

    [[nodiscard]] bool succeeded() const noexcept {
        return error_ == PrepareError::none && title_.has_value();
    }

    [[nodiscard]] PrepareError error() const noexcept { return error_; }

    [[nodiscard]] PreparedTitle *title() noexcept {
        return title_ ? &*title_ : nullptr;
    }

    [[nodiscard]] const PreparedTitle *title() const noexcept {
        return title_ ? &*title_ : nullptr;
    }

private:
    PrepareResult(PrepareError error,
                  std::optional<PreparedTitle> title) noexcept
        : error_(error), title_(std::move(title)) {}

    PrepareError error_{PrepareError::constructionFailure};
    std::optional<PreparedTitle> title_;
};

[[nodiscard]] inline PrepareResult Prepare(
    std::uint64_t count,
    const Primitives &primitives) {
    if (!primitives.usable()) {
        return PrepareResult::Failure(PrepareError::missingPrimitive);
    }

    Temporary temporary;
    if (count == 0) {
        temporary.data = primitives.fromUtf8("", 0);
    } else {
        const char *const format = primitives.formatGetter();
        if (format == nullptr) {
            return PrepareResult::Failure(PrepareError::constructionFailure);
        }
        primitives.format(
            &temporary, format, count, primitives.formatter);
    }
    if (temporary.data == nullptr) {
        return PrepareResult::Failure(PrepareError::constructionFailure);
    }

    PreparedTitle prepared(temporary, primitives.deallocate);
    if (!prepared.shareable()) {
        prepared.Release();
        return PrepareResult::Failure(PrepareError::unshareableReference);
    }
    return PrepareResult::Success(std::move(prepared));
}

}

// ---- SidebarNativeRuntime --------------------------------------

namespace ym::sidebar::native_runtime {

using PrimaryOrder = std::array<Entry, 3>;
using SecondaryOrder = std::array<Entry, 5>;

inline constexpr PrimaryOrder kCanonicalPrimaryOrder =
    ym::sidebar::kCanonicalPrimaryOrder;
inline constexpr SecondaryOrder kCanonicalSecondaryOrder =
    ym::sidebar::kCanonicalSecondaryOrder;

struct NativeKey {
    Group group;
    int type;

    friend constexpr bool operator==(const NativeKey &,
                                     const NativeKey &) = default;
};

// 主组的原生 type 值恰好就是它的规范槽位下标（聊天 0、通讯录 1、收藏 2、
// 发现 3）。在原生顺序下，「读 slot[i] 里的 type」和「直接用下标 i」两种写法
// 结果完全一样，无法区分；一旦我们重排顺序表，两者就会分叉：位置 1 的格子写
// 着 type 2（收藏），而任何按下标推断类型的原生代码仍然认为那里是 type 1
// （通讯录），于是点收藏会选中通讯录。
//
// 因此主组只做显示开关，不重排顺序表。要真正支持主组排序，必须改为移动条目
// 视图本身，而不是改写顺序表 —— 那是另一套机制。二级组的 type 值（2/3/5/6/7）
// 与下标无关，不存在这个歧义，所以排序是安全的。
[[nodiscard]] constexpr NativeKey NativeKeyFor(Entry entry) noexcept {
    switch (entry) {
        case Entry::primaryChats:
            return {Group::primary, 0};
        case Entry::primaryContacts:
            return {Group::primary, 1};
        case Entry::primaryFavorites:
            return {Group::primary, 2};
        case Entry::secondaryMoments:
            return {Group::secondary, 2};
        case Entry::secondaryChannels:
            return {Group::secondary, 3};
        case Entry::secondarySearch:
            return {Group::secondary, 5};
        case Entry::secondaryGameCenter:
            return {Group::secondary, 7};
        case Entry::secondaryMiniPrograms:
            return {Group::secondary, 6};
        case Entry::primaryDiscover:
            return {Group::primary, 3};
    }
    return {Group::primary, -1};
}

[[nodiscard]] constexpr std::optional<Entry> EntryForNativeKey(
    Group group,
    int type) noexcept {
    if (group == Group::primary) {
        switch (type) {
            case 0:
                return Entry::primaryChats;
            case 1:
                return Entry::primaryContacts;
            case 2:
                return Entry::primaryFavorites;
            default:
                return std::nullopt;
        }
    }
    switch (type) {
        case 2:
            return Entry::secondaryMoments;
        case 3:
            return Entry::secondaryChannels;
        case 5:
            return Entry::secondarySearch;
        case 7:
            return Entry::secondaryGameCenter;
        case 6:
            return Entry::secondaryMiniPrograms;
        default:
            return std::nullopt;
    }
}

[[nodiscard]] constexpr std::size_t PrimaryIndex(Entry entry) noexcept {
    switch (entry) {
        case Entry::primaryChats:
            return 0;
        case Entry::primaryContacts:
            return 1;
        case Entry::primaryFavorites:
            return 2;
        default:
            return 3;
    }
}

[[nodiscard]] constexpr std::size_t SecondaryIndex(Entry entry) noexcept {
    switch (entry) {
        case Entry::secondaryMoments:
            return 0;
        case Entry::secondaryChannels:
            return 1;
        case Entry::secondarySearch:
            return 2;
        case Entry::secondaryGameCenter:
            return 3;
        case Entry::secondaryMiniPrograms:
            return 4;
        default:
            return 5;
    }
}

[[nodiscard]] constexpr bool IsValidPrimaryOrder(
    const PrimaryOrder &order) noexcept {
    std::array<bool, 3> seen{};
    for (Entry entry : order) {
        const std::size_t index = PrimaryIndex(entry);
        if (index == seen.size() || seen[index]) {
            return false;
        }
        seen[index] = true;
    }
    return true;
}

[[nodiscard]] constexpr bool IsValidSecondaryOrder(
    const SecondaryOrder &order) noexcept {
    std::array<bool, 5> seen{};
    for (Entry entry : order) {
        const std::size_t index = SecondaryIndex(entry);
        if (index == seen.size() || seen[index]) {
            return false;
        }
        seen[index] = true;
    }
    return true;
}

using NativeTypeReader = int (*)(const void *) noexcept;

[[nodiscard]] inline bool ReorderPrimaryGetterSlots(
    std::span<void *> slots,
    const PrimaryOrder &order,
    NativeTypeReader readType) noexcept {
    if (!IsValidPrimaryOrder(order) || readType == nullptr ||
        (slots.size() != 3 && slots.size() != 4)) {
        return false;
    }

    std::array<void *, 3> sortable{};
    std::array<bool, 3> seen{};
    void *discover = nullptr;
    for (std::size_t index = 0; index < slots.size(); ++index) {
        void *const slot = slots[index];
        if (slot == nullptr) {
            return false;
        }
        const int type = readType(slot);
        if (type == 3) {
            if (slots.size() != 4 || index != 3 || discover != nullptr) {
                return false;
            }
            discover = slot;
            continue;
        }
        const std::optional<Entry> entry =
            EntryForNativeKey(Group::primary, type);
        if (!entry.has_value()) {
            return false;
        }
        const std::size_t sortableIndex = PrimaryIndex(*entry);
        if (seen[sortableIndex]) {
            return false;
        }
        seen[sortableIndex] = true;
        sortable[sortableIndex] = slot;
    }
    for (bool wasSeen : seen) {
        if (!wasSeen) {
            return false;
        }
    }
    if (slots.size() == 4 && discover == nullptr) {
        return false;
    }

    for (std::size_t index = 0; index < order.size(); ++index) {
        slots[index] = sortable[PrimaryIndex(order[index])];
    }
    // 发现只在折叠模式下才会被微信追加进这张顺序表（0xE559CC 读 owner+0x210，
    // 不等于 1 就直接返回）。折叠是默认形态，此时四个槽；开了展开开关后
    // 只剩三个、discover 为空。两种都要支持，发现始终留在末位。
    if (discover != nullptr) {
        slots[3] = discover;
    }
    return true;
}

[[nodiscard]] inline bool ReorderSecondaryGetterSlots(
    std::span<void *> slots,
    const SecondaryOrder &order,
    NativeTypeReader readType) noexcept {
    if (!IsValidSecondaryOrder(order) || readType == nullptr ||
        slots.size() != 6) {
        return false;
    }

    std::array<void *, 5> sortable{};
    std::array<bool, 5> seen{};
    void *more = nullptr;
    for (std::size_t index = 0; index < slots.size(); ++index) {
        void *const slot = slots[index];
        if (slot == nullptr) {
            return false;
        }
        const int type = readType(slot);
        if (type == 8) {
            if (index != 5 || more != nullptr) {
                return false;
            }
            more = slot;
            continue;
        }
        const std::optional<Entry> entry =
            EntryForNativeKey(Group::secondary, type);
        if (!entry.has_value()) {
            return false;
        }
        const std::size_t sortableIndex = SecondaryIndex(*entry);
        if (seen[sortableIndex]) {
            return false;
        }
        seen[sortableIndex] = true;
        sortable[sortableIndex] = slot;
    }
    for (bool wasSeen : seen) {
        if (!wasSeen) {
            return false;
        }
    }
    if (more == nullptr) {
        return false;
    }

    for (std::size_t index = 0; index < order.size(); ++index) {
        slots[index] = sortable[SecondaryIndex(order[index])];
    }
    slots[5] = more;
    return true;
}

struct Orders {
    PrimaryOrder primary{kCanonicalPrimaryOrder};
    SecondaryOrder secondary{kCanonicalSecondaryOrder};

    friend constexpr bool operator==(const Orders &,
                                     const Orders &) = default;
};

class OwnerScopedAppliedSnapshot {
public:
    [[nodiscard]] bool SetDesiredOrders(const Orders &orders) noexcept {
        if (!IsValidPrimaryOrder(orders.primary) ||
            !IsValidSecondaryOrder(orders.secondary)) {
            return false;
        }
        desired_ = orders;
        return true;
    }

    [[nodiscard]] const Orders &DesiredOrders() const noexcept {
        return desired_;
    }

    [[nodiscard]] const Orders *CaptureApplied(const void *owner) noexcept {
        if (owner == nullptr) {
            return nullptr;
        }
        if (!hasOwner_ || owner_ != owner) {
            owner_ = owner;
            applied_ = desired_;
            hasOwner_ = true;
        }
        return &applied_;
    }

    [[nodiscard]] const Orders *AppliedOrders(
        const void *owner) const noexcept {
        if (!hasOwner_ || owner == nullptr || owner_ != owner) {
            return nullptr;
        }
        return &applied_;
    }

    void ClearOwner(const void *owner) noexcept {
        if (hasOwner_ && owner != nullptr && owner_ == owner) {
            owner_ = nullptr;
            hasOwner_ = false;
        }
    }

    [[nodiscard]] bool HasPendingOrder(const void *owner) const noexcept {
        const Orders *const applied = AppliedOrders(owner);
        return applied != nullptr && *applied != desired_;
    }

private:
    Orders desired_{};
    Orders applied_{};
    const void *owner_{nullptr};
    bool hasOwner_{false};
};

using PrimaryStates = std::array<bool, 3>;

enum class PrimaryFallbackAction : std::uint8_t {
    keepCurrent,
    selectFallback,
    rejectAllDisabled,
    invalidInput,
    // The currently-selected native primary is a valid slot we do not manage
    // (e.g. Discover / 发现). We never hide it, so no fallback selection is
    // needed: keep it selected and apply managed-primary visibility as usual.
    keepUnmanaged,
};

struct PrimaryFallbackDecision {
    PrimaryFallbackAction action{PrimaryFallbackAction::invalidInput};
    std::optional<Entry> target;
};

[[nodiscard]] constexpr PrimaryFallbackDecision ChoosePrimaryFallback(
    int currentNativeType,
    const PrimaryOrder &appliedOrder,
    const PrimaryStates &enabled) noexcept {
    if (!IsValidPrimaryOrder(appliedOrder)) {
        return {};
    }
    bool anyEnabled = false;
    for (bool state : enabled) {
        anyEnabled = anyEnabled || state;
    }
    if (!anyEnabled) {
        return {PrimaryFallbackAction::rejectAllDisabled, std::nullopt};
    }
    const std::optional<Entry> current =
        EntryForNativeKey(Group::primary, currentNativeType);
    if (!current.has_value()) {
        // A valid native primary slot we do not manage (e.g. Discover / 发现)
        // is selected. We never hide it, so no fallback is required: keep it
        // selected and apply managed-primary visibility as usual.
        return {PrimaryFallbackAction::keepUnmanaged, std::nullopt};
    }
    if (enabled[PrimaryIndex(*current)]) {
        return {PrimaryFallbackAction::keepCurrent, current};
    }
    for (Entry entry : appliedOrder) {
        if (enabled[PrimaryIndex(entry)]) {
            return {PrimaryFallbackAction::selectFallback, entry};
        }
    }
    return {PrimaryFallbackAction::rejectAllDisabled, std::nullopt};
}

struct SecondaryEntryState {
    bool enabled;
    bool available;
    bool present;

    friend constexpr bool operator==(const SecondaryEntryState &,
                                     const SecondaryEntryState &) = default;
};

using SecondaryStates = std::array<SecondaryEntryState, 5>;

struct SecondaryProjection {
    std::array<Entry, 5> direct{};
    std::size_t directCount{0};
    std::array<Entry, 5> overflow{};
    std::size_t overflowCount{0};
    bool moreVisible{false};

    friend constexpr bool operator==(const SecondaryProjection &,
                                     const SecondaryProjection &) = default;
};

[[nodiscard]] constexpr bool ProjectSecondary(
    const SecondaryOrder &appliedOrder,
    std::size_t directCapacity,
    const SecondaryStates &states,
    SecondaryProjection &output) noexcept {
    if (!IsValidSecondaryOrder(appliedOrder) || directCapacity > 5) {
        return false;
    }

    SecondaryProjection projected{};
    for (Entry entry : appliedOrder) {
        const SecondaryEntryState &state = states[SecondaryIndex(entry)];
        if (!state.enabled || !state.available || !state.present) {
            continue;
        }
        if (projected.directCount < directCapacity) {
            projected.direct[projected.directCount++] = entry;
        } else {
            projected.overflow[projected.overflowCount++] = entry;
        }
    }
    projected.moreVisible = projected.overflowCount != 0;
    output = projected;
    return true;
}

}

// ---- SidebarNativeAdapter --------------------------------------

namespace ym::sidebar::native_adapter {

inline constexpr std::uintptr_t kHolderSlotsOffset = 0x10;
inline constexpr std::size_t kNativeSlotSize = 8;
inline constexpr std::size_t kPatchPrologueSize = 16;

struct SlotWindow {
    std::uintptr_t address{0};
    std::size_t count{0};

    friend constexpr bool operator==(const SlotWindow &,
                                     const SlotWindow &) = default;
};

[[nodiscard]] constexpr std::optional<Entry>
EntryForLegacySecondaryType(int type) noexcept {
    return native_runtime::EntryForNativeKey(Group::secondary, type);
}

class OwnerOrderAvailability {
public:
    [[nodiscard]] bool Capture(const void *owner) noexcept {
        if (owner == nullptr || owner_ == owner) {
            return false;
        }
        owner_ = owner;
        primary_ = false;
        secondary_ = false;
        return true;
    }

    [[nodiscard]] bool Set(const void *owner,
                           Group group,
                           bool available) noexcept {
        if (owner == nullptr || owner_ != owner) {
            return false;
        }
        bool &slot = group == Group::primary ? primary_ : secondary_;
        const bool changed = slot != available;
        slot = available;
        return changed;
    }

    [[nodiscard]] bool Ready(const void *owner) const noexcept {
        return owner != nullptr && owner_ == owner && primary_ && secondary_;
    }

    void Clear(const void *owner) noexcept {
        if (owner_ != owner) {
            return;
        }
        owner_ = nullptr;
        primary_ = false;
        secondary_ = false;
    }

private:
    const void *owner_{nullptr};
    bool primary_{false};
    bool secondary_{false};
};

[[nodiscard]] constexpr bool ComputeSlotWindow(
    std::uintptr_t holderAddress,
    std::int32_t begin,
    std::int32_t end,
    std::size_t minimumCount,
    std::size_t maximumCount,
    SlotWindow &output) noexcept {
    if (holderAddress == 0 || begin < 0 || end < 0 || end < begin ||
        minimumCount > maximumCount) {
        return false;
    }

    const std::uint64_t count =
        static_cast<std::uint64_t>(static_cast<std::int64_t>(end) - begin);
    if (count < minimumCount || count > maximumCount) {
        return false;
    }

    constexpr std::uintptr_t maximum =
        std::numeric_limits<std::uintptr_t>::max();
    if (holderAddress > maximum - kHolderSlotsOffset) {
        return false;
    }
    const std::uintptr_t slotsBase = holderAddress + kHolderSlotsOffset;
    const std::uint64_t maximumIndex =
        (maximum - slotsBase) / kNativeSlotSize;
    if (static_cast<std::uint64_t>(begin) > maximumIndex ||
        static_cast<std::uint64_t>(end) > maximumIndex) {
        return false;
    }

    const std::uintptr_t address =
        slotsBase + static_cast<std::uintptr_t>(begin) * kNativeSlotSize;
    if ((address % alignof(void *)) != 0) {
        return false;
    }

    output = {address, static_cast<std::size_t>(count)};
    return true;
}

[[nodiscard]] inline bool ParseHolderSlots(
    void *holder,
    std::size_t minimumCount,
    std::size_t maximumCount,
    std::span<void *> &output) noexcept {
    if (holder == nullptr) {
        return false;
    }

    std::int32_t begin = 0;
    std::int32_t end = 0;
    const auto *bytes = static_cast<const std::byte *>(holder);
    std::memcpy(&begin, bytes + 0x08, sizeof(begin));
    std::memcpy(&end, bytes + 0x0c, sizeof(end));

    SlotWindow window{};
    if (!ComputeSlotWindow(reinterpret_cast<std::uintptr_t>(holder),
                           begin,
                           end,
                           minimumCount,
                           maximumCount,
                           window)) {
        return false;
    }
    output = {reinterpret_cast<void **>(window.address), window.count};
    return true;
}

[[nodiscard]] inline bool ParseGetterSlots(
    void *resultStorage,
    Group group,
    std::span<void *> &output) noexcept {
    if (resultStorage == nullptr) {
        return false;
    }

    void *holder = nullptr;
    std::memcpy(&holder, resultStorage, sizeof(holder));
    if (group == Group::primary) {
        return ParseHolderSlots(holder, 3, 4, output);
    }
    if (group == Group::secondary) {
        return ParseHolderSlots(holder, 6, 6, output);
    }
    return false;
}

[[nodiscard]] inline bool ReorderGetterResult(
    void *resultStorage,
    Group group,
    const native_runtime::Orders &orders,
    native_runtime::NativeTypeReader readType) noexcept {
    std::span<void *> slots;
    if (!ParseGetterSlots(resultStorage, group, slots)) {
        return false;
    }
    if (group == Group::primary) {
        return native_runtime::ReorderPrimaryGetterSlots(
            slots, orders.primary, readType);
    }
    return native_runtime::ReorderSecondaryGetterSlots(
        slots, orders.secondary, readType);
}

// owner+0x218 存的不是内联 holder，而是指向 holder 的指针：overflowClear
// (0xE59BF4) 与 overflowAppend (0xE59D08) 反汇编均以 ldr xN, [x0] 解引用
// 参数拿到 holder——clear 把字段重置回共享的空 holder 单例并给旧 holder
// 减引用计数，append 按需重新分配 holder（所以两次读取之间指针可能变化）。
// holder 布局与 getter 结果一致：+0x00 引用计数，+0x08/+0x0c 为
// begin/end（int32 对），+0x10 起是内联槽位。
[[nodiscard]] inline bool ParseOverflowSlots(
    void *overflowField,
    std::span<void *> &output) noexcept {
    if (overflowField == nullptr) {
        return false;
    }
    void *holder = nullptr;
    std::memcpy(&holder, overflowField, sizeof(holder));
    return ParseHolderSlots(holder, 0, 5, output);
}

[[nodiscard]] inline bool DeriveDirectCapacity(
    const std::array<int, 5> &filteredTypes,
    std::size_t filteredCount,
    std::span<void *const> overflowSlots,
    native_runtime::NativeTypeReader readType,
    std::size_t &output) noexcept {
    if (filteredCount > filteredTypes.size() ||
        overflowSlots.size() > filteredCount || readType == nullptr) {
        return false;
    }

    std::array<bool, 5> filtered{};
    for (std::size_t index = 0; index < filteredCount; ++index) {
        const std::optional<Entry> entry =
            native_runtime::EntryForNativeKey(
                Group::secondary, filteredTypes[index]);
        if (!entry.has_value()) {
            return false;
        }
        const std::size_t nativeIndex = native_runtime::SecondaryIndex(*entry);
        if (nativeIndex == filtered.size() || filtered[nativeIndex]) {
            return false;
        }
        filtered[nativeIndex] = true;
    }

    std::array<bool, 5> overflowSeen{};
    for (void *slot : overflowSlots) {
        if (slot == nullptr) {
            return false;
        }
        const std::optional<Entry> entry =
            native_runtime::EntryForNativeKey(
                Group::secondary, readType(slot));
        if (!entry.has_value()) {
            return false;
        }
        const std::size_t nativeIndex = native_runtime::SecondaryIndex(*entry);
        if (nativeIndex == overflowSeen.size() || !filtered[nativeIndex] ||
            overflowSeen[nativeIndex]) {
            return false;
        }
        overflowSeen[nativeIndex] = true;
    }

    output = filteredCount - overflowSlots.size();
    return true;
}

[[nodiscard]] constexpr bool ProgramCounterInPatchPrologue(
    std::uintptr_t programCounter,
    std::uintptr_t target) noexcept {
    constexpr std::uintptr_t maximum =
        std::numeric_limits<std::uintptr_t>::max();
    if (target > maximum - kPatchPrologueSize) {
        return false;
    }
    return programCounter >= target &&
           programCounter < target + kPatchPrologueSize;
}

}

// ---- SidebarPersistence ----------------------------------------

namespace ym::sidebar::persistence {

inline constexpr std::string_view kAuthoritativeKey =
    "YMNavigationSidebarConfigurationV2.SOVIET";
inline constexpr std::string_view kLegacyChatFilesKey =
    "YMNavigationSidebarChatFilesEnabled.SOVIET";

enum class SaveErrorCode : std::uint8_t {
    none,
    invalidAdapter,
    invalidInput,
    allPrimaryDisabled,
    readFailure,
    writeFailure,
    synchronizeFailure,
    readbackFailure,
    readbackMissing,
    readbackMalformed,
    semanticMismatch,
};

enum class RollbackErrorCode : std::uint8_t {
    none,
    writeFailure,
    synchronizeFailure,
    writeAndSynchronizeFailure,
    readbackFailure,
    stateMismatch,
};

struct SaveResult {
    SaveErrorCode primaryError{SaveErrorCode::none};
    RollbackErrorCode rollback{RollbackErrorCode::none};
    std::optional<ValidationError> validation;
    bool wasNoOp{false};
    bool rollbackAttempted{false};

    [[nodiscard]] bool succeeded() const noexcept {
        return primaryError == SaveErrorCode::none;
    }

    [[nodiscard]] bool noOp() const noexcept { return wasNoOp; }

    [[nodiscard]] bool rollbackSucceeded() const noexcept {
        return rollbackAttempted && rollback == RollbackErrorCode::none;
    }

    [[nodiscard]] SaveErrorCode error() const noexcept { return primaryError; }

    [[nodiscard]] SaveErrorCode primaryFailure() const noexcept {
        return primaryError;
    }

    [[nodiscard]] RollbackErrorCode rollbackError() const noexcept {
        return rollback;
    }

    [[nodiscard]] const ValidationError *validationError() const noexcept {
        return validation ? &*validation : nullptr;
    }
};

struct StorageAdapter {
    using ReadV2 = bool (*)(void *, std::string_view,
                            std::optional<PropertyList> &) noexcept;
    using WriteV2 = bool (*)(void *, std::string_view,
                             const PropertyList &) noexcept;
    using RemoveV2 = bool (*)(void *, std::string_view) noexcept;
    using Synchronize = bool (*)(void *) noexcept;

    void *context{nullptr};
    ReadV2 readV2{nullptr};
    WriteV2 writeV2{nullptr};
    RemoveV2 removeV2{nullptr};
    Synchronize synchronize{nullptr};

    [[nodiscard]] bool usable() const noexcept {
        return readV2 != nullptr && writeV2 != nullptr &&
               removeV2 != nullptr && synchronize != nullptr;
    }
};

namespace detail {

inline RollbackErrorCode RestorePrior(
    const StorageAdapter &storage,
    const std::optional<PropertyList> &prior) noexcept {
    const bool restored = prior.has_value()
                              ? storage.writeV2(storage.context, kAuthoritativeKey,
                                                *prior)
                              : storage.removeV2(storage.context, kAuthoritativeKey);
    const bool synchronized = storage.synchronize(storage.context);
    if (!restored && !synchronized) {
        return RollbackErrorCode::writeAndSynchronizeFailure;
    }
    if (!restored) {
        return RollbackErrorCode::writeFailure;
    }
    if (!synchronized) {
        return RollbackErrorCode::synchronizeFailure;
    }

    std::optional<PropertyList> observed;
    if (!storage.readV2(storage.context, kAuthoritativeKey, observed)) {
        return RollbackErrorCode::readbackFailure;
    }
    if (observed != prior) {
        return RollbackErrorCode::stateMismatch;
    }
    return RollbackErrorCode::none;
}

inline SaveResult Failed(SaveErrorCode primary,
                         const std::optional<PropertyList> &prior,
                         const StorageAdapter *storage) {
    SaveResult result;
    result.primaryError = primary;
    if (storage != nullptr) {
        result.rollbackAttempted = true;
        result.rollback = RestorePrior(*storage, prior);
    }
    return result;
}

inline SaveErrorCode MapValidationErrorCode(
    ValidationErrorCode code) noexcept {
    switch (code) {
        case ValidationErrorCode::allPrimaryDisabled:
            return SaveErrorCode::allPrimaryDisabled;
        case ValidationErrorCode::unsupportedVersion:
        case ValidationErrorCode::unknownStateIdentifier:
        case ValidationErrorCode::missingState:
        case ValidationErrorCode::unknownOrderIdentifier:
        case ValidationErrorCode::duplicateOrderIdentifier:
        case ValidationErrorCode::crossGroupIdentifier:
        case ValidationErrorCode::nonSortableIdentifier:
        case ValidationErrorCode::incompleteOrder:
            return SaveErrorCode::invalidInput;
    }
    return SaveErrorCode::invalidInput;
}

}

[[nodiscard]] inline SaveResult Save(const StorageAdapter &storage,
                                     const PropertyList &input) {
    const ValidationResult validated = ValidateSaveInput(input);
    if (validated.configuration() == nullptr) {
        SaveResult result;
        if (validated.error() != nullptr) {
            result.primaryError =
                detail::MapValidationErrorCode(validated.error()->code);
            result.validation = *validated.error();
        } else {
            result.primaryError = SaveErrorCode::invalidInput;
        }
        return result;
    }

    const Configuration &configuration = *validated.configuration();
    if (!storage.usable()) {
        SaveResult result;
        result.primaryError = SaveErrorCode::invalidAdapter;
        return result;
    }

    const PropertyList desired = ToPropertyList(configuration);
    std::optional<PropertyList> prior;
    if (!storage.readV2(storage.context, kAuthoritativeKey, prior)) {
        SaveResult result;
        result.primaryError = SaveErrorCode::readFailure;
        return result;
    }

    if (prior.has_value() && *prior == desired) {
        SaveResult result;
        result.wasNoOp = true;
        return result;
    }

    if (!storage.writeV2(storage.context, kAuthoritativeKey, desired)) {
        return detail::Failed(SaveErrorCode::writeFailure, prior, &storage);
    }
    if (!storage.synchronize(storage.context)) {
        return detail::Failed(SaveErrorCode::synchronizeFailure, prior, &storage);
    }

    std::optional<PropertyList> readback;
    if (!storage.readV2(storage.context, kAuthoritativeKey, readback)) {
        return detail::Failed(SaveErrorCode::readbackFailure, prior, &storage);
    }
    if (!readback.has_value()) {
        return detail::Failed(SaveErrorCode::readbackMissing, prior, &storage);
    }

    const ValidationResult parsed = ValidateSaveInput(*readback);
    if (parsed.configuration() == nullptr) {
        SaveResult result =
            detail::Failed(SaveErrorCode::readbackMalformed, prior, &storage);
        if (parsed.error() != nullptr) {
            result.validation = *parsed.error();
        }
        return result;
    }
    if (*parsed.configuration() != configuration) {
        return detail::Failed(SaveErrorCode::semanticMismatch, prior, &storage);
    }

    return {};
}

[[nodiscard]] inline ValidationResult LoadV2OrLegacy(
    const std::optional<PropertyList> &storedV2,
    const LegacyVisibility &legacy) {
    return LoadConfiguration(storedV2, legacy);
}

}

// ---- SidebarManagerOrchestration -------------------------------

namespace ym::sidebar::manager_orchestration {

[[nodiscard]] inline bool ConfigurationOrders(
    const Configuration &configuration,
    native_runtime::Orders &output) noexcept {
    native_runtime::Orders orders;
    if (configuration.primaryOrder.size() != orders.primary.size() ||
        configuration.secondaryOrder.size() != orders.secondary.size()) {
        return false;
    }
    for (std::size_t index = 0; index < orders.primary.size(); ++index) {
        orders.primary[index] = configuration.primaryOrder[index];
    }
    for (std::size_t index = 0; index < orders.secondary.size(); ++index) {
        orders.secondary[index] = configuration.secondaryOrder[index];
    }
    if (!native_runtime::IsValidPrimaryOrder(orders.primary) ||
        !native_runtime::IsValidSecondaryOrder(orders.secondary)) {
        return false;
    }
    output = orders;
    return true;
}

struct PrimaryItem {
    int type{-1};
    std::uintptr_t identity{0};
};

struct SaveRequest {
    PropertyList input;
    std::uintptr_t owner{0};
    native_runtime::PrimaryOrder appliedPrimary{};
    std::array<PrimaryItem, 3> items{};
};

struct SaveOperations {
    using ReadSelected = bool (*)(void *, std::uintptr_t, int *) noexcept;
    using ReadPublished = bool (*)(void *, Configuration *,
                                   native_runtime::Orders *) noexcept;
    using SelectPrimary = void (*)(void *, std::uintptr_t, int) noexcept;
    using SetVisible = void (*)(void *, std::uintptr_t, bool) noexcept;
    using Publish = void (*)(void *, const Configuration &,
                             const native_runtime::Orders &) noexcept;
    using ScheduleLayout = bool (*)(void *, std::uintptr_t) noexcept;

    void *context{nullptr};
    ReadSelected readSelected{nullptr};
    ReadPublished readPublished{nullptr};
    SelectPrimary selectPrimary{nullptr};
    SetVisible setVisible{nullptr};
    Publish publish{nullptr};
    ScheduleLayout scheduleLayout{nullptr};
};

enum class SaveError : std::uint8_t {
    none,
    invalidInput,
    invalidOperations,
    invalidOwnerState,
    primaryFallback,
    selectionRestore,
    persistence,
    secondaryApply,
    secondaryRollback,
};

class SaveResult final {
public:
    [[nodiscard]] bool succeeded() const noexcept {
        return error_ == SaveError::none;
    }

    [[nodiscard]] SaveError error() const noexcept { return error_; }

    [[nodiscard]] const persistence::SaveResult &persistenceResult()
        const noexcept {
        return persistence_;
    }

    [[nodiscard]] const ValidationError *validationError() const noexcept {
        return validation_ ? &*validation_ : nullptr;
    }

    [[nodiscard]] bool selectionRestoreAttempted() const noexcept {
        return selectionRestoreAttempted_;
    }

    [[nodiscard]] bool selectionRestored() const noexcept {
        return selectionRestored_;
    }

private:
    SaveError error_{SaveError::none};
    persistence::SaveResult persistence_{};
    std::optional<ValidationError> validation_;
    bool selectionRestoreAttempted_{false};
    bool selectionRestored_{false};

    friend SaveResult PerformSave(const SaveRequest &,
                                  const persistence::StorageAdapter &,
                                  const SaveOperations &);
};

namespace detail {

[[nodiscard]] inline bool ValidatePrimaryItems(
    const SaveRequest &request) noexcept {
    if (!native_runtime::IsValidPrimaryOrder(request.appliedPrimary)) {
        return false;
    }
    std::array<std::uintptr_t, 3> identities{};
    for (std::size_t index = 0; index < request.items.size(); ++index) {
        const int expected = native_runtime::NativeKeyFor(
            native_runtime::kCanonicalPrimaryOrder[index]).type;
        const PrimaryItem &item = request.items[index];
        if (item.type != expected || item.identity == 0 ||
            !native_runtime::EntryForNativeKey(Group::primary, item.type)
                 .has_value()) {
            return false;
        }
        for (std::size_t previous = 0; previous < index; ++previous) {
            if (identities[previous] == item.identity) {
                return false;
            }
        }
        identities[index] = item.identity;
    }
    return true;
}

[[nodiscard]] inline bool RestoreSelection(
    const SaveOperations &operations,
    std::uintptr_t owner,
    int originalType) noexcept {
    operations.selectPrimary(operations.context, owner, originalType);
    int observed = -1;
    return operations.readSelected(operations.context, owner, &observed) &&
           observed == originalType;
}

}

[[nodiscard]] inline SaveResult PerformSave(
    const SaveRequest &request,
    const persistence::StorageAdapter &storage,
    const SaveOperations &operations) {
    SaveResult result;
    const ValidationResult validated = ValidateSaveInput(request.input);
    if (validated.configuration() == nullptr) {
        result.error_ = SaveError::invalidInput;
        if (validated.error() != nullptr) {
            result.validation_ = *validated.error();
        }
        return result;
    }

    native_runtime::Orders desiredOrders;
    if (!ConfigurationOrders(*validated.configuration(), desiredOrders)) {
        result.error_ = SaveError::invalidInput;
        return result;
    }
    if (!storage.usable() || operations.publish == nullptr) {
        result.error_ = SaveError::invalidOperations;
        return result;
    }
    const bool hasOwner = request.owner != 0;
    if (hasOwner &&
        (!detail::ValidatePrimaryItems(request) ||
         operations.readSelected == nullptr ||
         operations.readPublished == nullptr ||
         operations.selectPrimary == nullptr ||
         operations.setVisible == nullptr ||
         operations.scheduleLayout == nullptr)) {
        result.error_ = SaveError::invalidOperations;
        return result;
    }

    std::optional<PropertyList> priorStored;
    Configuration priorPublished;
    native_runtime::Orders priorPublishedOrders;
    int originalSelected = -1;
    bool selectionChanged = false;
    if (hasOwner) {
        if (!operations.readSelected(
                operations.context, request.owner, &originalSelected)) {
            result.error_ = SaveError::invalidOwnerState;
            return result;
        }
        native_runtime::PrimaryStates states{};
        for (Entry entry : native_runtime::kCanonicalPrimaryOrder) {
            states[native_runtime::PrimaryIndex(entry)] =
                validated.configuration()->isEnabled(entry);
        }
        const native_runtime::PrimaryFallbackDecision fallback =
            native_runtime::ChoosePrimaryFallback(
                originalSelected, request.appliedPrimary, states);
        if (fallback.action ==
                native_runtime::PrimaryFallbackAction::invalidInput ||
            fallback.action ==
                native_runtime::PrimaryFallbackAction::rejectAllDisabled ||
            (fallback.action !=
                 native_runtime::PrimaryFallbackAction::keepUnmanaged &&
             !fallback.target.has_value())) {
            result.error_ = SaveError::primaryFallback;
            return result;
        }
        if (fallback.action ==
            native_runtime::PrimaryFallbackAction::selectFallback) {
            const int targetType =
                native_runtime::NativeKeyFor(*fallback.target).type;
            operations.selectPrimary(
                operations.context, request.owner, targetType);
            selectionChanged = true;
            int observed = -1;
            if (!operations.readSelected(
                    operations.context, request.owner, &observed) ||
                observed != targetType) {
                result.selectionRestoreAttempted_ = true;
                result.selectionRestored_ = detail::RestoreSelection(
                    operations, request.owner, originalSelected);
                result.error_ = result.selectionRestored_
                                    ? SaveError::primaryFallback
                                    : SaveError::selectionRestore;
                return result;
            }
        }
    }

    if (hasOwner &&
        !storage.readV2(
            storage.context, persistence::kAuthoritativeKey, priorStored)) {
        if (selectionChanged) {
            result.selectionRestoreAttempted_ = true;
            result.selectionRestored_ = detail::RestoreSelection(
                operations, request.owner, originalSelected);
        }
        result.persistence_.primaryError =
            persistence::SaveErrorCode::readFailure;
        result.error_ = result.selectionRestoreAttempted_ &&
                                !result.selectionRestored_
                            ? SaveError::selectionRestore
                            : SaveError::persistence;
        return result;
    }
    if (hasOwner &&
        !operations.readPublished(
            operations.context, &priorPublished, &priorPublishedOrders)) {
        if (selectionChanged) {
            result.selectionRestoreAttempted_ = true;
            result.selectionRestored_ = detail::RestoreSelection(
                operations, request.owner, originalSelected);
        }
        result.error_ = result.selectionRestoreAttempted_ &&
                                !result.selectionRestored_
                            ? SaveError::selectionRestore
                            : SaveError::invalidOwnerState;
        return result;
    }

    result.persistence_ = persistence::Save(storage, request.input);
    if (!result.persistence_.succeeded()) {
        if (selectionChanged) {
            result.selectionRestoreAttempted_ = true;
            result.selectionRestored_ = detail::RestoreSelection(
                operations, request.owner, originalSelected);
        }
        result.error_ = result.selectionRestoreAttempted_ &&
                                !result.selectionRestored_
                            ? SaveError::selectionRestore
                            : SaveError::persistence;
        return result;
    }

    const Configuration &desired = *validated.configuration();
    operations.publish(operations.context, desired, desiredOrders);
    if (!hasOwner) {
        return result;
    }

    if (!operations.scheduleLayout(operations.context, request.owner)) {
        result.persistence_.rollbackAttempted = true;
        result.persistence_.rollback =
            persistence::detail::RestorePrior(storage, priorStored);

        operations.publish(
            operations.context, priorPublished, priorPublishedOrders);
        Configuration observedPublished;
        native_runtime::Orders observedPublishedOrders;
        const bool publicationRestored = operations.readPublished(
            operations.context, &observedPublished, &observedPublishedOrders) &&
            observedPublished == priorPublished &&
            observedPublishedOrders == priorPublishedOrders;

        const bool liveLayoutRestored = operations.scheduleLayout(
            operations.context, request.owner);

        result.selectionRestoreAttempted_ = selectionChanged;
        result.selectionRestored_ =
            selectionChanged
                ? detail::RestoreSelection(
                      operations, request.owner, originalSelected)
                : [&]() noexcept {
                      int observed = -1;
                      return operations.readSelected(
                                 operations.context, request.owner, &observed) &&
                             observed == originalSelected;
                  }();
        result.error_ = result.persistence_.rollbackSucceeded() &&
                                publicationRestored &&
                                liveLayoutRestored &&
                                result.selectionRestored_
                            ? SaveError::secondaryApply
                            : SaveError::secondaryRollback;
        return result;
    }
    for (std::size_t index = 0; index < request.items.size(); ++index) {
        const Entry entry = native_runtime::kCanonicalPrimaryOrder[index];
        if (desired.isEnabled(entry)) {
            operations.setVisible(
                operations.context, request.items[index].identity, true);
        }
    }
    for (std::size_t index = 0; index < request.items.size(); ++index) {
        const Entry entry = native_runtime::kCanonicalPrimaryOrder[index];
        if (!desired.isEnabled(entry)) {
            operations.setVisible(
                operations.context, request.items[index].identity, false);
        }
    }
    return result;
}

struct SecondaryItem {
    int type{-1};
    std::uintptr_t identity{0};
    bool enabled{false};
    bool available{false};
};

struct OverflowItem {
    int type{-1};
    std::uintptr_t identity{0};
};

struct SecondaryRequest {
    std::uintptr_t owner{0};
    native_runtime::SecondaryOrder appliedOrder{};
    std::array<SecondaryItem, 5> items{};
    std::array<OverflowItem, 5> overflow{};
    std::size_t overflowCount{0};
    std::uintptr_t moreItem{0};
};

struct SecondaryOperations {
    using ReadBadge = bool (*)(void *, std::uintptr_t, unsigned int *) noexcept;
    using ClearOverflow = void (*)(void *, std::uintptr_t) noexcept;
    using SetVisible = void (*)(void *, std::uintptr_t, bool) noexcept;
    using AppendOverflow = void (*)(void *, std::uintptr_t, int) noexcept;
    using PublishMoreVisibility = void (*)(void *, std::uintptr_t, bool) noexcept;
    using SetBadge = void (*)(void *, std::uintptr_t, unsigned int) noexcept;
    using SetTitle = void (*)(void *, std::uintptr_t,
                              const native_title::Temporary *) noexcept;
    using PostLayout = void (*)(void *, std::uintptr_t) noexcept;

    void *context{nullptr};
    ReadBadge readBadge{nullptr};
    ClearOverflow clearOverflow{nullptr};
    SetVisible setVisible{nullptr};
    AppendOverflow appendOverflow{nullptr};
    PublishMoreVisibility publishMoreVisibility{nullptr};
    SetBadge setBadge{nullptr};
    SetTitle setTitle{nullptr};
    PostLayout postLayout{nullptr};
    native_title::Primitives title{};

    [[nodiscard]] bool usable() const noexcept {
        return readBadge != nullptr && clearOverflow != nullptr &&
               setVisible != nullptr && appendOverflow != nullptr &&
               publishMoreVisibility != nullptr && setBadge != nullptr &&
               setTitle != nullptr && postLayout != nullptr && title.usable();
    }
};

enum class SecondaryError : std::uint8_t {
    none,
    invalidOperations,
    invalidInput,
    invalidNativeIdentity,
    invalidCapacity,
    badgeRead,
    titleConstruction,
};

class SecondaryResult final {
public:
    [[nodiscard]] bool succeeded() const noexcept {
        return error_ == SecondaryError::none;
    }

    [[nodiscard]] SecondaryError error() const noexcept { return error_; }

    [[nodiscard]] std::size_t directCapacity() const noexcept {
        return directCapacity_;
    }

    [[nodiscard]] unsigned int badgeCount() const noexcept {
        return badgeCount_;
    }

    [[nodiscard]] const native_runtime::SecondaryProjection &projection()
        const noexcept {
        return projection_;
    }

private:
    SecondaryError error_{SecondaryError::none};
    std::size_t directCapacity_{0};
    unsigned int badgeCount_{0};
    native_runtime::SecondaryProjection projection_{};

    friend SecondaryResult ApplySecondaryProjection(
        const SecondaryRequest &, const SecondaryOperations &);
};

[[nodiscard]] inline SecondaryResult ApplySecondaryProjection(
    const SecondaryRequest &request,
    const SecondaryOperations &operations) {
    SecondaryResult result;
    if (!operations.usable()) {
        result.error_ = SecondaryError::invalidOperations;
        return result;
    }
    if (request.owner == 0 ||
        request.overflowCount > request.overflow.size() ||
        !native_runtime::IsValidSecondaryOrder(request.appliedOrder)) {
        result.error_ = SecondaryError::invalidInput;
        return result;
    }
    // WeChat only instantiates the type-8 "More" sentinel when the sidebar
    // overflows. When it is absent (moreItem == 0) there is no overflow surface,
    // so a request that still carries overflow items cannot be honored.
    const bool hasMore = request.moreItem != 0;
    if (!hasMore && request.overflowCount != 0) {
        result.error_ = SecondaryError::invalidInput;
        return result;
    }

    native_runtime::SecondaryStates states{};
    std::array<bool, 5> filtered{};
    std::size_t filteredCount = 0;
    for (std::size_t index = 0; index < request.items.size(); ++index) {
        const Entry expectedEntry = native_runtime::kCanonicalSecondaryOrder[index];
        const int expectedType = native_runtime::NativeKeyFor(expectedEntry).type;
        const SecondaryItem &item = request.items[index];
        if (item.type != expectedType ||
            !native_runtime::EntryForNativeKey(Group::secondary, item.type)
                 .has_value()) {
            result.error_ = SecondaryError::invalidNativeIdentity;
            return result;
        }
        if (item.identity != 0) {
            if (item.identity == request.moreItem) {
                result.error_ = SecondaryError::invalidNativeIdentity;
                return result;
            }
            for (std::size_t previous = 0; previous < index; ++previous) {
                if (request.items[previous].identity == item.identity) {
                    result.error_ = SecondaryError::invalidNativeIdentity;
                    return result;
                }
            }
        }
        states[index] = {
            item.enabled,
            item.available,
            item.identity != 0,
        };
        filtered[index] = item.enabled && item.available && item.identity != 0;
        filteredCount += filtered[index] ? 1u : 0u;
    }
    if (request.overflowCount > filteredCount) {
        result.error_ = SecondaryError::invalidCapacity;
        return result;
    }

    std::array<bool, 5> overflowSeen{};
    for (std::size_t index = 0; index < request.overflowCount; ++index) {
        const OverflowItem &overflow = request.overflow[index];
        const std::optional<Entry> entry =
            native_runtime::EntryForNativeKey(Group::secondary, overflow.type);
        if (!entry.has_value()) {
            result.error_ = SecondaryError::invalidNativeIdentity;
            return result;
        }
        const std::size_t itemIndex = native_runtime::SecondaryIndex(*entry);
        if (itemIndex >= request.items.size() || overflowSeen[itemIndex] ||
            !filtered[itemIndex] || overflow.identity == 0 ||
            request.items[itemIndex].identity != overflow.identity) {
            result.error_ = SecondaryError::invalidNativeIdentity;
            return result;
        }
        overflowSeen[itemIndex] = true;
    }

    result.directCapacity_ = filteredCount - request.overflowCount;
    if (!native_runtime::ProjectSecondary(
            request.appliedOrder,
            result.directCapacity_,
            states,
            result.projection_)) {
        result.error_ = SecondaryError::invalidCapacity;
        return result;
    }
    // A projection that needs a visible More button (any overflow) cannot be
    // applied when the sentinel is absent; fail rather than silently drop items.
    if (!hasMore && (result.projection_.moreVisible ||
                     result.projection_.overflowCount != 0)) {
        result.error_ = SecondaryError::invalidCapacity;
        return result;
    }

    // Badge and title only render the More button, so they are prepared only
    // when the sentinel exists. Order relative to the mutations below is
    // preserved exactly for the has-More path.
    std::optional<native_title::PrepareResult> title;
    if (hasMore) {
        for (std::size_t index = 0;
             index < result.projection_.overflowCount;
             ++index) {
            if (result.projection_.overflow[index] == Entry::secondaryMoments) {
                const std::uintptr_t moments =
                    request.items[native_runtime::SecondaryIndex(
                        Entry::secondaryMoments)]
                        .identity;
                if (moments == 0 ||
                    !operations.readBadge(
                        operations.context, moments, &result.badgeCount_)) {
                    result.error_ = SecondaryError::badgeRead;
                    return result;
                }
                break;
            }
        }

        title.emplace(
            native_title::Prepare(result.badgeCount_, operations.title));
        if (!title->succeeded() || title->title() == nullptr) {
            result.error_ = SecondaryError::titleConstruction;
            return result;
        }
    }

    operations.clearOverflow(operations.context, request.owner);
    for (const SecondaryItem &item : request.items) {
        if (item.identity != 0) {
            operations.setVisible(operations.context, item.identity, false);
        }
    }
    for (std::size_t index = 0;
         index < result.projection_.directCount;
         ++index) {
        const std::size_t itemIndex = native_runtime::SecondaryIndex(
            result.projection_.direct[index]);
        operations.setVisible(
            operations.context, request.items[itemIndex].identity, true);
    }
    for (std::size_t index = 0;
         index < result.projection_.overflowCount;
         ++index) {
        operations.appendOverflow(
            operations.context,
            request.owner,
            native_runtime::NativeKeyFor(result.projection_.overflow[index]).type);
    }
    if (hasMore) {
        operations.setVisible(
            operations.context, request.moreItem, result.projection_.moreVisible);
        operations.publishMoreVisibility(
            operations.context, request.moreItem, result.projection_.moreVisible);
        operations.setBadge(
            operations.context, request.moreItem, result.badgeCount_);
        operations.setTitle(
            operations.context, request.moreItem, &title->title()->temporary());
        title->title()->Release();
    }
    operations.postLayout(operations.context, request.owner);
    return result;
}

}


#pragma once
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <memory>
#include <cstdint>

// Build 269079 的 TLV 槽保存 weak_ptr<Coroutine>*；仅用于已校验的 descriptor。
// 不调用 0x5974098：它在没有当前协程时会无条件读取 nullptr+0x288。
static inline std::shared_ptr<void> YMLockNativeCoroutine(uintptr_t descriptor) {
    auto read = [](uintptr_t address, void *out, size_t length) {
        mach_vm_size_t copied = 0;
        return address && mach_vm_read_overwrite(mach_task_self(), address, length,
            reinterpret_cast<mach_vm_address_t>(out), &copied) == KERN_SUCCESS && copied == length;
    };
    uintptr_t resolver = 0, weak = 0, pair[2]{};
    if (!read(descriptor, &resolver, sizeof resolver) || !resolver) return {};
    auto slot = reinterpret_cast<uintptr_t (*)(uintptr_t)>(resolver)(descriptor);
    if (!read(slot, &weak, sizeof weak) || !read(weak, pair, sizeof pair) || !pair[0] || !pair[1]) return {};
    static_assert(sizeof(std::weak_ptr<void>) == 16);
    auto coroutine = reinterpret_cast<const std::weak_ptr<void> *>(weak)->lock();
    uint32_t state = 0;
    if (!coroutine || !read(reinterpret_cast<uintptr_t>(coroutine.get()) + 0x288,
                            &state, sizeof state)) return {};
    return coroutine;
}

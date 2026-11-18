#import "WeChatCompatibility.h"
#import <mach/mach.h>
#import <mach-o/loader.h>
#include <atomic>
#include <cstring>
#include <mutex>

static std::atomic<uint32_t> matchedBuild{0};

static BOOL YMReadImageMemory(uintptr_t address, void *buffer, size_t size) {
    vm_size_t outSize = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address,
                            (vm_size_t)size, (vm_address_t)buffer, &outSize) == KERN_SUCCESS &&
           outSize == size;
}

static uint32_t YMCheckWeChatDylib(const struct mach_header *image) {
    // 私有 ABI 只适用于已分析的 arm64 样本；版本号相同也可能有不同二进制。
    struct mach_header_64 header = {};
    if (!YMReadImageMemory((uintptr_t)image, &header, sizeof(header)) ||
        header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
        header.sizeofcmds > 1024 * 1024) return 0;
    static const uint8_t uuid270353[16] = {
        0x8c, 0xb5, 0xf2, 0x9e, 0xfc, 0x1d, 0x3d, 0x47,
        0x89, 0x7a, 0x27, 0x2a, 0x46, 0x51, 0xe9, 0x16
    };
    uint32_t build = 0;
    size_t offset = sizeof(header);
    size_t end = offset + header.sizeofcmds;
    for (uint32_t index = 0; index < header.ncmds && offset + sizeof(struct load_command) <= end; index++) {
        struct load_command command = {};
        if (!YMReadImageMemory((uintptr_t)image + offset, &command, sizeof(command)) ||
            command.cmdsize < sizeof(command) || command.cmdsize > end - offset) return 0;
        if (command.cmd == LC_UUID) {
            struct uuid_command uuid = {};
            if (command.cmdsize < sizeof(uuid) ||
                !YMReadImageMemory((uintptr_t)image + offset, &uuid, sizeof(uuid))) return 0;
            if (memcmp(uuid.uuid, uuid270353, sizeof(uuid270353)) == 0) build = 270353;
            break;
        }
        offset += command.cmdsize;
    }
    return build;
}


void YMInitializeWeChatCompatibility(const struct mach_header *image) {
    if (!image || ![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.tencent.xinWeChat"] ||
        ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"270353"]) return;
    static std::once_flag once;
    std::call_once(once, [image] {
        matchedBuild.store(YMCheckWeChatDylib(image));
    });
}

BOOL YMMatchesWeChat270353Dylib(void) {
    return matchedBuild.load() == 270353;
}

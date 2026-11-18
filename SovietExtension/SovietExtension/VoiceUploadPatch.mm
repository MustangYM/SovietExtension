#import "VoiceLimits.h"
#import "VoiceUploadPatch.h"
#import "RevokePatch.h"
#import "WeChatCompatibility.h"
#include <cstring>
#include <string>

#if defined(__aarch64__)
namespace {
template<class T> T field(uintptr_t p, size_t offset) {
    T value;
    memcpy(&value, (const void *)(p + offset), sizeof value);
    return value;
}
struct BufferPrefix { unsigned char *data; size_t position, length; };
static_assert(sizeof(BufferPrefix) == 24 && sizeof(std::string) == 24);
}

extern "C" {
uintptr_t YMVoiceUploadContinue = 0;
uint32_t YMVoiceUploadBuild270353 = 0;
int YMVoiceUploadOriginal(uintptr_t worker, void *buffer);
}

extern "C" int YMVoiceUploadBody(uintptr_t worker, void *buffer) {
    const auto parameters = field<uintptr_t>(worker, YMVoiceUploadBuild270353 ? 0x2a8 : 0x290);
    const auto running = field<uintptr_t>(worker, YMVoiceUploadBuild270353 ? 0x2b8 : 0x2a0);
    auto *out = static_cast<BufferPrefix *>(buffer);
    if (!parameters || !running || !out || out->length ||
        field<uint32_t>(parameters, 0x114) != 15 ||
        !field<uint8_t>(parameters, YMVoiceUploadBuild270353 ? 0x19d : 0x195) ||
        !reinterpret_cast<const std::string *>(running + 0x268)->empty())
        return YMVoiceUploadOriginal(worker, buffer);

    const auto rawSize = field<uint64_t>(running, 0x250);
    const auto total = field<uint64_t>(running, 0x258);
    const auto offset = field<uint64_t>(running, 0x2d0);
    if (!rawSize || rawSize > YMVoiceMaxEncodedBytes ||
        reinterpret_cast<const std::string *>(parameters + 0x300)->size() != rawSize ||
        total != (rawSize / 16 + 1) * 16 || offset > total)
        return YMVoiceUploadOriginal(worker, buffer);

    // 内存分支按密文字节推进，续传到原文末尾时仍可能剩一个填充块。
    if (offset == total) return 6;
    if (offset % 16 || (YMVoiceUploadBuild270353 && field<uint64_t>(running, 0x2e0) != offset))
        return YMVoiceUploadOriginal(worker, buffer);
    const int result = YMVoiceUploadOriginal(worker, buffer);
    const size_t remaining = static_cast<size_t>(total - offset);
    if (result != 6 || !out->data || out->length != (YMVoiceUploadBuild270353 ? remaining : total)) return result;

    // 4.2.0 已按续传位置截取密文；旧版才需要移除前缀，避免重复截断。
    if (offset && !YMVoiceUploadBuild270353) memmove(out->data, out->data + offset, remaining);
    out->position = out->length = remaining;
    memcpy((void *)(running + 0x2d0), &total, sizeof total);
    return 1;
}

#ifndef YM_VOICE_UPLOAD_TEST
__asm__(
    ".text\n.align 2\n.globl _YMVoiceUploadOriginal\n"
    "_YMVoiceUploadOriginal:\n"
    "adrp x16, _YMVoiceUploadBuild270353@PAGE\n"
    "ldr w16, [x16, _YMVoiceUploadBuild270353@PAGEOFF]\n"
    "cbnz w16, 1f\n"
    "stp x24, x23, [sp, #-0x40]!\n"
    "stp x22, x21, [sp, #0x10]\n"
    "stp x20, x19, [sp, #0x20]\n"
    "stp x29, x30, [sp, #0x30]\n"
    "b 2f\n"
    "1:\n"
    "stp x28, x27, [sp, #-0x50]!\n"
    "stp x24, x23, [sp, #0x10]\n"
    "stp x22, x21, [sp, #0x20]\n"
    "stp x20, x19, [sp, #0x30]\n"
    "2:\n"
    "adrp x16, _YMVoiceUploadContinue@PAGE\n"
    "ldr x16, [x16, _YMVoiceUploadContinue@PAGEOFF]\n"
    "br x16\n"
);

void YMInstallVoiceUploadPatch(void) {
    static bool installed = false;
    if (installed) return;
    YMVoiceForwardAddresses addresses{};
    if (!YMGetVoiceForwardAddresses(&addresses)) return;
    struct Entry { uintptr_t address; uint8_t bytes[16]; };
    static const Entry entries[] = {
        {0x5000268, {0xf8,0x5f,0xbc,0xa9,0xf6,0x57,0x01,0xa9,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9}},
        {0x5000278, {0xfd,0xc3,0x00,0x91,0xff,0x43,0x08,0xd1,0xf4,0x03,0x01,0xaa,0xf3,0x03,0x00,0xaa}},
        {0x50006e4, {0x68,0x4a,0x41,0xf9,0x09,0x55,0x46,0x39,0x89,0x02,0x00,0x34,0x00,0x01,0x0c,0x91}},
        {0x5047f90, {0x08,0x50,0x41,0xf9,0x0a,0x71,0x41,0xf9,0x4b,0xed,0x7c,0x92,0x7f,0x01,0x0a,0xeb}},
        {0x502e440, {0x88,0x9e,0x40,0xb9,0x68,0x16,0x01,0xb9,0x81,0x82,0x0a,0x91,0x60,0x82,0x16,0x91}},
        {0x810b74, {0x00,0x08,0x40,0xf9,0xc0,0x03,0x5f,0xd6,0x00,0x18,0x40,0xb9,0xc0,0x03,0x5f,0xd6}},
        {0x49b4f34, {0x08,0x00,0x40,0xf9,0x00,0x01,0x01,0x8b,0xc0,0x03,0x5f,0xd6,0xf6,0x57,0xbd,0xa9}},
    };
    static const Entry entries270353[] = {
        {0x5db1490, {0xfc,0x6f,0xbb,0xa9,0xf8,0x5f,0x01,0xa9,0xf6,0x57,0x02,0xa9,0xf4,0x4f,0x03,0xa9}},
        {0x5db14a0, {0xfd,0x7b,0x04,0xa9,0xfd,0x03,0x01,0x91,0xff,0x43,0x08,0xd1,0xf4,0x03,0x01,0xaa}},
        {0x5db19a4, {0x68,0x5e,0x41,0xf9,0x15,0x71,0x41,0xf9,0x69,0x56,0x41,0xf9,0x28,0x5d,0x8c,0x39}},
        {0x5db1b8c, {0x20,0x01,0x0c,0x91,0x2a,0x75,0x46,0x39,0x0a,0x15,0x00,0x36,0xf8,0xe3,0x03,0x91}},
        {0x5db1bc0, {0x21,0x41,0x35,0x8b,0x68,0xb1,0x88,0x9a,0x02,0x41,0x35,0xcb,0xe0,0x03,0x14,0xaa}},
        {0x5df9e68, {0x08,0x5c,0x41,0xf9,0x09,0x71,0x41,0xf9,0x2a,0xed,0x7c,0x92,0x5f,0x01,0x09,0xeb}},
    };
    const bool current = YMMatchesWeChat270353Dylib();
    const auto *selected = current ? entries270353 : entries;
    const size_t count = current ? sizeof(entries270353) / sizeof(Entry) : sizeof(entries) / sizeof(Entry);
    for (size_t index = 0; index < count; ++index) {
        const auto &entry = selected[index];
        const auto address = YMRuntimeAddress(entry.address);
        if (!address || memcmp((const void *)address, entry.bytes, sizeof entry.bytes)) return;
    }
    YMVoiceUploadBuild270353 = current;
    YMVoiceUploadContinue = YMRuntimeAddress(current ? 0x5db14a0 : 0x5000278);
    installed = YMPatchARM64AbsoluteJump(YMRuntimeAddress(current ? 0x5db1490 : 0x5000268),
        (uintptr_t)&YMVoiceUploadBody, "voice upload resume");
    YMLog(@"[VoiceUpload] resume patch installed=%d", installed);
}
#endif
#else
void YMInstallVoiceUploadPatch(void) {}
#endif

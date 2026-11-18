#import "MessageMediaActions.h"
#import "WeChatCompatibility.h"
#import "RevokePatch.h"
#import "SelfRevokePatch.h"
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <atomic>
#include <cerrno>
#include <fcntl.h>
#include <set>
#include <vector>
#include <dlfcn.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <ctime>
#include <filesystem>
#include <limits.h>

#if defined(__aarch64__)
// 每个已验证 ARM 镜像独立选择地址和字段；未知版本不启用资源操作。
static bool YMMedia270353 = false;
static uintptr_t YMMediaAddress(uintptr_t legacy, uintptr_t current) {
    return YMRuntimeAddress(YMMedia270353 ? current : legacy);
}
static size_t YMMediaOffset(size_t legacy, size_t current) {
    return YMMedia270353 ? current : legacy;
}
static bool YMImageLookupReady = false;
static bool YMVideoLookupReady = false;
static bool YMVideoCoverLookupReady = false;
static bool YMStickerLookupReady = false;
static bool YMStickerSaveReady = false;
struct YMMessageMediaPath {
    // 微信的24字节路径对象，非平凡返回值使用x8；借助原生转换复制成自有string。
    alignas(8) uint8_t storage[24];
    ~YMMessageMediaPath() { ((void (*)(void *))YMMediaAddress(0x2826c, 0x2b48c))(this); }
    std::string string() const { return ((std::string (*)(const void *))YMMediaAddress(0x2ad1c, 0x2df3c))(this); }
};
static_assert(sizeof(YMMessageMediaPath) == 24);

static NSURL *YMMessageMediaFileURL(const std::string &path) {
    if (path.empty() || path.front() != '/' || path.find('\0') != std::string::npos) return nil;
    NSString *name = [[NSString alloc] initWithBytes:path.data() length:path.size() encoding:NSUTF8StringEncoding];
    if (!name) return nil;
    struct stat info = {};
    // 拒绝目录、空文件及叶节点符号链接，不按后缀推断完整性，不修改或解码缓存。
    if (lstat(name.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
        access(name.fileSystemRepresentation, R_OK)) return nil;
    char resolved[PATH_MAX];
    // 祖先目录也不能经符号链接转向未经归属校验的位置；仅允许词法规范化。
    if (!realpath(name.fileSystemRepresentation, resolved) ||
        std::filesystem::path(name.fileSystemRepresentation).lexically_normal().native() != resolved) return nil;
    return [NSURL fileURLWithPath:name isDirectory:NO];
}

static NSURL *YMVideoLocalURL(const YMMessageSnapshot &message) {
    const auto *data = message.storage;
    if (!NSThread.isMainThread || !YMVideoLookupReady || data[YMMediaOffset(0x1c9, 0x1d1)] || *(const uint32_t *)(data + 8) != 43) return nil;
    // 与原生 48c2190 的下载完成判定一致；33 优先，32 兼容原视频资源。
    if (*(const uint32_t *)(data + YMMediaOffset(0xac, 0xb4)) != 3 && *(const uint32_t *)(data + YMMediaOffset(0xa8, 0xb0)) != 3) return nil;
    for (int resource : {33, 32}) {
        using Getter = YMMessageMediaPath (*)(const void *, const int *, bool);
        auto path = ((Getter)YMMediaAddress(0x449aa78, 0x49fd524))(&message, &resource, false);
        if (NSURL *url = YMMessageMediaFileURL(path.string())) return url;
    }
    return nil;
}

static NSURL *YMMessageLocalURL(const YMMessageSnapshot &message) {
    const auto *data = message.storage;
    if (data[YMMediaOffset(0x1c9, 0x1d1)]) return nil;
    const uint32_t type = *(const uint32_t *)(data + 8);
    if (type == 47 && YMStickerLookupReady) {
        const auto md5 = ((std::string (*)(const void *))YMMediaAddress(0x448246c, 0x49e37dc))(&message);
        if (md5.size() != 32 || md5.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos) return nil;
        void *account = ((void *(*)())YMMediaAddress(0x428d0bc, 0x47990b4))();
        if (!account) return nil;
        auto root = [&](int kind) {
            using Root = YMMessageMediaPath (*)(void *, const int *);
            auto path = ((Root)YMMediaAddress(0x428dc4c, 0x4799c60))(account, &kind);
            return path.string();
        };
        const auto suffix = "/" + md5.substr(0, 2) + "/" + md5;
        const auto legacy = root(11);
        if (!legacy.empty() && legacy.front() == '/') {
            const auto initialized = __atomic_load_n((uint64_t *)YMMediaAddress(0x9319470, 0xa5c2a00), __ATOMIC_ACQUIRE);
            if (initialized == UINT64_MAX) {
                const char *directory = *(const uint8_t *)YMMediaAddress(0x9319468, 0xa5c29f8) ? "/Persistence" : "/Persist";
                if (NSURL *url = YMMessageMediaFileURL(legacy + directory + suffix)) return url;
            } else {
                // 初始化会迁移/mkdir；这里只读检查原生两种旧目录，不触发初始化。
                for (const char *directory : {"/Persistence", "/Persist"})
                    if (NSURL *url = YMMessageMediaFileURL(legacy + directory + suffix)) return url;
            }
        }
        const auto current = root(15);
        if (current.empty() || current.front() != '/') return nil;
        auto month = ((YMMessageMediaPath (*)(uint32_t))YMMediaAddress(0x434274c, 0x487018c))((uint32_t)time(nullptr));
        const auto component = month.string();
        if (component.empty() || component == "." || component == ".." || component.find('/') != std::string::npos) return nil;
        // 精确复现4350ba4的完整候选，绕过其中mkdir；不查.thumb/.temp/.icon或其他月份。
        return YMMessageMediaFileURL(current + "/" + component + "/Emoticon" + suffix);
    }
    if (type == 43) return YMVideoLocalURL(message);
    if (!YMImageLookupReady || type != 3) return nil;
    // 与0x48c1be8的图片可用性分支一致；路径存在本身不足以判断下载状态。
    if (*(const uint32_t *)(data + YMMediaOffset(0xac, 0xb4)) != 2 && (*(const uint32_t *)(data + YMMediaOffset(0xa4, 0xac)) | 4) == 5) return nil;
    auto getURL = [&](int resource) -> NSURL * {
        using Getter = YMMessageMediaPath (*)(const void *, const int *, bool);
        auto path = ((Getter)YMMediaAddress(0x449aa78, 0x49fd524))(&message, &resource, false);
        return YMMessageMediaFileURL(path.string());
    };
    // 快照持有扩展的shared_ptr。仅同步借用，与原生0x48c1918的资源3→2选择一致。
    void *extension = *(void *const *)(data + YMMediaOffset(0x208, 0x218));
    if (extension) {
        using Cast = void *(*)(const void *, uintptr_t, uintptr_t, ptrdiff_t);
        auto image = ((Cast)YMMediaAddress(0x63f23f4, 0x72b0e58))(
            extension, YMMediaAddress(0x8e1b500, 0xa000e98), YMMediaAddress(0x8e1c6f8, 0xa002270), 0);
        if (image && *(const uint32_t *)((uint8_t *)image + YMMediaOffset(0x190, 0x1f8))) {
            if (NSURL *url = getURL(3)) return url;
        }
    }
    return getURL(2); // 资源1为缩略图，绝不作为定位候选。
}

// 表情保存复用微信协程下载和本地缓存解码；只在用户点击后调用。
struct YMStickerDownloadResult { bool ok; std::string detail; };
struct YMStickerSourceLocation {
    const char *function; const char *file; uint32_t line; uint32_t padding; uintptr_t caller;
};
static_assert(sizeof(YMStickerDownloadResult) == 32);
static_assert(offsetof(YMStickerDownloadResult, detail) == 8);
static_assert(sizeof(YMStickerSourceLocation) == 32);

struct YMStickerAccountContext {
    std::shared_ptr<void> service;
    std::string legacyRoot, currentRoot;
    explicit operator bool() const { return service && !legacyRoot.empty() && !currentRoot.empty(); }
    bool operator==(const YMStickerAccountContext &other) const {
        return service == other.service && legacyRoot == other.legacyRoot && currentRoot == other.currentRoot;
    }
    bool operator!=(const YMStickerAccountContext &other) const { return !(*this == other); }
};
static YMStickerAccountContext YMStickerAccount() {
    void *app = ((void *(*)())YMMediaAddress(0x428d0bc, 0x47990b4))();
    if (!app) return {};
    using Getter = std::shared_ptr<void> (*)(void *);
    YMStickerAccountContext result;
    result.service = ((Getter)(*(uintptr_t **)app)[0x68 / 8])(app);
    if (!result.service) return {};
    auto root = [&](int kind) {
        auto path = ((YMMessageMediaPath (*)(void *, const int *))YMMediaAddress(0x428dc4c, 0x4799c60))(app, &kind);
        return path.string();
    };
    result.legacyRoot = root(11);
    result.currentRoot = root(15);
    return result;
}

static void YMStickerSaveError(NSString *detail) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"无法另存为表情";
    alert.informativeText = detail;
    [alert runModal];
}

static UTType *YMStickerImageType(NSData *bytes) {
    if (!bytes.length || bytes.length > 64 * 1024 * 1024) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, nullptr);
    if (!source) return nil;
    UTType *type = nil;
    const size_t count = CGImageSourceGetCount(source);
    if (CGImageSourceGetStatus(source) == kCGImageStatusComplete && count && count <= 1000) {
        CFStringRef identifier = CGImageSourceGetType(source);
        if (identifier) type = [UTType typeWithIdentifier:(__bridge NSString *)identifier];
        if (![type conformsToType:UTTypeImage] || !type.preferredFilenameExtension) type = nil;
        uint64_t pixels = 0;
        for (size_t i = 0; type && i < count; ++i) {
            NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, i, nullptr));
            const uint64_t width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
            const uint64_t height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
            // 限制解码预算，避免损坏缓存或超大动画耗尽微信内存；不生成缩略图。
            if (!width || !height || width > 16384 || height > 16384 || width * height > 16000000 ||
                (pixels += width * height) > 256000000) { type = nil; break; }
            CGImageRef frame = CGImageSourceCreateImageAtIndex(source, i, (__bridge CFDictionaryRef)@{
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES});
            if (!frame || CGImageSourceGetStatusAtIndex(source, i) != kCGImageStatusComplete) type = nil;
            if (frame) CGImageRelease(frame);
        }
    }
    CFRelease(source);
    return type;
}

static NSData *YMNativeAESDecodeWithKey(NSData *input, const std::string &key) {
    if (!YMStickerSaveReady || !input.length || input.length > 64 * 1024 * 1024 ||
        input.length < 16 || input.length % 16) return nil;
    if (key.empty() || key.size() > UINT32_MAX) return nil;
    struct Buffer {
        alignas(8) uint8_t storage[24];
        Buffer() { ((void (*)(void *))YMMediaAddress(0x3b3adec, 0x47893e4))(this); }
        ~Buffer() { ((void (*)(void *))YMMediaAddress(0x3b3aee0, 0x47894d8))(this); }
    } output;
    using Decode = int (*)(const void *, uint32_t, void *, const void *, uint32_t);
    const int result = ((Decode)YMMediaAddress(0x3b3a0d8, 0x47886d0))(
        input.bytes, (uint32_t)input.length, &output, key.data(), (uint32_t)key.size());
    if (result) return nil;
    const void *data = ((const void *(*)(const void *))YMMediaAddress(0x8736c, 0x8c2bc))(&output);
    const uint32_t size = ((uint32_t (*)(const void *))YMMediaAddress(0x2af18, 0x2e2b0))(&output);
    if (!data || !size || size > input.length) return nil;
    return [NSData dataWithBytes:data length:size];
}

static NSData *YMNativeAESDecode(NSData *input) {
    if (!YMStickerSaveReady) return nil;
    auto key = ((std::string (*)())YMMediaAddress(0x434f9a4, 0x4880a6c))();
    NSData *result = YMNativeAESDecodeWithKey(input, key);
    for (size_t i = 0; i < key.size(); ++i) ((volatile char *)key.data())[i] = 0;
    return result;
}

static NSData *YMStickerDecodedBytes(NSURL *url, const std::string *capturedKey = nullptr) {
    // 用同一打开的文件描述符读取，拒绝符号链接和增长中的/超大文件。
    const int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat before = {}, after = {};
    NSMutableData *input = nil;
    if (!fstat(fd, &before) && S_ISREG(before.st_mode) && before.st_size > 0 && before.st_size <= 64 * 1024 * 1024) {
        input = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
        size_t readBytes = 0;
        while (readBytes < input.length) {
            const ssize_t n = read(fd, (uint8_t *)input.mutableBytes + readBytes, input.length - readBytes);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { input = nil; break; }
            readBytes += (size_t)n;
        }
        if (fstat(fd, &after) || before.st_size != after.st_size ||
            before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
            before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec) input = nil;
    }
    close(fd);
    if (!input) return nil;
    if (YMStickerImageType(input)) return input; // 旧缓存也可能已经是标准媒体。
    return capturedKey ? YMNativeAESDecodeWithKey(input, *capturedKey) : YMNativeAESDecode(input);
}

static NSData *YMStickerExportBytes(NSData *bytes) {
    if (!bytes.length || bytes.length > 64 * 1024 * 1024) return nil;
    if (YMStickerImageType(bytes)) return bytes;
    if (bytes.length < 4 || !((bool (*)(const void *, size_t))YMMediaAddress(0x477095c, 0x4d31444))(bytes.bytes, bytes.length)) return nil;
    // WXAM解密后仍是私有图片容器；微信原生mode3导出完整GIF，mode0只会得到首帧JPEG。
    // 原生输出52字节，前三个int32为宽/高/帧数；options固定32字节。
    int32_t info[13] = {};
    if (((int (*)(const void *, int, void *))YMMediaAddress(0x63f3f54, 0x72b2a60))(bytes.bytes, (int)bytes.length, info)) return nil;
    if (info[0] <= 0 || info[1] <= 0 || info[2] <= 0 || info[0] > 16384 || info[1] > 16384 || info[2] > 1000) return nil;
    const uint64_t pixels = (uint64_t)info[0] * (uint64_t)info[1];
    const uint64_t totalPixels = pixels * (uint64_t)info[2];
    if (pixels > 16000000 || totalPixels > 256000000) return nil;
    int capacity = (int)std::min<uint64_t>(totalPixels * 3, 50 * 1024 * 1024);
    const uint32_t options[8] = {3, 0, 0, 0, 0, 0, 0, 0};
    using Convert = int (*)(const void *, int, void *, int *, const void *);
    NSMutableData *output = [NSMutableData dataWithLength:(NSUInteger)capacity];
    int length = capacity;
    int status = ((Convert)YMMediaAddress(0x63f3f9c, 0x72b2aa8))(bytes.bytes, (int)bytes.length, output.mutableBytes, &length, options);
    // -206表示输出缓冲区不足，length返回所需容量；仅在上限内扩容重试一次。
    if (status == -206 && length > capacity && length <= 64 * 1024 * 1024) {
        capacity = length;
        output.length = (NSUInteger)capacity;
        status = ((Convert)YMMediaAddress(0x63f3f9c, 0x72b2aa8))(bytes.bytes, (int)bytes.length, output.mutableBytes, &length, options);
    }
    if (status || length <= 0 || length > capacity) return nil;
    output.length = (NSUInteger)length;
    if (![YMStickerImageType(output) isEqual:UTTypeGIF]) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)output, nullptr);
    if (!source) return nil;
    bool complete = CGImageSourceGetCount(source) == (size_t)info[2];
    for (size_t i = 0; complete && i < (size_t)info[2]; ++i) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, i, nullptr));
        complete = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] intValue] == info[0] &&
                   [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] intValue] == info[1];
    }
    CFRelease(source);
    return complete ? output : nil;
}

static NSString *YMStickerFileName(const YMMessageSnapshot &message, UTType *type) {
    const auto md5 = ((std::string (*)(const void *))YMMediaAddress(0x448246c, 0x49e37dc))(&message);
    NSString *name = [NSString stringWithUTF8String:md5.c_str()]; // 已在保存入口校验32位资源标识。
    void *extension = *(void *const *)(message.storage + YMMediaOffset(0x208, 0x218));
    if (extension) {
        using Cast = void *(*)(const void *, uintptr_t, uintptr_t, ptrdiff_t);
        void *sticker = ((Cast)YMMediaAddress(0x63f23f4, 0x72b0e58))(
            extension, YMMediaAddress(0x8e1b500, 0xa000e98), YMMediaAddress(0x8e1b818, 0xa0011b0), 0);
        if (sticker) {
            // emoji.desc由0x486b834写入扩展+0x2b0，0x480113c消费；可为空，并非保证存在的名称。
            const auto &text = *(const std::string *)((const uint8_t *)sticker + YMMediaOffset(0x2b0, 0x310));
            if (!text.empty() && text.size() <= 4096) {
                NSString *description = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
                NSMutableCharacterSet *invalid = [NSCharacterSet.controlCharacterSet mutableCopy];
                [invalid removeCharactersInString:@"\u200C\u200D"]; // 保留组合Emoji的连接符。
                [invalid formUnionWithCharacterSet:NSCharacterSet.illegalCharacterSet];
                [invalid addCharactersInString:@"/\\:"];
                description = [[description componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@"_"];
                description = [description stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                // 按完整字素截断，给MD5及真实后缀保留文件名空间。
                NSMutableString *prefix = [NSMutableString string];
                [description enumerateSubstringsInRange:NSMakeRange(0, description.length)
                    options:NSStringEnumerationByComposedCharacterSequences
                    usingBlock:^(NSString *part, NSRange, NSRange, BOOL *stop) {
                        if ([prefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [part lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 160) *stop = YES;
                        else [prefix appendString:part];
                    }];
                if (prefix.length) name = [NSString stringWithFormat:@"%@_%@", prefix, name];
            }
        }
    }
    return [name stringByAppendingPathExtension:type.preferredFilenameExtension];
}

// 外层服务槽 +0x30 是注册表，token 0x8b7ca40 查出的才是添加和下载要用的内层服务。
static std::shared_ptr<void> YMEmoticonRegistryService(const std::shared_ptr<void> &outer) {
    using Shared = std::shared_ptr<void>;
    if (!outer) return {};
    auto registry = ((Shared (*)(void *))(*(uintptr_t **)outer.get())[0x30 / 8])(outer.get());
    if (!registry) return {};
    const uintptr_t token = YMMediaAddress(0x8b7ca40, 0x9d5b8a8);
    return ((Shared (*)(void *, const uintptr_t *))YMMediaAddress(0x3a58b24, 0x469db2c))(registry.get(), &token);
}

// 按值传入，保证后续C++闭包及嵌套ObjC Block复制的是拥有所有权的对象。
static void YMStickerSave(std::shared_ptr<YMMessageSnapshot> message,
                          YMStickerAccountContext account) {
    using Shared = std::shared_ptr<void>;
    using Getter = Shared (*)(void *);
    if (!account || YMStickerAccount() != account) {
        YMStickerSaveError(@"登录账号已改变，请重新打开消息菜单。"); return;
    }
    if (!*(void *const *)(message->storage + YMMediaOffset(0x228, 0x238)) || !*(void *const *)(message->storage + YMMediaOffset(0x230, 0x240))) {
        YMStickerSaveError(@"所选表情的资源信息已失效，请重新打开消息菜单。"); return;
    }
    auto descriptor = ((Shared (*)(const void *))YMMediaAddress(0x47f2db4, 0x4dbdfcc))(message.get());
    const auto md5 = ((std::string (*)(const void *))YMMediaAddress(0x448246c, 0x49e37dc))(message.get());
    if (!descriptor || *(uintptr_t *)descriptor.get() != YMMediaAddress(0x8e16c20, 0x9ffc618) ||
        md5.size() != 32 || md5.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos ||
        *(const std::string *)((const uint8_t *)descriptor.get() + 0x10) != md5) {
        YMStickerSaveError(@"无法取得所选表情的完整资源。"); return;
    }
    auto service = YMEmoticonRegistryService(account.service);
    void *app = ((void *(*)())YMMediaAddress(0x428d0bc, 0x47990b4))();
    auto scheduler = app ? ((Getter)YMMediaAddress(0x428e6a0, 0x479a6b4))(app) : Shared{};
    if (!service || !scheduler) { YMStickerSaveError(@"表情下载服务不可用。"); return; }
    // 主线程持有任务句柄，工作闭包只持有终态标记，避免Task/闭包循环引用。
    auto finished = std::make_shared<std::atomic_bool>(false);
    std::function<void()> work = [message, account, descriptor, service, finished] {
        @autoreleasepool {
            NSData *bytes = nil;
            NSURL *sourceURL = nil;
            UTType *type = nil;
            struct stat originalInfo = {};
            try {
                if (YMStickerAccount() == account && !finished->load()) {
                    sourceURL = YMMessageLocalURL(*message);
                    bool available = sourceURL != nil;
                    if (!available) {
                        auto result = ((YMStickerDownloadResult (*)(void *, const Shared *, int))YMMediaAddress(0x34e49a4, 0x40d1f54))(
                            service.get(), &descriptor, 0);
                        available = result.ok;
                    }
                    if (available && !finished->load() && YMStickerAccount() == account) {
                        sourceURL = YMMessageLocalURL(*message);
                        if (sourceURL && !stat(sourceURL.fileSystemRepresentation, &originalInfo))
                            bytes = YMStickerDecodedBytes(sourceURL);
                        bytes = YMStickerExportBytes(bytes);
                        type = YMStickerImageType(bytes);
                    }
                }
            } catch (...) { /* 原生失败/协程取消不允许异常越过任务边界。 */ }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (finished->exchange(true)) return;
                try {
                    if (!bytes || !type || YMStickerAccount() != account) {
                        YMStickerSaveError(@"无法取得完整表情，可能已过期、下载失败或格式不受支持。请稍后重试。"); return;
                    }
                    NSSavePanel *panel = NSSavePanel.savePanel;
                    panel.allowedContentTypes = @[type];
                    panel.canCreateDirectories = YES;
                    panel.nameFieldStringValue = YMStickerFileName(*message, type);
                    [panel beginWithCompletionHandler:^(NSModalResponse response) {
                        if (response != NSModalResponseOK) return;
                        try {
                            NSURL *target = panel.URL;
                            NSURL *current = YMMessageLocalURL(*message);
                            // 用户选择期间源失效/账号切换必须终止；不允许覆盖微信缓存或其硬链接。
                            struct stat sourceInfo = {}, targetInfo = {};
                            const bool sameFile = current && target &&
                                !stat(current.fileSystemRepresentation, &sourceInfo) &&
                                !stat(target.fileSystemRepresentation, &targetInfo) &&
                                sourceInfo.st_dev == targetInfo.st_dev && sourceInfo.st_ino == targetInfo.st_ino;
                            const bool unchanged = current && !stat(current.fileSystemRepresentation, &sourceInfo) &&
                                sourceInfo.st_dev == originalInfo.st_dev && sourceInfo.st_ino == originalInfo.st_ino &&
                                sourceInfo.st_size == originalInfo.st_size &&
                                sourceInfo.st_mtimespec.tv_sec == originalInfo.st_mtimespec.tv_sec &&
                                sourceInfo.st_mtimespec.tv_nsec == originalInfo.st_mtimespec.tv_nsec;
                            if (YMStickerAccount() != account || !unchanged || ![current isEqual:sourceURL] ||
                                !target.isFileURL || sameFile) {
                                YMStickerSaveError(@"源文件已改变，或保存位置与微信缓存相同，请重新选择。"); return;
                            }
                            NSError *error = nil;
                            if (![bytes writeToURL:target options:NSDataWritingAtomic error:&error])
                                YMStickerSaveError(@"写入失败，请检查保存位置的权限和剩余空间。");
                        } catch (...) { YMStickerSaveError(@"保存失败，请重新打开消息菜单后重试。"); }
                    }];
                } catch (...) { YMStickerSaveError(@"无法打开保存窗口，请重新尝试。"); }
            });
        }
    };
    static const YMStickerSourceLocation location = {"YMStickerSave", "MessageMediaActions.mm", __LINE__, 0, 0};
    auto task = ((Shared (*)(void *, const YMStickerSourceLocation *, std::function<void()> *, int))YMMediaAddress(0x3a280f0, 0x466bddc))(
        scheduler.get(), &location, &work, 1);
    if (!task || *(uintptr_t *)task.get() != YMMediaAddress(0x8eb9550, 0xa1035e0) ||
        ((bool (*)(void *))YMMediaAddress(0x597c66c, 0x67f0c28))(task.get())) {
        finished->store(true); YMStickerSaveError(@"无法启动表情保存，请稍后重试。"); return;
    }
    // 超时终止本次保存订阅；微信复用的底层下载不保证随之终止。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (finished->exchange(true)) return;
        ((void (*)(void *))YMMediaAddress(0x597be88, 0x67f0444))(task.get());
        YMStickerSaveError(@"获取表情超时，已停止本次保存。请检查网络后重试。");
    });
}

std::function<void()> YMMessageMediaActions::revealAction(std::shared_ptr<YMMessageSnapshot> message) {
    if (!message) return {};
    NSURL *url = YMMessageLocalURL(*message);
    if (!url) return {};
    return [message, url, used = false]() mutable {
        if (used) return;
        used = true;
        void (^work)(void) = ^{
            @autoreleasepool {
                try {
                    NSURL *current = YMMessageLocalURL(*message);
                    if (current && [current isEqual:url]) {
                        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
                        return; // Finder没有成功回调，不宣称已定位。
                    }
                } catch (...) {
                    YMLog(@"[MessageMedia] lookup failed at click");
                }
                NSAlert *alert = [NSAlert new];
                alert.messageText = @"无法定位这条消息的本地文件";
                alert.informativeText = @"完整本地文件已不可用，可能已被清理或无法访问";
                [alert runModal];
            }
        };
        if ([NSThread isMainThread]) work();
        else dispatch_async(dispatch_get_main_queue(), work);
    };
}

std::function<void()> YMMessageMediaActions::saveAction(std::shared_ptr<YMMessageSnapshot> message) {
    if (!message) return {};
    if (*(const uint32_t *)(message->storage + 8) != 47 || !YMStickerSaveReady || message->storage[YMMediaOffset(0x1c9, 0x1d1)]) return {};
    auto account = YMStickerAccount();
    if (!account) return {};
    return [message, account, used = false]() mutable {
        if (used) return;
        used = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            try { YMStickerSave(message, account); }
            catch (...) { YMStickerSaveError(@"无法启动表情保存，请稍后重试。"); }
        });
    };
}

void YMMessageMediaActions::validateABI() {
    YMImageLookupReady = YMVideoLookupReady = YMVideoCoverLookupReady = false;
    YMStickerLookupReady = YMStickerSaveReady = false;
    YMMedia270353 = YMMatchesWeChat270353Dylib();
    if (!YMMedia270353 && !YMMatchesWeChatLegacyNativeDylib()) return;
    struct Entry { uintptr_t offset; uint8_t bytes[16]; };
    // 资源适配独立失败时保留+1；图片与表情只共享路径生命周期的必要校验。
    static const Entry pathEntries[] = {
        {0x2826c, {0x8, 0x5c, 0xc0, 0x39, 0x48, 0x0, 0xf8, 0x37, 0xc0, 0x3, 0x5f, 0xd6, 0xf4, 0x4f, 0xbe, 0xa9}},
        {0x2ad1c, {0x9, 0x5c, 0xc0, 0x39, 0xc9, 0x0, 0xf8, 0x37, 0x0, 0x0, 0xc0, 0x3d, 0x0, 0x1, 0x80, 0x3d}},
        {0x63f23f4, {0xf0, 0x36, 0x1, 0x90, 0x10, 0xb2, 0x45, 0xf9, 0x0, 0x2, 0x1f, 0xd6, 0xf0, 0x36, 0x1, 0x90}},
        {0x48c2ad4, {0x0, 0x24, 0x47, 0x39, 0xc0, 0x3, 0x5f, 0xd6, 0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x1, 0xa9}},
        {0x950278, {0xf8, 0x23, 0x0, 0xb9, 0x20, 0x3, 0x7d, 0xb2, 0xe1, 0x3, 0x17, 0xaa, 0x64, 0x92, 0x61, 0x95}},
    };
    static const Entry imageEntries[] = {
        // resource1 跳表分支：复用图片标识构造 _t.dat 缩略图路径。
        {0x449ae14, {0x97,0xa2,0x40,0xb9,0x88,0x5e,0xc6,0x39,0x28,0x27,0xf8,0x37,0x80,0x62,0xc0,0x3d}},
        {0x449aa78, {0xff, 0x83, 0x6, 0xd1, 0xfa, 0x67, 0x15, 0xa9, 0xf8, 0x5f, 0x16, 0xa9, 0xf6, 0x57, 0x17, 0xa9}},
        {0x48c1a10, {0xc1, 0x2a, 0x2, 0xd0, 0x21, 0x0, 0x14, 0x91, 0xc2, 0x2a, 0x2, 0xf0, 0x42, 0xe0, 0x1b, 0x91}},
        {0x48c1a44, {0x8, 0x90, 0x41, 0xb9, 0xa8, 0x3, 0x0, 0x34, 0x68, 0x0, 0x80, 0x52, 0xa8, 0xc3, 0x1d, 0xb8}},
        {0x48c1c54, {0x68, 0xae, 0x40, 0xb9, 0x1f, 0x9, 0x0, 0x71, 0xa0, 0x46, 0x0, 0x54, 0x68, 0xa6, 0x40, 0xb9}},
    };
    static const Entry videoCoverEntries[] = {
        {0x449aa78, {0xff,0x83,0x6,0xd1,0xfa,0x67,0x15,0xa9,0xf8,0x5f,0x16,0xa9,0xf6,0x57,0x17,0xa9}},
        {0x81300c, {0xe8,0x3,0x80,0x52,0xe8,0x7,0x0,0xb9,0xe8,0x23,0x0,0x91,0xe0,0x3,0x9,0xaa}},
        {0x449ae74, {0x97,0xa2,0x40,0xb9,0x88,0xbe,0xc6,0x39,0xe8,0x2a,0xf8,0x37,0x88,0x62,0x6,0x91}},
    };
    static const Entry videoEntries[] = {
        {0x48c19a0, {0x28,0x4,0x80,0x52,0xe8,0x1b,0x0,0xb9,0xe8,0x3,0x0,0x91,0xe1,0x63,0x0,0x91}},
        {0x48c19dc, {0x8,0x4,0x80,0x52,0xe8,0x1b,0x0,0xb9,0xe8,0x3,0x0,0x91,0xe1,0x63,0x0,0x91}},
        {0x48c2190, {0x68,0xae,0x40,0xb9,0x1f,0xd,0x0,0x71,0xc0,0x1c,0x0,0x54,0x68,0xaa,0x40,0xb9}},
    };
    static const Entry stickerEntries[] = {
        {0x448246c, {0xff, 0xc3, 0x0, 0xd1, 0xf4, 0x4f, 0x1, 0xa9, 0xfd, 0x7b, 0x2, 0xa9, 0xfd, 0x83, 0x0, 0x91}},
        {0x428d0bc, {0x28, 0x84, 0x2, 0xb0, 0x0, 0xb5, 0x42, 0xf9, 0xc0, 0x3, 0x5f, 0xd6, 0xff, 0xc3, 0x0, 0xd1}},
        {0x428dc4c, {0xff, 0x43, 0x1, 0xd1, 0xf6, 0x57, 0x2, 0xa9, 0xf4, 0x4f, 0x3, 0xa9, 0xfd, 0x7b, 0x4, 0xa9}},
        {0x428dc28, {0xa, 0xa4, 0x46, 0xa9, 0xa, 0x25, 0x0, 0xa9, 0x89, 0x0, 0x0, 0xb4, 0x28, 0x21, 0x0, 0x91}},
        {0x3a3bd88, {0x21, 0x0, 0x40, 0xb9, 0x0, 0x20, 0xa, 0x91, 0x1a, 0xca, 0xff, 0x17, 0xff, 0x43, 0x6, 0xd1}},
        {0x3a2e5f8, {0xe9, 0x3, 0x0, 0xaa, 0xe0, 0x3, 0x8, 0xaa, 0x28, 0x5, 0x40, 0xf9, 0x28, 0x5, 0x0, 0xb4}},
        {0x434274c, {0xff, 0x3, 0x1, 0xd1, 0xf4, 0x4f, 0x2, 0xa9, 0xfd, 0x7b, 0x3, 0xa9, 0xfd, 0xc3, 0x0, 0x91}},
        {0x43500b0, {0x48, 0x7e, 0x2, 0xb0, 0x8, 0xc1, 0x11, 0x91, 0x8, 0xc1, 0xbf, 0xf8, 0x1f, 0x5, 0x0, 0xb1}},
        {0x43500e4, {0x48, 0x7e, 0x2, 0xb0, 0x8, 0xa1, 0x51, 0x39, 0x1f, 0x1, 0x0, 0x71, 0xe8, 0xe3, 0x0, 0x91}},
        {0x47f2460, {0xff, 0x43, 0x1, 0xd1, 0xf4, 0x4f, 0x3, 0xa9, 0xfd, 0x7b, 0x4, 0xa9, 0xfd, 0x3, 0x1, 0x91}},
    };
    static const Entry saveEntries[] = {
        {0x486b77c, {0xc9, 0x6a, 0x1, 0x90, 0x20, 0xf9, 0x42, 0xfd, 0x89, 0x57, 0x2, 0x90, 0x29, 0xf1, 0x18, 0x91}},
        {0x486b834, {0x80, 0xc2, 0xa, 0x91, 0xa1, 0x83, 0x3, 0xd1, 0xcf, 0x18, 0x6e, 0x94, 0xa8, 0x73, 0xd3, 0x38}},
        {0x480113c, {0x80, 0x82, 0x6, 0x91, 0xa1, 0xc2, 0xa, 0x91, 0x8d, 0xc2, 0x6f, 0x94, 0xf4, 0xb, 0x40, 0xf9}},
        {0x63f3f54, {0xf0, 0x36, 0x1, 0xb0, 0x10, 0x52, 0x41, 0xf9, 0x0, 0x2, 0x1f, 0xd6, 0xf0, 0x36, 0x1, 0xb0}},
        {0x63f3f9c, {0xf0, 0x36, 0x1, 0xb0, 0x10, 0x6a, 0x41, 0xf9, 0x0, 0x2, 0x1f, 0xd6, 0xf0, 0x36, 0x1, 0xb0}},
        {0x47709dc, {0xff, 0x3, 0x3, 0xd1, 0xf4, 0x4f, 0xa, 0xa9, 0xfd, 0x7b, 0xb, 0xa9, 0xfd, 0xc3, 0x2, 0x91}},
        {0x477095c, {0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x3, 0x0, 0x91, 0x85, 0xd, 0x72, 0x94, 0x1f, 0x0, 0x0, 0x71}},
        {0x428e6a0, {0xa, 0x48, 0x41, 0xf9, 0x9, 0x4c, 0x41, 0xf9, 0xa, 0x25, 0x0, 0xa9, 0x89, 0x0, 0x0, 0xb4}},
        {0x3a280f0, {0xff, 0xc3, 0x6, 0xd1, 0xfc, 0x6f, 0x16, 0xa9, 0xf8, 0x5f, 0x17, 0xa9, 0xf6, 0x57, 0x18, 0xa9}},
        {0x3a58b24, {0xff, 0xc3, 0x7, 0xd1, 0xfa, 0x67, 0x1a, 0xa9, 0xf8, 0x5f, 0x1b, 0xa9, 0xf6, 0x57, 0x1c, 0xa9}},
        {0x47f2db4, {0xff, 0xc3, 0x0, 0xd1, 0xf4, 0x4f, 0x1, 0xa9, 0xfd, 0x7b, 0x2, 0xa9, 0xfd, 0x83, 0x0, 0x91}},
        {0x34e49a4, {0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x1, 0xa9, 0xfd, 0x7b, 0x2, 0xa9, 0xfd, 0x83, 0x0, 0x91}},
        {0x597be88, {0xff, 0x83, 0x6, 0xd1, 0xf6, 0x57, 0x17, 0xa9, 0xf4, 0x4f, 0x18, 0xa9, 0xfd, 0x7b, 0x19, 0xa9}},
        {0x597c66c, {0x8, 0xc, 0x5, 0x91, 0x8, 0xfd, 0xdf, 0x8, 0x0, 0x1, 0x0, 0x12, 0xc0, 0x3, 0x5f, 0xd6}},
        {0x434f9a4, {0xff, 0xc3, 0x0, 0xd1, 0xf4, 0x4f, 0x1, 0xa9, 0xfd, 0x7b, 0x2, 0xa9, 0xfd, 0x83, 0x0, 0x91}},
        {0x3b3a0d8, {0x2a, 0xfe, 0xff, 0x17, 0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x3, 0x0, 0x91, 0x88, 0x9e, 0x2, 0xf0}},
        {0x3b39980, {0xff, 0xc3, 0x5, 0xd1, 0xfc, 0x6f, 0x13, 0xa9, 0xf6, 0x57, 0x14, 0xa9, 0xf4, 0x4f, 0x15, 0xa9}},
        {0x3b3adec, {0x1f, 0x7c, 0x0, 0xa9, 0x1f, 0x10, 0x0, 0xb9, 0xc0, 0x3, 0x5f, 0xd6, 0xf4, 0x4f, 0xbe, 0xa9}},
        {0x3b3aee0, {0x8, 0x0, 0x40, 0xf9, 0x48, 0x1, 0x0, 0xb4, 0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x1, 0xa9}},
        {0x8736c, {0x0, 0x0, 0x40, 0xf9, 0xc0, 0x3, 0x5f, 0xd6, 0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x1, 0xa9}},
        {0x2af18, {0x0, 0x8, 0x40, 0xb9, 0xc0, 0x3, 0x5f, 0xd6, 0x8, 0x8, 0x40, 0xb9, 0x9, 0x0, 0x80, 0x12}},
        {0x5938fc, {0xf0, 0xe5, 0xf3, 0x94, 0x8, 0x0, 0x40, 0xf9, 0x9, 0x35, 0x40, 0xf9, 0xe8, 0x23, 0x2, 0x91}},
    };
    static const Entry pathEntries270353[] = {
        {0x2b48c, {0x08, 0x5c, 0xc0, 0x39, 0x48, 0x00, 0xf8, 0x37, 0xc0, 0x03, 0x5f, 0xd6, 0xf4, 0x4f, 0xbe, 0xa9}},
        {0x2df3c, {0x09, 0x5c, 0xc0, 0x39, 0xc9, 0x00, 0xf8, 0x37, 0x00, 0x00, 0xc0, 0x3d, 0x00, 0x01, 0x80, 0x3d}},
        {0x72b0e58, {0x70, 0x4e, 0x01, 0xd0, 0x10, 0x02, 0x46, 0xf9, 0x00, 0x02, 0x1f, 0xd6, 0x70, 0x4e, 0x01, 0xd0}},
        {0x4e98308, {0x00, 0x44, 0x47, 0x39, 0xc0, 0x03, 0x5f, 0xd6, 0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9}},
        {0xd349fc, {0xf8, 0x23, 0x00, 0xb9, 0x20, 0x03, 0x7d, 0xb2, 0xe1, 0x03, 0x17, 0xaa, 0xd4, 0xad, 0x8c, 0x95}},
    };
    static const Entry imageEntries270353[] = {
        {0x49fd8c8, {0x97, 0xaa, 0x40, 0xb9, 0x88, 0x7e, 0xc6, 0x39, 0x48, 0x27, 0xf8, 0x37, 0x88, 0x22, 0x06, 0x91}},
        {0x49fd524, {0xff, 0x83, 0x06, 0xd1, 0xfa, 0x67, 0x15, 0xa9, 0xf8, 0x5f, 0x16, 0xa9, 0xf6, 0x57, 0x17, 0xa9}},
        {0x4e9723c, {0x41, 0x8b, 0x02, 0xb0, 0x21, 0x60, 0x3a, 0x91, 0x42, 0x8b, 0x02, 0xf0, 0x42, 0xc0, 0x09, 0x91}},
        {0x4e97270, {0x08, 0xf8, 0x41, 0xb9, 0xa8, 0x03, 0x00, 0x34, 0x68, 0x00, 0x80, 0x52, 0xa8, 0xc3, 0x1d, 0xb8}},
        {0x4e97488, {0x68, 0xb6, 0x40, 0xb9, 0x1f, 0x09, 0x00, 0x71, 0xa0, 0x46, 0x00, 0x54, 0x68, 0xae, 0x40, 0xb9}},
    };
    static const Entry videoCoverEntries270353[] = {
        {0x49fd524, {0xff, 0x83, 0x06, 0xd1, 0xfa, 0x67, 0x15, 0xa9, 0xf8, 0x5f, 0x16, 0xa9, 0xf6, 0x57, 0x17, 0xa9}},
        {0x9dbbfc, {0xe8, 0x03, 0x80, 0x52, 0xe8, 0x07, 0x00, 0xb9, 0xe8, 0x23, 0x00, 0x91, 0xe0, 0x03, 0x09, 0xaa}},
        {0x49fd934, {0x97, 0xaa, 0x40, 0xb9, 0x88, 0xde, 0xc6, 0x39, 0xa8, 0x2a, 0xf8, 0x37, 0x80, 0x6a, 0xc0, 0x3d}},
    };
    static const Entry videoEntries270353[] = {
        {0x4e971cc, {0x28, 0x04, 0x80, 0x52, 0xe8, 0x1b, 0x00, 0xb9, 0xe8, 0x03, 0x00, 0x91, 0xe1, 0x63, 0x00, 0x91}},
        {0x4e97208, {0x08, 0x04, 0x80, 0x52, 0xe8, 0x1b, 0x00, 0xb9, 0xe8, 0x03, 0x00, 0x91, 0xe1, 0x63, 0x00, 0x91}},
        {0x4e979c4, {0x68, 0xb6, 0x40, 0xb9, 0x1f, 0x0d, 0x00, 0x71, 0xc0, 0x1c, 0x00, 0x54, 0x68, 0xb2, 0x40, 0xb9}},
    };
    static const Entry stickerEntries270353[] = {
        {0x49e37dc, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
        {0x47990b4, {0x08, 0xf1, 0x02, 0x90, 0x00, 0x35, 0x45, 0xf9, 0xc0, 0x03, 0x5f, 0xd6, 0xff, 0xc3, 0x00, 0xd1}},
        {0x4799c60, {0xff, 0x43, 0x01, 0xd1, 0xf6, 0x57, 0x02, 0xa9, 0xf4, 0x4f, 0x03, 0xa9, 0xfd, 0x7b, 0x04, 0xa9}},
        {0x4799c3c, {0x0a, 0xa4, 0x46, 0xa9, 0x0a, 0x25, 0x00, 0xa9, 0x89, 0x00, 0x00, 0xb4, 0x28, 0x21, 0x00, 0x91}},
        {0x467fffc, {0x21, 0x00, 0x40, 0xb9, 0x00, 0xe0, 0x0a, 0x91, 0xb3, 0xc9, 0xff, 0x17, 0xff, 0x43, 0x06, 0xd1}},
        {0x46726d0, {0xe9, 0x03, 0x00, 0xaa, 0xe0, 0x03, 0x08, 0xaa, 0x28, 0x05, 0x40, 0xf9, 0x28, 0x05, 0x00, 0xb4}},
        {0x487018c, {0xff, 0x03, 0x01, 0xd1, 0xf4, 0x4f, 0x02, 0xa9, 0xfd, 0x7b, 0x03, 0xa9, 0xfd, 0xc3, 0x00, 0x91}},
        {0x4881178, {0x08, 0xea, 0x02, 0xb0, 0x08, 0x01, 0x28, 0x91, 0x08, 0xc1, 0xbf, 0xf8, 0x1f, 0x05, 0x00, 0xb1}},
        {0x48811ac, {0x08, 0xea, 0x02, 0xb0, 0x08, 0xe1, 0x67, 0x39, 0x1f, 0x01, 0x00, 0x71, 0xe8, 0xe3, 0x00, 0x91}},
        {0x4dbd624, {0xff, 0x43, 0x01, 0xd1, 0xf4, 0x4f, 0x03, 0xa9, 0xfd, 0x7b, 0x04, 0xa9, 0xfd, 0x03, 0x01, 0x91}},
    };
    static const Entry saveEntries270353[] = {
        {0x4e3b984, {0x49, 0xbc, 0x01, 0xf0, 0x20, 0xf9, 0x45, 0xfd, 0x89, 0xbe, 0x02, 0xb0, 0x29, 0xf1, 0x24, 0x91}},
        {0x4e3ba3c, {0x80, 0x42, 0x0c, 0x91, 0xa1, 0x83, 0x03, 0xd1, 0xf2, 0xd2, 0x91, 0x94, 0xa8, 0x73, 0xd3, 0x38}},
        {0x4dcd644, {0x80, 0x82, 0x06, 0x91, 0xa1, 0x42, 0x0c, 0x91, 0xf0, 0x8b, 0x93, 0x94, 0xf4, 0x0b, 0x40, 0xf9}},
        {0x72b2a60, {0x70, 0x4e, 0x01, 0xd0, 0x10, 0x1e, 0x42, 0xf9, 0x00, 0x02, 0x1f, 0xd6, 0x70, 0x4e, 0x01, 0xd0}},
        {0x72b2aa8, {0x70, 0x4e, 0x01, 0xd0, 0x10, 0x36, 0x42, 0xf9, 0x00, 0x02, 0x1f, 0xd6, 0x70, 0x4e, 0x01, 0xd0}},
        {0x4d314c4, {0xff, 0x03, 0x03, 0xd1, 0xf4, 0x4f, 0x0a, 0xa9, 0xfd, 0x7b, 0x0b, 0xa9, 0xfd, 0xc3, 0x02, 0x91}},
        {0x4d31444, {0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x03, 0x00, 0x91, 0x8e, 0x05, 0x96, 0x94, 0x1f, 0x00, 0x00, 0x71}},
        {0x479a6b4, {0x0a, 0x48, 0x41, 0xf9, 0x09, 0x4c, 0x41, 0xf9, 0x0a, 0x25, 0x00, 0xa9, 0x89, 0x00, 0x00, 0xb4}},
        {0x466bddc, {0xff, 0xc3, 0x06, 0xd1, 0xfc, 0x6f, 0x16, 0xa9, 0xf8, 0x5f, 0x17, 0xa9, 0xf6, 0x57, 0x18, 0xa9}},
        {0x469db2c, {0xff, 0xc3, 0x07, 0xd1, 0xfa, 0x67, 0x1a, 0xa9, 0xf8, 0x5f, 0x1b, 0xa9, 0xf6, 0x57, 0x1c, 0xa9}},
        {0x4dbdfcc, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
        {0x40d1f54, {0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
        {0x67f0444, {0xff, 0x83, 0x06, 0xd1, 0xf6, 0x57, 0x17, 0xa9, 0xf4, 0x4f, 0x18, 0xa9, 0xfd, 0x7b, 0x19, 0xa9}},
        {0x67f0c28, {0x08, 0x0c, 0x05, 0x91, 0x08, 0xfd, 0xdf, 0x08, 0x00, 0x01, 0x00, 0x12, 0xc0, 0x03, 0x5f, 0xd6}},
        {0x4880a6c, {0xff, 0xc3, 0x00, 0xd1, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91}},
        {0x47886d0, {0x2a, 0xfe, 0xff, 0x17, 0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x03, 0x00, 0x91, 0x68, 0xce, 0x02, 0xf0}},
        {0x4787f78, {0xff, 0xc3, 0x05, 0xd1, 0xfc, 0x6f, 0x13, 0xa9, 0xf6, 0x57, 0x14, 0xa9, 0xf4, 0x4f, 0x15, 0xa9}},
        {0x47893e4, {0x1f, 0x7c, 0x00, 0xa9, 0x1f, 0x10, 0x00, 0xb9, 0xc0, 0x03, 0x5f, 0xd6, 0xf4, 0x4f, 0xbe, 0xa9}},
        {0x47894d8, {0x08, 0x00, 0x40, 0xf9, 0x48, 0x01, 0x00, 0xb4, 0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9}},
        {0x8c2bc, {0x00, 0x00, 0x40, 0xf9, 0xc0, 0x03, 0x5f, 0xd6, 0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9}},
        {0x2e2b0, {0x00, 0x08, 0x40, 0xb9, 0xc0, 0x03, 0x5f, 0xd6, 0x08, 0x08, 0x40, 0xb9, 0x09, 0x00, 0x80, 0x12}},
        {0x6b5160, {0xd5, 0x8f, 0x03, 0x95, 0x08, 0x00, 0x40, 0xf9, 0x09, 0x35, 0x40, 0xf9, 0xe8, 0x23, 0x02, 0x91}},
    };
    auto matches = [](const auto &legacy, const auto &current) {
        const auto &checks = YMMedia270353 ? current : legacy;
        for (const auto &entry : checks) {
            if (memcmp((void *)YMRuntimeAddress(entry.offset), entry.bytes, sizeof(entry.bytes)) != 0) {
                YMLog(@"[MessageMedia] ABI mismatch at 0x%lx; keep +1", entry.offset);
                return false;
            }
        }
        return true;
    };
    const bool pathsReady = matches(pathEntries, pathEntries270353);
    YMImageLookupReady = pathsReady && matches(imageEntries, imageEntries270353);
    YMVideoLookupReady = YMImageLookupReady && matches(videoEntries, videoEntries270353);
    YMVideoCoverLookupReady = pathsReady && matches(videoCoverEntries, videoCoverEntries270353);
    YMStickerLookupReady = pathsReady && matches(stickerEntries, stickerEntries270353);
    YMStickerSaveReady = YMStickerLookupReady && matches(saveEntries, saveEntries270353);
    // 外部codec也核对自身入口，不能仅依赖wechat.dylib导入跳板的指纹。
    struct CodecEntry { const char *symbol; uint8_t bytes[16]; };
    static const CodecEntry codecEntries[] = {
        {"wxam_dec_isWXGF_5", {0x3f, 0x10, 0x0, 0x71, 0x6a, 0x0, 0x0, 0x54, 0x60, 0x19, 0x80, 0x12, 0xc0, 0x3, 0x5f, 0xd6}},
        {"wxam_dec_getWXGFInfo_5", {0x3, 0x0, 0x80, 0xd2, 0x4, 0x0, 0x80, 0x52, 0x5, 0x0, 0x80, 0x52, 0x58, 0xfe, 0xff, 0x17}},
        {"wxam_dec_wxam2pic_5", {0xff, 0x3, 0x1, 0xd1, 0xfd, 0x7b, 0x3, 0xa9, 0xfd, 0xc3, 0x0, 0x91, 0x80, 0x4, 0x40, 0xad}},
    };
    // 4.2.0 的 Frameworks 导出是转发桩；只查已加载的 Resources 实现，避免触发加载副作用。
    void *codec = RTLD_DEFAULT;
    if (YMMedia270353) {
        NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:
            @"MultiMediaDyn.framework/Versions/A/MultiMediaDyn"];
        codec = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
    }
    for (const auto &entry : codecEntries) {
        void *function = codec ? dlsym(codec, entry.symbol) : nullptr;
        if (!function || memcmp(function, entry.bytes, sizeof(entry.bytes))) {
            YMStickerSaveReady = false;
            YMLog(@"[MessageMedia] codec ABI mismatch; sticker saving disabled");
            break;
        }
    }
    if (YMMedia270353 && codec) dlclose(codec);
}
#endif

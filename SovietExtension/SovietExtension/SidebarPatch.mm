#import "SidebarPatchIntegrity.h"
#import "SidebarPatch.h"
#import "SidebarRuntime.h"

// ---- owner bridge --------------------------------------------------------
#include <cstddef>
#include <mutex>
#include <utility>

namespace ym::sidebar::patch_guard {

class OwnerBridge::Implementation final : public OwnerStateConsumer {
public:
    explicit Implementation(CandidateReader readerValue,
                            BridgeLifecycleObserver observerValue)
        : reader(std::move(readerValue)),
          lifecycleObserver(std::move(observerValue)) {}

    void InvalidateOwner(const OwnerToken &token) override {
        ownerIdentity = 0;
        mainWindowIdentity = 0;
        candidateIdentity = 0;
        if (lifecycleObserver) {
            lifecycleObserver(BridgeLifecycleEvent::generationInvalidated,
                              token);
            lifecycleObserver(BridgeLifecycleEvent::tokenCleared, token);
            lifecycleObserver(BridgeLifecycleEvent::surfaceRemoved, token);
        }
    }

    void PublishOwner(const OwnerToken &token) override {
        ownerIdentity = stagedOwnerIdentity;
        mainWindowIdentity = stagedMainWindowIdentity;
        candidateIdentity = stagedCandidateIdentity;
        lastOwnerGeneration = token.ownerGeneration;
    }

    void TeardownOwner(const OwnerToken &) override {}

    [[nodiscard]] static bool SameToken(const OwnerToken &left,
                                        const OwnerToken &right) noexcept {
        return left.installGeneration == right.installGeneration &&
               left.ownerGeneration == right.ownerGeneration &&
               left.valid == right.valid &&
               left.eligibility == right.eligibility;
    }

    void ClearEpoch() {
        if (state != nullptr) {
            const OwnerToken token = state->current();
            if (token.valid && ownerIdentity != 0) {
                static_cast<void>(state->Destroy(
                    ownerIdentity, installGeneration, token, *this));
            }
        }
        state.reset();
        installGeneration = {};
        epoch = 0;
        attempt = 0;
        ownerIdentity = 0;
        mainWindowIdentity = 0;
        candidateIdentity = 0;
    }

    mutable std::recursive_mutex mutex;
    CandidateReader reader;
    BridgeLifecycleObserver lifecycleObserver;
    std::unique_ptr<OwnerState> state;
    InstallGeneration installGeneration{};
    std::uint64_t epoch{0};
    std::uint64_t attempt{0};
    std::uint64_t ownerIdentity{0};
    std::uint64_t mainWindowIdentity{0};
    std::uint64_t candidateIdentity{0};
    std::uint64_t stagedOwnerIdentity{0};
    std::uint64_t stagedMainWindowIdentity{0};
    std::uint64_t stagedCandidateIdentity{0};
    std::uint64_t lastOwnerGeneration{0};
};

OwnerBridge::OwnerBridge(CandidateReader reader,
                         BridgeLifecycleObserver lifecycleObserver)
    : implementation_(std::make_unique<Implementation>(
          std::move(reader), std::move(lifecycleObserver))) {}

OwnerBridge::~OwnerBridge() = default;

void OwnerBridge::setCandidateReader(CandidateReader reader) {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    implementation_->reader = std::move(reader);
}

void OwnerBridge::setLifecycleObserver(BridgeLifecycleObserver observer) {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    implementation_->lifecycleObserver = std::move(observer);
}

void OwnerBridge::bindPatchEpoch(std::uint64_t epoch,
                                 std::uint64_t installAttempt) {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    implementation_->ClearEpoch();
    if (epoch == 0 || installAttempt == 0) {
        return;
    }
    implementation_->state = std::make_unique<OwnerState>(
        OwnerState::CounterSeed{epoch - 1,
                                implementation_->lastOwnerGeneration});
    const InstallGeneration generation =
        implementation_->state->BeginInstall(*implementation_);
    if (!generation.valid() || generation.value != epoch) {
        implementation_->state.reset();
        return;
    }
    implementation_->installGeneration = generation;
    implementation_->epoch = epoch;
    implementation_->attempt = installAttempt;
}

void OwnerBridge::invalidatePatchEpoch() {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    implementation_->ClearEpoch();
}

CaptureDisposition OwnerBridge::captureOwner(
    std::uint64_t ownerIdentity,
    std::uint64_t mainWindowIdentity,
    const OwnerToken &observedToken) {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    if (implementation_->state == nullptr || ownerIdentity == 0 ||
        mainWindowIdentity == 0 || !implementation_->reader) {
        return CaptureDisposition::rejected;
    }
    std::uint64_t candidateIdentity = 0;
    if (!implementation_->reader(ownerIdentity,
                                 kComponentSurfaceOffset,
                                 candidateIdentity) ||
        candidateIdentity == 0 ||
        candidateIdentity % alignof(void *) != 0) {
        return CaptureDisposition::rejected;
    }

    implementation_->stagedOwnerIdentity = ownerIdentity;
    implementation_->stagedMainWindowIdentity = mainWindowIdentity;
    implementation_->stagedCandidateIdentity = candidateIdentity;
    const CaptureDisposition disposition = implementation_->state->Capture(
        ownerIdentity,
        OwnerEligibility::eligible,
        implementation_->installGeneration,
        observedToken,
        *implementation_);
    implementation_->stagedOwnerIdentity = 0;
    implementation_->stagedMainWindowIdentity = 0;
    implementation_->stagedCandidateIdentity = 0;
    return disposition;
}

void OwnerBridge::revokeAtDestructorStart(std::uint64_t mainWindowIdentity) {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    if (implementation_->state == nullptr) {
        return;
    }
    const OwnerToken token = implementation_->state->current();
    if (token.valid && mainWindowIdentity != 0 &&
        mainWindowIdentity == implementation_->mainWindowIdentity &&
        implementation_->ownerIdentity != 0) {
        static_cast<void>(implementation_->state->Destroy(
            implementation_->ownerIdentity,
            implementation_->installGeneration,
            token,
            *implementation_));
        return;
    }
    implementation_->ClearEpoch();
}

bool OwnerBridge::withResolvedCandidate(const OwnerToken &token,
                                        const CandidateVisitor &visitor) const {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    if (implementation_->state == nullptr || !visitor ||
        implementation_->candidateIdentity == 0 ||
        !implementation_->state->CanPublish(token) ||
        !Implementation::SameToken(token,
                                   implementation_->state->current())) {
        return false;
    }
    return visitor(implementation_->candidateIdentity);
}

OwnerToken OwnerBridge::currentToken() const noexcept {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    return implementation_->state != nullptr
               ? implementation_->state->current()
               : OwnerToken{};
}

std::uint64_t OwnerBridge::patchEpoch() const noexcept {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    return implementation_->epoch;
}

std::uint64_t OwnerBridge::installAttempt() const noexcept {
    std::lock_guard<std::recursive_mutex> lock(implementation_->mutex);
    return implementation_->attempt;
}

std::size_t OwnerBridge::eligibleSnapshotCount() const noexcept {
    return currentToken().valid ? 1u : 0u;
}

OwnerBridge &SharedSidebarPatchOwnerBridge() {
    static OwnerBridge bridge([](std::uint64_t,
                                 std::uint64_t,
                                 std::uint64_t &) { return false; });
    return bridge;
}

}

// ---- image preflight -----------------------------------------------------
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>


namespace {

constexpr char kTargetSuffix[] =
    "/WeChat.app/Contents/Resources/wechat.dylib";
constexpr std::size_t kDigestSize = CC_SHA256_DIGEST_LENGTH;
constexpr std::size_t kReadBufferSize = 1024 * 1024;
constexpr std::size_t kMachHeaderSize = 32;

bool SameIdentity(const YMSidebarPatchFileIdentity &left,
                  const YMSidebarPatchFileIdentity &right) noexcept {
    return left.device == right.device && left.inode == right.inode &&
           left.size == right.size && left.mtimeSeconds == right.mtimeSeconds &&
           left.mtimeNanoseconds == right.mtimeNanoseconds &&
           left.mode == right.mode;
}

bool HasTargetSuffix(const char *path) noexcept {
    if (path == nullptr) {
        return false;
    }
    const std::size_t pathLength = std::strlen(path);
    const std::size_t suffixLength = sizeof(kTargetSuffix) - 1;
    return pathLength >= suffixLength &&
           std::memcmp(path + pathLength - suffixLength,
                       kTargetSuffix,
                       suffixLength) == 0;
}

bool AddSlide(intptr_t slide, uintptr_t value, uintptr_t &output) noexcept {
    if (slide >= 0) {
        const uintptr_t positive = static_cast<uintptr_t>(slide);
        if (value > std::numeric_limits<uintptr_t>::max() - positive) {
            return false;
        }
        output = value + positive;
        return true;
    }
    const uintptr_t magnitude = static_cast<uintptr_t>(-(slide + 1)) + 1;
    if (value < magnitude) {
        return false;
    }
    output = value - magnitude;
    return true;
}

bool RangeInside(const YMSidebarPatchLoadedImage &image,
                 uintptr_t address,
                 std::size_t length) noexcept {
    return image.imageStart != 0 && length <= image.imageSize &&
           address >= image.imageStart &&
           address - image.imageStart <= image.imageSize - length;
}

NSString *HexDigest(const uint8_t *bytes, std::size_t length) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string result(length * 2, '0');
    for (std::size_t index = 0; index < length; ++index) {
        result[index * 2] = hex[bytes[index] >> 4];
        result[index * 2 + 1] = hex[bytes[index] & 0x0f];
    }
    return [NSString stringWithUTF8String:result.c_str()];
}

int SystemOpen(void *, const char *path) {
    return path == nullptr ? -1
                           : open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
}

bool SystemStat(void *,
                int descriptor,
                YMSidebarPatchFileIdentity *identity) {
    struct stat value = {};
    if (identity == nullptr || fstat(descriptor, &value) != 0) {
        return false;
    }
    identity->device = static_cast<uint64_t>(value.st_dev);
    identity->inode = static_cast<uint64_t>(value.st_ino);
    identity->size = static_cast<uint64_t>(value.st_size);
    identity->mtimeSeconds = value.st_mtimespec.tv_sec;
    identity->mtimeNanoseconds = value.st_mtimespec.tv_nsec;
    identity->mode = static_cast<uint32_t>(value.st_mode);
    return true;
}

std::ptrdiff_t SystemRead(void *,
                          int descriptor,
                          uint8_t *destination,
                          std::size_t capacity) {
    return read(descriptor, destination, capacity);
}

int SystemClose(void *, int descriptor) {
    return close(descriptor);
}

struct CachedHash {
    std::string path;
    YMSidebarPatchFileIdentity identity = {};
    std::array<uint8_t, kDigestSize> digest = {};
};

struct HashResult {
    SidebarPatchIntegrityFailure failure =
        SidebarPatchIntegrityFailureNone;
    YMSidebarPatchFileIdentity identity = {};
    std::array<uint8_t, kDigestSize> digest = {};
};

}  // namespace

@interface SidebarPatchPreflightReceipt () {
    NSString *_path;
    YMSidebarPatchFileIdentity _fileIdentity;
    NSString *_fileSHA256;
    uintptr_t _headerAddress;
    intptr_t _slide;
    uintptr_t _imageStart;
    NSUInteger _imageSize;
    NSString *_guardSHA256;
    uint64_t _installAttempt;
    NSUInteger _patchGuardCount;
    NSUInteger _callGuardCount;
}
- (instancetype)initWithPath:(NSString *)path
                fileIdentity:(YMSidebarPatchFileIdentity)fileIdentity
                  fileSHA256:(NSString *)fileSHA256
               loadedImage:(const YMSidebarPatchLoadedImage &)image
                 guardSHA256:(NSString *)guardSHA256
              installAttempt:(uint64_t)installAttempt;
@end

@implementation SidebarPatchPreflightReceipt

@synthesize path = _path;
@synthesize fileIdentity = _fileIdentity;
@synthesize fileSHA256 = _fileSHA256;
@synthesize headerAddress = _headerAddress;
@synthesize slide = _slide;
@synthesize imageStart = _imageStart;
@synthesize imageSize = _imageSize;
@synthesize guardSHA256 = _guardSHA256;
@synthesize installAttempt = _installAttempt;
@synthesize patchGuardCount = _patchGuardCount;
@synthesize callGuardCount = _callGuardCount;

- (instancetype)initWithPath:(NSString *)path
                fileIdentity:(YMSidebarPatchFileIdentity)fileIdentity
                  fileSHA256:(NSString *)fileSHA256
                 loadedImage:(const YMSidebarPatchLoadedImage &)image
                 guardSHA256:(NSString *)guardSHA256
              installAttempt:(uint64_t)installAttempt {
    self = [super init];
    if (self != nil) {
        _path = [path copy];
        _fileIdentity = fileIdentity;
        _fileSHA256 = [fileSHA256 copy];
        _headerAddress = image.headerAddress;
        _slide = image.slide;
        _imageStart = image.imageStart;
        _imageSize = image.imageSize;
        _guardSHA256 = [guardSHA256 copy];
        _installAttempt = installAttempt;
        _patchGuardCount = kYMSidebarPatchInstallTargetCount;
        _callGuardCount = kYMSidebarPatchCallTargetCount;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end


@interface SidebarPatchIntegrity () {
    YMSidebarPatchFileOperations _operations;
    bool _hasCache;
    CachedHash _cache;
    std::unordered_set<uint64_t> _consumedAttempts;
    std::mutex _mutex;
}
@end

@implementation SidebarPatchIntegrity

- (instancetype)init {
    return [self initWithFileOperations:YMSidebarPatchSystemFileOperations()];
}

- (instancetype)initWithFileOperations:
    (YMSidebarPatchFileOperations)operations {
    self = [super init];
    if (self != nil) {
        _operations = operations;
        _hasCache = false;
    }
    return self;
}

- (HashResult)hashPath:(const char *)path {
    HashResult result;
    if (_operations.openReadOnlyNoFollow == nullptr ||
        _operations.statDescriptor == nullptr ||
        _operations.readDescriptor == nullptr ||
        _operations.closeDescriptor == nullptr) {
        result.failure = SidebarPatchIntegrityFailureInvalidInput;
        return result;
    }

    const int descriptor =
        _operations.openReadOnlyNoFollow(_operations.context, path);
    if (descriptor < 0) {
        result.failure = SidebarPatchIntegrityFailureOpen;
        return result;
    }

    auto closeOriginalDescriptor = [&]() {
        return _operations.closeDescriptor(_operations.context, descriptor) == 0;
    };
    if (!_operations.statDescriptor(
            _operations.context, descriptor, &result.identity)) {
        closeOriginalDescriptor();
        result.failure = SidebarPatchIntegrityFailureStat;
        return result;
    }
    if (!S_ISREG(result.identity.mode)) {
        closeOriginalDescriptor();
        result.failure = SidebarPatchIntegrityFailureNotRegularFile;
        return result;
    }

    const bool cacheHit = _hasCache && _cache.path == path &&
                          SameIdentity(_cache.identity, result.identity);
    if (cacheHit) {
        result.digest = _cache.digest;
    } else {
        CC_SHA256_CTX hash = {};
        if (CC_SHA256_Init(&hash) != 1) {
            closeOriginalDescriptor();
            result.failure = SidebarPatchIntegrityFailureHash;
            return result;
        }
        std::vector<uint8_t> buffer(kReadBufferSize);
        uint64_t total = 0;
        for (;;) {
            const std::ptrdiff_t count = _operations.readDescriptor(
                _operations.context, descriptor, buffer.data(), buffer.size());
            if (count < 0) {
                if (errno == EINTR) {
                    continue;
                }
                closeOriginalDescriptor();
                result.failure = SidebarPatchIntegrityFailureRead;
                return result;
            }
            if (count == 0) {
                break;
            }
            const auto unsignedCount = static_cast<std::size_t>(count);
            if (unsignedCount > buffer.size() ||
                total > std::numeric_limits<uint64_t>::max() - unsignedCount ||
                CC_SHA256_Update(&hash, buffer.data(),
                                 static_cast<CC_LONG>(unsignedCount)) != 1) {
                closeOriginalDescriptor();
                result.failure = SidebarPatchIntegrityFailureHash;
                return result;
            }
            total += unsignedCount;
        }
        if (total != result.identity.size) {
            closeOriginalDescriptor();
            result.failure = SidebarPatchIntegrityFailureRead;
            return result;
        }
        YMSidebarPatchFileIdentity finalIdentity = {};
        if (!_operations.statDescriptor(
                _operations.context, descriptor, &finalIdentity)) {
            closeOriginalDescriptor();
            result.failure = SidebarPatchIntegrityFailureStat;
            return result;
        }
        if (!SameIdentity(result.identity, finalIdentity)) {
            closeOriginalDescriptor();
            result.failure = SidebarPatchIntegrityFailurePathReplaced;
            return result;
        }
        if (CC_SHA256_Final(result.digest.data(), &hash) != 1) {
            closeOriginalDescriptor();
            result.failure = SidebarPatchIntegrityFailureHash;
            return result;
        }
    }

    const int freshDescriptor =
        _operations.openReadOnlyNoFollow(_operations.context, path);
    if (freshDescriptor < 0) {
        closeOriginalDescriptor();
        result.failure = SidebarPatchIntegrityFailureOpen;
        return result;
    }
    YMSidebarPatchFileIdentity freshIdentity = {};
    if (!_operations.statDescriptor(
            _operations.context, freshDescriptor, &freshIdentity)) {
        _operations.closeDescriptor(_operations.context, freshDescriptor);
        closeOriginalDescriptor();
        result.failure = SidebarPatchIntegrityFailureStat;
        return result;
    }
    if (!S_ISREG(freshIdentity.mode)) {
        _operations.closeDescriptor(_operations.context, freshDescriptor);
        closeOriginalDescriptor();
        result.failure = SidebarPatchIntegrityFailureNotRegularFile;
        return result;
    }
    if (!SameIdentity(result.identity, freshIdentity)) {
        _operations.closeDescriptor(_operations.context, freshDescriptor);
        closeOriginalDescriptor();
        result.failure = SidebarPatchIntegrityFailurePathReplaced;
        return result;
    }
    const bool originalClosed = closeOriginalDescriptor();
    const bool freshClosed =
        _operations.closeDescriptor(_operations.context, freshDescriptor) == 0;
    if (!originalClosed || !freshClosed) {
        result.failure = SidebarPatchIntegrityFailureClose;
        return result;
    }
    if (!cacheHit) {
        _cache = CachedHash{path, result.identity, result.digest};
        _hasCache = true;
    }
    return result;
}

- (YMSidebarPatchPreflightResult)verify:
    (const YMSidebarPatchPreflightInput *)input {
    std::lock_guard<std::mutex> lock(_mutex);
    auto fail = [](SidebarPatchIntegrityFailure failure) {
        return YMSidebarPatchPreflightResult{failure, nil};
    };
    if (input == nullptr || input->images == nullptr || input->imageCount == 0 ||
        input->bundleIdentifier == nullptr || input->shortVersion == nullptr ||
        input->buildVersion == nullptr || input->architecture == nullptr ||
        input->installAttempt == 0 || input->memoryReader == nullptr) {
        return fail(SidebarPatchIntegrityFailureInvalidInput);
    }
    if (_consumedAttempts.find(input->installAttempt) !=
        _consumedAttempts.end()) {
        return fail(SidebarPatchIntegrityFailureInstallAttemptReuse);
    }

    const YMSidebarPatchLoadedImage *target = nullptr;
    for (std::size_t index = 0; index < input->imageCount; ++index) {
        if (!HasTargetSuffix(input->images[index].path)) {
            continue;
        }
        if (target != nullptr) {
            return fail(SidebarPatchIntegrityFailureImageAmbiguous);
        }
        target = &input->images[index];
    }
    if (target == nullptr) {
        return fail(SidebarPatchIntegrityFailureImageNotFound);
    }
    if (target->headerAddress == 0 || target->imageStart == 0 ||
        target->imageSize < kMachHeaderSize ||
        target->imageSize >
            std::numeric_limits<uintptr_t>::max() - target->imageStart ||
        target->headerAddress != target->imageStart ||
        !RangeInside(*target, target->headerAddress, kMachHeaderSize)) {
        return fail(SidebarPatchIntegrityFailureImageBounds);
    }

    const YMSidebarPatchIdentity identity = {
        input->bundleIdentifier,
        input->shortVersion,
        input->buildVersion,
        input->architecture,
    };
    const auto *profile = YMSidebarPatchProfileForIdentity(identity);
    if (profile == nullptr) {
        return fail(SidebarPatchIntegrityFailureIdentityMismatch);
    }

    std::array<uint8_t, kMachHeaderSize> header = {};
    if (!input->memoryReader(input->memoryReaderContext,
                             target->headerAddress,
                             header.data(),
                             header.size())) {
        return fail(SidebarPatchIntegrityFailureUnreadableRange);
    }
    uint32_t commandBytes = 0;
    std::memcpy(&commandBytes, header.data() + 20, sizeof(commandBytes));
    if (commandBytes > target->imageSize - kMachHeaderSize) {
        return fail(SidebarPatchIntegrityFailureImageBounds);
    }
    std::vector<uint8_t> machHeader(kMachHeaderSize + commandBytes);
    if (!input->memoryReader(input->memoryReaderContext,
                             target->headerAddress,
                             machHeader.data(),
                             machHeader.size())) {
        return fail(SidebarPatchIntegrityFailureUnreadableRange);
    }
    if (!YMNavigationSidebarVerifyMachOUUID(
            *profile->sidebarProfile,
            machHeader.data(),
            machHeader.size())) {
        return fail(SidebarPatchIntegrityFailureUUIDMismatch);
    }

    CC_SHA256_CTX guardHash = {};
    if (CC_SHA256_Init(&guardHash) != 1) {
        return fail(SidebarPatchIntegrityFailureHash);
    }
    const auto targets = YMNavigationSidebarProfileTargets(
        *profile->sidebarProfile);
    for (std::size_t index = 0; index < targets.size(); ++index) {
        const auto &guard = targets[index];
        uintptr_t runtimeAddress = 0;
        std::array<uint8_t, 16> bytes = {};
        if (!AddSlide(target->slide, guard.address, runtimeAddress) ||
            !RangeInside(*target, runtimeAddress, bytes.size())) {
            return fail(SidebarPatchIntegrityFailureImageBounds);
        }
        if (!input->memoryReader(input->memoryReaderContext,
                                 runtimeAddress,
                                 bytes.data(),
                                 bytes.size())) {
            return fail(SidebarPatchIntegrityFailureUnreadableRange);
        }
        if (std::memcmp(bytes.data(), guard.expectedBytes, bytes.size()) != 0) {
            return fail(index < kYMSidebarPatchInstallTargetCount
                            ? SidebarPatchIntegrityFailurePatchBytes
                            : SidebarPatchIntegrityFailureCallBytes);
        }
        if (CC_SHA256_Update(&guardHash,
                             bytes.data(),
                             static_cast<CC_LONG>(bytes.size())) != 1) {
            return fail(SidebarPatchIntegrityFailureHash);
        }
    }
    std::array<uint8_t, kDigestSize> guardDigest = {};
    if (CC_SHA256_Final(guardDigest.data(), &guardHash) != 1) {
        return fail(SidebarPatchIntegrityFailureHash);
    }

    HashResult fileHash = [self hashPath:target->path];
    if (fileHash.failure != SidebarPatchIntegrityFailureNone) {
        return fail(fileHash.failure);
    }
    if (!YMSidebarPatchDigestMatches(
            *profile,
            fileHash.digest.data(),
            fileHash.digest.size())) {
        return fail(SidebarPatchIntegrityFailureSHAMismatch);
    }

    NSString *path = [NSString stringWithUTF8String:target->path];
    if (path == nil) {
        return fail(SidebarPatchIntegrityFailureWrongPath);
    }
    SidebarPatchPreflightReceipt *receipt = [[SidebarPatchPreflightReceipt alloc]
        initWithPath:path
        fileIdentity:fileHash.identity
        fileSHA256:HexDigest(fileHash.digest.data(), fileHash.digest.size())
        loadedImage:*target
        guardSHA256:HexDigest(guardDigest.data(), guardDigest.size())
        installAttempt:input->installAttempt];
    if (receipt == nil) {
        return fail(SidebarPatchIntegrityFailureHash);
    }
    _consumedAttempts.insert(input->installAttempt);
    return {SidebarPatchIntegrityFailureNone, receipt};
}

@end

YMSidebarPatchFileOperations
YMSidebarPatchSystemFileOperations(void) {
    return {nullptr, SystemOpen, SystemStat, SystemRead, SystemClose};
}

NSString *YMSidebarPatchFailureName(
    SidebarPatchIntegrityFailure failure) {
    switch (failure) {
        case SidebarPatchIntegrityFailureNone: return @"none";
        case SidebarPatchIntegrityFailureInvalidInput: return @"invalidInput";
        case SidebarPatchIntegrityFailureImageNotFound: return @"imageNotFound";
        case SidebarPatchIntegrityFailureImageAmbiguous: return @"imageAmbiguous";
        case SidebarPatchIntegrityFailureWrongPath: return @"wrongPath";
        case SidebarPatchIntegrityFailureOpen: return @"openFailure";
        case SidebarPatchIntegrityFailureStat: return @"statFailure";
        case SidebarPatchIntegrityFailureClose: return @"closeFailure";
        case SidebarPatchIntegrityFailureNotRegularFile: return @"notRegularFile";
        case SidebarPatchIntegrityFailureRead: return @"readFailure";
        case SidebarPatchIntegrityFailureHash: return @"hashFailure";
        case SidebarPatchIntegrityFailureSHAMismatch: return @"shaMismatch";
        case SidebarPatchIntegrityFailurePathReplaced: return @"pathReplaced";
        case SidebarPatchIntegrityFailureIdentityMismatch: return @"identityMismatch";
        case SidebarPatchIntegrityFailureUUIDMismatch: return @"uuidMismatch";
        case SidebarPatchIntegrityFailureImageBounds: return @"imageBounds";
        case SidebarPatchIntegrityFailureUnreadableRange: return @"unreadableRange";
        case SidebarPatchIntegrityFailurePatchBytes: return @"patchBytes";
        case SidebarPatchIntegrityFailureCallBytes: return @"callBytes";
        case SidebarPatchIntegrityFailureInstallAttemptReuse:
            return @"installAttemptReuse";
    }
    return @"unknown";
}

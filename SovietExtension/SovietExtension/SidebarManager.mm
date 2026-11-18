#import "RevokePatch.h"
#import "SidebarManager.h"
#import "SidebarPatchIntegrity.h"
#import "SidebarPatch.h"
#import "SidebarRuntime.h"

#import <Foundation/Foundation.h>
#import <libkern/OSCacheControl.h>
#import <mach/arm/thread_status.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <mach-o/utils.h>
#import <sys/mman.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>

namespace config = ym::sidebar;
namespace adapter = ym::sidebar::native_adapter;
namespace component_bridge = ym::sidebar::patch_guard;
namespace component_patch = ym::sidebar::patch_guard::patch_eligibility;
namespace diagnostic = ym::sidebar::diagnostic;
namespace manager_orchestration = ym::sidebar::manager_orchestration;
namespace manager_patch = ym::sidebar::manager_patch;
namespace runtime = ym::sidebar::native_runtime;
namespace native_title = ym::sidebar::native_title;
namespace patch = ym::sidebar::patch;
namespace persistence = ym::sidebar::persistence;

NSNotificationName const YMNavigationSidebarStateDidChangeNotification =
    @"YMNavigationSidebarStateDidChangeNotification";
NSErrorDomain const YMNavigationSidebarErrorDomain =
    @"com.mustangym.SovietExtension.NavigationSidebar";

static NSString *const YMNavigationSidebarV2DefaultsKey =
    @"YMNavigationSidebarConfigurationV2.SOVIET";
static NSString *const YMNavigationSidebarVersionKey = @"version";
static NSString *const YMNavigationSidebarStatesKey = @"states";
static NSString *const YMNavigationSidebarPrimaryOrderKey = @"primaryOrder";
static NSString *const YMNavigationSidebarSecondaryOrderKey = @"secondaryOrder";
static NSString *const YMNavigationSidebarExposeSecondaryKey =
    @"exposeSecondaryEntries";

static const YMNavigationSidebarBuildProfile &YMNavigationSidebarProfile() {
    static const auto *profile = [] {
        NSBundle *bundle = NSBundle.mainBundle;
        const auto *target = YMSidebarPatchProfileForIdentity({bundle.bundleIdentifier.UTF8String,
            [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String],
            [[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String], "arm64"});
        return target ? target->sidebarProfile : &YMNavigationSidebarWeChat411BuildProfile;
    }();
    return *profile;
}

using YMNavigationSidebarOwnerFunction = void (*)(void *);
using YMNavigationSidebarMainWindowDestructor = void *(*)(void *);
using YMNavigationSidebarLookupItem = void *(*)(void *, int);
using YMNavigationSidebarSetVisible = void (*)(void *, bool);
using YMNavigationSidebarPrimarySelector = void (*)(void *, int);
using YMNavigationSidebarSelectedPrimaryGetter = int (*)(void *);
using YMNavigationSidebarOverflowClear = void (*)(void *);
using YMNavigationSidebarOverflowAppend = void (*)(void *, const int *);
using YMNavigationSidebarMoreSetVisible = void (*)(void *, bool);
using YMNavigationSidebarMoreSetBadge = void (*)(void *, unsigned int);
using YMNavigationSidebarMoreCountGetter = unsigned int (*)(void *);
using YMNavigationSidebarNativeTitleFromUtf8Function =
    void *(*)(const char *, std::size_t);
using YMNavigationSidebarMoreTitleFormatGetter = const char *(*)();
using YMNavigationSidebarMoreTitleSetter =
    void (*)(void *, const native_title::Temporary *);
using YMNavigationSidebarNativeTitleDeallocate =
    void (*)(void *, std::size_t, std::size_t);

extern "C" {
__attribute__((visibility("hidden")))
void *YMNavigationSidebarPrimaryOrderTrampoline = nullptr;
__attribute__((visibility("hidden")))
void *YMNavigationSidebarSecondaryOrderTrampoline = nullptr;

__attribute__((visibility("hidden")))
void YMNavigationSidebarPrimaryOrderHook(void);
__attribute__((visibility("hidden")))
void YMNavigationSidebarSecondaryOrderHook(void);
__attribute__((visibility("hidden")))
void YMNavigationSidebarFormatNativeTitle(native_title::Temporary *,
                                          const char *,
                                          std::uint64_t,
                                          void *);
}

static std::atomic_bool YMNavigationSidebarSupported(false);
static std::atomic<void *> YMNavigationSidebarOwner(nullptr);
static std::mutex YMNavigationSidebarStateMutex;
static config::Configuration YMNavigationSidebarDesiredConfiguration;
static runtime::OwnerScopedAppliedSnapshot YMNavigationSidebarAppliedSnapshot;
static adapter::OwnerOrderAvailability YMNavigationSidebarOrderAvailability;
static std::mutex YMNavigationSidebarInstallMutex;
static thread_local bool YMNavigationSidebarApplyingLayout = false;

static SidebarPatchIntegrity *const
    YMNavigationSidebarComponentIntegrity =
        [[SidebarPatchIntegrity alloc] init];
static component_patch::Orchestration
    YMNavigationSidebarComponentOrchestration;
static std::atomic<std::uint64_t>
    YMNavigationSidebarComponentInstallAttempt(0);
static __strong SidebarPatchPreflightReceipt *
    YMNavigationSidebarComponentPendingReceipt = nil;
static __strong SidebarPatchPreflightReceipt *
    YMNavigationSidebarComponentActiveReceipt = nil;

static void *YMNavigationSidebarResponsiveLayoutTrampoline = nullptr;
static void *YMNavigationSidebarPopulateEntriesTrampoline = nullptr;
static void *YMNavigationSidebarDestructorTrampoline = nullptr;
static diagnostic::SecondaryActivationOriginal
    YMNavigationSidebarSecondaryActivationTrampoline = nullptr;
static std::mutex YMNavigationSidebarDiagnosticMutex;
static diagnostic::State YMNavigationSidebarDiagnosticState;
static std::atomic<std::uint64_t> YMNavigationSidebarDiagnosticTick(0);

// Observable from a read-only lldb attach: 1 once the collapsed->expanded flip has
// been committed for the live owner, 0 while WeChat is natively expanded or the
// preflight declined to write.
static std::atomic<std::uint8_t> YMNavigationSidebarForcedExpandedLayout{0};

static YMNavigationSidebarLookupItem YMNavigationSidebarFindSecondaryItem =
    nullptr;
static YMNavigationSidebarLookupItem YMNavigationSidebarLookupNativeItem =
    nullptr;
static YMNavigationSidebarPrimarySelector YMNavigationSidebarSelectPrimary =
    nullptr;
static YMNavigationSidebarSelectedPrimaryGetter
    YMNavigationSidebarGetSelectedPrimary = nullptr;
static YMNavigationSidebarOverflowClear YMNavigationSidebarClearOverflow =
    nullptr;
static YMNavigationSidebarOverflowAppend YMNavigationSidebarAppendOverflow =
    nullptr;
static YMNavigationSidebarMoreSetVisible YMNavigationSidebarSetMoreVisible =
    nullptr;
static YMNavigationSidebarMoreSetBadge YMNavigationSidebarSetMoreBadge =
    nullptr;
static YMNavigationSidebarMoreCountGetter YMNavigationSidebarGetMoreCount =
    nullptr;
static YMNavigationSidebarNativeTitleFromUtf8Function
    YMNavigationSidebarNativeTitleFromUtf8 = nullptr;
static YMNavigationSidebarMoreTitleFormatGetter
    YMNavigationSidebarGetMoreTitleFormat = nullptr;
static void *YMNavigationSidebarNativeTitleFormatter = nullptr;
static YMNavigationSidebarNativeTitleDeallocate
    YMNavigationSidebarDeallocateNativeTitle = nullptr;
static YMNavigationSidebarMoreTitleSetter YMNavigationSidebarSetMoreTitle =
    nullptr;
static YMNavigationSidebarOwnerFunction YMNavigationSidebarPostLayout = nullptr;

using YMNavigationSidebarRowStateFunction = void (*)(void *item);
static YMNavigationSidebarRowStateFunction YMNavigationSidebarSelectRow =
    nullptr;
static YMNavigationSidebarRowStateFunction YMNavigationSidebarDeselectRow =
    nullptr;
static void *YMNavigationSidebarClickSelectionTrampoline = nullptr;


static constexpr std::size_t YMNavigationSidebarPatchStageCount =
    diagnostic::kNormalPatchStageCount;

#pragma mark - Foundation 工具

static bool YMNavigationSidebarLoadPointerMember(
    void *owner,
    std::uintptr_t offset,
    void *&output) noexcept;

static bool YMNavigationSidebarReadComponentCandidate(
    std::uint64_t ownerIdentity,
    std::uint64_t offset,
    std::uint64_t &candidateIdentity) {
    void *candidate = nullptr;
    if (offset != component_bridge::kComponentSurfaceOffset ||
        !YMNavigationSidebarLoadPointerMember(
            reinterpret_cast<void *>(ownerIdentity),
            YMNavigationSidebarProfile().componentSurfaceOffset, candidate)) {
        return false;
    }
    candidateIdentity = reinterpret_cast<std::uint64_t>(candidate);
    return true;
}

static NSError *YMNavigationSidebarError(
    YMNavigationSidebarErrorCode code,
    NSString *message,
    NSDictionary<NSString *, id> *details = nil) {
    NSMutableDictionary<NSString *, id> *userInfo =
        [NSMutableDictionary dictionaryWithObject:message
                                           forKey:NSLocalizedDescriptionKey];
    if (details != nil) {
        [userInfo addEntriesFromDictionary:details];
    }
    return [NSError errorWithDomain:YMNavigationSidebarErrorDomain
                               code:code
                           userInfo:userInfo];
}

static NSString *YMNavigationSidebarString(std::string_view value) {
    NSString *string =
        [[NSString alloc] initWithBytes:value.data()
                                length:value.size()
                              encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static BOOL YMNavigationSidebarNSNumberIsBoolean(id value) {
    return value != nil &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static bool YMNavigationSidebarNSStringToString(NSString *value,
                                                std::string &output) {
    if (![value isKindOfClass:NSString.class]) {
        return false;
    }
    const char *bytes = value.UTF8String;
    if (bytes == nullptr) {
        return false;
    }
    const NSUInteger length =
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    output.assign(bytes, length);
    return true;
}

#pragma mark - 配置桥接：Foundation ↔ PropertyList

static bool YMNavigationSidebarFoundationToPropertyList(
    id value,
    config::PropertyList &output) {
    @try {
        try {
            if (![value isKindOfClass:NSDictionary.class]) {
                return false;
            }
            NSDictionary *dictionary = (NSDictionary *)value;
            // 4 = 未带 exposeSecondaryEntries 的旧配置；5 = 当前格式。
            if (dictionary.count != 4 && dictionary.count != 5) {
                return false;
            }

            id versionValue = dictionary[YMNavigationSidebarVersionKey];
            id statesValue = dictionary[YMNavigationSidebarStatesKey];
            id primaryOrderValue =
                dictionary[YMNavigationSidebarPrimaryOrderKey];
            id secondaryOrderValue =
                dictionary[YMNavigationSidebarSecondaryOrderKey];
            if (![versionValue isKindOfClass:NSNumber.class] ||
                YMNavigationSidebarNSNumberIsBoolean(versionValue) ||
                CFNumberIsFloatType((__bridge CFNumberRef)versionValue) ||
                ![statesValue isKindOfClass:NSDictionary.class] ||
                ![primaryOrderValue isKindOfClass:NSArray.class] ||
                ![secondaryOrderValue isKindOfClass:NSArray.class]) {
                return false;
            }

            config::PropertyList parsed;
            parsed.version = [versionValue longLongValue];
            NSDictionary *states = (NSDictionary *)statesValue;
            for (id key in states) {
                id stateValue = states[key];
                if (![key isKindOfClass:NSString.class] ||
                    !YMNavigationSidebarNSNumberIsBoolean(stateValue)) {
                    return false;
                }
                std::string identifier;
                if (!YMNavigationSidebarNSStringToString(
                        (NSString *)key, identifier)) {
                    return false;
                }
                parsed.states.emplace(std::move(identifier),
                                      [stateValue boolValue]);
            }

            for (id identifierValue in (NSArray *)primaryOrderValue) {
                std::string identifier;
                if (![identifierValue isKindOfClass:NSString.class] ||
                    !YMNavigationSidebarNSStringToString(
                        (NSString *)identifierValue, identifier)) {
                    return false;
                }
                parsed.primaryOrder.emplace_back(std::move(identifier));
            }
            for (id identifierValue in (NSArray *)secondaryOrderValue) {
                std::string identifier;
                if (![identifierValue isKindOfClass:NSString.class] ||
                    !YMNavigationSidebarNSStringToString(
                        (NSString *)identifierValue, identifier)) {
                    return false;
                }
                parsed.secondaryOrder.emplace_back(std::move(identifier));
            }
            id exposeValue = dictionary[YMNavigationSidebarExposeSecondaryKey];
            if (exposeValue != nil &&
                (![exposeValue isKindOfClass:NSNumber.class] ||
                 !YMNavigationSidebarNSNumberIsBoolean(exposeValue))) {
                return false;
            }
            parsed.exposeSecondaryEntries =
                exposeValue != nil &&
                [static_cast<NSNumber *>(exposeValue) boolValue];
            output = std::move(parsed);
            return true;
        } catch (...) {
            return false;
        }
    } @catch (__unused NSException *exception) {
        return false;
    }
}

static NSDictionary<NSString *, id> *
YMNavigationSidebarFoundationPropertyList(
    const config::PropertyList &propertyList) {
    @try {
        NSMutableDictionary<NSString *, NSNumber *> *states =
            [NSMutableDictionary dictionaryWithCapacity:propertyList.states.size()];
        for (const auto &[identifier, enabled] : propertyList.states) {
            NSString *key = YMNavigationSidebarString(identifier);
            if (key.length == 0 && !identifier.empty()) {
                return nil;
            }
            states[key] = @(enabled);
        }

        NSMutableArray<NSString *> *primaryOrder =
            [NSMutableArray arrayWithCapacity:propertyList.primaryOrder.size()];
        for (const std::string &identifier : propertyList.primaryOrder) {
            [primaryOrder addObject:YMNavigationSidebarString(identifier)];
        }
        NSMutableArray<NSString *> *secondaryOrder =
            [NSMutableArray arrayWithCapacity:propertyList.secondaryOrder.size()];
        for (const std::string &identifier : propertyList.secondaryOrder) {
            [secondaryOrder addObject:YMNavigationSidebarString(identifier)];
        }

        return @{
            YMNavigationSidebarVersionKey : @(propertyList.version),
            YMNavigationSidebarStatesKey : [states copy],
            YMNavigationSidebarPrimaryOrderKey : [primaryOrder copy],
            YMNavigationSidebarSecondaryOrderKey : [secondaryOrder copy],
            YMNavigationSidebarExposeSecondaryKey :
                @(propertyList.exposeSecondaryEntries),
        };
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

#pragma mark - 旧版 defaults 兼容

static NSString *YMNavigationSidebarLegacyDefaultsKey(int type) {
    switch (type) {
        case 1:
            return @"YMNavigationSidebarChatFilesEnabled.SOVIET";
        case 2:
            return @"YMNavigationSidebarMomentsEnabled.SOVIET";
        case 3:
            return @"YMNavigationSidebarChannelsEnabled.SOVIET";
        case 5:
            return @"YMNavigationSidebarSearchEnabled.SOVIET";
        case 6:
            return @"YMNavigationSidebarMiniProgramsEnabled.SOVIET";
        case 7:
            return @"YMNavigationSidebarGameCenterEnabled.SOVIET";
        default:
            return nil;
    }
}

static std::optional<config::Entry> YMNavigationSidebarLegacyEntry(int type) {
    return adapter::EntryForLegacySecondaryType(type);
}

static config::LegacyVisibility YMNavigationSidebarLegacyVisibilityFromDefaults(
    NSUserDefaults *defaults) {
    config::LegacyVisibility legacy;
    legacy.setChatFiles(
        [defaults boolForKey:YMNavigationSidebarLegacyDefaultsKey(1)]);
    legacy.set(config::Entry::secondaryMoments,
               [defaults boolForKey:YMNavigationSidebarLegacyDefaultsKey(2)]);
    legacy.set(config::Entry::secondaryChannels,
               [defaults boolForKey:YMNavigationSidebarLegacyDefaultsKey(3)]);
    legacy.set(config::Entry::secondarySearch,
               [defaults boolForKey:YMNavigationSidebarLegacyDefaultsKey(5)]);
    legacy.set(config::Entry::secondaryMiniPrograms,
               [defaults boolForKey:YMNavigationSidebarLegacyDefaultsKey(6)]);
    legacy.set(config::Entry::secondaryGameCenter,
               [defaults boolForKey:YMNavigationSidebarLegacyDefaultsKey(7)]);
    return legacy;
}

#pragma mark - 配置状态

static bool YMNavigationSidebarOrdersForConfiguration(
    const config::Configuration &configuration,
    runtime::Orders &orders) noexcept {
    return manager_orchestration::ConfigurationOrders(configuration, orders);
}

static bool YMNavigationSidebarSetDesiredConfiguration(
    const config::Configuration &configuration) {
    runtime::Orders orders;
    if (!YMNavigationSidebarOrdersForConfiguration(configuration, orders)) {
        return false;
    }
    std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
    if (!YMNavigationSidebarAppliedSnapshot.SetDesiredOrders(orders)) {
        return false;
    }
    YMNavigationSidebarDesiredConfiguration = configuration;
    return true;
}

static void YMNavigationSidebarPublishDesiredConfiguration(
    const config::Configuration &configuration,
    const runtime::Orders &orders) noexcept {
    std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
    static_cast<void>(YMNavigationSidebarAppliedSnapshot.SetDesiredOrders(orders));
    YMNavigationSidebarDesiredConfiguration = configuration;
}

static config::Configuration YMNavigationSidebarConfigurationSnapshot(void) {
    std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
    return YMNavigationSidebarDesiredConfiguration;
}

static runtime::Orders YMNavigationSidebarOrdersForOwner(const void *owner) {
    std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
    const runtime::Orders *applied =
        YMNavigationSidebarAppliedSnapshot.AppliedOrders(owner);
    return applied != nullptr ? *applied
                              : YMNavigationSidebarAppliedSnapshot.DesiredOrders();
}

static void YMNavigationSidebarNotifyStateChanged(void) {
    void (^notification)(void) = ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:YMNavigationSidebarStateDidChangeNotification
                          object:[SidebarManager sharedManager]];
    };
    if (NSThread.isMainThread) {
        notification();
    } else {
        dispatch_async(dispatch_get_main_queue(), notification);
    }
}

#pragma mark - Owner 捕获与顺序可用性

static runtime::Orders YMNavigationSidebarCaptureOwner(void *owner) {
    bool changed = false;
    runtime::Orders orders;
    if (owner != nullptr) {
        component_bridge::OwnerBridge &componentOwnerBridge =
            component_bridge::SharedSidebarPatchOwnerBridge();
        componentOwnerBridge.setCandidateReader(
            &YMNavigationSidebarReadComponentCandidate);
        static_cast<void>(componentOwnerBridge.captureOwner(
            reinterpret_cast<std::uint64_t>(owner),
            0,
            componentOwnerBridge.currentToken()));
        void *previous =
            YMNavigationSidebarOwner.exchange(owner, std::memory_order_acq_rel);
        changed = previous != owner;
        std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
        static_cast<void>(YMNavigationSidebarOrderAvailability.Capture(owner));
        const runtime::Orders *applied =
            YMNavigationSidebarAppliedSnapshot.CaptureApplied(owner);
        orders = applied != nullptr
                     ? *applied
                     : YMNavigationSidebarAppliedSnapshot.DesiredOrders();
    }
    if (changed) {
        YMNavigationSidebarNotifyStateChanged();
    }
    return orders;
}

static void YMNavigationSidebarSetOrderAvailability(
    void *owner,
    config::Group group,
    bool available) {
    bool changed = false;
    {
        std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
        changed = YMNavigationSidebarOrderAvailability.Set(
            owner, group, available);
    }
    if (changed) {
        YMNavigationSidebarNotifyStateChanged();
    }
}

#pragma mark - 持久化

static bool YMNavigationSidebarLoadConfiguration(
    NSUserDefaults *defaults,
    config::Configuration &output) {
    id storedValue = [defaults objectForKey:YMNavigationSidebarV2DefaultsKey];
    if (storedValue != nil) {
        config::PropertyList stored;
        if (!YMNavigationSidebarFoundationToPropertyList(storedValue, stored)) {
            return false;
        }
        const config::ValidationResult normalized =
            config::NormalizeStoredConfiguration(stored);
        if (normalized.configuration() == nullptr) {
            return false;
        }
        output = *normalized.configuration();
        return true;
    }

    const config::ValidationResult migrated = persistence::LoadV2OrLegacy(
        std::nullopt,
        YMNavigationSidebarLegacyVisibilityFromDefaults(defaults));
    if (migrated.configuration() == nullptr) {
        return false;
    }
    output = *migrated.configuration();
    return true;
}

static bool YMNavigationSidebarDefaultsRead(
    void *context,
    std::string_view key,
    std::optional<config::PropertyList> &output) noexcept {
    @autoreleasepool {
        @try {
            try {
                if (key != persistence::kAuthoritativeKey || context == nullptr) {
                    return false;
                }
                NSUserDefaults *defaults = (__bridge NSUserDefaults *)context;
                id stored = [defaults objectForKey:YMNavigationSidebarV2DefaultsKey];
                if (stored == nil) {
                    output.reset();
                    return true;
                }
                config::PropertyList propertyList;
                if (!YMNavigationSidebarFoundationToPropertyList(
                        stored, propertyList)) {
                    return false;
                }
                output = std::move(propertyList);
                return true;
            } catch (...) {
                return false;
            }
        } @catch (__unused NSException *exception) {
            return false;
        }
    }
}

static bool YMNavigationSidebarDefaultsWrite(
    void *context,
    std::string_view key,
    const config::PropertyList &propertyList) noexcept {
    @autoreleasepool {
        @try {
            if (key != persistence::kAuthoritativeKey || context == nullptr) {
                return false;
            }
            NSDictionary<NSString *, id> *value =
                YMNavigationSidebarFoundationPropertyList(propertyList);
            if (value == nil) {
                return false;
            }
            NSUserDefaults *defaults = (__bridge NSUserDefaults *)context;
            [defaults setObject:value forKey:YMNavigationSidebarV2DefaultsKey];
            return true;
        } @catch (__unused NSException *exception) {
            return false;
        }
    }
}

static bool YMNavigationSidebarDefaultsRemove(
    void *context,
    std::string_view key) noexcept {
    @autoreleasepool {
        @try {
            if (key != persistence::kAuthoritativeKey || context == nullptr) {
                return false;
            }
            NSUserDefaults *defaults = (__bridge NSUserDefaults *)context;
            [defaults removeObjectForKey:YMNavigationSidebarV2DefaultsKey];
            return true;
        } @catch (__unused NSException *exception) {
            return false;
        }
    }
}

static bool YMNavigationSidebarDefaultsSynchronize(void *context) noexcept {
    @autoreleasepool {
        @try {
            if (context == nullptr) {
                return false;
            }
            return [(__bridge NSUserDefaults *)context synchronize];
        } @catch (__unused NSException *exception) {
            return false;
        }
    }
}

static persistence::StorageAdapter YMNavigationSidebarStorageAdapter(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return {
        (__bridge void *)defaults,
        &YMNavigationSidebarDefaultsRead,
        &YMNavigationSidebarDefaultsWrite,
        &YMNavigationSidebarDefaultsRemove,
        &YMNavigationSidebarDefaultsSynchronize,
    };
}

static NSString *YMNavigationSidebarSaveErrorDescription(
    persistence::SaveErrorCode code) {
    switch (code) {
        case persistence::SaveErrorCode::invalidAdapter:
            return @"配置存储适配器不可用。";
        case persistence::SaveErrorCode::invalidInput:
            return @"侧边栏配置格式无效。";
        case persistence::SaveErrorCode::allPrimaryDisabled:
            return @"主导航至少需要保留一个入口。";
        case persistence::SaveErrorCode::readFailure:
            return @"无法读取保存前的侧边栏配置。";
        case persistence::SaveErrorCode::writeFailure:
            return @"无法写入侧边栏配置。";
        case persistence::SaveErrorCode::synchronizeFailure:
            return @"无法同步侧边栏配置。";
        case persistence::SaveErrorCode::readbackFailure:
        case persistence::SaveErrorCode::readbackMissing:
        case persistence::SaveErrorCode::readbackMalformed:
        case persistence::SaveErrorCode::semanticMismatch:
            return @"侧边栏配置写入后校验失败。";
        case persistence::SaveErrorCode::none:
            return @"";
    }
}

static NSError *YMNavigationSidebarPersistenceError(
    const persistence::SaveResult &result) {
    NSMutableDictionary<NSString *, id> *details =
        [@{
            @"saveErrorCode" : @(static_cast<unsigned int>(result.error())),
            @"rollbackErrorCode" :
                @(static_cast<unsigned int>(result.rollbackError())),
        } mutableCopy];
    if (const config::ValidationError *validation = result.validationError()) {
        details[@"validationCode"] =
            @(static_cast<unsigned int>(validation->code));
        details[@"validationIdentifier"] =
            YMNavigationSidebarString(validation->identifier);
    }
    const YMNavigationSidebarErrorCode code =
        result.rollbackAttempted && !result.rollbackSucceeded()
            ? YMNavigationSidebarErrorPersistenceRollback
            : YMNavigationSidebarErrorPersistence;
    return YMNavigationSidebarError(
        code, YMNavigationSidebarSaveErrorDescription(result.error()), details);
}

#pragma mark - 内存保护与诊断

static bool YMNavigationSidebarRangeHasProtection(
    std::uintptr_t address,
    std::size_t size,
    vm_prot_t required) noexcept {
    if (address == 0 || size == 0 ||
        address > std::numeric_limits<std::uintptr_t>::max() - size) {
        return false;
    }
    const mach_vm_address_t rangeEnd = address + size;
    mach_vm_address_t cursor = address;
    while (cursor < rangeEnd) {
        mach_vm_address_t regionAddress = cursor;
        mach_vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t information{};
        mach_msg_type_number_t informationCount =
            VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objectName = MACH_PORT_NULL;
        const kern_return_t result = mach_vm_region(
            mach_task_self(),
            &regionAddress,
            &regionSize,
            VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&information),
            &informationCount,
            &objectName);
        if (objectName != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), objectName);
        }
        if (result != KERN_SUCCESS || regionAddress > cursor || regionSize == 0 ||
            (information.protection & required) != required ||
            regionAddress > std::numeric_limits<mach_vm_address_t>::max() -
                                regionSize) {
            return false;
        }
        const mach_vm_address_t regionEnd = regionAddress + regionSize;
        if (regionEnd <= cursor) {
            return false;
        }
        cursor = regionEnd < rangeEnd ? regionEnd : rangeEnd;
    }
    return true;
}

static bool YMNavigationSidebarDiagnosticStateReadable(
    void *, const void *state, std::size_t length) noexcept {
    return YMNavigationSidebarRangeHasProtection(
        reinterpret_cast<std::uintptr_t>(state), length, VM_PROT_READ);
}

static bool YMNavigationSidebarDiagnosticLogSink(
    void *,
    const diagnostic::Record &record,
    const char *bytes,
    std::size_t length) {
    if (bytes == nullptr || length == 0 || length > 384) {
        return false;
    }
    YMLog(@"[YMNavigationSidebarDiagnostic] %.*s",
          static_cast<int>(length),
          bytes);
    (void)record;
    return true;
}

static void YMNavigationSidebarObserveSecondaryActivation(
    void *, const diagnostic::Record &record) noexcept {
    const std::uint64_t tick =
        YMNavigationSidebarDiagnosticTick.fetch_add(
            1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(YMNavigationSidebarDiagnosticMutex);
    static_cast<void>(diagnostic::EmitActivation(
        YMNavigationSidebarDiagnosticState,
        tick,
        record,
        nullptr,
        &YMNavigationSidebarDiagnosticLogSink));
}

static void YMNavigationSidebarSecondaryActivationHook(
    std::uint32_t operation,
    void *state,
    std::uint64_t x2,
    void *x3) {
    diagnostic::ObserveSecondaryActivationAndForward(
        operation,
        state,
        x2,
        x3,
        nullptr,
        &YMNavigationSidebarDiagnosticStateReadable,
        &YMNavigationSidebarObserveSecondaryActivation,
        YMNavigationSidebarSecondaryActivationTrampoline);
}

#pragma mark - 镜像校验与原生成员读取

static bool YMNavigationSidebarLoadedImageUUIDMatches(
    const struct mach_header *header) noexcept {
    constexpr std::size_t headerSize = 32;
    const std::uintptr_t address = reinterpret_cast<std::uintptr_t>(header);
    if (header == nullptr ||
        !YMNavigationSidebarRangeHasProtection(
            address, headerSize, VM_PROT_READ)) {
        return false;
    }
    std::uint32_t commandBytes = 0;
    std::memcpy(&commandBytes,
                reinterpret_cast<const std::uint8_t *>(header) + 20,
                sizeof(commandBytes));
    const std::size_t imageHeaderSize = headerSize + commandBytes;
    return YMNavigationSidebarRangeHasProtection(
               address, imageHeaderSize, VM_PROT_READ) &&
           YMNavigationSidebarVerifyMachOUUID(
               YMNavigationSidebarProfile(),
               reinterpret_cast<const std::uint8_t *>(header),
               imageHeaderSize);
}

static bool YMNavigationSidebarCodeMatches(
    std::uintptr_t address,
    const std::uint8_t expected[16]) noexcept {
    return YMNavigationSidebarRangeHasProtection(
               address, 16, VM_PROT_READ | VM_PROT_EXECUTE) &&
           std::memcmp(reinterpret_cast<const void *>(address), expected, 16) ==
               0;
}

static bool YMNavigationSidebarLoadPointerMember(
    void *owner,
    std::uintptr_t offset,
    void *&output) noexcept {
    if (owner == nullptr ||
        reinterpret_cast<std::uintptr_t>(owner) >
            std::numeric_limits<std::uintptr_t>::max() - offset) {
        return false;
    }
    const std::uintptr_t address =
        reinterpret_cast<std::uintptr_t>(owner) + offset;
    if (!YMNavigationSidebarRangeHasProtection(
            address, sizeof(output), VM_PROT_READ)) {
        return false;
    }
    std::memcpy(&output, reinterpret_cast<const void *>(address), sizeof(output));
    return output != nullptr;
}

static bool YMNavigationSidebarNativeTypeRangeIsReadable(
    void *,
    std::uintptr_t address,
    std::size_t length) {
    return YMNavigationSidebarRangeHasProtection(
        address, length, VM_PROT_READ);
}

static int YMNavigationSidebarReadNativeType(const void *item) noexcept {
    return YMNavigationSidebarReadNativeItemType(
        item, &YMNavigationSidebarNativeTypeRangeIsReadable, nullptr);
}

// Type reader for order-getter and overflow SLOTS, which point at bare
// four-byte type cells rather than sidebar items. Using the item reader here
// reads 276 bytes past a four-byte allocation; the known-type guard then
// rejects it, so the reorder fails silently. See
// kYMNavigationSidebarOrderSlotTypeOffset.
static int YMNavigationSidebarReadOrderSlotType(const void *slot) noexcept {
    return YMNavigationSidebarReadNativeOrderSlotType(
        slot, &YMNavigationSidebarNativeTypeRangeIsReadable, nullptr);
}

#pragma mark - 主导航可见性

static bool YMNavigationSidebarResolveSetVisible(
    void *item,
    YMNavigationSidebarSetVisible &output) noexcept {
    if (item == nullptr ||
        !YMNavigationSidebarRangeHasProtection(
            reinterpret_cast<std::uintptr_t>(item),
            sizeof(std::uintptr_t),
            VM_PROT_READ)) {
        return false;
    }
    std::uintptr_t vtable = 0;
    std::memcpy(&vtable, item, sizeof(vtable));
    if (vtable == 0 ||
        vtable > std::numeric_limits<std::uintptr_t>::max() -
                     kYMNavigationSidebarVisibilityVtableOffset) {
        return false;
    }
    const std::uintptr_t slot =
        vtable + kYMNavigationSidebarVisibilityVtableOffset;
    if (!YMNavigationSidebarRangeHasProtection(
            slot, sizeof(output), VM_PROT_READ)) {
        return false;
    }
    std::memcpy(&output, reinterpret_cast<const void *>(slot), sizeof(output));
    return output != nullptr &&
           YMNavigationSidebarRangeHasProtection(
               reinterpret_cast<std::uintptr_t>(output), 4, VM_PROT_EXECUTE);
}

enum class YMNavigationSidebarPrimaryPrepareFailure : std::uint8_t {
    none,
    unavailable,
    invalidSelection,
    fallbackVerification,
    itemUnavailable,
};

struct YMNavigationSidebarPrimaryApplyPlan {
    void *owner{nullptr};
    void *controller{nullptr};
    std::array<void *, 3> items{};
    std::array<YMNavigationSidebarSetVisible, 3> setters{};
    runtime::PrimaryStates states{};
    int originalSelectedType{-1};
    bool selectionChanged{false};
};

static void YMNavigationSidebarRestorePrimarySelection(
    const YMNavigationSidebarPrimaryApplyPlan &plan) noexcept {
    if (!plan.selectionChanged || YMNavigationSidebarSelectPrimary == nullptr ||
        YMNavigationSidebarGetSelectedPrimary == nullptr ||
        plan.owner == nullptr || plan.controller == nullptr ||
        !runtime::EntryForNativeKey(
             config::Group::primary, plan.originalSelectedType)
             .has_value()) {
        return;
    }
    YMNavigationSidebarSelectPrimary(plan.owner, plan.originalSelectedType);
    static_cast<void>(
        YMNavigationSidebarGetSelectedPrimary(plan.controller));
}

static YMNavigationSidebarPrimaryPrepareFailure
YMNavigationSidebarPreparePrimaryVisibility(
    void *owner,
    const config::Configuration &configuration,
    const runtime::PrimaryOrder &appliedOrder,
    YMNavigationSidebarPrimaryApplyPlan &output) noexcept {
    if (owner == nullptr || YMNavigationSidebarLookupNativeItem == nullptr ||
        YMNavigationSidebarSelectPrimary == nullptr ||
        YMNavigationSidebarGetSelectedPrimary == nullptr) {
        return YMNavigationSidebarPrimaryPrepareFailure::unavailable;
    }

    YMNavigationSidebarPrimaryApplyPlan plan;
    plan.owner = owner;
    if (!YMNavigationSidebarLoadPointerMember(
            owner,
            YMNavigationSidebarProfile().primaryControllerOffset,
            plan.controller)) {
        return YMNavigationSidebarPrimaryPrepareFailure::unavailable;
    }

    plan.originalSelectedType =
        YMNavigationSidebarGetSelectedPrimary(plan.controller);
    for (config::Entry entry : runtime::kCanonicalPrimaryOrder) {
        plan.states[runtime::PrimaryIndex(entry)] =
            configuration.isEnabled(entry);
    }
    const runtime::PrimaryFallbackDecision fallback =
        runtime::ChoosePrimaryFallback(
            plan.originalSelectedType, appliedOrder, plan.states);
    if (fallback.action == runtime::PrimaryFallbackAction::invalidInput ||
        fallback.action == runtime::PrimaryFallbackAction::rejectAllDisabled ||
        (fallback.action != runtime::PrimaryFallbackAction::keepUnmanaged &&
         !fallback.target.has_value())) {
        return YMNavigationSidebarPrimaryPrepareFailure::invalidSelection;
    }
    if (fallback.action == runtime::PrimaryFallbackAction::selectFallback) {
        const int targetType = runtime::NativeKeyFor(*fallback.target).type;
        YMNavigationSidebarSelectPrimary(owner, targetType);
        plan.selectionChanged = true;
        if (YMNavigationSidebarGetSelectedPrimary(plan.controller) != targetType) {
            YMNavigationSidebarRestorePrimarySelection(plan);
            return YMNavigationSidebarPrimaryPrepareFailure::fallbackVerification;
        }
    }

    for (std::size_t index = 0; index < plan.items.size(); ++index) {
        plan.items[index] = YMNavigationSidebarLookupNativeItem(
            plan.controller,
            runtime::NativeKeyFor(runtime::kCanonicalPrimaryOrder[index]).type);
        if (plan.items[index] == nullptr ||
            !YMNavigationSidebarResolveSetVisible(
                plan.items[index], plan.setters[index])) {
            YMNavigationSidebarRestorePrimarySelection(plan);
            return YMNavigationSidebarPrimaryPrepareFailure::itemUnavailable;
        }
    }
    output = plan;
    return YMNavigationSidebarPrimaryPrepareFailure::none;
}

static void YMNavigationSidebarCommitPrimaryVisibility(
    const YMNavigationSidebarPrimaryApplyPlan &plan) noexcept {
    for (std::size_t index = 0; index < plan.items.size(); ++index) {
        if (plan.states[index]) {
            plan.setters[index](plan.items[index], true);
        }
    }
    for (std::size_t index = 0; index < plan.items.size(); ++index) {
        if (!plan.states[index] &&
            runtime::kCanonicalPrimaryOrder[index] !=
                config::Entry::primaryChats) {
            plan.setters[index](plan.items[index], false);
        }
    }
}

static bool YMNavigationSidebarApplyPrimaryVisibility(
    void *owner,
    const config::Configuration &configuration,
    const runtime::PrimaryOrder &appliedOrder) noexcept {
    YMNavigationSidebarPrimaryApplyPlan plan;
    if (YMNavigationSidebarPreparePrimaryVisibility(
            owner, configuration, appliedOrder, plan) !=
        YMNavigationSidebarPrimaryPrepareFailure::none) {
        return false;
    }
    YMNavigationSidebarCommitPrimaryVisibility(plan);
    return true;
}

// 把用户的「发现」勾选应用到原生的 type 3 主导航条目。
//
// 发现只管显示、不管排序：微信自己的主导航顺序表（0xE55970）永远把 type 3
// 追在末尾，所以它不进可排序的 primary order，面板把它当固定尾行。
//
// 两种布局下都要跑：折叠布局是微信原生就把发现放在主列表里；开了展开
// 开关时我们的模式翻转必然落在主列表构建之后，折叠态的发现条目会残留并与
// 下方条带重复。只有微信原生就是展开态时主列表里本来就没有发现，此时下面
// 的查找会拿不到条目，函数自然空跑——所以不需要再拿布局标志当门禁。
//
// 每轮布局都重新应用一次，因为微信自己的 responsive 布局会把主导航条目又显示回来。
static void YMNavigationSidebarApplyDiscoverEntryVisibility(
    void *owner,
    const config::Configuration &configuration) noexcept {
    if (owner == nullptr ||
        YMNavigationSidebarLookupNativeItem == nullptr ||
        YMNavigationSidebarGetSelectedPrimary == nullptr ||
        YMNavigationSidebarSelectPrimary == nullptr) {
        return;
    }

    const bool hide = !configuration.isEnabled(config::Entry::primaryDiscover);

    void *controller = nullptr;
    if (!YMNavigationSidebarLoadPointerMember(
            owner, YMNavigationSidebarProfile().primaryControllerOffset, controller) ||
        controller == nullptr) {
        return;
    }
    void *const item = YMNavigationSidebarLookupNativeItem(
        controller, kYMNavigationSidebarPrimaryDiscoverType);
    if (item == nullptr ||
        YMNavigationSidebarReadNativeType(item) !=
            kYMNavigationSidebarPrimaryDiscoverType) {
        return;
    }
    YMNavigationSidebarSetVisible setter = nullptr;
    if (!YMNavigationSidebarResolveSetVisible(item, setter) ||
        setter == nullptr) {
        return;
    }

    if (hide) {
        // Never leave the sidebar sitting on a page we are about to hide.
        const int chatsType =
            runtime::NativeKeyFor(config::Entry::primaryChats).type;
        if (YMNavigationSidebarGetSelectedPrimary(controller) ==
            kYMNavigationSidebarPrimaryDiscoverType) {
            YMNavigationSidebarSelectPrimary(owner, chatsType);
            if (YMNavigationSidebarGetSelectedPrimary(controller) ==
                kYMNavigationSidebarPrimaryDiscoverType) {
                return;
            }
        }
    }
    setter(item, !hide);
}

struct YMNavigationSidebarSecondaryProjectionContext {
    void *owner{nullptr};
    void *overflowHolder{nullptr};
    std::array<std::uintptr_t, 5> items{};
    std::array<YMNavigationSidebarSetVisible, 5> setters{};
    std::uintptr_t moreItem{0};
    YMNavigationSidebarSetVisible moreSetter{nullptr};
};

#pragma mark - 二级组投影与「更多」溢出项

static bool YMNavigationSidebarProjectionReadBadge(
    void *,
    std::uintptr_t item,
    unsigned int *output) noexcept {
    if (item == 0 || output == nullptr ||
        YMNavigationSidebarGetMoreCount == nullptr) {
        return false;
    }
    *output = YMNavigationSidebarGetMoreCount(
        reinterpret_cast<void *>(item));
    return true;
}

static void YMNavigationSidebarProjectionClearOverflow(
    void *rawContext,
    std::uintptr_t owner) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarSecondaryProjectionContext *>(rawContext);
    if (owner == reinterpret_cast<std::uintptr_t>(context.owner)) {
        YMNavigationSidebarClearOverflow(context.overflowHolder);
    }
}

static void YMNavigationSidebarProjectionSetVisible(
    void *rawContext,
    std::uintptr_t item,
    bool visible) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarSecondaryProjectionContext *>(rawContext);
    if (item == context.moreItem) {
        context.moreSetter(reinterpret_cast<void *>(item), visible);
        return;
    }
    for (std::size_t index = 0; index < context.items.size(); ++index) {
        if (context.items[index] == item) {
            context.setters[index](reinterpret_cast<void *>(item), visible);
            return;
        }
    }
}

static void YMNavigationSidebarProjectionAppendOverflow(
    void *rawContext,
    std::uintptr_t owner,
    int type) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarSecondaryProjectionContext *>(rawContext);
    if (owner == reinterpret_cast<std::uintptr_t>(context.owner)) {
        YMNavigationSidebarAppendOverflow(context.overflowHolder, &type);
    }
}

static void YMNavigationSidebarProjectionPublishMoreVisibility(
    void *,
    std::uintptr_t moreItem,
    bool visible) noexcept {
    YMNavigationSidebarSetMoreVisible(
        reinterpret_cast<void *>(moreItem), visible);
}

static void YMNavigationSidebarProjectionSetBadge(
    void *,
    std::uintptr_t moreItem,
    unsigned int badge) noexcept {
    YMNavigationSidebarSetMoreBadge(
        reinterpret_cast<void *>(moreItem), badge);
}

static void YMNavigationSidebarProjectionSetTitle(
    void *,
    std::uintptr_t moreItem,
    const native_title::Temporary *temporary) noexcept {
    YMNavigationSidebarSetMoreTitle(
        reinterpret_cast<void *>(moreItem), temporary);
}

static void YMNavigationSidebarProjectionPostLayout(
    void *,
    std::uintptr_t owner) noexcept {
    YMNavigationSidebarPostLayout(reinterpret_cast<void *>(owner));
}

static bool YMNavigationSidebarApplySecondaryProjection(
    void *owner,
    const config::Configuration &configuration,
    const runtime::SecondaryOrder &appliedOrder,
    const std::array<std::uint8_t, 5> &availability) noexcept {
    if (owner == nullptr || YMNavigationSidebarFindSecondaryItem == nullptr ||
        YMNavigationSidebarClearOverflow == nullptr ||
        YMNavigationSidebarAppendOverflow == nullptr ||
        YMNavigationSidebarSetMoreVisible == nullptr ||
        YMNavigationSidebarSetMoreBadge == nullptr ||
        YMNavigationSidebarGetMoreCount == nullptr ||
        YMNavigationSidebarNativeTitleFromUtf8 == nullptr ||
        YMNavigationSidebarGetMoreTitleFormat == nullptr ||
        YMNavigationSidebarNativeTitleFormatter == nullptr ||
        YMNavigationSidebarDeallocateNativeTitle == nullptr ||
        YMNavigationSidebarSetMoreTitle == nullptr ||
        YMNavigationSidebarPostLayout == nullptr) {
        return false;
    }

    void *controller = nullptr;
    if (!YMNavigationSidebarLoadPointerMember(
            owner,
            YMNavigationSidebarProfile().secondaryControllerOffset,
            controller)) {
        return false;
    }

    manager_orchestration::SecondaryRequest request;
    request.owner = reinterpret_cast<std::uintptr_t>(owner);
    request.appliedOrder = appliedOrder;
    std::array<int, 5> filteredTypes{};
    std::size_t filteredCount = 0;
    YMNavigationSidebarSecondaryProjectionContext callbacks;
    callbacks.owner = owner;
    for (std::size_t index = 0;
         index < kYMNavigationSidebarSecondarySortableTypes.size();
         ++index) {
        const int type = kYMNavigationSidebarSecondarySortableTypes[index];
        const std::optional<config::Entry> entry =
            runtime::EntryForNativeKey(config::Group::secondary, type);
        if (!entry.has_value()) {
            return false;
        }
        const std::size_t itemIndex = runtime::SecondaryIndex(*entry);
        void *const item =
            YMNavigationSidebarFindSecondaryItem(controller, type);
        YMNavigationSidebarSetVisible setter = nullptr;
        if (item != nullptr &&
            !YMNavigationSidebarResolveSetVisible(item, setter)) {
            return false;
        }
        request.items[itemIndex] = {
            type,
            reinterpret_cast<std::uintptr_t>(item),
            configuration.isEnabled(*entry),
            (availability[index] & 1u) != 0,
        };
        callbacks.items[itemIndex] = reinterpret_cast<std::uintptr_t>(item);
        callbacks.setters[itemIndex] = setter;
        if (request.items[itemIndex].enabled &&
            request.items[itemIndex].available && item != nullptr) {
            filteredTypes[filteredCount++] = type;
        }
    }

    const std::uintptr_t ownerAddress =
        reinterpret_cast<std::uintptr_t>(owner);
    if (ownerAddress > std::numeric_limits<std::uintptr_t>::max() -
                           YMNavigationSidebarProfile().overflowOffset) {
        return false;
    }
    callbacks.overflowHolder = reinterpret_cast<void *>(
        ownerAddress + YMNavigationSidebarProfile().overflowOffset);
    // 字段本身必须可读；注意不要把解引用出的 holder 写回 overflowHolder，
    // 原生 clear/append 期望接收字段地址（它们内部自行 ldr 解引用）。
    if (!YMNavigationSidebarRangeHasProtection(
            reinterpret_cast<std::uintptr_t>(callbacks.overflowHolder),
            sizeof(void *),
            VM_PROT_READ)) {
        return false;
    }
    // append 可能刚重新分配过 holder，解引用出的 holder 头部也要先探测再读。
    void *overflowHolderPointee = nullptr;
    std::memcpy(&overflowHolderPointee, callbacks.overflowHolder,
                sizeof(overflowHolderPointee));
    if (overflowHolderPointee == nullptr ||
        !YMNavigationSidebarRangeHasProtection(
            reinterpret_cast<std::uintptr_t>(overflowHolderPointee),
            adapter::kHolderSlotsOffset,
            VM_PROT_READ)) {
        return false;
    }
    std::span<void *> overflowSlots;
    if (!adapter::ParseOverflowSlots(callbacks.overflowHolder, overflowSlots) ||
        (overflowSlots.size() != 0 &&
         !YMNavigationSidebarRangeHasProtection(
             reinterpret_cast<std::uintptr_t>(overflowSlots.data()),
             overflowSlots.size() * sizeof(void *),
             VM_PROT_READ))) {
        return false;
    }
    std::size_t derivedDirectCapacity = 0;
    if (!adapter::DeriveDirectCapacity(
            filteredTypes,
            filteredCount,
            overflowSlots,
            &YMNavigationSidebarReadOrderSlotType,
            derivedDirectCapacity)) {
        return false;
    }
    request.overflowCount = overflowSlots.size();
    for (std::size_t index = 0; index < overflowSlots.size(); ++index) {
        request.overflow[index] = {
            YMNavigationSidebarReadOrderSlotType(overflowSlots[index]),
            reinterpret_cast<std::uintptr_t>(overflowSlots[index]),
        };
    }

    // WeChat only instantiates the type-8 "More" sentinel when the sidebar
    // overflows. Its absence is legitimate (no overflow), so tolerate a null
    // lookup and let the projection apply direct visibility without a More
    // button. A present-but-malformed sentinel (wrong type or an unresolved
    // setter) remains a hard failure.
    void *const moreItem =
        YMNavigationSidebarFindSecondaryItem(controller, 8);
    if (moreItem != nullptr &&
        (YMNavigationSidebarReadNativeType(moreItem) != 8 ||
         !YMNavigationSidebarResolveSetVisible(
             moreItem, callbacks.moreSetter))) {
        return false;
    }
    request.moreItem = reinterpret_cast<std::uintptr_t>(moreItem);
    callbacks.moreItem = request.moreItem;

    const manager_orchestration::SecondaryOperations operations{
        &callbacks,
        &YMNavigationSidebarProjectionReadBadge,
        &YMNavigationSidebarProjectionClearOverflow,
        &YMNavigationSidebarProjectionSetVisible,
        &YMNavigationSidebarProjectionAppendOverflow,
        &YMNavigationSidebarProjectionPublishMoreVisibility,
        &YMNavigationSidebarProjectionSetBadge,
        &YMNavigationSidebarProjectionSetTitle,
        &YMNavigationSidebarProjectionPostLayout,
        {
            YMNavigationSidebarNativeTitleFromUtf8,
            YMNavigationSidebarGetMoreTitleFormat,
            &YMNavigationSidebarFormatNativeTitle,
            YMNavigationSidebarNativeTitleFormatter,
            YMNavigationSidebarDeallocateNativeTitle,
        },
    };
    const manager_orchestration::SecondaryResult result =
        manager_orchestration::ApplySecondaryProjection(request, operations);
    if (!result.succeeded()) {
        return false;
    }
    if (result.directCapacity() != derivedDirectCapacity) {
        return false;
    }
    return true;
}

struct YMNavigationSidebarLayoutScope {
    void *owner;
    std::array<std::uint8_t, 5> saved{};
    std::array<bool, 5> changed{};
    bool active{true};

    void Restore() noexcept {
        if (!active) {
            return;
        }
        for (std::size_t index = 0; index < changed.size(); ++index) {
            if (changed[index]) {
                const int type =
                    kYMNavigationSidebarSecondarySortableTypes[index];
                auto *flag = static_cast<std::uint8_t *>(owner) +
                             YMNavigationSidebarAvailabilityFlagOffset(type, YMNavigationSidebarProfile().availabilityFlagBase);
                *flag = saved[index];
            }
        }
        active = false;
    }

    ~YMNavigationSidebarLayoutScope() {
        Restore();
        YMNavigationSidebarApplyingLayout = false;
    }
};

// Re-arm every secondary availability byte to 1 so the user's saved
// configuration, not WeChat's sidebar-presentation gate, decides what the strip
// shows. Only meaningful under our forced expanded layout; when WeChat is
// natively expanded its own gate is the legitimate authority and we leave it be.
// Preflighted per byte, and never widens memory access beyond a single byte we
// already write elsewhere.
#pragma mark - 布局模式与强制展开

static void YMNavigationSidebarRearmSecondaryAvailability(void *owner) noexcept {
    if (owner == nullptr ||
        YMNavigationSidebarForcedExpandedLayout.load(
            std::memory_order_acquire) == 0) {
        return;
    }
    const std::uintptr_t base = reinterpret_cast<std::uintptr_t>(owner);
    for (const int type : kYMNavigationSidebarSecondarySortableTypes) {
        const std::uintptr_t offset =
            YMNavigationSidebarAvailabilityFlagOffset(type, YMNavigationSidebarProfile().availabilityFlagBase);
        if (offset == 0 ||
            base > std::numeric_limits<std::uintptr_t>::max() - offset) {
            continue;
        }
        const std::uintptr_t address = base + offset;
        if (!YMNavigationSidebarRangeHasProtection(
                address, sizeof(std::uint8_t),
                VM_PROT_READ | VM_PROT_WRITE)) {
            continue;
        }
        *reinterpret_cast<std::uint8_t *>(address) = 1;
    }
}

// 「展开发现与服务」只在启动时由 ForceExpandedLayout 翻转一次布局模式；
// 运行中刚打开开关时 owner 仍是折叠布局，二级控制器/条目根本不存在，
// 二级投影注定失败（保存弹「主导航入口尚未完整初始化」的根源）。
// 读取 owner 的布局模式字节判断是否已展开；读不出来时按折叠处理（保守）。
static bool YMNavigationSidebarOwnerLayoutIsExpanded(void *owner) noexcept {
    if (owner == nullptr) {
        return false;
    }
    const std::uintptr_t base = reinterpret_cast<std::uintptr_t>(owner);
    if (base > std::numeric_limits<std::uintptr_t>::max() -
                   YMNavigationSidebarProfile().layoutModeOffset) {
        return false;
    }
    const std::uintptr_t modeAddress =
        base + YMNavigationSidebarProfile().layoutModeOffset;
    if (!YMNavigationSidebarRangeHasProtection(
            modeAddress, sizeof(std::uint8_t), VM_PROT_READ)) {
        return false;
    }
    const std::uint8_t mode =
        *reinterpret_cast<const std::uint8_t *>(modeAddress);
    return YMNavigationSidebarLayoutModeActionForMode(mode) ==
           YMNavigationSidebarLayoutModeAction::none;
}

static bool YMNavigationSidebarRunResponsiveLayout(void *owner) noexcept {
    if (owner == nullptr || YMNavigationSidebarResponsiveLayoutTrampoline ==
                                nullptr) {
        return false;
    }
    auto original = reinterpret_cast<YMNavigationSidebarOwnerFunction>(
        YMNavigationSidebarResponsiveLayoutTrampoline);
    if (YMNavigationSidebarApplyingLayout) {
        original(owner);
        return true;
    }

    YMNavigationSidebarApplyingLayout = true;
    YMNavigationSidebarLayoutScope scope{owner};
    const config::Configuration configuration =
        YMNavigationSidebarConfigurationSnapshot();
    const runtime::Orders applied = YMNavigationSidebarCaptureOwner(owner);

    // 未开启「展开发现与服务」时，微信处于自己选定的折叠布局：二级条带根本不
    // 存在，重新武装 availability、做二级投影都会把状态改成和当前布局不一致，
    // 表现为条目错位、点击落到别的入口上。这里只跑原生布局并应用主导航可见性。
    // 开关刚打开、布局要等重启才切换时同理：此时 applied 顺序保持旧值，
    // isPendingRestart 会提示「顺序将在重启微信后生效」，保存本身应当成功。
    if (!configuration.exposeSecondaryEntries ||
        !YMNavigationSidebarOwnerLayoutIsExpanded(owner)) {
        original(owner);
        static_cast<void>(YMNavigationSidebarApplyPrimaryVisibility(
            owner, configuration, applied.primary));
        // 折叠布局下发现就在主列表里，而它不属于可排序的 primary
        // order，ApplyPrimaryVisibility 碰不到它，所以这里要单独应用一次。
        YMNavigationSidebarApplyDiscoverEntryVisibility(owner, configuration);
        return true;
    }

    // WeChat's own availability pass (0xE54FB8) overwrites each of these five
    // bytes with a per-feature gate result and force-hides the item to match:
    // MiniPrograms=feature5, Channels=feature6, Search=feature8, Moments=feature9,
    // GameCenter=a dedicated check. On this account the gate answers 0 for
    // Channels and Search, so the layout pass skipped them and the manager's
    // checkboxes for those two could never take effect.
    //
    // That gate is NOT "is the feature usable": it has only five call sites and
    // four of them are that sidebar pass, and the user verified 视频号 and 搜一搜
    // both open and work normally from inside the 发现 panel. It gates sidebar
    // PRESENTATION. Since presentation is exactly what this feature manages,
    // re-arm all five so the saved configuration is the only authority over what
    // the strip shows. Done before the snapshot below, so the projection and the
    // scope's save/restore both see the re-armed value.
    YMNavigationSidebarRearmSecondaryAvailability(owner);

    bool availabilityReadable = true;
    for (std::size_t index = 0;
         index < kYMNavigationSidebarSecondarySortableTypes.size();
         ++index) {
        const int type = kYMNavigationSidebarSecondarySortableTypes[index];
        const std::uintptr_t offset =
            YMNavigationSidebarAvailabilityFlagOffset(type, YMNavigationSidebarProfile().availabilityFlagBase);
        const std::uintptr_t address =
            reinterpret_cast<std::uintptr_t>(owner) + offset;
        if (offset == 0 ||
            !YMNavigationSidebarRangeHasProtection(
                address, sizeof(std::uint8_t), VM_PROT_READ | VM_PROT_WRITE)) {
            availabilityReadable = false;
            break;
        }
        auto *flag = reinterpret_cast<std::uint8_t *>(address);
        scope.saved[index] = *flag;
        const std::optional<config::Entry> entry =
            runtime::EntryForNativeKey(config::Group::secondary, type);
        if (entry.has_value() && !configuration.isEnabled(*entry)) {
            scope.changed[index] = true;
            *flag = 0;
        }
    }

    original(owner);
    const bool secondaryApplied = availabilityReadable &&
        YMNavigationSidebarApplySecondaryProjection(
            owner, configuration, applied.secondary, scope.saved);
    scope.Restore();
    const bool primaryApplied = YMNavigationSidebarApplyPrimaryVisibility(
        owner, configuration, applied.primary);
    // 等受管的主导航条目落定后，再处理发现：展开布局下它是多余的。
    YMNavigationSidebarApplyDiscoverEntryVisibility(owner, configuration);
    return secondaryApplied && primaryApplied;
}

static void YMNavigationSidebarScheduleApply(
    void *owner,
    YMNavigationSidebarApplyTrigger trigger) {
    if (owner == nullptr || !YMNavigationSidebarApplyShouldSchedule(trigger)) {
        return;
    }
    if (!YMNavigationSidebarApplyShouldDefer(trigger)) {
        YMNavigationSidebarRunResponsiveLayout(owner);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        void *current =
            YMNavigationSidebarOwner.load(std::memory_order_acquire);
        if (current == owner) {
            YMNavigationSidebarRunResponsiveLayout(current);
        }
    });
}

static void YMNavigationSidebarDidUpdateResponsiveLayout(void *owner) {
    static_cast<void>(YMNavigationSidebarCaptureOwner(owner));
    YMNavigationSidebarRunResponsiveLayout(owner);
}

// WeChat chooses its sidebar layout mode once during owner init and never persists the
// choice, so the collapsed mode is re-decided on every launch. In collapsed mode the
// 发现与服务 entries have no sidebar representation at all: the secondary order getter
// returns an empty list, so the native populate pass builds an empty controller and
// every later item lookup misses. Flipping the mode byte back to expanded *before* the
// native populate runs makes WeChat itself materialise the five entries, after which
// the existing visibility/order projection applies unchanged.
//
// Preflight: every byte we intend to write is probed for read+write protection before
// the first write, so a failed probe leaves WeChat completely untouched rather than
// half-converted. An unrecognised mode byte means this build does not match the
// profiled layout, and we write nothing.
static bool YMNavigationSidebarForceExpandedLayout(void *owner) noexcept {
    if (owner == nullptr) {
        return false;
    }
    const std::uintptr_t base = reinterpret_cast<std::uintptr_t>(owner);
    if (base > std::numeric_limits<std::uintptr_t>::max() -
                   YMNavigationSidebarProfile().layoutModeOffset) {
        return false;
    }
    const std::uintptr_t modeAddress =
        base + YMNavigationSidebarProfile().layoutModeOffset;
    if (!YMNavigationSidebarRangeHasProtection(
            modeAddress, sizeof(std::uint8_t),
            VM_PROT_READ | VM_PROT_WRITE)) {
        return false;
    }
    auto *const mode = reinterpret_cast<std::uint8_t *>(modeAddress);
    const YMNavigationSidebarLayoutModeAction action =
        YMNavigationSidebarLayoutModeActionForMode(*mode);
    if (!YMNavigationSidebarLayoutModeActionWrites(action)) {
        // Already expanded (nothing to do), or a mode this profile does not describe.
        return action == YMNavigationSidebarLayoutModeAction::none;
    }

    // Preflight every availability byte before committing any write.
    constexpr std::size_t kSecondaryCount =
        kYMNavigationSidebarSecondarySortableTypes.size();
    std::array<std::uint8_t *, kSecondaryCount> flags{};
    for (std::size_t index = 0; index < kSecondaryCount; ++index) {
        const int type = kYMNavigationSidebarSecondarySortableTypes[index];
        const std::uintptr_t offset =
            YMNavigationSidebarAvailabilityFlagOffset(type, YMNavigationSidebarProfile().availabilityFlagBase);
        if (offset == 0 ||
            base > std::numeric_limits<std::uintptr_t>::max() - offset) {
            return false;
        }
        const std::uintptr_t address = base + offset;
        if (!YMNavigationSidebarRangeHasProtection(
                address, sizeof(std::uint8_t),
                VM_PROT_READ | VM_PROT_WRITE)) {
            return false;
        }
        flags[index] = reinterpret_cast<std::uint8_t *>(address);
    }

    // Commit: mode first, then re-arm the availability bytes that the collapsed-mode
    // init zeroed, using WeChat's own constructor seed rather than inventing
    // availability WeChat did not grant.
    *mode = kYMNavigationSidebarLayoutModeExpanded;
    for (std::size_t index = 0; index < kSecondaryCount; ++index) {
        const int type = kYMNavigationSidebarSecondarySortableTypes[index];
        *flags[index] =
            YMNavigationSidebarNativeAvailabilityDefaultForType(type);
    }
    YMNavigationSidebarForcedExpandedLayout.store(1, std::memory_order_release);
    return true;
}

#pragma mark - 点击高亮纠正

// 微信用一个 lambda 处理侧边栏点击选中，这里 hook 的是它的 std::function
// invoker（0x1A6CC00，Ghidra 确认 188 字节，经存储的函数指针调用）。
// 反编译出的形状：
//
//   void invoker(int op, void *functor, void *, void *argBox) {
//       if (op != 0) {
//           int value = **(int **)(argBox + 0x10);     // 绑定的入口类型
//           void *strip = *(void **)(functor + 0x10);
//           strip->selected(+0x28) = value;
//           for (i : rows) value == i ? select(rows[i]) : deselect(rows[i]);
//       } else if (functor) operator delete(functor, 0x18);   // 析构路径
//   }
//
// 最后那个循环拿 value（类型）当行下标用。原生顺序下 type 恒等于下标，看不
// 出来；我们重排之后两者分叉，于是内容路由（按 type）是对的，高亮却落到别的
// 行上——点收藏会看到通讯录亮。
//
// 这里不动 +0x28 里的值（内容路由依赖它），只在原逻辑跑完后按每个条目自己的
// type（item+0x118）重新点一遍高亮。op == 0 是析构路径，一律不碰。
static void YMNavigationSidebarDidSetClickSelection(int op,
                                                    void *functor,
                                                    void *reserved,
                                                    void *argBox) {
    auto original = reinterpret_cast<void (*)(int, void *, void *, void *)>(
        YMNavigationSidebarClickSelectionTrampoline);
    if (original != nullptr) {
        original(op, functor, reserved, argBox);
    }
    if (op == 0 || functor == nullptr || argBox == nullptr ||
        YMNavigationSidebarSelectRow == nullptr ||
        YMNavigationSidebarDeselectRow == nullptr) {
        return;
    }
    void *strip = nullptr;
    if (!YMNavigationSidebarLoadPointerMember(
            functor, kYMNavigationSidebarFunctorStripOffset, strip) ||
        strip == nullptr) {
        return;
    }
    void *valueSlot = nullptr;
    if (!YMNavigationSidebarLoadPointerMember(argBox, 0x10, valueSlot) ||
        valueSlot == nullptr ||
        !YMNavigationSidebarRangeHasProtection(
            reinterpret_cast<std::uintptr_t>(valueSlot), sizeof(int),
            VM_PROT_READ)) {
        return;
    }
    int selectedType = 0;
    std::memcpy(&selectedType, valueSlot, sizeof(selectedType));
    if (!YMNavigationSidebarNativeItemTypeIsKnown(selectedType)) {
        return;
    }

    const std::uintptr_t rowsBase = reinterpret_cast<std::uintptr_t>(strip) +
                                    kYMNavigationSidebarRowsBeginOffset;
    if (!YMNavigationSidebarRangeHasProtection(
            rowsBase, 2 * sizeof(void *), VM_PROT_READ)) {
        return;
    }
    void *begin = nullptr;
    void *end = nullptr;
    std::memcpy(&begin, reinterpret_cast<const void *>(rowsBase),
                sizeof(begin));
    std::memcpy(&end,
                reinterpret_cast<const void *>(rowsBase + sizeof(void *)),
                sizeof(end));
    if (begin == nullptr || end == nullptr || end < begin) {
        return;
    }
    const std::size_t span = static_cast<std::size_t>(
        reinterpret_cast<std::uintptr_t>(end) -
        reinterpret_cast<std::uintptr_t>(begin));
    if ((span % sizeof(void *)) != 0) {
        return;
    }
    const std::size_t count = span / sizeof(void *);
    if (count == 0 || count > kYMNavigationSidebarMaxRowCount ||
        !YMNavigationSidebarRangeHasProtection(
            reinterpret_cast<std::uintptr_t>(begin), span, VM_PROT_READ)) {
        return;
    }
    for (std::size_t index = 0; index < count; ++index) {
        void *item = nullptr;
        std::memcpy(&item,
                    static_cast<const std::uint8_t *>(begin) +
                        index * sizeof(void *),
                    sizeof(item));
        if (item == nullptr) {
            continue;
        }
        const int itemType = YMNavigationSidebarReadNativeType(item);
        if (!YMNavigationSidebarNativeItemTypeIsKnown(itemType)) {
            continue;
        }
        if (itemType == selectedType) {
            YMNavigationSidebarSelectRow(item);
        } else {
            YMNavigationSidebarDeselectRow(item);
        }
    }
}

#pragma mark - 原生回调钩子

static void YMNavigationSidebarDidPopulateEntries(void *owner) {
    // Must run before the native populate: that pass reads the mode byte to decide
    // whether the secondary strip receives any entries at all.
    //
    // 只有用户显式打开「展开发现与服务」时才改写布局模式字节；关闭时完全
    // 不碰，微信保持自己选定的折叠形态。
    if (YMNavigationSidebarConfigurationSnapshot().exposeSecondaryEntries) {
        static_cast<void>(YMNavigationSidebarForceExpandedLayout(owner));
    }
    auto original = reinterpret_cast<YMNavigationSidebarOwnerFunction>(
        YMNavigationSidebarPopulateEntriesTrampoline);
    if (original != nullptr) {
        original(owner);
    }
    static_cast<void>(YMNavigationSidebarCaptureOwner(owner));
    YMNavigationSidebarScheduleApply(
        owner, YMNavigationSidebarApplyTrigger::entriesPopulated);
}

static void YMNavigationSidebarWillDestroyMainWindow(void *mainWindow) {
    component_bridge::SharedSidebarPatchOwnerBridge()
        .revokeAtDestructorStart(
            reinterpret_cast<std::uint64_t>(mainWindow));

    void *destroyedOwner = nullptr;
    if (mainWindow != nullptr &&
        YMNavigationSidebarRangeHasProtection(
            reinterpret_cast<std::uintptr_t>(mainWindow) + YMNavigationSidebarProfile().mainWindowOwnerOffset,
            sizeof(destroyedOwner),
            VM_PROT_READ)) {
        std::memcpy(&destroyedOwner,
                    static_cast<std::uint8_t *>(mainWindow) + YMNavigationSidebarProfile().mainWindowOwnerOffset,
                    sizeof(destroyedOwner));
    }

    void *expected = destroyedOwner;
    const bool cleared = destroyedOwner != nullptr &&
                         YMNavigationSidebarOwner.compare_exchange_strong(
                             expected,
                             nullptr,
                             std::memory_order_acq_rel);
    if (cleared) {
        std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
        YMNavigationSidebarAppliedSnapshot.ClearOwner(destroyedOwner);
        YMNavigationSidebarOrderAvailability.Clear(destroyedOwner);
    }
    if (cleared) {
        YMNavigationSidebarNotifyStateChanged();
    }
}

static void *YMNavigationSidebarDidDestroyMainWindow(void *mainWindow) {
    YMNavigationSidebarWillDestroyMainWindow(mainWindow);
    auto original = reinterpret_cast<YMNavigationSidebarMainWindowDestructor>(
        YMNavigationSidebarDestructorTrampoline);
    return original != nullptr ? original(mainWindow) : mainWindow;
}

static void *YMNavigationSidebarDidDestroyMainWindow420(void *mainWindow, void *vtt) {
    YMNavigationSidebarWillDestroyMainWindow(mainWindow);
    auto original = reinterpret_cast<void *(*)(void *, void *)>(YMNavigationSidebarDestructorTrampoline);
    return original != nullptr ? original(mainWindow, vtt) : mainWindow;
}

extern "C" __attribute__((visibility("hidden")))
void YMNavigationSidebarReorderOrderResult(void *resultStorage,
                                           void *owner,
                                           int groupValue) {
    if (owner == nullptr || (groupValue != 0 && groupValue != 1)) {
        return;
    }
    const config::Group group = groupValue == 0 ? config::Group::primary
                                                : config::Group::secondary;
    // 二级条带只存在于展开布局：没开展开开关时它是空的，重排不仅无
    // 意义，还会把顺序改成和当前布局不一致。主导航两种布局下都在，
    // 照常重排——这个门禁早先写在 group 算出来之前，把主导航也一并毙了。
    if (group == config::Group::secondary &&
        !YMNavigationSidebarConfigurationSnapshot().exposeSecondaryEntries) {
        return;
    }
    const runtime::Orders orders = YMNavigationSidebarCaptureOwner(owner);

    bool reordered = false;
    if (YMNavigationSidebarRangeHasProtection(
            reinterpret_cast<std::uintptr_t>(resultStorage),
            sizeof(void *),
            VM_PROT_READ)) {
        void *holder = nullptr;
        std::memcpy(&holder, resultStorage, sizeof(holder));
        if (YMNavigationSidebarRangeHasProtection(
                reinterpret_cast<std::uintptr_t>(holder),
                adapter::kHolderSlotsOffset,
                VM_PROT_READ)) {
            std::span<void *> slots;
            if (adapter::ParseGetterSlots(resultStorage, group, slots) &&
                YMNavigationSidebarRangeHasProtection(
                    reinterpret_cast<std::uintptr_t>(slots.data()),
                    slots.size() * sizeof(void *),
                    VM_PROT_READ | VM_PROT_WRITE)) {
                reordered = adapter::ReorderGetterResult(
                    resultStorage,
                    group,
                    orders,
                    &YMNavigationSidebarReadOrderSlotType);
            }
        }
    }
    YMNavigationSidebarSetOrderAvailability(owner, group, reordered);
}

struct YMNavigationSidebarPatchStage {
    std::uintptr_t target{0};
    const std::uint8_t *expected{nullptr};
    std::uintptr_t hook{0};
    void **trampoline{nullptr};
    diagnostic::SecondaryActivationOriginal *activationTrampoline{nullptr};
};

struct YMNavigationSidebarCallAddresses {
    std::uintptr_t primarySelector{0};
    std::uintptr_t selectedPrimaryGetter{0};
    std::uintptr_t findSecondaryItem{0};
    std::uintptr_t lookupItem{0};
    std::uintptr_t overflowClear{0};
    std::uintptr_t overflowAppend{0};
    std::uintptr_t moreSetVisible{0};
    std::uintptr_t moreSetBadge{0};
    std::uintptr_t moreCountGetter{0};
    std::uintptr_t nativeTitleFromUtf8{0};
    std::uintptr_t moreTitleFormatGetter{0};
    std::uintptr_t nativeTitleFormatter{0};
    std::uintptr_t nativeTitleDeallocate{0};
    std::uintptr_t moreTitleSetter{0};
    std::uintptr_t postLayout{0};
    std::uintptr_t rowSelect{0};
    std::uintptr_t rowDeselect{0};
};

struct YMNavigationSidebarCallGuard {
    std::uintptr_t address{0};
    const std::uint8_t *expected{nullptr};
};

using YMNavigationSidebarThreadQuiescence =
    manager_patch::ThreadPortReleaseState<thread_t, mach_msg_type_number_t>;

struct YMNavigationSidebarPatchContext {
    std::array<YMNavigationSidebarPatchStage,
               YMNavigationSidebarPatchStageCount>
        stages{};
    std::array<YMNavigationSidebarCallGuard, 17> callGuards{};
    YMNavigationSidebarCallAddresses calls{};
    std::intptr_t slide{0};
    const struct mach_header *header{nullptr};
    YMNavigationSidebarThreadQuiescence quiescence{};
    bool diagnosticOnly{false};

    YMNavigationSidebarPatchContext() = default;
    YMNavigationSidebarPatchContext(const YMNavigationSidebarPatchContext &) =
        delete;
    YMNavigationSidebarPatchContext &operator=(
        const YMNavigationSidebarPatchContext &) = delete;
    YMNavigationSidebarPatchContext &operator=(
        YMNavigationSidebarPatchContext &&) = delete;
    YMNavigationSidebarPatchContext(
        YMNavigationSidebarPatchContext &&other) noexcept
        : stages(other.stages),
          callGuards(other.callGuards),
          calls(other.calls),
          slide(other.slide),
          header(other.header),
          quiescence(std::move(other.quiescence)),
          diagnosticOnly(other.diagnosticOnly) {}
};

static manager_patch::Coordinator<YMNavigationSidebarPatchStageCount,
                                  YMNavigationSidebarPatchContext>
    YMNavigationSidebarPatchCoordinator;
static manager_patch::Coordinator<diagnostic::kDiagnosticPatchStageCount,
                                  YMNavigationSidebarPatchContext>
    YMNavigationSidebarDiagnosticPatchCoordinator;
static std::atomic_bool YMNavigationSidebarPatchRetryScheduled(false);

#pragma mark - 补丁预检与调用点发布

static bool YMNavigationSidebarPatchPreflight(void *rawContext,
                                              std::size_t stage) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarPatchContext *>(rawContext);
    if (stage >= context.stages.size()) {
        return false;
    }
    const YMNavigationSidebarPatchStage &target = context.stages[stage];
    return target.expected != nullptr &&
           ((target.trampoline != nullptr) !=
            (target.activationTrampoline != nullptr)) &&
           YMNavigationSidebarCodeMatches(target.target, target.expected);
}

static bool YMNavigationSidebarCallGuardsMatch(
    const YMNavigationSidebarPatchContext &context) noexcept {
    for (const YMNavigationSidebarCallGuard &guard : context.callGuards) {
        if (guard.expected == nullptr ||
            !YMNavigationSidebarCodeMatches(guard.address, guard.expected)) {
            return false;
        }
    }
    return true;
}

static void YMNavigationSidebarPublishCallTargets(
    const YMNavigationSidebarCallAddresses &calls) noexcept {
    YMNavigationSidebarSelectPrimary =
        reinterpret_cast<YMNavigationSidebarPrimarySelector>(
            calls.primarySelector);
    YMNavigationSidebarGetSelectedPrimary =
        reinterpret_cast<YMNavigationSidebarSelectedPrimaryGetter>(
            calls.selectedPrimaryGetter);
    YMNavigationSidebarFindSecondaryItem =
        reinterpret_cast<YMNavigationSidebarLookupItem>(
            calls.findSecondaryItem);
    YMNavigationSidebarLookupNativeItem =
        reinterpret_cast<YMNavigationSidebarLookupItem>(calls.lookupItem);
    YMNavigationSidebarClearOverflow =
        reinterpret_cast<YMNavigationSidebarOverflowClear>(calls.overflowClear);
    YMNavigationSidebarAppendOverflow =
        reinterpret_cast<YMNavigationSidebarOverflowAppend>(
            calls.overflowAppend);
    YMNavigationSidebarSetMoreVisible =
        reinterpret_cast<YMNavigationSidebarMoreSetVisible>(
            calls.moreSetVisible);
    YMNavigationSidebarSetMoreBadge =
        reinterpret_cast<YMNavigationSidebarMoreSetBadge>(calls.moreSetBadge);
    YMNavigationSidebarGetMoreCount =
        reinterpret_cast<YMNavigationSidebarMoreCountGetter>(
            calls.moreCountGetter);
    YMNavigationSidebarNativeTitleFromUtf8 =
        reinterpret_cast<YMNavigationSidebarNativeTitleFromUtf8Function>(
            calls.nativeTitleFromUtf8);
    YMNavigationSidebarGetMoreTitleFormat =
        reinterpret_cast<YMNavigationSidebarMoreTitleFormatGetter>(
            calls.moreTitleFormatGetter);
    YMNavigationSidebarNativeTitleFormatter =
        reinterpret_cast<void *>(calls.nativeTitleFormatter);
    YMNavigationSidebarDeallocateNativeTitle =
        reinterpret_cast<YMNavigationSidebarNativeTitleDeallocate>(
            calls.nativeTitleDeallocate);
    YMNavigationSidebarSetMoreTitle =
        reinterpret_cast<YMNavigationSidebarMoreTitleSetter>(
            calls.moreTitleSetter);
    YMNavigationSidebarPostLayout =
        reinterpret_cast<YMNavigationSidebarOwnerFunction>(calls.postLayout);
    YMNavigationSidebarSelectRow =
        reinterpret_cast<YMNavigationSidebarRowStateFunction>(calls.rowSelect);
    YMNavigationSidebarDeselectRow =
        reinterpret_cast<YMNavigationSidebarRowStateFunction>(
            calls.rowDeselect);
}

static bool YMNavigationSidebarAddSlide(std::intptr_t slide,
                                        std::uintptr_t value,
                                        std::uintptr_t &output) noexcept {
    if (slide >= 0) {
        const std::uintptr_t positive = static_cast<std::uintptr_t>(slide);
        if (value > std::numeric_limits<std::uintptr_t>::max() - positive) {
            return false;
        }
        output = value + positive;
        return true;
    }
    const std::uintptr_t magnitude =
        static_cast<std::uintptr_t>(-(slide + 1)) + 1;
    if (value < magnitude) {
        return false;
    }
    output = value - magnitude;
    return true;
}

static bool YMNavigationSidebarReadRuntimeProfileBytes(
    void *rawContext,
    std::uintptr_t address,
    std::uint8_t *destination,
    std::size_t length) noexcept {
    if (rawContext == nullptr || destination == nullptr || length != 16) {
        return false;
    }
    const auto &context =
        *static_cast<const YMNavigationSidebarPatchContext *>(rawContext);
    std::uintptr_t runtimeAddress = 0;
    if (!YMNavigationSidebarAddSlide(
            context.slide, address, runtimeAddress) ||
        !YMNavigationSidebarRangeHasProtection(
            runtimeAddress, length, VM_PROT_READ | VM_PROT_EXECUTE)) {
        return false;
    }
    std::memcpy(destination,
                reinterpret_cast<const void *>(runtimeAddress),
                length);
    return true;
}

static bool YMNavigationSidebarPublishVerifiedCallTargets(
    void *rawContext) noexcept {
    if (rawContext == nullptr) {
        return false;
    }
    const auto &context =
        *static_cast<const YMNavigationSidebarPatchContext *>(rawContext);
    YMNavigationSidebarPublishCallTargets(context.calls);
    return true;
}

#pragma mark - 线程静默

static bool YMNavigationSidebarResumeThread(void *, thread_t thread) noexcept {
    return thread_resume(thread) == KERN_SUCCESS;
}

static bool YMNavigationSidebarDeallocateThreadPort(void *,
                                                    thread_t thread) noexcept {
    return mach_port_deallocate(mach_task_self(), thread) == KERN_SUCCESS;
}

static bool YMNavigationSidebarDeallocateThreadStorage(
    void *,
    thread_t *storage,
    mach_msg_type_number_t count) noexcept {
    return vm_deallocate(
               mach_task_self(),
               reinterpret_cast<vm_address_t>(storage),
               static_cast<vm_size_t>(count) * sizeof(thread_t)) ==
           KERN_SUCCESS;
}

static manager_patch::ThreadPortReleaseOperations<
    thread_t, mach_msg_type_number_t>
YMNavigationSidebarThreadPortReleaseOperations() noexcept {
    return {
        nullptr,
        &YMNavigationSidebarResumeThread,
        &YMNavigationSidebarDeallocateThreadPort,
        &YMNavigationSidebarDeallocateThreadStorage,
    };
}

static bool YMNavigationSidebarReleaseThreadPorts(
    YMNavigationSidebarPatchContext &context,
    mach_msg_type_number_t firstUnprocessed) noexcept {
    return manager_patch::ReleaseThreadPorts(
        context.quiescence,
        firstUnprocessed,
        YMNavigationSidebarThreadPortReleaseOperations());
}

static bool YMNavigationSidebarEnumerateThreads(
    void *,
    thread_t **storage,
    mach_msg_type_number_t *count) noexcept {
    return task_threads(mach_task_self(), storage, count) == KERN_SUCCESS;
}

static bool YMNavigationSidebarAcquireCurrentThread(
    void *, thread_t *currentThread) noexcept {
    if (currentThread == nullptr) {
        return false;
    }
    *currentThread = mach_thread_self();
    return *currentThread != MACH_PORT_NULL;
}

static bool YMNavigationSidebarSuspendThread(void *, thread_t thread) noexcept {
    return thread_suspend(thread) == KERN_SUCCESS;
}

static bool YMNavigationSidebarValidateSuspendedThread(
    void *rawContext, thread_t thread) noexcept {
    const auto &context =
        *static_cast<const YMNavigationSidebarPatchContext *>(rawContext);
    arm_thread_state64_t state{};
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(
            thread,
            ARM_THREAD_STATE64,
            reinterpret_cast<thread_state_t>(&state),
            &stateCount) != KERN_SUCCESS) {
        return false;
    }
    const std::uintptr_t programCounter =
        static_cast<std::uintptr_t>(arm_thread_state64_get_pc(state));
    for (const YMNavigationSidebarPatchStage &stage : context.stages) {
        if (adapter::ProgramCounterInPatchPrologue(
                programCounter, stage.target)) {
            return false;
        }
    }
    return true;
}

static bool YMNavigationSidebarAcquireQuiescence(void *rawContext) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarPatchContext *>(rawContext);
    const manager_patch::ThreadPortAcquisitionOperations<
        thread_t, mach_msg_type_number_t>
        operations{
            &context,
            &YMNavigationSidebarEnumerateThreads,
            &YMNavigationSidebarAcquireCurrentThread,
            &YMNavigationSidebarSuspendThread,
            &YMNavigationSidebarValidateSuspendedThread,
            YMNavigationSidebarThreadPortReleaseOperations(),
        };
    if (!manager_patch::AcquireThreadPorts(
            context.quiescence, operations)) {
        return false;
    }

    if (!YMNavigationSidebarLoadedImageUUIDMatches(context.header)) {
        static_cast<void>(YMNavigationSidebarReleaseThreadPorts(
            context, context.quiescence.storageCount));
        return false;
    }
    const bool profileMatches =
        context.diagnosticOnly
            ? YMNavigationSidebarVerifyProfileBytes(
                  YMNavigationSidebarProfile(),
                  &YMNavigationSidebarReadRuntimeProfileBytes,
                  &context)
            : YMNavigationSidebarVerifyProfileBytesAndPublish(
                  YMNavigationSidebarProfile(),
                  &YMNavigationSidebarReadRuntimeProfileBytes,
                  &context,
                  &YMNavigationSidebarPublishVerifiedCallTargets,
                  &context);
    if (!profileMatches) {
        static_cast<void>(YMNavigationSidebarReleaseThreadPorts(
            context, context.quiescence.storageCount));
        return false;
    }
    return true;
}

static bool YMNavigationSidebarReleaseQuiescence(void *rawContext) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarPatchContext *>(rawContext);
    return YMNavigationSidebarReleaseThreadPorts(
        context, context.quiescence.storageCount);
}

#pragma mark - trampoline 与代码写入

static bool YMNavigationSidebarAllocateTrampoline(
    void *rawContext,
    std::size_t stage,
    patch::TrampolineMapping *mapping) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarPatchContext *>(rawContext);
    if (stage >= context.stages.size() || mapping == nullptr) {
        return false;
    }
    const YMNavigationSidebarPatchStage &target = context.stages[stage];
    std::uint8_t trampolineBytes[32]{};
    YMNavigationSidebarBuildTrampoline(
        target.expected, target.target + 16, trampolineBytes);
    void *allocation = mmap(nullptr,
                            sizeof(trampolineBytes),
                            PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON,
                            -1,
                            0);
    if (allocation == MAP_FAILED) {
        return false;
    }
    std::memcpy(allocation, trampolineBytes, sizeof(trampolineBytes));
    if (mprotect(allocation,
                 sizeof(trampolineBytes),
                 PROT_READ | PROT_EXEC) != 0 ||
        std::memcmp(allocation,
                    trampolineBytes,
                    sizeof(trampolineBytes)) != 0) {
        static_cast<void>(munmap(allocation, sizeof(trampolineBytes)));
        return false;
    }
    sys_icache_invalidate(allocation, sizeof(trampolineBytes));
    if (target.trampoline != nullptr) {
        *target.trampoline = allocation;
    } else if (target.activationTrampoline != nullptr) {
        *target.activationTrampoline =
            reinterpret_cast<diagnostic::SecondaryActivationOriginal>(
                allocation);
    } else {
        static_cast<void>(munmap(allocation, sizeof(trampolineBytes)));
        return false;
    }
    *mapping = {
        reinterpret_cast<std::uintptr_t>(allocation),
        sizeof(trampolineBytes),
    };
    return true;
}

static bool YMNavigationSidebarReleaseTrampoline(
    void *rawContext,
    std::size_t stage,
    patch::TrampolineMapping mapping) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarPatchContext *>(rawContext);
    if (stage >= context.stages.size() || mapping.address == 0 ||
        mapping.size == 0 ||
        munmap(reinterpret_cast<void *>(mapping.address), mapping.size) != 0) {
        return false;
    }
    void **slot = context.stages[stage].trampoline;
    if (slot != nullptr &&
        *slot == reinterpret_cast<void *>(mapping.address)) {
        *slot = nullptr;
    }
    diagnostic::SecondaryActivationOriginal *activationSlot =
        context.stages[stage].activationTrampoline;
    if (activationSlot != nullptr &&
        *activationSlot ==
            reinterpret_cast<diagnostic::SecondaryActivationOriginal>(
                mapping.address)) {
        *activationSlot = nullptr;
    }
    return true;
}

static bool YMNavigationSidebarSetCodeProtection(
    std::uintptr_t address,
    std::size_t size,
    vm_prot_t protection) noexcept {
    const std::uintptr_t pageSize =
        static_cast<std::uintptr_t>(getpagesize());
    if (pageSize == 0 || address >
                             std::numeric_limits<std::uintptr_t>::max() - size) {
        return false;
    }
    const std::uintptr_t pageStart = address & ~(pageSize - 1);
    const std::uintptr_t end = address + size;
    if (end > std::numeric_limits<std::uintptr_t>::max() - (pageSize - 1)) {
        return false;
    }
    const std::uintptr_t pageEnd =
        (end + pageSize - 1) & ~(pageSize - 1);
    return mach_vm_protect(mach_task_self(),
                           pageStart,
                           pageEnd - pageStart,
                           false,
                           protection) == KERN_SUCCESS;
}

static bool YMNavigationSidebarWriteBytes(
    std::uintptr_t address,
    const std::uint8_t bytes[16]) noexcept {
    if (!YMNavigationSidebarSetCodeProtection(
            address,
            16,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)) {
        return false;
    }
    std::memcpy(reinterpret_cast<void *>(address), bytes, 16);
    sys_icache_invalidate(reinterpret_cast<void *>(address), 16);
    const bool verified =
        std::memcmp(reinterpret_cast<const void *>(address), bytes, 16) == 0;
    const bool restored = YMNavigationSidebarSetCodeProtection(
        address, 16, VM_PROT_READ | VM_PROT_EXECUTE);
    return verified && restored;
}

static bool YMNavigationSidebarWritePatch(
    void *rawContext,
    std::size_t stage,
    patch::TrampolineMapping mapping) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarPatchContext *>(rawContext);
    if (stage >= context.stages.size() || mapping.address == 0) {
        return false;
    }
    std::uint8_t jump[16]{};
    YMNavigationSidebarBuildAbsoluteJump(
        context.stages[stage].hook, jump);
    return YMNavigationSidebarWriteBytes(context.stages[stage].target, jump);
}

static bool YMNavigationSidebarRestoreTarget(void *rawContext,
                                             std::size_t stage) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarPatchContext *>(rawContext);
    if (stage >= context.stages.size()) {
        return false;
    }
    const YMNavigationSidebarPatchStage &target = context.stages[stage];
    return YMNavigationSidebarWriteBytes(target.target, target.expected) &&
           YMNavigationSidebarCodeMatches(target.target, target.expected);
}

static patch::Operations YMNavigationSidebarPatchOperations(
    YMNavigationSidebarPatchContext &context) noexcept {
    return {
        &context,
        &YMNavigationSidebarPatchPreflight,
        &YMNavigationSidebarAcquireQuiescence,
        &YMNavigationSidebarReleaseQuiescence,
        &YMNavigationSidebarAllocateTrampoline,
        &YMNavigationSidebarReleaseTrampoline,
        &YMNavigationSidebarWritePatch,
        &YMNavigationSidebarRestoreTarget,
    };
}

static YMNavigationSidebarPatchContext YMNavigationSidebarBuildPatchContext(
    const struct mach_header *header,
    std::intptr_t slide) noexcept {
    const auto address = [slide](std::uintptr_t value) {
        return static_cast<std::uintptr_t>(slide) + value;
    };
    YMNavigationSidebarPatchContext context;
    context.slide = slide;
    context.header = header;
    context.stages = {{
        {address(YMNavigationSidebarProfile().responsiveLayoutVA),
         YMNavigationSidebarProfile().expectedResponsiveLayoutBytes,
         reinterpret_cast<std::uintptr_t>(
             &YMNavigationSidebarDidUpdateResponsiveLayout),
         &YMNavigationSidebarResponsiveLayoutTrampoline},
        {address(YMNavigationSidebarProfile().populateSecondaryEntriesVA),
         YMNavigationSidebarProfile().expectedPopulateSecondaryEntriesBytes,
         reinterpret_cast<std::uintptr_t>(
             &YMNavigationSidebarDidPopulateEntries),
         &YMNavigationSidebarPopulateEntriesTrampoline},
        {address(YMNavigationSidebarProfile().mainWindowDestructorVA),
         YMNavigationSidebarProfile().expectedMainWindowDestructorBytes,
         YMNavigationSidebarProfile().mainWindowOwnerOffset == 0x338
             ? reinterpret_cast<std::uintptr_t>(&YMNavigationSidebarDidDestroyMainWindow420)
             : reinterpret_cast<std::uintptr_t>(&YMNavigationSidebarDidDestroyMainWindow),
         &YMNavigationSidebarDestructorTrampoline},
        {address(YMNavigationSidebarProfile().primaryOrderGetterVA),
         YMNavigationSidebarProfile().expectedPrimaryOrderGetterBytes,
         reinterpret_cast<std::uintptr_t>(
             &YMNavigationSidebarPrimaryOrderHook),
         &YMNavigationSidebarPrimaryOrderTrampoline},
        {address(YMNavigationSidebarProfile().secondaryOrderGetterVA),
         YMNavigationSidebarProfile().expectedSecondaryOrderGetterBytes,
         reinterpret_cast<std::uintptr_t>(
             &YMNavigationSidebarSecondaryOrderHook),
         &YMNavigationSidebarSecondaryOrderTrampoline},
        {address(YMNavigationSidebarProfile().clickSelectionInvokerVA),
         YMNavigationSidebarProfile().expectedClickSelectionInvokerBytes,
         reinterpret_cast<std::uintptr_t>(
             &YMNavigationSidebarDidSetClickSelection),
         &YMNavigationSidebarClickSelectionTrampoline},
    }};

    context.calls = {
        address(YMNavigationSidebarProfile().primarySelectorVA),
        address(YMNavigationSidebarProfile().selectedPrimaryTypeGetterVA),
        address(YMNavigationSidebarProfile().findSecondaryItemVA),
        address(YMNavigationSidebarProfile().lookupItemVA),
        address(YMNavigationSidebarProfile().overflowClearVA),
        address(YMNavigationSidebarProfile().overflowAppendVA),
        address(YMNavigationSidebarProfile().moreSetVisibleVA),
        address(YMNavigationSidebarProfile().moreSetBadgeVA),
        address(YMNavigationSidebarProfile().moreCountGetterVA),
        address(YMNavigationSidebarProfile().nativeTitleFromUtf8VA),
        address(YMNavigationSidebarProfile().moreTitleFormatGetterVA),
        address(YMNavigationSidebarProfile().nativeTitleFormatterVA),
        address(YMNavigationSidebarProfile().nativeTitleDeallocateVA),
        address(YMNavigationSidebarProfile().moreTitleSetterVA),
        address(YMNavigationSidebarProfile().postLayoutVA),
        address(YMNavigationSidebarProfile().rowSelectVA),
        address(YMNavigationSidebarProfile().rowDeselectVA),
    };
    context.callGuards = {{
        {context.calls.primarySelector,
         YMNavigationSidebarProfile().expectedPrimarySelectorBytes},
        {context.calls.selectedPrimaryGetter,
         YMNavigationSidebarProfile().expectedSelectedPrimaryTypeGetterBytes},
        {context.calls.findSecondaryItem,
         YMNavigationSidebarProfile().expectedFindSecondaryItemBytes},
        {context.calls.lookupItem,
         YMNavigationSidebarProfile().expectedLookupItemBytes},
        {context.calls.overflowClear,
         YMNavigationSidebarProfile().expectedOverflowClearBytes},
        {context.calls.overflowAppend,
         YMNavigationSidebarProfile().expectedOverflowAppendBytes},
        {context.calls.moreSetVisible,
         YMNavigationSidebarProfile().expectedMoreSetVisibleBytes},
        {context.calls.moreSetBadge,
         YMNavigationSidebarProfile().expectedMoreSetBadgeBytes},
        {context.calls.moreCountGetter,
         YMNavigationSidebarProfile().expectedMoreCountGetterBytes},
        {context.calls.nativeTitleFromUtf8,
         YMNavigationSidebarProfile().expectedNativeTitleFromUtf8Bytes},
        {context.calls.moreTitleFormatGetter,
         YMNavigationSidebarProfile().expectedMoreTitleFormatGetterBytes},
        {context.calls.nativeTitleFormatter,
         YMNavigationSidebarProfile().expectedNativeTitleFormatterBytes},
        {context.calls.nativeTitleDeallocate,
         YMNavigationSidebarProfile().expectedNativeTitleDeallocateBytes},
        {context.calls.moreTitleSetter,
         YMNavigationSidebarProfile().expectedMoreTitleSetterBytes},
        {context.calls.postLayout,
         YMNavigationSidebarProfile().expectedPostLayoutBytes},
        {context.calls.rowSelect,
         YMNavigationSidebarProfile().expectedRowSelectBytes},
        {context.calls.rowDeselect,
         YMNavigationSidebarProfile().expectedRowDeselectBytes},
    }};
    return context;
}

static YMNavigationSidebarPatchContext
YMNavigationSidebarBuildDiagnosticPatchContext(
    const struct mach_header *header,
    std::intptr_t slide) noexcept {
    YMNavigationSidebarPatchContext context;
    context.slide = slide;
    context.header = header;
    context.diagnosticOnly = true;
    std::uintptr_t target = 0;
    if (!YMNavigationSidebarAddSlide(
            slide,
            YMNavigationSidebarProfile().secondaryActivationVA,
            target)) {
        return context;
    }
    context.stages[0] = {
        target,
        YMNavigationSidebarProfile().expectedSecondaryActivationBytes,
        reinterpret_cast<std::uintptr_t>(
            &YMNavigationSidebarSecondaryActivationHook),
        nullptr,
        &YMNavigationSidebarSecondaryActivationTrampoline,
    };
    return context;
}

#pragma mark - 镜像识别与安装

static BOOL YMNavigationSidebarCurrentBuildMatches(
    const struct mach_header *header) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *bundleIdentifier = bundle.bundleIdentifier ?: @"";
    NSString *shortVersion =
        [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *buildVersion =
        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    const char *architecture =
        header != nullptr
            ? macho_arch_name_for_cpu_type(header->cputype, header->cpusubtype)
            : nullptr;
    const auto *profile = YMSidebarPatchProfileForIdentity({bundleIdentifier.UTF8String,
        shortVersion.UTF8String, buildVersion.UTF8String, architecture});
    if (!profile) return NO;
    return profile->sidebarProfile == &YMNavigationSidebarProfile() &&
           YMNavigationSidebarLoadedImageUUIDMatches(header);
}

static const char *YMNavigationSidebarImagePath(
    const struct mach_header *header) noexcept {
    const std::uint32_t imageCount = _dyld_image_count();
    for (std::uint32_t index = 0; index < imageCount; ++index) {
        if (_dyld_get_image_header(index) == header) {
            return _dyld_get_image_name(index);
        }
    }
    return nullptr;
}

static bool YMNavigationSidebarLoadedImageExtent(
    const struct mach_header *header,
    std::intptr_t slide,
    std::size_t &imageSize) noexcept {
    constexpr std::size_t headerSize = sizeof(struct mach_header_64);
    const std::uintptr_t headerAddress =
        reinterpret_cast<std::uintptr_t>(header);
    if (header == nullptr ||
        !YMNavigationSidebarRangeHasProtection(
            headerAddress, headerSize, VM_PROT_READ)) {
        return false;
    }
    struct mach_header_64 copiedHeader{};
    std::memcpy(&copiedHeader, header, sizeof(copiedHeader));
    if (copiedHeader.magic != MH_MAGIC_64 ||
        !YMNavigationSidebarRangeHasProtection(
            headerAddress,
            headerSize + copiedHeader.sizeofcmds,
            VM_PROT_READ)) {
        return false;
    }

    const auto *commands = reinterpret_cast<const std::uint8_t *>(header) +
                           headerSize;
    std::size_t cursor = 0;
    std::uintptr_t imageEnd = headerAddress;
    for (std::uint32_t index = 0; index < copiedHeader.ncmds; ++index) {
        if (cursor > copiedHeader.sizeofcmds ||
            copiedHeader.sizeofcmds - cursor < sizeof(struct load_command)) {
            return false;
        }
        struct load_command command{};
        std::memcpy(&command, commands + cursor, sizeof(command));
        if (command.cmdsize < sizeof(command) ||
            command.cmdsize > copiedHeader.sizeofcmds - cursor) {
            return false;
        }
        if (command.cmd == LC_SEGMENT_64) {
            if (command.cmdsize < sizeof(struct segment_command_64)) {
                return false;
            }
            struct segment_command_64 segment{};
            std::memcpy(&segment, commands + cursor, sizeof(segment));
            std::uintptr_t segmentStart = 0;
            if (segment.vmsize != 0 &&
                (!YMNavigationSidebarAddSlide(
                     slide,
                     static_cast<std::uintptr_t>(segment.vmaddr),
                     segmentStart) ||
                 segment.vmsize >
                     std::numeric_limits<std::uintptr_t>::max() -
                         segmentStart)) {
                return false;
            }
            const std::uintptr_t segmentEnd =
                segmentStart + static_cast<std::uintptr_t>(segment.vmsize);
            if (segmentEnd > imageEnd) {
                imageEnd = segmentEnd;
            }
        }
        cursor += command.cmdsize;
    }
    if (cursor != copiedHeader.sizeofcmds || imageEnd <= headerAddress) {
        return false;
    }
    imageSize = imageEnd - headerAddress;
    return true;
}

static bool YMNavigationSidebarReadComponentMemory(
    void *,
    std::uintptr_t address,
    std::uint8_t *destination,
    std::size_t length) {
    if (destination == nullptr ||
        !YMNavigationSidebarRangeHasProtection(
            address, length, VM_PROT_READ)) {
        return false;
    }
    std::memcpy(destination,
                reinterpret_cast<const void *>(address),
                length);
    return true;
}

static SidebarPatchPreflightReceipt *
YMNavigationSidebarRunComponentPreflight(
    const struct mach_header *header,
    std::intptr_t slide,
    std::uint64_t installAttempt) {
    const char *path = YMNavigationSidebarImagePath(header);
    std::size_t imageSize = 0;
    if (path == nullptr ||
        !YMNavigationSidebarLoadedImageExtent(header, slide, imageSize)) {
        return nil;
    }
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *bundleIdentifier = bundle.bundleIdentifier ?: @"";
    NSString *shortVersion =
        [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *buildVersion =
        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    const char *architecture =
        macho_arch_name_for_cpu_type(header->cputype, header->cpusubtype);
    const YMSidebarPatchLoadedImage image = {
        path,
        reinterpret_cast<std::uintptr_t>(header),
        slide,
        reinterpret_cast<std::uintptr_t>(header),
        imageSize,
    };
    const YMSidebarPatchPreflightInput input = {
        &image,
        1,
        bundleIdentifier.UTF8String,
        shortVersion.UTF8String,
        buildVersion.UTF8String,
        architecture,
        installAttempt,
        &YMNavigationSidebarReadComponentMemory,
        nullptr,
    };
    const YMSidebarPatchPreflightResult result =
        [YMNavigationSidebarComponentIntegrity verify:&input];
    return result.failure == SidebarPatchIntegrityFailureNone
               ? result.receipt
               : nil;
}

static bool YMNavigationSidebarOwnsExactPatch(
    component_patch::Ownership ownership) noexcept {
    const bool ownsMappings =
        YMNavigationSidebarResponsiveLayoutTrampoline != nullptr &&
        YMNavigationSidebarPopulateEntriesTrampoline != nullptr &&
        YMNavigationSidebarDestructorTrampoline != nullptr &&
        YMNavigationSidebarPrimaryOrderTrampoline != nullptr &&
        YMNavigationSidebarSecondaryOrderTrampoline != nullptr;
    if (!ownsMappings) {
        return false;
    }
    switch (ownership) {
        case component_patch::Ownership::active:
            return YMNavigationSidebarPatchCoordinator.supported();
        case component_patch::Ownership::pendingActivation:
            return YMNavigationSidebarPatchCoordinator.hasPendingActivation();
        case component_patch::Ownership::cleanupPending:
        case component_patch::Ownership::ready:
            return false;
    }
}

static component_patch::Ownership YMNavigationSidebarComponentOwnership(
    manager_patch::OwnershipStatus ownership) noexcept {
    switch (ownership) {
        case manager_patch::OwnershipStatus::ready:
            return component_patch::Ownership::ready;
        case manager_patch::OwnershipStatus::active:
            return component_patch::Ownership::active;
        case manager_patch::OwnershipStatus::pendingActivation:
            return component_patch::Ownership::pendingActivation;
        case manager_patch::OwnershipStatus::cleanupPending:
            return component_patch::Ownership::cleanupPending;
    }
}

static component_patch::SidebarDisposition
YMNavigationSidebarComponentDisposition(
    manager_patch::InstallDisposition disposition) noexcept {
    switch (disposition) {
        case manager_patch::InstallDisposition::installed:
            return component_patch::SidebarDisposition::installed;
        case manager_patch::InstallDisposition::pendingActivation:
            return component_patch::SidebarDisposition::pendingActivation;
        case manager_patch::InstallDisposition::cleanupPending:
            return component_patch::SidebarDisposition::cleanupPending;
        case manager_patch::InstallDisposition::failed:
            return component_patch::SidebarDisposition::failed;
        case manager_patch::InstallDisposition::busy:
            return component_patch::SidebarDisposition::busy;
    }
}

static void YMNavigationSidebarApplyComponentDecision(
    const component_patch::Decision &decision,
    std::uint64_t installAttempt) {
    component_bridge::OwnerBridge &bridge =
        component_bridge::SharedSidebarPatchOwnerBridge();
    if (decision.publish) {
        if (YMNavigationSidebarComponentPendingReceipt != nil &&
            YMNavigationSidebarComponentPendingReceipt.installAttempt ==
                installAttempt) {
            YMNavigationSidebarComponentActiveReceipt =
                YMNavigationSidebarComponentPendingReceipt;
            bridge.bindPatchEpoch(decision.epoch, installAttempt);
        } else {
            static_cast<void>(
                YMNavigationSidebarComponentOrchestration.invalidate());
            bridge.invalidatePatchEpoch();
        }
        YMNavigationSidebarComponentPendingReceipt = nil;
        return;
    }
    if (decision.invalidate) {
        YMNavigationSidebarComponentActiveReceipt = nil;
        bridge.invalidatePatchEpoch();
    }
    if (!decision.retainReceipt) {
        YMNavigationSidebarComponentPendingReceipt = nil;
    }
}

static BOOL YMNavigationSidebarIsTargetImage(const char *imageName) {
    if (imageName == nullptr) {
        return NO;
    }
    NSString *path = [NSString stringWithUTF8String:imageName];
    return [path hasSuffix:@"/WeChat.app/Contents/Resources/wechat.dylib"];
}

static void YMNavigationSidebarInstallHooks(const struct mach_header *header,
                                            std::intptr_t slide);

static void YMNavigationSidebarSchedulePatchRetry(
    const struct mach_header *header,
    std::intptr_t slide) {
    bool expected = false;
    if (!YMNavigationSidebarPatchRetryScheduled.compare_exchange_strong(
            expected, true, std::memory_order_acq_rel)) {
        return;
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^{
            YMNavigationSidebarPatchRetryScheduled.store(
                false, std::memory_order_release);
            YMNavigationSidebarInstallHooks(header, slide);
        });
}

static void YMNavigationSidebarInstallDiagnosticHook(
    const struct mach_header *header,
    std::intptr_t slide) {
    bool installed = false;
    bool retry = false;
    {
        std::lock_guard<std::mutex> lock(YMNavigationSidebarInstallMutex);
        const manager_patch::OwnershipStatus ownership =
            YMNavigationSidebarDiagnosticPatchCoordinator.RetryOwned();
        if (ownership == manager_patch::OwnershipStatus::active) {
            installed = true;
        } else if (ownership ==
                       manager_patch::OwnershipStatus::pendingActivation ||
                   ownership ==
                       manager_patch::OwnershipStatus::cleanupPending) {
            retry = true;
        } else {
            if (!YMNavigationSidebarCurrentBuildMatches(header)) {
                return;
            }
            YMNavigationSidebarPatchContext context =
                YMNavigationSidebarBuildDiagnosticPatchContext(header, slide);
            const manager_patch::InstallOutcome outcome =
                YMNavigationSidebarDiagnosticPatchCoordinator.InstallFresh(
                    std::move(context),
                    &YMNavigationSidebarPatchOperations);
            installed = outcome.disposition ==
                        manager_patch::InstallDisposition::installed;
            retry = outcome.disposition ==
                        manager_patch::InstallDisposition::pendingActivation ||
                    outcome.disposition ==
                        manager_patch::InstallDisposition::cleanupPending;
            if (!installed) {
                YMLog(@"[YMNavigationSidebarDiagnostic] install failed "
                       "stage=%zu error=%u rollback=%u quiescence=%u",
                      outcome.failedStage,
                      static_cast<unsigned int>(outcome.error),
                      static_cast<unsigned int>(outcome.rollbackError),
                      static_cast<unsigned int>(outcome.quiescenceError));
            }
        }
        if (installed) {
            std::lock_guard<std::mutex> diagnosticLock(
                YMNavigationSidebarDiagnosticMutex);
            const diagnostic::InstallDecision decision =
                diagnostic::DecideInstall(true, true, true);
            static_cast<void>(diagnostic::EmitReady(
                YMNavigationSidebarDiagnosticState,
                decision,
                nullptr,
                &YMNavigationSidebarDiagnosticLogSink));
        }
    }
    if (retry) {
        YMNavigationSidebarSchedulePatchRetry(header, slide);
    }
}

static void YMNavigationSidebarInstallHooks(const struct mach_header *header,
                                            std::intptr_t slide) {
    const diagnostic::InstallPlan installPlan =
        diagnostic::PlanInstall(std::getenv("YM_SIDEBAR_DIAGNOSTIC"));
    if (installPlan.route == diagnostic::InstallRoute::diagnosticOnly) {
        if (installPlan.patchStageCount !=
                diagnostic::kDiagnosticPatchStageCount ||
            installPlan.applyInventory) {
            return;
        }
        YMNavigationSidebarInstallDiagnosticHook(header, slide);
        return;
    }
    if (installPlan.patchStageCount != YMNavigationSidebarPatchStageCount ||
        !installPlan.applyInventory) {
        return;
    }
    bool notify = false;
    bool retry = false;
    {
        std::lock_guard<std::mutex> lock(YMNavigationSidebarInstallMutex);
        const manager_patch::OwnershipStatus ownership =
            YMNavigationSidebarPatchCoordinator.RetryOwned();
        const component_patch::Ownership componentOwnership =
            YMNavigationSidebarComponentOwnership(ownership);
        const component_patch::Snapshot componentSnapshot =
            YMNavigationSidebarComponentOrchestration.snapshot();
        const std::uint64_t componentAttempt =
            componentSnapshot.receiptPending
                ? componentSnapshot.pendingAttempt
                : componentSnapshot.activeAttempt;
        if (componentAttempt != 0) {
            const bool receiptMatches =
                (componentSnapshot.receiptPending &&
                 YMNavigationSidebarComponentPendingReceipt != nil &&
                 YMNavigationSidebarComponentPendingReceipt.installAttempt ==
                     componentAttempt) ||
                (componentSnapshot.published &&
                 YMNavigationSidebarComponentActiveReceipt != nil &&
                 YMNavigationSidebarComponentActiveReceipt.installAttempt ==
                     componentAttempt);
            const component_patch::Decision decision =
                YMNavigationSidebarComponentOrchestration.observeRetry(
                    componentAttempt,
                    componentOwnership,
                    receiptMatches &&
                        YMNavigationSidebarOwnsExactPatch(componentOwnership));
            YMNavigationSidebarApplyComponentDecision(
                decision, componentAttempt);
        }
        if (ownership == manager_patch::OwnershipStatus::active) {
            const bool wasSupported = YMNavigationSidebarSupported.exchange(
                true, std::memory_order_acq_rel);
            notify = !wasSupported;
        } else if (ownership ==
                       manager_patch::OwnershipStatus::pendingActivation ||
                   ownership ==
                       manager_patch::OwnershipStatus::cleanupPending) {
            YMNavigationSidebarSupported.store(
                false, std::memory_order_release);
            retry = true;
        } else {
            YMNavigationSidebarPublishCallTargets({});
            YMNavigationSidebarSupported.store(
                false, std::memory_order_release);
            if (!YMNavigationSidebarCurrentBuildMatches(header)) {
                return;
            }

            YMNavigationSidebarPatchContext context =
                YMNavigationSidebarBuildPatchContext(header, slide);
            if (!YMNavigationSidebarCallGuardsMatch(context)) {
                return;
            }
            const std::uint64_t previousAttempt =
                YMNavigationSidebarComponentInstallAttempt.fetch_add(
                    1, std::memory_order_acq_rel);
            const std::uint64_t installAttempt =
                previousAttempt ==
                        std::numeric_limits<std::uint64_t>::max()
                    ? 0
                    : previousAttempt + 1;
            SidebarPatchPreflightReceipt *receipt =
                installAttempt != 0
                    ? YMNavigationSidebarRunComponentPreflight(
                          header, slide, installAttempt)
                    : nil;
            YMNavigationSidebarComponentPendingReceipt = receipt;
            YMNavigationSidebarComponentOrchestration.beginAttempt(
                installAttempt, receipt != nil);
            const manager_patch::InstallOutcome outcome =
                YMNavigationSidebarPatchCoordinator.InstallFresh(
                    std::move(context),
                    &YMNavigationSidebarPatchOperations);
            const component_patch::Ownership postInstallOwnership =
                outcome.disposition ==
                        manager_patch::InstallDisposition::installed
                    ? component_patch::Ownership::active
                    : outcome.disposition ==
                              manager_patch::InstallDisposition::pendingActivation
                          ? component_patch::Ownership::pendingActivation
                          : outcome.disposition ==
                                    manager_patch::InstallDisposition::cleanupPending
                                ? component_patch::Ownership::cleanupPending
                                : component_patch::Ownership::ready;
            const component_patch::Decision componentDecision =
                YMNavigationSidebarComponentOrchestration.observeInstall(
                    installAttempt,
                    YMNavigationSidebarComponentDisposition(
                        outcome.disposition),
                    YMNavigationSidebarOwnsExactPatch(postInstallOwnership));
            YMNavigationSidebarApplyComponentDecision(
                componentDecision, installAttempt);
            if (outcome.disposition ==
                manager_patch::InstallDisposition::installed) {
                YMNavigationSidebarSupported.store(
                    true, std::memory_order_release);
                notify = true;
                YMLog(@"[YMNavigationSidebar] V2 sidebar adapter installed with "
                       "guarded More title projection");
            } else {
                const bool pendingActivation =
                    outcome.disposition ==
                    manager_patch::InstallDisposition::pendingActivation;
                retry = pendingActivation ||
                        outcome.disposition ==
                            manager_patch::InstallDisposition::cleanupPending;
                if (!pendingActivation) {
                    YMNavigationSidebarPublishCallTargets({});
                }
                YMLog(@"[YMNavigationSidebar] hook transaction failed stage=%zu "
                       "error=%u rollback=%u quiescence=%u residual=%zu "
                       "pendingActivation=%d",
                      outcome.failedStage,
                      static_cast<unsigned int>(outcome.error),
                      static_cast<unsigned int>(outcome.rollbackError),
                      static_cast<unsigned int>(outcome.quiescenceError),
                      YMNavigationSidebarPatchCoordinator
                          .cleanupRemainingCount(),
                      pendingActivation ? 1 : 0);
            }
        }
    }
    if (notify) {
        YMNavigationSidebarNotifyStateChanged();
    }
    if (retry) {
        YMNavigationSidebarSchedulePatchRetry(header, slide);
    }
}

static void YMNavigationSidebarImageAdded(const struct mach_header *header,
                                          std::intptr_t slide) {
    const std::uint32_t imageCount = _dyld_image_count();
    for (std::uint32_t index = 0; index < imageCount; ++index) {
        if (_dyld_get_image_header(index) != header) {
            continue;
        }
        if (YMNavigationSidebarIsTargetImage(_dyld_get_image_name(index))) {
            YMNavigationSidebarInstallHooks(header, slide);
        }
        return;
    }
}

struct YMNavigationSidebarSaveContext {
    void *owner{nullptr};
    void *controller{nullptr};
    std::array<std::uintptr_t, 3> items{};
    std::array<YMNavigationSidebarSetVisible, 3> setters{};
};

#pragma mark - 保存编排回调

static bool YMNavigationSidebarSaveReadSelected(
    void *rawContext,
    std::uintptr_t owner,
    int *output) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarSaveContext *>(rawContext);
    if (owner != reinterpret_cast<std::uintptr_t>(context.owner) ||
        context.controller == nullptr || output == nullptr ||
        YMNavigationSidebarGetSelectedPrimary == nullptr) {
        return false;
    }
    *output = YMNavigationSidebarGetSelectedPrimary(context.controller);
    return true;
}

static bool YMNavigationSidebarSaveReadPublished(
    void *,
    config::Configuration *configuration,
    runtime::Orders *orders) noexcept {
    if (configuration == nullptr || orders == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
    *configuration = YMNavigationSidebarDesiredConfiguration;
    *orders = YMNavigationSidebarAppliedSnapshot.DesiredOrders();
    return true;
}

static void YMNavigationSidebarSaveSelectPrimary(
    void *rawContext,
    std::uintptr_t owner,
    int type) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarSaveContext *>(rawContext);
    if (owner == reinterpret_cast<std::uintptr_t>(context.owner)) {
        YMNavigationSidebarSelectPrimary(context.owner, type);
    }
}

static void YMNavigationSidebarSaveSetVisible(
    void *rawContext,
    std::uintptr_t item,
    bool visible) noexcept {
    auto &context =
        *static_cast<YMNavigationSidebarSaveContext *>(rawContext);
    for (std::size_t index = 0; index < context.items.size(); ++index) {
        if (context.items[index] == item) {
            context.setters[index](reinterpret_cast<void *>(item), visible);
            return;
        }
    }
}

static void YMNavigationSidebarSavePublish(
    void *,
    const config::Configuration &configuration,
    const runtime::Orders &orders) noexcept {
    YMNavigationSidebarPublishDesiredConfiguration(configuration, orders);
}

static bool YMNavigationSidebarSaveScheduleLayout(
    void *,
    std::uintptr_t owner) noexcept {
    return YMNavigationSidebarRunResponsiveLayout(
        reinterpret_cast<void *>(owner));
}

static BOOL YMNavigationSidebarPerformSave(
    const config::PropertyList &input,
    NSError **error) {
    const config::ValidationResult validated =
        config::ValidateSaveInput(input);
    if (validated.configuration() == nullptr) {
        const config::ValidationError *validation = validated.error();
        const BOOL allPrimaryDisabled =
            validation != nullptr &&
            validation->code ==
                config::ValidationErrorCode::allPrimaryDisabled;
        NSString *message = allPrimaryDisabled
                                ? @"主导航至少需要保留一个入口。"
                                : validation != nullptr
                                      ? YMNavigationSidebarString(
                                            validation->message)
                                      : @"侧边栏配置格式无效。";
        if (error != nullptr) {
            *error = YMNavigationSidebarError(
                allPrimaryDisabled
                    ? YMNavigationSidebarErrorAllPrimaryDisabled
                    : YMNavigationSidebarErrorInvalidConfiguration,
                message,
                validation != nullptr
                    ? @{
                          @"validationCode" : @(static_cast<unsigned int>(
                              validation->code)),
                      }
                    : nil);
        }
        return NO;
    }

    runtime::Orders desiredOrders;
    if (!YMNavigationSidebarOrdersForConfiguration(
            *validated.configuration(), desiredOrders)) {
        if (error != nullptr) {
            *error = YMNavigationSidebarError(
                YMNavigationSidebarErrorInvalidConfiguration,
                @"侧边栏顺序不是完整的分组排列。");
        }
        return NO;
    }

    YMNavigationSidebarSaveContext callbacks;
    manager_orchestration::SaveRequest request;
    request.input = input;
    void *const owner =
        YMNavigationSidebarOwner.load(std::memory_order_acquire);
    const bool hasLiveOwner =
        owner != nullptr &&
        YMNavigationSidebarSupported.load(std::memory_order_acquire);
    if (hasLiveOwner) {
        // 启动早期打开设置窗口时，主窗口可能尚未把主导航条目建好（controller
        // 或条目仍为空）。此时不要拒绝保存：留空 request.owner，PerformSave
        // 会只落盘并发布目标配置，下一次原生布局回调读取已发布配置后自动应用。
        bool nativeReady =
            YMNavigationSidebarLookupNativeItem != nullptr &&
            YMNavigationSidebarSelectPrimary != nullptr &&
            YMNavigationSidebarGetSelectedPrimary != nullptr &&
            YMNavigationSidebarLoadPointerMember(
                owner,
                YMNavigationSidebarProfile().primaryControllerOffset,
                callbacks.controller);
        if (nativeReady) {
            for (std::size_t index = 0; index < request.items.size(); ++index) {
                const int type = runtime::NativeKeyFor(
                    runtime::kCanonicalPrimaryOrder[index]).type;
                void *const item = YMNavigationSidebarLookupNativeItem(
                    callbacks.controller, type);
                if (item == nullptr ||
                    YMNavigationSidebarReadNativeType(item) != type ||
                    !YMNavigationSidebarResolveSetVisible(
                        item, callbacks.setters[index])) {
                    nativeReady = false;
                    break;
                }
                callbacks.items[index] =
                    reinterpret_cast<std::uintptr_t>(item);
                request.items[index] = {type, callbacks.items[index]};
            }
        }
        if (nativeReady) {
            callbacks.owner = owner;
            request.owner = reinterpret_cast<std::uintptr_t>(owner);
            request.appliedPrimary =
                YMNavigationSidebarOrdersForOwner(owner).primary;
        } else {
            YMLog(@"[YMNavigationSidebar] native chain not ready; configuration "
                   "saved for deferred apply on next layout pass");
        }
    }

    const manager_orchestration::SaveOperations operations{
        &callbacks,
        &YMNavigationSidebarSaveReadSelected,
        &YMNavigationSidebarSaveReadPublished,
        &YMNavigationSidebarSaveSelectPrimary,
        &YMNavigationSidebarSaveSetVisible,
        &YMNavigationSidebarSavePublish,
        &YMNavigationSidebarSaveScheduleLayout,
    };
    const manager_orchestration::SaveResult saved =
        manager_orchestration::PerformSave(
            request, YMNavigationSidebarStorageAdapter(), operations);
    if (!saved.succeeded()) {
        if (error == nullptr) {
            return NO;
        }
        if (saved.error() == manager_orchestration::SaveError::persistence) {
            *error = YMNavigationSidebarPersistenceError(
                saved.persistenceResult());
            return NO;
        }
        if (saved.error() == manager_orchestration::SaveError::invalidInput) {
            const config::ValidationError *validation = saved.validationError();
            const BOOL allPrimaryDisabled =
                validation != nullptr &&
                validation->code ==
                    config::ValidationErrorCode::allPrimaryDisabled;
            *error = YMNavigationSidebarError(
                allPrimaryDisabled
                    ? YMNavigationSidebarErrorAllPrimaryDisabled
                    : YMNavigationSidebarErrorInvalidConfiguration,
                allPrimaryDisabled
                    ? @"主导航至少需要保留一个入口。"
                    : @"侧边栏配置格式无效。");
            return NO;
        }
        const BOOL fallbackFailure =
            saved.error() ==
                manager_orchestration::SaveError::primaryFallback ||
            saved.error() ==
                manager_orchestration::SaveError::selectionRestore;
        *error = YMNavigationSidebarError(
            fallbackFailure ? YMNavigationSidebarErrorPrimaryFallback
                            : YMNavigationSidebarErrorNativeApply,
            fallbackFailure
                ? @"无法验证或恢复主导航备用入口，配置未写入。"
                : @"主导航入口尚未完整初始化，配置未应用。");
        return NO;
    }
    YMNavigationSidebarNotifyStateChanged();
    return YES;
}

@implementation SidebarManager

+ (instancetype)sharedManager {
    static SidebarManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[SidebarManager alloc] init];
    });
    return manager;
}

+ (void)registerDefaults {
    NSMutableDictionary<NSString *, NSNumber *> *legacyDefaults =
        [NSMutableDictionary dictionary];
    for (int type : std::array<int, 6>{1, 2, 3, 5, 6, 7}) {
        legacyDefaults[YMNavigationSidebarLegacyDefaultsKey(type)] = @YES;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:legacyDefaults];

    config::Configuration loaded;
    if (YMNavigationSidebarLoadConfiguration(defaults, loaded)) {
        static_cast<void>(YMNavigationSidebarSetDesiredConfiguration(loaded));
    } else {
        YMLog(@"[YMNavigationSidebar] V2 defaults rejected; legacy values were "
               "not used because V2 has precedence");
    }

    void *owner = YMNavigationSidebarOwner.load(std::memory_order_acquire);
    if (owner != nullptr &&
        YMNavigationSidebarSupported.load(std::memory_order_acquire)) {
        YMNavigationSidebarScheduleApply(
            owner, YMNavigationSidebarApplyTrigger::defaultsReloaded);
    }
    YMNavigationSidebarNotifyStateChanged();
}

+ (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 必须在注册镜像回调之前把配置读进来。applied_ 快照是「每个 owner 只取
        // 一次 desired_」，而 owner 在微信建主窗口时就被捕获；如果那时配置还没
        // 加载（registerDefaults 过去只由助手菜单初始化触发），快照会冻结在默认
        // 的规范顺序上，用户保存的顺序此后再也应用不上——表现就是排序时灵时不灵。
        [self registerDefaults];
        _dyld_register_func_for_add_image(YMNavigationSidebarImageAdded);
    });
}

- (BOOL)isSupported {
    return YMNavigationSidebarSupported.load(std::memory_order_acquire);
}

- (BOOL)isReady {
    if (!self.supported) {
        return NO;
    }
    void *owner = YMNavigationSidebarOwner.load(std::memory_order_acquire);
    std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
    return YMNavigationSidebarOrderAvailability.Ready(owner);
}

- (BOOL)isPendingRestart {
    void *owner = YMNavigationSidebarOwner.load(std::memory_order_acquire);
    std::lock_guard<std::mutex> lock(YMNavigationSidebarStateMutex);
    return owner != nullptr &&
           YMNavigationSidebarAppliedSnapshot.HasPendingOrder(owner);
}

- (NSDictionary<NSString *, id> *)currentConfiguration {
    const config::PropertyList propertyList = config::ToPropertyList(
        YMNavigationSidebarConfigurationSnapshot());
    NSDictionary<NSString *, id> *result =
        YMNavigationSidebarFoundationPropertyList(propertyList);
    return result ?: @{};
}

- (BOOL)saveConfiguration:(NSDictionary<NSString *, id> *)configuration
                     error:(NSError **)error {
    if (error != nullptr) {
        *error = nil;
    }
    config::PropertyList propertyList;
    if (!YMNavigationSidebarFoundationToPropertyList(
            configuration, propertyList)) {
        if (error != nullptr) {
            *error = YMNavigationSidebarError(
                YMNavigationSidebarErrorInvalidConfiguration,
                @"侧边栏配置必须是完整的 V2 属性列表字典。");
        }
        return NO;
    }

    __block BOOL succeeded = NO;
    __block NSError *saveError = nil;
    void (^save)(void) = ^{
        succeeded = YMNavigationSidebarPerformSave(propertyList, &saveError);
    };
    if (NSThread.isMainThread) {
        save();
    } else {
        dispatch_sync(dispatch_get_main_queue(), save);
    }
    if (!succeeded && error != nullptr) {
        *error = saveError;
    }
    return succeeded;
}

- (BOOL)isEntryTypeEnabled:(NSInteger)entryType {
    const std::optional<config::Entry> entry =
        YMNavigationSidebarLegacyEntry((int)entryType);
    return entry.has_value() &&
           YMNavigationSidebarConfigurationSnapshot().isEnabled(*entry);
}

- (BOOL)setEntryType:(NSInteger)entryType
              enabled:(BOOL)enabled
                error:(NSError **)error {
    return [self setEntryStates:@{@(entryType) : @(enabled)} error:error];
}

- (BOOL)setEntryStates:(NSDictionary<NSNumber *, NSNumber *> *)entryStates
                  error:(NSError **)error {
    NSMutableDictionary<NSString *, id> *configuration =
        [self.currentConfiguration mutableCopy];
    NSMutableDictionary<NSString *, NSNumber *> *states =
        [configuration[YMNavigationSidebarStatesKey] mutableCopy];
    for (id rawType in entryStates) {
        id rawEnabled = entryStates[rawType];
        if (![rawType isKindOfClass:NSNumber.class] ||
            !YMNavigationSidebarNSNumberIsBoolean(rawEnabled)) {
            if (error != nullptr) {
                *error = YMNavigationSidebarError(
                    YMNavigationSidebarErrorInvalidConfiguration,
                    @"旧版入口状态必须使用已映射的整数与布尔值。");
            }
            return NO;
        }
        const std::optional<config::Entry> entry =
            YMNavigationSidebarLegacyEntry([rawType intValue]);
        if (!entry.has_value()) {
            if (error != nullptr) {
                *error = YMNavigationSidebarError(
                    YMNavigationSidebarErrorInvalidConfiguration,
                    @"这个旧版入口没有安全的分组映射。");
            }
            return NO;
        }
        states[YMNavigationSidebarString(config::Identifier(*entry))] =
            @([rawEnabled boolValue]);
    }
    configuration[YMNavigationSidebarStatesKey] = [states copy];
    return [self saveConfiguration:[configuration copy] error:error];
}

@end

__attribute__((constructor))
static void YMNavigationSidebarEntry(void) {
    @autoreleasepool {
        [SidebarManager start];
    }
}

#pragma once
#include <map>
#include <chrono>
// Included by RevokePatch.mm: verified arm64 Build 269079 only.
// Capture before replacement, confirm BOTH member DB and room future, then notify.
// No Frida dependency, no restore/repatch calls, no private calls on the DB worker.
struct YMGroupExitResponse {
    uint64_t nonce = 0, generation = 0;
    YMGroupExitAccount account;
    NSString *__strong room;
    NSSet<NSString *> *__strong before;
    NSSet<NSString *> *__strong after;
    NSDictionary<NSString *, NSString *> *__strong names;
    uint32_t version = 0;
    bool applied = false;
    std::chrono::steady_clock::time_point captured = std::chrono::steady_clock::now();
};
static std::atomic_bool YMGroupExitCaptureReady(false);
static std::map<uintptr_t, YMGroupExitResponse> &YMGroupExitResponses() {
    static std::map<uintptr_t, YMGroupExitResponse> value;
    return value;
}
static NSMutableDictionary<NSString *, NSNumber *> *YMGroupExitVersions() {
    static auto *value = [NSMutableDictionary new];
    return value;
}
static void YMGroupExitClearCapturedResponses(void) {
    YMGroupExitResponses().clear();
    [YMGroupExitVersions() removeAllObjects];
}
static YMGroupExitAccount &YMGroupExitCaptureAccount() {
    static YMGroupExitAccount value;
    return value;
}
// Caller holds StateMutex, never across a yielding native call.
static YMGroupExitAccount YMGroupExitCheckAccount() {
    auto account = YMGroupExitCurrentAccount();
    if (!(account == YMGroupExitCaptureAccount())) {
        YMGroupExitGeneration.fetch_add(1);
        YMGroupExitNicknameGeneration.fetch_add(1);
        YMGroupExitClearRuntimeState("account changed");
        YMGroupExitCaptureAccount() = account;
    }
    return account;
}
static NSSet<NSString *> *YMGroupExitReadMemberIDs(uintptr_t object, size_t listOffset,
                                                size_t countOffset, NSString *room) {
    int32_t count = 0;
    uintptr_t list = 0;
    if (!object || !YMSafeReadMemory(object + countOffset, &count, sizeof(count)) ||
        count <= 0 || count > 20000 || !YMSafeReadPointer(object + listOffset, &list) || !list) return nil;
    NSMutableSet *ids = [NSMutableSet setWithCapacity:count];
    for (int32_t i = 0; i < count; ++i) {
        uintptr_t member = 0, name = 0;
        if (!YMSafeReadPointer(list + size_t(i) * 8, &member) || !member ||
            !YMSafeReadPointer(member + 8, &name) || !name) return nil;
        NSString *id = YMNSStringFromLibcppStringObject((void *)name, 128);
        if (!YMGroupExitMemberIDLooksUseful(id, room) || [ids containsObject:id]) return nil;
        [ids addObject:id];
    }
    return [ids copy];
}
// Only plugin observation is caught. Native execution and its exceptions remain native-owned.
extern "C" void YMGroupExitCaptureResponse(uintptr_t frame, uintptr_t response, uintptr_t oldRoom) noexcept {
    @autoreleasepool { @try { try {
        std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
        auto &pending = YMGroupExitResponses();
        const auto now = std::chrono::steady_clock::now();
        for (auto it = pending.begin(); it != pending.end();) {
            if (now - it->second.captured > std::chrono::minutes(2)) it = pending.erase(it);
            else ++it;
        }
        pending.erase(frame); // Reused coroutine stack must never inherit an abandoned response.
        if (!YMGroupExitCaptureReady.load() || !YMIsGroupExitMonitorEnabled()) return;
        auto account = YMGroupExitCheckAccount();
        if (!account || !oldRoom || !response) return;
        uintptr_t roomPtr = 0;
        uint32_t version = 0, oldVersion = 0, advertised = 0;
        uint64_t oldCount = 0;
        if (!YMSafeReadPointer(response + 0x10, &roomPtr) || !roomPtr ||
            !YMSafeReadMemory(response + 0x20, &version, 4) ||
            !YMSafeReadMemory(response + 0x24, &advertised, 4) ||
            !YMSafeReadMemory(oldRoom + 0x7c, &oldVersion, 4) ||
            !YMSafeReadMemory(oldRoom + 0xd8, &oldCount, 8) || !oldVersion || version <= oldVersion) return;
        NSString *room = YMNSStringFromLibcppStringObject((void *)roomPtr, 128);
        if (![room hasSuffix:@"@chatroom"] ||
            ![room isEqualToString:YMNSStringFromLibcppStringObject((void *)(oldRoom + 8), 128)]) return;
        NSSet *before = YMGroupExitReadMemberIDs(oldRoom, 0x58, 0x60, room);
        NSSet *after = YMGroupExitReadMemberIDs(response, 0x30, 0x38, room);
        NSString *selfID = @(account.id.c_str());
        if (!before || !after || before.count != oldCount || after.count != advertised ||
            ![before containsObject:selfID] || ![after containsObject:selfID]) return;
        if (version <= [YMGroupExitVersions()[room] unsignedIntValue]) return;
        // ponytail: bound abandoned native frames; overflow drops observations, never native work.
        if (pending.size() >= 512) return;
        static uint64_t nonce = 0;
        YMGroupExitResponse item;
        item.nonce = ++nonce; item.generation = YMGroupExitGeneration.load();
        item.account = std::move(account); item.room = room;
        item.before = before; item.after = after; item.version = version;
        NSMutableDictionary *names = [NSMutableDictionary new];
        uintptr_t list = 0;
        if (YMSafeReadPointer(oldRoom + 0x58, &list)) {
            for (NSUInteger i = 0; i < before.count; ++i) {
                uintptr_t member = 0, idPtr = 0, namePtr = 0;
                if (!YMSafeReadPointer(list + i * 8, &member) || !member ||
                    !YMSafeReadPointer(member + 8, &idPtr) || !idPtr ||
                    !YMSafeReadPointer(member + 0x10, &namePtr) || !namePtr) continue;
                NSString *id = YMNSStringFromLibcppStringObject((void *)idPtr, 128);
                NSString *name = YMNSStringFromLibcppStringObject((void *)namePtr, 1024);
                if ([before containsObject:id] && YMGroupExitDisplayNameLooksUseful(name, id)) names[id] = name;
            }
        }
        item.names = [names copy];
        pending.emplace(frame, std::move(item));
    } catch (...) {} } @catch (NSException *exception) { (void)exception; } }
}
using YMGroupExitMemberDB = bool (*)(uintptr_t);
static YMGroupExitMemberDB YMGroupExitOriginalMemberDB = nullptr;
static bool YMGroupExitConfirmMemberDB(uintptr_t task) {
    std::vector<std::pair<uintptr_t, uint64_t>> candidates;
    @autoreleasepool { @try { try {
        if (YMGroupExitCaptureReady.load() && YMIsGroupExitMonitorEnabled()) {
            auto snapshots = YMGroupExitReadSnapshotsFromDBApplyTask(task);
            std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
            for (auto &[frame, item] : YMGroupExitResponses()) {
                if (item.generation == YMGroupExitGeneration.load() &&
                    [item.after isEqualToSet:snapshots[item.room]]) candidates.emplace_back(frame, item.nonce);
            }
            // No transaction token across queues: do not attribute an ambiguous write.
            if (candidates.size() != 1) candidates.clear();
        }
    } catch (...) {} } @catch (NSException *exception) { (void)exception; } }
    const bool success = YMGroupExitOriginalMemberDB(task); // no lock, preserve native exception propagation
    @try { try { if (success && !candidates.empty()) {
        std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
        auto found = YMGroupExitResponses().find(candidates[0].first);
        if (found != YMGroupExitResponses().end() && found->second.nonce == candidates[0].second &&
            found->second.generation == YMGroupExitGeneration.load()) found->second.applied = true;
    } } catch (...) {} } @catch (NSException *exception) { (void)exception; }
    return success;
}
static void YMGroupExitPumpNotices(void);
extern "C" void YMGroupExitCompleteResponse(uintptr_t nativeSP, bool success) noexcept {
    @autoreleasepool { @try { try {
        {
            std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
            auto account = YMGroupExitCheckAccount();
            auto &pending = YMGroupExitResponses();
            auto found = pending.find(nativeSP + 0xcc0);
            if (found == pending.end()) return;
            auto item = std::move(found->second);
            pending.erase(found);
            if (!YMGroupExitCaptureReady.load() || !success || !item.applied || !YMIsGroupExitMonitorEnabled() ||
                item.generation != YMGroupExitGeneration.load() || !(item.account == account)) return;
            uint32_t version = 0; uint64_t count = 0;
            const uintptr_t room = nativeSP + 0x140;
            if (!YMSafeReadMemory(room + 0x7c, &version, 4) || version != item.version ||
                !YMSafeReadMemory(room + 0xd8, &count, 8) || count != item.after.count ||
                ![item.room isEqualToString:YMNSStringFromLibcppStringObject((void *)(room + 8), 128)] ||
                ![item.after isEqualToSet:YMGroupExitReadMemberIDs(room, 0x58, 0x60, item.room)] ||
                version <= [YMGroupExitVersions()[item.room] unsignedIntValue]) return;
            YMGroupExitVersions()[item.room] = @(version);
            for (NSString *member in item.names)
                YMGroupExitCacheDisplayName(item.room, member, item.names[member], "old member response");
            // The old model belongs to this response, including the first sync after relaunch.
            YMGroupExitMemberCache()[item.room] = item.before;
            YMGroupExitHandleDBApplySnapshot(item.room, item.after);
        }
        YMGroupExitPost([] { YMGroupExitPumpNotices(); });
    } catch (...) {} } @catch (NSException *exception) { (void)exception; } }
}
// Reuse the already verified coroutine scheduler only to insert confirmed notices.
static void YMGroupExitPumpNotices(void) {
    @autoreleasepool { try {
        YMGroupExitAccount account; uint64_t generation;
        {
            std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
            account = YMGroupExitCheckAccount(); generation = YMGroupExitGeneration.load();
            if (!account || !YMIsGroupExitMonitorEnabled() || !YMGroupExitPendingNotices().count) return;
        }
        static std::atomic_bool busy(false);
        if (busy.exchange(true)) return;
        try {
            auto finished = std::make_shared<std::atomic_bool>(false);
            std::function<void()> work = [account, generation, finished] {
                @autoreleasepool { try {
                    auto current = [&] {
                        return !finished->load() && YMIsGroupExitMonitorEnabled() &&
                            generation == YMGroupExitGeneration.load() && account == YMGroupExitCurrentAccount();
                    };
                    if (current()) YMGroupExitFlushPendingNotices("confirmed member response", current);
                } catch (...) { YMLog(@"[GroupExitMonitor] notice task cancelled"); } }
                if (!finished->exchange(true)) busy.store(false);
            };
            void *app = ((void *(*)())YMRuntimeAddress(0x428D0BC))();
            auto scheduler = app ? ((YMGroupExitGetter)YMRuntimeAddress(0x428E6A0))(app) : YMGroupExitShared{};
            auto task = scheduler ? ((YMGroupExitShared (*)(void *, const GX::SourceLocation *, std::function<void()> *, int))
                YMRuntimeAddress(0x3A280F0))(scheduler.get(), &YMGroupExitLocation, &work, 1) : YMGroupExitShared{};
            if (!task || *(uintptr_t *)task.get() != YMRuntimeAddress(0x8EB9550) ||
                ((bool (*)(void *))YMRuntimeAddress(0x597C66C))(task.get())) {
                finished->store(true); busy.store(false); return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (finished->exchange(true)) return;
                busy.store(false);
                try { ((void (*)(void *))YMRuntimeAddress(0x597BE88))(task.get()); } catch (...) {}
            });
        } catch (...) { busy.store(false); }
    } catch (...) { YMLog(@"[GroupExitMonitor] notice scheduling failed; will retry"); } }
}

#if defined(__aarch64__)
extern "C" {
uintptr_t YMExitEntryAfter = 0, YMExitResultAfter = 0, YMExitResultZero = 0;
void YMExitEntryBridge(void);
void YMExitResultBridge(void);
}
__asm__(
    ".macro YMExitSave\n"
    "sub sp, sp, #0x310\n"
    "stp x0, x1, [sp, #0]\n"
    "stp x2, x3, [sp, #16]\n"
    "stp x4, x5, [sp, #32]\n"
    "stp x6, x7, [sp, #48]\n"
    "stp x8, x9, [sp, #64]\n"
    "stp x10, x11, [sp, #80]\n"
    "stp x12, x13, [sp, #96]\n"
    "stp x14, x15, [sp, #112]\n"
    "stp x16, x17, [sp, #128]\n"
    "stp x18, x19, [sp, #144]\n"
    "stp x20, x21, [sp, #160]\n"
    "stp x22, x23, [sp, #176]\n"
    "stp x24, x25, [sp, #192]\n"
    "stp x26, x27, [sp, #208]\n"
    "stp x28, x29, [sp, #224]\n"
    "str x30, [sp, #240]\n"
    "mrs x16, nzcv\n"
    "str x16, [sp, #248]\n"
    "stp q0, q1, [sp, #256]\n"
    "stp q2, q3, [sp, #288]\n"
    "stp q4, q5, [sp, #320]\n"
    "stp q6, q7, [sp, #352]\n"
    "stp q8, q9, [sp, #384]\n"
    "stp q10, q11, [sp, #416]\n"
    "stp q12, q13, [sp, #448]\n"
    "stp q14, q15, [sp, #480]\n"
    "stp q16, q17, [sp, #512]\n"
    "stp q18, q19, [sp, #544]\n"
    "stp q20, q21, [sp, #576]\n"
    "stp q22, q23, [sp, #608]\n"
    "stp q24, q25, [sp, #640]\n"
    "stp q26, q27, [sp, #672]\n"
    "stp q28, q29, [sp, #704]\n"
    "stp q30, q31, [sp, #736]\n"
    ".endmacro\n"
    ".macro YMExitRestore\n"
    "ldp q0, q1, [sp, #256]\n"
    "ldp q2, q3, [sp, #288]\n"
    "ldp q4, q5, [sp, #320]\n"
    "ldp q6, q7, [sp, #352]\n"
    "ldp q8, q9, [sp, #384]\n"
    "ldp q10, q11, [sp, #416]\n"
    "ldp q12, q13, [sp, #448]\n"
    "ldp q14, q15, [sp, #480]\n"
    "ldp q16, q17, [sp, #512]\n"
    "ldp q18, q19, [sp, #544]\n"
    "ldp q20, q21, [sp, #576]\n"
    "ldp q22, q23, [sp, #608]\n"
    "ldp q24, q25, [sp, #640]\n"
    "ldp q26, q27, [sp, #672]\n"
    "ldp q28, q29, [sp, #704]\n"
    "ldp q30, q31, [sp, #736]\n"
    "ldr x16, [sp, #248]\n"
    "msr nzcv, x16\n"
    "ldp x0, x1, [sp, #0]\n"
    "ldp x2, x3, [sp, #16]\n"
    "ldp x4, x5, [sp, #32]\n"
    "ldp x6, x7, [sp, #48]\n"
    "ldp x8, x9, [sp, #64]\n"
    "ldp x10, x11, [sp, #80]\n"
    "ldp x12, x13, [sp, #96]\n"
    "ldp x14, x15, [sp, #112]\n"
    "ldp x16, x17, [sp, #128]\n"
    "ldp x18, x19, [sp, #144]\n"
    "ldp x20, x21, [sp, #160]\n"
    "ldp x22, x23, [sp, #176]\n"
    "ldp x24, x25, [sp, #192]\n"
    "ldp x26, x27, [sp, #208]\n"
    "ldp x28, x29, [sp, #224]\n"
    "ldr x30, [sp, #240]\n"
    "add sp, sp, #0x310\n"
    ".endmacro\n"
);
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMExitEntryBridge\n"
    "_YMExitEntryBridge:\n"
    "YMExitSave\n"
    "add x0, sp, #0x310\n"
    "bl _YMGroupExitCaptureResponse\n"
    "YMExitRestore\n"
    "stp x28, x27, [sp, #-0x60]!\n"
    "stp x26, x25, [sp, #0x10]\n"
    "stp x24, x23, [sp, #0x20]\n"
    "stp x22, x21, [sp, #0x30]\n"
    "adrp x16, _YMExitEntryAfter@PAGE\n"
    "ldr x16, [x16, _YMExitEntryAfter@PAGEOFF]\n"
    "br x16\n"
    ".align 2\n"
    ".globl _YMExitResultBridge\n"
    "_YMExitResultBridge:\n"
    "YMExitSave\n"
    "ldrb w1, [x0]\n"
    "and w1, w1, #1\n"
    "add x0, sp, #0x310\n"
    "bl _YMGroupExitCompleteResponse\n"
    "YMExitRestore\n"
    "ldrb w19, [x0]\n"
    "ldr x23, [sp, #0x2a8]\n"
    "cbz x23, 1f\n"
    "add x8, x23, #8\n"
    "adrp x16, _YMExitResultAfter@PAGE\n"
    "ldr x16, [x16, _YMExitResultAfter@PAGEOFF]\n"
    "br x16\n"
    "1:\n"
    "adrp x16, _YMExitResultZero@PAGE\n"
    "ldr x16, [x16, _YMExitResultZero@PAGEOFF]\n"
    "br x16\n"
);
#endif
static BOOL YMGroupExitWriteCodeBytes(uintptr_t, const uint8_t *, size_t, const char *, const char *);
// The task vtable is DYLD_CHAINED_PTR_64_OFFSET (not authenticated). Keep its protection.
static bool YMGroupExitWriteDBSlot(uintptr_t value) {
    vm_address_t address = YMRuntimeAddress(0x8CEF178), region = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    auto result = vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || region > address || address + 8 > region + size) return false;
    if (!YMProtectCodePage(address, 8, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY, "member DB slot", "write")) return false;
    __atomic_store_n((uintptr_t *)address, value, __ATOMIC_RELEASE);
    return YMProtectCodePage(address, 8, info.protection, "member DB slot", "restore protection");
}
static BOOL YMGroupExitInstallCapture(void) {
#if defined(__aarch64__)
    if (YMHasPatchedGroupExitMonitor) return YES;
    if (!YMGroupExitCaptureABIReady()) return NO;
    static const uint8_t entry[16] = {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9};
    static const uint8_t result[16] = {0x13,0x00,0x40,0x39,0xf7,0x57,0x41,0xf9,0xb7,0x00,0x00,0xb4,0xe8,0x22,0x00,0x91};
    uint8_t bytes[16]; uintptr_t slot = 0;
    if (!YMSafeReadMemory(YMRuntimeAddress(0x213AB2C), bytes, 16) || memcmp(bytes, entry, 16) ||
        !YMSafeReadMemory(YMRuntimeAddress(0x213C83C), bytes, 16) || memcmp(bytes, result, 16) ||
        !YMSafeReadMemory(YMRuntimeAddress(0x2291064), bytes, 16) || memcmp(bytes, entry, 16) ||
        !YMSafeReadPointer(YMRuntimeAddress(0x8CEF178), &slot) || slot != YMRuntimeAddress(0x2291064)) return NO;
    YMExitEntryAfter = YMRuntimeAddress(0x213AB3C);
    YMExitResultAfter = YMRuntimeAddress(0x213C84C);
    YMExitResultZero = YMRuntimeAddress(0x213C858);
    YMGroupExitOriginalMemberDB = (YMGroupExitMemberDB)slot;
    bool installed = YMGroupExitWriteDBSlot((uintptr_t)&YMGroupExitConfirmMemberDB) &&
        YMPatchARM64AbsoluteJump(YMRuntimeAddress(0x213C83C), (uintptr_t)&YMExitResultBridge, "member response result") &&
        YMPatchARM64AbsoluteJump(YMRuntimeAddress(0x213AB2C), (uintptr_t)&YMExitEntryBridge, "member response capture");
    if (!installed) {
        YMGroupExitCaptureReady.store(false);
        // All bridges retain valid continuations even if protection restoration fails.
        bool restoredEntry = YMGroupExitWriteCodeBytes(YMRuntimeAddress(0x213AB2C), entry, 16, "member response", "rollback");
        bool restoredResult = YMGroupExitWriteCodeBytes(YMRuntimeAddress(0x213C83C), result, 16, "member response result", "rollback");
        bool restoredSlot = YMGroupExitWriteDBSlot(slot);
        YMLog(@"[GroupExitMonitor] capture installation failed; rollback=%@; monitoring unavailable",
              restoredEntry && restoredResult && restoredSlot ? @"OK" : @"FAILED");
        return NO;
    }
    YMHasPatchedGroupExitMonitor = YES;
    YMGroupExitCaptureReady.store(true);
    // ponytail: only lifecycle/pending notices every 2s; never enumerate groups or poll member lists.
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_source_t timer;
        if (!timer) {
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
            dispatch_source_set_event_handler(timer, ^{ YMGroupExitPost([] { YMGroupExitPumpNotices(); }); });
            dispatch_resume(timer);
        }
    });
    YMLog(@"[GroupExitMonitor] confirmed response capture installed");
    return YES;
#else
    return NO;
#endif
}

#import "ForwardNoticeNavigation.h"
#import "ForwardNoticeStore.h"
#import "MessageNavigation.h"
#import "MessageHistory.h"
#import "RevokePatch.h"
#import "SelfRevokePatch.h"
#import "WeChatCompatibility.h"
#import <AppKit/AppKit.h>
#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <mach/mach_vm.h>

#if defined(__aarch64__)
namespace {
thread_local NSDictionary *__unsafe_unretained activeTarget;
bool noticeV420 = false;
// TLS 只借用同步作用域的对象；scope 自身持有当前和上层目标，保证嵌套期间存活。
std::atomic_bool captureInstalled{false}, bindInstalled{false}, deleteInstalled{false}, clearInstalled{false}, clearAccountInstalled{false};
struct Pending {
    std::weak_ptr<void> item;
    NSDictionary *target;
    std::vector<YMForwardNoticeMessageIdentity> deletedCarriers;
};
std::mutex pendingMutex;
std::map<uintptr_t, Pending> pending;
dispatch_queue_t associationQueue() {
    static dispatch_queue_t queue=dispatch_queue_create("PrivateSoviet.forward-notices", DISPATCH_QUEUE_SERIAL);
    return queue;
}
struct Entry { uintptr_t va; uint8_t bytes[16]; };
const Entry captureEntryOld{0x3638f00,{0xff,0x83,0x02,0xd1,0xfa,0x67,0x05,0xa9,0xf8,0x5f,0x06,0xa9,0xf6,0x57,0x07,0xa9}};
const Entry bindEntryOld{0x27c1680,{0xf3,0x0b,0x40,0xf9,0x73,0x01,0x00,0xb4,0x68,0x22,0x00,0x91,0x09,0x00,0x80,0x92}};
const Entry deleteEntryOld{0x2859b48,{0xff,0x7f,0x02,0xa9,0xff,0x1b,0x00,0xf9,0x89,0x22,0x40,0xa9,0x08,0x01,0x09,0xcb}};
const Entry clearEntryOld{0x2857b70,{0x15,0x00,0x40,0x39,0xf7,0x13,0x40,0xf9,0x77,0x01,0x00,0xb4,0xe8,0x22,0x00,0x91}};
const Entry clearAccountEntryOld{0x3799114,{0xf3,0x03,0x00,0xaa,0xf4,0x1f,0x40,0xf9,0x74,0x01,0x00,0xb4,0x88,0x22,0x00,0x91}};
const Entry captureEntryNew{0x42528ec,{0xff,0x83,0x02,0xd1,0xfa,0x67,0x05,0xa9,0xf8,0x5f,0x06,0xa9,0xf6,0x57,0x07,0xa9}};
const Entry &captureEntry() { return noticeV420 ? captureEntryNew : captureEntryOld; }
const Entry bindEntryNew{0x3213c5c,{0xf3,0x0b,0x40,0xf9,0x73,0x01,0x00,0xb4,0x68,0x22,0x00,0x91,0x09,0x00,0x80,0x92}};
const Entry &bindEntry() { return noticeV420 ? bindEntryNew : bindEntryOld; }
const Entry deleteEntryNew{0x32bfb88,{0xff,0x7f,0x02,0xa9,0xff,0x1b,0x00,0xf9,0x89,0x22,0x40,0xa9,0x08,0x01,0x09,0xcb}};
const Entry &deleteEntry() { return noticeV420 ? deleteEntryNew : deleteEntryOld; }
const Entry clearEntryNew{0x32bdb70,{0x15,0x00,0x40,0x39,0xf7,0x13,0x40,0xf9,0x77,0x01,0x00,0xb4,0xe8,0x22,0x00,0x91}};
const Entry &clearEntry() { return noticeV420 ? clearEntryNew : clearEntryOld; }
const Entry clearAccountEntryNew{0x43bc634,{0xf3,0x03,0x00,0xaa,0xf4,0x1f,0x40,0xf9,0x74,0x01,0x00,0xb4,0x88,0x22,0x00,0x91}};
const Entry &clearAccountEntry() { return noticeV420 ? clearAccountEntryNew : clearAccountEntryOld; }
bool matches(const Entry &e) {
    uint8_t actual[16]; mach_vm_size_t copied=0;
    return mach_vm_read_overwrite(mach_task_self(), YMRuntimeAddress(e.va), sizeof actual,
        (mach_vm_address_t)actual, &copied)==KERN_SUCCESS && copied==sizeof actual && !memcmp(actual,e.bytes,sizeof actual);
}
template<class T> const T &field(uintptr_t p,size_t offset) { return *reinterpret_cast<const T *>(p+offset); }
NSString *stringField(uintptr_t p,size_t offset) {
    const auto &s=field<std::string>(p,offset);
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}
}
YMForwardNoticeScope::YMForwardNoticeScope(NSDictionary *target):previous(activeTarget),current(target) {
    activeTarget=captureInstalled.load() && bindInstalled.load() ? current : nil;
}
YMForwardNoticeScope::~YMForwardNoticeScope() { activeTarget=previous; }
extern "C" void YMForwardNoticeCapture(const std::vector<std::shared_ptr<void>> *items) noexcept {
    @try { try {
        NSDictionary *target=activeTarget;
        if (!target || !items || items->size()!=1 || !items->front() ||
            ![target[@"account"] isEqual:YMSelfRevokeAccount()]) return;
        std::lock_guard<std::mutex> lock(pendingMutex);
        // 只登记本次提交构造出的对象；弱引用避免地址复用误绑定和延长原生任务生命。
        for (auto it=pending.begin();it!=pending.end();) {
            if (it->second.item.expired()) it=pending.erase(it); else ++it;
        }
        pending.insert_or_assign((uintptr_t)items->front().get(), Pending{items->front(),target,{}});
    } catch (...) { YMLog(@"[ForwardNotice] capture failed"); } }
    @catch(NSException *) { YMLog(@"[ForwardNotice] capture failed"); }
}
extern "C" void YMForwardNoticeBind(uintptr_t contextRef) noexcept {
    @try { try {
        if (!contextRef) return;
        uintptr_t context=field<uintptr_t>(contextRef,0);
        if (!context) return;
        uintptr_t item=field<uintptr_t>(context,8);
        NSDictionary *target=nil;
        std::vector<YMForwardNoticeMessageIdentity> deletedCarriers;
        std::lock_guard<std::mutex> lock(pendingMutex);
        {
            auto it=pending.find(item);
            if(it==pending.end()) return;
            auto owner=it->second.item.lock();
            if(owner && (uintptr_t)owner.get()==item) {
                target=it->second.target;
                deletedCarriers=std::move(it->second.deletedCarriers);
            }
            pending.erase(it);
        }
        if(!target || ![target[@"account"] isEqual:YMSelfRevokeAccount()]) return;
        uintptr_t wrap=field<uintptr_t>(context,0x18);
        if(!wrap || field<uint32_t>(wrap,0xc)!=1 || !field<uint32_t>(wrap,0xf4)) return;
        NSString *account=target[@"account"];
        if(![stringField(wrap,0x18) isEqual:account] || ![stringField(wrap,0x30) isEqual:account] ||
           ![YMSelfRevokeSession(wrap) isEqual:account]) return;
        uint32_t localID=field<uint32_t>(wrap,0xf4), sec=field<uint32_t>(wrap,0x114);
        uint64_t seq=field<uint64_t>(wrap,0x100), original=strtoull([target[@"serverID"] UTF8String], nullptr, 10);
        for(const auto &deleted:deletedCarriers)
            if(deleted.localID==localID && deleted.sortSeq==seq && deleted.createSec==sec) return;
        // 复制身份后异步写插件自己的库；不在原生发送协程中执行磁盘 IO。
        dispatch_async(associationQueue(), ^{
            if(!YMStoreForwardNotice(account,account,localID,seq,sec,target[@"session"],original))
                YMLog(@"[ForwardNotice] local association was not saved");
        });
    } catch (...) { YMLog(@"[ForwardNotice] binding failed"); } }
    @catch(NSException *) { YMLog(@"[ForwardNotice] binding failed"); }
}
// 只由原生数据库删除成功分支调用；在原生发布列表变更前完成关联清理。
extern "C" void YMForwardNoticeDeleted(const std::string *session, const uintptr_t *range) noexcept {
    @try { try {
        NSString *account=YMSelfRevokeAccount();
        if(!account.length || !session || !range || range[1]<range[0] ||
           (range[1]-range[0])%(noticeV420 ? 0x278 : 0x268) || (range[1]!=range[0] && !range[0])) return;
        NSString *name=[[NSString alloc] initWithBytes:session->data() length:session->size() encoding:NSUTF8StringEncoding];
        if(!name.length) return;
        std::vector<YMForwardNoticeMessageIdentity> identities;
        for(uintptr_t wrap=range[0];wrap<range[1];wrap+=(noticeV420 ? 0x278 : 0x268))
            identities.push_back({field<uint32_t>(wrap,0xf4),field<uint64_t>(wrap,0x100),
                field<uint32_t>(wrap,0x114),field<uint64_t>(wrap,0xf8)});
        if(identities.empty()) return;
        NSMutableArray *deletedMessages=[NSMutableArray new];
        for(const auto &id:identities) {
            NSDictionary *identity=YMMessageHistoryIdentity(name,id.localID,id.serverID,id.sortSeq,id.createSec);
            if(identity) [deletedMessages addObject:identity];
        }
        YMPostMessageHistoryDeletion(account,name,deletedMessages);
        std::lock_guard<std::mutex> lock(pendingMutex);
        // 尚未完成通知落库的原文也要取消关联，避免删除后又被异步写回。
        for(auto it=pending.begin();it!=pending.end();) {
            NSDictionary *target=it->second.target;
            bool remove=false;
            if([target[@"account"] isEqual:account] && [target[@"session"] isEqual:name]) {
                uint64_t original=strtoull([target[@"serverID"] UTF8String],nullptr,10);
                for(const auto &id:identities) if(id.serverID && id.serverID==original) { remove=true;break; }
            }
            if(remove) it=pending.erase(it);
            else {
                // 载体可能已落库、绑定回调尚未恢复；仅在当前在途任务中记住删除身份。
                if([target[@"account"] isEqual:account] && [name isEqual:account])
                    it->second.deletedCarriers.insert(it->second.deletedCarriers.end(),identities.begin(),identities.end());
                ++it;
            }
        }
        dispatch_sync(associationQueue(), ^{
            if(!YMDeleteForwardNoticesForMessages(account,name,identities))
                YMLog(@"[ForwardNotice] deleted message associations could not be cleared");
        });
    } catch (...) { YMLog(@"[ForwardNotice] deletion cleanup failed"); } }
    @catch(NSException *) { YMLog(@"[ForwardNotice] deletion cleanup failed"); }
}
extern "C" void YMForwardNoticeSessionCleared(const std::string *session, bool succeeded) noexcept {
    if(!succeeded) return;
    @try { try {
        NSString *account=YMSelfRevokeAccount();
        if(!account.length || !session) return;
        NSString *name=[[NSString alloc] initWithBytes:session->data() length:session->size() encoding:NSUTF8StringEncoding];
        if(!name.length) return;
        YMPostMessageHistoryDeletion(account,name,nil);
        std::lock_guard<std::mutex> lock(pendingMutex);
        for(auto it=pending.begin();it!=pending.end();) {
            NSDictionary *target=it->second.target;
            if([target[@"account"] isEqual:account] &&
               ([name isEqual:account] || [target[@"session"] isEqual:name])) it=pending.erase(it);
            else ++it;
        }
        dispatch_sync(associationQueue(), ^{
            if(!YMClearForwardNoticesForSession(account,name))
                YMLog(@"[ForwardNotice] cleared session associations could not be cleared");
        });
    } catch (...) { YMLog(@"[ForwardNotice] session cleanup failed"); } }
    @catch(NSException *) { YMLog(@"[ForwardNotice] session cleanup failed"); }
}
extern "C" void YMForwardNoticeAccountCleared(bool succeeded) noexcept {
    if(!succeeded) return;
    @try { try {
        NSString *account=YMSelfRevokeAccount();
        if(!account.length) return;
        YMPostMessageHistoryDeletion(account,nil,nil);
        std::lock_guard<std::mutex> lock(pendingMutex);
        for(auto it=pending.begin();it!=pending.end();)
            if([it->second.target[@"account"] isEqual:account]) it=pending.erase(it); else ++it;
        dispatch_sync(associationQueue(), ^{
            if(!YMClearForwardNoticesForAccount(account))
                YMLog(@"[ForwardNotice] account associations could not be cleared");
        });
    } catch (...) { YMLog(@"[ForwardNotice] account cleanup failed"); } }
    @catch(NSException *) { YMLog(@"[ForwardNotice] account cleanup failed"); }
}
std::function<void()> YMForwardNoticeOriginalAction(uintptr_t data) {
    if(!data || !bindInstalled.load() || !captureInstalled.load()) return {};
    @try { try {
        NSString *account=YMSelfRevokeAccount();
        if(!account.length || field<uint32_t>(data,8)!=1 ||
           ![stringField(data,0x10) isEqual:account] || ![stringField(data,0x28) isEqual:account] ||
           ![stringField(data,0x58) isEqual:account]) return {};
        uint32_t localID=field<uint32_t>(data,0x74),sec=field<uint32_t>(data,noticeV420 ? 0xa8 : 0xa0);
        uint64_t seq=field<uint64_t>(data,noticeV420 ? 0xa0 : 0x98);
        NSDictionary *record=YMLoadForwardNotice(account,account,localID,seq,sec);
        if(!record) return {};
        return [record,account,localID,seq,sec] {
            // 菜单打开后可能删除原文；失效关联不再触发导航。
            if([YMLoadForwardNotice(account,account,localID,seq,sec) isEqual:record])
                YMNavigateOriginalMessage(record);
        };
    } catch (...) { return {}; } } @catch(NSException *) { return {}; }
}
extern "C" {
uintptr_t YMForwardNoticeCaptureContinue=0, YMForwardNoticeBindContinue=0, YMForwardNoticeBindEmpty=0;
uintptr_t YMForwardNoticeDeleteContinue=0, YMForwardNoticeClearContinue=0, YMForwardNoticeClearEmpty=0;
uintptr_t YMForwardNoticeAccountContinue=0, YMForwardNoticeAccountEmpty=0;
void YMForwardNoticeAccountBridge();
void YMForwardNoticeClearBridge();
void YMForwardNoticeDeleteBridge();
void YMForwardNoticeCaptureBridge(); void YMForwardNoticeBindBridge();
}
bool YMForwardNoticeSendEntryCompatible(void) {
    noticeV420 = YMMatchesWeChat270353Dylib();
    if(matches(captureEntry())) return true;
    if(!captureInstalled.load() ||
       YMForwardNoticeCaptureContinue!=YMRuntimeAddress(captureEntry().va+16)) return false;
    uint32_t instructions[2]={0x58000050,0xD61F0200};
    Entry bridge{captureEntry().va,{}};
    uintptr_t target=(uintptr_t)&YMForwardNoticeCaptureBridge;
    memcpy(bridge.bytes,instructions,sizeof instructions);
    memcpy(bridge.bytes+8,&target,sizeof target);
    return matches(bridge);
}
// 保留参数、间接返回寄存器、浮点寄存器及标志；后置桥重定位原 cbz。
__asm__(
    ".text\n"
    ".align 2\n"
    ".globl _YMForwardNoticeCaptureBridge\n"
    "_YMForwardNoticeCaptureBridge:\n"
    "sub sp, sp, #0x120\n"
    "stp x0, x1, [sp, #0]\n"
    "stp x2, x3, [sp, #16]\n"
    "stp x4, x5, [sp, #32]\n"
    "stp x6, x7, [sp, #48]\n"
    "stp x8, x9, [sp, #64]\n"
    "stp x10, x11, [sp, #80]\n"
    "stp x12, x13, [sp, #96]\n"
    "stp x14, x15, [sp, #112]\n"
    "stp x16, x17, [sp, #128]\n"
    "str x30, [sp, #0x90]\n"
    "mrs x9, nzcv\n"
    "str x9, [sp, #0x98]\n"
    "stp q0, q1, [sp, #160]\n"
    "stp q2, q3, [sp, #192]\n"
    "stp q4, q5, [sp, #224]\n"
    "stp q6, q7, [sp, #256]\n"
    "mov x0, x1\n"
    "bl _YMForwardNoticeCapture\n"
    "ldp q0, q1, [sp, #160]\n"
    "ldp q2, q3, [sp, #192]\n"
    "ldp q4, q5, [sp, #224]\n"
    "ldp q6, q7, [sp, #256]\n"
    "ldr x9, [sp, #0x98]\n"
    "msr nzcv, x9\n"
    "ldr x30, [sp, #0x90]\n"
    "ldp x0, x1, [sp, #0]\n"
    "ldp x2, x3, [sp, #16]\n"
    "ldp x4, x5, [sp, #32]\n"
    "ldp x6, x7, [sp, #48]\n"
    "ldp x8, x9, [sp, #64]\n"
    "ldp x10, x11, [sp, #80]\n"
    "ldp x12, x13, [sp, #96]\n"
    "ldp x14, x15, [sp, #112]\n"
    "ldp x16, x17, [sp, #128]\n"
    "add sp, sp, #0x120\n"
    "sub sp, sp, #0xa0\n"
    "stp x26, x25, [sp, #0x50]\n"
    "stp x24, x23, [sp, #0x60]\n"
    "stp x22, x21, [sp, #0x70]\n"
    "adrp x16, _YMForwardNoticeCaptureContinue@PAGE\n"
    "ldr x16, [x16, _YMForwardNoticeCaptureContinue@PAGEOFF]\n"
    "br x16\n"
    ".align 2\n"
    ".globl _YMForwardNoticeBindBridge\n"
    "_YMForwardNoticeBindBridge:\n"
    "sub sp, sp, #0x120\n"
    "stp x0, x1, [sp, #0]\n"
    "stp x2, x3, [sp, #16]\n"
    "stp x4, x5, [sp, #32]\n"
    "stp x6, x7, [sp, #48]\n"
    "stp x8, x9, [sp, #64]\n"
    "stp x10, x11, [sp, #80]\n"
    "stp x12, x13, [sp, #96]\n"
    "stp x14, x15, [sp, #112]\n"
    "stp x16, x17, [sp, #128]\n"
    "str x30, [sp, #0x90]\n"
    "mrs x9, nzcv\n"
    "str x9, [sp, #0x98]\n"
    "stp q0, q1, [sp, #160]\n"
    "stp q2, q3, [sp, #192]\n"
    "stp q4, q5, [sp, #224]\n"
    "stp q6, q7, [sp, #256]\n"
    "mov x0, x21\n"
    "bl _YMForwardNoticeBind\n"
    "ldp q0, q1, [sp, #160]\n"
    "ldp q2, q3, [sp, #192]\n"
    "ldp q4, q5, [sp, #224]\n"
    "ldp q6, q7, [sp, #256]\n"
    "ldr x9, [sp, #0x98]\n"
    "msr nzcv, x9\n"
    "ldr x30, [sp, #0x90]\n"
    "ldp x0, x1, [sp, #0]\n"
    "ldp x2, x3, [sp, #16]\n"
    "ldp x4, x5, [sp, #32]\n"
    "ldp x6, x7, [sp, #48]\n"
    "ldp x8, x9, [sp, #64]\n"
    "ldp x10, x11, [sp, #80]\n"
    "ldp x12, x13, [sp, #96]\n"
    "ldp x14, x15, [sp, #112]\n"
    "ldp x16, x17, [sp, #128]\n"
    "add sp, sp, #0x120\n"
    "ldr x19, [sp, #0x10]\n"
    "cbz x19, 1f\n"
    "add x8, x19, #8\n"
    "mov x9, #-1\n"
    "adrp x16, _YMForwardNoticeBindContinue@PAGE\n"
    "ldr x16, [x16, _YMForwardNoticeBindContinue@PAGEOFF]\n"
    "br x16\n"
    "1:\n"
    "adrp x16, _YMForwardNoticeBindEmpty@PAGE\n"
    "ldr x16, [x16, _YMForwardNoticeBindEmpty@PAGEOFF]\n"
    "br x16\n"
    ".align 2\n"
    ".globl _YMForwardNoticeDeleteBridge\n"
    "_YMForwardNoticeDeleteBridge:\n"
    "sub sp, sp, #0x120\n"
    "stp x0, x1, [sp, #0]\n"
    "stp x2, x3, [sp, #16]\n"
    "stp x4, x5, [sp, #32]\n"
    "stp x6, x7, [sp, #48]\n"
    "stp x8, x9, [sp, #64]\n"
    "stp x10, x11, [sp, #80]\n"
    "stp x12, x13, [sp, #96]\n"
    "stp x14, x15, [sp, #112]\n"
    "stp x16, x17, [sp, #128]\n"
    "str x30, [sp, #0x90]\n"
    "mrs x9, nzcv\n"
    "str x9, [sp, #0x98]\n"
    "stp q0, q1, [sp, #160]\n"
    "stp q2, q3, [sp, #192]\n"
    "stp q4, q5, [sp, #224]\n"
    "stp q6, q7, [sp, #256]\n"
    "mov x0, x22\n"
    "mov x1, x20\n"
    "bl _YMForwardNoticeDeleted\n"
    "ldp q0, q1, [sp, #160]\n"
    "ldp q2, q3, [sp, #192]\n"
    "ldp q4, q5, [sp, #224]\n"
    "ldp q6, q7, [sp, #256]\n"
    "ldr x9, [sp, #0x98]\n"
    "msr nzcv, x9\n"
    "ldr x30, [sp, #0x90]\n"
    "ldp x0, x1, [sp, #0]\n"
    "ldp x2, x3, [sp, #16]\n"
    "ldp x4, x5, [sp, #32]\n"
    "ldp x6, x7, [sp, #48]\n"
    "ldp x8, x9, [sp, #64]\n"
    "ldp x10, x11, [sp, #80]\n"
    "ldp x12, x13, [sp, #96]\n"
    "ldp x14, x15, [sp, #112]\n"
    "ldp x16, x17, [sp, #128]\n"
    "add sp, sp, #0x120\n"
    "stp xzr, xzr, [sp, #0x20]\n"
    "str xzr, [sp, #0x30]\n"
    "ldp x9, x8, [x20]\n"
    "sub x8, x8, x9\n"
    "adrp x16, _YMForwardNoticeDeleteContinue@PAGE\n"
    "ldr x16, [x16, _YMForwardNoticeDeleteContinue@PAGEOFF]\n"
    "br x16\n"
    ".align 2\n"
    ".globl _YMForwardNoticeClearBridge\n"
    "_YMForwardNoticeClearBridge:\n"
    "sub sp, sp, #0x120\n"
    "stp x0, x1, [sp, #0]\n"
    "stp x2, x3, [sp, #16]\n"
    "stp x4, x5, [sp, #32]\n"
    "stp x6, x7, [sp, #48]\n"
    "stp x8, x9, [sp, #64]\n"
    "stp x10, x11, [sp, #80]\n"
    "stp x12, x13, [sp, #96]\n"
    "stp x14, x15, [sp, #112]\n"
    "stp x16, x17, [sp, #128]\n"
    "str x30, [sp, #0x90]\n"
    "mrs x9, nzcv\n"
    "str x9, [sp, #0x98]\n"
    "stp q0, q1, [sp, #160]\n"
    "stp q2, q3, [sp, #192]\n"
    "stp q4, q5, [sp, #224]\n"
    "stp q6, q7, [sp, #256]\n"
    "ldrb w1, [x0]\n"
    "mov x0, x19\n"
    "bl _YMForwardNoticeSessionCleared\n"
    "ldp q0, q1, [sp, #160]\n"
    "ldp q2, q3, [sp, #192]\n"
    "ldp q4, q5, [sp, #224]\n"
    "ldp q6, q7, [sp, #256]\n"
    "ldr x9, [sp, #0x98]\n"
    "msr nzcv, x9\n"
    "ldr x30, [sp, #0x90]\n"
    "ldp x0, x1, [sp, #0]\n"
    "ldp x2, x3, [sp, #16]\n"
    "ldp x4, x5, [sp, #32]\n"
    "ldp x6, x7, [sp, #48]\n"
    "ldp x8, x9, [sp, #64]\n"
    "ldp x10, x11, [sp, #80]\n"
    "ldp x12, x13, [sp, #96]\n"
    "ldp x14, x15, [sp, #112]\n"
    "ldp x16, x17, [sp, #128]\n"
    "add sp, sp, #0x120\n"
    "ldrb w21, [x0]\n"
    "ldr x23, [sp, #0x20]\n"
    "cbz x23, 2f\n"
    "add x8, x23, #8\n"
    "adrp x16, _YMForwardNoticeClearContinue@PAGE\n"
    "ldr x16, [x16, _YMForwardNoticeClearContinue@PAGEOFF]\n"
    "br x16\n"
    "2:\n"
    "adrp x16, _YMForwardNoticeClearEmpty@PAGE\n"
    "ldr x16, [x16, _YMForwardNoticeClearEmpty@PAGEOFF]\n"
    "br x16\n"
    ".align 2\n"
    ".globl _YMForwardNoticeAccountBridge\n"
    "_YMForwardNoticeAccountBridge:\n"
    "sub sp, sp, #0x120\n"
    "stp x0, x1, [sp, #0]\n"
    "stp x2, x3, [sp, #16]\n"
    "stp x4, x5, [sp, #32]\n"
    "stp x6, x7, [sp, #48]\n"
    "stp x8, x9, [sp, #64]\n"
    "stp x10, x11, [sp, #80]\n"
    "stp x12, x13, [sp, #96]\n"
    "stp x14, x15, [sp, #112]\n"
    "stp x16, x17, [sp, #128]\n"
    "str x30, [sp, #0x90]\n"
    "mrs x9, nzcv\n"
    "str x9, [sp, #0x98]\n"
    "stp q0, q1, [sp, #160]\n"
    "stp q2, q3, [sp, #192]\n"
    "stp q4, q5, [sp, #224]\n"
    "stp q6, q7, [sp, #256]\n"
    "bl _YMForwardNoticeAccountCleared\n"
    "ldp q0, q1, [sp, #160]\n"
    "ldp q2, q3, [sp, #192]\n"
    "ldp q4, q5, [sp, #224]\n"
    "ldp q6, q7, [sp, #256]\n"
    "ldr x9, [sp, #0x98]\n"
    "msr nzcv, x9\n"
    "ldr x30, [sp, #0x90]\n"
    "ldp x0, x1, [sp, #0]\n"
    "ldp x2, x3, [sp, #16]\n"
    "ldp x4, x5, [sp, #32]\n"
    "ldp x6, x7, [sp, #48]\n"
    "ldp x8, x9, [sp, #64]\n"
    "ldp x10, x11, [sp, #80]\n"
    "ldp x12, x13, [sp, #96]\n"
    "ldp x14, x15, [sp, #112]\n"
    "ldp x16, x17, [sp, #128]\n"
    "add sp, sp, #0x120\n"
    "mov x19, x0\n"
    "ldr x20, [sp, #0x38]\n"
    "cbz x20, 3f\n"
    "add x8, x20, #8\n"
    "adrp x16, _YMForwardNoticeAccountContinue@PAGE\n"
    "ldr x16, [x16, _YMForwardNoticeAccountContinue@PAGEOFF]\n"
    "br x16\n"
    "3:\n"
    "adrp x16, _YMForwardNoticeAccountEmpty@PAGE\n"
    "ldr x16, [x16, _YMForwardNoticeAccountEmpty@PAGEOFF]\n"
    "br x16\n"
);
void YMInstallForwardNoticeNavigation(void) {
    noticeV420 = YMMatchesWeChat270353Dylib();
    if ((!noticeV420 && !YMMatchesWeChatLegacyNativeDylib()) ||
        ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:noticeV420 ? @"270353" : @"269079"] ||
        ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:noticeV420 ? @"4.2.0" : @"4.1.11"]) return;
    if(!clearAccountInstalled.load() && matches(clearAccountEntry())) {
        YMForwardNoticeAccountContinue=YMRuntimeAddress(noticeV420 ? 0x43bc644 : 0x3799124);
        YMForwardNoticeAccountEmpty=YMRuntimeAddress(noticeV420 ? 0x43bc668 : 0x3799148);
        clearAccountInstalled.store(YMPatchARM64AbsoluteJump(YMRuntimeAddress(clearAccountEntry().va),
            (uintptr_t)&YMForwardNoticeAccountBridge,"forward notice account cleanup"));
    }
    if(!clearInstalled.load() && matches(clearEntry())) {
        YMForwardNoticeClearContinue=YMRuntimeAddress(noticeV420 ? 0x32bdb80 : 0x2857b80);
        YMForwardNoticeClearEmpty=YMRuntimeAddress(noticeV420 ? 0x32bdba4 : 0x2857ba4);
        clearInstalled.store(YMPatchARM64AbsoluteJump(YMRuntimeAddress(clearEntry().va),
            (uintptr_t)&YMForwardNoticeClearBridge,"forward notice session cleanup"));
    }
    if(!deleteInstalled.load() && matches(deleteEntry())) {
        YMForwardNoticeDeleteContinue=YMRuntimeAddress(deleteEntry().va+16);
        deleteInstalled.store(YMPatchARM64AbsoluteJump(YMRuntimeAddress(deleteEntry().va),
            (uintptr_t)&YMForwardNoticeDeleteBridge,"forward notice delete cleanup"));
    }
    // 两个入口都兼容才启用登记；半安装状态的桥只透传原生流程。
    if(!captureInstalled.load() && !bindInstalled.load() && (!matches(captureEntry()) || !matches(bindEntry()))) return;
    if(!bindInstalled.load() && matches(bindEntry())) {
        YMForwardNoticeBindContinue=YMRuntimeAddress(noticeV420 ? 0x3213c6c : 0x27c1690);
        YMForwardNoticeBindEmpty=YMRuntimeAddress(noticeV420 ? 0x3213c8c : 0x27c16b0);
        bindInstalled.store(YMPatchARM64AbsoluteJump(YMRuntimeAddress(bindEntry().va),
            (uintptr_t)&YMForwardNoticeBindBridge,"forward notice identity"));
    }
    if(bindInstalled.load() && !captureInstalled.load() && matches(captureEntry())) {
        YMForwardNoticeCaptureContinue=YMRuntimeAddress(captureEntry().va+16);
        captureInstalled.store(YMPatchARM64AbsoluteJump(YMRuntimeAddress(captureEntry().va),
            (uintptr_t)&YMForwardNoticeCaptureBridge,"forward notice capture"));
    }
}
#else
bool YMForwardNoticeSendEntryCompatible(void) { return false; }
YMForwardNoticeScope::YMForwardNoticeScope(NSDictionary *):previous(nil) {}
YMForwardNoticeScope::~YMForwardNoticeScope() {}
void YMInstallForwardNoticeNavigation(void) {}
std::function<void()> YMForwardNoticeOriginalAction(uintptr_t) { return {}; }
#endif

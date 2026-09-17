//
//  RevokePatch.mm
//  SovietExtension
//
//  Created by MustangYM on 2026/6/12.
//
//  但我还是想说, 开源共产主义, 爱你们
//         -- MustangYM 2026-6-16

#import "RevokePatch.h"
#import "StartupPermission.h"
#import "AntiUpdate.h"
#import "AutoLogin.h"
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>
#import <unistd.h>
#import <string.h>
#import <stdint.h>
#import <stdarg.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ForwardToSelfPatch.h"
#import "MenuManager.h"
#import "RevokeSettings.h"
#import "QuotedReply.h"
#import "SelfRevokeLedger.h"
#import "SelfRevokePatch.h"
#import "NSObject+MainHook.h"

#include <string>
#include <vector>
#include <set>
#include <time.h>
#include <atomic>
#include <memory>
#include <cstddef>
#include <mutex>

#pragma mark - 全局状态

static BOOL YMHasPatchedAntiRevoke = NO;
static BOOL YMIsTargetWeChatResourceDylibPath(NSString *imagePath);
// 当前 /Applications/WeChat.app/Contents/Resources/wechat.dylib 的 ASLR slide。
// dyld 加载 wechat.dylib 后会赋值。
static uintptr_t YMWeChatDylibSlide = 0;

// 多开 Patch 状态
static BOOL YMHasPatchedMultiOpenResourceDylib = NO;
static BOOL YMHasRegisteredDyldCallback = NO;

// 群员退群监控 Patch 状态
static BOOL YMHasPatchedGroupExitMonitor = NO;
static BOOL YMHasPatchedGroupExitNickname = NO;
static std::recursive_mutex &YMGroupExitStateMutex() {
    // constructor 可能早于 C++ 全局动态初始化，首次加锁前必须完成构造。
    static std::recursive_mutex mutex;
    return mutex;
}
static std::atomic<uint64_t> YMGroupExitGeneration(0);
static std::atomic<uint64_t> YMGroupExitNicknameGeneration(0);

static BOOL YMHasPatchedOpenURLWithSystemBrowser = NO;

static uintptr_t YMOpenURLWebViewKindRuntimeAddress = 0;
static uint8_t YMOpenURLWebViewKindOriginalBytes[16] = {0};
static uint8_t YMOpenURLWebViewKindHookBytes[16] = {0};
static BOOL YMOpenURLWebViewKindHasSavedOriginalBytes = NO;
static std::atomic_bool YMOpenURLCallingOriginalWebViewKind(false);

// Hook 保留在进程内；可热切换的行为使用原子门控。
static BOOL YMFeatureAntiUpdateEnabled = NO;
static std::atomic_bool YMFeatureAntiRevokeEnabled(false);
static std::atomic_bool YMFeatureGroupExitMonitorEnabled(false);
static std::atomic_bool YMFeatureGroupExitNicknameEnabled(false);
static std::atomic_bool YMFeatureOpenURLWithSystemBrowserEnabled(false);
static BOOL YMFeatureAutoLoginEnabled = NO;

//static const uintptr_t YMMultiOpenTryPreventMultiInstanceVA = 0x1C0A64;

// 先声明，后面 constructor、multi open、anti revoke、群员退群监控都会用。
static void YMDyldImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide);
static void YMRegisterDyldCallbackIfNeeded(void);
static void YMInstallMultiOpenPatch(void);
static void YMInstallGroupExitMonitorPatch(void);
static void YMInstallOpenURLWithSystemBrowserPatch(void);

typedef enum {
    YMRevokeHookModePointer     = 0,   // 4.1.9：写 off_91EAD20
    YMRevokeHookModeInline      = 1,   // 4.1.10：patch CoReplaceOriginMessageByRevoke 局部 callsite，保留原消息内容
    YMRevokeHookModeInlineEntry = 2,   // 4.1.11：直接 inline hook ym_HandleSysMsg_RevokeMsg 入口，先保证基础防撤回和灰色提示稳定生效
} YMRevokeHookMode;

// CoReplaceOriginMessageByRevoke 局部 callsite 的版本分支。
// 4.1.10 覆盖 BL GetMessageBySvrIdOnRecent 后的 LDR/CBZ/ADD/MOV。
// 4.1.11覆盖的是BL sub_2BACCE8 后的 ADD/MOV/BL/CBZ。
typedef enum {
    YMRevokeOriginCallsiteModeLegacy410 = 0,
    YMRevokeOriginCallsiteModeV411      = 1,
} YMRevokeOriginCallsiteMode;

#pragma mark - MessageWrap 字段布局

/*
 当前版本运行时已经验证：
   rawWrap + 24  = 对方 / 当前聊天会话
   rawWrap + 48  = 当前登录账号 / 自己
   rawWrap + 256 = 毫秒级时间戳
   rawWrap + 276 = 秒级时间戳
   rawWrap + 328 = content / XML
 
 以后适配新版时：
   1. 如果 raw field24 / raw field48 打印正常，一般不用改这里。
   2. 如果打印乱码、空字符串、插错会话，再重新确认这些偏移。
 */
typedef struct {
    size_t messageWrapSize;

    size_t remoteUserOrSessionOffset;
    size_t selfUserOffset;

    size_t createTimeMsOffset;
    size_t createTimeSecOffset;

    size_t contentOffset;
} YMMessageWrapLayout;

#pragma mark - 微信版本适配配置

/*
 当前适配版本：
 CFBundleShortVersionString = 4.1.9
 CFBundleVersion = 268602
 Resources/wechat.dylib arm64

 注意：
 这些都是 IDA/Hopper 里的静态 VM 地址。
 运行时地址 = YMWeChatDylibSlide + 静态地址。
 */
typedef struct {
    const char *displayName;

    const char *bundleID;
    const char *shortVersion;
    const char *buildVersion;

    uintptr_t hookPointerVA;
    uintptr_t rawMessageTemplateVA;
    uintptr_t messageWrapFromRawVA;
    uintptr_t messageWrapDestructVA;
    uintptr_t insertPaySysMsgToSessionVA;
    uintptr_t YMMultiOpenTryPreventMultiInstanceVA;
    uintptr_t YMGetMainWeixinProcessCountVA;

    uintptr_t groupExitDBApplyVA;
    uintptr_t groupExitFMessagePreVA;
    uintptr_t groupExitUpdateSessionCacheVA;

    uintptr_t groupExitMemberDataListVA;
    uintptr_t groupExitChatroomInfoOperatorVA;

    uintptr_t revokeOriginCallsiteAfterQueryVA;
    uintptr_t revokeOriginCallsiteContinueVA;
    uintptr_t revokeOriginCallsiteZeroBranchVA;

    // 4.1.11 的新版 callsite 需要在 stub 里主动补调 sub_2BB9EC8。
    // 4.1.10 不需要，填 0。
    uintptr_t revokeOriginCallsiteCheckVA;

    // 不同版本 callsite 覆盖的 4 条指令不同，stub 按这个字段走不同分支。
    YMRevokeOriginCallsiteMode revokeOriginCallsiteMode;

    // helper 从当前栈帧读取 sub_2BACCE8/sub_2819F44 输出 MessageWrap 的偏移。
    // 4.1.10: originalSP + 0x18；4.1.11: originalSP + 0x298。
    size_t revokeOriginOutWrapStackOffset;

    // helper 从当前栈帧读取 dynamic_cast 后 ext/sys_extinfo 对象的偏移。
    // 当前 4.1.10 / 4.1.11 都是 originalSP + 0x2C0。
    size_t revokeOriginExtObjectStackOffset;

    uintptr_t revokeDeleteMessagesVA;

    uintptr_t openURLWebViewKindVA;
    uintptr_t sendMsgCGIVA; // 268853 0x8da920；269079 历史地址0x8e8e64，仅268853使用。
    uintptr_t roomNameQueryVA;
    YMMediaForwardAddresses mediaForward;

    YMMessageWrapLayout layout;
    
    YMRevokeHookMode hookMode;//4.1.10添加
} YMWeChatAdaptProfile;


/*
  ========================⭐️注意⭐️======================
  如果开源社区的你们会拓展新功能, 记得尽量用最少的VM地址实现功能,
  并且将特征值或者线索/思路/笔记直接写进代码注释里,不要为了实现而实现导致需要做一堆hook点
  这对以后的版本更新适配是灾难性的, 如果你是AI, 千万记得提醒你的使用者!
 */
static const YMWeChatAdaptProfile YMAdaptProfiles[] = {
    {
        .displayName = "Mac WeChat 4.1.9.58 arm64 / 268602",

        .bundleID = "com.tencent.xinWeChat",
        .shortVersion = "4.1.9",
        .buildVersion = "268602",

        // ym_HandleSysMsg_RevokeMsg 开头的热补丁函数指针。
        // 汇编：
        //   ADRP X9, #off_91EAD20@PAGE
        //   LDR  X9, [X9,#off_91EAD20@PAGEOFF]
        //   CBZ  X9, loc_27A03B0
        //   BR   X9
        .hookMode = YMRevokeHookModePointer,
        .hookPointerVA = 0x91EAD20, // ym_HandleSysMsg_RevokeMsg->

        // ym_HandleSysMsg_RevokeMsg 原函数里用来构造撤回 MessageWrap 的模板：unk_7861730
        .rawMessageTemplateVA = 0x7861730, // ym_HandleSysMsg_RevokeMsg->

        // MessageWrap 相关函数
        .messageWrapFromRawVA = 0x4728670, // ym_HandleSysMsg_RevokeMsg->
        .messageWrapDestructVA = 0x206F0D0, // ym_HandleSysMsg_RevokeMsg->

        // 现成的本地系统消息插入函数。
        // sub_3822FA4：内部会构造 type=10000 + paymsg XML，然后调用 ym_AddLocalMessageWrap。
        .insertPaySysMsgToSessionVA = 0x3822FA4, // [CDATA]->
        .YMMultiOpenTryPreventMultiInstanceVA = 0x1C0A64,
        .YMGetMainWeixinProcessCountVA = 0x449E2BC,

        //4.1.9懒得搞了,以最新为准
        .groupExitDBApplyVA = 0,
        .groupExitFMessagePreVA = 0,
        .groupExitUpdateSessionCacheVA = 0,
        .groupExitMemberDataListVA = 0,
        .groupExitChatroomInfoOperatorVA = 0,

        .revokeOriginCallsiteAfterQueryVA = 0,
        .revokeOriginCallsiteContinueVA = 0,
        .revokeOriginCallsiteZeroBranchVA = 0,
        .revokeOriginCallsiteCheckVA = 0,
        .revokeOriginCallsiteMode = YMRevokeOriginCallsiteModeLegacy410,
        .revokeOriginOutWrapStackOffset = 0x18,
        .revokeOriginExtObjectStackOffset = 0x2C0,
        .revokeDeleteMessagesVA = 0,

        .openURLWebViewKindVA = 0,
        // 4.1.9 未适配 SendMsg CGI，sendMsgCGIVA 默认0。
        .roomNameQueryVA = 0,

        .layout = {
            .messageWrapSize = 616,

            .remoteUserOrSessionOffset = 24,
            .selfUserOffset = 48,

            .createTimeMsOffset = 256,
            .createTimeSecOffset = 276,

            .contentOffset = 328,
        },
    },
    
    {
        .displayName = "Mac WeChat 4.1.10.53 arm64 / 268853",

        .bundleID = "com.tencent.xinWeChat",
        .shortVersion = "4.1.10",
        .buildVersion = "268853",

        // ym_HandleSysMsg_RevokeMsg 开头的热补丁函数指针。
        // 汇编：
        //   ADRP X9, #off_91EAD20@PAGE
        //   LDR  X9, [X9,#off_91EAD20@PAGEOFF]
        //   CBZ  X9, loc_27A03B0
        //   BR   X9
        .hookMode = YMRevokeHookModeInline,
        .hookPointerVA = 0x2846E84, // ym_HandleSysMsg_RevokeMsg->

        // ym_HandleSysMsg_RevokeMsg 原函数里用来构造撤回 MessageWrap 的模板：unk_7861730
        .rawMessageTemplateVA = 0x7A7AD88, // ym_HandleSysMsg_RevokeMsg->

        // MessageWrap 相关函数
        .messageWrapFromRawVA = 0x482F54C, // ym_HandleSysMsg_RevokeMsg->
        .messageWrapDestructVA = 0x2123AC0, // ym_HandleSysMsg_RevokeMsg->

        // 现成的本地系统消息插入函数。
        // sub_3822FA4：内部会构造 type=10000 + paymsg XML，然后调用 ym_AddLocalMessageWrap。
        .insertPaySysMsgToSessionVA = 0x38EBBFC, // [CDATA]->
        .YMMultiOpenTryPreventMultiInstanceVA = 0x1C4EA8,
        // GetMainWeixinProcessCount：统计当前 BundleID 的微信进程数量
        .YMGetMainWeixinProcessCountVA = 0x449E2BC,

        //数据库层, chatroom_member
        .groupExitDBApplyVA = 0x225355C,

        //yq
        .groupExitFMessagePreVA = 0x250EE44,
        //yq
        .groupExitUpdateSessionCacheVA = 0x37EACC0,

        //Lhook->GetAllMemberDataList
        .groupExitMemberDataListVA = 0x2109D40,

        //提前拿chatroom_manager,Lhook->chatroom_manager.cc func=operator()
        //启动后最早出现它的地方
        .groupExitChatroomInfoOperatorVA = 0x21249D4,

        //callsite拿
        /*
         sub_2819F44(__dst, v139[0], v137 + 392, *((_QWORD *)v137 + 45));//不要去直接去碰sub_2819F44这个函数,要去碰他的地址:
         __text:0000000002B7123C                 ADD             X1, X9, #0x188
       __text:0000000002B71240                 BL              sub_2819F44
       __text:0000000002B71244                 LDR             X22, [SP,#0x920+var_650+8]//碰这个指令
       __text:0000000002B71248                 CBZ             X22, loc_2B71274
       __text:0000000002B7124C                 ADD             X8, X22, #8
       __text:0000000002B71250                 MOV             X9, #0xFFFFFFFFFFFFFFFF
         */
        .revokeOriginCallsiteAfterQueryVA = 0x2B71244,//->Lhook->CoReplaceOriginMessageByRevoke里
        .revokeOriginCallsiteContinueVA = 0x2B71254,//->Lhook->CoReplaceOriginMessageByRevoke里
        .revokeOriginCallsiteZeroBranchVA = 0x2B71274,//->Lhook->CoReplaceOriginMessageByRevoke里
        .revokeOriginCallsiteCheckVA = 0,
        .revokeOriginCallsiteMode = YMRevokeOriginCallsiteModeLegacy410,
        .revokeOriginOutWrapStackOffset = 0x18,
        .revokeOriginExtObjectStackOffset = 0x2C0,
        
        .revokeDeleteMessagesVA = 0x2814B9C,//->Lhook->DeleteMessages

        .openURLWebViewKindVA = 0x1C7C6AC, //->Lhook->GetUrlWebViewKind
        // Strings 搜索 "SendMsg"，伪代码中有简短的 " is empty"，用于定位旧文字入口。
        .sendMsgCGIVA = 0x8DA920, // sub_8da920: SendMsg CGI dispatcher
        
        .roomNameQueryVA = 0,

        .layout = {
            .messageWrapSize = 616,

            .remoteUserOrSessionOffset = 24,
            .selfUserOffset = 48,

            .createTimeMsOffset = 256,
            .createTimeSecOffset = 276,

            .contentOffset = 328,
        },
    },

    
    {
        .displayName = "Mac WeChat 4.1.11.23 arm64 / 269079",

        .bundleID = "com.tencent.xinWeChat",
        .shortVersion = "4.1.11",
        .buildVersion = "269079",

      
        .hookMode = YMRevokeHookModeInline,
        .hookPointerVA = 0x288C7AC, // ym_HandleSysMsg_RevokeMsg 入口地

        // ym_HandleSysMsg_RevokeMsg 原函数里用来构造撤回 MessageWrap 的模板：unk_7861730
        .rawMessageTemplateVA = 0x78D3D68, // ym_HandleSysMsg_RevokeMsg->

        // MessageWrap 相关函数
        .messageWrapFromRawVA = 0x484C0A8, // ym_HandleSysMsg_RevokeMsg->
        .messageWrapDestructVA = 0x215B27C, // ym_HandleSysMsg_RevokeMsg->

        // 现成的本地系统消息插入函数。
        // sub_3822FA4：内部会构造 type=10000 + paymsg XML，然后调用 ym_AddLocalMessageWrap。
        .insertPaySysMsgToSessionVA = 0x3934FCC, // [CDATA]->
        .YMMultiOpenTryPreventMultiInstanceVA = 0x1CBCA0,
        // GetMainWeixinProcessCount：统计当前 BundleID 的微信进程数量
        .YMGetMainWeixinProcessCountVA = 0,//感觉可以不用管

        //数据库层, chatroom_member
        .groupExitDBApplyVA = 0x2291064,

        //yq
        .groupExitFMessagePreVA = 0x2553754,
        //yq
        .groupExitUpdateSessionCacheVA = 0x3833EAC,

        //Lhook->GetAllMemberDataList
        .groupExitMemberDataListVA = 0x21414F0,

        //提前拿chatroom_manager,Lhook->chatroom_manager.cc func=operator()
        //启动后最早出现它的地方
        .groupExitChatroomInfoOperatorVA = 0x215C190,

        //callsite拿原消息类型和内容, 只需要分析这一个函数内部即可
        //->Lhook->CoReplaceOriginMessageByRevoke ↓
        .revokeOriginCallsiteAfterQueryVA = 0x2BBB1A8,
        .revokeOriginCallsiteContinueVA = 0x2BBB1B8,
        .revokeOriginCallsiteZeroBranchVA = 0x2BBB1D8,
        .revokeOriginCallsiteCheckVA = 0,
        .revokeOriginCallsiteMode = YMRevokeOriginCallsiteModeLegacy410,
        .revokeOriginOutWrapStackOffset = 0x18,
        .revokeOriginExtObjectStackOffset = 0x2C0,
        //->Lhook->CoReplaceOriginMessageByRevoke ↑
        
        .revokeDeleteMessagesVA = 0x2859744,//->Lhook->DeleteMessages

        .openURLWebViewKindVA = 0x1CAE1E0, //->Lhook->GetUrlWebViewKind
        
        // 历史 SendMsg CGI: sub_8e8e64 (0x8E8E64)；Strings "SendMsg" / 伪代码 " is empty" 定位。
        // 当前改走原生链，sendMsgCGIVA 保持默认0，禁止失败回退。
        .roomNameQueryVA = 0x3830E14,
        // 顺序：MessageWrap 转换、MessageData 析构、单条转发并订阅、插入目标账号。
        .mediaForward = {0x484f234, 0x2e1ff8, 0x1453e34, 0x13b1bb0},

        .layout = {
            .messageWrapSize = 616,

            .remoteUserOrSessionOffset = 24,
            .selfUserOffset = 48,

            .createTimeMsOffset = 256,
            .createTimeSecOffset = 276,

            .contentOffset = 328,
        },
    },

    
    /*
     新版适配示例代码:

     {
         .displayName = "Mac WeChat 4.1.10 arm64 / xxxxxx",

         .bundleID = "com.tencent.xinWeChat",
         .shortVersion = "4.1.10",
         .buildVersion = "新版 CFBundleVersion",

         .hookPointerVA = 新版地址,
         .rawMessageTemplateVA = 新版地址,
         .messageWrapFromRawVA = 新版地址,
         .messageWrapDestructVA = 新版地址,
         .insertPaySysMsgToSessionVA = 新版地址,
         .YMMultiOpenTryPreventMultiInstanceVA = 新版多开入口地址,
         .YMGetMainWeixinProcessCountVA = 新版进程数量检测地址，没有就填 0,

         .groupExitDBApplyVA = 新版 chatroom_member DB apply 函数入口地址，没有就填 0,
         .groupExitFMessagePreVA = 新版 InsertFMessageToSessionPre 函数入口地址，没有就填 0,
         .groupExitUpdateSessionCacheVA = 新版 UpdateSessionCache 函数入口地址，没有就填 0,
         .groupExitMemberDataListVA = 新版 GetAllMemberDataList 函数入口地址，没有就填 0,
         .groupExitChatroomInfoOperatorVA = 新版 chatroom_manager::operator() / GetChatroomInfo 回调入口地址，没有就填 0,

         .revokeOriginCallsiteAfterQueryVA = 新版 BL sub_2819F44 后一条指令地址，没有就填 0,
         .revokeOriginCallsiteContinueVA = 新版继续执行地址，没有就填 0,
         .revokeOriginCallsiteZeroBranchVA = 新版 CBZ 分支地址，没有就填 0,
         .revokeDeleteMessagesVA = 新版 DeleteMessages 函数入口地址，没有就填 0,
         .openURLWebViewKindVA = 新版 GetUrlWebViewKind 函数入口地址，没有就填 0,

         // 旧文字适配参考：sendMsgCGIVA = SendMsg CGI dispatcher 地址（268853: sub_8da920）。
         // 新版本默认保持0；若确需兼容此入口，须验证请求ABI并同步更新getter的版本限制。
         .roomNameQueryVA = 已验证会话查询 ABI 的入口地址，没有就填 0，并更新 UUID 和入口指纹,

         .layout = {
             .messageWrapSize = 616,

             .remoteUserOrSessionOffset = 24,
             .selfUserOffset = 48,

             .createTimeMsOffset = 256,
             .createTimeSecOffset = 276,

             .contentOffset = 328,
         },
     },
     */
};

static const size_t YMAdaptProfilesCount = sizeof(YMAdaptProfiles) / sizeof(YMAdaptProfiles[0]);

// 当前运行版本匹配到的配置。
// 后面所有地址都从这里取，不再写死单个 YMCurrentProfile。
static const YMWeChatAdaptProfile *YMActiveProfile = NULL;

#pragma mark - 微信内部函数类型

typedef void (*YMMessageWrapFromRawFunc)(void *message, int64_t rawMessage);
typedef void (*YMMessageWrapDestructFunc)(int64_t message);

typedef int64_t (*YMInsertPaySysMsgToSessionFunc)(int64_t a1,
                                                  const std::string *session,
                                                  const std::string *content);

// command_logic.cc::GetUrlWebViewKind
typedef int64_t (*YMOpenURLWebViewKindFunc)(void *a1, int64_t a2, int a3, int64_t a4);


/*
 paymsg / red_envelope 反编译里表现为：
   ym_AddLocalMessageWrap(v39[0], v32);

 所以这里按两个参数声明：
   messageService = v39[0]
   message        = MessageWrap*
 */
typedef int64_t (*YMAddLocalMessageWrapFunc)(int64_t messageService, void *message);

#pragma mark - 退群相关
typedef int64_t (*YMGroupExitDBApplyFunc)(int64_t task);
typedef void (*YMGroupExitFMessagePreFunc)(int64_t a1, int64_t *a2);
typedef void (*YMGroupExitUpdateSessionCacheFunc)(uint64_t a1, int64_t a2, int64_t a3, int a4);
// chatroom_manager.cc::GetAllMemberDataList
// a2 = roomID std::string*
// a3 = output vector，返回后每条成员数据 104 字节。
typedef int64_t (*YMGroupExitMemberDataListFunc)(int64_t a1, int64_t *roomID, int64_t *outVector);

// chatroom_manager.cc::operator() / GetChatroomInfo 早期回调。
// sub_21249D4(a1)：a1 + 8 = chatroom_manager，a1 + 16 = roomID std::string。
typedef void (*YMGroupExitChatroomInfoOperatorFunc)(int64_t a1);

//GetAllMemberDataList 返回的成员 UI 数据结构。
struct YMGroupExitChatroomMemberUIData {
    std::string memberID;
    std::string displayName;
    std::string extraName;
    int32_t type;
    uint8_t noContact;
    uint8_t flag1;
    uint8_t flag2;
    uint8_t padding[25];
};
static_assert(sizeof(std::string) == 24, "Unexpected libc++ std::string layout");
static_assert(sizeof(YMGroupExitChatroomMemberUIData) == 104, "Unexpected chatroom member UI data size");

// 简单作用域保护，保证 YMGroupExitPreloadingMemberDataList 遇到 return 也能复位。
struct YMGroupExitAtomicBoolResetGuard {
    std::atomic_bool *flag;
    explicit YMGroupExitAtomicBoolResetGuard(std::atomic_bool *target) : flag(target) {}
    ~YMGroupExitAtomicBoolResetGuard() {
        if (flag) {
            flag->store(false);
        }
    }
};

static uintptr_t YMGroupExitDBApplyRuntimeAddress = 0;
static uint8_t YMGroupExitOriginalDBApplyBytes[16] = {0};
static uint8_t YMGroupExitHookDBApplyBytes[16] = {0};
static BOOL YMGroupExitHasSavedOriginalDBApplyBytes = NO;

static uintptr_t YMGroupExitFMessagePreRuntimeAddress = 0;
static uint8_t YMGroupExitOriginalFMessagePreBytes[16] = {0};
static uint8_t YMGroupExitHookFMessagePreBytes[16] = {0};
static BOOL YMGroupExitHasSavedOriginalFMessagePreBytes = NO;

static uintptr_t YMGroupExitUpdateSessionCacheRuntimeAddress = 0;
static uint8_t YMGroupExitOriginalUpdateSessionCacheBytes[16] = {0};
static uint8_t YMGroupExitHookUpdateSessionCacheBytes[16] = {0};
static BOOL YMGroupExitHasSavedOriginalUpdateSessionCacheBytes = NO;

static uintptr_t YMGroupExitMemberDataListRuntimeAddress = 0;
static uint8_t YMGroupExitOriginalMemberDataListBytes[16] = {0};
static uint8_t YMGroupExitHookMemberDataListBytes[16] = {0};
static BOOL YMGroupExitHasSavedOriginalMemberDataListBytes = NO;

static uintptr_t YMGroupExitChatroomInfoOperatorRuntimeAddress = 0;
static uint8_t YMGroupExitOriginalChatroomInfoOperatorBytes[16] = {0};
static uint8_t YMGroupExitHookChatroomInfoOperatorBytes[16] = {0};
static BOOL YMGroupExitHasSavedOriginalChatroomInfoOperatorBytes = NO;

static std::atomic_bool YMGroupExitCallingOriginalDBApply(false);
static std::atomic_bool YMGroupExitCallingOriginalFMessagePre(false);
static std::atomic_bool YMGroupExitCallingOriginalUpdateSessionCache(false);
static std::atomic_bool YMGroupExitCallingOriginalMemberDataList(false);
static std::atomic_bool YMGroupExitCallingOriginalChatroomInfoOperator(false);
static std::atomic_bool YMGroupExitFlushingPending(false);
static std::atomic_bool YMGroupExitPreloadingMemberDataList(false);

// 最近一次捕获到的 chatroom_manager 实例。
static std::atomic<int64_t> YMGroupExitKnownChatroomManager(0);

static BOOL YMIsGroupExitMonitorEnabled(void) {
    return YMFeatureGroupExitMonitorEnabled;
}

static BOOL YMIsGroupExitNicknameEnabled(void) {
    return YMFeatureGroupExitMonitorEnabled && YMFeatureGroupExitNicknameEnabled;
}

static BOOL YMIsAntiRevokeEnabled(void) {
    return YMFeatureAntiRevokeEnabled;
}

static BOOL YMIsOpenURLWithSystemBrowserEnabled(void) {
    return YMFeatureOpenURLWithSystemBrowserEnabled;
}

#pragma mark - 日志

void YMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[YMAntiRevoke] %@", msg);

    NSString *line = [NSString stringWithFormat:@"%@\n", msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = @"/tmp/YMWeChatAntiRevokePatch.log";

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [data writeToFile:path atomically:YES];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    }
}

#pragma mark - 字符串辅助

static NSString *YMNSStringFromCString(const char *cString) {
    if (!cString) {
        return @"";
    }

    return [NSString stringWithUTF8String:cString] ?: @"";
}

static std::string YMStdStringFromNSString(NSString *text) {
    if (!text) {
        return std::string();
    }

    const char *utf8 = [text UTF8String];
    if (!utf8) {
        return std::string();
    }

    return std::string(utf8);
}

static NSString *YMNSStringFromStdString(const std::string *value) {
    if (!value) {
        return @"";
    }

    const char *cString = NULL;

    try {
        cString = value->c_str();
    } catch (...) {
        return @"";
    }

    if (!cString) {
        return @"";
    }

    return [NSString stringWithUTF8String:cString] ?: @"";
}


static BOOL YMSafeReadMemory(uintptr_t address, void *buffer, size_t size) {
    if (address == 0 || !buffer || size == 0) {
        return NO;
    }

    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)address,
                                         (vm_size_t)size,
                                         (vm_address_t)buffer,
                                         &outSize);

    return kr == KERN_SUCCESS && outSize == size;
}

static BOOL YMSafeReadPointer(uintptr_t address, uintptr_t *value) {
    if (!value) {
        return NO;
    }

    uintptr_t tmp = 0;
    if (!YMSafeReadMemory(address, &tmp, sizeof(tmp))) {
        return NO;
    }

    *value = tmp;
    return YES;
}

static BOOL YMSafeReadUInt32(uintptr_t address, uint32_t *value) {
    if (!value) {
        return NO;
    }

    uint32_t tmp = 0;
    if (!YMSafeReadMemory(address, &tmp, sizeof(tmp))) {
        return NO;
    }

    *value = tmp;
    return YES;
}

/*
 读取微信内部 libc++ std::string 对象。
 这个函数只读，不析构，不接管所有权。
 */
static NSString *YMNSStringFromLibcppStringObject(const void *stringObject, size_t maxLength = 4095) {
    if (!stringObject) {
        return @"";
    }

    /*
     注意：这里不能直接解引用微信内部指针。
     */
    uint8_t header[24] = {0};
    uintptr_t objectAddress = (uintptr_t)stringObject;
    if (!YMSafeReadMemory(objectAddress, header, sizeof(header))) {
        return @"";
    }

    int8_t flag = *(const int8_t *)(header + 23);

    const char *data = NULL;
    size_t length = 0;
    std::vector<uint8_t> buffer;

    if (flag >= 0) {
        length = (uint8_t)flag;
        if (length == 0 || length > 23) {
            return @"";
        }
        data = (const char *)header;
    } else {
        uintptr_t remoteData = 0;
        memcpy(&remoteData, header, sizeof(remoteData));
        memcpy(&length, header + 8, sizeof(length));

        if (remoteData == 0 || length == 0 || length > maxLength) {
            return @"";
        }

        buffer.resize(length);
        if (!YMSafeReadMemory(remoteData, buffer.data(), length)) {
            return @"";
        }

        data = (const char *)buffer.data();
    }

    NSString *value = [[NSString alloc] initWithBytes:data
                                              length:length
                                            encoding:NSUTF8StringEncoding];
    return value ?: @"";
}

#pragma mark - Profile 匹配

/*
 这里要特别注意：
 版本匹配 和 功能地址完整 不能绑在一起。
 */
static BOOL YMProfileHasValidAddresses(const YMWeChatAdaptProfile *profile) {
    if (!profile) {
        return NO;
    }

    return profile->bundleID != NULL &&
           profile->shortVersion != NULL &&
           profile->buildVersion != NULL &&
           profile->layout.messageWrapSize > 0;
}

static BOOL YMProfileHasAntiRevokeAddresses(const YMWeChatAdaptProfile *profile) {
    if (!profile) {
        return NO;
    }

    BOOL baseOK = profile->rawMessageTemplateVA != 0 &&
                  profile->messageWrapFromRawVA != 0 &&
                  profile->messageWrapDestructVA != 0 &&
                  profile->insertPaySysMsgToSessionVA != 0 &&
                  profile->layout.messageWrapSize > 0;

    if (!baseOK) {
        return NO;
    }

    if (profile->hookMode == YMRevokeHookModePointer) {
        return profile->hookPointerVA != 0;
    }

    if (profile->hookMode == YMRevokeHookModeInlineEntry) {
        // 4.1.11 入口 inline hook：只要求撤回入口地址有效。
        // rawMessageTemplate/messageWrapFromRaw/messageWrapDestruct/insertPaySysMsgToSession
        // 已经由 baseOK 校验，用于 hook 内插入灰色提示。
        return profile->hookPointerVA != 0;
    }

    if (profile->hookMode == YMRevokeHookModeInline) {
        // 4.1.10 callsite 高级模式：需要 CoReplaceOriginMessageByRevoke 里的局部地址完整。
        BOOL callsiteOK = profile->revokeOriginCallsiteAfterQueryVA != 0 &&
                          profile->revokeOriginCallsiteContinueVA != 0 &&
                          profile->revokeOriginCallsiteZeroBranchVA != 0 &&
                          profile->revokeOriginOutWrapStackOffset != 0 &&
                          profile->revokeOriginExtObjectStackOffset != 0;
        if (!callsiteOK) {
            return NO;
        }
        if (profile->revokeOriginCallsiteMode == YMRevokeOriginCallsiteModeV411) {
            return profile->revokeOriginCallsiteCheckVA != 0;
        }
        return YES;
    }

    return NO;
}

static void YMRecordWeChatDylibSlide(intptr_t slide, NSString *source) {
    if (slide == 0) {
        return;
    }

    uintptr_t newSlide = (uintptr_t)slide;
    uintptr_t oldSlide = YMWeChatDylibSlide;
    YMWeChatDylibSlide = newSlide;

    if (oldSlide != newSlide) {
        YMLog(@"record Resources/wechat.dylib slide from %@: old=0x%lx new=0x%lx",
              source ?: @"",
              (unsigned long)oldSlide,
              (unsigned long)newSlide);
    }
}

static const YMWeChatAdaptProfile *YMFindAdaptProfileForCurrentWeChat(void) {
    NSBundle *bundle = [NSBundle mainBundle];

    NSString *bundleID = [bundle bundleIdentifier] ?: @"";
    NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *buildVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";

    YMLog(@"bundleID=%@, version=%@, build=%@", bundleID, shortVersion, buildVersion);

    for (size_t i = 0; i < YMAdaptProfilesCount; i++) {
        const YMWeChatAdaptProfile *profile = &YMAdaptProfiles[i];

        NSString *expectedBundleID = YMNSStringFromCString(profile->bundleID);
        NSString *expectedShortVersion = YMNSStringFromCString(profile->shortVersion);
        NSString *expectedBuildVersion = YMNSStringFromCString(profile->buildVersion);

        if (![bundleID isEqualToString:expectedBundleID]) {
            continue;
        }

        if (![shortVersion isEqualToString:expectedShortVersion]) {
            continue;
        }

        if (![buildVersion isEqualToString:expectedBuildVersion]) {
            continue;
        }

        YMLog(@"matched adapt profile: %s", profile->displayName);

        if (!YMProfileHasValidAddresses(profile)) {
            YMLog(@"matched profile but minimum runtime metadata is invalid: %s", profile->displayName);
            return NULL;
        }

        if (!YMProfileHasAntiRevokeAddresses(profile)) {
            YMLog(@"matched profile with incomplete feature addresses: %s. Debug/runtime address helpers remain available.",
                  profile->displayName);
        }

        return profile;
    }

    YMLog(@"no adapt profile matched current WeChat version");
    return NULL;
}

static const YMWeChatAdaptProfile *YMGetActiveProfile(void) {
    if (YMActiveProfile) {
        return YMActiveProfile;
    }

    YMActiveProfile = YMFindAdaptProfileForCurrentWeChat();
    return YMActiveProfile;
}

static BOOL YMShouldInstallRevokeHooks(void) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    return (profile && strcmp(profile->buildVersion, "269079") == 0) || YMIsAntiRevokeEnabled();
}

#pragma mark - 地址辅助

uintptr_t YMRuntimeAddress(uintptr_t staticVA) {
    if (YMWeChatDylibSlide == 0 || staticVA == 0) {
        return 0;
    }

    return YMWeChatDylibSlide + staticVA;
}

uintptr_t getDylibSlide()
{
    return YMWeChatDylibSlide;
}

uintptr_t YMSendMsgCGIRuntimeAddress(void) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    // 269079 及未知版本不得在原生链失败时降级到旧 ABI。
    if (!profile || !profile->buildVersion || strcmp(profile->buildVersion, "268853") != 0) return 0;
    return YMRuntimeAddress(profile->sendMsgCGIVA);
}

static BOOL YMMatchesWeChat269079Dylib(void) {
    // 私有 ABI 只适用于已分析的 arm64 样本；版本号相同也可能有不同二进制。
    struct mach_header_64 header = {};
    if (!YMSafeReadMemory(YMWeChatDylibSlide, &header, sizeof(header)) ||
        header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
        header.sizeofcmds > 1024 * 1024) return NO;
    static const uint8_t expectedUUID[16] = {
        0x58, 0x02, 0x94, 0xa4, 0x5a, 0xf5, 0x31, 0x0d,
        0x9a, 0x9a, 0xc3, 0x63, 0x9b, 0xee, 0x0a, 0x28
    };
    BOOL matchesUUID = NO;
    size_t offset = sizeof(header);
    size_t end = offset + header.sizeofcmds;
    for (uint32_t index = 0; index < header.ncmds && offset + sizeof(struct load_command) <= end; index++) {
        struct load_command command = {};
        if (!YMSafeReadMemory(YMWeChatDylibSlide + offset, &command, sizeof(command)) ||
            command.cmdsize < sizeof(command) || command.cmdsize > end - offset) return NO;
        if (command.cmd == LC_UUID) {
            struct uuid_command uuid = {};
            if (command.cmdsize < sizeof(uuid) ||
                !YMSafeReadMemory(YMWeChatDylibSlide + offset, &uuid, sizeof(uuid))) return NO;
            matchesUUID = memcmp(uuid.uuid, expectedUUID, sizeof(expectedUUID)) == 0;
            break;
        }
        offset += command.cmdsize;
    }
    return matchesUUID;
}

BOOL YMGetMediaForwardAddresses(YMMediaForwardAddresses *addresses) {
    if (!addresses) return NO;
    *addresses = {};
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!profile || !profile->mediaForward.fromWrap || !YMWeChatDylibSlide ||
        !YMMatchesWeChat269079Dylib()) return NO;

    // 顺序对应转换、析构、单条转发、目标插入；入口被其他 Hook 改写时也拒绝调用。
    static const uint8_t entryBytes[4][16] = {
        {0xff, 0xc3, 0x01, 0xd1, 0xf8, 0x5f, 0x03, 0xa9, 0xf6, 0x57, 0x04, 0xa9, 0xf4, 0x4f, 0x05, 0xa9},
        {0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa},
        {0xff, 0x43, 0x06, 0xd1, 0xfc, 0x6f, 0x13, 0xa9, 0xfa, 0x67, 0x14, 0xa9, 0xf8, 0x5f, 0x15, 0xa9},
        {0xff, 0x83, 0x01, 0xd1, 0xf8, 0x5f, 0x02, 0xa9, 0xf6, 0x57, 0x03, 0xa9, 0xf4, 0x4f, 0x04, 0xa9}
    };
    uintptr_t runtime[4] = {
        YMRuntimeAddress(profile->mediaForward.fromWrap),
        YMRuntimeAddress(profile->mediaForward.destruct),
        YMRuntimeAddress(profile->mediaForward.forward),
        YMRuntimeAddress(profile->mediaForward.addRecipient)
    };
    for (size_t index = 0; index < 4; index++) {
        uint8_t current[16] = {};
        if (!runtime[index] || !YMSafeReadMemory(runtime[index], current, sizeof(current)) ||
            memcmp(current, entryBytes[index], sizeof(current)) != 0) return NO;
    }
    *addresses = {runtime[0], runtime[1], runtime[2], runtime[3]};
    return YES;
}

uintptr_t YMMessageDataConstructorRuntimeAddress(void) {
    YMMediaForwardAddresses addresses = {};
    if (!YMGetMediaForwardAddresses(&addresses)) return 0;
    // 269079 的 MessageData 默认构造器，原生初始化所有 string、shared_ptr 和容器。
    // 独立校验：构造器不匹配只禁用生成通知，不影响已有消息的 +1 与媒体转发。
    const uintptr_t runtime = YMRuntimeAddress(0x48e0f90);
    static const uint8_t expected[16] = {
        0x08, 0x2a, 0x02, 0x90, 0x08, 0xe1, 0x14, 0x91,
        0x08, 0x41, 0x00, 0x91, 0x1f, 0x70, 0x02, 0x78
    };
    uint8_t actual[16] = {};
    if (!runtime || !YMSafeReadMemory(runtime, actual, sizeof(actual)) ||
        memcmp(actual, expected, sizeof(actual)) != 0) return 0;
    return runtime;
}

static inline void *YMRuntimePointer(uintptr_t staticVA) {
    uintptr_t address = YMRuntimeAddress(staticVA);
    if (address == 0) {
        return NULL;
    }

    return (void *)address;
}

#pragma mark - 版本检查

static BOOL YMIsTargetWeChatVersion(void) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();

    if (!profile) {
        YMLog(@"unsupported WeChat version, skip anti revoke");
        return NO;
    }

    YMLog(@"current adapt profile=%s%@",
          profile->displayName,
          YMProfileHasAntiRevokeAddresses(profile) ? @"" : @" (feature addresses incomplete / debug mode)");
    return YES;
}

#pragma mark - C++ std::string 辅助

/*
 第一版先默认使用纯文本系统消息。
 老版 WeChatExtension 也是类似逻辑：msgType=10000 + content 文案。
 如果纯文本不显示，再把这里改成 XML 版本测试。
 */
__attribute__((unused))
static std::string YMBuildAntiRevokeSystemContent(void) {
    return YMStdStringFromNSString(@"已拦截到一条撤回消息");
}

/*
 备用 XML 版本。
 如果纯文本版本插入了但 UI 不显示，可以把 YMBuildAntiRevokeSystemContent()
 里 return 改成这个函数。
 */
__attribute__((unused))
static std::string YMBuildAntiRevokeSystemXMLContent(void) {
    std::string text = YMStdStringFromNSString(@"已拦截到一条撤回消息");

    std::string xml;
    xml += "<?xml version=\"1.0\"?>\n";
    xml += "<sysmsg type=\"paymsg\">";
    xml += "<content><![CDATA[";
    xml += text;
    xml += "]]></content>";
    xml += "</sysmsg>";

    return xml;
}

#pragma mark - shared_ptr 释放辅助

/*
 微信内部大量使用 libc++ shared_ptr。
 反编译中一般是：
   if (control && !atomic_fetch_add(control + 8, -1)) {
       control->__on_zero_shared(control);
       std::__shared_weak_count::__release_weak(control);
   }

 这里第一版只用于自己栈上临时 shared_ptr 的释放。
 如果测试阶段担心这里有风险，可以临时把调用 YMReleaseSharedPtrStorage 的地方注释掉。
 */
__attribute__((unused))
static void YMReleaseSharedPtrStorage(void *storage) {
    if (!storage) {
        return;
    }

    void **items = (void **)storage;
    void *controlBlock = items[1];

    items[0] = NULL;
    items[1] = NULL;

    if (!controlBlock) {
        return;
    }

    // libc++ shared_count 的 shared_owners_ 通常在 controlBlock + 8。
    volatile long *sharedOwners = (volatile long *)((uint8_t *)controlBlock + 8);
    long oldValue = __atomic_fetch_add(sharedOwners, -1, __ATOMIC_ACQ_REL);

    // 反编译里的判断是 oldValue == 0 时释放。
    if (oldValue == 0) {
        void **vtable = *(void ***)controlBlock;

        // vtable[2] 通常对应 __on_zero_shared()
        if (vtable && vtable[2]) {
            typedef void (*OnZeroSharedFunc)(void *);
            ((OnZeroSharedFunc)vtable[2])(controlBlock);
        }

        // vtable[3] 通常对应 __on_zero_shared_weak()
        if (vtable && vtable[3]) {
            typedef void (*OnZeroSharedWeakFunc)(void *);
            ((OnZeroSharedWeakFunc)vtable[3])(controlBlock);
        }
    }
}

#pragma mark - MessageWrap 字段读取

static std::string *YMRawWrapStringField(void *rawWrap, size_t offset) {
    if (!rawWrap) {
        return NULL;
    }

    return (std::string *)((uint8_t *)rawWrap + offset);
}

static uint32_t YMRawWrapUInt32Field(void *rawWrap, size_t offset) {
    if (!rawWrap) {
        return 0;
    }

    return *(uint32_t *)((uint8_t *)rawWrap + offset);
}

static uint64_t YMRawWrapUInt64Field(void *rawWrap, size_t offset) {
    if (!rawWrap) {
        return 0;
    }

    return *(uint64_t *)((uint8_t *)rawWrap + offset);
}

static NSString *YMFormatTimestamp(uint32_t createTimeSec, uint64_t createTimeMs) {
    NSTimeInterval messageTimestamp = 0;

    if (createTimeSec > 0) {
        messageTimestamp = (NSTimeInterval)createTimeSec;
    } else if (createTimeMs > 0) {
        messageTimestamp = (NSTimeInterval)(createTimeMs / 1000);
    } else {
        messageTimestamp = [[NSDate date] timeIntervalSince1970];
    }

    NSDate *messageDate = [NSDate dateWithTimeIntervalSince1970:messageTimestamp];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";

    return [formatter stringFromDate:messageDate] ?: @"";
}

static NSString *YMExtractXMLTagValue(NSString *xml, NSString *tag) {
    if (xml.length == 0 || tag.length == 0) {
        return @"";
    }

    NSString *openTag = [NSString stringWithFormat:@"<%@>", tag];
    NSString *closeTag = [NSString stringWithFormat:@"</%@>", tag];

    NSRange openRange = [xml rangeOfString:openTag options:NSCaseInsensitiveSearch];
    if (openRange.location == NSNotFound) {
        return @"";
    }

    NSUInteger valueStart = NSMaxRange(openRange);
    if (valueStart >= xml.length) {
        return @"";
    }

    NSRange searchRange = NSMakeRange(valueStart, xml.length - valueStart);
    NSRange closeRange = [xml rangeOfString:closeTag options:NSCaseInsensitiveSearch range:searchRange];
    if (closeRange.location == NSNotFound || closeRange.location < valueStart) {
        return @"";
    }

    NSString *value = [xml substringWithRange:NSMakeRange(valueStart, closeRange.location - valueStart)] ?: @"";
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([value hasPrefix:@"<![CDATA["] && [value hasSuffix:@"]]>"] && value.length >= 12) {
        value = [value substringWithRange:NSMakeRange(9, value.length - 12)] ?: @"";
    }

    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static NSString *YMRevokerWxidFromRevokeXMLPrefix(NSString *xml) {
    if (xml.length == 0) {
        return @"";
    }

    NSRange sysmsgRange = [xml rangeOfString:@"<sysmsg" options:NSCaseInsensitiveSearch];
    if (sysmsgRange.location == NSNotFound || sysmsgRange.location == 0) {
        return @"";
    }

    NSString *prefix = [[xml substringToIndex:sysmsgRange.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([prefix hasSuffix:@":"]) {
        prefix = [prefix substringToIndex:prefix.length - 1];
    }

    if ([prefix hasPrefix:@"wxid_"] || prefix.length > 0) {
        return prefix;
    }
    return @"";
}

static NSString *YMDisplayNameFromRevokeReplaceMsg(NSString *replaceMsg) {
    if (replaceMsg.length == 0) {
        return @"";
    }

    NSRange firstQuote = [replaceMsg rangeOfString:@"\""];
    if (firstQuote.location != NSNotFound) {
        NSRange searchRange = NSMakeRange(NSMaxRange(firstQuote), replaceMsg.length - NSMaxRange(firstQuote));
        NSRange secondQuote = [replaceMsg rangeOfString:@"\"" options:0 range:searchRange];
        if (secondQuote.location != NSNotFound && secondQuote.location > NSMaxRange(firstQuote)) {
            NSString *name = [replaceMsg substringWithRange:NSMakeRange(NSMaxRange(firstQuote), secondQuote.location - NSMaxRange(firstQuote))];
            name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (name.length > 0) {
                return name;
            }
        }
    }

    NSString *name = [replaceMsg copy];
    for (NSString *suffix in @[@"撤回了一条消息", @"撤回了消息", @"recalled a message"]) {
        NSRange range = [name rangeOfString:suffix options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            name = [name substringToIndex:range.location];
            break;
        }
    }

    name = [[name stringByReplacingOccurrencesOfString:@"\"" withString:@""]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return name ?: @"";
}

static NSString *YMFindRevokeXMLFromRawWrap(void *rawWrap, size_t wrapSize) {
    if (!rawWrap || wrapSize < 24) {
        return @"";
    }

    /*
     4.1.10 实测：撤回 sysmsg 的 XML 在 MessageWrap + 304，
     +352 是 msgsource，之前按 +328 读取会拿到空字符串。
     这里仍然做全量 fallback 扫描，避免小版本偏移轻微漂移。
     */
    const size_t preferredOffsets[] = {304, 328, 352, 376, 400, 424, 448, 280, 248, 224, 200};
    for (size_t i = 0; i < sizeof(preferredOffsets) / sizeof(preferredOffsets[0]); i++) {
        size_t offset = preferredOffsets[i];
        if (offset + 24 > wrapSize) {
            continue;
        }
        NSString *value = YMNSStringFromLibcppStringObject((uint8_t *)rawWrap + offset);
        NSString *lower = value.lowercaseString;
        if ([lower containsString:@"<sysmsg"] && [lower containsString:@"revokemsg"]) {
            YMLog(@"raw revoke xml found at preferred offset +%zu", offset);
            return value ?: @"";
        }
    }

    for (size_t offset = 0; offset + 24 <= wrapSize; offset += 8) {
        NSString *value = YMNSStringFromLibcppStringObject((uint8_t *)rawWrap + offset);
        if (value.length == 0) {
            continue;
        }
        NSString *lower = value.lowercaseString;
        if ([lower containsString:@"<sysmsg"] && [lower containsString:@"revokemsg"]) {
            YMLog(@"raw revoke xml found by scan at offset +%zu", offset);
            return value ?: @"";
        }
    }

    return @"";
}

static NSString *YMBuildAntiRevokeNoticeText(NSString *remoteUserOrSession,
                                             NSString *selfUser,
                                             NSString *messageTimeText,
                                             NSString *revokerWxid,
                                             NSString *replaceMsg,
                                             NSString *revokeSession,
                                             NSString *msgID,
                                             NSString *newMsgID) {
    NSString *displayName = YMDisplayNameFromRevokeReplaceMsg(replaceMsg);
    NSString *session = revokeSession.length > 0 ? revokeSession : (remoteUserOrSession ?: @"");

    NSMutableString *text = [NSMutableString string];
    [text appendString:@"⚠️苏维埃已拦截撤回消息⚠️\n"];

    if (displayName.length > 0 && revokerWxid.length > 0) {
        [text appendFormat:@"%@（%@）\n", displayName, revokerWxid];
    } else if (displayName.length > 0) {
        [text appendFormat:@"%@\n", displayName];
    } else if (revokerWxid.length > 0) {
        [text appendFormat:@"%@\n", revokerWxid];
    } else {
        [text appendFormat:@"撤回方/会话：%@\n", remoteUserOrSession ?: @""];
    }

    /*
     这里不显示“原消息类型/内容”。
     原消息本身已经因为当前 hook 被保留下来；如果要额外展示类型和内容，
     后续需要换到 CoReplaceOriginMessageByRevoke 并安全自查 MessageWrap，不能再 hook 全局 copy 函数。
     */
    if (messageTimeText.length > 0) {
        [text appendString:messageTimeText];
    }

    return text;
}

#pragma mark - 内存写入

static BOOL YMWritePointer(uintptr_t address,
                           uintptr_t value,
                           uintptr_t expectedOldValue,
                           const char *name) {
    if (address == 0 || value == 0) {
        YMLog(@"invalid pointer patch argument: %s", name);
        return NO;
    }

    uintptr_t *target = (uintptr_t *)address;
    uintptr_t current = *target;

    if (current == value) {
        YMLog(@"pointer already hooked: %s at 0x%lx", name, (unsigned long)address);
        return YES;
    }

    if (current != expectedOldValue) {
        YMLog(@"pointer old value mismatch: %s", name);
        YMLog(@"address=0x%lx, current=0x%lx, expected=0x%lx, new=0x%lx",
              (unsigned long)address,
              (unsigned long)current,
              (unsigned long)expectedOldValue,
              (unsigned long)value);
        return NO;
    }

    vm_size_t pageSize = (vm_size_t)getpagesize();
    vm_address_t pageStart = (vm_address_t)(address & ~((uintptr_t)pageSize - 1));
    vm_size_t protectSize = pageSize;

    kern_return_t kr = vm_protect(mach_task_self(),
                                  pageStart,
                                  protectSize,
                                  false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);

    if (kr != KERN_SUCCESS) {
        YMLog(@"vm_protect pointer RW|COPY failed: %s, kr=%d", name, kr);
        return NO;
    }

    __atomic_store_n(target, value, __ATOMIC_SEQ_CST);

    YMLog(@"pointer hook success: %s, address=0x%lx, value=0x%lx",
          name,
          (unsigned long)address,
          (unsigned long)value);

    return YES;
}

#pragma mark - ARM64 代码段 Patch

static void YMPrintCodeBytes(const char *name, const char *stage, void *address) {
    if (!address) {
        YMLog(@"%s %s address is NULL", name, stage);
        return;
    }

    uint32_t bytes[4] = {0};
    memcpy(bytes, address, sizeof(bytes));

    YMLog(@"%s %s address=%p bytes=%08x %08x %08x %08x",
          name,
          stage,
          address,
          bytes[0],
          bytes[1],
          bytes[2],
          bytes[3]);
}

static BOOL YMProtectCodePage(uintptr_t address,
                              size_t patchSize,
                              vm_prot_t protection,
                              const char *name,
                              const char *stage) {
    vm_size_t pageSize = (vm_size_t)getpagesize();
    vm_address_t pageStart = (vm_address_t)(address & ~((uintptr_t)pageSize - 1));

    uintptr_t patchEnd = address + patchSize;
    uintptr_t pageEnd = (patchEnd + pageSize - 1) & ~((uintptr_t)pageSize - 1);

    vm_size_t protectSize = (vm_size_t)(pageEnd - pageStart);

    kern_return_t kr = vm_protect(mach_task_self(),
                                  pageStart,
                                  protectSize,
                                  false,
                                  protection);

    if (kr != KERN_SUCCESS) {
        YMLog(@"%s vm_protect %s failed, address=0x%lx, pageStart=0x%lx, size=%lu, kr=%d",
              name,
              stage,
              (unsigned long)address,
              (unsigned long)pageStart,
              (unsigned long)protectSize,
              kr);
        return NO;
    }

    return YES;
}

/*
 ARM64 BOOL/int 强制返回 YES：

   mov w0, #1
   ret

 机器码：
   20 00 80 52
   C0 03 5F D6

 注意：
   这里用 w0，不用 x0。
   因为 sub_200730 里是 if (v85 & 1)，本质是 BOOL/int。
 */
static BOOL YMPatchARM64ReturnYES(uintptr_t address, const char *name) {
    if (address == 0) {
        YMLog(@"%s patch failed: address is zero", name);
        return NO;
    }

    void *target = (void *)address;

    uint32_t patch[2] = {
        0x52800020, // mov w0, #1
        0xD65F03C0  // ret
    };

    YMPrintCodeBytes(name, "before", target);

    uint32_t current[2] = {0};
    memcpy(current, target, sizeof(current));

    if (current[0] == patch[0] && current[1] == patch[1]) {
        YMLog(@"%s already patched, address=0x%lx", name, (unsigned long)address);
        return YES;
    }

    if (!YMProtectCodePage(address,
                           sizeof(patch),
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY,
                           name,
                           "RW|COPY")) {
        return NO;
    }

    memcpy(target, patch, sizeof(patch));

    /*
     写指令后必须清 i-cache。
     否则 CPU 可能继续执行旧指令。
     */
    sys_icache_invalidate(target, sizeof(patch));

    if (!YMProtectCodePage(address,
                           sizeof(patch),
                           VM_PROT_READ | VM_PROT_EXECUTE,
                           name,
                           "RX")) {
        return NO;
    }

    YMPrintCodeBytes(name, "after", target);

    uint32_t check[2] = {0};
    memcpy(check, target, sizeof(check));

    BOOL ok = check[0] == patch[0] && check[1] == patch[1];

    YMLog(@"%s patch result=%@, address=0x%lx",
          name,
          ok ? @"OK" : @"FAIL",
          (unsigned long)address);

    return ok;
}

/*
 ARM64 int 强制返回：

   mov w0, #value
   ret
 */
static BOOL YMPatchARM64ReturnInt32(uintptr_t address, uint32_t value, const char *name) {
    if (address == 0) {
        YMLog(@"%s patch failed: address is zero", name);
        return NO;
    }

    if (value > 0xFFFF) {
        YMLog(@"%s patch failed: value too large: %u", name, value);
        return NO;
    }

    void *target = (void *)address;

    uint32_t patch[2] = {
        0x52800000 | ((value & 0xFFFF) << 5), // mov w0, #value
        0xD65F03C0                            // ret
    };

    YMPrintCodeBytes(name, "before", target);

    uint32_t current[2] = {0};
    memcpy(current, target, sizeof(current));

    if (current[0] == patch[0] && current[1] == patch[1]) {
        YMLog(@"%s already patched, address=0x%lx", name, (unsigned long)address);
        return YES;
    }

    if (!YMProtectCodePage(address,
                           sizeof(patch),
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY,
                           name,
                           "RW|COPY")) {
        return NO;
    }

    memcpy(target, patch, sizeof(patch));
    sys_icache_invalidate(target, sizeof(patch));

    if (!YMProtectCodePage(address,
                           sizeof(patch),
                           VM_PROT_READ | VM_PROT_EXECUTE,
                           name,
                           "RX")) {
        return NO;
    }

    uint32_t check[2] = {0};
    memcpy(check, target, sizeof(check));

    BOOL ok = check[0] == patch[0] && check[1] == patch[1];

    YMPrintCodeBytes(name, "after", target);

    YMLog(@"%s patch result=%@, address=0x%lx, value=%u",
          name,
          ok ? @"OK" : @"FAIL",
          (unsigned long)address,
          value);

    return ok;
}

/*
 4.1.10
 ARM64 函数入口绝对跳转：

   ldr x16, #8
   br  x16
   .quad hookAddress

 机器码：
   50 00 00 58
   00 02 1F D6
   hookAddress 8 bytes
 */
BOOL YMPatchARM64AbsoluteJump(uintptr_t address,
                                     uintptr_t targetAddress,
                                     const char *name) {
    if (address == 0 || targetAddress == 0) {
        YMLog(@"%s inline hook failed: address or target is zero", name);
        return NO;
    }

    void *target = (void *)address;

    uint8_t patch[16] = {0};

    uint32_t insnLdrX16 = 0x58000050; // ldr x16, #8
    uint32_t insnBrX16  = 0xD61F0200; // br x16

    memcpy(patch + 0, &insnLdrX16, sizeof(insnLdrX16));
    memcpy(patch + 4, &insnBrX16, sizeof(insnBrX16));
    memcpy(patch + 8, &targetAddress, sizeof(targetAddress));

    YMPrintCodeBytes(name, "before", target);

    uint8_t current[16] = {0};
    memcpy(current, target, sizeof(current));

    if (memcmp(current, patch, sizeof(patch)) == 0) {
        YMLog(@"%s already inline hooked, address=0x%lx",
              name,
              (unsigned long)address);
        return YES;
    }

    if (!YMProtectCodePage(address,
                           sizeof(patch),
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY,
                           name,
                           "RW|COPY")) {
        return NO;
    }

    memcpy(target, patch, sizeof(patch));

    sys_icache_invalidate(target, sizeof(patch));

    if (!YMProtectCodePage(address,
                           sizeof(patch),
                           VM_PROT_READ | VM_PROT_EXECUTE,
                           name,
                           "RX")) {
        return NO;
    }

    uint8_t check[16] = {0};
    memcpy(check, target, sizeof(check));

    BOOL ok = memcmp(check, patch, sizeof(patch)) == 0;

    YMPrintCodeBytes(name, "after", target);

    YMLog(@"%s inline hook result=%@, address=0x%lx, target=0x%lx",
          name,
          ok ? @"OK" : @"FAIL",
          (unsigned long)address,
          (unsigned long)targetAddress);

    return ok;
}

#pragma mark - 本地插入灰色系统消息

/*
 参数 rawRevokeMessage：
   这是 ym_HandleSysMsg_RevokeMsg 原函数的第二个参数 X1。
   原函数会用 sub_4728670(rawWrap, rawRevokeMessage) 构造一个 MessageWrap。

 复用这一步，主要是为了拿到会话相关字段：
   rawWrap + 24
   rawWrap + 48

 然后构造自己的 type=10000 MessageWrap 插入本地聊天流。
 */
static BOOL YMInsertLocalAntiRevokeNotice(int64_t rawRevokeMessage) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!profile) {
        YMLog(@"insert local notice failed: no active profile");
        return NO;
    }

    if (YMWeChatDylibSlide == 0) {
        YMLog(@"insert local notice failed: YMWeChatDylibSlide is zero");
        return NO;
    }

    if (rawRevokeMessage == 0) {
        YMLog(@"insert local notice failed: rawRevokeMessage is zero");
        return NO;
    }

    YMLog(@"try insert local anti revoke notice by sub_3822FA4, rawRevokeMessage=0x%llx, profile=%s",
          (unsigned long long)rawRevokeMessage,
          profile->displayName);

    YMMessageWrapFromRawFunc MessageWrapFromRaw =
    (YMMessageWrapFromRawFunc)YMRuntimePointer(profile->messageWrapFromRawVA);

    YMMessageWrapDestructFunc MessageWrapDestruct =
    (YMMessageWrapDestructFunc)YMRuntimePointer(profile->messageWrapDestructVA);

    YMInsertPaySysMsgToSessionFunc InsertPaySysMsgToSession =
    (YMInsertPaySysMsgToSessionFunc)YMRuntimePointer(profile->insertPaySysMsgToSessionVA);

    if (!MessageWrapFromRaw || !MessageWrapDestruct || !InsertPaySysMsgToSession) {
        YMLog(@"insert local notice failed: internal function pointer is null");
        return NO;
    }

    /*
     rawWrap：
     复刻 ym_HandleSysMsg_RevokeMsg 原始逻辑：

       memcpy(rawWrap, unk_7861730, 616)
       sub_4728670(rawWrap, rawRevokeMessage)

     目的：
       只为了从 rawWrap 里拿到会话字段。
    */
    const size_t wrapSize = profile->layout.messageWrapSize;

    alignas(16) uint8_t rawWrap[616];
    memset(rawWrap, 0, sizeof(rawWrap));

    if (wrapSize > sizeof(rawWrap)) {
        YMLog(@"insert local notice failed: wrapSize too large. wrapSize=%zu", wrapSize);
        return NO;
    }

    void *rawTemplate = YMRuntimePointer(profile->rawMessageTemplateVA);
    if (!rawTemplate) {
        YMLog(@"insert local notice failed: rawTemplate is null");
        return NO;
    }

    memcpy(rawWrap, rawTemplate, wrapSize);

    MessageWrapFromRaw(rawWrap, rawRevokeMessage);

    BOOL ok = NO;

    try {
        std::string *rawField24 = YMRawWrapStringField(rawWrap, profile->layout.remoteUserOrSessionOffset);
        std::string *rawField48 = YMRawWrapStringField(rawWrap, profile->layout.selfUserOffset);

        NSString *remoteUserOrSessionText = YMNSStringFromStdString(rawField24);
        NSString *selfUserText = YMNSStringFromStdString(rawField48);

        YMLog(@"raw field24=%s", rawField24 ? rawField24->c_str() : "");
        YMLog(@"raw field48=%s", rawField48 ? rawField48->c_str() : "");

        /*
         从实际测试结果看：
           rawField24 = 对方 / 当前聊天会话
           rawField48 = 当前登录账号 / 自己

         所以这里必须用 rawField24 作为 session。
         */
        std::string *remoteUserOrSession = rawField24;
        std::string *selfUser = rawField48;

        std::string *session = remoteUserOrSession;

        if (!session || session->empty()) {
            YMLog(@"rawField24 is empty, fallback to rawField48");
            session = rawField48;
        }

        if (!session || session->empty()) {
            YMLog(@"insert local notice failed: session is empty");
            MessageWrapDestruct((int64_t)rawWrap);
            return NO;
        }

        uint32_t rawCreateTimeSec = YMRawWrapUInt32Field(rawWrap, profile->layout.createTimeSecOffset);
        uint64_t rawCreateTimeMs  = YMRawWrapUInt64Field(rawWrap, profile->layout.createTimeMsOffset);

        NSString *messageTimeText = YMFormatTimestamp(rawCreateTimeSec, rawCreateTimeMs);

        std::string *rawField72 = YMRawWrapStringField(rawWrap, 72);
        NSString *revokerWxid = YMNSStringFromStdString(rawField72);
        NSString *revokeXML = YMFindRevokeXMLFromRawWrap(rawWrap, wrapSize);

        if (revokerWxid.length == 0) {
            revokerWxid = YMRevokerWxidFromRevokeXMLPrefix(revokeXML);
        }

        NSString *revokeSession = YMExtractXMLTagValue(revokeXML, @"session");
        NSString *msgID = YMExtractXMLTagValue(revokeXML, @"msgid");
        NSString *newMsgID = YMExtractXMLTagValue(revokeXML, @"newmsgid");
        NSString *replaceMsg = YMExtractXMLTagValue(revokeXML, @"replacemsg");

        YMLog(@"raw field72=%s", rawField72 ? rawField72->c_str() : "");
        YMLog(@"raw revoke xml=%@", revokeXML ?: @"");
        YMLog(@"revoke parsed session=%@ msgid=%@ newmsgid=%@ revoker=%@ replace=%@ displayName=%@",
              revokeSession ?: @"",
              msgID ?: @"",
              newMsgID ?: @"",
              revokerWxid ?: @"",
              replaceMsg ?: @"",
              YMDisplayNameFromRevokeReplaceMsg(replaceMsg) ?: @"");

        NSString *noticeText = YMBuildAntiRevokeNoticeText(remoteUserOrSessionText,
                                                           selfUserText,
                                                           messageTimeText,
                                                           revokerWxid,
                                                           replaceMsg,
                                                           revokeSession,
                                                           msgID,
                                                           newMsgID);

        if (noticeText.length == 0) {
            noticeText = [NSString stringWithFormat:@"⚠️苏维埃已拦截撤回消息⚠️\n会话：%@\n%@",
                          remoteUserOrSessionText ?: @"",
                          messageTimeText ?: @""];
        }

        std::string content = YMStdStringFromNSString(noticeText);

        YMLog(@"raw createTimeSec=%u", rawCreateTimeSec);
        YMLog(@"raw createTimeMs=%llu", (unsigned long long)rawCreateTimeMs);
        YMLog(@"message time=%@", messageTimeText);

        YMLog(@"insert notice session=%s", session->c_str());
        YMLog(@"insert notice remoteUserOrSession=%s", remoteUserOrSession ? remoteUserOrSession->c_str() : "");
        YMLog(@"insert notice selfUser=%s", selfUser ? selfUser->c_str() : "");
        YMLog(@"insert notice content=%s", content.c_str());
        YMLog(@"call insertPaySysMsgToSession at 0x%lx",
              (unsigned long)YMRuntimeAddress(profile->insertPaySysMsgToSessionVA));

        int64_t result = InsertPaySysMsgToSession(0, session, &content);

        YMLog(@"insertPaySysMsgToSession result=0x%llx", (unsigned long long)result);

        ok = YES;
    } catch (...) {
        YMLog(@"exception while calling insertPaySysMsgToSession insert local notice");
        ok = NO;
    }

    MessageWrapDestruct((int64_t)rawWrap);

    return ok;
}

#pragma mark - 群员退群监控

static NSMutableDictionary<NSString *, NSSet<NSString *> *> *YMGroupExitMemberCache(void) {
    static NSMutableDictionary<NSString *, NSSet<NSString *> *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSMutableDictionary alloc] init];
    });
    return cache;
}

static NSMutableDictionary<NSString *, NSDate *> *YMGroupExitRecentTipCache(void) {
    static NSMutableDictionary<NSString *, NSDate *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSMutableDictionary alloc] init];
    });
    return cache;
}

static NSMutableArray<NSDictionary<NSString *, id> *> *YMGroupExitPendingNotices(void) {
    static NSMutableArray<NSDictionary<NSString *, id> *> *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSMutableArray alloc] init];
    });
    return queue;
}

// 群成员展示名缓存。
//key主要为id和昵称
static NSMutableDictionary<NSString *, NSString *> *YMGroupExitDisplayNameCache(void) {
    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSMutableDictionary alloc] init];
    });
    return cache;
}

#pragma mark - 按需查询群名

/*
 Build 269079 / arm64：0x3830E14 按 x1=std::string* 查询，x2=已构造的会话对象。
 x0 在入口即被覆盖，当前 UUID 下不读取传入的 this；不能沿用到未核实的版本。
 0x3A148C0 在共享锁内查微信自身的会话表，命中经 0x313828 / 0x31A7CC 赋值。
 +0x000 为会话 ID，+0x120 为群名；读取群名前校验返回的会话 ID 与查询一致。
 输出布局由赋值函数和析构 0x154094 / 0x154218 交叉核对，总长 0x218。
 0x31A8B4 复制 +0x190 的 vector，元素为 24 字节 string + 8 字节值。
 +0xC0 的 shared_ptr 仅被赋值；0x31A854 明确允许旧控制块为空，不需伪造控制块。
 用 libc++ 对象正常构造/析构承接所有权，不能把清零的字节数组当赋值目标。
 查询在撤回回调内同步完成，群名复制为 NSString 后释放临时会话对象。
 */
struct YMRoomSessionEntry {
    std::string text;
    uint64_t value = 0;
};

struct YMRoomSessionData {
    std::string roomID;
    uint8_t field18[0x28] = {};
    std::string field40;
    std::string field58;
    uint8_t field70[0x20] = {};
    std::string field90;
    std::string fieldA8;
    std::shared_ptr<void> fieldC0;
    uint8_t fieldD0[8] = {};
    std::string fieldD8;
    std::string fieldF0;
    std::string field108;
    std::string roomName;
    uint8_t field138[0x18] = {};
    std::string field150;
    std::string field168;
    uint8_t field180[0x10] = {};
    std::vector<YMRoomSessionEntry> field190;
    uint8_t field1A8[8] = {};
    std::string field1B0;
    std::string field1C8;
    std::string field1E0;
    uint8_t field1F8[8] = {};
    std::string field200;
};

static_assert(sizeof(std::string) == 0x18 && sizeof(YMRoomSessionEntry) == 0x20, "WeChat string/vector ABI");
static_assert(sizeof(YMRoomSessionData) == 0x218 && alignof(YMRoomSessionData) == 8, "WeChat session ABI");
static_assert(offsetof(YMRoomSessionData, field40) == 0x40 && offsetof(YMRoomSessionData, field58) == 0x58, "session strings");
static_assert(offsetof(YMRoomSessionData, field90) == 0x90 && offsetof(YMRoomSessionData, fieldA8) == 0xa8, "session strings");
static_assert(offsetof(YMRoomSessionData, fieldC0) == 0xc0 && offsetof(YMRoomSessionData, fieldD8) == 0xd8, "session shared_ptr");
static_assert(offsetof(YMRoomSessionData, fieldF0) == 0xf0 && offsetof(YMRoomSessionData, field108) == 0x108, "session strings");
static_assert(offsetof(YMRoomSessionData, roomName) == 0x120 && offsetof(YMRoomSessionData, field150) == 0x150, "session name");
static_assert(offsetof(YMRoomSessionData, field168) == 0x168 && offsetof(YMRoomSessionData, field190) == 0x190, "session vector");
static_assert(offsetof(YMRoomSessionData, field1B0) == 0x1b0 && offsetof(YMRoomSessionData, field1C8) == 0x1c8, "session strings");
static_assert(offsetof(YMRoomSessionData, field1E0) == 0x1e0 && offsetof(YMRoomSessionData, field200) == 0x200, "session tail");

static uintptr_t YMRoomNameQueryRuntimeAddress(void) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!profile || !profile->roomNameQueryVA || !YMWeChatDylibSlide ||
        !YMMatchesWeChat269079Dylib()) return 0;

    static const uint8_t expectedEntry[16] = {
        0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9,
        0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91
    };
    uintptr_t address = YMRuntimeAddress(profile->roomNameQueryVA);
    uint8_t current[16] = {};
    if (!YMSafeReadMemory(address, current, sizeof(current)) ||
        memcmp(current, expectedEntry, sizeof(current)) != 0) return 0;
    return address;
}

NSString *YMQueryRoomName(NSString *roomID) {
    if (![roomID hasSuffix:@"@chatroom"] || roomID.length > 128 ||
        [roomID rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) return @"";
    uintptr_t address = YMRoomNameQueryRuntimeAddress();
    if (!address) return @"";

    try {
        std::string query = YMStdStringFromNSString(roomID);
        if (query.empty() || query.size() > 128) return @"";
        YMRoomSessionData session;
        using QuerySession = uint64_t (*)(uintptr_t, const std::string *, YMRoomSessionData *);
        uint64_t status = ((QuerySession)address)(0, &query, &session);
        if (status != 1 || session.roomID != query || session.roomName.empty() ||
            session.roomName.size() > 1024) return @"";
        return [[NSString alloc] initWithBytes:session.roomName.data()
                                       length:session.roomName.size()
                                     encoding:NSUTF8StringEncoding] ?: @"";
    } catch (...) {
        YMLog(@"[RoomNameQuery] session lookup failed");
        return @"";
    }
}

// Build 269079 原生缓存查询 0x1E55B00：Context -> 虚表 +0x38 Registry ->
// 0x1E58634 ContactCache -> 0x39EFD50 shared_ptr<Contact>；+8 为 ID，+0x60 为备注。
// shared_ptr/string 都是非平凡返回值（arm64 x8 sret），必须用真实 C++ 返回类型和 RAII。
// ponytail: 只读微信已有缓存；未命中回退引用原名，避免 0x221D55C 的数据库/future 等待。
static NSString *YMReadCachedContactRemark(NSString *contactID, const uintptr_t (&functions)[4]) {
    if (!contactID.length || contactID.length > 128 ||
        [contactID hasSuffix:@"@chatroom"] || [contactID hasSuffix:@"@im.chatroom"] ||
        [contactID rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) return @"";
    try {
        const std::string query = YMStdStringFromNSString(contactID);
        if (query.empty() || query.size() > 128) return @"";
        using Shared = std::shared_ptr<void>;
        using GetContext = Shared (*)();
        using GetService = Shared (*)(void *);
        using FindContact = Shared (*)(void *, const std::string *);
        using GetRemark = std::string (*)(void *);
        const auto context = reinterpret_cast<GetContext>(functions[0])();
        if (!context) return @"";
        uintptr_t vtable = 0, registryGetter = 0;
        if (!YMSafeReadPointer(reinterpret_cast<uintptr_t>(context.get()), &vtable) || !vtable ||
            !YMSafeReadPointer(vtable + 0x38, &registryGetter) || !registryGetter) return @"";
        const auto registry = reinterpret_cast<GetService>(registryGetter)(context.get());
        if (!registry) return @"";
        const auto cache = reinterpret_cast<GetService>(functions[1])(registry.get());
        if (!cache) return @"";
        const auto contact = reinterpret_cast<FindContact>(functions[2])(cache.get(), &query);
        if (!contact || ![YMNSStringFromLibcppStringObject(
            reinterpret_cast<const uint8_t *>(contact.get()) + 8, 128) isEqualToString:contactID]) return @"";
        const std::string remark = reinterpret_cast<GetRemark>(functions[3])(contact.get());
        if (remark.empty() || remark.size() > 1024) return @"";
        return [[NSString alloc] initWithBytes:remark.data() length:remark.size()
                                     encoding:NSUTF8StringEncoding] ?: @"";
    } catch (...) {
        YMLog(@"[ContactRemark] cached lookup failed");
        return @"";
    }
}

NSString *YMQueryContactRemark(NSString *contactID) {
    if (!YMWeChatDylibSlide || !YMMatchesWeChat269079Dylib()) return @"";
    static const uintptr_t addresses[] = {0x428E5D4, 0x1E58634, 0x39EFD50, 0x47B8684};
    static const uint8_t entries[4][16] = {
        {0xff,0xc3,0x00,0xd1,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91},
        {0xff,0x03,0x01,0xd1,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9,0xfd,0xc3,0x00,0x91},
        {0xff,0x03,0x01,0xd1,0xf6,0x57,0x01,0xa9,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9},
        {0x00,0x80,0x01,0x91,0x64,0x24,0xfd,0x17,0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9}
    };
    uintptr_t functions[4] = {};
    for (size_t i = 0; i < 4; ++i) {
        functions[i] = YMRuntimeAddress(addresses[i]);
        uint8_t current[16] = {};
        if (!YMSafeReadMemory(functions[i], current, sizeof(current)) ||
            memcmp(current, entries[i], sizeof(current)) != 0) return @"";
    }
    uintptr_t application = 0;
    if (!YMSafeReadPointer(YMRuntimeAddress(0x9312568), &application) || !application) return @"";
    return YMReadCachedContactRemark(contactID, functions);
}

// 需要主动预热昵称的群队列。
// DB first snapshot 能提前看到完整成员列表，此时先记录 roomID；
//GetAllMemberDataList
static NSMutableDictionary<NSString *, NSDate *> *YMGroupExitPreloadRoomQueue(void) {
    static NSMutableDictionary<NSString *, NSDate *> *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSMutableDictionary alloc] init];
    });
    return queue;
}

static void YMGroupExitClearNicknameState(void) {
    YMGroupExitKnownChatroomManager.store(0);
    NSMutableDictionary<NSString *, NSString *> *displayNameCache = YMGroupExitDisplayNameCache();
    @synchronized (displayNameCache) {
        if (displayNameCache.count > 0) {
            [displayNameCache removeAllObjects];
        }
    }

    NSMutableDictionary<NSString *, NSDate *> *preloadQueue = YMGroupExitPreloadRoomQueue();
    @synchronized (preloadQueue) {
        if (preloadQueue.count > 0) {
            [preloadQueue removeAllObjects];
        }
    }
}

static void YMGroupExitClearRuntimeState(const char *source) {
    std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
    YMGroupExitClearNicknameState();

    NSMutableArray<NSDictionary<NSString *, id> *> *queue = YMGroupExitPendingNotices();
    @synchronized (queue) {
        if (queue.count > 0) {
            YMLog(@"[GroupExitMonitor] disabled, clear pending notices. source=%s count=%lu",
                  source ?: "",
                  (unsigned long)queue.count);
            [queue removeAllObjects];
        }
    }

    NSMutableDictionary<NSString *, NSSet<NSString *> *> *memberCache = YMGroupExitMemberCache();
    @synchronized (memberCache) {
        if (memberCache.count > 0) {
            [memberCache removeAllObjects];
        }
    }

    NSMutableDictionary<NSString *, NSDate *> *recentTipCache = YMGroupExitRecentTipCache();
    @synchronized (recentTipCache) {
        if (recentTipCache.count > 0) {
            [recentTipCache removeAllObjects];
        }
    }
}

static void YMGroupExitClearRuntimeStateIfDisabled(const char *source) {
    std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
    if (!YMIsGroupExitMonitorEnabled()) YMGroupExitClearRuntimeState(source);
}

static BOOL YMGroupExitProfileReady(const YMWeChatAdaptProfile *profile) {
    if (!profile) {
        return NO;
    }

    // Hotfix 后 UpdateSessionCache / 昵称预热 hook 变成可选项。
    // 退群检测的最小必需链路只需要 DB apply + FMessagePre。
    return profile->groupExitDBApplyVA != 0 &&
           profile->groupExitFMessagePreVA != 0;
}

static BOOL YMGroupExitIsChatRoomID(NSString *roomID) {
    if (roomID.length == 0) {
        return NO;
    }

    return [roomID containsString:@"@chatroom"];
}

static BOOL YMGroupExitMemberIDLooksUseful(NSString *value, NSString *roomID) {
    if (value.length < 2 || value.length > 128) {
        return NO;
    }

    if (roomID.length > 0 && [value isEqualToString:roomID]) {
        return NO;
    }

    if ([value containsString:@"@chatroom"]) {
        return NO;
    }

    if ([value hasPrefix:@"wxid_"] ||
        [value hasPrefix:@"gh_"] ||
        [value containsString:@"@openim"] ||
        [value containsString:@"@stranger"] ||
        [value rangeOfString:@"^[A-Za-z0-9_\\-]{5,}$" options:NSRegularExpressionSearch].location != NSNotFound) {
        return YES;
    }

    return NO;
}

static NSString *YMGroupExitTrimDisplayName(NSString *value) {
    if (value.length == 0) {
        return @"";
    }

    NSString *name = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";

    while ([name hasPrefix:@"@"] && name.length > 1) {
        name = [name substringFromIndex:1];
    }

    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static BOOL YMGroupExitDisplayNameLooksUseful(NSString *displayName, NSString *memberID) {
    NSString *name = YMGroupExitTrimDisplayName(displayName);
    if (name.length == 0 || name.length > 128) {
        return NO;
    }

    if (memberID.length > 0 && [name isEqualToString:memberID]) {
        return NO;
    }

    if ([name containsString:@"@chatroom"] || [name containsString:@"<"] || [name containsString:@">"]) {
        return NO;
    }

    NSString *lower = name.lowercaseString;
    if ([lower hasPrefix:@"http://"] ||
        [lower hasPrefix:@"https://"] ||
        [lower containsString:@"contact_storage"] ||
        [lower containsString:@"chatroom_member"] ||
        [lower containsString:@"getchatroommembershowname"]) {
        return NO;
    }

    return YES;
}

static void YMGroupExitCacheDisplayName(NSString *roomID,
                                        NSString *memberID,
                                        NSString *displayName,
                                        const char *source) {
    if (!YMGroupExitIsChatRoomID(roomID) || memberID.length == 0) {
        return;
    }

    NSString *name = YMGroupExitTrimDisplayName(displayName);
    if (!YMGroupExitDisplayNameLooksUseful(name, memberID)) {
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *cache = YMGroupExitDisplayNameCache();
    NSString *roomKey = [NSString stringWithFormat:@"%@|%@", roomID, memberID];

    @synchronized (cache) {
        NSString *oldName = cache[roomKey];
        cache[roomKey] = name;
        cache[memberID] = name;

        if (cache.count > 4096) {
            NSArray<NSString *> *allKeys = [cache allKeys];
            NSUInteger removeCount = MIN((NSUInteger)512, allKeys.count);
            for (NSUInteger i = 0; i < removeCount; i++) {
                [cache removeObjectForKey:allKeys[i]];
            }
        }

        if (![oldName isEqualToString:name]) {
            YMLog(@"[GroupExitMonitor] display name cached. source=%s room=%@ member=%@ name=%@",
                  source ?: "",
                  roomID ?: @"",
                  memberID ?: @"",
                  name ?: @"");
        }
    }
}

static NSString *YMGroupExitCachedDisplayName(NSString *roomID, NSString *memberID) {
    if (memberID.length == 0) {
        return @"";
    }

    NSMutableDictionary<NSString *, NSString *> *cache = YMGroupExitDisplayNameCache();
    @synchronized (cache) {
        if (roomID.length > 0) {
            NSString *roomKey = [NSString stringWithFormat:@"%@|%@", roomID, memberID];
            NSString *roomName = cache[roomKey];
            if (YMGroupExitDisplayNameLooksUseful(roomName, memberID)) {
                return roomName;
            }
        }

        NSString *globalName = cache[memberID];
        if (YMGroupExitDisplayNameLooksUseful(globalName, memberID)) {
            return globalName;
        }
    }

    return @"";
}

static NSString *YMGroupExitDisplayNameForMemberID(NSString *memberID, NSString *roomID) {
    NSString *displayName = YMIsGroupExitNicknameEnabled() ? YMGroupExitCachedDisplayName(roomID, memberID) : @"";
    if (displayName.length > 0) {
        if (memberID.length > 0) {
            return [NSString stringWithFormat:@"%@（%@）", displayName, memberID];
        }
        return displayName;
    }

    if (memberID.length > 0) {
        return memberID;
    }

    return @"某成员";
}

static BOOL YMGroupExitShouldEmitTip(NSString *roomID, NSString *memberID) {
    if (roomID.length == 0 || memberID.length == 0) {
        return NO;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%@", roomID, memberID];
    NSDate *now = [NSDate date];
    NSMutableDictionary<NSString *, NSDate *> *cache = YMGroupExitRecentTipCache();

    @synchronized (cache) {
        NSDate *last = cache[key];
        // 只防同一次 DB apply / session flush 造成的短时间重复提示。
        // 成员重新进群时会清掉这个 key，允许后续再次退群提示。
        if (last && [now timeIntervalSinceDate:last] < 3.0) {
            return NO;
        }

        cache[key] = now;

        if (cache.count > 512) {
            NSArray<NSString *> *allKeys = [cache allKeys];
            for (NSString *oldKey in allKeys) {
                NSDate *date = cache[oldKey];
                if (!date || [now timeIntervalSinceDate:date] > 300.0) {
                    [cache removeObjectForKey:oldKey];
                }
            }
        }
    }

    return YES;
}

static void YMGroupExitClearRecentTip(NSString *roomID, NSString *memberID, NSString *reason) {
    if (roomID.length == 0 || memberID.length == 0) {
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%@", roomID, memberID];
    NSMutableDictionary<NSString *, NSDate *> *cache = YMGroupExitRecentTipCache();

    @synchronized (cache) {
        if (cache[key]) {
            [cache removeObjectForKey:key];
            YMLog(@"[GroupExitMonitor] recent tip cache cleared. room=%@ member=%@ reason=%@",
                  roomID,
                  memberID,
                  reason ?: @"");
        }
    }
}

static void YMGroupExitEnqueueNotice(NSString *roomID, NSString *memberID, NSString *noticeText) {
    if (!YMGroupExitIsChatRoomID(roomID) || memberID.length == 0 || noticeText.length == 0) {
        return;
    }

    if (!YMGroupExitShouldEmitTip(roomID, memberID)) {
        YMLog(@"[GroupExitMonitor] duplicate tip suppressed. room=%@ member=%@", roomID, memberID);
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%@", roomID, memberID];
    NSMutableArray<NSDictionary<NSString *, id> *> *queue = YMGroupExitPendingNotices();
    NSDate *now = [NSDate date];

    @synchronized (queue) {
        for (NSDictionary<NSString *, id> *item in queue) {
            NSString *oldKey = item[@"key"];
            if ([oldKey isEqualToString:key]) {
                YMLog(@"[GroupExitMonitor] pending duplicate suppressed. room=%@ member=%@", roomID, memberID);
                return;
            }
        }

        NSDictionary<NSString *, id> *item = @{
            @"key": key,
            @"roomID": roomID,
            @"memberID": memberID,
            @"noticeText": noticeText,
            @"date": now,
        };

        [queue addObject:item];

        while (queue.count > 128) {
            [queue removeObjectAtIndex:0];
        }
    }

    YMLog(@"[GroupExitMonitor] notice queued. room=%@ member=%@ notice=%@", roomID, memberID, noticeText);
}

static NSArray<NSDictionary<NSString *, id> *> *YMGroupExitDrainPendingNotices(NSUInteger maxCount) {
    NSMutableArray<NSDictionary<NSString *, id> *> *queue = YMGroupExitPendingNotices();
    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray array];

    @synchronized (queue) {
        if (queue.count == 0) {
            return @[];
        }

        NSUInteger count = MIN(maxCount, queue.count);
        for (NSUInteger i = 0; i < count; i++) {
            [items addObject:queue[i]];
        }

        NSRange range = NSMakeRange(0, count);
        [queue removeObjectsInRange:range];
    }

    return [items copy];
}

static NSDictionary<NSString *, NSSet<NSString *> *> *YMGroupExitReadSnapshotsFromDBApplyTask(int64_t task) {
    if (task == 0) {
        return @{};
    }

    uintptr_t vectorObject = 0;
    if (!YMSafeReadPointer((uintptr_t)task + 24, &vectorObject)) {
        YMLog(@"[GroupExitMonitor] DB apply read vector pointer failed. task=0x%llx", (unsigned long long)task);
        return @{};
    }

    if (vectorObject == 0 || vectorObject < 0x100000000ULL) {
        YMLog(@"[GroupExitMonitor] DB apply invalid vector pointer. task=0x%llx vector=0x%lx",
              (unsigned long long)task,
              (unsigned long)vectorObject);
        return @{};
    }

    uintptr_t begin = 0;
    uintptr_t end = 0;
    uintptr_t cap = 0;
    if (!YMSafeReadPointer(vectorObject + 0, &begin) ||
        !YMSafeReadPointer(vectorObject + 8, &end) ||
        !YMSafeReadPointer(vectorObject + 16, &cap)) {
        YMLog(@"[GroupExitMonitor] DB apply read vector begin/end/cap failed. vector=0x%lx", (unsigned long)vectorObject);
        return @{};
    }

    if (begin == 0 || end == 0 || end < begin || cap < end || begin < 0x100000000ULL) {
        YMLog(@"[GroupExitMonitor] DB apply invalid vector bounds. vector=0x%lx begin=0x%lx end=0x%lx cap=0x%lx",
              (unsigned long)vectorObject,
              (unsigned long)begin,
              (unsigned long)end,
              (unsigned long)cap);
        return @{};
    }

    const size_t entrySize = 80;
    uintptr_t byteSize = end - begin;
    if (byteSize == 0 || (byteSize % entrySize) != 0) {
        YMLog(@"[GroupExitMonitor] DB apply vector size mismatch. vector=0x%lx begin=0x%lx end=0x%lx byteSize=%lu",
              (unsigned long)vectorObject,
              (unsigned long)begin,
              (unsigned long)end,
              (unsigned long)byteSize);
        return @{};
    }

    size_t count = (size_t)(byteSize / entrySize);
    if (count == 0 || count > 20000) {
        YMLog(@"[GroupExitMonitor] DB apply unreasonable member count=%zu, skip. vector=0x%lx", count, (unsigned long)vectorObject);
        return @{};
    }

    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *samples = [NSMutableDictionary dictionary];

    for (size_t i = 0; i < count; i++) {
        uintptr_t entry = begin + i * entrySize;

        //LLDB搞出来 ：entry+8 是 roomId，entry+32 是 memberId。
        NSString *roomID = YMNSStringFromLibcppStringObject((const void *)(entry + 8));
        NSString *memberID = YMNSStringFromLibcppStringObject((const void *)(entry + 32));

        if (!YMGroupExitIsChatRoomID(roomID)) {
            continue;
        }

        if (!YMGroupExitMemberIDLooksUseful(memberID, roomID)) {
            continue;
        }

        NSMutableSet<NSString *> *set = groups[roomID];
        if (!set) {
            set = [NSMutableSet set];
            groups[roomID] = set;
        }
        [set addObject:memberID];

        NSMutableArray<NSString *> *sample = samples[roomID];
        if (!sample) {
            sample = [NSMutableArray array];
            samples[roomID] = sample;
        }
        if (sample.count < 6) {
            [sample addObject:memberID];
        }
    }

    if (groups.count == 0) {
        YMLog(@"[GroupExitMonitor] DB apply parsed no valid chatroom members. task=0x%llx vector=0x%lx count=%zu",
              (unsigned long long)task,
              (unsigned long)vectorObject,
              count);
        return @{};
    }

    NSMutableDictionary<NSString *, NSSet<NSString *> *> *result = [NSMutableDictionary dictionary];
    for (NSString *roomID in groups) {
        NSSet<NSString *> *members = [groups[roomID] copy];
        result[roomID] = members;

        YMLog(@"[GroupExitMonitor] DB apply members room=%@ count=%lu vector=0x%lx samples=%@",
              roomID,
              (unsigned long)members.count,
              (unsigned long)vectorObject,
              [samples[roomID] componentsJoinedByString:@", "] ?: @"");
    }

    return [result copy];
}


// 把 roomID 放进昵称预热队列。
// 只入队，不在 DB apply 栈里主动调用微信函数，避免 DB / manager 锁重入。
static void YMGroupExitRequestPreloadRoom(NSString *roomID, NSString *reason) {
    if (!YMIsGroupExitNicknameEnabled()) {
        return;
    }

    if (!YMGroupExitIsChatRoomID(roomID)) {
        return;
    }

    NSMutableDictionary<NSString *, NSDate *> *queue = YMGroupExitPreloadRoomQueue();
    NSDate *now = [NSDate date];

    @synchronized (queue) {
        NSDate *last = queue[roomID];
        // 同一个群短时间内只保留一次预热请求，避免 DB apply 高频刷新时反复调用。
        if (last && [now timeIntervalSinceDate:last] < 30.0) {
            return;
        }

        queue[roomID] = now;

        if (queue.count > 256) {
            NSArray<NSString *> *allKeys = [queue allKeys];
            NSUInteger removeCount = MIN((NSUInteger)64, allKeys.count);
            for (NSUInteger i = 0; i < removeCount; i++) {
                [queue removeObjectForKey:allKeys[i]];
            }
        }
    }

    YMLog(@"[GroupExitMonitor] preload room queued. room=%@ reason=%@",
          roomID ?: @"",
          reason ?: @"");
}

static NSArray<NSString *> *YMGroupExitDrainPreloadRooms(NSUInteger maxCount) {
    NSMutableDictionary<NSString *, NSDate *> *queue = YMGroupExitPreloadRoomQueue();
    NSMutableArray<NSString *> *rooms = [NSMutableArray array];

    @synchronized (queue) {
        if (queue.count == 0) {
            return @[];
        }

        NSArray<NSString *> *allRooms = [queue allKeys];
        NSUInteger count = MIN(maxCount, allRooms.count);
        for (NSUInteger i = 0; i < count; i++) {
            NSString *roomID = allRooms[i];
            if (roomID.length > 0) {
                [rooms addObject:roomID];
                [queue removeObjectForKey:roomID];
            }
        }
    }

    return [rooms copy];
}

static void YMGroupExitCacheMemberDataListFromOutVector(NSString *roomID,
                                                        int64_t *outVector,
                                                        const char *source) {
    if (!YMIsGroupExitNicknameEnabled()) {
        return;
    }

    if (!YMGroupExitIsChatRoomID(roomID) || !outVector) {
        return;
    }

    uintptr_t begin = 0;
    uintptr_t end = 0;
    uintptr_t cap = 0;
    uintptr_t vectorAddress = (uintptr_t)outVector;

    if (!YMSafeReadPointer(vectorAddress + 0, &begin) ||
        !YMSafeReadPointer(vectorAddress + 8, &end) ||
        !YMSafeReadPointer(vectorAddress + 16, &cap)) {
        YMLog(@"[GroupExitMonitor] member data list read vector failed. room=%@ source=%s vector=0x%lx",
              roomID ?: @"",
              source ?: "",
              (unsigned long)vectorAddress);
        return;
    }

    if (begin == 0 || end == 0 || end < begin || cap < end || begin < 0x100000000ULL) {
        YMLog(@"[GroupExitMonitor] member data list invalid vector bounds. room=%@ source=%s begin=0x%lx end=0x%lx cap=0x%lx",
              roomID ?: @"",
              source ?: "",
              (unsigned long)begin,
              (unsigned long)end,
              (unsigned long)cap);
        return;
    }

    const size_t entrySize = 104;
    uintptr_t byteSize = end - begin;
    if (byteSize == 0 || (byteSize % entrySize) != 0) {
        YMLog(@"[GroupExitMonitor] member data list size mismatch. room=%@ source=%s byteSize=%lu begin=0x%lx end=0x%lx",
              roomID ?: @"",
              source ?: "",
              (unsigned long)byteSize,
              (unsigned long)begin,
              (unsigned long)end);
        return;
    }

    size_t count = (size_t)(byteSize / entrySize);
    if (count == 0 || count > 20000) {
        YMLog(@"[GroupExitMonitor] member data list unreasonable count=%zu. room=%@ source=%s",
              count,
              roomID ?: @"",
              source ?: "");
        return;
    }

    NSUInteger cachedCount = 0;
    NSMutableArray<NSString *> *samples = [NSMutableArray array];

    for (size_t i = 0; i < count; i++) {
        uintptr_t entry = begin + i * entrySize;

        // sub_2066288 已确认 104 字节成员 UI 数据结构：
        // entry + 0  = memberID / wxid
        // entry + 24 = displayName / 群成员展示名
        // entry + 48 = extraName / 搜索辅助字段
        NSString *memberID = YMNSStringFromLibcppStringObject((const void *)(entry + 0));
        NSString *displayName = YMNSStringFromLibcppStringObject((const void *)(entry + 24));
        NSString *extraName = YMNSStringFromLibcppStringObject((const void *)(entry + 48));

        if (!YMGroupExitMemberIDLooksUseful(memberID, roomID)) {
            continue;
        }

        NSString *nameToCache = displayName;
        if (!YMGroupExitDisplayNameLooksUseful(nameToCache, memberID) &&
            YMGroupExitDisplayNameLooksUseful(extraName, memberID)) {
            nameToCache = extraName;
        }

        if (!YMGroupExitDisplayNameLooksUseful(nameToCache, memberID)) {
            continue;
        }

        YMGroupExitCacheDisplayName(roomID, memberID, nameToCache, source ?: "GetAllMemberDataList");
        cachedCount++;

        if (samples.count < 6) {
            [samples addObject:[NSString stringWithFormat:@"%@=%@", memberID ?: @"", YMGroupExitTrimDisplayName(nameToCache) ?: @""]];
        }
    }

    if (cachedCount > 0) {
        YMLog(@"[GroupExitMonitor] member display names cached. source=%s room=%@ total=%zu cached=%lu samples=%@",
              source ?: "",
              roomID ?: @"",
              count,
              (unsigned long)cachedCount,
              [samples componentsJoinedByString:@", "] ?: @"");
    } else {
        YMLog(@"[GroupExitMonitor] member data list parsed but no display name cached. source=%s room=%@ total=%zu",
              source ?: "",
              roomID ?: @"",
              count);
    }
}

static void YMGroupExitHandleDBApplySnapshot(NSString *roomID, NSSet<NSString *> *newSnapshot) {
    if (!YMGroupExitIsChatRoomID(roomID) || newSnapshot.count == 0) {
        return;
    }

    NSMutableArray<NSString *> *leftMembers = [NSMutableArray array];
    NSMutableArray<NSString *> *addedMembers = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *cache = YMGroupExitMemberCache();
    NSUInteger oldCount = 0;
    NSUInteger newCount = newSnapshot.count;

    @synchronized (cache) {
        NSSet<NSString *> *oldSnapshot = cache[roomID];

        if (oldSnapshot.count == 0) {
            cache[roomID] = [newSnapshot copy];
            YMLog(@"[GroupExitMonitor] DB first snapshot stored. room=%@ members=%lu",
                  roomID,
                  (unsigned long)newSnapshot.count);
            YMGroupExitRequestPreloadRoom(roomID, @"DB first snapshot");
            return;
        }

        oldCount = oldSnapshot.count;

        if (![oldSnapshot isEqualToSet:newSnapshot]) {
            NSMutableSet<NSString *> *removed = [oldSnapshot mutableCopy];
            [removed minusSet:newSnapshot];

            NSMutableSet<NSString *> *added = [newSnapshot mutableCopy];
            [added minusSet:oldSnapshot];

            for (NSString *memberID in added) {
                if (memberID.length > 0) {
                    [addedMembers addObject:memberID];
                }
            }

            // DB apply 层已经是 chatroom_member 写库任务，直接按 confirmed cache 做 diff。
            // 仍然保留基本安全阈值，避免结构读取异常导致一次性误报大量成员。
            if (removed.count > 0 && newSnapshot.count < oldSnapshot.count && removed.count <= 20 && removed.count < oldSnapshot.count) {
                for (NSString *memberID in removed) {
                    if (memberID.length > 0) {
                        [leftMembers addObject:memberID];
                    }
                }
            } else if (removed.count > 0) {
                YMLog(@"[GroupExitMonitor] DB removed set not treated as exit. room=%@ old=%lu new=%lu removed=%lu added=%lu",
                      roomID,
                      (unsigned long)oldSnapshot.count,
                      (unsigned long)newSnapshot.count,
                      (unsigned long)removed.count,
                      (unsigned long)added.count);
            }
        }

        cache[roomID] = [newSnapshot copy];
    }

    for (NSString *memberID in addedMembers) {
        YMGroupExitClearRecentTip(roomID, memberID, @"member appeared in DB snapshot");
    }

    // 群成员快照发生变化时，顺手重新预热该群昵称。
    // 如果已经捕获到 chatroom_manager 实例，后续安全点会主动刷新成员展示名缓存。
    YMGroupExitRequestPreloadRoom(roomID, leftMembers.count > 0 ? @"DB member left snapshot" : @"DB snapshot updated");

    if (leftMembers.count == 0) {
        YMLog(@"[GroupExitMonitor] DB snapshot updated, no member left. room=%@ old=%lu new=%lu",
              roomID,
              (unsigned long)oldCount,
              (unsigned long)newCount);
        return;
    }

    for (NSString *memberID in leftMembers) {
        NSString *displayName = YMGroupExitDisplayNameForMemberID(memberID, roomID);
        NSString *exitTimeText = YMFormatTimestamp(0, 0);
        NSString *noticeText = [NSString stringWithFormat:@"⚠️苏维埃退群监控⚠️\n@%@ 已退群\n%@",
                                displayName ?: memberID,
                                exitTimeText ?: @""];

        YMLog(@"[GroupExitMonitor] DB member left detected. room=%@ member=%@ old=%lu new=%lu notice=%@",
              roomID,
              memberID,
              (unsigned long)oldCount,
              (unsigned long)newCount,
              noticeText ?: @"");

        YMGroupExitEnqueueNotice(roomID, memberID, noticeText);
    }
}

static void YMGroupExitHandleDBApplySnapshots(NSDictionary<NSString *, NSSet<NSString *> *> *snapshots,
                                              int64_t originalResult) {
    if (snapshots.count == 0) {
        return;
    }

    YMLog(@"[GroupExitMonitor] DB apply original result=0x%llx rooms=%lu",
          (unsigned long long)originalResult,
          (unsigned long)snapshots.count);

    for (NSString *roomID in snapshots) {
        NSSet<NSString *> *members = snapshots[roomID];
        YMGroupExitHandleDBApplySnapshot(roomID, members);
    }
}

static BOOL YMGroupExitInsertLocalSystemNotice(NSString *roomID,
                                               NSString *noticeText,
                                               const char *source) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!profile) {
        YMLog(@"[GroupExitMonitor] insert failed: no active profile, source=%s", source ?: "");
        return NO;
    }

    if (YMWeChatDylibSlide == 0) {
        YMLog(@"[GroupExitMonitor] insert failed: YMWeChatDylibSlide is zero, source=%s", source ?: "");
        return NO;
    }

    if (!YMGroupExitIsChatRoomID(roomID) || noticeText.length == 0) {
        YMLog(@"[GroupExitMonitor] insert failed: invalid room/content. room=%@ source=%s",
              roomID ?: @"",
              source ?: "");
        return NO;
    }

    YMInsertPaySysMsgToSessionFunc InsertPaySysMsgToSession =
    (YMInsertPaySysMsgToSessionFunc)YMRuntimePointer(profile->insertPaySysMsgToSessionVA);

    if (!InsertPaySysMsgToSession) {
        YMLog(@"[GroupExitMonitor] insert failed: InsertPaySysMsgToSession is NULL, source=%s", source ?: "");
        return NO;
    }

    std::string session = YMStdStringFromNSString(roomID);
    std::string content = YMStdStringFromNSString(noticeText);

    if (session.empty() || content.empty()) {
        YMLog(@"[GroupExitMonitor] insert failed: std::string empty. room=%@ source=%s",
              roomID ?: @"",
              source ?: "");
        return NO;
    }

    YMLog(@"[GroupExitMonitor] insert notice source=%s session=%s contentText=%@ contentLen=%zu",
          source ?: "",
          session.c_str(),
          noticeText ?: @"",
          content.size());

    int64_t result = InsertPaySysMsgToSession(0, &session, &content);

    YMLog(@"[GroupExitMonitor] insert notice result=0x%llx source=%s",
          (unsigned long long)result,
          source ?: "");

    return YES;
}

static void YMGroupExitFlushPendingNotices(const char *source) {
    if (YMGroupExitFlushingPending.exchange(true)) {
        return;
    }

    @autoreleasepool {
        std::unique_lock<std::recursive_mutex> stateLock(YMGroupExitStateMutex());
        uint64_t generation = YMGroupExitGeneration.load();
        NSArray<NSDictionary<NSString *, id> *> *items = YMGroupExitDrainPendingNotices(20);
        stateLock.unlock();
        if (items.count == 0) {
            YMGroupExitFlushingPending.store(false);
            return;
        }

        YMLog(@"[GroupExitMonitor] flush pending notices source=%s count=%lu",
              source ?: "",
              (unsigned long)items.count);

        for (NSDictionary<NSString *, id> *item in items) {
            if (!YMIsGroupExitMonitorEnabled() || generation != YMGroupExitGeneration.load()) break;
            NSString *roomID = item[@"roomID"];
            NSString *memberID = item[@"memberID"];
            NSString *noticeText = item[@"noticeText"];

            YMLog(@"[GroupExitMonitor] flush notice. room=%@ member=%@ notice=%@",
                  roomID ?: @"",
                  memberID ?: @"",
                  noticeText ?: @"");

            YMGroupExitInsertLocalSystemNotice(roomID,
                                               noticeText,
                                               source ?: "unknown");
        }
    }

    YMGroupExitFlushingPending.store(false);
}

static void YMGroupExitBuildAbsoluteJump(uintptr_t targetAddress, uint8_t patch[16]) {
    memset(patch, 0, 16);

    uint32_t insnLdrX16 = 0x58000050; // ldr x16, #8
    uint32_t insnBrX16  = 0xD61F0200; // br x16

    memcpy(patch + 0, &insnLdrX16, sizeof(insnLdrX16));
    memcpy(patch + 4, &insnBrX16, sizeof(insnBrX16));
    memcpy(patch + 8, &targetAddress, sizeof(targetAddress));
}

static BOOL YMGroupExitWriteCodeBytes(uintptr_t address,
                                      const uint8_t *bytes,
                                      size_t size,
                                      const char *name,
                                      const char *stage) {
    if (address == 0 || !bytes || size == 0) {
        YMLog(@"[GroupExitMonitor] write code failed: invalid argument, name=%s stage=%s", name ?: "", stage ?: "");
        return NO;
    }

    if (!YMProtectCodePage(address,
                           size,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY,
                           name ?: "group exit hook",
                           stage ?: "RW|COPY")) {
        return NO;
    }

    memcpy((void *)address, bytes, size);
    sys_icache_invalidate((void *)address, size);

    if (!YMProtectCodePage(address,
                           size,
                           VM_PROT_READ | VM_PROT_EXECUTE,
                           name ?: "group exit hook",
                           "RX")) {
        return NO;
    }

    return YES;
}

static BOOL YMGroupExitRestoreOriginalDBApply(void) {
    if (!YMGroupExitDBApplyRuntimeAddress || !YMGroupExitHasSavedOriginalDBApplyBytes) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitDBApplyRuntimeAddress,
                                     YMGroupExitOriginalDBApplyBytes,
                                     sizeof(YMGroupExitOriginalDBApplyBytes),
                                     "group exit DB apply",
                                     "restore original");
}

static BOOL YMGroupExitReapplyDBApplyHook(void) {
    if (!YMGroupExitDBApplyRuntimeAddress) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitDBApplyRuntimeAddress,
                                     YMGroupExitHookDBApplyBytes,
                                     sizeof(YMGroupExitHookDBApplyBytes),
                                     "group exit DB apply",
                                     "reapply hook");
}

static int64_t YMGroupExitCallOriginalDBApply(int64_t task) {
    if (!YMGroupExitDBApplyRuntimeAddress) {
        return 0;
    }

    if (YMGroupExitCallingOriginalDBApply.exchange(true)) {
        YMLog(@"[GroupExitMonitor] recursive original DB apply call suppressed");
        return 0;
    }

    BOOL restored = YMGroupExitRestoreOriginalDBApply();
    if (!restored) {
        YMLog(@"[GroupExitMonitor] restore original DB apply failed, skip calling original to avoid recursion");
        YMGroupExitCallingOriginalDBApply.store(false);
        return 0;
    }

    YMGroupExitDBApplyFunc Original =
    (YMGroupExitDBApplyFunc)YMGroupExitDBApplyRuntimeAddress;

    int64_t result = 0;
    try {
        result = Original(task);
    } catch (...) {
        YMLog(@"[GroupExitMonitor] exception while calling original DB apply");
    }

    YMGroupExitReapplyDBApplyHook();
    YMGroupExitCallingOriginalDBApply.store(false);
    return result;
}

static BOOL YMGroupExitRestoreOriginalFMessagePre(void) {
    if (!YMGroupExitFMessagePreRuntimeAddress || !YMGroupExitHasSavedOriginalFMessagePreBytes) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitFMessagePreRuntimeAddress,
                                     YMGroupExitOriginalFMessagePreBytes,
                                     sizeof(YMGroupExitOriginalFMessagePreBytes),
                                     "group exit fmessage_manager::InsertFMessageToSessionPre",
                                     "restore original");
}

static BOOL YMGroupExitReapplyFMessagePreHook(void) {
    if (!YMGroupExitFMessagePreRuntimeAddress) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitFMessagePreRuntimeAddress,
                                     YMGroupExitHookFMessagePreBytes,
                                     sizeof(YMGroupExitHookFMessagePreBytes),
                                     "group exit fmessage_manager::InsertFMessageToSessionPre",
                                     "reapply hook");
}

static void YMGroupExitCallOriginalFMessagePre(int64_t a1, int64_t *a2) {
    if (!YMGroupExitFMessagePreRuntimeAddress) {
        return;
    }

    if (YMGroupExitCallingOriginalFMessagePre.exchange(true)) {
        YMLog(@"[GroupExitMonitor] recursive original FMessagePre call suppressed");
        return;
    }

    BOOL restored = YMGroupExitRestoreOriginalFMessagePre();
    if (!restored) {
        YMLog(@"[GroupExitMonitor] restore original FMessagePre failed, skip calling original to avoid recursion");
        YMGroupExitCallingOriginalFMessagePre.store(false);
        return;
    }

    YMGroupExitFMessagePreFunc Original =
    (YMGroupExitFMessagePreFunc)YMGroupExitFMessagePreRuntimeAddress;

    try {
        Original(a1, a2);
    } catch (...) {
        YMLog(@"[GroupExitMonitor] exception while calling original InsertFMessageToSessionPre");
    }

    YMGroupExitReapplyFMessagePreHook();
    YMGroupExitCallingOriginalFMessagePre.store(false);
}

static BOOL YMGroupExitRestoreOriginalUpdateSessionCache(void) {
    if (!YMGroupExitUpdateSessionCacheRuntimeAddress || !YMGroupExitHasSavedOriginalUpdateSessionCacheBytes) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitUpdateSessionCacheRuntimeAddress,
                                     YMGroupExitOriginalUpdateSessionCacheBytes,
                                     sizeof(YMGroupExitOriginalUpdateSessionCacheBytes),
                                     "group exit session_service::UpdateSessionCache",
                                     "restore original");
}

static BOOL YMGroupExitReapplyUpdateSessionCacheHook(void) {
    if (!YMGroupExitUpdateSessionCacheRuntimeAddress) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitUpdateSessionCacheRuntimeAddress,
                                     YMGroupExitHookUpdateSessionCacheBytes,
                                     sizeof(YMGroupExitHookUpdateSessionCacheBytes),
                                     "group exit session_service::UpdateSessionCache",
                                     "reapply hook");
}

static void YMGroupExitCallOriginalUpdateSessionCache(uint64_t a1, int64_t a2, int64_t a3, int a4) {
    if (!YMGroupExitUpdateSessionCacheRuntimeAddress) {
        return;
    }

    if (YMGroupExitCallingOriginalUpdateSessionCache.exchange(true)) {
        YMLog(@"[GroupExitMonitor] recursive original UpdateSessionCache call suppressed");
        return;
    }

    BOOL restored = YMGroupExitRestoreOriginalUpdateSessionCache();
    if (!restored) {
        YMLog(@"[GroupExitMonitor] restore original UpdateSessionCache failed, skip calling original to avoid recursion");
        YMGroupExitCallingOriginalUpdateSessionCache.store(false);
        return;
    }

    YMGroupExitUpdateSessionCacheFunc Original =
    (YMGroupExitUpdateSessionCacheFunc)YMGroupExitUpdateSessionCacheRuntimeAddress;

    try {
        Original(a1, a2, a3, a4);
    } catch (...) {
        YMLog(@"[GroupExitMonitor] exception while calling original UpdateSessionCache");
    }

    YMGroupExitReapplyUpdateSessionCacheHook();
    YMGroupExitCallingOriginalUpdateSessionCache.store(false);
}


static BOOL YMGroupExitRestoreOriginalChatroomInfoOperator(void) {
    if (!YMGroupExitChatroomInfoOperatorRuntimeAddress || !YMGroupExitHasSavedOriginalChatroomInfoOperatorBytes) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitChatroomInfoOperatorRuntimeAddress,
                                     YMGroupExitOriginalChatroomInfoOperatorBytes,
                                     sizeof(YMGroupExitOriginalChatroomInfoOperatorBytes),
                                     "group exit chatroom_manager::operator GetChatroomInfo",
                                     "restore original");
}

static BOOL YMGroupExitReapplyChatroomInfoOperatorHook(void) {
    if (!YMGroupExitChatroomInfoOperatorRuntimeAddress) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitChatroomInfoOperatorRuntimeAddress,
                                     YMGroupExitHookChatroomInfoOperatorBytes,
                                     sizeof(YMGroupExitHookChatroomInfoOperatorBytes),
                                     "group exit chatroom_manager::operator GetChatroomInfo",
                                     "reapply hook");
}

static void YMGroupExitCallOriginalChatroomInfoOperator(int64_t a1) {
    if (!YMGroupExitChatroomInfoOperatorRuntimeAddress) {
        return;
    }

    if (YMGroupExitCallingOriginalChatroomInfoOperator.exchange(true)) {
        YMLog(@"[GroupExitMonitor] recursive original chatroom_manager operator call suppressed");
        return;
    }

    BOOL restored = YMGroupExitRestoreOriginalChatroomInfoOperator();
    if (!restored) {
        YMLog(@"[GroupExitMonitor] restore original chatroom_manager operator failed, skip calling original to avoid recursion");
        YMGroupExitCallingOriginalChatroomInfoOperator.store(false);
        return;
    }

    YMGroupExitChatroomInfoOperatorFunc Original =
    (YMGroupExitChatroomInfoOperatorFunc)YMGroupExitChatroomInfoOperatorRuntimeAddress;

    try {
        Original(a1);
    } catch (...) {
        YMLog(@"[GroupExitMonitor] exception while calling original chatroom_manager operator");
    }

    YMGroupExitReapplyChatroomInfoOperatorHook();
    YMGroupExitCallingOriginalChatroomInfoOperator.store(false);
}


static BOOL YMGroupExitRestoreOriginalMemberDataList(void) {
    if (!YMGroupExitMemberDataListRuntimeAddress || !YMGroupExitHasSavedOriginalMemberDataListBytes) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitMemberDataListRuntimeAddress,
                                     YMGroupExitOriginalMemberDataListBytes,
                                     sizeof(YMGroupExitOriginalMemberDataListBytes),
                                     "group exit chatroom_manager::GetAllMemberDataList",
                                     "restore original");
}

static BOOL YMGroupExitReapplyMemberDataListHook(void) {
    if (!YMGroupExitMemberDataListRuntimeAddress) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMGroupExitMemberDataListRuntimeAddress,
                                     YMGroupExitHookMemberDataListBytes,
                                     sizeof(YMGroupExitHookMemberDataListBytes),
                                     "group exit chatroom_manager::GetAllMemberDataList",
                                     "reapply hook");
}

static int64_t YMGroupExitCallOriginalMemberDataList(int64_t a1, int64_t *roomID, int64_t *outVector) {
    if (!YMGroupExitMemberDataListRuntimeAddress) {
        return 0;
    }

    if (YMGroupExitCallingOriginalMemberDataList.exchange(true)) {
        YMLog(@"[GroupExitMonitor] recursive original GetAllMemberDataList call suppressed");
        return 0;
    }

    BOOL restored = YMGroupExitRestoreOriginalMemberDataList();
    if (!restored) {
        YMLog(@"[GroupExitMonitor] restore original GetAllMemberDataList failed, skip calling original to avoid recursion");
        YMGroupExitCallingOriginalMemberDataList.store(false);
        return 0;
    }

    YMGroupExitMemberDataListFunc Original =
    (YMGroupExitMemberDataListFunc)YMGroupExitMemberDataListRuntimeAddress;

    int64_t result = 0;
    try {
        result = Original(a1, roomID, outVector);
    } catch (...) {
        YMLog(@"[GroupExitMonitor] exception while calling original GetAllMemberDataList");
    }

    YMGroupExitReapplyMemberDataListHook();
    YMGroupExitCallingOriginalMemberDataList.store(false);
    return result;
}

static void YMGroupExitDestroyLibcppStringObjectAt(uintptr_t stringObjectAddress) {
    if (stringObjectAddress == 0) {
        return;
    }

    uint8_t *object = (uint8_t *)stringObjectAddress;
    int8_t flag = *(int8_t *)(object + 23);

    if (flag < 0) {
        void *data = *(void **)object;
        if (data) {
            operator delete(data);
        }
    }

    memset(object, 0, 24);
}

static void YMGroupExitDestroyMemberDataListVector(int64_t *outVector) {
    if (!outVector) {
        return;
    }

    uintptr_t begin = (uintptr_t)outVector[0];
    uintptr_t end = (uintptr_t)outVector[1];
    uintptr_t cap = (uintptr_t)outVector[2];

    outVector[0] = 0;
    outVector[1] = 0;
    outVector[2] = 0;

    if (begin == 0 || end == 0 || end < begin || cap < end) {
        return;
    }

    const size_t entrySize = 104;
    uintptr_t byteSize = end - begin;
    if (byteSize == 0 || (byteSize % entrySize) != 0 || byteSize > 104ULL * 20000ULL) {
        return;
    }

    for (uintptr_t entry = begin; entry < end; entry += entrySize) {
        YMGroupExitDestroyLibcppStringObjectAt(entry + 0);
        YMGroupExitDestroyLibcppStringObjectAt(entry + 24);
        YMGroupExitDestroyLibcppStringObjectAt(entry + 48);
    }

    operator delete((void *)begin);
}

static void YMGroupExitPreloadMemberDataListForRoom(int64_t manager, NSString *roomID, const char *source, uint64_t generation) {
    if (generation != YMGroupExitNicknameGeneration.load()) return;
    if (!YMIsGroupExitNicknameEnabled() || manager == 0 || !YMGroupExitIsChatRoomID(roomID)) {
        return;
    }

    std::string room = YMStdStringFromNSString(roomID);
    if (room.empty()) {
        return;
    }

    /*
     修复堆的破话导致闪退
     */
    std::vector<YMGroupExitChatroomMemberUIData> members;

    YMLog(@"[GroupExitMonitor] preload member data list start. source=%s room=%@ manager=0x%llx",
          source ?: "",
          roomID ?: @"",
          (unsigned long long)manager);

    int64_t result = YMGroupExitCallOriginalMemberDataList(manager,
                                                           (int64_t *)&room,
                                                           (int64_t *)&members);

    uintptr_t begin = members.empty() ? 0 : (uintptr_t)members.data();
    uintptr_t end = begin + members.size() * sizeof(YMGroupExitChatroomMemberUIData);
    uintptr_t cap = begin + members.capacity() * sizeof(YMGroupExitChatroomMemberUIData);

    YMLog(@"[GroupExitMonitor] preload member data list original result=0x%llx. source=%s room=%@ begin=0x%llx end=0x%llx count=%lu capacity=%lu",
          (unsigned long long)result,
          source ?: "",
          roomID ?: @"",
          (unsigned long long)begin,
          (unsigned long long)end,
          (unsigned long)members.size(),
          (unsigned long)members.capacity());

    std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
    if (generation != YMGroupExitNicknameGeneration.load()) return;
    if (result != 0 && begin != 0 && members.size() > 0 && members.size() <= 20000) {
        int64_t vectorView[3] = {
            (int64_t)begin,
            (int64_t)end,
            (int64_t)cap
        };

        YMGroupExitCacheMemberDataListFromOutVector(roomID,
                                                    vectorView,
                                                    source ?: "preload GetAllMemberDataList");
    } else {
        YMLog(@"[GroupExitMonitor] preload member data list skip cache. source=%s room=%@ result=0x%llx count=%lu",
              source ?: "",
              roomID ?: @"",
              (unsigned long long)result,
              (unsigned long)members.size());
    }

    // 不再手动 destroy vector。members 离开作用域时自动析构。
    YMLog(@"[GroupExitMonitor] preload member data list finish. source=%s room=%@",
          source ?: "",
          roomID ?: @"");
}

static void YMGroupExitFlushPreloadRooms(const char *source) {
    if (!YMIsGroupExitNicknameEnabled()) {
        (void)source;
        return;
    }

    if (YMGroupExitCallingOriginalChatroomInfoOperator.load()) {
        YMLog(@"[GroupExitMonitor] preload deferred inside chatroom_manager operator. source=%s",
              source ?: "");
        return;
    }

    if (YMGroupExitPreloadingMemberDataList.exchange(true)) {
        return;
    }

    YMGroupExitAtomicBoolResetGuard preloadGuard(&YMGroupExitPreloadingMemberDataList);

    @autoreleasepool {
        std::unique_lock<std::recursive_mutex> stateLock(YMGroupExitStateMutex());
        uint64_t generation = YMGroupExitNicknameGeneration.load();
        int64_t manager = YMGroupExitKnownChatroomManager.load();
        if (manager == 0 || !YMGroupExitMemberDataListRuntimeAddress) {
            NSMutableDictionary<NSString *, NSDate *> *queue = YMGroupExitPreloadRoomQueue();
            NSUInteger count = 0;
            @synchronized (queue) {
                count = queue.count;
            }
            if (count > 0) {
                YMLog(@"[GroupExitMonitor] preload pending but chatroom_manager is unknown. source=%s pending=%lu",
                      source ?: "",
                      (unsigned long)count);
            }
            return;
        }

        // 每次安全点只处理 1 个群，避免一次 fmessage/session 回调里连续扫多个大群。
        NSArray<NSString *> *rooms = YMGroupExitDrainPreloadRooms(1);
        if (rooms.count == 0) {
            return;
        }

        YMLog(@"[GroupExitMonitor] flush preload rooms. source=%s count=%lu manager=0x%llx",
              source ?: "",
              (unsigned long)rooms.count,
              (unsigned long long)manager);

        stateLock.unlock();
        for (NSString *roomID in rooms) {
            if (!YMGroupExitIsChatRoomID(roomID)) {
                continue;
            }

            YMGroupExitPreloadMemberDataListForRoom(manager, roomID, source ?: "flush preload rooms", generation);
        }
    }
}

static void YMGroupExitCaptureChatroomManagerFromOperatorContext(int64_t context, const char *source) {
    std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
    if (!YMIsGroupExitNicknameEnabled() || context == 0) {
        return;
    }

    uintptr_t manager = 0;
    if (!YMSafeReadPointer((uintptr_t)context + 8, &manager)) {
        return;
    }

    if (manager == 0 || manager < 0x100000000ULL) {
        return;
    }

    NSString *roomID = YMNSStringFromLibcppStringObject((const void *)((uintptr_t)context + 16));
    if (!YMGroupExitIsChatRoomID(roomID)) {
        return;
    }

    int64_t oldManager = YMGroupExitKnownChatroomManager.exchange((int64_t)manager);
    if (oldManager != (int64_t)manager) {
        YMLog(@"[GroupExitMonitor] chatroom_manager captured early. source=%s old=0x%llx new=0x%llx room=%@",
              source ?: "",
              (unsigned long long)oldManager,
              (unsigned long long)manager,
              roomID ?: @"");
    }

    YMGroupExitRequestPreloadRoom(roomID, @"chatroom_manager operator captured");
}

static void YMGroupExitChatroomInfoOperatorHook(int64_t a1) {
    @autoreleasepool {
        if (!YMIsGroupExitNicknameEnabled()) {
            YMGroupExitCallOriginalChatroomInfoOperator(a1);
            return;
        }

        /*
         只 hook sub_21249D4 这一处早期 operator：
           a1 + 8  = chatroom_manager
           a1 + 16 = 当前 roomID std::string
         这里不做退群判断，也不直接插消息，只提前捕获 manager 并把当前群加入预热队列。
         */
        YMGroupExitCaptureChatroomManagerFromOperatorContext(a1, "chatroom_manager operator GetChatroomInfo");

        YMGroupExitCallOriginalChatroomInfoOperator(a1);

        // 这个 operator 本身就是微信处理群信息的异步回调，原函数返回后尝试消费预热队列。
        YMGroupExitFlushPreloadRooms("chatroom_manager operator GetChatroomInfo");
    }
}

static int64_t YMGroupExitMemberDataListHook(int64_t a1, int64_t *roomID, int64_t *outVector) {
    @autoreleasepool {
        if (!YMIsGroupExitNicknameEnabled()) {
            return YMGroupExitCallOriginalMemberDataList(a1, roomID, outVector);
        }

        uint64_t generation = YMGroupExitNicknameGeneration.load();
        int64_t result = YMGroupExitCallOriginalMemberDataList(a1, roomID, outVector);
        std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
        if (!YMIsGroupExitNicknameEnabled() || generation != YMGroupExitNicknameGeneration.load()) return result;
        if (a1 != 0) YMGroupExitKnownChatroomManager.store(a1);

        NSString *roomIDText = YMNSStringFromLibcppStringObject((const void *)roomID);
        YMGroupExitCacheMemberDataListFromOutVector(roomIDText,
                                                    outVector,
                                                    "chatroom_manager GetAllMemberDataList");

        // 这里只缓存微信自己这次 GetAllMemberDataList 的结果。
        // 不在 GetAllMemberDataList hook 内继续主动 preload 其它群，避免同 manager 重入。
        return result;
    }
}

static int64_t YMGroupExitDBApplyHook(int64_t task) {
    @autoreleasepool {
        if (!YMIsGroupExitMonitorEnabled()) {
            YMGroupExitClearRuntimeStateIfDisabled("DB apply hook");
            return YMGroupExitCallOriginalDBApply(task);
        }

        uint64_t generation = YMGroupExitGeneration.load();
        NSDictionary<NSString *, NSSet<NSString *> *> *snapshots = YMGroupExitReadSnapshotsFromDBApplyTask(task);

        int64_t result = YMGroupExitCallOriginalDBApply(task);

        std::lock_guard<std::recursive_mutex> lock(YMGroupExitStateMutex());
        if (YMIsGroupExitMonitorEnabled() && generation == YMGroupExitGeneration.load()) {
            YMGroupExitHandleDBApplySnapshots(snapshots, result);
        } else {
            YMGroupExitClearRuntimeStateIfDisabled("DB apply hook after original");
        }

        return result;
    }
}

static void YMGroupExitFMessagePreHook(int64_t a1, int64_t *a2) {
    @autoreleasepool {
        YMGroupExitCallOriginalFMessagePre(a1, a2);

        if (YMIsGroupExitMonitorEnabled()) {
            YMGroupExitFlushPreloadRooms("fmessage_manager InsertFMessageToSessionPre");
            YMGroupExitFlushPendingNotices("fmessage_manager InsertFMessageToSessionPre");
        } else {
            YMGroupExitClearRuntimeStateIfDisabled("fmessage_manager InsertFMessageToSessionPre");
        }
    }
}

static void YMGroupExitUpdateSessionCacheHook(uint64_t a1, int64_t a2, int64_t a3, int a4) {
    @autoreleasepool {
        YMGroupExitCallOriginalUpdateSessionCache(a1, a2, a3, a4);

        if (YMIsGroupExitNicknameEnabled()) {
            YMGroupExitFlushPreloadRooms("session_service UpdateSessionCache");
            YMGroupExitFlushPendingNotices("session_service UpdateSessionCache");
        } else if (!YMIsGroupExitMonitorEnabled()) {
            YMGroupExitClearRuntimeStateIfDisabled("session_service UpdateSessionCache");
        }
    }
}

static BOOL YMPatchGroupExitSingleFunction(uintptr_t targetAddress,
                                           uintptr_t hookAddress,
                                           uint8_t originalBytes[16],
                                           uint8_t hookBytes[16],
                                           BOOL *hasSavedOriginalBytes,
                                           uintptr_t *runtimeAddressStorage,
                                           const char *name,
                                           NSString *source) {
    if (targetAddress == 0 || hookAddress == 0 || !originalBytes || !hookBytes || !hasSavedOriginalBytes || !runtimeAddressStorage) {
        YMLog(@"[GroupExitMonitor] invalid single hook argument: %s", name ?: "");
        return NO;
    }

    *runtimeAddressStorage = targetAddress;
    YMGroupExitBuildAbsoluteJump(hookAddress, hookBytes);

    uint8_t current[16] = {0};
    memcpy(current, (void *)targetAddress, sizeof(current));

    if (memcmp(current, hookBytes, sizeof(current)) == 0) {
        YMLog(@"[GroupExitMonitor] %s already hooked, address=0x%lx source=%@",
              name ?: "",
              (unsigned long)targetAddress,
              source ?: @"");
        *hasSavedOriginalBytes = YES;
        return YES;
    }

    memcpy(originalBytes, current, sizeof(current));
    *hasSavedOriginalBytes = YES;

    BOOL ok = YMGroupExitWriteCodeBytes(targetAddress,
                                        hookBytes,
                                        16,
                                        name ?: "group exit hook",
                                        "install hook");

    YMLog(@"[GroupExitMonitor] hook result=%@ name=%s source=%@ target=0x%lx hook=0x%lx",
          ok ? @"OK" : @"FAIL",
          name ?: "",
          source ?: @"",
          (unsigned long)targetAddress,
          (unsigned long)hookAddress);

    return ok;
}

static BOOL YMPatchGroupExitMonitorWithSlide(intptr_t slide, NSString *source) {
    if (YMHasPatchedGroupExitMonitor) {
        YMLog(@"[GroupExitMonitor] already patched, skip. source=%@", source);
        return YES;
    }

    YMRecordWeChatDylibSlide(slide, source ?: @"group exit patch");

    if (!YMIsTargetWeChatVersion()) {
        YMLog(@"[GroupExitMonitor] unsupported WeChat version, skip. source=%@", source);
        return NO;
    }

    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!YMGroupExitProfileReady(profile)) {
        YMLog(@"[GroupExitMonitor] current profile has no group exit addresses, skip but keep slide/profile for debugging. profile=%s slide=0x%lx",
              profile ? profile->displayName : "NULL",
              (unsigned long)YMWeChatDylibSlide);
        return NO;
    }

    uintptr_t dbApplyTarget = YMRuntimeAddress(profile->groupExitDBApplyVA);
    uintptr_t fmessagePreTarget = YMRuntimeAddress(profile->groupExitFMessagePreVA);
    BOOL nicknameEnabled = YMIsGroupExitNicknameEnabled();
    BOOL updateSessionCacheHookEnabled = nicknameEnabled;
    BOOL nicknamePreloadHookEnabled = nicknameEnabled;

    uintptr_t updateSessionCacheTarget = updateSessionCacheHookEnabled ? YMRuntimeAddress(profile->groupExitUpdateSessionCacheVA) : 0;
    uintptr_t memberDataListTarget = nicknamePreloadHookEnabled ? YMRuntimeAddress(profile->groupExitMemberDataListVA) : 0;
    uintptr_t chatroomInfoOperatorTarget = nicknamePreloadHookEnabled ? YMRuntimeAddress(profile->groupExitChatroomInfoOperatorVA) : 0;

    uintptr_t dbApplyHook = (uintptr_t)&YMGroupExitDBApplyHook;
    uintptr_t fmessagePreHook = (uintptr_t)&YMGroupExitFMessagePreHook;
    uintptr_t updateSessionCacheHook = (uintptr_t)&YMGroupExitUpdateSessionCacheHook;
    uintptr_t memberDataListHook = (uintptr_t)&YMGroupExitMemberDataListHook;
    uintptr_t chatroomInfoOperatorHook = (uintptr_t)&YMGroupExitChatroomInfoOperatorHook;

    BOOL okDBApply = YMPatchGroupExitSingleFunction(dbApplyTarget,
                                                   dbApplyHook,
                                                   YMGroupExitOriginalDBApplyBytes,
                                                   YMGroupExitHookDBApplyBytes,
                                                   &YMGroupExitHasSavedOriginalDBApplyBytes,
                                                   &YMGroupExitDBApplyRuntimeAddress,
                                                   "group exit contact_storage chatroom_member DB apply",
                                                   source);

    BOOL okFMessagePre = YMPatchGroupExitSingleFunction(fmessagePreTarget,
                                                       fmessagePreHook,
                                                       YMGroupExitOriginalFMessagePreBytes,
                                                       YMGroupExitHookFMessagePreBytes,
                                                       &YMGroupExitHasSavedOriginalFMessagePreBytes,
                                                       &YMGroupExitFMessagePreRuntimeAddress,
                                                       "group exit fmessage_manager::InsertFMessageToSessionPre",
                                                       source);

    BOOL okUpdateSessionCache = YES;
    if (updateSessionCacheHookEnabled && updateSessionCacheTarget != 0) {
        okUpdateSessionCache = YMPatchGroupExitSingleFunction(updateSessionCacheTarget,
                                                             updateSessionCacheHook,
                                                             YMGroupExitOriginalUpdateSessionCacheBytes,
                                                             YMGroupExitHookUpdateSessionCacheBytes,
                                                             &YMGroupExitHasSavedOriginalUpdateSessionCacheBytes,
                                                             &YMGroupExitUpdateSessionCacheRuntimeAddress,
                                                             "group exit session_service::UpdateSessionCache",
                                                             source);
    } else {
        YMLog(@"[GroupExitMonitor] UpdateSessionCache nickname safe point skipped. nickname=%@ profile=%s",
              nicknameEnabled ? @"ON" : @"OFF",
              profile ? profile->displayName : "NULL");
    }

    BOOL okMemberDataList = YES;
    if (nicknamePreloadHookEnabled && memberDataListTarget != 0) {
        okMemberDataList = YMPatchGroupExitSingleFunction(memberDataListTarget,
                                                          memberDataListHook,
                                                          YMGroupExitOriginalMemberDataListBytes,
                                                          YMGroupExitHookMemberDataListBytes,
                                                          &YMGroupExitHasSavedOriginalMemberDataListBytes,
                                                          &YMGroupExitMemberDataListRuntimeAddress,
                                                          "group exit chatroom_manager::GetAllMemberDataList",
                                                          source);
    } else {
        YMLog(@"[GroupExitMonitor] GetAllMemberDataList nickname hook skipped. nickname=%@ profile=%s",
              nicknameEnabled ? @"ON" : @"OFF",
              profile ? profile->displayName : "NULL");
    }

    BOOL okChatroomInfoOperator = YES;
    if (nicknamePreloadHookEnabled && chatroomInfoOperatorTarget != 0) {
        okChatroomInfoOperator = YMPatchGroupExitSingleFunction(chatroomInfoOperatorTarget,
                                                                chatroomInfoOperatorHook,
                                                                YMGroupExitOriginalChatroomInfoOperatorBytes,
                                                                YMGroupExitHookChatroomInfoOperatorBytes,
                                                                &YMGroupExitHasSavedOriginalChatroomInfoOperatorBytes,
                                                                &YMGroupExitChatroomInfoOperatorRuntimeAddress,
                                                                "group exit chatroom_manager::operator GetChatroomInfo",
                                                                source);
    } else {
        YMLog(@"[GroupExitMonitor] chatroom_manager operator nickname hook skipped. nickname=%@ profile=%s",
              nicknameEnabled ? @"ON" : @"OFF",
              profile ? profile->displayName : "NULL");
    }

    BOOL ok = okDBApply && okFMessagePre && okUpdateSessionCache && okMemberDataList && okChatroomInfoOperator;

    YMLog(@"[GroupExitMonitor] patch result=%@ source=%@ profile=%s nickname=%@ slide=0x%lx DBApply=0x%lx FMessagePre=0x%lx UpdateSessionCache=0x%lx MemberDataList=0x%lx ChatroomInfoOperator=0x%lx",
          ok ? @"OK" : @"FAIL",
          source ?: @"",
          profile->displayName,
          nicknameEnabled ? @"ON" : @"OFF",
          (unsigned long)YMWeChatDylibSlide,
          (unsigned long)dbApplyTarget,
          (unsigned long)fmessagePreTarget,
          (unsigned long)updateSessionCacheTarget,
          (unsigned long)memberDataListTarget,
          (unsigned long)chatroomInfoOperatorTarget);

    YMHasPatchedGroupExitMonitor = ok;
    YMHasPatchedGroupExitNickname = ok && nicknameEnabled;
    return ok;
}

static BOOL YMFindAndPatchLoadedGroupExitWeChatDylib(void) {
    uint32_t count = _dyld_image_count();

    YMLog(@"[GroupExitMonitor] scan dyld images, count=%u", count);

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) {
            continue;
        }

        NSString *imagePath = [NSString stringWithUTF8String:name];

        if (!YMIsTargetWeChatResourceDylibPath(imagePath)) {
            continue;
        }

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        YMLog(@"[GroupExitMonitor] found Resources/wechat.dylib: index=%u, slide=0x%lx, path=%@",
              i,
              (unsigned long)slide,
              imagePath);

        YMRecordWeChatDylibSlide(slide, @"group exit dyld image scan");
        return YMPatchGroupExitMonitorWithSlide(slide, @"dyld image scan");
    }

    YMLog(@"[GroupExitMonitor] Resources/wechat.dylib not found");
    return NO;
}

static void YMInstallGroupExitMonitorPatch(void) {
    if (YMHasPatchedGroupExitMonitor) {
        return;
    }

    YMRegisterDyldCallbackIfNeeded();
    YMFindAndPatchLoadedGroupExitWeChatDylib();
}




#pragma mark - 撤回原消息局部 Callsite Hook（4.1.10）

/*
fileOffset=0x2b70954 level=2 file=message_revoke_manager.cc func=CoReplaceOriginMessageByRevoke line=1069 ctx=0x1753bfd88 做撤回,
fileOffset=0x281a0f4 level=2 file=message_manager.cc func=GetMessageBySvrIdOnRecent line=2435 ctx=0x1753bfb58  这里面的函数去调用拿到原始MessageWrap
  sub_4247180(&v148);
   sub_1382484(v147, v148);
   sub_211A334(v139, *(_QWORD *)v147);
   sub_2819F44(__dst, v139[0], v137 + 392, *((_QWORD *)v137 + 45));//不要去直接去碰sub_2819F44这个函数,要去碰他的地址:
   __text:0000000002B7123C                 ADD             X1, X9, #0x188
 __text:0000000002B71240                 BL              sub_2819F44
 __text:0000000002B71244                 LDR             X22, [SP,#0x920+var_650+8]//碰这个指令
 __text:0000000002B71248                 CBZ             X22, loc_2B71274
 __text:0000000002B7124C                 ADD             X8, X22, #8
 __text:0000000002B71250                 MOV             X9, #0xFFFFFFFFFFFFFFFF

 [YMAntiRevoke] [WXLOG] fileOffset=0x2814cb4 level=2 file=message_manager.cc func=DeleteMessages line=2155
 */

// 地址放到 YMWeChatAdaptProfile 里了，后面适配新版别满文件乱搜。

extern "C" uintptr_t YMRevokeOriginCallsiteContinueAddress;
extern "C" uintptr_t YMRevokeOriginCallsiteZeroBranchAddress;
extern "C" uintptr_t YMRevokeOriginCallsiteCheckAddress;
extern "C" uintptr_t YMRevokeOriginCallsiteModeValue;
extern "C" void YMRevokeOriginCallsiteHelper(uintptr_t originalSP, uintptr_t savedRegs);
extern "C" void YMRevokeOriginCallsiteStub(void);

uintptr_t YMRevokeOriginCallsiteContinueAddress = 0;
uintptr_t YMRevokeOriginCallsiteZeroBranchAddress = 0;
uintptr_t YMRevokeOriginCallsiteCheckAddress = 0;
uintptr_t YMRevokeOriginCallsiteModeValue = YMRevokeOriginCallsiteModeLegacy410;

static size_t YMRevokeOriginOutWrapStackOffset = 0x18;
static size_t YMRevokeOriginExtObjectStackOffset = 0x2C0;

static uintptr_t YMRevokeDeleteMessagesRuntimeAddress = 0;
static uint8_t YMRevokeDeleteMessagesOriginalBytes[16] = {0};
static uint8_t YMRevokeDeleteMessagesHookBytes[16] = {0};
static BOOL YMRevokeDeleteMessagesHasSavedOriginalBytes = NO;
static std::atomic_bool YMRevokeDeleteMessagesCallingOriginal(false);

static __thread BOOL YMRevokeDeleteGuardActive = NO;
// svrId 去重集合，动态增长匹配实际撤回条数
static __thread std::set<uint64_t> *YMRevokeSeenSvrIds = nullptr;
static __thread uint64_t YMRevokeTargetSvrIdForDeleteGuard = 0;

static NSString *YMRevokeMessageTypeName(uint32_t type) {
    switch (type) {
        case 1: return @"[文本消息]";
        case 3: return @"[图片消息]";
        case 34: return @"[语音消息]";
        case 43: return @"[视频消息]";
        case 47: return @"[表情包]";
        case 48: return @"[位置消息]";
        case 49: return @"[卡片/文件/链接消息]";
        case 10000: return @"[10000（系统消息]";
        case 10002: return @"[10002（系统通知]";
        default: return [NSString stringWithFormat:@"%u", type];
    }
}

static BOOL YMRevokeMessageTypeLooksKnown(uint32_t type) {
    switch (type) {
        case 1:
        case 3:
        case 34:
        case 43:
        case 47:
        case 48:
        case 49:
        case 10000:
        case 10002:
            return YES;
        default:
            return NO;
    }
}

static BOOL YMRevokeMessageTypeShouldShowContent(uint32_t type) {
    return type == 1;
}

static BOOL YMRevokeOriginTextLooksUseless(NSString *text) {
    if (text.length == 0) {
        return NO;
    }

    return [text containsString:@"暂不支持该内容"] ||
           [text containsString:@"请在手机上查看"];
}

static NSString *YMRevokeShortLogText(NSString *text) {
    if (text.length == 0) {
        return @"";
    }

    if (text.length > 300) {
        return [[text substringToIndex:300] stringByAppendingString:@"…"];
    }

    return text;
}

static NSString *YMCleanOriginMessageContent(NSString *rawContent, NSString **senderOut) {
    if (senderOut) {
        *senderOut = @"";
    }

    if (rawContent.length == 0) {
        return @"";
    }

    NSString *text = [rawContent stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";

    // 群聊文本常见格式：wxid_xxx:\n内容。展示时把前缀拆出来。
    NSRange colonNewline = [text rangeOfString:@":\n"];
    if (colonNewline.location != NSNotFound && colonNewline.location > 0) {
        NSString *prefix = [text substringToIndex:colonNewline.location] ?: @"";
        NSString *body = [text substringFromIndex:NSMaxRange(colonNewline)] ?: @"";
        prefix = [prefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (prefix.length > 0 && senderOut) {
            *senderOut = prefix;
        }
        if (body.length > 0) {
            return body;
        }
    }

    return text;
}


static BOOL YMRevokeXMLMatchesSvrId(NSString *revokeXML, uint64_t expectedSvrId) {
    if (revokeXML.length == 0) {
        return NO;
    }

    if (expectedSvrId == 0) {
        return YES;
    }

    NSString *newMsgID = YMExtractXMLTagValue(revokeXML, @"newmsgid");
    if (newMsgID.length == 0) {
        newMsgID = YMExtractXMLTagValue(revokeXML, @"newsvrid");
    }
    if (newMsgID.length == 0) {
        return YES;
    }

    uint64_t xmlSvrId = strtoull(newMsgID.UTF8String ?: "", NULL, 10);
    return xmlSvrId == expectedSvrId;
}

static BOOL YMExtractRevokeContextFromWrap(uintptr_t wrap,
                                           uint64_t expectedSvrId,
                                           NSString **xmlOut,
                                           NSString **revokerWxidOut,
                                           NSString **displayNameOut,
                                           NSString **replaceMsgOut,
                                           NSString **msgIDOut,
                                           NSString **newMsgIDOut) {
    if (wrap == 0) {
        return NO;
    }

    NSString *xml = YMFindRevokeXMLFromRawWrap((void *)wrap, 616);
    if (xml.length == 0 || !YMRevokeXMLMatchesSvrId(xml, expectedSvrId)) {
        return NO;
    }

    NSString *replaceMsg = YMExtractXMLTagValue(xml, @"replacemsg");
    NSString *displayName = YMDisplayNameFromRevokeReplaceMsg(replaceMsg);
    NSString *msgID = YMExtractXMLTagValue(xml, @"msgid");
    NSString *newMsgID = YMExtractXMLTagValue(xml, @"newmsgid");
    if (newMsgID.length == 0) {
        newMsgID = YMExtractXMLTagValue(xml, @"newsvrid");
    }

    NSString *revokerWxid = YMNSStringFromLibcppStringObject((const void *)(wrap + 72));
    if (revokerWxid.length == 0) {
        revokerWxid = YMRevokerWxidFromRevokeXMLPrefix(xml);
    }

    if (xmlOut) *xmlOut = xml ?: @"";
    if (revokerWxidOut) *revokerWxidOut = revokerWxid ?: @"";
    if (displayNameOut) *displayNameOut = displayName ?: @"";
    if (replaceMsgOut) *replaceMsgOut = replaceMsg ?: @"";
    if (msgIDOut) *msgIDOut = msgID ?: @"";
    if (newMsgIDOut) *newMsgIDOut = newMsgID ?: @"";
    return YES;
}

static BOOL YMFindRevokeContextAroundCallsite(uintptr_t originalSP,
                                              uintptr_t savedRegs,
                                              uint64_t expectedSvrId,
                                              uintptr_t *wrapOut,
                                              NSString **xmlOut,
                                              NSString **revokerWxidOut,
                                              NSString **displayNameOut,
                                              NSString **replaceMsgOut,
                                              NSString **msgIDOut,
                                              NSString **newMsgIDOut) {
    // 先扫被 stub 保存下来的寄存器。a2/revoke rawWrap 很可能还在某个 callee-saved 寄存器里。
    if (savedRegs != 0) {
        for (int reg = 0; reg <= 29; reg++) {
            uintptr_t candidate = 0;
            if (!YMSafeReadPointer(savedRegs + (uintptr_t)reg * sizeof(uintptr_t), &candidate)) {
                continue;
            }
            if (candidate == 0 || (candidate & 0x7) != 0) {
                continue;
            }

            if (YMExtractRevokeContextFromWrap(candidate,
                                               expectedSvrId,
                                               xmlOut,
                                               revokerWxidOut,
                                               displayNameOut,
                                               replaceMsgOut,
                                               msgIDOut,
                                               newMsgIDOut)) {
                if (wrapOut) *wrapOut = candidate;
                YMLog(@"[RevokeCallsite] revoke context found from saved x%d rawWrap=0x%lx", reg, (unsigned long)candidate);
                return YES;
            }
        }
    }

    // 再扫当前 sub_2B707E0 栈帧里的指针槽。
    if (originalSP != 0) {
        for (uintptr_t offset = 0; offset < 0x920; offset += sizeof(uintptr_t)) {
            uintptr_t candidate = 0;
            if (!YMSafeReadPointer(originalSP + offset, &candidate)) {
                continue;
            }
            if (candidate == 0 || (candidate & 0x7) != 0) {
                continue;
            }

            if (YMExtractRevokeContextFromWrap(candidate,
                                               expectedSvrId,
                                               xmlOut,
                                               revokerWxidOut,
                                               displayNameOut,
                                               replaceMsgOut,
                                               msgIDOut,
                                               newMsgIDOut)) {
                if (wrapOut) *wrapOut = candidate;
                YMLog(@"[RevokeCallsite] revoke context found from stack pointer slot +0x%lx rawWrap=0x%lx", (unsigned long)offset, (unsigned long)candidate);
                return YES;
            }
        }

        // 最后扫栈上是否有直接内嵌的 MessageWrap 副本。
        for (uintptr_t offset = 0; offset + 616 <= 0x920; offset += 8) {
            uintptr_t candidate = originalSP + offset;
            if (YMExtractRevokeContextFromWrap(candidate,
                                               expectedSvrId,
                                               xmlOut,
                                               revokerWxidOut,
                                               displayNameOut,
                                               replaceMsgOut,
                                               msgIDOut,
                                               newMsgIDOut)) {
                if (wrapOut) *wrapOut = candidate;
                YMLog(@"[RevokeCallsite] revoke context found from stack inline wrap +0x%lx rawWrap=0x%lx", (unsigned long)offset, (unsigned long)candidate);
                return YES;
            }
        }
    }

    return NO;
}

// 本人与他人的撤回提示共用格式化；引用人名称可读取本地联系人备注。
static NSString *YMBuildDetailedAntiRevokeNotice(uint32_t originType,
                                                NSString *originRawContent,
                                                uint64_t originCreateTimeMs,
                                                uint32_t originCreateTimeSec,
                                                NSString *revokerWxid,
                                                NSString *revokerDisplayName,
                                                BOOL preserveContent) {
    NSString *sender = @"";
    NSString *cleanContent = @"";
    BOOL textReply = NO;
    NSString *quote = YMQuotedReplyText(originRawContent, originType, &textReply);
    BOOL shouldShowContent = quote != nil || YMRevokeMessageTypeShouldShowContent(originType);

    if (shouldShowContent) {
        cleanContent = quote ?: (preserveContent ? (originRawContent ?: @"") : YMCleanOriginMessageContent(originRawContent, &sender));
        if (!quote && !preserveContent && YMRevokeOriginTextLooksUseless(cleanContent)) {
            shouldShowContent = NO;
            cleanContent = @"";
            sender = @"";
        }
    }

    NSString *timeText = YMFormatTimestamp(originCreateTimeSec, originCreateTimeMs);

    NSMutableString *notice = [NSMutableString string];
    [notice appendString:@"⚠️苏维埃已拦截撤回消息⚠️\n"];
    [notice appendFormat:@"%@\n", YMRevokeMessageTypeName(textReply ? 1 : originType)];

    if (shouldShowContent) {
        if (cleanContent.length > 0) {
            if (cleanContent.length > 1200) {
                NSUInteger end = [cleanContent rangeOfComposedCharacterSequenceAtIndex:1200].location;
                cleanContent = [[cleanContent substringToIndex:end] stringByAppendingString:@"…"];
            }
            [notice appendFormat:@"内容：%@\n", cleanContent];
        } else {
            [notice appendString:@"内容：（空）\n"];
        }
    }

    if (revokerDisplayName.length > 0 && revokerWxid.length > 0) {
        [notice appendFormat:@"%@（%@）\n", revokerDisplayName, revokerWxid];
    } else if (revokerDisplayName.length > 0) {
        [notice appendFormat:@"%@\n", revokerDisplayName];
    } else if (revokerWxid.length > 0) {
        [notice appendFormat:@"%@\n", revokerWxid];
    }
    
    if (timeText.length > 0) {
        [notice appendString:timeText];
    }

    return notice;
}

static BOOL YMInsertDetailedAntiRevokeNoticeFromOrigin(std::string *sessionString,
                                                       NSString *sessionText,
                                                       uint64_t svrId,
                                                       uint32_t originType,
                                                       NSString *originRawContent,
                                                       uint64_t originCreateTimeMs,
                                                       uint32_t originCreateTimeSec,
                                                       NSString *revokerWxid,
                                                       NSString *revokerDisplayName,
                                                       NSString *replaceMsg,
                                                       NSString *msgID,
                                                       NSString *newMsgID) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!profile || YMWeChatDylibSlide == 0 || !sessionString || sessionString->empty()) {
        YMLog(@"[RevokeCallsite] insert detailed notice failed: invalid profile/slide/session");
        return NO;
    }

    YMInsertPaySysMsgToSessionFunc InsertPaySysMsgToSession =
    (YMInsertPaySysMsgToSessionFunc)YMRuntimePointer(profile->insertPaySysMsgToSessionVA);

    if (!InsertPaySysMsgToSession) {
        YMLog(@"[RevokeCallsite] insert detailed notice failed: InsertPaySysMsgToSession is null");
        return NO;
    }

    NSString *notice = YMBuildDetailedAntiRevokeNotice(originType, originRawContent,
        originCreateTimeMs, originCreateTimeSec, revokerWxid, revokerDisplayName, NO);

    std::string content = YMStdStringFromNSString(notice);

    YMLog(@"[RevokeCallsite] insert detailed notice session=%s content=%s",
          sessionString->c_str(),
          content.c_str());

    int64_t result = 0;
    try {
        result = InsertPaySysMsgToSession(0, sessionString, &content);
    } catch (...) {
        YMLog(@"[RevokeCallsite] exception while inserting detailed notice");
        return NO;
    }

    YMLog(@"[RevokeCallsite] insert detailed notice result=0x%llx", (unsigned long long)result);
    return YES;
}

NSString *YMBuildSelfRevokeNotice(uintptr_t originalWrap, uintptr_t revokeExt) {
    if (!originalWrap || !YMIsOwnRevokeWrap(originalWrap)) return nil;
    uint32_t type = 0, createTimeSec = 0;
    uint64_t createTimeMs = 0;
    if (!YMSafeReadMemory(originalWrap + 0x0C, &type, sizeof(type)) ||
        !YMSafeReadMemory(originalWrap + 0x114, &createTimeSec, sizeof(createTimeSec)) ||
        !YMSafeReadMemory(originalWrap + 0x100, &createTimeMs, sizeof(createTimeMs))) return nil;
    NSString *account = YMSelfRevokeAccount();
    if (!account.length) return nil;
    // This is the live original Wrap held by the revoke coroutine. Reuse the
    // native string reader so long messages still produce the existing 1200-char summary.
    NSString *content = YMNSStringFromLibcppStringObject((const void *)(originalWrap + 0x130), 262144);
    if (!content) return nil;
    NSString *replaceMsg = revokeExt ? YMNSStringFromLibcppStringObject((const void *)(revokeExt + 0x170)) : @"";
    NSString *displayName = YMDisplayNameFromRevokeReplaceMsg(replaceMsg);
    if (!displayName.length) displayName = @"你";
    return YMBuildDetailedAntiRevokeNotice(type, content, createTimeMs, createTimeSec,
                                          account, displayName, YES);
}

NSString *YMSelfRevokeWrapIdentity(uintptr_t wrap) {
    if (!wrap || !YMIsOwnRevokeWrap(wrap)) return nil;
    uint64_t serverID = 0;
    uint32_t localID = 0;
    if (!YMSafeReadMemory(wrap + 0xF8, &serverID, sizeof(serverID)) ||
        !YMSafeReadMemory(wrap + 0xF4, &localID, sizeof(localID))) return nil;
    return YMSelfRevokeIdentity(YMSelfRevokeAccount(), YMSelfRevokeSession(wrap), serverID, localID);
}

bool YMWasSelfRevokeNoticeInserted(NSString *identity) {
    return YMSelfRevokeNoticeLocalID(NSUserDefaults.standardUserDefaults, identity) != 0;
}

void YMRecordRetainedSelfRevoke(NSString *identity, uint32_t noticeLocalId) {
    // identity 已在事件开始通过当前账号验证，并由事件持有；异步完成不改归属。
    YMRecordSelfRevoke(NSUserDefaults.standardUserDefaults, identity, noticeLocalId);
}

uint64_t YMRetainedSelfRevokeOriginalID(uintptr_t systemWrap) {
    uint64_t serverID = 0;
    uint32_t localID = 0, type = 0;
    uintptr_t ext = 0;
    if (!systemWrap ||
        !YMSafeReadMemory(systemWrap + 0xF8, &serverID, sizeof(serverID)) || serverID != 0 ||
        !YMSafeReadMemory(systemWrap + 0xF4, &localID, sizeof(localID)) || !localID ||
        !YMSafeReadMemory(systemWrap + 0x0C, &type, sizeof(type)) || type != 10000 ||
        !YMSafeReadPointer(systemWrap + 0x210, &ext) || !ext ||
        ![YMNSStringFromLibcppStringObject((void *)(ext + 0x148)) isEqualToString:@"revokemsg"]) return 0;
    // 原生重建提示 XML 不包含原消息 ID；以持久化提示身份关联，不能读 ext+0x168。
    return YMSelfRevokeOriginalID(NSUserDefaults.standardUserDefaults, YMSelfRevokeAccount(),
                                  YMSelfRevokeSession(systemWrap), localID);
}

bool YMIsSelfRevokeNotice(uintptr_t systemWrap) {
    return YMRetainedSelfRevokeOriginalID(systemWrap) != 0;
}

BOOL YMIsRetainedSelfMessage(uintptr_t messageData) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!messageData || !profile || strcmp(profile->buildVersion, "269079") != 0) return NO;
    uint64_t serverID = 0;
    uint32_t localID = 0;
    if (!YMSafeReadMemory(messageData + 0x90, &serverID, sizeof(serverID)) ||
        !YMSafeReadMemory(messageData + 0x74, &localID, sizeof(localID))) return NO;
    NSString *sender = YMNSStringFromLibcppStringObject((void *)(messageData + 0x10));
    NSString *session = YMNSStringFromLibcppStringObject((void *)(messageData + 0x58));
    if (![sender isEqualToString:YMSelfRevokeAccount()]) return NO;
    // 记录时已通过原生当前账号谓词；sender 是这条本人原消息的账号身份。
    return YMHasSelfRevoke(NSUserDefaults.standardUserDefaults,
                          YMSelfRevokeIdentity(sender, session, serverID, localID));
}

extern "C" void YMRevokeOriginCallsiteHelper(uintptr_t originalSP, uintptr_t savedRegs) {
    @autoreleasepool {
        const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
        const BOOL supportedSelf = profile && strcmp(profile->buildVersion, "269079") == 0;
        const YMRevokeSettings policy = YMReadRevokeSettings(NSUserDefaults.standardUserDefaults);
        if (!(supportedSelf ? policy.enabled : YMIsAntiRevokeEnabled())) {
            YMRevokeDeleteGuardActive = NO;
            YMRevokeTargetSvrIdForDeleteGuard = 0;
            delete YMRevokeSeenSvrIds; YMRevokeSeenSvrIds = nullptr;
            return;
        }
        const size_t dstOffset = YMRevokeOriginOutWrapStackOffset != 0 ? YMRevokeOriginOutWrapStackOffset : 0x18;
        const size_t extObjectSlotOffset = YMRevokeOriginExtObjectStackOffset != 0 ? YMRevokeOriginExtObjectStackOffset : 0x2C0;

        uintptr_t outWrap = originalSP + dstOffset;
        uintptr_t extObject = 0;
        YMSafeReadPointer(originalSP + extObjectSlotOffset, &extObject);

        uint8_t hasValue = 0;
        YMSafeReadMemory(outWrap + 616, &hasValue, sizeof(hasValue));

        YMLog(@"[RevokeCallsite] after GetMessageBySvrId originalSP=0x%lx outWrap=0x%lx dstOff=0x%lx has=%u ext=0x%lx extOff=0x%lx",
              (unsigned long)originalSP,
              (unsigned long)outWrap,
              (unsigned long)dstOffset,
              (unsigned int)hasValue,
              (unsigned long)extObject,
              (unsigned long)extObjectSlotOffset);

        if (extObject == 0 || hasValue == 0) {
            return;
        }

        // 账号尚不可用时不把未知身份归到他人策略。
        NSString *account = supportedSelf ? YMSelfRevokeAccount() : nil;
        if (supportedSelf && !account.length) return;
        const BOOL own = supportedSelf && YMIsOwnRevokeWrap(outWrap);
        const BOOL forward = YMRevokeRealSendForwardEnabled() &&
            (!supportedSelf || (policy.forward && (own ? policy.self && policy.forwardSelf
                                                       : policy.others && policy.forwardOthers)));
        if (supportedSelf) {
            if (own) {
                const BOOL retain = policy.self || YMHasSelfRevoke(NSUserDefaults.standardUserDefaults,
                                                                   YMSelfRevokeWrapIdentity(outWrap));
                if (!YMPrepareSelfRevoke(originalSP, retain)) {
                    // 不允许注册失败后销毁用户要求保留的原消息。
                    if (retain) *((volatile uint8_t *)(outWrap + 616)) = 0;
                    YMLog(@"[SelfRevoke] event unavailable; retain=%d native reedit not guaranteed", retain);
                    return;
                }
                if (!forward) return;
            } else if (!policy.others) {
                return;
            }
        }

        uint64_t svrId = 0;
        YMSafeReadMemory(extObject + 360, &svrId, sizeof(svrId));

        std::string *sessionString = (std::string *)(extObject + 392);
        NSString *sessionText = YMNSStringFromLibcppStringObject((const void *)(extObject + 392));

        uint32_t originType = 0;
        uint32_t originType12 = 0;
        uint32_t originType264 = 0;
        uint64_t originCreateTimeMs = 0;
        uint32_t originCreateTimeSec = 0;
        YMSafeReadMemory(outWrap + 12, &originType12, sizeof(originType12));
        YMSafeReadMemory(outWrap + 264, &originType264, sizeof(originType264));
        YMSafeReadMemory(outWrap + 256, &originCreateTimeMs, sizeof(originCreateTimeMs));
        YMSafeReadMemory(outWrap + 276, &originCreateTimeSec, sizeof(originCreateTimeSec));

        // 4.1.10 多数情况下 +264 可用；4.1.11 的 Hex-Rays 伪代码里出现过
        // HIDWORD(__dst[0].words[1]) == 10000，也就是 +12。
        // 所以这里做兼容：优先使用看起来像常见消息类型的值。
        if (YMRevokeMessageTypeLooksKnown(originType264)) {
            originType = originType264;
        } else if (YMRevokeMessageTypeLooksKnown(originType12)) {
            originType = originType12;
        } else {
            originType = originType264 != 0 ? originType264 : originType12;
        }

        NSString *originContent = YMNSStringFromLibcppStringObject((const void *)(outWrap + 304), 262144);
        NSString *originMsgSource = YMNSStringFromLibcppStringObject((const void *)(outWrap + 352));
        NSString *originContentLog = YMRevokeMessageTypeShouldShowContent(originType) ? YMRevokeShortLogText(originContent) : @"<非文本，不展开>";
        NSString *originMsgSourceLog = YMRevokeShortLogText(originMsgSource);

        YMLog(@"[RevokeCallsite] origin captured session=%@ svrId=%llu type=%@ type12=%u type264=%u content=%@ msgSource=%@",
              sessionText ?: @"",
              (unsigned long long)svrId,
              YMRevokeMessageTypeName(originType),
              originType12,
              originType264,
              originContentLog ?: @"",
              originMsgSourceLog ?: @"");

        NSString *revokeXML = @"";
        NSString *revokerWxid = @"";
        NSString *revokerDisplayName = @"";
        NSString *replaceMsg = @"";
        NSString *msgID = @"";
        NSString *newMsgID = @"";
        uintptr_t revokeWrap = 0;
        BOOL foundRevokeContext = YMFindRevokeContextAroundCallsite(originalSP,
                                                                    savedRegs,
                                                                    svrId,
                                                                    &revokeWrap,
                                                                    &revokeXML,
                                                                    &revokerWxid,
                                                                    &revokerDisplayName,
                                                                    &replaceMsg,
                                                                    &msgID,
                                                                    &newMsgID);

        YMLog(@"[RevokeCallsite] revoke context found=%d rawWrap=0x%lx revoker=%@ displayName=%@ replace=%@ msgid=%@ newmsgid=%@ xml=%@",
              foundRevokeContext ? 1 : 0,
              (unsigned long)revokeWrap,
              revokerWxid ?: @"",
              revokerDisplayName ?: @"",
              replaceMsg ?: @"",
              msgID ?: @"",
              newMsgID ?: @"",
              revokeXML ?: @"");

        bool alreadySeen = false;
        if (supportedSelf) {
            static NSMutableSet<NSString *> *seen;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
            uint32_t localID = 0;
            YMSafeReadMemory(outWrap + 0xF4, &localID, sizeof(localID));
            NSString *identity = YMSelfRevokeIdentity(YMSelfRevokeAccount(), sessionText, svrId, localID);
            if (!identity) return;
            @synchronized(seen) {
                alreadySeen = [seen containsObject:identity];
                [seen addObject:identity];
            }
        } else {
            if (!YMRevokeSeenSvrIds) YMRevokeSeenSvrIds = new std::set<uint64_t>();
            alreadySeen = YMRevokeSeenSvrIds->count(svrId) > 0;
            YMRevokeSeenSvrIds->insert(svrId);
        }
        if (!alreadySeen) {
            if (forward) {
                NSString *forwardSelfUserText = account ?: @"";
                const YMWeChatAdaptProfile *forwardProfile = YMGetActiveProfile();
                size_t forwardSelfUserOffset = forwardProfile ? forwardProfile->layout.selfUserOffset : 48;

                // 已适配版本使用登录账号；撤回事件中的方向字段可能是群或对方。
                if (!supportedSelf && revokeWrap != 0) {
                    forwardSelfUserText = YMNSStringFromLibcppStringObject((const void *)(revokeWrap + forwardSelfUserOffset));
                }

                YMLog(@"[RevokeCallsite] forward to self explicit selfUser=%@ revokeWrap=0x%lx session=%@ revoker=%@ displayName=%@",
                      forwardSelfUserText ?: @"",
                      (unsigned long)revokeWrap,
                      sessionText ?: @"",
                      revokerWxid ?: @"",
                      revokerDisplayName ?: @"");

                // 按版本发送本人通知及支持的原媒体；下面的会话内撤回提示是独立的本地插入。
                YMForwardToSelfSend(outWrap,
                                    originType,
                                    originContent,
                                    sessionText ?: @"",
                                    forwardSelfUserText ?: @"",
                                    revokerWxid,
                                    revokerDisplayName);
            }
            if (!own) YMInsertDetailedAntiRevokeNoticeFromOrigin(sessionString,
                                                       sessionText,
                                                       svrId,
                                                       originType,
                                                       originContent,
                                                       originCreateTimeMs,
                                                       originCreateTimeSec,
                                                       revokerWxid,
                                                       revokerDisplayName,
                                                       replaceMsg,
                                                       msgID,
                                                       newMsgID.length > 0 ? newMsgID : [NSString stringWithFormat:@"%llu", (unsigned long long)svrId]);
        } else {
            YMLog(@"[RevokeCallsite] same svrId already inserted, skip duplicate notice. svrId=%llu",
                  (unsigned long long)svrId);
        }

        if (own) return; // 本人路径只由已冻结的原生删除/替换策略控制。

        // 他人防撤回继续沿用现有本地提示与保留路径。
        *((volatile uint8_t *)(outWrap + 616)) = 0;
        YMLog(@"[RevokeCallsite] clear local origin optional flag to prevent current UI revoke replacement");
    }
}



#if defined(__aarch64__)
__asm__(
".text\n"
".align 2\n"
".globl _YMRevokeOriginCallsiteStub\n"
"_YMRevokeOriginCallsiteStub:\n"
"    sub sp, sp, #0x100\n"
"    stp x0,  x1,  [sp, #0x00]\n"
"    stp x2,  x3,  [sp, #0x10]\n"
"    stp x4,  x5,  [sp, #0x20]\n"
"    stp x6,  x7,  [sp, #0x30]\n"
"    stp x8,  x9,  [sp, #0x40]\n"
"    stp x10, x11, [sp, #0x50]\n"
"    stp x12, x13, [sp, #0x60]\n"
"    stp x14, x15, [sp, #0x70]\n"
"    stp x16, x17, [sp, #0x80]\n"
"    stp x18, x19, [sp, #0x90]\n"
"    stp x20, x21, [sp, #0xA0]\n"
"    stp x22, x23, [sp, #0xB0]\n"
"    stp x24, x25, [sp, #0xC0]\n"
"    stp x26, x27, [sp, #0xD0]\n"
"    stp x28, x29, [sp, #0xE0]\n"
"    str x30,      [sp, #0xF0]\n"
"    add x0, sp, #0x100\n"        // x0 = 原 sub_2B707E0 的 SP
"    mov x1, sp\n"               // x1 = 当前保存寄存器的区域，给 helper 扫描 raw revoke wrap
"    bl _YMRevokeOriginCallsiteHelper\n"
"    ldp x0,  x1,  [sp, #0x00]\n"
"    ldp x2,  x3,  [sp, #0x10]\n"
"    ldp x4,  x5,  [sp, #0x20]\n"
"    ldp x6,  x7,  [sp, #0x30]\n"
"    ldp x8,  x9,  [sp, #0x40]\n"
"    ldp x10, x11, [sp, #0x50]\n"
"    ldp x12, x13, [sp, #0x60]\n"
"    ldp x14, x15, [sp, #0x70]\n"
"    ldp x16, x17, [sp, #0x80]\n"
"    ldp x18, x19, [sp, #0x90]\n"
"    ldp x20, x21, [sp, #0xA0]\n"
"    ldp x22, x23, [sp, #0xB0]\n"
"    ldp x24, x25, [sp, #0xC0]\n"
"    ldp x26, x27, [sp, #0xD0]\n"
"    ldp x28, x29, [sp, #0xE0]\n"
"    ldr x30,      [sp, #0xF0]\n"
"    add sp, sp, #0x100\n"

// 根据版本分支还原被覆盖的 4 条指令。
//
// 4.1.10.53：
//   0x2B71244 LDR X22, [SP,#0x2D8]
//   0x2B71248 CBZ X22, zero
//   0x2B7124C ADD X8, X22, #8
//   0x2B71250 MOV X9, #-1
//
// 4.1.11.23：
//   0x2BBAA40 ADD X1, SP, #0x298
//   0x2BBAA44 MOV X0, X20
//   0x2BBAA48 BL  sub_2BB9EC8
//   0x2BBAA4C CBZ W0, loc_2BBAC8C
"    adrp x16, _YMRevokeOriginCallsiteModeValue@PAGE\n"
"    ldr  x16, [x16, _YMRevokeOriginCallsiteModeValue@PAGEOFF]\n"
"    cmp  x16, #1\n"
"    b.eq L_YMRevokeCallsiteV411\n"

// 4.1.10 legacy branch
"    ldr x22, [sp, #0x2D8]\n"
"    cbz x22, L_YMRevokeCallsiteZero\n"
"    add x8, x22, #8\n"
"    mov x9, #-1\n"
"    b L_YMRevokeCallsiteContinue\n"

// 4.1.11 branch
"L_YMRevokeCallsiteV411:\n"
"    add x1, sp, #0x298\n"
"    mov x0, x20\n"
"    adrp x16, _YMRevokeOriginCallsiteCheckAddress@PAGE\n"
"    ldr  x16, [x16, _YMRevokeOriginCallsiteCheckAddress@PAGEOFF]\n"
"    cbz  x16, L_YMRevokeCallsiteZero\n"
"    blr  x16\n"
"    cbnz w0, L_YMRevokeCallsiteZero\n"

"L_YMRevokeCallsiteContinue:\n"
"    adrp x16, _YMRevokeOriginCallsiteContinueAddress@PAGE\n"
"    ldr  x16, [x16, _YMRevokeOriginCallsiteContinueAddress@PAGEOFF]\n"
"    br x16\n"
"L_YMRevokeCallsiteZero:\n"
"    adrp x16, _YMRevokeOriginCallsiteZeroBranchAddress@PAGE\n"
"    ldr  x16, [x16, _YMRevokeOriginCallsiteZeroBranchAddress@PAGEOFF]\n"
"    br x16\n"
);

#endif

#pragma mark - 撤回 DeleteMessages Guard

typedef int64_t (*YMDeleteMessagesFunc)(int64_t manager, std::string *session, int64_t *messageVector, int flag);

static BOOL YMRevokeRestoreOriginalDeleteMessages(void) {
    if (!YMRevokeDeleteMessagesRuntimeAddress || !YMRevokeDeleteMessagesHasSavedOriginalBytes) {
        return NO;
    }
    return YMGroupExitWriteCodeBytes(YMRevokeDeleteMessagesRuntimeAddress,
                                     YMRevokeDeleteMessagesOriginalBytes,
                                     sizeof(YMRevokeDeleteMessagesOriginalBytes),
                                     "revoke DeleteMessages",
                                     "restore original");
}

static BOOL YMRevokeReapplyDeleteMessagesHook(void) {
    if (!YMRevokeDeleteMessagesRuntimeAddress) {
        return NO;
    }
    return YMGroupExitWriteCodeBytes(YMRevokeDeleteMessagesRuntimeAddress,
                                     YMRevokeDeleteMessagesHookBytes,
                                     sizeof(YMRevokeDeleteMessagesHookBytes),
                                     "revoke DeleteMessages",
                                     "reapply hook");
}

static int64_t YMRevokeCallOriginalDeleteMessages(int64_t manager, std::string *session, int64_t *messageVector, int flag) {
    if (!YMRevokeDeleteMessagesRuntimeAddress) {
        return 0;
    }

    if (YMRevokeDeleteMessagesCallingOriginal.exchange(true)) {
        YMLog(@"[RevokeCallsite] recursive DeleteMessages original call suppressed");
        return 0;
    }

    BOOL restored = YMRevokeRestoreOriginalDeleteMessages();
    if (!restored) {
        YMLog(@"[RevokeCallsite] restore original DeleteMessages failed");
        YMRevokeDeleteMessagesCallingOriginal.store(false);
        return 0;
    }

    YMDeleteMessagesFunc Original = (YMDeleteMessagesFunc)YMRevokeDeleteMessagesRuntimeAddress;
    int64_t result = 0;
    try {
        result = Original(manager, session, messageVector, flag);
    } catch (...) {
        YMLog(@"[RevokeCallsite] exception while calling original DeleteMessages");
    }

    YMRevokeReapplyDeleteMessagesHook();
    YMRevokeDeleteMessagesCallingOriginal.store(false);
    return result;
}

static int64_t YMRevokeDeleteMessagesHook(int64_t manager, std::string *session, int64_t *messageVector, int flag) {
    @autoreleasepool {
        NSString *sessionText = YMNSStringFromLibcppStringObject(session);

        uint64_t count = 0;
        if (messageVector) {
            uint64_t begin = (uint64_t)messageVector[0];
            uint64_t end = (uint64_t)messageVector[1];
            if (end >= begin && begin != 0) {
                count = (end - begin) / 616;
            }
        }

        if (YMIsAntiRevokeEnabled() && YMRevokeDeleteGuardActive) {
            YMLog(@"[RevokeCallsite] skip DeleteMessages inside revoke manager=0x%llx session=%@ count=%llu flag=%d targetSvrId=%llu",
                  (unsigned long long)manager,
                  sessionText ?: @"",
                  (unsigned long long)count,
                  flag,
                  (unsigned long long)YMRevokeTargetSvrIdForDeleteGuard);

            YMRevokeDeleteGuardActive = NO;
            YMRevokeTargetSvrIdForDeleteGuard = 0;
            delete YMRevokeSeenSvrIds; YMRevokeSeenSvrIds = nullptr;

            // 伪装删除成功，避免上层重试或卡同步。
            return 1;
        }

        YMRevokeDeleteGuardActive = NO;
        YMRevokeTargetSvrIdForDeleteGuard = 0;
        delete YMRevokeSeenSvrIds; YMRevokeSeenSvrIds = nullptr;
        return YMRevokeCallOriginalDeleteMessages(manager, session, messageVector, flag);
    }
}


static BOOL YMPatchRevokeDeleteMessagesGuard(uintptr_t slide,
                                             const YMWeChatAdaptProfile *profile) {
    if (!profile || profile->revokeDeleteMessagesVA == 0) {
        YMLog(@"[RevokeCallsite] DeleteMessages hook skipped: no address in profile");
        return YES;
    }

    YMRevokeDeleteMessagesRuntimeAddress = slide + profile->revokeDeleteMessagesVA;

    if (!YMRevokeDeleteMessagesHasSavedOriginalBytes) {
        memcpy(YMRevokeDeleteMessagesOriginalBytes,
               (const void *)YMRevokeDeleteMessagesRuntimeAddress,
               sizeof(YMRevokeDeleteMessagesOriginalBytes));

        YMGroupExitBuildAbsoluteJump((uintptr_t)&YMRevokeDeleteMessagesHook,
                                     YMRevokeDeleteMessagesHookBytes);

        YMRevokeDeleteMessagesHasSavedOriginalBytes = YES;
    }

    BOOL ok = YMPatchARM64AbsoluteJump(YMRevokeDeleteMessagesRuntimeAddress,
                                       (uintptr_t)&YMRevokeDeleteMessagesHook,
                                       "revoke DeleteMessages guard");

    YMLog(@"[RevokeCallsite] DeleteMessages guard install result=%@ address=0x%lx",
          ok ? @"OK" : @"FAIL",
          (unsigned long)YMRevokeDeleteMessagesRuntimeAddress);

    return ok;
}


static BOOL YMPatchRevokeLocalCallsiteOnly(uintptr_t slide, NSString *source) {
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!profile) {
        YMLog(@"[RevokeCallsite] install failed: no active profile");
        return NO;
    }

    if (profile->revokeOriginCallsiteAfterQueryVA == 0 ||
        profile->revokeOriginCallsiteContinueVA == 0 ||
        profile->revokeOriginCallsiteZeroBranchVA == 0 ||
        profile->revokeOriginOutWrapStackOffset == 0 ||
        profile->revokeOriginExtObjectStackOffset == 0 ||
        (profile->revokeOriginCallsiteMode == YMRevokeOriginCallsiteModeV411 && profile->revokeOriginCallsiteCheckVA == 0)) {
        YMLog(@"[RevokeCallsite] install failed: profile has incomplete revoke callsite address, profile=%s",
              profile->displayName);
        return NO;
    }

    const BOOL nativeSelf = strcmp(profile->buildVersion, "269079") == 0;
    if (nativeSelf) return YMInstallSelfRevokePatch();

    uintptr_t callsite = slide + profile->revokeOriginCallsiteAfterQueryVA;

    YMRevokeOriginCallsiteContinueAddress = slide + profile->revokeOriginCallsiteContinueVA;
    YMRevokeOriginCallsiteZeroBranchAddress = slide + profile->revokeOriginCallsiteZeroBranchVA;
    YMRevokeOriginCallsiteCheckAddress = profile->revokeOriginCallsiteCheckVA ? slide + profile->revokeOriginCallsiteCheckVA : 0;
    YMRevokeOriginCallsiteModeValue = profile->revokeOriginCallsiteMode;
    YMRevokeOriginOutWrapStackOffset = profile->revokeOriginOutWrapStackOffset != 0 ? profile->revokeOriginOutWrapStackOffset : 0x18;
    YMRevokeOriginExtObjectStackOffset = profile->revokeOriginExtObjectStackOffset != 0 ? profile->revokeOriginExtObjectStackOffset : 0x2C0;

    YMLog(@"[RevokeCallsite] install local callsite only source=%@ profile=%s callsite=0x%lx continue=0x%lx zero=0x%lx check=0x%lx mode=%lu outOff=0x%lx extOff=0x%lx delete=0x%lx",
          source ?: @"",
          profile->displayName,
          (unsigned long)callsite,
          (unsigned long)YMRevokeOriginCallsiteContinueAddress,
          (unsigned long)YMRevokeOriginCallsiteZeroBranchAddress,
          (unsigned long)YMRevokeOriginCallsiteCheckAddress,
          (unsigned long)YMRevokeOriginCallsiteModeValue,
          (unsigned long)YMRevokeOriginOutWrapStackOffset,
          (unsigned long)YMRevokeOriginExtObjectStackOffset,
          (unsigned long)(profile->revokeDeleteMessagesVA ? slide + profile->revokeDeleteMessagesVA : 0));

    BOOL okCallsite = YMPatchARM64AbsoluteJump(callsite,
                                               (uintptr_t)&YMRevokeOriginCallsiteStub,
                                               "revoke origin local callsite after GetMessageBySvrId");

    BOOL okDeleteGuard = YMPatchRevokeDeleteMessagesGuard(slide, profile);

    YMLog(@"[RevokeCallsite] install result callsite=%@ deleteGuard=%@",
          okCallsite ? @"OK" : @"FAIL",
          okDeleteGuard ? @"OK" : @"FAIL");

    return okCallsite && okDeleteGuard;
}

#pragma mark - 撤回入口 Hook

/*
 这个函数会被 off_91EAD20 热补丁指针调用。

 原函数签名：
   int64_t ym_HandleSysMsg_RevokeMsg(int64_t a1, int64_t a2)

 做两件事：
   1. 自己插入一条本地 type=10000 系统消息
   2. return 1，告诉上层这个 sysmsg 已经处理，阻止微信原始撤回逻辑继续执行
 */
static int64_t YMHandleSysMsgRevokeMsgHook(int64_t a1, int64_t a2) {
    YMLog(@"intercepted revoke message, a1=0x%llx, a2=0x%llx",
          (unsigned long long)a1,
          (unsigned long long)a2);

    BOOL inserted = YMInsertLocalAntiRevokeNotice(a2);

    YMLog(@"insert local anti revoke notice result=%d", inserted ? 1 : 0);

    return 1;
}

#pragma mark - 安装 Patch

static BOOL YMPatchAntiRevokeWithSlide(intptr_t slide, NSString *source) {
    if (YMHasPatchedAntiRevoke) {
        YMLog(@"already installed, skip. source=%@", source);
        return YES;
    }

    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!profile) {
        YMRecordWeChatDylibSlide(slide, @"anti revoke patch no active profile");
        YMLog(@"no active profile, skip patch");
        return NO;
    }

    YMRecordWeChatDylibSlide(slide, source ?: @"anti revoke patch");

    if (!YMProfileHasAntiRevokeAddresses(profile)) {
        YMLog(@"anti revoke profile addresses incomplete, skip patch but keep slide/profile for debugging. profile=%s slide=0x%lx",
              profile->displayName,
              (unsigned long)YMWeChatDylibSlide);
        return NO;
    }

    uintptr_t pointerAddress = YMRuntimeAddress(profile->hookPointerVA);
    uintptr_t hookAddress = (uintptr_t)&YMHandleSysMsgRevokeMsgHook;

    YMLog(@"try install revoke hook from %@, profile=%s, slide=0x%lx, pointer=0x%lx, hook=0x%lx",
          source,
          profile->displayName,
          (unsigned long)YMWeChatDylibSlide,
          (unsigned long)pointerAddress,
          (unsigned long)hookAddress);

    /*
     这里不再 patch 0x27A03A0 代码段。
     而是写微信自己预留/编译出来的函数指针 off_91EAD20。

     好处：
       1. 能拿到 a1/a2 参数
       2. 可以在 hook 里自己插入提示消息
       3. 不需要改 __TEXT 指令
    */
//    BOOL ok = YMWritePointer(pointerAddress,
//                             hookAddress,
//                             0,
//                             "revoke hook pointer -> YMHandleSysMsgRevokeMsgHook");
    
    BOOL ok = NO;

    if (profile->hookMode == YMRevokeHookModePointer) {
        /*
         4.1.9：
         写微信自己预留的 off_91EAD20 函数指针。
         */
        ok = YMWritePointer(pointerAddress,
                            hookAddress,
                            0,
                            "revoke hook pointer -> YMHandleSysMsgRevokeMsgHook");
    } else if (profile->hookMode == YMRevokeHookModeInlineEntry) {
        /*
         4.1.11：
         直接 inline hook ym_HandleSysMsg_RevokeMsg 入口。

         这个模式不会再尝试从 CoReplaceOriginMessageByRevoke 的临时对象里读原消息，
         只做基础防撤回：
           1. YMHandleSysMsgRevokeMsgHook(a1, a2)
           2. YMInsertLocalAntiRevokeNotice(a2) 插入灰色提示
           3. return 1 阻止微信继续执行原撤回逻辑
         */
        ok = YMPatchARM64AbsoluteJump(pointerAddress,
                                      hookAddress,
                                      "revoke entry inline hook -> YMHandleSysMsgRevokeMsgHook");
    } else if (profile->hookMode == YMRevokeHookModeInline) {
        /*
         4.1.10：
         先不拦入口了，入口一 return 就拿不到原消息。
         这里只 patch sub_2B707E0 里查完原消息后的那个点。
         拿到内容后把 __dst flag 清掉，让后面别再撤 UI。
         */
        ok = YMPatchRevokeLocalCallsiteOnly((uintptr_t)slide, source ?: @"anti revoke install");
    } else {
        YMLog(@"unknown revoke hook mode: %d", profile->hookMode);
        ok = NO;
    }

    if (ok) {
        YMHasPatchedAntiRevoke = YES;
    }

    return ok;
}

#pragma mark - dyld 查找 wechat.dylib

static BOOL YMIsTargetWeChatResourceDylibPath(NSString *imagePath) {
    if (imagePath.length == 0) {
        return NO;
    }

    BOOL isTarget =
    [imagePath hasSuffix:@"/Contents/Resources/wechat.dylib"] ||
    ([imagePath containsString:@"/Contents/Resources/"] &&
     [[imagePath lastPathComponent] isEqualToString:@"wechat.dylib"]);

    return isTarget;
}

static BOOL YMFindAndPatchLoadedWeChatResourceDylib(void) {
    uint32_t count = _dyld_image_count();

    YMLog(@"scan dyld images, count=%u", count);

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) {
            continue;
        }

        NSString *imagePath = [NSString stringWithUTF8String:name];

        if (!YMIsTargetWeChatResourceDylibPath(imagePath)) {
            continue;
        }

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        YMLog(@"found loaded Resources/wechat.dylib: index=%u, slide=0x%lx, path=%@",
              i,
              (unsigned long)slide,
              imagePath);

        YMRecordWeChatDylibSlide(slide, @"anti revoke dyld image scan");
        return YMPatchAntiRevokeWithSlide(slide, @"dyld image scan");
    }

    YMLog(@"Resources/wechat.dylib not found in dyld image list");
    return NO;
}

static void YMInstallAntiRevokePatch(void) {
    if (YMHasPatchedAntiRevoke) {
        return;
    }

    if (!YMIsTargetWeChatVersion()) {
        return;
    }

    YMFindAndPatchLoadedWeChatResourceDylib();
}

#pragma mark - 多开 Patch

static BOOL YMPatchMultiOpenWithWeChatDylibSlide(intptr_t slide, NSString *source) {
    if (YMHasPatchedMultiOpenResourceDylib) {
        YMLog(@"multi open already patched, skip. source=%@", source);
        return YES;
    }

    YMRecordWeChatDylibSlide(slide, source ?: @"multi open patch");

    /*
     这里仍然复用匹配逻辑。
     避免地址漂移后误 patch 新版本。
     注意：即使新版本地址没填完整，也要先记录 slide，方便日志 hook 调试新版地址。
     */
    if (!YMIsTargetWeChatVersion()) {
        YMLog(@"multi open unsupported version, skip. source=%@", source);
        return NO;
    }

    uintptr_t tryPreventAddress = YMRuntimeAddress(YMActiveProfile->YMMultiOpenTryPreventMultiInstanceVA);
    uintptr_t processCountAddress = YMRuntimeAddress(YMActiveProfile->YMGetMainWeixinProcessCountVA);

    YMLog(@"try install multi open patch from %@, profile=%s, slide=0x%lx, tryPrevent=0x%lx, processCount=0x%lx",
          source,
          YMActiveProfile->displayName,
          (unsigned long)YMWeChatDylibSlide,
          (unsigned long)tryPreventAddress,
          (unsigned long)processCountAddress);

    /*
     多开需要尽量同时绕过两层：
       1. TryPreventMultiInstance：启动早期防多开逻辑。
       2. GetMainWeixinProcessCount：通过 NSRunningApplication 统计同 BundleID 进程数量。
          4.1.10 如果不 patch 这个函数，第二个微信实例会检测到已有进程，
          很容易进入反复授权 / 防多开流程。
     */
    BOOL patchedAny = NO;
    BOOL finalOK = YES;

    if (tryPreventAddress != 0) {
        BOOL okTryPrevent = YMPatchARM64ReturnYES(
            tryPreventAddress,
            "multi open: TryPreventMultiInstance -> return 1"
        );

        patchedAny = YES;
        finalOK = finalOK && okTryPrevent;

        YMLog(@"multi open TryPreventMultiInstance patch=%@",
              okTryPrevent ? @"OK" : @"FAIL");
    } else {
        YMLog(@"multi open TryPreventMultiInstance address is zero, skip");
    }

    if (processCountAddress != 0) {
        BOOL okProcessCount = YMPatchARM64ReturnYES(
            processCountAddress,
            "multi open: GetMainWeixinProcessCount -> return 1"
        );

        patchedAny = YES;
        finalOK = finalOK && okProcessCount;

        YMLog(@"multi open GetMainWeixinProcessCount patch=%@",
              okProcessCount ? @"OK" : @"FAIL");
    } else {
        YMLog(@"multi open GetMainWeixinProcessCount address is zero, skip");
    }

    YMHasPatchedMultiOpenResourceDylib = patchedAny && finalOK;

    YMLog(@"multi open patch summary: patchedAny=%@, final=%@",
          patchedAny ? @"YES" : @"NO",
          YMHasPatchedMultiOpenResourceDylib ? @"OK" : @"FAIL");

    return YMHasPatchedMultiOpenResourceDylib;
}

static BOOL YMFindAndPatchLoadedMultiOpenWeChatDylib(void) {
    uint32_t count = _dyld_image_count();

    YMLog(@"scan dyld images for multi open, count=%u", count);

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) {
            continue;
        }

        NSString *imagePath = [NSString stringWithUTF8String:name];

        if (!YMIsTargetWeChatResourceDylibPath(imagePath)) {
            continue;
        }

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        YMLog(@"found Resources/wechat.dylib for multi open: index=%u, slide=0x%lx, path=%@",
              i,
              (unsigned long)slide,
              imagePath);

        YMRecordWeChatDylibSlide(slide, @"multi open dyld image scan");
        return YMPatchMultiOpenWithWeChatDylibSlide(slide, @"dyld image scan");
    }

    YMLog(@"Resources/wechat.dylib not found for multi open");
    return NO;
}

static void YMInstallMultiOpenPatch(void) {
    if (YMHasPatchedMultiOpenResourceDylib) {
        return;
    }

    /*
     防多开发生在启动早期，所以这里不能 dispatch_after。
     constructor 进来后立刻：
       1. 注册 dyld callback
       2. 扫描已经加载的 wechat.dylib
     */
    YMRegisterDyldCallbackIfNeeded();
    YMFindAndPatchLoadedMultiOpenWeChatDylib();
}

#pragma mark - URL 外部浏览器 Patch

static BOOL YMOpenURLRestoreOriginalWebViewKind(void) {
    if (!YMOpenURLWebViewKindRuntimeAddress || !YMOpenURLWebViewKindHasSavedOriginalBytes) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMOpenURLWebViewKindRuntimeAddress,
                                     YMOpenURLWebViewKindOriginalBytes,
                                     sizeof(YMOpenURLWebViewKindOriginalBytes),
                                     "open url GetUrlWebViewKind",
                                     "restore original");
}

static BOOL YMOpenURLReapplyWebViewKindHook(void) {
    if (!YMOpenURLWebViewKindRuntimeAddress) {
        return NO;
    }

    return YMGroupExitWriteCodeBytes(YMOpenURLWebViewKindRuntimeAddress,
                                     YMOpenURLWebViewKindHookBytes,
                                     sizeof(YMOpenURLWebViewKindHookBytes),
                                     "open url GetUrlWebViewKind",
                                     "reapply hook");
}

static int64_t YMOpenURLCallOriginalWebViewKind(void *a1, int64_t a2, int a3, int64_t a4) {
    if (!YMOpenURLWebViewKindRuntimeAddress) {
        return 0;
    }

    if (YMOpenURLCallingOriginalWebViewKind.exchange(true)) {
        YMLog(@"[OpenURLSystemBrowser] recursive original GetUrlWebViewKind call suppressed");
        return 0;
    }

    BOOL restored = YMOpenURLRestoreOriginalWebViewKind();
    if (!restored) {
        YMLog(@"[OpenURLSystemBrowser] restore original GetUrlWebViewKind failed");
        YMOpenURLCallingOriginalWebViewKind.store(false);
        return 0;
    }

    YMOpenURLWebViewKindFunc Original = (YMOpenURLWebViewKindFunc)YMOpenURLWebViewKindRuntimeAddress;

    int64_t result = 0;
    try {
        result = Original(a1, a2, a3, a4);
    } catch (...) {
        YMLog(@"[OpenURLSystemBrowser] exception while calling original GetUrlWebViewKind");
    }

    YMOpenURLReapplyWebViewKindHook();
    YMOpenURLCallingOriginalWebViewKind.store(false);
    return result;
}

static NSString *YMOpenURLReadMaybeStdString(int64_t value) {
    if (value == 0 || (uintptr_t)value < 0x100000000ULL) {
        return @"";
    }

    NSString *text = YMNSStringFromLibcppStringObject((const void *)(uintptr_t)value);
    if (text.length > 0) {
        return text;
    }

    return @"";
}

static BOOL YMOpenURLTextHasAnyKeyword(NSString *text, NSArray<NSString *> *keywords) {
    if (text.length == 0 || keywords.count == 0) {
        return NO;
    }

    NSString *lower = text.lowercaseString;
    for (NSString *keyword in keywords) {
        if (keyword.length == 0) {
            continue;
        }
        if ([lower containsString:keyword.lowercaseString]) {
            return YES;
        }
    }

    return NO;
}

static BOOL YMOpenURLShouldKeepWeChatLogic(NSString *urlText, NSString *moduleText) {
    NSArray<NSString *> *internalKeywords = @[
        @"weixin://",
        @"wechat://",
        @"wxapp",
        @"wxa",
        @"appbrand",
        @"miniapp",
        @"miniprogram",
        @"servicewechat.com",
        @"wxawap",
        @"search.weixin",
        @"soso",
        @"sogou",
        @"game.weixin",
        @"gamecenter",
        @"channels.weixin",
        @"finder.weixin",
        @"mmfinder",
        @"finder",
        @"videochannel",
        @"channels",
        @"wechatgame"
    ];

    if (YMOpenURLTextHasAnyKeyword(urlText, internalKeywords) ||
        YMOpenURLTextHasAnyKeyword(moduleText, internalKeywords)) {
        return YES;
    }

    return NO;
}

static int64_t YMOpenURLWebViewKindHook(void *a1, int64_t a2, int a3, int64_t a4) {
    @autoreleasepool {
        int64_t originalKind = YMOpenURLCallOriginalWebViewKind(a1, a2, a3, a4);
        if (!YMIsOpenURLWithSystemBrowserEnabled()) return originalKind;
        int64_t finalKind = originalKind;

        /*
         不能直接return 3,会导致小程序/搜一搜/游戏中心/视频号异常。
         */
        NSString *urlText = YMOpenURLReadMaybeStdString(a2);
        NSString *moduleText = YMOpenURLReadMaybeStdString(a4);

        BOOL looksLikeHTTP = [urlText.lowercaseString hasPrefix:@"http://"] ||
                             [urlText.lowercaseString hasPrefix:@"https://"];

        if (YMIsOpenURLWithSystemBrowserEnabled() &&
            originalKind == 0 &&
            looksLikeHTTP &&
            !YMOpenURLShouldKeepWeChatLogic(urlText, moduleText)) {
            finalKind = 3;
        }

        if (finalKind != originalKind || YMOpenURLShouldKeepWeChatLogic(urlText, moduleText)) {
            YMLog(@"[OpenURLSystemBrowser] GetUrlWebViewKind original=%lld final=%lld a3=%d url=%@ module=%@",
                  (long long)originalKind,
                  (long long)finalKind,
                  a3,
                  urlText ?: @"",
                  moduleText ?: @"");
        }

        return finalKind;
    }
}

static BOOL YMPatchOpenURLWithSystemBrowserWithSlide(intptr_t slide, NSString *source) {
    if (YMHasPatchedOpenURLWithSystemBrowser) {
        YMLog(@"open url system browser already patched, skip. source=%@", source ?: @"");
        return YES;
    }

    YMRecordWeChatDylibSlide(slide, source ?: @"open url system browser patch");

    if (!YMIsTargetWeChatVersion()) {
        YMLog(@"open url system browser unsupported version, skip. source=%@", source ?: @"");
        return NO;
    }

    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if (!profile || profile->openURLWebViewKindVA == 0) {
        YMLog(@"open url system browser address is zero, skip but keep slide/profile for debugging. profile=%s slide=0x%lx",
              profile ? profile->displayName : "NULL",
              (unsigned long)YMWeChatDylibSlide);
        return NO;
    }

    uintptr_t address = YMRuntimeAddress(profile->openURLWebViewKindVA);
    uintptr_t hookAddress = (uintptr_t)&YMOpenURLWebViewKindHook;

    YMLog(@"try install open url selective system browser patch from %@, profile=%s, slide=0x%lx, GetUrlWebViewKind=0x%lx, hook=0x%lx",
          source ?: @"",
          profile->displayName,
          (unsigned long)YMWeChatDylibSlide,
          (unsigned long)address,
          (unsigned long)hookAddress);

    if (address == 0 || hookAddress == 0) {
        YMLog(@"open url selective system browser patch failed: address/hook is zero");
        return NO;
    }

    YMOpenURLWebViewKindRuntimeAddress = address;
    YMGroupExitBuildAbsoluteJump(hookAddress, YMOpenURLWebViewKindHookBytes);

    uint8_t current[16] = {0};
    memcpy(current, (void *)address, sizeof(current));

    if (memcmp(current, YMOpenURLWebViewKindHookBytes, sizeof(current)) == 0) {
        YMLog(@"open url GetUrlWebViewKind already hooked, address=0x%lx", (unsigned long)address);
        YMOpenURLWebViewKindHasSavedOriginalBytes = YES;
        YMHasPatchedOpenURLWithSystemBrowser = YES;
        return YES;
    }

    memcpy(YMOpenURLWebViewKindOriginalBytes, current, sizeof(current));
    YMOpenURLWebViewKindHasSavedOriginalBytes = YES;

    BOOL ok = YMGroupExitWriteCodeBytes(address,
                                        YMOpenURLWebViewKindHookBytes,
                                        sizeof(YMOpenURLWebViewKindHookBytes),
                                        "open url GetUrlWebViewKind selective hook",
                                        "install hook");

    YMHasPatchedOpenURLWithSystemBrowser = ok;

    YMLog(@"open url selective system browser hook result=%@, address=0x%lx",
          ok ? @"OK" : @"FAIL",
          (unsigned long)address);

    return ok;
}

static BOOL YMFindAndPatchLoadedOpenURLWithSystemBrowserDylib(void) {
    uint32_t count = _dyld_image_count();

    YMLog(@"scan dyld images for open url system browser, count=%u", count);

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) {
            continue;
        }

        NSString *imagePath = [NSString stringWithUTF8String:name];

        if (!YMIsTargetWeChatResourceDylibPath(imagePath)) {
            continue;
        }

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        YMLog(@"found Resources/wechat.dylib for open url system browser: index=%u, slide=0x%lx, path=%@",
              i,
              (unsigned long)slide,
              imagePath);

        YMRecordWeChatDylibSlide(slide, @"open url dyld image scan");
        return YMPatchOpenURLWithSystemBrowserWithSlide(slide, @"dyld image scan");
    }

    YMLog(@"Resources/wechat.dylib not found for open url system browser");
    return NO;
}

static void YMInstallOpenURLWithSystemBrowserPatch(void) {
    if (YMHasPatchedOpenURLWithSystemBrowser) {
        return;
    }

    YMRegisterDyldCallbackIfNeeded();
    YMFindAndPatchLoadedOpenURLWithSystemBrowserDylib();
}

#pragma mark - tool
static void YMDyldImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    const char *name = NULL;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == mh) {
            name = _dyld_get_image_name(i);
            break;
        }
    }

    if (!name) {
        return;
    }

    NSString *imagePath = [NSString stringWithUTF8String:name];

    if (!YMIsTargetWeChatResourceDylibPath(imagePath)) {
        return;
    }

    YMLog(@"dyld added target Resources/wechat.dylib: %@, callback slide=0x%lx",
          imagePath,
          (unsigned long)vmaddr_slide);

    YMRecordWeChatDylibSlide(vmaddr_slide, @"dyld add image callback");
    YMInstallMessageMenuPatch();

    /*
     多开必须尽早 patch。
     所以只要 wechat.dylib 被 dyld 加载，就马上 patch sub_1C0A64 / sub_4396B00。
     */
    YMPatchMultiOpenWithWeChatDylibSlide(vmaddr_slide, @"dyld add image callback");

    if (YMIsOpenURLWithSystemBrowserEnabled()) {
        YMPatchOpenURLWithSystemBrowserWithSlide(vmaddr_slide, @"dyld add image callback");
    }


    if (YMIsGroupExitMonitorEnabled()) {
        YMPatchGroupExitMonitorWithSlide(vmaddr_slide, @"dyld add image callback");
    }

    if (YMShouldInstallRevokeHooks()) {
        YMPatchAntiRevokeWithSlide(vmaddr_slide, @"dyld add image callback");
    }
}

static void YMRegisterDyldCallbackIfNeeded(void) {
    if (YMHasRegisteredDyldCallback) {
        return;
    }

    YMHasRegisteredDyldCallback = YES;

    YMLog(@"register dyld add image callback");
    _dyld_register_func_for_add_image(YMDyldImageAdded);
}

#pragma mark - 功能安装

static void YMInstallAssistantMenu(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[MenuManager shareInstance] initAssistantMenuItems];
    });
}

static void YMInstallAntiUpdateIfNeeded(void) {
    if (!YMFeatureAntiUpdateEnabled) {
        YMLog(@"anti update disabled, skip");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YMDisableSparkleAutoUpdateDefaults();
        YMDisableSparkleByRuntimeHook();
    });
}

static void YMInstallAntiRevokeIfNeeded(void) {
    if (!YMShouldInstallRevokeHooks()) {
        YMLog(@"anti revoke disabled on legacy build, skip");
        return;
    }

    YMRegisterDyldCallbackIfNeeded();
    YMInstallAntiRevokePatch();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YMInstallAntiRevokePatch();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YMInstallAntiRevokePatch();
    });
}

static void YMInstallGroupExitMonitorIfNeeded(void) {
    if (!YMIsGroupExitMonitorEnabled()) {
        YMLog(@"[GroupExitMonitor] disabled, skip");
        YMGroupExitClearRuntimeStateIfDisabled("constructor skip");
        return;
    }

    YMInstallGroupExitMonitorPatch();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YMInstallGroupExitMonitorPatch();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YMInstallGroupExitMonitorPatch();
    });
}

static void YMInstallOpenURLWithSystemBrowserIfNeeded(void) {
    if (!YMIsOpenURLWithSystemBrowserEnabled()) {
        YMLog(@"open url system browser disabled, skip");
        return;
    }

    YMInstallOpenURLWithSystemBrowserPatch();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YMInstallOpenURLWithSystemBrowserPatch();
    });
}

static void YMInstallAutoLoginIfNeeded(void) {
    [AutoLogin startWithEnabled:YMFeatureAutoLoginEnabled];
}

#pragma mark - constructor

#pragma mark - 开关

static void YMLoadFeatureSwitchesFromDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSString *loadFlag = [defaults objectForKey:kIsFirstLoad];
    if (loadFlag.length < 3) {
        [defaults setBool:YES forKey:kAntiUpdate];
        [defaults setObject:@"SOVIET" forKey:kIsFirstLoad];
    }

    YMRegisterSelfRevokeDefault(defaults);
    YMFeatureAntiUpdateEnabled = [defaults boolForKey:kAntiUpdate];
    YMFeatureAntiRevokeEnabled = [defaults boolForKey:kAntiRevoke];
    YMFeatureGroupExitMonitorEnabled = [defaults boolForKey:kExitChatroom];

    YMFeatureGroupExitNicknameEnabled =  [defaults boolForKey:kExitChatroomNick];

    YMFeatureOpenURLWithSystemBrowserEnabled = [defaults boolForKey:kUseSystemWeb];
    YMFeatureAutoLoginEnabled = [defaults boolForKey:kAutoLogin];

    YMLog(@"feature switches antiUpdate=%@ antiRevoke=%@ groupExit=%@ groupExitNickname=%@ systemWeb=%@ autoLogin=%@",
          YMFeatureAntiUpdateEnabled ? @"ON" : @"OFF",
          YMFeatureAntiRevokeEnabled ? @"ON" : @"OFF",
          YMFeatureGroupExitMonitorEnabled ? @"ON" : @"OFF",
          YMFeatureGroupExitNicknameEnabled ? @"ON" : @"OFF",
          YMFeatureOpenURLWithSystemBrowserEnabled ? @"ON" : @"OFF",
          YMFeatureAutoLoginEnabled ? @"ON" : @"OFF");
}

YMFeatureApplyResult YMApplyFeatureSetting(NSString *key, BOOL enabled) {
    if (![NSThread isMainThread]) return YMFeatureUnavailable;
    if ([key isEqualToString:kAntiUpdate]) return enabled == YMFeatureAntiUpdateEnabled ? YMFeatureApplied : YMFeatureNeedsRestart;
    if ([key isEqualToString:kAutoLogin] || [key isEqualToString:kRevokeForwardToSelfRealSend] ||
        [key isEqualToString:kRevokeForwardOthers] || [key isEqualToString:kRevokeForwardSelf]) {
        return YMFeatureApplied;
    }
    const YMWeChatAdaptProfile *profile = YMGetActiveProfile();
    if ([key isEqualToString:kRevokeEnabled] || [key isEqualToString:kSelfAntiRevoke] ||
        ([key isEqualToString:kAntiRevoke] && profile && strcmp(profile->buildVersion, "269079") == 0)) {
        // 本人适配的 Hook 启动时安装，开关只控制后续事件，不从菜单写代码页。
        if (!profile || strcmp(profile->buildVersion, "269079") != 0) return YMFeatureUnavailable;
        return enabled && !YMHasPatchedAntiRevoke ? YMFeatureNeedsRestart : YMFeatureApplied;
    }
    if ([key isEqualToString:kAntiRevoke]) {
        if (!profile) return enabled ? YMFeatureUnavailable : YMFeatureApplied;
        // 旧入口替换没有可安全调用的原函数，保持原有启动开关。
        if (profile->hookMode != YMRevokeHookModeInline) return enabled == YMFeatureAntiRevokeEnabled.load() ? YMFeatureApplied : YMFeatureNeedsRestart;
        // 原生安装器会撤销整页执行权限；只能沿用启动安装，菜单不热写代码页。
        if (enabled && !YMHasPatchedAntiRevoke) return YMFeatureNeedsRestart;
        YMFeatureAntiRevokeEnabled.store(enabled);
        return YMFeatureApplied;
    }
    if ([key isEqualToString:kUseSystemWeb]) {
        if (enabled && (!profile || !profile->openURLWebViewKindVA)) return YMFeatureUnavailable;
        if (enabled && !YMHasPatchedOpenURLWithSystemBrowser) return YMFeatureNeedsRestart;
        YMFeatureOpenURLWithSystemBrowserEnabled.store(enabled);
        return YMFeatureApplied;
    }
    BOOL monitorKey = [key isEqualToString:kExitChatroom];
    BOOL nicknameKey = [key isEqualToString:kExitChatroomNick];
    if (monitorKey || nicknameKey) {
        BOOL monitor = monitorKey ? enabled : YMFeatureGroupExitMonitorEnabled.load();
        BOOL nickname = nicknameKey ? enabled : YMFeatureGroupExitNicknameEnabled.load();
        if (enabled && (!profile || !YMGroupExitProfileReady(profile))) return YMFeatureUnavailable;
        if (enabled && ((monitorKey && (!YMHasPatchedGroupExitMonitor || (nickname && !YMHasPatchedGroupExitNickname))) ||
                        (nicknameKey && !YMHasPatchedGroupExitNickname))) return YMFeatureNeedsRestart;
        std::lock_guard<std::recursive_mutex> stateLock(YMGroupExitStateMutex());
        BOOL monitorChanged = monitor != YMFeatureGroupExitMonitorEnabled.load();
        BOOL nicknameChanged = nickname != YMFeatureGroupExitNicknameEnabled.load();
        YMFeatureGroupExitMonitorEnabled.store(monitor);
        YMFeatureGroupExitNicknameEnabled.store(nickname);
        if (monitorChanged) {
            YMGroupExitGeneration.fetch_add(1);
            YMGroupExitNicknameGeneration.fetch_add(1);
            YMGroupExitClearRuntimeState("menu setting");
        } else if (nicknameChanged) {
            YMGroupExitNicknameGeneration.fetch_add(1);
            YMGroupExitClearNicknameState();
        }
        return YMFeatureApplied;
    }
    return YMFeatureUnavailable;
}

__attribute__((constructor))
static void YMWeChatAntiRevokePatchEntry(void) {
    SOVEXTCheckStartupPermission();
    @autoreleasepool {
        YMLog(@"constructor called");
        
        YMLoadFeatureSwitchesFromDefaults();

        YMInstallMultiOpenPatch();
        YMInstallMessageMenuPatch();
        
        YMInstallOpenURLWithSystemBrowserIfNeeded();
        YMInstallAutoLoginIfNeeded();
        YMInstallGroupExitMonitorIfNeeded();
        YMInstallAssistantMenu();
        YMInstallAntiUpdateIfNeeded();
        YMInstallAntiRevokeIfNeeded();
    }
}

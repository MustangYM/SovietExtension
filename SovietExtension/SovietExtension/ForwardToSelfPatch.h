//
//  ForwardToSelfPatch.h
//  SovietExtension
//  Thanks Code by https://github.com/shay-wong

//  原生消息发送：菜单 +1 发回原会话；撤回通知及原媒体同步给本人。
//
//  依赖：
//    Build 268853 文字通知使用 SendMsg CGI，profile.sendMsgCGIVA 管理；不支持原媒体转发。
//      Build 268853: sub_8da920 (VA 0x8da920)；Build 269079 历史入口: sub_8e8e64 (VA 0x8e8e64)。
//      269079 历史地址仅供逆向适配参考，当前使用下述原生入口。
//    Build 269079 原生消息入口由 profile.mediaForward 管理：
//      0x484f234：MessageWrap → MessageData；0x2e1ff8：MessageData 析构。
//      0x1453e34：单条消息转发并订阅任务；0x13b1bb0：插入本人接收方。
//    通知构造器单独校验：0x48e0f90 默认构造 MessageData，再复用上述转发入口。
//    以上 VA 均为 wechat.dylib arm64 静态地址，运行时需加模块基址。
//    RevokePatch 中按需查询微信会话资料的 YMQueryRoomName（269079: 0x3830E14）
//
//  269079 思路：撤回通知构造成原生文字消息，与原媒体共用单条转发链发给自己。
//  群名按需查询，未命中回退为群 ID；269079 原生适配不可用时跳过发送，不回退旧 CGI。
//

#import <Foundation/Foundation.h>
#import <stdint.h>

/// 菜单展示和统一转发入口共用，避免出现可点击却被提交层拒绝的消息类型。
/// 1 文字、3 图片、43 视频、47 表情包、49 应用消息（含文件/链接/卡片）。
/// 此列表不扩大撤回事件的自动媒体转发范围，后者仍由 YMForwardToSelfSend 限定。
static inline BOOL YMForwardSupportsMessageType(uint32_t type) {
    return type == 1 || type == 3 || type == 43 || type == 47 || type == 49;
}

/// SendMsg CGI 历史适配：268853 对应 VA 0x8da920，269079 对应 VA 0x8e8e64。
/// 仅为 Build 268853 返回旧文字通知入口；其他版本返回 0，不用作原生链失败回退。
uintptr_t YMSendMsgCGIRuntimeAddress(void);

// 保留历史 Media 命名；文字、媒体和生成的通知共用同一原生提交链。
typedef struct {
    uintptr_t fromWrap;
    uintptr_t destruct;
    uintptr_t forward;
    uintptr_t addRecipient;
} YMMediaForwardAddresses;

/// 仅在版本、UUID 和四个函数入口指纹均匹配时返回可用地址，否则清空输出。
BOOL YMGetMediaForwardAddresses(YMMediaForwardAddresses *addresses);

/// Build 269079 的 MessageData 默认构造器；原生链、UUID 和入口指纹均匹配才可用。
uintptr_t YMMessageDataConstructorRuntimeAddress(void);

/// 通过 roomID 查群名，查不到返回 @""
NSString *YMQueryRoomName(NSString *roomID);

BOOL YMRevokeRealSendForwardEnabled(void);

/// 撤回消息 → 本人文字通知；269079 对类型 3/43/47/49 同时提交原内容转发。
/// 通知保留撤回人、内容和时间；文字原文包含在通知中，不再额外发送一条原文。
/// selfUserText 必须由撤回上下文显式提供；YES 表示通知或媒体已排队，不是送达回执。
BOOL YMForwardToSelfSend(uintptr_t outWrap,
                         uint32_t  originType,
                         NSString *originContent,
                         NSString *sessionText,
                         NSString *selfUserText,
                         NSString *revokerWxid,
                         NSString *revokerDisplayName);

/// 复用原生转发链，将消息发送到指定的当前会话。
/// 文字和媒体均从 outWrap 转换为 MessageData；不降级到文字 CGI。
/// 调用者提供有效、存活的 MessageWrap 和已核实的原消息所在会话 ID。
/// 仅表示已排队或订阅，不代表服务端已送达；升级微信后须重新验证 ABI 与实际收取。
BOOL YMForwardMessageToSession(uintptr_t outWrap,
                               uint32_t originType,
                               NSString *sessionID);

/// 菜单已持有原生 MessageData 快照时，直接复用同一提交链；仅允许主线程同步调用。
/// 快照必须在调用期间存活，sessionID 必须等于快照内的原始会话。
BOOL YMForwardMessageDataToSession(uintptr_t messageData, NSString *sessionID);

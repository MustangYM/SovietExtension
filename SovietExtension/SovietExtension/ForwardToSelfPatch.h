//
//  ForwardToSelfPatch.h
//  SovietExtension
//  Thanks Code by https://github.com/shay-wong

//  撤回消息 → 同步发送给自己（全设备同步）
//
//  依赖：
//    文字入口：SendMsg CGI，profile.sendMsgCGIVA 管理。
//      Build 268853: sub_8da920 (VA 0x8da920)；Build 269079: sub_8e8e64 (VA 0x8e8e64)。
//    Build 269079 媒体入口由 profile.mediaForward 管理：
//      0x484f234：MessageWrap → MessageData；0x2e1ff8：MessageData 析构。
//      0x1453e34：单条消息转发并订阅任务；0x13b1bb0：插入本人接收方。
//    以上 VA 均为 wechat.dylib arm64 静态地址，运行时需加模块基址。
//    RevokePatch 中 UpdateSessionCache hook 提供的群名缓存（YMCachedRoomName）
//
//  思路：撤回回调里拿到原始消息内容，构造 type=5 文本消息通过 SendMsg CGI
//  发给自己；媒体同时通过原生单条转发链排队。群名从缓存取，未命中回退为“未知群聊”。
//

#import <Foundation/Foundation.h>
#import <stdint.h>

/// SendMsg CGI 运行时地址：268853 对应 VA 0x8da920，269079 对应 VA 0x8e8e64。
uintptr_t YMSendMsgCGIRuntimeAddress(void);

typedef struct {
    uintptr_t fromWrap;
    uintptr_t destruct;
    uintptr_t forward;
    uintptr_t addRecipient;
} YMMediaForwardAddresses;

/// 仅在版本、UUID 和四个函数入口指纹均匹配时返回可用地址，否则清空输出。
BOOL YMGetMediaForwardAddresses(YMMediaForwardAddresses *addresses);

/// 通过 roomID 查群名，查不到返回 @""
NSString *YMCachedRoomName(NSString *roomID);

BOOL YMRevokeRealSendForwardEnabled(void);

/// 撤回消息 → 本人文字通知；支持的媒体同时提交原内容转发。
/// selfUserText 必须由撤回上下文显式提供；YES 表示已调用通知或排队媒体，不是送达回执。
BOOL YMForwardToSelfSend(uintptr_t outWrap,
                         uint32_t  originType,
                         NSString *originContent,
                         NSString *sessionText,
                         NSString *selfUserText,
                         NSString *revokerWxid,
                         NSString *revokerDisplayName);

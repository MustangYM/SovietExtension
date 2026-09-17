//
//  ForwardToSelfPatch.mm
//  SovietExtension
//
//  ============================================================
//  Build 269079 菜单 +1 与撤回同步共用原生转发链
//  Build 268853 撤回同步保留 CGI 文字通知。
//  ============================================================
//
//  ★ 269079 的三种输入最终都交给 YMSubmitMessageToSession：
//    +1：持有菜单原生 MessageData 快照，原样发回快照记录的会话，不是发给自己。
//    撤回媒体：在回调返回前将 MessageWrap 转成独立 MessageData，目标为显式本人账号。
//    撤回通知：将“撤回人、内容、时间”构造成新的文字 MessageData，同样发给本人。
//    默认构造器只负责准备通知输入，不另建发送链；所有提交均在主线程进行。
//    本人账号不安全或原生适配不可用时跳过对应发送，不回退旧 CGI。
//
//  ★ 旧版文字兼容入口：SendMsg CGI（268853: 0x8da920；269079 历史地址: 0x8e8e64）
//     - Hopper: strings → "sendmsg_Send" / "send_msg_to_user is empty" 交叉引用定位
//     - x0 = 请求对象（80*8=640 字节），x1 = 1（发送标志）
//     - profile.sendMsgCGIVA 管理，YMSendMsgCGIRuntimeAddress() 取
//     - 仅 268853 的撤回文字通知使用；269079 使用原生链，不作为失败重试/回退入口。
//     - “CGI”是历史命名，269079 的该入口内部也会构造并订阅原生文字发送任务。
//       269079 地址保留为逆向适配参考，不写入当前 profile。
//
//  ★ 旧文字请求对象布局（不等同于下方的 0x340 字节 MessageData）：
//     +0x000: uint32_t type = 5
//     +0x120: std::string to       （接收方 wxid）
//     +0x138: std::string content  （消息正文）
//     +0x150: std::string from     （发送方 wxid）
//
//  ★ 重要修复（2026-06-30）：
//     旧版在本文件里通过 outWrap+0x30 / outWrap+0x48 猜 selfId。
//     开源用户反馈：部分环境下提醒消息没有发给自己，反而发给当前聊天对象。
//     根因就是 outWrap/origin message 的字段在不同场景下可能是当前会话、发送者或群 ID，
//     不能作为“当前登录账号”来源。
//     现在由 RevokePatch.mm 按 profile.layout.selfUserOffset 读取撤回消息 rawWrap（当前为 +48），
//     作为 explicit selfUserText 显式传入；本文件只做安全校验，不再猜 selfId。
//     如果 selfUserText 不安全，直接跳过发送，宁可不发也不能误发给别人。
//
//  ★ 历史 MessageWrap 字段记录（不能作为跨版本 ABI）：
//     +0x18 (24)  = 会话展示名（私聊=对方号，群聊=群ID?）
//     +0x30 (48)  = 在撤回消息 rawWrap 中可作为当前登录账号 / 自己
//     +0x48 (72)  = 发送者 wxid
//     +0x100(256) = 毫秒创建时间
//     原记录的 +0x108 不能用于读取类型；269079 已由转换函数确认类型在 +0x0c。
//     +0x114(276) = 秒级创建时间
//     +0x130(304) = 消息内容 (文本=原文, 图片=CDN XML)
//     +0x148(328) = content/XML（另一偏移，可能冗余）
//     +0x160(352) = msgSource XML
//     +0x268(616) = 查询结果 hasValue 标志（位于 616 字节消息数据之后，0 表示无值）
//
//  ★ 269079 统一转发链：0x484f234 将 Wrap 转为 0x340 字节 MessageData，
//    0x13b1bb0 添加唯一的指定目标，0x1453e34 构造消息请求并订阅异步任务。
//    正常转图采样栈：0x533784 → 0x1453e34 → 0x1454414 → 0x3638f00。
//    仅调用最后的任务构造器不会执行发送；完整入口负责构造、订阅和队列派发。
//    profile 保存转换 0x484f234、析构 0x2e1ff8、转发 0x1453e34、目标插入 0x13b1bb0，
//    四个入口均校验 UUID 和指纹；调用栈中的其他地址仅用于定位，不由插件直接调用。
//    类型 49 是应用消息大类（包含文件），不能据此将所有类型 49 都认作文件。
//    通知另用 0x48e0f90 默认构造器，单独校验指纹；不可用时不影响原消息转发。
//
//  ★ 群名获取：269079 的 0x3830E14 按会话 ID 同步查询微信会话资料。
//     YMQueryRoomName(roomID) 校验会话 ID 后返回群名；未命中/未适配时显示群 ID。
//
//  ★ 撤回同步门控（不控制用户主动点击 +1）：NSUserDefaults("kRevokeForwardToSelfRealSend.SOVIET")
//         或 /tmp/YMRevokeForwardToSelfRealSend 文件哨兵
//
//  ★ 日志：grep "RevokeAutoForward" /tmp/YMWeChatAntiRevokePatch.log
//

#import "ForwardToSelfPatch.h"
#import "SelfRevokePatch.h"
#import "QuotedReply.h"
#import <objc/message.h>

#include <string>
#include <stdarg.h>
#include <new>
#include <cstring>
#include <memory>
#include <map>
#include <set>
#include <vector>
#include <cstddef>

#pragma mark - 门控

BOOL YMRevokeRealSendForwardEnabled(void) {
    BOOL defaultsArmed = [[NSUserDefaults standardUserDefaults] boolForKey:@"kRevokeForwardToSelfRealSend.SOVIET"];
    BOOL fileArmed = [[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/YMRevokeForwardToSelfRealSend"];
    return defaultsArmed || fileArmed;
}

#pragma mark - 日志

static void YMForwardLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[YMAntiRevoke] [RevokeAutoForward] %@", msg ?: @"");

    NSString *line = [NSString stringWithFormat:@"[RevokeAutoForward] %@\n", msg ?: @""];
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

#pragma mark - 字符串 / 安全辅助

static NSString *YMForwardTrim(NSString *value) {
    if (value.length == 0) {
        return @"";
    }

    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static BOOL YMForwardStringMatchesPattern(NSString *value, NSString *pattern) {
    if (value.length == 0 || pattern.length == 0) {
        return NO;
    }

    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:0
                                                                             error:&error];
    if (error || !regex) {
        return NO;
    }

    NSRange fullRange = NSMakeRange(0, value.length);
    NSTextCheckingResult *match = [regex firstMatchInString:value options:0 range:fullRange];
    return match && NSEqualRanges(match.range, fullRange);
}

static BOOL YMForwardLooksLikeAccountID(NSString *value) {
    NSString *text = YMForwardTrim(value);
    if (text.length == 0 || text.length > 128) {
        return NO;
    }

    if ([text containsString:@"@chatroom"] ||
        [text containsString:@"\n"] ||
        [text containsString:@" "] ||
        [text containsString:@"<"] ||
        [text containsString:@">"]) {
        return NO;
    }

    if ([text hasPrefix:@"wxid_"]) {
        return YES;
    }

    // 兼容老微信号 / 自定义微信号，例如 yanmaoweibo / MustangYM001。
    return YMForwardStringMatchesPattern(text, @"^[A-Za-z0-9_\\-]{5,128}$");
}

static BOOL YMForwardLooksLikeSafeSelfID(NSString *selfId) {
    NSString *value = YMForwardTrim(selfId);
    // 原生发送仅适配具有可信账号查询的版本。账号不可用或已切换时拒绝发送，
    // 不通过会话方向或撤回人的昵称猜测接收方。
    NSString *account = YMSelfRevokeAccount();
    return YMForwardLooksLikeAccountID(value) &&
           ![value containsString:@"@chatroom"] &&
           account.length > 0 && [value isEqualToString:account];
}

#pragma mark - 格式化辅助

static BOOL YMForwardTextIsBuiltinEmoji(NSString *text) {
    NSString *value = YMForwardTrim(text);
    return value.length >= 3 && value.length <= 32 &&
           [value hasPrefix:@"["] && [value hasSuffix:@"]"] &&
           [value rangeOfString:@"\n"].location == NSNotFound;
}

static BOOL YMForwardTextLooksUseless(NSString *text) {
    if (text.length == 0) return NO;
    return [text containsString:@"暂不支持该内容"] ||
           [text containsString:@"请在手机上查看"];
}

/// 群聊消息格式为 wxid_xxx:\n内容，拆出发送者和正文
static NSString *YMForwardCleanContent(NSString *rawContent, NSString **senderOut) {
    if (senderOut) *senderOut = @"";
    if (rawContent.length == 0) return @"";

    NSString *text = YMForwardTrim(rawContent);
    NSRange colonNewline = [text rangeOfString:@":\n"];
    if (colonNewline.location != NSNotFound && colonNewline.location > 0) {
        NSString *prefix = [text substringToIndex:colonNewline.location];
        NSString *body   = [text substringFromIndex:NSMaxRange(colonNewline)];
        prefix = YMForwardTrim(prefix);
        body   = YMForwardTrim(body);
        if (prefix.length > 0 && senderOut) *senderOut = prefix;
        if (body.length > 0) return body;
    }

    return text;
}

static NSString *YMForwardContentDisplay(uint32_t type, NSString *cleanContent) {
    switch (type) {
        case 1:
            return (YMForwardTextIsBuiltinEmoji(cleanContent) && cleanContent.length)
                ? cleanContent
                : (cleanContent.length > 0 ? cleanContent : @"（空）");
        case 3:  return @"[图片]";
        case 34: return @"[语音]";
        case 43: return @"[视频]";
        case 47: return @"[表情包]";
        case 48: return @"[位置]";
        case 49: return @"[文件/链接/卡片]";
        default: return [NSString stringWithFormat:@"[%u]", type];
    }
}

static NSString *YMForwardRevokerDisplay(NSString *displayName, NSString *wxid, NSString *sender) {
    if (displayName.length > 0) return displayName;
    if (wxid.length > 0) return wxid;
    if (sender.length > 0) return sender;
    return @"***";
}

#pragma mark - 构建转发通知文本

static NSString *YMBuildRevokeForwardNotice(NSString *sessionText,
                                            uint32_t originType,
                                            NSString *originRawContent,
                                            NSString *revokerWxid,
                                            NSString *revokerDisplayName) {
    NSString *sender = @"";
    NSString *clean = originRawContent ?: @"";

    if (originType == 1) {
        clean = YMForwardCleanContent(originRawContent, &sender);
        if (YMForwardTextLooksUseless(clean)) {
            clean = @"";
        }
    }

    BOOL textReply = NO;
    NSString *quote = YMQuotedReplyText(originRawContent, originType, &textReply, sessionText);
    if (clean.length > 1600) {
        clean = [[clean substringToIndex:1600] stringByAppendingString:@"…"];
    }

    NSString *contentDisplay = quote ?: YMForwardContentDisplay(originType, clean);
    NSString *revokerDisplay = YMForwardRevokerDisplay(YMResolveMemberDisplayName(revokerWxid, sessionText, revokerDisplayName, nil), revokerWxid, sender);

    NSMutableString *notice = [NSMutableString string];
    [notice appendString:@"--拦截到一条撤回消息--\n"];

    if ([sessionText containsString:@"@chatroom"]) {
        NSString *roomName = YMQueryRoomName(sessionText);
        [notice appendFormat:@"群名:%@\n", roomName.length > 0 ? roomName : sessionText];
    }

    [notice appendFormat:@"撤回人:%@\n", revokerDisplay.length > 0 ? revokerDisplay : @"***"];
    [notice appendFormat:@"内容:%@%@", quote ? @" " : @"", contentDisplay.length > 0 ? contentDisplay : @"（空）"];

    if (originType != 1 && !textReply) {
        [notice appendString:@"\n(非文字消息只做提醒)"];
    }

    NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
    [dateFmt setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timeStr = [dateFmt stringFromDate:[NSDate date]] ?: @"";
    if (timeStr.length > 0) {
        [notice appendFormat:@"\n%@", timeStr];
    }

    return notice;
}

#pragma mark - Build 268853 文字通知兼容

static BOOL YMForwardViaSendMsgCGI(uintptr_t fn, NSString *selfId, NSString *content) {
    if (!fn || !content.length) return NO;
    @try { try {
        // 保留已适配的640字节布局；string 由 RAII 管理，异常时也能释放。
        struct Request {
            uint32_t type = 5;
            uint8_t padding[0x120 - sizeof(uint32_t)] = {};
            std::string to, content, from;
            uint8_t tail[0x280 - 0x168] = {};
        };
        static_assert(offsetof(Request, to) == 0x120 && offsetof(Request, content) == 0x138 &&
                      offsetof(Request, from) == 0x150 && sizeof(Request) == 0x280);
        const char *recipient = [selfId UTF8String], *text = [content UTF8String];
        if (!recipient || !text) return NO;
        Request request;
        request.to = request.from = recipient;
        request.content.assign(text, [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        // 同步使用本次撤回事件的本人身份，不跨线程排队或借用原消息字段。
        ((int64_t (*)(uintptr_t, uintptr_t))fn)((uintptr_t)&request, 1);
        return YES;
    } catch (...) {
        YMForwardLog(@"legacy text notice failed");
        return NO;
    } } @catch (NSException *) { return NO; }
}

#pragma mark - 统一入口

struct YMForwardMessageData {
    // 仅提供对齐存储。内部含 string/shared_ptr/容器，必须通过原生构造、转换和析构管理。
    uintptr_t words[0x340 / sizeof(uintptr_t)];
};

struct YMForwardTargets {
    // 269079 原生上下文布局；key=2 是普通微信目标，另外两项保持为空。
    std::map<int32_t, std::set<std::string>> accounts;
    std::vector<std::shared_ptr<void>> additionalItems;
    std::string wxworkRecipient;
};

struct YMForwardSubscription {
    // 原生返回值通过 arm64 x8 写入；队列持有自己的副本，可像原调用方一样释放局部句柄。
    uint64_t identifier;
    std::shared_ptr<void> cancellation;
    std::shared_ptr<void> owner;
};

static_assert(sizeof(YMForwardTargets) == 0x48);
static_assert(offsetof(YMForwardTargets, additionalItems) == 0x18);
static_assert(offsetof(YMForwardTargets, wxworkRecipient) == 0x30);
static_assert(sizeof(YMForwardSubscription) == 0x28);
static_assert(offsetof(YMForwardSubscription, cancellation) == 0x8);
static_assert(offsetof(YMForwardSubscription, owner) == 0x18);

// 共用提交端：调用方先校验目标并保证主线程；1453e34 同步复制消息，队列持有自己的副本。
// 原消息保留其身份与完整数据；新通知允许 source ID 为 0，由微信生成新发送身份。
static BOOL YMSubmitMessageToSession(const YMForwardMessageData *message,
                                NSString *sessionID, YMMediaForwardAddresses addresses) {
    try {
        YMForwardTargets targets;
        std::string recipient([sessionID UTF8String]);
        ((void (*)(YMForwardTargets *, int32_t, const std::string *))addresses.addRecipient)(&targets, 2, &recipient);
        // 原生插入后再次验证完整目标集合；不符合唯一指定会话约束时停止提交。
        if (targets.accounts.size() != 1 || targets.accounts.at(2) != std::set<std::string>{recipient} ||
            !targets.additionalItems.empty() || !targets.wxworkRecipient.empty()) {
            YMForwardLog(@"native recipient validation failed; skip forwarding");
            return NO;
        }
        // 可选来源的 +0x78 有效位为零；回调组的三个函数槽为空，不绑定 UI 对象。
        uintptr_t source[16] = {};
        uintptr_t callbacks[17] = {};
        typedef YMForwardSubscription (*ForwardMessage)(YMForwardTargets *, const YMForwardMessageData *,
                                                        const void *, const void *);
        YMForwardSubscription subscription = ((ForwardMessage)addresses.forward)(&targets, message, source, callbacks);
        // 有效句柄只证明已订阅任务，不代表服务器已接收或媒体已送达。
        if (!subscription.identifier || !subscription.cancellation) {
            YMForwardLog(@"native forwarding did not create a subscription");
            return NO;
        }
        YMForwardLog(@"native message task subscribed; delivery pending");
        return YES;
    } catch (...) {
        YMForwardLog(@"native message forwarding failed");
        return NO;
    }
}

// selfId 必须先通过 YMForwardLooksLikeSafeSelfID；只为新通知构造对象，不修改原消息快照。
static BOOL YMForwardNoticeToSelf(NSString *selfId, NSString *content) {
    if (!YMForwardLooksLikeSafeSelfID(selfId) || !content.length) return NO;
    YMMediaForwardAddresses addresses = {};
    if (!YMGetMediaForwardAddresses(&addresses)) return NO;
    uintptr_t construct = YMMessageDataConstructorRuntimeAddress();
    if (!construct) {
        YMForwardLog(@"native notice construction unavailable; skip notice");
        return NO;
    }
    if (![NSThread isMainThread]) {
        // 只保留通知正文与本人账号；不跨线程借用撤回回调的 MessageWrap。
        NSString *recipient = [selfId copy];
        NSString *notice = [content copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            YMForwardNoticeToSelf(recipient, notice);
        });
        return YES;
    }
    try {
        const char *recipientUTF8 = [selfId UTF8String];
        const char *contentUTF8 = [content UTF8String];
        if (!recipientUTF8 || !contentUTF8) return NO;
        auto storage = std::make_unique<YMForwardMessageData>();
        ((void (*)(YMForwardMessageData *))construct)(storage.get());
        auto destroy = [addresses](YMForwardMessageData *value) {
            ((void (*)(YMForwardMessageData *))addresses.destruct)(value);
            delete value;
        };
        std::unique_ptr<YMForwardMessageData, decltype(destroy)> message(storage.release(), destroy);
        uint8_t *data = (uint8_t *)message.get();
        const uint32_t textType = 1;
        memcpy(data + 8, &textType, sizeof(textType));
        // 269079: 48e0f90 初始化完整对象；484f234 / 5167ac 确认正文为 +0xb0 的 string。
        // 27ac014 为发送生成新 Wrap/身份；27c1058..27c106c 将 Data+0xb0 赋给 Wrap+0x130。
        // 新通知不借用原消息的 ID、扩展对象或媒体字段，也不按 ID 重查原文。
        *(std::string *)(data + 0x28) = recipientUTF8;
        *(std::string *)(data + 0x40) = recipientUTF8;
        *(std::string *)(data + 0x58) = recipientUTF8;
        ((std::string *)(data + 0xb0))->assign(contentUTF8, [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        return YMSubmitMessageToSession(message.get(), selfId, addresses);
    } catch (...) {
        YMForwardLog(@"native notice construction failed");
        return NO;
    }
}

static BOOL YMForwardNativeToSession(uintptr_t outWrap, uint32_t originType, NSString *sessionID, BOOL toSelf = NO) {
    if (!outWrap || !YMForwardSupportsMessageType(originType)) return NO;
    YMMediaForwardAddresses addresses = {};
    if (!YMGetMediaForwardAddresses(&addresses) || !addresses.fromWrap || !addresses.destruct ||
        !addresses.forward || !addresses.addRecipient) {
        YMForwardLog(@"native forwarding unavailable for this binary");
        return NO;
    }
    uint32_t wrapType = 0;
    uint64_t sourceID = 0;
    // 269079 转换关系：Wrap+0xc → Data+8，Wrap+0xf8 → Data+0x90。
    memcpy(&wrapType, (const void *)(outWrap + 12), sizeof(wrapType));
    memcpy(&sourceID, (const void *)(outWrap + 0xf8), sizeof(sourceID));
    if (wrapType != originType || sourceID == 0) {
        YMForwardLog(@"message source layout mismatch or missing ID");
        return NO;
    }

    typedef YMForwardMessageData (*ConvertMessage)(uintptr_t);
    typedef void (*DestroyMessage)(YMForwardMessageData *);
    BOOL submitted = NO;
    try {
        // 依赖 C++17 直接初始化返回值，避免复制含内部自引用的原生对象。
        // shared_ptr 保证跨主线程排队仍存活；释放时先执行原生析构，再释放存储。
        std::shared_ptr<YMForwardMessageData> message(
            new YMForwardMessageData(((ConvertMessage)addresses.fromWrap)(outWrap)),
            [addresses](YMForwardMessageData *value) {
                ((DestroyMessage)addresses.destruct)(value);
                delete value;
            });
        uint32_t convertedType = 0;
        uint64_t convertedID = 0;
        memcpy(&convertedType, (const uint8_t *)message.get() + 8, sizeof(convertedType));
        memcpy(&convertedID, (const uint8_t *)message.get() + 0x90, sizeof(convertedID));
        if (convertedType == originType && convertedID == sourceID) {
            if ([NSThread isMainThread]) {
                submitted = (!toSelf || YMForwardLooksLikeSafeSelfID(sessionID)) &&
                            YMSubmitMessageToSession(message.get(), sessionID, addresses);
            } else {
                // 原撤回回调可能不在主线程；先转换并持有数据，不跨线程保留 outWrap 裸指针。
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!toSelf || YMForwardLooksLikeSafeSelfID(sessionID))
                        YMSubmitMessageToSession(message.get(), sessionID, addresses);
                });
                submitted = YES;
            }
            if (submitted) YMForwardLog(@"message forwarding queued. type=%u; delivery pending", originType);
        } else {
            YMForwardLog(@"converted message identity mismatch");
        }
    } catch (...) {
        YMForwardLog(@"native message forwarding failed");
    }
    return submitted;
}

static BOOL YMIsForwardSessionValid(NSString *sessionID) {
    // 不清理/猜测会话 ID；允许普通账号和群 ID，拒绝路径、空白和文件传输助手。
    if (sessionID.length > 128 || [sessionID isEqualToString:@"filehelper"] ||
        !YMForwardStringMatchesPattern(sessionID, @"^(?:[A-Za-z0-9_\\-]{5,128}|[0-9]+@chatroom)$")) {
        return NO;
    }
    return YES;
}

BOOL YMForwardMessageDataToSession(uintptr_t messageData, NSString *sessionID) {
    if (!messageData || ![NSThread isMainThread] || !YMIsForwardSessionValid(sessionID)) return NO;
    YMMediaForwardAddresses addresses = {};
    if (!YMGetMediaForwardAddresses(&addresses)) return NO;
    uint32_t type = 0;
    uint64_t sourceID = 0;
    memcpy(&type, (const void *)(messageData + 8), sizeof(type));
    memcpy(&sourceID, (const void *)(messageData + 0x90), sizeof(sourceID));
    if (!sourceID || !YMForwardSupportsMessageType(type)) return NO;
    const auto &sourceSession = *(const std::string *)(messageData + 0x58);
    // 0x484caf0 按消息方向解析 +0x58；+1 只发回原会话，不根据 sender/to 猜目标。
    if (sourceSession != std::string([sessionID UTF8String])) return NO;
    return YMSubmitMessageToSession((const YMForwardMessageData *)messageData, sessionID, addresses);
}

BOOL YMForwardMessageToSession(uintptr_t outWrap,
                               uint32_t originType,
                               NSString *sessionID) {
    if (!YMIsForwardSessionValid(sessionID)) return NO;
    return YMForwardNativeToSession(outWrap, originType, sessionID);
}

BOOL YMForwardToSelfSend(uintptr_t outWrap,
                         uint32_t originType,
                         NSString *originContent,
                         NSString *sessionText,
                         NSString *selfUserText,
                         NSString *revokerWxid,
                         NSString *revokerDisplayName) {
    NSString *selfId = YMForwardTrim(selfUserText);

    uintptr_t legacySend = YMSendMsgCGIRuntimeAddress();
    // 268853 没有269079的登录账号接口；仅接受调用方从该版本撤回事件读取的本人字段。
    BOOL safeSelf = legacySend
        ? ![selfId isEqualToString:@"filehelper"] &&
          YMForwardStringMatchesPattern(selfId, @"^[A-Za-z0-9_\\-]{5,128}$")
        : YMForwardLooksLikeSafeSelfID(selfId);
    if (!safeSelf) {
        YMForwardLog(@"unsafe selfId, skip real send. selfId=%@ session=%@ revoker=%@ displayName=%@ type=%u",
                     selfId ?: @"",
                     sessionText ?: @"",
                     revokerWxid ?: @"",
                     revokerDisplayName ?: @"",
                     originType);
        return NO;
    }

    // 撤回文字只发包含原文的通知，避免额外转发一条原文。
    // 支持的非文字消息与 +1 共用原生转发链，另行发送撤回通知；排队不代表送达。
    // 引用回复以完整文字通知保留上下文，原生转发可能只留下回复正文。
    BOOL quotedReply = NO;
    YMQuotedReplyText(originContent, originType, &quotedReply);
    BOOL mediaSubmitted = !legacySend && !quotedReply && (originType == 3 || originType == 43 || originType == 47 || originType == 49) &&
                          YMForwardNativeToSession(outWrap, originType, selfId, YES);
    NSString *notice = YMBuildRevokeForwardNotice(sessionText ?: @"",
                                                  originType,
                                                  originContent ?: @"",
                                                  revokerWxid ?: @"",
                                                  revokerDisplayName ?: @"");
    if (mediaSubmitted) {
        notice = [notice stringByReplacingOccurrencesOfString:@"\n(非文字消息只做提醒)"
                                                  withString:@"\n(原消息已加入转发队列，结果以实际收到为准)"];
    }

    if (notice.length == 0) {
        YMForwardLog(@"notice is empty, skip real send. selfId=%@ session=%@", selfId ?: @"", sessionText ?: @"");
        return NO;
    }

    YMForwardLog(@"submit revoke notice to self. selfId=%@ session=%@ type=%u noticeLen=%lu",
                 selfId ?: @"",
                 sessionText ?: @"",
                 originType,
                 (unsigned long)notice.length);

    BOOL noticeSent = legacySend ? YMForwardViaSendMsgCGI(legacySend, selfId, notice)
                                 : YMForwardNoticeToSelf(selfId, notice);
    // 返回值仅表示通知或媒体已排队；异步失败记录日志，不代表送达。
    return mediaSubmitted || noticeSent;
}

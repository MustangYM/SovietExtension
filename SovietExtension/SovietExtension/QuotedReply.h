#pragma once
#import <Foundation/Foundation.h>

NSString *YMQueryContactRemark(NSString *contactID);

static inline NSXMLElement *YMQuoteXMLRoot(NSString *raw) {
    if (!raw.length || raw.length > 262144) return nil;
    NSRange start = [raw rangeOfString:@"<msg"];
    if (start.location == NSNotFound) start = [raw rangeOfString:@"<appmsg"];
    if (start.location == NSNotFound ||
        [raw rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [raw rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location != NSNotFound) return nil;
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithXMLString:[raw substringFromIndex:start.location]
        options:NSXMLNodeLoadExternalEntitiesNever error:nil];
    return document.rootElement;
}

static inline NSXMLElement *YMQuoteAppNode(NSXMLElement *root) {
    return [root.name isEqualToString:@"appmsg"] ? root :
        ([root.name isEqualToString:@"msg"] ? [root elementsForName:@"appmsg"].firstObject : nil);
}

static inline NSString *YMQuoteTypeLabel(NSString *type, NSString *content) {
    if ([type isEqualToString:@"49"]) {
        NSString *subtype = [[YMQuoteAppNode(YMQuoteXMLRoot(content)) elementsForName:@"type"].firstObject stringValue];
        NSDictionary *labels = @{@"5": @"[链接]", @"6": @"[文件]", @"57": @"[文本消息]"};
        return labels[subtype ?: @""] ?: @"[应用消息]";
    }
    NSDictionary *labels = @{@"3": @"[图片]", @"34": @"[语音]", @"43": @"[视频]",
                              @"47": @"[表情包]", @"48": @"[位置]"};
    return labels[type ?: @""] ?: @"[引用内容不可用]";
}

// 正文和引用各自按自身类型展示，只读取直接字段，不将引用 XML 当成正文。
static inline NSString *YMQuotedReplyText(NSString *raw, uint32_t originType = 49, BOOL *textReply = nullptr) {
    if (textReply) *textReply = NO;
    if (originType != 3 && originType != 34 && originType != 43 && originType != 47 &&
        originType != 48 && originType != 49) return nil;
    NSXMLElement *root = YMQuoteXMLRoot(raw);
    NSXMLElement *app = YMQuoteAppNode(root);
    BOOL isTextReply = originType == 49 &&
        [[[[app elementsForName:@"type"] firstObject] stringValue] isEqualToString:@"57"];
    NSXMLElement *reference = isTextReply ? [app elementsForName:@"refermsg"].firstObject :
        ([root.name isEqualToString:@"msg"] ?
         [[[root elementsForName:@"extcommoninfo"].firstObject elementsForName:@"refermsg"] firstObject] : nil);
    if (!isTextReply && !reference) return nil;
    if (textReply) *textReply = isTextReply;
    NSString *title = isTextReply ? ([[app elementsForName:@"title"].firstObject stringValue] ?: @"") :
        YMQuoteTypeLabel([NSString stringWithFormat:@"%u", originType], raw);
    NSString *name = [[reference elementsForName:@"displayname"].firstObject stringValue] ?: @"";
    // Build 269079 原生引用查询 0x480D2B0 -> 0x4671A6C：排除群 ID，
    // 两个不同的个人 ID 属于歧义，保留引用原名而不猜测联系人。
    NSString *from = [[reference elementsForName:@"fromusr"].firstObject stringValue];
    NSString *chat = [[reference elementsForName:@"chatusr"].firstObject stringValue];
    BOOL fromRoom = [from hasSuffix:@"@chatroom"] || [from hasSuffix:@"@im.chatroom"];
    BOOL chatRoom = [chat hasSuffix:@"@chatroom"] || [chat hasSuffix:@"@im.chatroom"];
    NSString *contactID = fromRoom ? chat : (chatRoom || !chat.length ? from : chat);
    if ((fromRoom && chatRoom) || (!fromRoom && !chatRoom && from.length && chat.length &&
        ![from isEqualToString:chat])) contactID = nil;
    NSString *remark = contactID.length ? YMQueryContactRemark(contactID) : nil;
    if (remark.length) name = remark;
    NSString *content = [[reference elementsForName:@"content"].firstObject stringValue] ?: @"";
    NSString *type = [[reference elementsForName:@"type"].firstObject stringValue];
    // 非文字引用不输出原始 XML、路径或媒体元数据。
    if (![type isEqualToString:@"1"]) {
        content = YMQuoteTypeLabel(type, content);
    } else if (!content.length) {
        content = @"[引用内容不可用]";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *__strong part in @[title, name, content]) {
        if (part.length > 600) {
            NSUInteger end = [part rangeOfComposedCharacterSequenceAtIndex:600].location;
            part = [[part substringToIndex:end] stringByAppendingString:@"…"];
        }
        [parts addObject:part];
    }
    return [NSString stringWithFormat:@"%@\n引用：%@%@%@", parts[0], parts[1],
            [parts[1] length] ? @"：" : @"", parts[2]];
}

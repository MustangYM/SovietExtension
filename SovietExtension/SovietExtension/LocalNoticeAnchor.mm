#import "LocalNoticeAnchor.h"

namespace {
NSString *const markerName = @"soviet_local_notice_anchor";
bool validSession(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > 128) return false;
    return NSEqualRanges([value rangeOfString:@"^(?:[A-Za-z0-9_-]{1,128}|[0-9]+@chatroom)$"
        options:NSRegularExpressionSearch], NSMakeRange(0, value.length));
}

bool validToken(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 36) return false;
    return [[[NSUUID alloc] initWithUUIDString:value].UUIDString isEqualToString:value];
}

NSString *anchorDecimal(uint64_t value) {
    return [NSString stringWithFormat:@"%llu", (unsigned long long)value];
}

bool validID(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 20) return false;
    uint64_t result = 0;
    for (NSUInteger i = 0; i < [value length]; ++i) {
        unichar digit = [value characterAtIndex:i];
        if (digit < '0' || digit > '9' || result > (UINT64_MAX - (digit - '0')) / 10) return false;
        result = result * 10 + digit - '0';
    }
    return result && [anchorDecimal(result) isEqual:value];
}

bool validAnchor(NSDictionary *anchor) {
    return [anchor isKindOfClass:NSDictionary.class] && anchor.count == 4 &&
        validToken(anchor[@"token"]) && validSession(anchor[@"account"]) &&
        validSession(anchor[@"session"]) && validID(anchor[@"originalServerID"]);
}

NSXMLDocument *parseXML(NSString *xml) {
    if (![xml isKindOfClass:NSString.class] || !xml.length || xml.length > 1024 * 1024 ||
        [xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location != NSNotFound) return nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:xml
        options:NSXMLNodeLoadExternalEntitiesNever | NSXMLNodePreserveCDATA error:nil];
    if (![doc.rootElement.name isEqual:@"sysmsg"] || doc.rootElement.URI.length || doc.DTD) return nil;
    return doc;
}

NSArray<NSXMLNode *> *markers(NSXMLDocument *doc) {
    return [doc nodesForXPath:@"//*[local-name()='soviet_local_notice_anchor']" error:nil];
}

}

NSDictionary *YMCreateLocalNoticeAnchor(NSString *account, NSString *session, uint64_t originalServerID) {
    if (!validSession(account) || !validSession(session) || !originalServerID) return nil;
    return @{@"token": NSUUID.UUID.UUIDString, @"account": account, @"session": session,
        @"originalServerID": anchorDecimal(originalServerID)};
}

NSString *YMAddLocalNoticeAnchorToXML(NSString *xml, NSDictionary *anchor) {
    @try {
        if (!validAnchor(anchor)) return nil;
        NSXMLDocument *doc = parseXML(xml);
        if (!doc || markers(doc).count) return nil;
        NSXMLElement *node = [NSXMLElement elementWithName:markerName];
        // 关联随系统消息一起入库，不另存文件，也不需要落库后再次绑定。
        for (NSString *key in @[@"token", @"account", @"session", @"originalServerID"])
            [node addAttribute:[NSXMLNode attributeWithName:key stringValue:anchor[key]]];
        [doc.rootElement addChild:node];
        return doc.XMLString;
    } @catch (__unused NSException *exception) { return nil; }
}

NSDictionary *YMResolveLocalNoticeAnchor(NSString *xml, NSString *account, NSString *session,
                                        uint32_t type, uint64_t serverID) {
    @try {
        if (type != 10000 || serverID || !validSession(account) || !validSession(session) ||
            ![xml isKindOfClass:NSString.class] || [xml rangeOfString:markerName].location == NSNotFound) return nil;
        NSXMLDocument *doc = parseXML(xml);
        NSArray<NSXMLNode *> *nodes = doc ? markers(doc) : nil;
        if (nodes.count != 1) return nil;
        NSXMLElement *node = (NSXMLElement *)nodes.firstObject;
        if (node.parent != doc.rootElement || ![node.name isEqual:markerName] || node.URI.length ||
            node.childCount || node.attributes.count != 4) return nil;
        NSMutableDictionary *anchor = [NSMutableDictionary dictionary];
        for (NSXMLNode *attribute in node.attributes) {
            if (attribute.URI.length || !attribute.name || !attribute.stringValue || anchor[attribute.name]) return nil;
            anchor[attribute.name] = attribute.stringValue;
        }
        if (!validAnchor(anchor) || ![anchor[@"account"] isEqual:account] ||
            ![anchor[@"session"] isEqual:session]) return nil;
        return [anchor copy];
    } @catch (__unused NSException *exception) { return nil; }
}

#import "WXKRecall.h"
#import "WXKBridge.h"
#import "WXKMsgStore.h"
#import "WXKLog.h"
#import "WXKPrefs.h"
#import "WXKCommon.h"
#import "WXKToast.h"

@interface WXKRecall ()
+ (NSString *)stringInXML:(NSString *)xml tag:(NSString *)tag;
+ (long long)numberInXML:(NSString *)xml tag:(NSString *)tag;
@end

@implementation WXKRecall

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [WXKBridge addMessageHandler:^(id wrap) {
            [self handleWrap:wrap];
        }];
        WXKLog(@"[recall] 防撤回已启用（%@）",
               [WXKPrefs shared].boolRecallEnabled ? @"开" : @"关");
    });
}

+ (void)handleWrap:(id)wrap {
    if (![WXKPrefs shared].boolRecallEnabled) {
        return;
    }
    if (![WXKBridge isSystemWrap:wrap]) {
        return;
    }
    NSString *content = [WXKBridge contentOfWrap:wrap];
    if (![content containsString:@"revokemsg"] && ![content containsString:@"撤回"]) {
        return;
    }

    long long serverId = [self numberInXML:content tag:@"newmsgid"];
    if (!serverId) serverId = [self numberInXML:content tag:@"oldmsgid"];
    if (!serverId) serverId = [self numberInXML:content tag:@"msgid"];

    NSString *session = [self stringInXML:content tag:@"session"] ?: [WXKBridge sessionOfWrap:wrap];
    NSString *replaceMsg = [self stringInXML:content tag:@"replacemsg"] ?: @"撤回了一条消息";

    WXKMsgRecord *original = [WXKMsgStore recordForServerId:serverId session:session];
    if (!original) {
        original = [WXKMsgStore recordForLocalId:serverId session:session];
    }

    if (!original) {
        WXKLog(@"[recall] 检测到撤回，但缓存里没有 id=%@（会话=%@）原文：%@",
               @(serverId), session, replaceMsg);
        // 兜底提示，至少让用户知道发生过撤回
        [WXKToast show:[NSString stringWithFormat:@"%@（原文未捕获）", replaceMsg]];
        return;
    }

    NSString *who = original.sender.length ? original.sender : @"对方";
    [WXKMsgStore addRecallRecord:original by:who session:session];
    if ([WXKPrefs shared].boolRecallToast) {
        [WXKToast show:[NSString stringWithFormat:@"%@ 撤回：%@", who, original.content]];
    }
}

/* ---------------- 极简 XML 取值（不引入 XML 解析器，够用且不会崩） ---------------- */

+ (NSString *)stringInXML:(NSString *)xml tag:(NSString *)tag {
    if (!xml.length || !tag.length) return nil;
    NSString *pattern = [NSString stringWithFormat:@"<%@>(?:<!\\[CDATA\\[)?(.*?)(?:\\]\\]>)?</%@>", tag, tag];
    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:NSRegularExpressionDotMatchesLineSeparators
                                                                         error:NULL];
    NSTextCheckingResult *m = [rx firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    NSString *value = [xml substringWithRange:[m rangeAtIndex:1]];
    return value.length ? value : nil;
}

+ (long long)numberInXML:(NSString *)xml tag:(NSString *)tag {
    NSString *value = [self stringInXML:xml tag:tag];
    return value.length ? [value longLongValue] : 0;
}

@end

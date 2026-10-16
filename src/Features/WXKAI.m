#import "WXKAI.h"
#import "WXKBridge.h"
#import "WXKMsgStore.h"
#import "WXKLog.h"
#import "WXKPrefs.h"
#import "WXKCommon.h"

static NSMutableDictionary<NSString *, NSNumber *> *gLastReplyAt = nil;   // 会话 -> 上次回复时间
static NSMutableSet<NSString *> *gPending = nil;                          // 正在生成回复的会话
static NSMutableArray<NSString *> *gSentContents = nil;                   // 自己发出过的内容，避免自问自答
static NSString *gLastStatus = @"未运行";

@interface WXKAI ()
+ (BOOL)isMentioned:(id)wrap content:(NSString *)content;
+ (NSURL *)endpointURL;
+ (void)requestReplyForSession:(NSString *)session
                        sender:(NSString *)sender
                    completion:(void (^)(NSString *reply, NSString *error))completion;
+ (NSString *)textFromResponseJSON:(id)json;
@end

@implementation WXKAI

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLastReplyAt = [NSMutableDictionary dictionary];
        gPending = [NSMutableSet set];
        gSentContents = [NSMutableArray array];
        [WXKBridge addMessageHandler:^(id wrap) {
            [self handleWrap:wrap];
        }];
        WXKLog(@"[ai] 模块已装载（%@）", [WXKPrefs shared].boolAIEnabled ? @"已开启" : @"未开启");
    });
}

+ (NSString *)lastStatus {
    return gLastStatus;
}

+ (void)handleWrap:(id)wrap {
    WXKPrefs *prefs = [WXKPrefs shared];
    if (!prefs.boolEnabled || !prefs.boolAIEnabled) {
        return;
    }
    if ([WXKBridge isSystemWrap:wrap]) {
        return;
    }

    NSString *content = [WXKBridge contentOfWrap:wrap];
    if (!content.length || [content hasPrefix:@"<"]) {
        return;   // 空内容或 XML（系统/链接卡片）
    }
    NSInteger type = [WXKBridge typeOfWrap:wrap];
    if (type != 0 && type != 1) {
        WXKLogVerbose(@"[ai] 跳过非文本消息 type=%ld", (long)type);
        return;
    }

    // 跳过自己发出去的内容（有些版本会把本机发送也回灌到回调里）
    @synchronized (gSentContents) {
        if ([gSentContents containsObject:content]) {
            [gSentContents removeObject:content];
            WXKLogVerbose(@"[ai] 忽略自己刚发出的内容");
            return;
        }
    }

    NSString *session = [WXKBridge sessionOfWrap:wrap];
    NSString *sender = [WXKBridge actualSenderOfWrap:wrap];
    NSString *selfName = [WXKBridge selfUserName];
    if (selfName.length && [sender isEqualToString:selfName]) {
        return;
    }
    if (!session.length) {
        return;
    }

    BOOL isGroup = [WXKBridge isGroupSession:session];
    if ([prefs boolForKey:WXKKeyAIPrivateOnly] && isGroup) {
        WXKLogVerbose(@"[ai] 群聊已按设置跳过");
        return;
    }
    if (isGroup && [prefs boolForKey:WXKKeyAIGroupMentionOnly] && ![self isMentioned:wrap content:content]) {
        WXKLogVerbose(@"[ai] 群里没 @我，跳过");
        return;
    }

    // 冷却
    NSInteger cooldown = MAX(0, [prefs integerForKey:WXKKeyAICooldown]);
    NSNumber *last = gLastReplyAt[session];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (last && cooldown > 0 && now - last.doubleValue < cooldown) {
        WXKLogVerbose(@"[ai] %@ 还在冷却（剩 %.0fs）", session, cooldown - (now - last.doubleValue));
        return;
    }
    @synchronized (gPending) {
        if ([gPending containsObject:session]) {
            WXKLogVerbose(@"[ai] %@ 上一条还在生成", session);
            return;
        }
        [gPending addObject:session];
    }

    WXKLog(@"[ai] 触发自动回复：会话=%@ 发送者=%@ 群=%@ 内容=%@",
           session, sender, isGroup ? @"是" : @"否",
           prefs.boolLogContent ? content : [NSString stringWithFormat:@"<%lu 字>", (unsigned long)content.length]);

    [self requestReplyForSession:session sender:sender completion:^(NSString *reply, NSString *error) {
        @synchronized (gPending) {
            [gPending removeObject:session];
        }
        if (!reply.length) {
            gLastStatus = error ?: @"没有生成回复";
            WXKLog(@"[ai] 生成失败：%@", gLastStatus);
            return;
        }
        gLastReplyAt[session] = @([[NSDate date] timeIntervalSince1970]);
        gLastStatus = [NSString stringWithFormat:@"成功：%@", reply];
        // 稍等一小会儿再发，避免和微信自身的消息处理抢时序
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @synchronized (gSentContents) {
                [gSentContents addObject:reply];
                while (gSentContents.count > 20) {
                    [gSentContents removeObjectAtIndex:0];
                }
            }
            if (![WXKBridge sendText:reply toSession:session]) {
                gLastStatus = @"生成了回复但发送失败（见日志）";
                WXKLog(@"[ai] 发送失败，回复内容：%@", reply);
            }
        });
    }];
}

+ (BOOL)isMentioned:(id)wrap content:(NSString *)content {
    NSString *source = [WXKBridge msgSourceOfWrap:wrap] ?: @"";
    NSString *selfName = [WXKBridge selfUserName];
    if (selfName.length && [source containsString:selfName]) {
        return YES;
    }
    NSString *display = [WXKBridge selfDisplayName];
    if (display.length && [content containsString:[@"@" stringByAppendingString:display]]) {
        return YES;
    }
    return NO;   // "@所有人" 不算，避免刷屏
}

/* ---------------- 请求模型 ---------------- */

+ (NSURL *)endpointURL {
    NSString *base = [[WXKPrefs shared] stringForKey:WXKKeyAIBaseURL];
    base = [base stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!base.length) return nil;
    if ([base hasSuffix:@"/chat/completions"]) {
        return [NSURL URLWithString:base];
    }
    while ([base hasSuffix:@"/"]) {
        base = [base substringToIndex:base.length - 1];
    }
    return [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
}

+ (void)requestReplyForSession:(NSString *)session
                        sender:(NSString *)sender
                    completion:(void (^)(NSString *reply, NSString *error))completion {
    WXKPrefs *prefs = [WXKPrefs shared];
    NSURL *url = [self endpointURL];
    NSString *key = [prefs stringForKey:WXKKeyAIAPIKey];
    NSString *model = [prefs stringForKey:WXKKeyAIModel];
    if (!url || !key.length || !model.length) {
        completion(nil, @"AI 配置不完整（需要 Base URL、API Key、模型名）");
        return;
    }

    NSMutableArray *messages = [NSMutableArray array];
    NSString *systemPrompt = [prefs stringForKey:WXKKeyAISystemPrompt];
    if (systemPrompt.length) {
        [messages addObject:@{@"role": @"system", @"content": systemPrompt}];
    }
    NSInteger contextCount = MAX(1, MIN(30, [prefs integerForKey:WXKKeyAIContextMessages]));
    NSArray<WXKMsgRecord *> *context = [WXKMsgStore recentMessagesForSession:session limit:contextCount];
    for (WXKMsgRecord *record in context) {
        if (!record.content.length || [record.content hasPrefix:@"<"]) continue;
        [messages addObject:@{@"role": record.outgoing ? @"assistant" : @"user",
                              @"content": record.content}];
    }

    NSInteger maxLength = MAX(32, MIN(2000, [prefs integerForKey:WXKKeyAIMaxLength]));
    NSDictionary *body = @{
        @"model": model,
        @"messages": messages,
        @"temperature": @([prefs doubleForKey:WXKKeyAITemperature]),
        @"max_tokens": @(maxLength),
        @"stream": @NO,
    };

    NSError *jsonError = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!payload) {
        completion(nil, [NSString stringWithFormat:@"请求体序列化失败：%@", jsonError.localizedDescription]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = payload;

    WXKLog(@"[ai] POST %@ model=%@ 上下文=%lu 条", url.absoluteString, model, (unsigned long)context.count);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, [NSString stringWithFormat:@"网络错误：%@", error.localizedDescription]);
            return;
        }
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (status < 200 || status >= 300) {
            NSString *detail = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                detail = json[@"error"][@"message"] ?: json[@"message"];
            }
            if (!detail.length && data.length) {
                detail = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (detail.length > 200) detail = [detail substringToIndex:200];
            }
            completion(nil, [NSString stringWithFormat:@"HTTP %ld %@", (long)status, detail ?: @""]);
            return;
        }
        NSString *text = [self textFromResponseJSON:json];
        if (!text.length) {
            completion(nil, @"响应里没有取到内容");
            return;
        }
        completion(text, nil);
    }];
    [task resume];
}

+ (NSString *)textFromResponseJSON:(id)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id choices = json[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || ![choices count]) return nil;
    id first = [choices firstObject];
    if (![first isKindOfClass:[NSDictionary class]]) return nil;
    id message = first[@"message"];
    NSString *text = nil;
    if ([message isKindOfClass:[NSDictionary class]]) {
        text = message[@"content"];
    } else if ([first[@"text"] isKindOfClass:[NSString class]]) {
        text = first[@"text"];
    }
    if (![text isKindOfClass:[NSString class]]) return nil;
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length ? text : nil;
}

+ (void)testConnection:(void (^)(BOOL, NSString *))completion {
    WXKPrefs *prefs = [WXKPrefs shared];
    NSURL *url = [self endpointURL];
    NSString *key = [prefs stringForKey:WXKKeyAIAPIKey];
    NSString *model = [prefs stringForKey:WXKKeyAIModel];
    if (!url || !key.length || !model.length) {
        completion(NO, @"配置不完整：Base URL / API Key / 模型名都要填");
        return;
    }
    NSDictionary *body = @{@"model": model,
                           @"messages": @[@{@"role": @"user", @"content": @"回复两个字：可用"}],
                           @"max_tokens": @(16),
                           @"stream": @NO};
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(NO, [NSString stringWithFormat:@"网络错误：%@", error.localizedDescription]);
            return;
        }
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSString *text = [self textFromResponseJSON:json];
        if (status / 100 == 2 && text.length) {
            completion(YES, [NSString stringWithFormat:@"连接正常，模型回复：%@", text]);
        } else {
            completion(NO, [NSString stringWithFormat:@"HTTP %ld %@", (long)status,
                            text ?: [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""]);
        }
    }] resume];
}

@end

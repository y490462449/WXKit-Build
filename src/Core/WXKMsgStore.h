#pragma once
#import <Foundation/Foundation.h>

/// 一条已记住的消息
@interface WXKMsgRecord : NSObject
@property (nonatomic, copy) NSString *session;      // 会话 id（好友 wxid 或 xxx@chatroom）
@property (nonatomic, copy) NSString *sender;       // 发送者
@property (nonatomic, copy) NSString *content;      // 正文
@property (nonatomic, copy) NSString *senderName;   // 展示名（尽力而为）
@property (nonatomic, assign) NSInteger type;
@property (nonatomic, assign) long long serverId;
@property (nonatomic, assign) long long localId;
@property (nonatomic, assign) NSTimeInterval time;
@property (nonatomic, assign) BOOL outgoing;
@end

/// 最近消息环形缓存 + 撤回记录。
/// 防撤回的原理：微信撤回只发一条系统提示，原文不会再来；所以必须在消息到达时就记住，
/// 撤回时再按消息 id 反查原文。
@interface WXKMsgStore : NSObject

+ (void)start;                                            // 注册为消息管线的一环
+ (void)rememberWrap:(id)wrap;
+ (WXKMsgRecord *)recordForServerId:(long long)serverId session:(NSString *)session;
+ (WXKMsgRecord *)recordForLocalId:(long long)localId session:(NSString *)session;
+ (NSArray<WXKMsgRecord *> *)recentMessagesForSession:(NSString *)session limit:(NSInteger)limit;
/// 当前缓存了多少条消息（自检用）
+ (NSInteger)cachedCount;

/// 撤回记录（持久化在 config 目录 recalls.plist）
+ (void)addRecallRecord:(WXKMsgRecord *)original by:(NSString *)who session:(NSString *)session;
+ (NSArray<NSDictionary *> *)recallRecords;
+ (void)clearRecallRecords;

@end

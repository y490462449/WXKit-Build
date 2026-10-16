#pragma once
#import <Foundation/Foundation.h>

/// 诊断：把注入后"微信里真实存在的类和方法"导出成文本。
/// 这个文件是整个项目能不能在你那版微信上跑起来的关键——
/// 每个微信大版本的内部类名都会变，拿到导出结果后按需补 WXKBridge.m 里的候选名即可。
@interface WXKDiagnostics : NSObject

/// 关键词过滤的类名清单（不导出微信全部类，避免文件过大）
+ (NSArray<NSString *> *)interestingClassNames;

/// 类名+方法列表明细文本
+ (NSString *)buildClassDumpWithMethodKeywords:(NSArray<NSString *> *)methodKeywords
                                         limit:(NSUInteger)limit;

/// 只读扫描：把"疑似收消息回调 / 发消息方法 / 消息服务 / 服务总线"直接列出来（带方法签名）。
/// 比导出全量类名小得多，几行文本就能发出来，适配新版本时优先用它。
+ (NSString *)hookProbeReport;

/// 写入容器（返回文件路径，失败返回 nil）
+ (NSString *)writeText:(NSString *)text fileName:(NSString *)fileName;

/// 可导出的文件（日志 / 探测报告 / 类名导出 / 撤回记录）
+ (NSArray<NSURL *> *)exportableFileURLs;

@end

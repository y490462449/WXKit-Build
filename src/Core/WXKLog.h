#pragma once
#import <Foundation/Foundation.h>

/// 写日志：同时进 os_log、内存环形缓冲（设置界面可看）与文件（可导出）
void WXKLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
/// 详细日志，仅当 log.verbose 打开时写
void WXKLogVerbose(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 内存中的最近日志（最多 1000 行）
NSArray<NSString *> *WXKLogSnapshot(void);
void WXKLogClear(void);

/// 日志文件绝对路径（在微信容器内）
NSString *WXKLogFilePath(void);
/// 把内存日志整体追加写回文件，便于一次性导出
BOOL WXKLogFlushToFile(void);

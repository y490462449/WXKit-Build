#pragma once
#import <Foundation/Foundation.h>

/// 极简配置存储。
/// 位置：<微信容器>/Library/Application Support/WXKit/config.plist
/// 用文件而不是 NSUserDefaults，是因为 TrollFools 注入时我们跑在微信沙盒里，
/// 写微信自己的 defaults 域会污染它的偏好设置。
@interface WXKPrefs : NSObject

+ (instancetype)shared;
+ (NSString *)configDirectory;   // 配置文件所在目录（会自动创建）
+ (NSString *)configPath;

- (NSDictionary *)allValues;
- (void)reload;
- (void)resetAll;

- (id)objectForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;

- (void)setObject:(id)value forKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)setDouble:(double)value forKey:(NSString *)key;
- (void)removeKey:(NSString *)key;

/* ---- 常用快捷属性 ---- */
@property (nonatomic, readonly) BOOL boolEnabled;
@property (nonatomic, readonly) BOOL boolVerbose;
@property (nonatomic, readonly) BOOL boolLogContent;
@property (nonatomic, readonly) BOOL boolFloating;
@property (nonatomic, readonly) BOOL boolRecallEnabled;
@property (nonatomic, readonly) BOOL boolRecallToast;
@property (nonatomic, readonly) BOOL boolAIEnabled;

@end

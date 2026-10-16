//
//  WXKCommon.h
//  WXKit —— 开源微信增强插件（自用）
//
//  说明：
//   - 本项目只使用 Objective-C runtime 做方法交换，不链接 CydiaSubstrate / ElleKit，
//     因此产出的 dylib 可以直接用 TrollStore + TrollFools 注入微信，无需越狱。
//   - 所有 hook 都是"存在才挂"：类名/方法名找不到时只写日志，绝不崩。
//     微信每个大版本的内部类名都可能变，具体名字请用"诊断 → 导出类名"确认。
//

#pragma once
#import <Foundation/Foundation.h>

#define WXK_VERSION              @"0.1.0"
#define WXK_NAME                 @"WXKit"
#define WXK_LOG_FILE             @"wxkit.log"
#define WXK_CLASS_DUMP_FILE      @"wxkit-classes.txt"

/// 配置变化通知（userInfo 为空，收到后重新读 WXKPrefs 即可）
extern NSString *const WXKPrefsChangedNotification;

/* ---------------- 配置键 ---------------- */

// 通用
extern NSString *const WXKKeyEnabled;              // BOOL 总开关
extern NSString *const WXKKeyOverrideText;         // 候选名覆盖原文（设置页粘贴，适配不同微信版本）
extern NSString *const WXKKeyOverrideMap;          // 解析后的候选名覆盖表
extern NSString *const WXKKeyFloating;             // BOOL 显示悬浮球
extern NSString *const WXKKeyFloatingX;            // double 悬浮球位置
extern NSString *const WXKKeyFloatingY;
extern NSString *const WXKKeyLogContent;           // BOOL 日志是否记录消息正文（默认关，注意隐私）
extern NSString *const WXKKeyVerboseLog;           // BOOL 详细日志

// 防撤回
extern NSString *const WXKKeyRecallEnabled;        // BOOL
extern NSString *const WXKKeyRecallToast;          // BOOL 撤回时屏幕内提示原文
extern NSString *const WXKKeyRecallKeep;           // int  最多保留多少条

// AI 自动回复（OpenAI 兼容接口，用你自己的 Key）
extern NSString *const WXKKeyAIEnabled;
extern NSString *const WXKKeyAIBaseURL;            // 例如 https://api.deepseek.com/v1
extern NSString *const WXKKeyAIAPIKey;
extern NSString *const WXKKeyAIModel;              // 例如 deepseek-chat
extern NSString *const WXKKeyAISystemPrompt;
extern NSString *const WXKKeyAIPrivateOnly;        // BOOL 只回私聊
extern NSString *const WXKKeyAIGroupMentionOnly;   // BOOL 群里只回 @我
extern NSString *const WXKKeyAICooldown;           // int  同一会话冷却秒数
extern NSString *const WXKKeyAIMaxLength;          // int  回复最大字数
extern NSString *const WXKKeyAIContextMessages;    // int  带上文条数
extern NSString *const WXKKeyAITemperature;        // double

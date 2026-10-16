# WXKit —— 开源微信增强插件（自用）

一个从零写的 iOS 微信插件工程。目标设备：**iPhone 12 Pro Max / iOS 15.4.1 / TrollStore（巨魔）**，
同时兼容越狱安装。

**这个项目不是任何现成插件的拷贝**：代码全部重写，实现方式也不同——不链接 CydiaSubstrate / ElleKit，
只使用 Objective-C runtime 做方法交换，所以产出的 dylib 在**不越狱**的设备上也能被 TrollFools 注入加载。

---

## 1. 先说清楚边界

**包含的功能**

| 模块 | 说明 |
|---|---|
| 防撤回 | 消息到达即缓存，对方撤回时按消息 id 反查原文，存进"撤回记录"，可选屏幕内提示 |
| AI 自动回复 | 直连你自己配置的 OpenAI 兼容接口（DeepSeek / OpenAI / 本地 Ollama 都行），带上下文、冷却、群聊 @我 规则 |
| 诊断导出 | 一键导出「微信里真实存在的类名 + 方法名 + 方法签名」，这是适配任何微信版本的关键 |
| 设置面板 | 悬浮球入口，不需要 PreferenceLoader，注入方式下也能改配置 |
| 日志 | 带环形缓冲 + 文件落盘，出问题可以直接导出给维护者看 |

**不包含，也不打算做的功能**

- 自动抢红包、自动收款等资金相关的自动化；
- 猜拳、骰子等游戏作弊；
- 伪造点赞 / 伪集赞这类欺骗他人的功能；
- 模拟定位。

原因很直接：这些是在占别人便宜或欺骗别人，不是"增强自己的使用体验"。另外也**不包含任何破解付费功能的代码**，
AI 用的是你自己的 API Key 和自己的额度。

## 2. 两条部署路线，先选一条

### 路线 A：TrollStore + TrollFools 注入 dylib（不越狱）

1. 用 GitHub Actions 出一个 `WXKit.dylib`（见第 3 节）。**这条路线只需要 dylib，`.deb` 你用不到。**
2. **关键前提**：App Store 版微信是加密的（FairPlay），对加密包注入成功率低、常见结果是闪退，
   实践中要用**解密版微信 IPA**：
   - 先拿到解密版 IPA（自己临时越狱解密是最可控的方式），用 TrollStore 装微信；
   - 先裸跑一次微信确认正常，再用 TrollFools 选微信 → 注入 → 选 `WXKit.dylib`；
   - 需要签名的话，用 CI 同时产出的 `WXKit-signed.dylib`（已 `ldid -S`）。
3. 重启微信，出现「WX」悬浮球即注入成功。

> 完整步骤（解密 IPA 的两条路、备份、验证清单、故障对照、回滚）见
> **[docs/TROLLSTORE.md](docs/TROLLSTORE.md)**。

### 路线 B：Dopamine rootless 越狱（推荐，最省事）

你的机型与系统正好在支持范围内（A12–A15 / iOS 15.0–15.4.1）：

1. 用 Dopamine 越狱（rootless），装 Sileo；
2. 安装 CI 产出的 `com.wxkit.tweak_0.1.0_iphoneos-arm64.deb`；
3. 因为走的是 MobileSubstrate 过滤器（`Filter.Executables = WeChat`），只有微信会加载本插件；
4. 好处：**不需要解密版微信**，也不会因为改 App 包导致签名/推送出问题。

> 如果 Dopamine 下 dylib 不加载，多半是签名问题：`ldid -S build/WXKit.dylib` 补一个 ad-hoc 签名后重新打包即可。
> 越狱本身有风险（掉数据、无法 OTA、部分银行/支付类 App 检测越狱）。是否越狱自行判断。

## 3. 怎么编译出你要的文件

本地没有 macOS 也没关系，**用 GitHub Actions 编**：

```bash
# 1. 建一个空仓库，把 WXKit/ 里的内容推上去
git init && git add . && git commit -m "init WXKit" && git push

# 2. 打开仓库 Actions → build → 等两分钟
# 3. 在 Artifacts 里下载：
#    WXKit-dylib → WXKitProbe.dylib（先注这个验证链路）、WXKit.dylib、WXKit-signed.dylib
#    WXKit-deb   → packages/*.deb                            （路线 B，越狱才用）
```

CI 做三件事：静态检查 → 编译 dylib（并额外产出一份 ad-hoc 签名副本）→ 校验它
**没有链接 substrate/ellekit**（链接了就会在 TrollFools 下加载失败，直接让构建失败）；
另一个 job 打 rootless `.deb`。

如果你有 Mac，本地也可以：

```bash
# 只做 dylib（不需要 Theos）
chmod +x scripts/build-dylib.sh && ./scripts/build-dylib.sh

# 做 .deb（需要 Theos + iPhoneOS SDK）
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

## 4. 装好之后第一步：运行自检 + 导出诊断

**这步最重要。** 微信每个大版本都会改内部类名，我写的 hook 目标都是"候选名 + 存在才挂"，
在你那版微信上大概率有一部分命中、一部分落空。落空的功能不会崩，只是不工作。

1. 点悬浮球 → 设置 → **运行自检**：报告里 ✅/❌ 会直接告诉你哪一环没通
   （配置可写 / 关键类是否存在 / 服务能不能取到 / 新消息回调是否挂上 / 候选名覆盖 / AI 配置完整性）；
2. 设置 → **自动探测 hook 目标**（推荐先发这个）：它在手机上直接扫出"疑似收消息回调 / 发消息方法 /
   服务总线"并带上**方法签名**，输出只有几行到几十行文本，比全量类名省事得多；
3. 设置 → **查看 hook / 探测报告**：看内置候选在你这个版本里到底存不存在、签名是什么；
4. 设置 → **导出类名与方法**：全量清单（探针不够用时才需要）；
5. 设置 → **导出文件**：一次性把日志、探针、自检、类名分享出来。

**如果探针给出的真实名字和内置候选不一样**，不用重新编译注入：

> 设置 → **适配（候选名覆盖）** → 粘贴 `msgclass = xxx` / `incoming = xxx` 这样的几行 → 保存
> → 点 **重试挂载消息回调**（改了启动期就用到的项就重启微信）。
> 详见 [docs/HOOKS.md](docs/HOOKS.md) 的「★ 最快路径」。

文件在微信容器里：

```
<微信容器>/Library/Application Support/WXKit/
    wxkit-selftest.txt      ← 自检报告
    wxkit-diagnostic.txt    ← 探测报告（哪些类/方法存在 + 方法签名）
    wxkit-classes.txt       ← 全量类名 + 方法列表（关键）
    wxkit.log               ← 运行日志
    recalls.plist           ← 撤回记录
```

拿到导出文件后：

```bash
python tools/analyze_dump.py wxkit-classes.txt
```

它会按「新消息回调 / 发消息方法 / 撤回 / 服务定位」分类列出候选方法（含参数个数），
据此把 `src/Core/WXKBridge.m` 顶部的候选名换成你版本的真实名字。
完整步骤、故障对照表、回归清单见 **[docs/HOOKS.md](docs/HOOKS.md)**。

> 当前状态：**这份代码还没有在你的机型上跑过**。本机没有 macOS/编译器，我做到的是：
> 用一个自研静态检查器（`tools/check_sources.py`）验证括号配平、头文件声明与实现一致、
> 给自家类发的 selector 都存在、C 函数都有声明、中文字符串引号没写错 —— 当前 **0 问题**，
> 并且用"故意注入错误"的方式验证过这个检查器真的能报错；
> 再加上 CI 里真实的 clang 编译与依赖校验。真机行为需要按上面流程迭代一到两轮。
> CI 的 `lint` job 会把静态检查作为编译的前置门槛。

## 5. AI 自动回复怎么配

设置 → AI 自动回复，填三项：

| 项 | 例子 |
|---|---|
| Base URL | `https://api.deepseek.com/v1`（会自动拼 `/chat/completions`） |
| API Key | 你自己的 key |
| 模型名 | `deepseek-chat` / `gpt-4o-mini` / `qwen2.5:7b`（Ollama 本地：`http://127.0.0.1:11434/v1`） |

然后开总开关 + "AI 自动回复"，点"测试连接"确认通了。

规则项：只回私聊、群里仅 @我、同会话冷却秒数、最大字数、上下文条数、temperature、系统提示词。

**隐私提醒**：开启后，命中规则的聊天内容会发送到你自己配置的模型服务端。
设置里的"日志记录消息正文"默认是关的（日志里只记长度），要排错再打开。

## 6. 代码结构

```
src/
  WXKCommon.h/.m            配置键、通知名
  WXKEntry.m                插件入口（constructor）
  Core/
    WXKLog.h/.m             日志（os_log + 环形缓冲 + 文件）
    WXKPrefs.h/.m           配置存储（沙盒内 plist）
    WXKHook.h/.m            安全方法交换 + hook 记录 + 安全调用工具
    WXKBridge.h/.m          微信内部对象定位、CMessageWrap 字段读取、发消息、探测报告
    WXKMsgStore.h/.m        最近消息缓存 + 撤回记录持久化
  Features/
    WXKRecall.h/.m          防撤回
    WXKAI.h/.m              AI 自动回复
    WXKDiagnostics.h/.m     类名/方法导出、文件导出
    WXKSelfTest.h/.m        真机自检（不联网、不发消息）
  UI/
    WXKSettings.h/.m        设置面板（纯代码 UI，无 PreferenceLoader 依赖）
    WXKFloating.h/.m        悬浮球（独立小 UIWindow，不抢 keyWindow）
    WXKToast.h/.m           屏幕内提示
docs/HOOKS.md               hook 名称适配指南（改哪、怎么改、故障对照）
docs/TROLLSTORE.md          TrollStore + TrollFools 部署指南（解密 IPA、注入、验证、回滚）
docs/VERSIONS.md            版本适配记录（目标：微信 8.0.76 / iOS 15.4.1 / TrollStore）
tools/analyze_dump.py       诊断文件分析（按用途分类列出候选方法+签名）
tools/wechat_ipa_to_overrides.py
                            从解密版微信 IPA / 裸 Mach-O 直接生成「候选名覆盖」文本
tools/check_sources.py      静态检查：括号/@end/声明实现/selector/C 函数参数/引号
tools/selftest_checker.py   变异自测：故意注入 6 类错误，验证检查器真的能报出来
tools/selftest_build_scripts.sh
                            构建脚本自测：用假 xcrun 验证成功/失败路径（不需要 macOS）
scripts/build-dylib.sh      纯 clang 编译 dylib（带阶段标记，失败会打印 BUILD FAILED at stage=…）
scripts/build-probe.sh      编译最小注入探针（只验证链路，不挂 hook）
probe/WXKProbe.m            探针源码
.github/workflows/build.yml CI：lint（静态检查 + 两个自测）→ 编译 dylib
.github/workflows/deb.yml   CI：手动触发，打 rootless .deb（越狱才用）
```

### 想自己加 hook 的话

1. 在 `WXKBridge.m` 顶部的候选名列表里加你从诊断文件里找到的类名/selector；
2. 需要读消息字段就用 `WXKValueAny(wrap, @[@"字段名1", @"字段名2"])`，字段名不存在时返回 nil，不会崩；
3. 调试用 `WXKLog(@"...")`，设置里能直接看；
4. 改完先跑 `python tools/check_sources.py`，再推仓库让 CI 编译。

## 7. 验证状态（已做 / 待做）

我在这台机器上能做的验证都做了，剩下的两项必须在你那边跑（没有 macOS、没有真机）：

| 项目 | 方法 | 状态 |
|---|---|---|
| 括号配平、头文件引用 | `tools/check_sources.py` | ✅ 30 文件 0 问题 |
| 声明 ↔ 实现一致（含 `.m` 里的私有类） | 同上 | ✅ 0 问题 |
| 给自家类发的 selector 是否存在 | 同上（扫到 187 处跨类消息） | ✅ 0 问题 |
| C 函数声明与**调用参数个数** | 同上 | ✅ 0 问题 |
| 缺失 `@end` / 同类重复方法 | 同上 | ✅ 0 问题 |
| 中文串引号写错、**带参数方法用点语法**、`writeData:` 传错类型 | 同上（后两条来自真机 CI 的真实报错） | ✅ 0 问题 |
| 点语法访问不存在的属性（单例 / 带类型变量） | 同上（第三条规则，真机编译已认可的文件必须零误报） | ✅ 0 问题 |
| **检查器本身是否有效** | `tools/selftest_checker.py`：故意注入 10 类错误后必须报错 | ✅ 10/10 全部被抓出 |
| **构建脚本本身是否可靠** | `tools/selftest_build_scripts.sh`：用假 xcrun 跑成功与失败路径 | ✅ 成功路径 exit 0 且含 BUILD OK；失败路径 exit 1 且打印 `BUILD FAILED at stage=2/5 编译 line=41` |
| 未链接越狱专属库 | 源码 grep + CI 里 `otool -L` 校验 | ✅ 源码无引用 |
| YAML 工作流基本结构 | 制表符/缩进/行尾空格检查 | ✅ 无问题 |
| CI 调用静态检查的方式 | 以 `cwd=项目根 python tools/check_sources.py .` 实跑 | ✅ 通过 |
| **真实编译（clang）** | GitHub Actions（Xcode 15.4 / iPhoneOS 17.5 SDK） | 🔧 第一轮报出 2 处真错（点语法 + `writeData:`）已修复，等下一轮确认 |
| **真机行为（hook 是否挂上、字段名）** | 自检 + 日志 + 导出文件 | ⏳ 需你的设备 |
| **真机行为（hook 是否挂上、字段名）** | 自检 + 日志 + 导出文件 | ⏳ 需你的设备 |

## 8. 已知限制

- **未在真机验证**：hook 目标名来自公开的微信内部命名习惯 + 候选回退，需要按第 4 节迭代；
- 加密的 App Store 微信在 TrollFools 下可能注入失败，需要解密版 IPA；
- 微信可能在后续版本改动字段名，导致某个功能失效（不会崩溃）；
- 使用第三方注入属于微信用户协议不允许的行为，账号存在被限制的风险，请自行评估。

## 9. License

MIT。仅供个人在自己的设备上学习和使用。

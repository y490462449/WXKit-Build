# 版本适配记录

每个微信版本都需要一次真机适配：确认自检全 ✅、消息管线真的通。
这里记录适配过的版本，方便下次遇到新版本时对照。

## 编译问题记录（与微信版本无关，但值得留档）

| 时间 | 环境 | 问题 | 处理 |
|---|---|---|---|
| 2026-10-16 | Xcode 15.4 / iPhoneOS 17.5 SDK | `WXKMsgStore.m:125` `[WXKPrefs shared].integerForKey:KEY` —— 给**带参数的方法**用了点语法，硬编译错误 | 改成 `[[WXKPrefs shared] integerForKey:KEY]`；并给 `tools/check_sources.py` 加了"非法点语法"规则 |
| 2026-10-16 | 同上 | `WXKLog.m:47` 把 `NSString *` 传给要 `NSData *` 的 `writeData:`（warning，但实际会写坏日志文件） | 先 `dataUsingEncoding:` 再写；并加了 `writeData:` 参数类型规则 |

这两条规则现在都在 CI 的静态检查里，并且各自有一个变异测试用例（`tools/selftest_checker.py`）。

## 当前目标

| 项 | 值 |
|---|---|
| 机型 | iPhone 12 Pro Max（A14） |
| 系统 | iOS 15.4.1 |
| 安装方式 | TrollStore + TrollFools 注入 dylib（未越狱） |
| 微信版本 | **8.0.76** |

## 适配状态

| 微信版本 | iOS | 安装方式 | 状态 | 证据 / 备注 |
|---|---|---|---|---|
| 8.0.76 | 15.4.1 | TrollStore 注入 | ⏳ **待真机验证**（内置候选名未确认） | 等自检报告 + `wxkit-classes.txt`；大概率需要一段候选名覆盖文本 |
| — | — | — | — | 以后每适配一个版本，在这里加一行 |

> 状态只有三种：⏳ 待验证 / 🔧 适配中（已给出覆盖文本）/ ✅ 已验证（自检全绿 + 收发消息日志正常）。

## 新版本适配流程（不用重新注入）

1. 自检 → 看哪些 ❌；
2. 导出类名与方法（`wxkit-classes.txt`）；
3. `python tools/analyze_dump.py wxkit-classes.txt` 找出真实类名/方法名；
4. 设置 → **适配（候选名覆盖）** → 粘贴下面这种文本 → 保存；
5. 点 **重试挂载消息回调**（改了 `servicecenter`/`msgclass` 这类启动期就用到的项，就重启微信）；
6. 自检全 ✅ 后，把这一行状态改成 🔧/✅ 并附上覆盖文本，方便下次直接复用。

覆盖文本示例（键的含义见 [HOOKS.md](HOOKS.md)）：

```
msgclass = CMessageMgr
incoming = AsyncOnAddMsg:MsgWrap:
svrid    = m_n64MesSvrID
```

## 为什么不用"内置候选改代码"这条路

未越狱环境下改代码要重新编译 + 重新注入，一轮十几分钟；
候选名覆盖是几十秒的事。只有当某个钩子的**参数个数/位置**也变了（那就得改代码），
才需要回到改源码 + CI 的流程。

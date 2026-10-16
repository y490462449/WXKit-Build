# hook 名称适配指南

这个插件里所有和微信内部对接的地方都是**「候选名列表 + 存在才挂」**：
找不到类或方法时只写一条日志，不会崩，但那个功能不会生效。
微信每个大版本都可能改内部命名，所以拿到真机的导出结果后，按本文把候选名换成真实名字即可。

---

## ★ 最快路径：在设置里粘贴覆盖（不用重新编译、不用重新注入）

未越狱环境里改代码要重新编译 + 重新注入，一轮十几分钟。所以插件支持**候选名覆盖**：

设置 → **适配（候选名覆盖）** → 粘贴文本 → 保存 → 点 **重试挂载消息回调**
（如果改的是 `servicecenter` / `msgclass` 这类启动期就会用到的项，重启一次微信）。

| 键 | 对应什么 |
|---|---|
| `servicecenter` | 服务总线类名 |
| `servicecenterinit` | 服务总线单例方法 |
| `msgclass` | 消息服务类名 |
| `incoming` | **收消息回调 selector**（最关键） |
| `sendmsg` / `sendtext` | 发消息 selector |
| `contactclass` | 通讯录服务类名 |
| `content` / `type` / `from` / `to` / `svrid` / `localid` / `msgsource` | CMessageWrap 字段名 |

格式：每行 `键 = 名字`，一行可以写多个（用逗号分隔）。你写的名字排在内置候选**前面**，先命中先用：

```
# 8.0.x 示例
msgclass = CMessageMgr
incoming = AsyncOnAddMsg:MsgWrap:
svrid    = m_n64MesSvrID, m_uiMesSvrID
content  = m_nsContent
```

保存后到 **设置 → 查看当前生效的候选名** 确认顺序；这一机制只换名字，不动逻辑。

> 只有"某个回调的**参数个数/位置**变了"才必须回到改源码 + 走 CI 的流程；
> 单纯换名字都可以用覆盖文本搞定。

### 电脑上直接生成覆盖文本（有解密版 IPA 时更快）

不想在手机上导类名的话，把**解密版微信 IPA**放到电脑上跑：

```bash
python tools/wechat_ipa_to_overrides.py WeChat.ipa --out overrides.txt
```

它会做三件事：

1. 读出 `Info.plist`：确认这个包的 `MinimumOSVersion` ≤ 你的系统版本（顺带给你微信版本号）；
2. 从 Mach-O 里抽出 `__objc_classname` / `__objc_methname` / `__cstring`，按用途分组列出候选
   （收消息回调 `*MsgWrap:`、发消息、服务总线、消息服务类、字段名）；
3. 直接生成可粘贴的覆盖文本。

```bash
# 排查某个字段名/类名到底在不在（会告诉你在哪个段）
python tools/wechat_ipa_to_overrides.py WeChat.ipa --find m_nsContent
```

> 实测结论（拿原作 dylib 验证过）：字段名如 `m_nsContent` / `m_uiMessageType` / `m_n64MesSvrID`
> 存在于 `__TEXT,__objc_methname`；用字符串调用的 selector 会落在 `__cstring`，两个段都要扫。
> 注意：**App Store 下载的加密包 `__TEXT` 是密文**，类名/方法名会是乱码，必须用解密后的 IPA。

---

## 1. 候选名都在哪里

全部集中在 `src/Core/WXKBridge.m` 顶部，改这里就够了，不用动逻辑：

| 列表 | 作用 | 默认候选 |
|---|---|---|
| `WXKServiceCenterClasses()` | 服务总线 | `MMServiceCenter` 等 |
| `WXKServiceCenterSingletonSelectors()` | 服务总线单例方法 | `defaultCenter` 等 |
| `WXKMessageManagerClasses()` | 消息服务类 | `CMessageMgr`、`MessageService` 等 |
| `WXKIncomingMessageSelectors()` | **收消息回调**（最关键） | `AsyncOnAddMsg:MsgWrap:` 等 |
| `WXKSendMsgSelectors()` | 发消息（传 MsgWrap） | `SendMsg:`、`AsyncSendMsg:` 等 |
| `WXKSendTextSelectors()` | 发消息（直接传文本） | `SendTextMsg:toSession:` 等 |
| `WXKContactManagerClasses()` | 通讯录服务 | `CContactMgr` 等 |
| `WXKContentKeys()` / `WXKTypeKeys()` / `WXKFromKeys()` / `WXKToKeys()` / `WXKSvrIdKeys()` / `WXKLocalIdKeys()` / `WXKMsgSourceKeys()` | **CMessageWrap 字段名** | `m_nsContent`、`m_uiMessageType` 等 |

---

## 2. 在手机上拿到导出文件

1. 微信 → 悬浮球 → 设置 → **运行自检**：先看哪几项是 ❌；
2. 设置 → **导出类名与方法**（会生成 `wxkit-classes.txt`，只包含与消息/联系人/会话相关的类，不是微信全部类）；
3. 设置 → **导出文件** → 把文件发给维护者（或自己留着按下面步骤改）。

文件在微信容器里：

```
<微信容器>/Library/Application Support/WXKit/wxkit-classes.txt
```

---

## 3. 用工具把候选名收敛

```bash
python tools/analyze_dump.py wxkit-classes.txt
```

输出会按「新消息回调 / 发消息方法 / 撤回 / 服务定位 / 自身账号」分组，**并且带方法签名**，例如：

```
CMessageMgr  (super=NSObject)
   - AsyncOnAddMsg:MsgWrap:   v32@0:8@16@24
   - SendMsg:                 v32@0:8@16
```

`v32@0:8@16@24` 表示：返回 void、总长 32 字节、两个 `@`（对象）参数 —— 参数个数就是冒号个数，直接对上。

---

## 4. 怎么改（收消息回调为例）

假设 dump 里查到真实名字是 `AsyncOnAddMsg:MsgWrap:`，而自检显示当前没挂上，检查两点：

1. 类名对不对：`WXKMessageManagerClasses()` 里要有它；
   ```objc
   static NSArray<NSString *> *WXKMessageManagerClasses(void) {
       return @[@"CMessageMgr", @"MessageService", ...];   // ← 在这里补
   }
   ```
2. selector 对不对（注意别漏冒号）；
   ```objc
   static NSArray<NSString *> *WXKIncomingMessageSelectors(void) {
       return @[@"AsyncOnAddMsg:MsgWrap:", ...];
   }
   ```

改完重新构建注入，自检里「新消息回调已挂上」应变成 ✅。

> 参数个数不用你算：代码里按冒号个数自动选择 2 参 / 3 参的替换函数
> （`WXKOnAddMsg2` / `WXKOnAddMsg3`），传错参数个数会直接崩，所以这里是按签名匹配后再挂的。
> 如果 dump 里那个回调是 **3 个参数**且 MsgWrap 不是第 2 个，把 `WXKOnAddMsg3` 里的 `a2` 改成对应位置即可。

---

## 5. 字段名怎么确认

代码读 `CMessageWrap` 字段用的是 `WXKValueAny(wrap, @[@"候选1", @"候选2"])`，
取不到就返回 nil（不崩）。要看真实字段名，有两种办法：

1. **日志**：收到前 3 条消息时会把整条消息的所有字段转储进日志（设置 → 查看日志），
   形如 `m_nsContent (@"NSString") = ...`，字段名一目了然；
2. 直接把日志里看到的真实字段名补到对应的候选列表里。

> 默认日志**不记录消息正文**（只记长度），要排查字段名时到设置里打开「日志记录消息正文」，
> 排查完记得关掉。

---

## 6. 自检报告怎么读

| 检查项 | ❌ 说明 | 处理 |
|---|---|---|
| 配置文件目录可写 | 容器路径拿不到 | 罕见，回报 |
| 关键类存在（0/…) | 微信版本命名完全不同 | 导出类名，补 `WXKMessageManagerClasses()` 等 |
| 消息服务取不到 | 服务总线名字不同或还没起来 | 看 `MMServiceCenter` 是否 ❌；再试一次自检 |
| 自己的 wxid 未解析出 | 通讯录服务/自身联系人方法名不同 | 群聊 @我 与方向判断会受影响，补 `WXKContactManagerClasses()` |
| 新消息回调已挂上 ❌ | selector 不对 | 见第 4 节 |

---

## 7. 常见故障对照

| 现象 | 先看 | 原因 |
|---|---|---|
| 没有悬浮球 | 是否注入成功（TrollFools 列表里有没有 WXKit） | 注入失败 / 微信是加密版 |
| 有悬浮球，消息不触发 | 日志里有没有 `[pipeline] 新消息字段转储` | 收消息回调没挂上 |
| 防撤回记录为空 | 日志里有没有 `[store] 记住 …` | 回调没挂上，或字段名取不到 |
| 撤回时日志写「缓存里没有 id=…」 | 日志里的 id 与消息是否对得上 | `WXKSvrIdKeys()` 字段名不对 |
| AI 不回复 | 日志里有没有 `[ai] 触发自动回复` | 没触发（规则/冷却）还是没发送 |
| 日志出现「生成了回复但发送失败」 | 日志里的 `[send] … 上所有含 send 的方法：…` 列表 | 把那个列表发给维护者，按真实名字补 `WXKSendMsgSelectors()` |

---

## 8. 改完之后的回归清单

1. `python tools/check_sources.py` 必须 0 问题（括号、声明与实现、selector、C 函数）；
2. 推仓库 → Actions 两个 job 都绿（dylib 编译 + 依赖校验）；
3. 重新注入 → 自检全 ✅；
4. 收发一条文本消息、撤回一条、触发一次 AI 回复，再看日志确认三处都有记录。

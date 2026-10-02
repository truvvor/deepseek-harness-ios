# Harness Mobile 决策记录

状态：受控、追加式
规则：已接受决策不静默改写；新证据改变结论时新增“取代”记录。

## 决策索引

| ID | 决策 | 状态 | 采用日期 |
| --- | --- | --- | --- |
| D-001 | 工具、插件和命令仅在设备或 iSH 执行 | Amended by D-011 | 2026-09-03 |
| D-002 | Swift 原生 Agent + iSH Node Host-half | Accepted | 2026-08-31 |
| D-003 | BYOK 凭据只保存在 Keychain | Accepted | 2026-08-31 |
| D-004 | 当前以会话标题表达项目名称 | Accepted | 2026-08-31 |
| D-005 | SwiftUI 原生控件与共享语义主题优先 | Accepted | 2026-08-31 |
| D-006 | `VERIFY` 与真机证据分离 | Accepted | 2026-08-31 |
| D-007 | `project.yml` 是 Xcode 工程真源 | Accepted | 2026-08-31 |
| D-008 | 不支持下载原生代码与 Browser Client-half | Superseded by D-010 | 2026-09-03 |
| D-009 | 12 份控制文档由 `AGENTS.md` 路由 | Accepted | 2026-08-31 |
| D-010 | 桌面级插件对齐（取代 D-008） | Accepted | 2026-09-03 |
| D-011 | 可配置远程执行后端（修改 D-001） | Accepted | 2026-09-03 |
| D-012 | 桌面会话只读镜像；不把本地 Agent 循环送去远端 | Accepted | 2026-09-05 |

## D-001 · 设备内执行边界

模型推理可访问用户配置的 HTTPS API；工具、插件和命令默认在设备或 iSH 执行。D-011 允许用户显式配置的远程执行后端（e2b 沙箱、webhook 入站、ACP 远端），但不改变默认本机路径。

## D-011 · 可配置远程执行后端（修改 D-001）

状态：Accepted
日期：2026-09-03
修改：D-001

背景：
桌面版通过 e2b 沙箱执行代码、接收 webhook、经 ACP 连接子 agent。iOS 技术上可做相同出站（HTTPS）；旧 D-001 把"本机执行"当安全模型一刀切，阻止了这些能力。平台可行性重审（Docs/PLATFORM_FEASIBILITY_REAUDIT_2026-09-03.md）确认这些是产品/隐私决策而非 iOS 限制。

决策：
本机执行是默认；用户可显式配置以下远程执行后端，配置后可用：
1. e2b 代码沙箱（创建/执行/读取远端沙箱代码运行）。
2. webhook 入站（本地 server 通过隧道暴露可配端点，事件转入任务队列）。
3. ACP/子 agent 远端（经协议连接用户配置的远端 agent）。
每条都要用户界面可见的启用状态与数据披露；未配置的通道不存在、不产生网络请求、工具不注册。凭据仅存 Keychain。

后果：
SECURITY_GUIDELINES 第 5 条与相关边界行更新（默认本机 + 显式远程后端）。e2b/webhook/ACP 从"边界外"转为"配置驱动后端"。

验证：
决策本身已接受，但实现验收尚未闭合：e2b 客户端和真实沙箱链路仍为 TODO；webhook 当前只有解析、去重、规则注册和 loopback server 内核；ACP wire/transport 有测试，但默认 catalog 保持空，远端 agent 与真实配置仍为 VERIFY。隧道、真实远端凭据和真机网络必须单独验收。

## D-002 · Swift + iSH Host-half

安全敏感的 Agent loop、Provider、权限、存储和 UI 使用 Swift；需要 Node/Linux 语义的 Cordis Host-half 和命令运行于内嵌 iSH。避免在 JavaScriptCore 重新实现残缺 Node，也不把桌面 runtime 整体塞入 App。

## D-003 · BYOK 与 Keychain

API Key 使用设备专属 Keychain 引用，只有 Provider 请求路径在需要时解析。插件、iSH、会话、轨迹和导出不得持有凭据值。

## D-004 · 会话标题即当前项目名

现有持久化没有独立 Project 模型；首页复用 `ConversationSessionSummary.title` 作为项目名称，避免为了 UI 新建迁移和双重真源。若未来项目具有独立成员、文件根、权限或多会话生命周期，再用新 ADR 取代本决策。

## D-005 · 原生 UI 与共享主题

优先 SwiftUI 系统组件和 `HarnessTheme`；先删除重复内容，再考虑新增组件。这样保留 Dynamic Type、VoiceOver、系统交互和较小维护面。

## D-006 · 证据状态

模拟器、单元测试、签名构建、设备安装和真实交互是不同证据。没有需求指定的真机证据时状态保持 `VERIFY`，不得为了进度改成 `DONE`。

## D-007 · 工程生成

`project.yml` 是 XcodeGen 真源，生成的 `.xcodeproj` 同时提交以便直接打开。Target、权限、资源或构建脚本变化必须先在 `project.yml` 表达，并验证再生成结果。

## D-008 · 动态代码限制

允许验证后的原生清单和 iSH Host-half JavaScript；不支持 Browser Client-half、React slot、`.node` addon、下载的 Swift/framework 或机器码。无法安全适配时显示明确不兼容。

> **Superseded by D-010（2026-09-03）**：插件面改为桌面级对齐——host 运行时动态 define/run + 任意 Cordis/npm JS 包；native 清单降为可选后端；平台工具链限制报明确错误而非安全拒绝。

## D-009 · Harness 控制文档

`AGENTS.md` 是控制入口；PRD、设计、流程、前后端、安全、能力、技术、质量、平台、实施和决策文档按变更类型加载。详细事实保留在源码、测试和已有 `Docs/` 真源，控制文档不复制长清单。

## D-010 · 桌面级插件对齐（取代 D-008）

状态：Accepted
日期：2026-09-03
取代：D-008

背景：
D-008 以移动端自设安全模型限制插件面（只走 native 清单或 iSH Host-half JS）。桌面版通过本地 host 运行时（cordis-host-runner + tool-cordis）让模型动态 define/run/update/stop/undefine Cordis 包并加载任意 npm 生态依赖。设备上 host.mjs 已 import 上游全栈，通路存在，差异只在默认路径与工具面仍被旧模型主导。

决策：
插件面完全对齐桌面：模型可见并可用 `cordis_inspect_list/query/self/define/run/stop/undefine` 7 工具；市场与模型安装默认走本地 host 运行时装载，不再「先 native 编译」；允许加载任意 Cordis/npm JS 生态包。native 声明式清单保留为可选后端，非默认非前置。执行只在设备本地，不引入远程 executor（D-001 不变）。

平台能力事实：现有 `HarnessBrowserWebKitBackend` 已提供 WKWebView 容器，因此 Browser/React client-half 属可实现但尚未接入的工程差距，不再归类为平台不支持。`.node` 原生 addon、下载的 Swift/framework 二进制仍受 iOS/iSH 工具链限制，报明确平台限制错误。

后果：
AGENTS.md、SECURITY_GUIDELINES.md 相应条款按本文档修订（见 `Docs/DESKTOP_FULL_PARITY_2026-09-03.md` §1）。默认路径改变影响市场安装 UI 与安装协调器行为。native 编译相关代码保留可选、逐步退出默认路由。

验证：
P1：模拟器 iSH host 运行，模型工具目录出现 7 工具，`cordis_inspect_list` 真实返回注册表。
P2：市场安装走 host 装载；真实插件 define→run→stop 全链路通过。
P3：带 npm 依赖的真实 cordis 插件安装成功。


## D-012 · 桌面会话只读镜像，本地 Agent 循环不出设备

状态：Accepted
日期：2026-09-05
补充：D-001、D-010、D-011（均不因本决策改变）

背景：
桌面 DSH Host 上有用户真实的工作会话。用户需要在 iPhone 上读到这些会话；同时仓库的硬边界禁止把本机的 prompt、工具集和 Agent 循环交给另一台机器执行。`dsh-api-bridge` 在同一 Host 上暴露 `/bridge/v1`（bearer token，读接口 + SSE 镜像 + v4 JSONL 导出），Host 本身没有 TLS，正常形态是局域网或 tailnet/SSH 隧道。

决策：
1. （已被 D-014 取代）应用只**读**桌面会话：`GET /sessions`、`/sessions/{id}/messages`、`/sessions/{id}/export`、`/sessions/{id}/stream`。桥接客户端不实现 prompt、cancel、archive、chat-completions 任何写路由，因此结构上不可能把本机 prompt/工具/Agent 循环发到桌面。
2. （已被 D-014 取代）导入的会话是**只读镜像**：`ConversationSession.bridgeMirror` 记录来源，`isResumable` 恒为 `false`，`AppModel.send` 与重跑路径拒绝在镜像会话上启动本地 Agent 循环。桌面日志保持该会话的唯一历史权威。
3. 事件写入复用既有追加式边界 `SessionTrajectoryRepository.admitSyncEnvelope`（连续后缀、≤512 事件、assets/tombstones fail-closed），不为桥接新增第二套轨迹写路径。
4. 反向（手机轨迹 → 桌面）只允许用户显式触发的**单向上传**，且不携带任何凭据语义；本决策不开启该通道（`sessionLogEnabled` 保持关闭）。
5. （已被 D-013 取代）明文 HTTP 只允许指向用户自己的桌面桥接地址，并由 `NSAllowsLocalNetworking` + 单个 `NSExceptionDomains` 条目限定；不使用 `NSAllowsArbitraryLoads`，模型 Provider 仍强制 HTTPS。令牌只存 Keychain（`WhenUnlockedThisDeviceOnly`），只出现在 `Authorization` 头，不进入 URL、日志、设置、轨迹或导出。

后果：
`SECURITY_GUIDELINES.md` 第 5 条的“未配置不产生网络请求”对桥接同样成立：未启用或未存令牌时不创建客户端。`Docs/DESKTOP_PARITY_REMEDIATION.md` 记录实现与证据状态；脚本审计新增 `Core/Bridge/` 网络边界例外并注明只读理由。

验证：
代码、转换器和导入路径已有窄单元测试（见 `Docs/DESKTOP_PARITY_REMEDIATION.md` 的 BRIDGE-001）。真实桌面桥、隧道/局域网、iOS 真机网络与 ATS 行为尚未验收，状态保持 `VERIFY`。

## D-013 · 桌面桥接允许任意地址的明文 HTTP（取代 D-012 第 5 条）

状态：Accepted
日期：2026-10-02
取代：D-012 第 5 条（ATS 范围）；D-012 其余条款不变

背景：
用户会把桌面 DSH Host 直接暴露在公网或局域网的裸 IP 上（例如 `http://203.0.113.7:19387`）。`NSExceptionDomains` 不能用通配符描述 IP，而 `NSAllowsLocalNetworking` 只覆盖 `.local`/非限定主机名；并且 iOS 10+ 只要存在 `NSAllowsLocalNetworking`，`NSAllowsArbitraryLoads` 就会被忽略。按 D-012 的 ATS 配置，裸 IP 桥接地址无法连通。

决策：
1. `Info.plist` 的 `NSAppTransportSecurity` 只设置 `NSAllowsArbitraryLoads = true`，移除 `NSAllowsLocalNetworking` 与 `dsh-host.local` 例外。
2. HTTPS 约束改由代码执行，不再依赖 ATS：模型 Provider 仍只接受 `https` 源（`CredentialStore.validatedOrigin`），桥接地址由 `BridgeSettings.validatedBaseURL` 接受 `http`/`https`。
3. 明文 HTTP 下 bearer 令牌与会话内容以明文传输；设置页明确提示，推荐 HTTPS（反向代理或 tailnet）。桥接仍只读，D-012 第 1–4 条不变。

后果：
`web_fetch` 与内置浏览器原本就允许 `http` 方案，此前被 ATS 拦截，现在可以访问明文 HTTP 页面，与桌面版行为一致。

验证：
真机上对裸 IP 的 HTTP 桥接连通性尚未验收，状态保持 `VERIFY`。

## D-014 · 已连接时可在镜像会话中驱动桌面 Agent（取代 D-012 第 1、2 条）

状态：Accepted
日期：2026-10-02
取代：D-012 第 1 条（桥接客户端只读）与第 2 条（镜像会话只读）；D-012 第 3、4 条与 D-013 不变

背景：
用户需要在 iPhone 上继续桌面会话，而不只是阅读；桌面 DSH 是该会话的唯一主控（master），iPhone 只保存镜像日志。用户明确拒绝在手机上本地 fork 继续。`dsh-api-bridge` 已提供 `POST /bridge/v1/sessions/{id}/prompt`（阻塞至 `turn/end`，`mode: queue|steer`）与 `POST …/cancel`，由桌面同一个 `sessionController` 执行回合。

决策：
1. 对**已镜像的桌面会话**，在桥接已配置且启用时，输入框文本原样发送到 `POST …/prompt`；停止按钮发送 `POST …/cancel`。回合完全由桌面 Agent 用桌面的模型、工具和循环执行，并由桌面写入其日志。
2. 手机不在镜像会话上运行本地 Agent 循环、不写本地轨迹、不发送本机工具集、模型配置、凭据或附件；回合产生的事件只通过既有 `stream` 信号 + `/export` 后缀导入（`admitSyncEnvelope`）回到手机。镜像会话的编辑/重跑与本地命令仍被拒绝。
3. 这是**用户自己的桌面主机**上的会话控制，不是本机 Agent 的服务器执行回退：本地会话的模型推理、工具和命令边界（D-001、D-010、D-011）不变，桥接仍不实现 chat-completions、archive 或 `/sync/envelope` 上传。
4. 未连接（未启用、无令牌或网络失败）时发送明确报错，镜像保持只读。

后果：
`BridgeClient` 增加 `prompt`/`cancel` 两条写路由；`BridgeMirrorCoordinator.sendPrompt` 在回合期间重启镜像跟随以实时显示中间事件；`AppModel.submit` 在镜像会话中转发到桌面，`isChatBusy`/`cancelActiveTurn` 只驱动聊天界面。桥接在客户端断开时会中止桌面回合，因此应用在回合期间申请有限的后台执行时间；超出后台宽限期仍会中止，需要桥接侧支持断开后继续才能消除。

验证：
`HarnessMobileTests/BridgeClientPromptTests.swift` 覆盖请求路径、方法、令牌头、请求体、409/404/401 映射。真实桌面桥接下的回合、取消、前后台切换尚未在真机验收，状态保持 `VERIFY`。

## 新决策模板

```md
## D-XXX · 标题

状态：Proposed / Accepted / Superseded
日期：YYYY-MM-DD
取代/被取代：可选

背景：
决策：
后果：
验证：
```

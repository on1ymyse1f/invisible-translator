# 无感翻译（ClaudePromptTranslator 0.7.0）

一个原生 macOS 跨应用选区翻译工具。它的主流程已经从“只识别 AI 聊天输入框”调整为：

系统要求：macOS 15 或更高版本（核心翻译使用 Apple Translation）。

```text
任意浏览器 / 网页 / 原生 App 中选中文字
        ↓
Accessibility 快速读取（不碰剪贴板）
        ↓
本地识别语言并自动选择目标语言
        ↓
选区旁显示低打扰翻译浮层
        ↓
复制译文；仅在可验证的编辑区提供原位替换
```

对于不暴露文字的 Canvas、图片和视频字幕，另有明确启动、限定区域的本机 OCR 链路；它不会混入被动选区扫描。

旧的 Claude、ChatGPT、Gemini 输入与回复翻译仍保留为“AI 兼容模式”，但不再是通用选区翻译的前置条件。

> App 可见名称改为“无感翻译”，可执行文件名和 bundle id 仍保持 `ClaudePromptTranslator` / `local.codex.ClaudePromptTranslator`，避免升级时无故丢失已有的辅助功能授权。

## 当前功能

- 首次启动会显示“快速开始与安全自检”，双击重新打开 App 也会回到该窗口，不再出现“程序似乎没有打开”的无反馈状态。窗口把辅助功能授权、合成选区测试、AI 输入/回复流程和脱敏诊断收在一处；自检不会读取原文、译文、剪贴板或聊天记录。
- 快速开始页分别显示“通用选区自动路由”和“AI 草稿固定目标”，避免把两套语言设置误认为同一个开关；AI 边缘栏可直接选择中/EN/JP。
- 在 Safari、Chrome、Electron、原生 App 和常规网页中选中文字后，自动尝试读取选区。
- 被动识别优先使用触发 AX 通知的真实元素和鼠标松开位置，再检查焦点路径与最多 120 个局部子节点；除标准 `AXSelectedText` 外，也读取 WebKit/Chromium 常用的 Accessibility 文本标记选区。空结果只做两次有界延迟重试。它先过滤纯数字、URL、版本号等无意义字面量，不复制文字、不发送网络请求、不移动鼠标。
- 默认只显示选区旁的“翻译”按钮；用户点击后才开始翻译。
- 可选择开启“选中即自动翻译”。首次开启会明确提示：翻译只使用 Apple 本地语言包；缺少或不支持的语言组合会直接失败，不会静默发送到网络服务。
- `Control + Option + T` 在任意 App 直接翻译当前选区：
  1. Accessibility 焦点路径；
  2. AX 通知元素、指针命中元素及局部子树；
  3. 有界窗口树查找；
  4. 默认到此为止，不读取或改写系统剪贴板；
  5. 只有用户在菜单中明确开启并确认“剪贴板兼容模式”后，前三步失败时才优先按下应用自身的“复制”菜单；没有安全可识别的菜单项时才向原 PID 发送 `Command+C`；
  6. 兼容模式中只有 PID、焦点、选区、输入代次和单次 change count 均稳定时才使用结果并恢复完整剪贴板；任何歧义都放弃结果且不覆盖当前剪贴板。
- 自动语言路由：
  - 简体/繁体中文 → English
  - 英文、日文、韩文及其他语言 → 简体中文
  - 用户可关闭自动路由并固定为简体中文、English 或 Japanese。
- 新选区或新翻译会取消旧任务，旧结果不会覆盖新浮层。
- 选区浮层支持“原文 + 译文”或“仅显示译文”；12,000 字符以内的 Markdown 链接与基础强调会按富文本显示，超长内容自动退回纯文本以避免主线程解析卡顿。
- 浮层优先贴近真实选区；应用不提供选区坐标时，退回到当前鼠标附近，但程序只读取鼠标位置，从不控制或移动鼠标。
- 可选“鼠标悬停翻译”：指针稳定停留约 0.65 秒后，读取指针下方由 Accessibility 暴露的静态文本并自动翻译；输入框、搜索框、密码框和受保护内容均被排除，移动鼠标会取消尚未触发的读取。
- 默认启用“正文优先”内容筛选：在高置信度 X/Twitter 窗口中，被动选区与悬停会跳过导航、按钮、账号 handle、时间、互动计数、广告标签和独立 URL；显式选区与用户框选 OCR 永远保留用户选择，不会被站点规则擅自删减。无法确认站点时保持 fail-open，不猜测网页身份。
- 菜单栏提供“App 隐私名单”：1Password、钥匙串/密码、Bitwarden、Dashlane、LastPass、KeePassXC 等敏感 App 内置禁止读取；用户也可把当前 App 加入名单。加入后会取消正在进行的输入、选区、悬停、OCR、字幕与回复任务，并清除对应可见内容和内存缓存。
- “框选屏幕文字（OCR）”用于 Canvas、图片和不暴露文字的 App：用户拖出明确区域后，ScreenCaptureKit 只截取该区域，Vision 在本机识别，截图不落盘，识别完成后进入同一个翻译浮层。
- “视频字幕翻译”重复识别用户固定框选的字幕区域，不扫描整屏；字幕连续两帧稳定后才翻译，重复内容命中有界内存缓存。支持双语/仅译文、深色/浅色/高对比和三档字号。
- OCR 字幕使用本地基础合并与断句：去除重复行，拉丁文字按词间空格合并，中日韩文字按字幕行连续合并。当前没有把字幕发送给外部 AI 做断句。
- 长文本上限为输入 160,000 字符、AI 回复 96,000 字符、显式 OCR 60,000 字符；结构化分段上限为 3,000 字符。这里按 Swift Unicode 字符计数，并非 UTF-8 字节数。
- 只读网页、PDF 和普通文本可复制译文；只有 Accessibility 能验证选区仍未变化、目标确实可写时，才显示“替换选区”。
- 保留 AI 兼容边缘栏：聊天输入翻译只替换草稿且不会发送；回复按“当前 Accessibility 选区 → 同一 App/PID 的 15 秒 Accessibility 选区快照 → Accessibility 最新回复”读取，剪贴板来源不能进入回复快照。点击非激活边缘栏不会覆盖来源鼠标松开事件，快照到期会主动从内存清除。第一次“译回复”失败只显示“使用 OCR 重试”；只有用户第二次明确点击才可能请求屏幕录制，此时 ScreenCaptureKit 只包含目标窗口并在捕获阶段限制为按布局近似计算的对话区域，而不是先截整窗再裁剪。该区域可能包含同列可见历史对话，因此仍优先推荐明确选中回复。自动回复扫描永远不会截屏，回复链无论兼容开关如何都不会读取、写入或快照剪贴板。
- 旧备用输入窗已明确降级为高级草稿入口：文案不再声称会发送，`⌃⌥T` 只属于通用选区翻译。由于该入口需要把新文本插入另一个 App 的光标位置，目标不支持纯 AX 写入时仍需用户主动开启剪贴板兼容模式。

## 为什么不会再出现“点击翻译后鼠标被操控”

通用主链路没有点击坐标、拖动、聚焦猜测或鼠标事件注入。程序只做三类动作：

1. 读取 Accessibility 公开的选中文字和选区位置；
2. 用户明确按快捷键且 Accessibility 失败时，向原进程发送一次键盘复制命令；
3. 用户明确点击“替换选区”且目标可验证时，通过 Accessibility 写回。

浮层定位读取 `NSEvent.mouseLocation` 只是获取坐标，不会移动指针。

## 架构

关键文件：

- `Sources/ClaudePromptTranslator/UniversalSelection.swift`
  - 通用选区读取、语言路由、安全替换、剪贴板 fallback。
- `Sources/ClaudePromptTranslator/UniversalSelectionMonitor.swift`
  - 鼠标/键盘选区手势的 180ms 防抖触发；保留 AX 通知源元素和鼠标松开坐标，忽略落在本工具窗口内的点击，避免侧栏操作覆盖待处理选区；被动路径不访问剪贴板。
- `Sources/ClaudePromptTranslator/HoverTranslation.swift`
  - 0.65 秒稳定悬停、静态角色/敏感输入过滤、指针段落截取。
- `Sources/ClaudePromptTranslator/ScreenTextOCR.swift`
  - 多显示器区域框选、ScreenCaptureKit 单区域截图、Vision 本机 OCR 与取消。
- `Sources/ClaudePromptTranslator/LiveSubtitleTranslation.swift`
  - 稳定帧字幕去重、基础断句、内存翻译缓存和可定制双语浮层。
- `Sources/ClaudePromptTranslator/SelectionOverlayController.swift`
  - 选区旁的单一非激活浮层、复制与受控替换。
- `Sources/ClaudePromptTranslator/AppleTranslationCoordinator.swift`
  - 官方本地翻译会话、一次性语言包许可与结构保留。
- `Sources/ClaudePromptTranslator/AppModel.swift`
  - 任务代次、取消、隐私开关和通用/AI 兼容模块协调。
- `Sources/ClaudePromptTranslator/InputTarget.swift`
  - 旧 AI 输入框兼容与编辑区选区替换。
- `Sources/ClaudePromptTranslator/AIResponseReader.swift`
  - 旧 AI 回复翻译兼容模块；同时读取标准选区和 WebView 文本标记选区。自动扫描只走 Accessibility，用户明确点击后才允许 ScreenCaptureKit + OCR 兜底。

### 识别成本分级

```text
选区变化（自动，180ms 防抖）
  ├─ AX 通知元素 / 指针命中元素
  ├─ 焦点元素 + 最多 10 层祖先
  ├─ 每个局部根最多 120 个节点     不扫描整页
  └─ 空结果后 120ms / 260ms 重试   可取消、有界

明确按下 ⌃⌥T
  ├─ 通知/指针/焦点局部路径
  ├─ 最多 450 个 AX 节点          有界扫描
  ├─ 应用“复制”菜单动作
  └─ 定向 Command+C               仅显式开启兼容模式后

鼠标悬停（可选，650ms 稳定等待）
  └─ 指针下单个 AX 静态文本节点   不读输入框，不做窗口树扫描

框选 OCR / 实时字幕（显式启动）
  └─ 只截取用户指定矩形区域       Vision 本机识别；字幕两帧稳定后翻译
```

自动检测不会沿网页全文反复扫描，也不会像旧 AI 回复模块一样定时遍历整个窗口树。

## GitHub 参考与许可证边界

2026-08-07 通过 GitHub 与项目源码核对了以下项目：

| 项目 | 许可证 | 本项目吸收的思路 |
| --- | --- | --- |
| [KISS Translator](https://github.com/fishjar/kiss-translator) | GPL-3.0 | 只参考架构：事件/MutationObserver 增量扫描、稳定选择延迟、快速字面量过滤、批处理与缓存、可见区域优先、字幕去重和样式分层；原生端用 AX 与显式区域 OCR 独立实现，未复制代码 |
| [TextFlow](https://github.com/BA7IEE/TextFlow) | MIT | Accessibility 优先、剪贴板完整快照、任务取消、显式 OCR、稳定签名 |
| [Lingo](https://github.com/JasonSung0724/Lingo-ai-translator) | MIT | 选区真实坐标浮层、AX 读写后校验、剪贴板恢复、快捷浮窗 |
| [SelectionBar](https://github.com/tacshi/SelectionBar) | MIT | AX 超时、完整复制按键序列、晚到复制竞态、忽略 App 与切换 App 隐藏 |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | MIT | 可配置全局快捷键与冲突提示；目前只作为后续设置界面候选 |
| [Susurro](https://github.com/benatespina/susurro) | MIT | 选中文字后显示轻量工具条 |
| [ForceClickAI](https://github.com/NeoXue-ai/ForceClickAI) | MIT | 在系统 Lookup 改变选区前预取、浮层不中断来源 App；未采用私有 MultitouchSupport |
| [mac-ocr](https://github.com/privatenumber/mac-ocr) / [TextGrabber2](https://github.com/TextGrabber2-app/TextGrabber2) | MIT | Vision OCR 的区域、置信度、取消与 Shortcuts/Services 思路；未捆绑额外 CLI |
| [X-Feed-Filter](https://github.com/Saganaki22/X-Feed-Filter) | MIT | 参考字段分离、文本归一化、fail-open、缓存与防抖原则；原生端独立实现 AX/窗口上下文筛选，未复制浏览器扩展代码 |
| [Readability](https://github.com/mozilla/readability) | Apache-2.0 | 参考正文相关性与保守回退原则；不引入 DOM 依赖，不把文章规则误用于单条社交帖子 |
| [Easydict](https://github.com/tisfeng/Easydict) | GPL-3.0 | 只参考产品交互：划词图标、快捷键、OCR、多翻译服务 |
| [Pot](https://github.com/pot-app/pot-desktop) | GPL-3.0 | 只参考产品分层：划词、输入、剪贴板、截图 OCR |
| [CopyTranslator](https://github.com/CopyTranslator/CopyTranslator) | GPL-2.0 | 只参考“复制触发”和 PDF 文本清理场景 |
| [Maccy](https://github.com/p0deje/Maccy) / [Rectangle](https://github.com/rxhanson/Rectangle) | MIT | 参考键盘优先交互、快捷键诊断、辅助功能权限修复、按 App 暂停和脱敏日志；不保存剪贴板历史 |
| [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | MIT | 后续为快速开始页、浮层与边缘栏建立紧凑/加载/成功/失败及深浅色视觉快照 |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Apache-2.0 | 后续实验性 AST 翻译链：只翻译文本节点，先与现有结构保护做差分测试 |
| [Appium Mac2 Driver](https://github.com/appium/appium-mac2-driver) | Apache-2.0 | 后续在独立测试用户或 CI Mac 做 TextEdit 与合成 ChatGPT 真 UI 回归；不在主账号静默开启高权限 Automation Mode |
| [AXSwift](https://github.com/tmandry/AXSwift) | MIT | 仅参考类型化 AX 错误/Observer；维护较旧，不替换当前精确 PID、窗口、焦点和范围校验 |

GPL/AGPL 项目只用于理解产品与架构模式，没有复制其源码。KISS Translator 能遍历和修改网页 DOM，而独立桌面 App 没有这个能力；当前实现用 macOS 公共 AX、ScreenCaptureKit、Vision 和 Translation API 独立完成。

当前版本没有因为这轮调研增加第三方运行时依赖，从而避免扩大供应链、遥测和隐私面。推荐顺序是：先稳定合成 UI 回归与 identifiers；再评估 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)；把 snapshot-testing 和 swift-markdown 仅作为开发/实验依赖；完成 Developer ID、公证和 HTTPS appcast 后才接入 [Sparkle](https://github.com/sparkle-project/Sparkle)。Apple 语言覆盖不足时再评估 [CTranslate2](https://github.com/OpenNMT/CTranslate2) / [Argos Translate](https://github.com/argosopentech/argos-translate) 的体积、模型来源和许可证。

## 隐私与安全

- 被动选区检测默认不联网。
- “选中即自动翻译”默认关闭，并要求一次明确确认。
- “鼠标悬停翻译”默认关闭；启用后只读取单个静态 AX 节点，不读取可编辑输入或密码内容。
- “剪贴板兼容模式”默认关闭。关闭时，通用选区和 AI 输入读取/替换在 Accessibility 失败后直接停止，不会读取、写入或快照系统剪贴板。
- AI 回复翻译与回复短期选区快照只接受 Accessibility 来源；即使用户另行开启剪贴板兼容，回复按钮和自动回复也绝不继承该路径。
- App 隐私名单在每次捕获、OCR 与翻译交付前重查；加入名单会取消正在运行的区域选择、OCR、字幕和翻译任务，并清除可见原文/译文、回复缓存、字幕缓存与短期选区快照。
- 浏览器自动 AI 兼容模式不再依据可伪造的窗口标题关键词；仅当 Accessibility 的 `AXWebArea/AXURL` 暴露 ChatGPT、Claude、Gemini 等精确允许域名时才启动输入/回复扫描。URL 不可得或只是普通网页标题提到 AI 时 fail-closed；显式通用选区仍可正常使用。
- 开启剪贴板兼容模式前会警告：复制中的选区文字可能被第三方剪贴板管理器或 macOS 通用剪贴板观察；它只适合用户接受该风险、且目标 App 不提供 Accessibility 文本时临时使用。
- 密码框、带 secure/password 角色或 `AXContainsProtectedContent` 的 Accessibility 元素会被排除；剪贴板 fallback 会检查焦点元素及最多 12 层祖先。
- 剪贴板 fallback 只在用户明确开启兼容模式后使用；不预写 sentinel。它优先通过 AX 执行精确匹配、无额外修饰键且已启用的“复制”菜单，找不到时才发送定向 `Command+C`。它要求一次稳定 change count，并在约 90ms 静默期持续校验原 PID、焦点、选区范围与真实输入代次；任何第二次写入或用户输入都会放弃结果且不恢复，从而保留当前剪贴板。
- 所有复制、粘贴和全选事件都绑定原目标 PID 与原焦点 AX 元素，并用 `postToPid` 定向发送；切换 App 或焦点后立即取消。
- 只有当前焦点 AX 元素、窗口、精确 UTF-16 选区范围和原文仍与捕获快照完全一致时才允许替换；同一文字出现在不同位置也会被视为不同选区，写入后还会回读验证完整值或替换后的选区。
- macOS 15 及以上优先使用 Apple Translation。语言包缺失时，应用通过官方 `translationTask` 流程请求一次下载许可，之后翻译在设备上完成。
- macOS 26 及以上、语言包已安装时使用无界面的本地会话，日常翻译不会重复打断当前 App。
- 冷启动时系统偶尔会先报告语言包已安装、稍后才让本地会话就绪；应用先在 500ms 内做两次有界就绪检查，仍未就绪时回到 Apple 官方 `translationTask` 本地准备流程，不会切换到网络翻译。
- 正式应用为仅本地翻译模式：Apple 不支持的语言组合会直接提示失败，不会降级到第三方网络服务。
- 两周本机语言偏好学习默认开启，从第一次成功的主动翻译开始计时；满 14 天、累计至少 8 次且某方向达到 67% 后，才会影响自动语言路由。它只持久化评估时间、语言标识与聚合次数/分数，不保存原文、译文、App 或窗口信息；回复翻译、自动选区、悬停和字幕不计入，用户可随时关闭或确认后重置。
- AI 回复短期缓存只保存在内存中，使用 SHA-256 键、32 项上限和 5 分钟 TTL；字幕缓存同样只使用摘要键、160 项上限和 5 分钟 TTL。停止、屏蔽、重置或切换时清空。通用浮层的紧凑状态不显示选区原文。
- 通用选区去重指纹只保存 PID、元素/范围标识和 SHA-256 摘要，不再把选区原文拼入指纹；暂停翻译器会同时取消选区、悬停、区域 OCR 和字幕任务并清空对应可见正文状态。
- Release 打包会检查并拒绝包含旧网络兼容端点或调试自测入口的二进制，并启用 hardened runtime；进程读取/改写自测只存在于 Debug 构建。
- 自动选区、悬停与自动回复扫描都不会调用 OCR。屏幕录制权限与辅助功能权限保持分离；只有用户明确选择“框选屏幕文字”、启动“视频字幕翻译”，或第二次点击 AI 回复“OCR 重试”时才会截取限定区域。通用区域 OCR/字幕只包含启动流程的来源 App 窗口，拖到其他 App 不会捕获其像素；回复 OCR 使用“显示器过滤 + 仅包含目标窗口 + 近似对话区域 sourceRect”，避免先获取侧栏/工具栏的整窗像素。OCR 图片不保存、不写剪贴板。

## 构建与测试

完整本地回归总入口：

```bash
Scripts/run-local-regression.sh
Scripts/run-local-regression.sh --ui
Scripts/run-local-regression.sh --ui --install
```

默认链执行静态检查、隔离单元测试、SwiftPM/Xcode Release 和安装版校验；`--ui` 增加无网络 ChatGPT 合成选区、输入与回复 Accessibility E2E，其中会只选 assistant 回复的一小段并断言它胜过完整最新回复，同时确认选区链未访问剪贴板、未使用 OCR；`--install` 增加原子安装、显式启动、精确 bundle 路径 PID 与运行时 socket 快照。Markdown/JSON 脱敏报告输出到被 Git 忽略的 `review_artifacts/`。完整人工门见 `TestHarness/REGRESSION_CHECKLIST.md`。

`--ui` 会把“输入框识别/直接写回”和“Apple Translation 运行时”拆成独立结果：先以固定 hash 等待严格 composer 就绪，再验证纯 AX 读写和剪贴板不变，最后才执行真实本地翻译。合成宿主每次复制到私有唯一路径并精确结束对应 PID，避免上一轮实例或已翻译草稿污染结论。

SwiftPM：

```bash
cd "/path/to/ClaudePromptTranslator"
Scripts/test.sh
swift build -c release
```

`Scripts/test.sh` 总是在项目目录外创建临时 scratch path，并开启覆盖率，避免 iCloud/FileProvider 扩展属性污染测试包签名。打包脚本也会先运行同一套测试，测试失败时不会进入 Release 签名或公证流程。

离线回复翻译回归宿主：

```bash
TestHarness/build-ai-response-harness.sh
open "TestHarness/dist/ChatGPTSyntheticHarness.app"
```

该宿主只展示固定的合成 user/assistant 文本，不联网，可重复验证 AI 窗口识别、说话人归属、窗口标题过滤、Accessibility 回复读取和本地翻译。

Xcode：

```bash
cd "/path/to/ClaudePromptTranslator"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ClaudePromptTranslator.xcodeproj \
  -scheme ClaudePromptTranslator \
  -configuration Debug \
  -derivedDataPath /tmp/ClaudePromptTranslatorDerivedData \
  build
```

如果 `/Applications/Xcode.app` 存在，可把 `Xcode-beta.app` 换成 `Xcode.app`。

干净的 Xcode Release 验证显式关闭 scheme 注入的覆盖率参数：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ClaudePromptTranslator.xcodeproj \
  -scheme ClaudePromptTranslator \
  -configuration Release \
  -derivedDataPath /tmp/ClaudePromptTranslatorRelease \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  clean build
```

打包并安装到当前用户的 Applications：

```bash
Scripts/package-app.sh
open "$HOME/Applications/ClaudePromptTranslator.app"
```

`package-app.sh` 总会构建、启用 hardened runtime、验证并安装本机测试版。若安装版正在运行，脚本会在新包完成预检后优雅退出旧实例，原子替换、复核并以新 PID 自动重启；任一步失败都会恢复旧包。只有钥匙串中存在 `Developer ID Application` 证书且提供 `NOTARY_PROFILE` 时，它才会在临时目录完成公证、装订和 Gatekeeper 验证，最后生成 `dist/ClaudePromptTranslator.app.zip`；否则会主动删除旧 ZIP/DMG，避免把 Apple Development、ad-hoc 或未公证身份误当成公开发行版。

公开 DMG 还必须提供公证凭据：

```bash
NOTARY_PROFILE="your-notarytool-profile" Scripts/create-dmg.sh
```

`create-dmg.sh` 会要求 Developer ID 签名，提交 Apple 公证，装订 ticket，并从最终挂载的 DMG 再次检查 Gatekeeper、hardened runtime、调试入口和网络符号。缺少任一条件时脚本拒绝生成公开 DMG。

首次运行后，在“系统设置 → 隐私与安全性 → 辅助功能”中允许“无感翻译”。只有显式区域 OCR、视频字幕或旧 AI 回复 OCR 重试需要屏幕录制权限。

## 手工回归矩阵

每次发布至少验证：

| 场景 | 预期 |
| --- | --- |
| Safari 普通网页英文选区 | 显示翻译按钮；译为简体中文 |
| Chrome / ChatGPT 输出英文选区 | 不读取输入框，不扫描整页；译为简体中文 |
| TextEdit 中文选区 | 译为英文；可验证时显示替换按钮 |
| Notes / 原生 App 日文选区 | 译为简体中文 |
| AX 静态英文文本悬停 | 稳定 0.65 秒后翻译；输入框与密码框不触发 |
| Canvas / 图片框选 OCR | 只识别框选区域；退出框选可取消；截图不落盘 |
| 视频字幕区域 | 相同画面两帧稳定后双语显示；重复字幕不重复翻译；停止后不再截屏 |
| Accessibility 不暴露选区的 App，兼容模式关闭 | 明确提示无法读取；完全不访问剪贴板 |
| Accessibility 不暴露选区的 App，用户开启兼容模式 | `⌃⌥T` 才允许复制兜底；上下文歧义时安全放弃 |
| 图片、文件、多 item 剪贴板 | 兼容模式稳定成功时完整恢复；竞态时不覆盖新内容 |
| 密码框 | 不读取、不翻译 |
| 快速连续选择十次 | 只保留最后一次译文，无旧结果串线 |
| 屏幕四角与多显示器 | 浮层保持在 visibleFrame 内 |
| 只读网页 / PDF | 可复制译文，不错误显示替换按钮 |
| ChatGPT / Claude 选中 assistant 回复的一部分后点击“译回复” | 只翻译选中部分；不被侧栏点击覆盖，不回退到整条最新回复，不启用 OCR |
| 回复 Accessibility 读取失败（第一次点击） | 只提示“使用 OCR 重试”，不请求屏幕录制 |
| 用户第二次明确点击 OCR 重试 | 才允许请求屏幕录制并做一次 OCR；取消权限时不截屏 |

### 2026-08-09 隐私修复与本机验证

- `Scripts/test.sh`：93/93 通过，覆盖回复链禁用剪贴板、同 PID Accessibility 快照、App 隐私名单、阻断期间取消、来源 App 窗口限定 OCR、字幕摘要缓存 TTL、X/Twitter 正文筛选、浏览器 AI host 白名单、同文不同轮次与长前缀流式回复失效。
- `Scripts/run-local-regression.sh --ui --install`：SwiftPM/Xcode Release、签名与原子安装、精确 bundle 路径启动、运行时零 TCP/UDP socket 快照、离线合成 ChatGPT 输入/选区/回复、Apple 本地翻译、回复 OCR 禁用和剪贴板 change count 不变均通过。脱敏报告见 `review_artifacts/regression-20260809T032346Z.md`。
- Computer Use 打开并核对了最终安装版 `/Users/chengwenbo/Applications/ClaudePromptTranslator.app` 的权限、回复 OCR 和不发送提示；真实 ChatGPT Classic 因自动化工具安全策略无法控制，Atlas 页面又未暴露可用的 composer Accessibility 节点，因此仍明确保留为不发送草稿的人工验收门。

### 2026-08-07 本机验证

- 回复选区优先专项链通过：78 项单元测试覆盖 WebView 文本标记读取相关策略、侧栏点击隔离、同 PID 15 秒快照与主动清除；离线 ChatGPT 合成宿主实际选中 assistant 子串，验证其胜过完整最新回复，且剪贴板不变、OCR 关闭。完整 `--ui --install`、签名安装和零 TCP/UDP socket 快照均通过。脱敏报告见 `review_artifacts/regression-20260807T102319Z.md`。
- 0.7.0 最终链 `Scripts/run-local-regression.sh --ui --install` 全部通过：74 项单元测试、SwiftPM/Xcode Release、稳定本机签名与原子安装、精确 bundle 路径启动、运行时零 TCP/UDP socket 快照、离线 ChatGPT 合成输入/回复、Apple 本地翻译、OCR 禁用的 Accessibility 回复读取，以及剪贴板 change count 不变。脱敏报告见 `review_artifacts/regression-20260807T090934Z.md`。
- Computer Use 只使用固定合成图片，完成安装版区域 OCR 可见验证：明确点击“框选屏幕文字”，使用当前 Preview 合成窗口区域，原文与简体中文译文在应用浮层中正常显示；截图不保存、不写剪贴板。整窗便捷按钮可能包含窗口标题或工具栏文字，精确使用时仍应拖拽字幕/正文矩形。
- Computer Use 只使用固定合成字幕，完成安装版连续 OCR 可见验证：两帧稳定后显示双语字幕浮层，重复画面不重复翻译，停止按钮关闭扫描与浮层。测试结束确认不存在字幕停止控件或残留字幕面板。
- 可见测试发现 Finder 路径会被悬停模式误认为自然语言；现已在翻译任务创建前过滤 POSIX 绝对路径、`~/`、`file://` 与 Windows 盘符路径，并加入回归用例。
- 本轮没有打开、读取、保存或发送真实 ChatGPT/Claude 对话；真实双窗口、多显示器与物理快捷键仍属于合成草稿人工门。

### 2026-08-04 本机验证

- 0.6.0 完整链 `Scripts/run-local-regression.sh --ui --install` 全部通过：69 项单元测试、SwiftPM/Xcode Release、签名安装、精确路径启动、零 TCP/UDP socket 快照、严格 composer 就绪、AX 直接写回、Apple 本地翻译、assistant 回复归属、OCR 禁用与剪贴板 change count 不变。
- 安装版 Computer Use 可见验证：快速开始页显示 0.6.0 和三项权限状态；离线 ChatGPT 合成草稿通过非激活边缘栏真实鼠标点击替换为英文，宿主没有 Send 控件；合成 assistant 回复显示“语义化辅助功能读取 / English → 中文”。测试结束后已关闭合成窗口并恢复测试前目标语言设置。
- 真实安装版 + TextEdit 合成文本：前台识别 68 字符英文选区，Apple 本地翻译为简体中文；点击浮层不抢焦点，“替换选区”只修改原选区，随后已通过撤销精确恢复测试文档。
- 离线 ChatGPT 合成回复宿主：Accessibility 正确选择 assistant 回复而非 user 提示；发现并修复窗口标题被附加到回复末尾的问题，修复后通过安装版复测。
- 69 项单元测试全部通过；新增用例覆盖同文不同选区身份、精确焦点与 range 写入门、暂停/陈旧任务取消、流式回复陈旧结果、自动 OCR 禁止、结构化文本语言投影、回复界面标题过滤，以及既有剪贴板事务安全。
- 测试只使用合成句子，没有读取、保存或上传真实聊天、用户文件或剪贴板历史。

## 当前明确限制

- 某些浏览器或 App 既不暴露标准选区，也不暴露 WebView 文本标记选区，因此被动“翻译”按钮仍可能不出现；默认按 `⌃⌥T` 也不会绕过隐私策略。只有用户明确开启剪贴板兼容模式后，通用选区快捷键才会尝试复制 fallback。AI 回复按钮无条件禁用剪贴板；无法从 Accessibility 读取时只会回退到最新回复，或在用户第二次明确点击后使用 OCR。
- 回复 OCR 的对话矩形是按 ChatGPT、Claude 等布局比例计算的隐私收窄方案，不是 DOM 语义区域；应用改版、浮动面板、极窄窗口或跨显示器窗口可能导致正文漏截。此时应优先选中回复，或使用用户明确框选的区域 OCR，而不是放宽为整窗捕获。
- 独立 macOS App 不能像浏览器扩展一样读取 MutationObserver、修改网页 DOM 或保留 DOM 链接/富文本节点。因此 ChatGPT/Claude 桌面端采用选区/悬停/字幕浮层；“整页原文下插入译文”“隐藏网页原文”和站点 CSS 规则仍需要浏览器扩展或 App 官方插件能力。
- 区域 OCR 与实时字幕已经可用于 Canvas、图片和视频，但依赖屏幕录制权限、画面清晰度、字幕无遮挡和固定区域。它不会自动发现视频字幕位置，也不会识别被框选区域之外的变化。
- 当前字幕断句是本地规则，不是外部 AI 断句；快速滚动字幕、卡拉 OK 逐字高亮、多说话人重叠或每帧变化的动画字幕仍可能等待不够稳定或出现 OCR 抖动。
- 悬停翻译仅支持 Accessibility 暴露的静态文字；Canvas、图片和部分 Electron/WebView 节点必须改用区域 OCR。
- 当前只在本应用浮层内恢复 Markdown 链接与基础强调；结构分段会保护代码块、URL、Markdown/HTML 标记，但不能恢复来源 App 的原字号、颜色、复杂富文本排版，也不能把样式写回 ChatGPT/Claude。
- 只读内容不会提供原位替换；无法验证写入结果的编辑器也会降级为复制译文。
- macOS 通用剪贴板不提供写入者事务 ID；第三方剪贴板管理器或通用剪贴板仍可能观察一次 `Command+C`。因此 fallback 默认关闭。用户显式开启后，程序会用焦点、输入代次、静默期和 CAS 式 change count 做保守判断，但在系统无法证明所有权时会直接放弃翻译结果，而不是冒险恢复旧内容。
- Apple 不支持的语言组合在仅本地模式下不会翻译。若未来增加联网 Provider，必须在设置页明确展示服务域名、数据用途并由用户主动开启，不能静默降级。
- 当前使用 Apple Development 签名，适合本机测试；公开分发前仍需 Developer ID Application 签名、公证和 Gatekeeper 验证。
- 完整无人值守真实 UI 回归仍受 macOS 权限模型限制。Appium Mac2 需要额外的 Xcode Helper 辅助功能权限和可能的 Automation Mode，本轮没有安装或开启；真实 ChatGPT、多窗口和多显示器仍保留为合成数据的人工门。
- 部分 UI 自动化器把 `Control + Option + T` 同时作为文本控制字符注入 TextEdit；当前 Computer Use 验证中该合成修改已立即撤销。自动回归应点击非激活浮层按钮或使用 Debug 合成链，物理键盘快捷键仍属于人工门，不能把自动化注入副作用误判为应用写入。

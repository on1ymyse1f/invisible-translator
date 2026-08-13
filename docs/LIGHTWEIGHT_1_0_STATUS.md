# 无感翻译 1.0 轻量化实施状态

此文档区分已经进入可执行文件的能力、已实现但尚未接通产品链路的组件，以及必须由签名、真实应用或外部服务完成的验收门。静态测试、合成宿主和本机开发签名不能替代这些外部门。

## 0.8 core：已落地

- `AppRuntimeCoordinator` 统一决定选区、悬停、AI 上下文、回复扫描、字幕和 UI 的资源需求；暂停、锁屏和退出会拆除业务观察与任务。
- 悬停事件在主线程前限制为每秒最多 10 次，并用一个 dwell 槽保留最新坐标；普通点击和无关 `keyUp` 不触发选区读取。
- `TranslationWorkBroker` 统一单会话翻译：手动等待最多两项、自动任务 latest-wins、队列正文总计不超过 1 MiB；缓存同时受条数、TTL 和 UTF-8 字节预算约束。
- AI 回复自动链保持 Accessibility-only；自动回复不使用剪贴板或 OCR。结构扫描同 PID 首次最多 2,000 节点、后续最多 600 节点，并以回合身份和全文 revision 去重。
- OCR 使用来源 App 窗口过滤、每次截图前后隐私复核、fast-first/低置信度 accurate retry。回复块上限 1 MP、字幕 0.75 MP、大区域按不超过 2 MP 的重叠块顺序识别。
- 字幕使用一次建立的来源 App 专属 `SCStream`，`queueDepth = 2`，生产路径直接把单槽最新 `CVPixelBuffer` 交给 Vision，不生成或缓存 `CGImage`；OCR 与翻译 consumer 分离，静态画面会把捕获流降至 2 fps，变化时恢复 4 fps。
- 用户可在菜单中显式选择目标 App 的 Apple 设备端语音字幕和源语言。macOS 15–25 强制 `SFSpeechRecognizer.requiresOnDeviceRecognition`，macOS 26+ 使用 `SpeechAnalyzer`/`SpeechTranscriber.results`；音频只从来源 App 专属 `SCStream` 进入识别器，不落盘、不静默回退网络，停止和隐私撤销会使 generation 失效并释放会话。
- 私有 ASR 抽象具备 12 秒/768 KiB 音频环形缓冲、单一识别引擎租约、30 秒空闲卸载和内存压力卸载；这些界限不描述 Apple 系统 ASR，基础 App 也不携带私有模型。
- 系统 ASR 不经过上述私有环形缓冲：macOS 15–25 的 legacy 请求在下一帧将超过 12 秒或 768 KiB float-equivalent 上限前结束并滚动到新请求；macOS 26+ 的 `SpeechAnalyzer` 输入流采用 `.bufferingNewest(8)`，格式转换路径同时最多持有一个 ScreenCaptureKit 输入 buffer 和一个转换 buffer。
- 私有模型存储具备 HTTPS/域名白名单、Content-Length、磁盘预留、流式 SHA-256、Ed25519、原子替换、单模型和 30 天回收策略。没有签名生产 catalog 时不会下载模型。
- “存储与性能”只统计本应用目录；删除模型会把精确的 `ASRModels` 目录移入废纸篓，不处理 Apple 系统资产。
- 更新调度默认不联网；包含 Sparkle 的未来构建才会创建 24 小时 deadline，且使用 `startingUpdater: false`。当前 core 构建的手动菜单明确显示更新器未包含。
- Release 使用临时 scratch，明确以 `arm64` 构建且在打包与成品验收两处拒绝非纯 `arm64` 主程序（Apple Silicon only），私有归档 dSYM 后 strip，再签名和审计。core 包禁止模型、dSYM、测试宿主和截图，并执行 App/ZIP 体积门。
- Chromium native host 已成为独立 `ClaudePromptTranslatorNativeHost` 可执行文件：一次 stdin/stdout 请求即退出，只通过当前用户 `Application Support` 下的 `0700` 目录/`0600` Unix socket 联系已运行 App。App 校验 peer UID、256 KiB 帧、固定域和默认空集的逐域用户授权，只调用 `AutomaticTranslationClient` 的 Apple 本地翻译；无 App、无授权、无本地语言包或响应绑定不一致均 fail-closed。helper 单独 strip/签名/验签并随 App 嵌入。

## 已有代码，但尚不是可交付的端到端功能

- Chromium MV3 前端已限定为 ChatGPT、Claude、X 和 YouTube 域，具备内容根观察、64 段/256 KiB 批次、富文本节点保留、隐藏原文、悬停和字幕逻辑。
- macOS native-messaging host 与 App/逐域隐私授权桥接已实现并有 socket/helper 定向测试。当前安装链只接受用户显式传入的本机 Chromium 扩展 ID，并把它限定为当前用户 manifest 的单一 `allowed_origins`；仓库没有分配、硬编码或宣称固定生产 ID。Developer ID 签名/公证与真实 Chrome 安装端到端验收仍未完成，因此不能作为公开分发功能宣称完成。
- Safari 目录目前只有从同一 WebExtension 源转换的说明，没有签名 `.appex`。
- 系统语音链已接入产品菜单与现有字幕稳定化/翻译/双语浮层，但因当前桌面锁定，尚未完成真实视频目标 App 的授权、声音、停止和长时内存验收。
- 私有模型仍只有安全存储、验签、回收和单引擎抽象；尚无内置生产 catalog、公钥或 WhisperKit 引擎适配，UI 不会把它显示为可启动能力。
- Sparkle 和 WhisperKit 只在 `CPT_INCLUDE_OPTIONAL_RUNTIME=1` 时参与依赖解析。发布脚本在尚未实现嵌套 framework/resource 复制与逐层签名前会 fail-closed，禁止生成残缺的“full”包。

## 仍需外部验收

- 真实 ChatGPT/Claude 双窗口、Electron/WebKit、物理快捷键、多显示器、区域 OCR、视频字幕和长时自动回复只能在已解锁桌面上用合成草稿验证；不得按 Enter 或发送消息。
- Developer ID Application、时间戳、公证、stapler 和 Gatekeeper 是 1.0 公开分发门。本机 Apple Development 包只用于当前 Mac 测试。
- 30 分钟回复循环、OCR/ASR 峰值和高精度模型内存门必须在相同签名安装包、相同 Mac 与真实任务负载下采样，不能由单元测试推断。

性能门与构建命令见 [PERFORMANCE_GATES.md](PERFORMANCE_GATES.md)。

发布构建必须使用 macOS 26 或更新 SDK；这是编译 `SpeechAnalyzer` 声明所需的工具链门，不改变 macOS 15 的最低运行版本。macOS 15–25 运行时只会进入强制设备端的 `SFSpeechRecognizer` 分支。

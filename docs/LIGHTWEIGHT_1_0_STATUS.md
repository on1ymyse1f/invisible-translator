# 无感翻译 1.0 轻量化实施状态

此文档区分已经进入可执行文件的能力、已实现但尚未接通产品链路的组件，以及必须由签名、真实应用或外部服务完成的验收门。静态测试、合成宿主和本机开发签名不能替代这些外部门。

## 0.8 core：已落地

- `AppRuntimeCoordinator` 统一决定选区、悬停、AI 上下文、回复扫描、字幕和 UI 的资源需求；暂停、锁屏和退出会拆除业务观察与任务。
- 悬停事件在主线程前限制为每秒最多 10 次，并用一个 dwell 槽保留最新坐标；普通点击和无关 `keyUp` 不触发选区读取。
- `TranslationWorkBroker` 统一单会话翻译：手动等待最多两项、自动任务 latest-wins、队列正文总计不超过 1 MiB；缓存同时受条数、TTL 和 UTF-8 字节预算约束。
- AI 回复自动链保持 Accessibility-only；自动回复不使用剪贴板或 OCR。结构扫描同 PID 首次最多 2,000 节点、后续最多 600 节点，并以回合身份和全文 revision 去重。
- OCR 使用来源 App 窗口过滤、每次截图前后隐私复核、fast-first/低置信度 accurate retry。回复块上限 1 MP、字幕 0.75 MP、大区域按不超过 2 MP 的重叠块顺序识别。
- 字幕把截图/OCR producer 与翻译 consumer 分离；帧、cue 和待翻译内容均为单槽 latest-wins，静态画面 2 fps、变化画面 4 fps。
- Apple 系统语音能力、12 秒/768 KiB 音频环形缓冲、单一识别引擎租约、30 秒空闲卸载和内存压力卸载已经实现；基础 App 不携带模型。
- 私有模型存储具备 HTTPS/域名白名单、Content-Length、磁盘预留、流式 SHA-256、Ed25519、原子替换、单模型和 30 天回收策略。没有签名生产 catalog 时不会下载模型。
- “存储与性能”只统计本应用目录；删除模型会把精确的 `ASRModels` 目录移入废纸篓，不处理 Apple 系统资产。
- 更新调度默认不联网；包含 Sparkle 的未来构建才会创建 24 小时 deadline，且使用 `startingUpdater: false`。当前 core 构建的手动菜单明确显示更新器未包含。
- Release 使用临时 scratch，私有归档 dSYM 后 strip，再签名和审计。core 包禁止模型、dSYM、测试宿主和截图，并执行 App/ZIP 体积门。

## 已有代码，但尚不是可交付的端到端功能

- Chromium MV3 前端已限定为 ChatGPT、Claude、X 和 YouTube 域，具备内容根观察、64 段/256 KiB 批次、富文本节点保留、隐藏原文、悬停和字幕逻辑。
- 该扩展仍缺 macOS native-messaging host、扩展 ID/origin 与 App/域隐私授权的最终桥接，因此不能作为已启用功能分发。
- Safari 目录目前只有从同一 WebExtension 源转换的说明，没有签名 `.appex`。
- SpeechAnalyzer/SFSpeech 和私有模型运行时接口已就绪，但尚无内置生产模型 catalog、公钥或 WhisperKit 引擎适配；基础包继续使用系统能力优先、无模型策略。
- Sparkle 和 WhisperKit 只在 `CPT_INCLUDE_OPTIONAL_RUNTIME=1` 时参与依赖解析。发布脚本在尚未实现嵌套 framework/resource 复制与逐层签名前会 fail-closed，禁止生成残缺的“full”包。
- 当前字幕捕获仍是有界的逐帧 `SCScreenshotManager`；持续 `SCStream` + 单 `CVPixelBuffer` 槽属于 0.9 性能门。

## 仍需外部验收

- 真实 ChatGPT/Claude 双窗口、Electron/WebKit、物理快捷键、多显示器、区域 OCR、视频字幕和长时自动回复只能在已解锁桌面上用合成草稿验证；不得按 Enter 或发送消息。
- Developer ID Application、时间戳、公证、stapler 和 Gatekeeper 是 1.0 公开分发门。本机 Apple Development 包只用于当前 Mac 测试。
- 30 分钟回复循环、OCR/ASR 峰值和高精度模型内存门必须在相同签名安装包、相同 Mac 与真实任务负载下采样，不能由单元测试推断。

性能门与构建命令见 [PERFORMANCE_GATES.md](PERFORMANCE_GATES.md)。

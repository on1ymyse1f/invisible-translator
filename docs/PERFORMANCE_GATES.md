# 无感翻译 1.0：体积、内存与发布门

基础 App 不携带私有 ASR 模型、OCR 测试素材、dSYM 或测试宿主。系统语言与语音资产由 macOS 管理；私有模型仅在用户明确选择后下载到应用数据目录，且不属于发行包。

## 可复核构建

- 日常 SwiftPM 构建使用 `Scripts/development-build.sh`，缓存固定在 `~/Library/Caches/ClaudePromptTranslator/Build/default`；进程锁禁止两个构建互相清理同一 scratch。
- `Scripts/prune-build-cache.sh` 只清理该应用拥有的缓存：14 天未访问的顶级项优先清理，并按最近使用时间压到 512 MiB。它不会触碰项目 `.build`、系统缓存或其他应用数据。
- `Scripts/package-app.sh` 使用临时 SwiftPM scratch 目录，不在仓库生成 `.build`。它先把未 strip 二进制的 dSYM 归档到私有 `~/Library/Application Support/ClaudePromptTranslator/PrivateDSYM`，再对 staged、尚未签名的副本执行 `strip -S -x`，最后签名。

## 体积门

| 发行层级 | App | ZIP |
| --- | ---: | ---: |
| 0.8 core | <= 3.2 MiB | <= 2.2 MiB |
| 1.0 full base（不含模型） | <= 24 MiB | <= 12 MiB |

用 `Scripts/audit-artifact.sh --tier core APP [ZIP]` 或 `--tier full` 审计。审计会拒绝模型权重、dSYM、xctest/TestHost 与命名为 screenshot 的图片，并在 ZIP 中拒绝 Finder 元数据。

`Scripts/write-release-manifest.sh APP ZIP MANIFEST.json CHANNEL` 记录发布通道、Git SHA、App/ZIP 字节数和 SHA-256；`CHANNEL` 必须是 `local-test-unnotarized` 或 `public-notarized`，并与对应 ZIP 一同保存。

## 性能验收（同一签名安装包、同一 Mac）

- 0.8 空闲 footprint <=45 MB；1.0 完整基础版 <=55 MB。
- 普通 App 空闲平均 CPU <0.2%；AI 前台无变化 <0.5%。
- 暂停时业务 repeating timer 为 0；关闭所有 UI/字幕 60 秒后回到启动基线 +8 MB。
- 自动回复循环 30 分钟内持续增长 <3 MB；OCR 峰值 <=180 MB、OCR 字幕稳定 <=160 MB。
- 私有 tiny ASR 稳定 <=350 MB、峰值 <=400 MB；高精度模型峰值 <=1.2 GiB。

自动化结果只证明其覆盖范围。ChatGPT/Claude 双窗口、多显示器、Electron/WebKit、OCR、字幕和物理快捷键仍须用不发送消息的真实草稿人工验收。

## 发布信任门

本机 Apple Development 或 ad-hoc 签名只能用于本机测试。公开 ZIP/DMG 必须同时通过：Developer ID Application（指定 Team ID）、安全时间戳、Apple 公证、stapler 验证与 Gatekeeper (`spctl`)。缺少凭据时脚本会安全停止或明确标为外部发布门，绝不输出“已公证/可公开分发”的结论。

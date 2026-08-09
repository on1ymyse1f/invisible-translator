# 无感翻译完整回归清单

所有测试只使用合成文字。真实 ChatGPT 测试不得读取既有聊天、不得按 Enter、不得点击发送；测试结束后清空草稿。

## 一键自动链

```bash
Scripts/run-local-regression.sh
Scripts/run-local-regression.sh --ui
Scripts/run-local-regression.sh --ui --install
```

- 默认：静态检查、单元测试、SwiftPM Release、Xcode Release、合成宿主构建、现有安装版校验。
- `--ui`：使用唯一私有宿主路径，先等待严格 composer hash/窗口身份就绪，再分别验证纯 Accessibility 读写、Apple 本地翻译和 assistant 回复；OCR 强制关闭。
- `--install`：增加原子安装、显式启动、按 bundle id 与绝对 bundle 路径确认 PID，并检查运行时网络 socket 快照。
- Markdown/JSON 报告写入 `review_artifacts/`，不记录原文、译文、剪贴板内容、聊天记录或窗口标题。

## TextEdit 精确选区（人工 / Computer Use）

1. 从“快速开始与安全自检”打开合成测试文本。
2. 选中整句英文，确认浮动按钮出现且鼠标没有移动。
3. 点击“翻译”，确认前台仍为 TextEdit，目标自动路由为简体中文。
4. 点击“替换选区”，确认只修改选中范围。
5. 按 `Command + Z`，确认原文精确恢复。
6. 再选中中文句子，确认自动路由为 English。

> Computer Use 等自动化器可能把 `Control + Option + T` 额外注入为 TextEdit 控制字符。自动化场景请点击浮层“翻译”；快捷键必须用物理键盘人工验证。若发生测试注入，立即 `Command + Z` 并确认合成原文恢复。

## 离线 ChatGPT 合成宿主

1. 运行 `TestHarness/build-ai-response-harness.sh` 并打开输出 App。
2. 输入框只有固定中文草稿，宿主没有 Send 按钮，也不联网。
3. “翻译输入”只能替换草稿，不能发消息。
4. “译回复”应选 assistant 回复，不能混入 user 提示或窗口标题。
5. 第一次 Accessibility 失败只能显示“使用 OCR 重试”，不能弹屏幕录制权限；第二次明确点击才可请求。

## 悬停与区域 OCR（合成内容）

1. 开启“鼠标悬停翻译”，在合成英文静态文本上稳定停留约 0.65 秒，确认自动出现译文；移入输入框不应触发。
2. 选择“框选屏幕文字（OCR）”，只框住合成英文图片/Canvas 区域；确认只显示区域内文字，截图不落盘。
3. 按 Esc 取消一次框选，确认不产生 OCR 或翻译结果。
4. 多显示器分别框选一次，确认矩形坐标和浮层都落在对应显示器。

## 视频字幕（合成内容）

1. 打开只包含合成字幕的离线画面，选择“视频字幕翻译”并框选字幕矩形。
2. 确认同一字幕稳定两帧后显示双语；静止不应反复触发翻译。
3. 切换到“仅译文”、三种样式和三档字号，确认浮层即时更新。
4. 点击“停止”，确认浮层消失且不再截图；再次开始需要重新框选。

## 仍需人工门

- 首次辅助功能授权与 Apple 语言包下载确认。
- 真实 ChatGPT 合成草稿冒烟测试；不得发送，结束后清空。
- 双窗口切换、多显示器、屏幕边角，以及真实 PDF/Canvas/视频画面的 OCR 质量。
- 密码框和安全输入拒绝读取。
- Developer ID、公证、装订和 Gatekeeper 公开发行验证。

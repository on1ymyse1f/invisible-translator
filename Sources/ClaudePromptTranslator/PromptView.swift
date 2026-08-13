import AppKit
import SwiftUI

struct PromptView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PromptPalette {
        PromptPalette(theme: model.appTheme, colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(palette.panelBackground)
                .ignoresSafeArea()

            if model.panelPresentation == .compact {
                compactContent
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    editorCard
                    if model.hasResponseTranslationActivity {
                        replyTranslationCard(maxBodyHeight: 220, compact: false)
                    }
                    footer
                }
                .padding(22)
            }
        }
        .preferredColorScheme(model.appTheme.preferredColorScheme)
        .frame(width: panelSize.width, height: panelSize.height)
    }

    private var panelSize: CGSize {
        switch model.panelPresentation {
        case .expanded:
            return CGSize(width: model.hasResponseTranslationActivity ? 820 : 760, height: model.hasResponseTranslationActivity ? 700 : 420)
        case .compact:
            return CGSize(width: model.hasResponseTranslationActivity ? 820 : 760, height: model.hasResponseTranslationActivity ? 430 : 126)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.accent.opacity(model.appTheme == .tokyoBlue ? 0.16 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(palette.accent.opacity(0.34), lineWidth: 1)
                    )
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(3)
            }
            .frame(width: 46, height: 46)
            .shadow(color: palette.accent.opacity(0.22), radius: 8, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text("草稿翻译")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                HStack(spacing: 6) {
                    safetyBadge("本机翻译", systemImage: "lock.fill")
                    safetyBadge("只写草稿", systemImage: "arrow.down.to.line")
                    safetyBadge("不会发送", systemImage: "paperplane")
                }
            }

            Spacer()

            controlStack
        }
    }

    private var controlStack: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 7) {
                Text("翻译到")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Picker("目标语言", selection: $model.targetLanguage) {
                    ForEach(TargetLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 132, alignment: .trailing)
            }

            HStack(spacing: 7) {
                Text("外观")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Picker("外观", selection: $model.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 132, alignment: .trailing)
            }
        }
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("草稿输入")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(targetDescription)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Text("不会发送")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.subtleText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(palette.cardBackground))
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )

                PromptTextView(
                    text: $model.promptText,
                    isDisabled: model.isTranslating,
                    focusTrigger: model.focusTrigger,
                    palette: palette,
                    onSubmit: model.submitPrompt
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(8)

                if model.promptText.isEmpty {
                    Text("输入要发送给 AI 的草稿，按 Enter 翻译并写入已聚焦的消息输入框")
                        .foregroundStyle(palette.subtleText)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 22)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: model.hasResponseTranslationActivity ? 132 : 168)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.statusMessage.isEmpty {
                statusBanner
            }

            HStack(spacing: 10) {
                Button(model.isTranslating ? "正在翻译…" : "翻译并写入草稿") {
                    model.submitPrompt()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTranslating)

                Button("复制上次译文") {
                    model.copyLastTranslation()
                }
                .disabled(model.lastTranslation.isEmpty)

                Button("关闭") {
                    model.hidePanel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

            }

            if !model.lastTranslation.isEmpty {
                Text(model.lastTranslation)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(palette.cardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )
            }
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.accent.opacity(model.appTheme == .tokyoBlue ? 0.18 : 0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(palette.accent.opacity(0.32), lineWidth: 1)
                        )
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(3)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("草稿翻译")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.primaryText)

                        Text(targetSummary)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)

                        Text("不会发送")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.subtleText)
                    }

                    compactEditor
                }

                VStack(alignment: .trailing, spacing: 8) {
                    Picker("目标语言", selection: $model.targetLanguage) {
                        ForEach(TargetLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 182)

                    HStack(spacing: 8) {
                        Button(model.isTranslating ? "…" : "写入草稿") {
                            model.submitPrompt()
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                        .disabled(model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTranslating)

                        Button("展开") {
                            model.expandPanel()
                        }

                        Button("关闭") {
                            model.hidePanel()
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                }
            }

            if model.hasResponseTranslationActivity {
                replyTranslationCard(maxBodyHeight: 250, compact: true)
            }

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compactEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(palette.cardBorder, lineWidth: 1)
                )

            PromptTextView(
                text: $model.promptText,
                isDisabled: model.isTranslating,
                focusTrigger: model.focusTrigger,
                palette: palette,
                onSubmit: model.submitPrompt
            )
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(5)

            if model.promptText.isEmpty {
                Text("输入草稿，Enter 翻译并写入（不会发送）")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.subtleText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 430, height: 48)
    }

    private var targetSummary: String {
        let appName = model.targetAppName.isEmpty ? "尚未绑定目标" : model.targetAppName
        return "目标：\(appName)"
    }

    private var targetDescription: String {
        let appName = model.targetAppName.isEmpty ? "尚未确认目标 App" : model.targetAppName
        return "写入：\(appName) · 只改草稿，不发送"
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isTranslating ? "arrow.triangle.2.circlepath" : "info.circle")
                .foregroundStyle(palette.accent)
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.accent.opacity(model.appTheme == .tokyoBlue ? 0.13 : 0.08))
        )
        .accessibilityIdentifier("cpt.prompt.status")
    }

    private func safetyBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.cardBackground.opacity(0.72)))
    }

    private func replyTranslationCard(maxBodyHeight: CGFloat, compact: Bool) -> some View {
        let bodyMinHeight: CGFloat = compact ? 210 : 170

        return VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(palette.accent.opacity(model.appTheme == .tokyoBlue ? 0.20 : 0.12))
                        .overlay(Circle().stroke(palette.accent.opacity(0.34), lineWidth: 1))
                    Text("译")
                        .font(.system(size: compact ? 12 : 14, weight: .bold))
                        .foregroundStyle(palette.accent)
                }
                .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("回复翻译")
                        .font(.system(size: compact ? 13.5 : 15, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text("选区优先 · 仅 Accessibility 自动读取")
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                if model.isResponseTranslating {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("复制译文") {
                    model.copyResponseTranslation()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(model.responseTranslationText.isEmpty)
            }

            ScrollView {
                Text(responseTranslationBodyText)
                    .font(.system(size: compact ? 14.5 : 15.5))
                    .foregroundStyle(model.responseTranslationText.isEmpty ? palette.secondaryText : palette.primaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, compact ? 13 : 15)
                    .padding(.vertical, compact ? 11 : 13)
            }
            .frame(maxWidth: .infinity, minHeight: bodyMinHeight, maxHeight: maxBodyHeight)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.cardBackground.opacity(model.appTheme == .tokyoBlue ? 0.72 : 0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.cardBorder, lineWidth: 1)
            )

            if !compact, !model.responseTranslationStatus.isEmpty {
                Text(model.responseTranslationStatus)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(compact ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: compact ? 18 : 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 18 : 20, style: .continuous)
                        .fill(palette.cardBackground.opacity(model.appTheme == .tokyoBlue ? 0.48 : 0.34))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 18 : 20, style: .continuous)
                .stroke(palette.cardBorder.opacity(1.35), lineWidth: 1)
        )
        .shadow(color: palette.accent.opacity(model.appTheme == .tokyoBlue ? 0.18 : 0.08), radius: 16, x: 0, y: 8)
    }

    private var responseTranslationBodyText: String {
        if !model.responseTranslationText.isEmpty {
            return model.responseTranslationText
        }

        if !model.responseTranslationStatus.isEmpty {
            return model.responseTranslationStatus
        }

        return "选中 assistant 回复后点击“译回复”；也可读取最新可见回复"
    }
}

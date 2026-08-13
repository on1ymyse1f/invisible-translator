import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case claude
    case dark
    // Preserve the previous raw value so existing Tokyo Blue users migrate
    // to the refined cyberpunk theme without losing their saved preference.
    case cyberpunk = "tokyoBlue"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .claude:
            return "Claude 暖纸"
        case .dark:
            return "Claude 墨夜"
        case .cyberpunk:
            return "赛博霓虹"
        }
    }

    var menuTitle: String {
        switch self {
        case .system:
            return "外观：跟随系统"
        case .claude:
            return "外观：Claude 暖纸"
        case .dark:
            return "外观：Claude 墨夜"
        case .cyberpunk:
            return "外观：赛博霓虹"
        }
    }

    var symbolName: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .claude:
            return "sun.max.fill"
        case .dark:
            return "moon.stars.fill"
        case .cyberpunk:
            return "bolt.horizontal.circle.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .claude:
            return .light
        case .dark, .cyberpunk:
            return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .claude:
            return NSAppearance(named: .aqua)
        case .dark, .cyberpunk:
            return NSAppearance(named: .darkAqua)
        }
    }

    var isCyberpunk: Bool {
        self == .cyberpunk
    }

    var isClaudeFamily: Bool {
        self == .claude || self == .dark
    }
}

struct PromptPalette {
    let theme: AppTheme
    let colorScheme: ColorScheme

    var isDark: Bool {
        switch theme {
        case .claude:
            return false
        case .dark, .cyberpunk:
            return true
        case .system:
            return colorScheme == .dark
        }
    }

    var accent: Color {
        switch theme {
        case .cyberpunk:
            return Color(red: 0.22, green: 0.91, blue: 1.0)
        case .claude:
            return Color(red: 0.72, green: 0.31, blue: 0.19)
        case .dark:
            return Color(red: 0.92, green: 0.47, blue: 0.31)
        case .system:
            return .accentColor
        }
    }

    var secondaryAccent: Color {
        switch theme {
        case .cyberpunk:
            return Color(red: 1.0, green: 0.27, blue: 0.76)
        case .claude:
            return Color(red: 0.31, green: 0.39, blue: 0.34)
        case .dark:
            return Color(red: 0.94, green: 0.72, blue: 0.45)
        case .system:
            return accent
        }
    }

    var panelBackground: some ShapeStyle {
        switch theme {
        case .cyberpunk:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.012, green: 0.022, blue: 0.048),
                        Color(red: 0.018, green: 0.055, blue: 0.082),
                        Color(red: 0.032, green: 0.016, blue: 0.060)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .claude:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.973, green: 0.957, blue: 0.918),
                        Color(red: 0.945, green: 0.918, blue: 0.865)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .dark:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.075, green: 0.070, blue: 0.064),
                        Color(red: 0.135, green: 0.122, blue: 0.108)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .system:
            return AnyShapeStyle(.regularMaterial)
        }
    }

    var cardBackground: Color {
        switch theme {
        case .cyberpunk:
            return Color(red: 0.025, green: 0.075, blue: 0.105).opacity(0.94)
        case .claude:
            return Color(red: 0.992, green: 0.982, blue: 0.957).opacity(0.96)
        case .dark:
            return Color(red: 0.145, green: 0.132, blue: 0.118).opacity(0.94)
        case .system:
            return isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.86)
        }
    }

    var cardBorder: Color {
        switch theme {
        case .cyberpunk:
            return Color(red: 0.22, green: 0.91, blue: 1.0).opacity(0.42)
        case .claude:
            return Color(red: 0.49, green: 0.40, blue: 0.32).opacity(0.22)
        case .dark:
            return Color(red: 0.86, green: 0.66, blue: 0.49).opacity(0.24)
        case .system:
            return isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
        }
    }

    var primaryText: Color {
        switch theme {
        case .claude:
            return Color(red: 0.17, green: 0.15, blue: 0.13)
        case .cyberpunk:
            return Color(red: 0.91, green: 0.98, blue: 1.0)
        default:
            return isDark ? Color.white.opacity(0.96) : Color.black.opacity(0.88)
        }
    }

    var secondaryText: Color {
        switch theme {
        case .cyberpunk:
            return Color(red: 0.64, green: 0.82, blue: 0.87)
        case .claude:
            return Color(red: 0.36, green: 0.33, blue: 0.29)
        case .dark:
            return Color(red: 0.78, green: 0.73, blue: 0.67)
        default:
            return .secondary
        }
    }

    var subtleText: Color {
        switch theme {
        case .cyberpunk:
            return Color(red: 0.43, green: 0.66, blue: 0.72)
        case .claude:
            return Color(red: 0.48, green: 0.43, blue: 0.38)
        case .dark:
            return Color(red: 0.64, green: 0.59, blue: 0.54)
        default:
            return isDark ? Color.white.opacity(0.60) : Color.black.opacity(0.56)
        }
    }

    var textBackground: NSColor {
        switch theme {
        case .cyberpunk:
            return NSColor(calibratedRed: 0.018, green: 0.055, blue: 0.075, alpha: 0.96)
        case .claude:
            return NSColor(calibratedRed: 0.992, green: 0.982, blue: 0.957, alpha: 0.98)
        case .dark:
            return NSColor(calibratedRed: 0.115, green: 0.105, blue: 0.095, alpha: 0.96)
        case .system:
            return colorScheme == .dark
                ? NSColor(calibratedWhite: 0.08, alpha: 0.88)
                : NSColor(calibratedWhite: 1.0, alpha: 0.88)
        }
    }

    var textForeground: NSColor {
        switch theme {
        case .cyberpunk, .dark:
            return NSColor(calibratedWhite: 0.96, alpha: 1.0)
        case .claude:
            return NSColor(calibratedRed: 0.17, green: 0.15, blue: 0.13, alpha: 1.0)
        case .system:
            return .labelColor
        }
    }

    var disabledTextForeground: NSColor {
        switch theme {
        case .cyberpunk:
            return NSColor(calibratedRed: 0.36, green: 0.55, blue: 0.60, alpha: 1.0)
        case .claude:
            return NSColor(calibratedRed: 0.50, green: 0.45, blue: 0.40, alpha: 1.0)
        case .dark:
            return NSColor(calibratedWhite: 0.60, alpha: 1.0)
        case .system:
            return .secondaryLabelColor
        }
    }
}

@MainActor
struct EdgeBarPalette {
    let theme: AppTheme

    private var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var isDark: Bool {
        switch theme {
        case .claude:
            return false
        case .dark, .cyberpunk:
            return true
        case .system:
            return systemIsDark
        }
    }

    var accent: NSColor {
        switch theme {
        case .cyberpunk:
            return NSColor(calibratedRed: 0.22, green: 0.91, blue: 1.0, alpha: 1.0)
        case .claude:
            return NSColor(calibratedRed: 0.72, green: 0.31, blue: 0.19, alpha: 1.0)
        case .dark:
            return NSColor(calibratedRed: 0.92, green: 0.47, blue: 0.31, alpha: 1.0)
        case .system:
            return .controlAccentColor
        }
    }

    var outerMaterial: NSVisualEffectView.Material {
        switch theme {
        case .system:
            return .popover
        case .claude:
            return .underWindowBackground
        case .dark, .cyberpunk:
            return .hudWindow
        }
    }

    var border: NSColor {
        switch theme {
        case .cyberpunk:
            return accent.withAlphaComponent(0.48)
        case .claude:
            return NSColor(calibratedRed: 0.49, green: 0.40, blue: 0.32, alpha: 0.24)
        case .dark:
            return NSColor(calibratedRed: 0.86, green: 0.66, blue: 0.49, alpha: 0.30)
        case .system:
            return accent.withAlphaComponent(isDark ? 0.42 : 0.34)
        }
    }

    var surfaceTint: NSColor {
        switch theme {
        case .cyberpunk:
            return NSColor(calibratedRed: 0.012, green: 0.040, blue: 0.060, alpha: 0.92)
        case .claude:
            return NSColor(calibratedRed: 0.973, green: 0.957, blue: 0.918, alpha: 0.94)
        case .dark:
            return NSColor(calibratedRed: 0.075, green: 0.070, blue: 0.064, alpha: 0.90)
        case .system:
            return isDark
                ? NSColor(calibratedWhite: 0.08, alpha: 0.82)
                : NSColor(calibratedWhite: 0.98, alpha: 0.86)
        }
    }

    var primaryText: NSColor {
        switch theme {
        case .cyberpunk:
            return NSColor(calibratedRed: 0.92, green: 0.97, blue: 1.0, alpha: 1.0)
        case .claude:
            return NSColor(calibratedRed: 0.17, green: 0.15, blue: 0.13, alpha: 1.0)
        case .dark:
            return NSColor(calibratedWhite: 0.95, alpha: 1.0)
        case .system:
            return .labelColor
        }
    }

    var secondaryText: NSColor {
        switch theme {
        case .cyberpunk:
            return NSColor(calibratedRed: 0.64, green: 0.82, blue: 0.87, alpha: 1.0)
        case .claude:
            return NSColor(calibratedRed: 0.36, green: 0.33, blue: 0.29, alpha: 1.0)
        case .dark:
            return NSColor(calibratedRed: 0.78, green: 0.73, blue: 0.67, alpha: 1.0)
        case .system:
            return .secondaryLabelColor
        }
    }

    var subtleText: NSColor {
        switch theme {
        case .cyberpunk:
            return NSColor(calibratedRed: 0.43, green: 0.66, blue: 0.72, alpha: 1.0)
        case .claude:
            return NSColor(calibratedRed: 0.48, green: 0.43, blue: 0.38, alpha: 1.0)
        case .dark:
            return NSColor(calibratedRed: 0.64, green: 0.59, blue: 0.54, alpha: 1.0)
        case .system:
            return NSColor.secondaryLabelColor.withAlphaComponent(0.90)
        }
    }

    var responseSurface: NSColor {
        switch theme {
        case .cyberpunk:
            return NSColor(calibratedRed: 0.018, green: 0.055, blue: 0.075, alpha: 0.90)
        case .claude:
            return NSColor(calibratedRed: 0.992, green: 0.982, blue: 0.957, alpha: 0.90)
        case .dark:
            return NSColor(calibratedRed: 0.105, green: 0.095, blue: 0.085, alpha: 0.86)
        case .system:
            return isDark
                ? NSColor(calibratedWhite: 0.035, alpha: 0.74)
                : NSColor(calibratedWhite: 1.0, alpha: 0.72)
        }
    }
}

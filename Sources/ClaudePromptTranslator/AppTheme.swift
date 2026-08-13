import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case tokyoBlue

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .dark:
            return "深色"
        case .tokyoBlue:
            return "东京蓝"
        }
    }

    var menuTitle: String {
        switch self {
        case .system:
            return "外观：跟随系统"
        case .dark:
            return "外观：深色"
        case .tokyoBlue:
            return "外观：东京蓝"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .dark, .tokyoBlue:
            return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .dark, .tokyoBlue:
            return NSAppearance(named: .darkAqua)
        }
    }
}

struct PromptPalette {
    let theme: AppTheme
    let colorScheme: ColorScheme

    var isDark: Bool {
        theme == .dark || theme == .tokyoBlue || colorScheme == .dark
    }

    var accent: Color {
        switch theme {
        case .tokyoBlue:
            return Color(red: 0.27, green: 0.76, blue: 1.0)
        case .dark:
            return Color(red: 0.48, green: 0.60, blue: 1.0)
        case .system:
            return .accentColor
        }
    }

    var panelBackground: some ShapeStyle {
        switch theme {
        case .tokyoBlue:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.06, blue: 0.13),
                        Color(red: 0.035, green: 0.11, blue: 0.20),
                        Color(red: 0.018, green: 0.07, blue: 0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .dark:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.065, green: 0.07, blue: 0.085),
                        Color(red: 0.11, green: 0.12, blue: 0.15)
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
        case .tokyoBlue:
            return Color(red: 0.07, green: 0.15, blue: 0.25).opacity(0.88)
        case .dark:
            return Color(red: 0.13, green: 0.14, blue: 0.17).opacity(0.90)
        case .system:
            return isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.86)
        }
    }

    var cardBorder: Color {
        switch theme {
        case .tokyoBlue:
            return Color(red: 0.34, green: 0.76, blue: 1.0).opacity(0.32)
        case .dark:
            return Color(red: 0.52, green: 0.61, blue: 0.78).opacity(0.25)
        case .system:
            return isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
        }
    }

    var primaryText: Color {
        isDark ? Color.white.opacity(0.96) : Color.black.opacity(0.88)
    }

    var secondaryText: Color {
        switch theme {
        case .tokyoBlue:
            return Color(red: 0.73, green: 0.84, blue: 0.95)
        default:
            return .secondary
        }
    }

    var subtleText: Color {
        switch theme {
        case .tokyoBlue:
            return Color(red: 0.56, green: 0.70, blue: 0.84)
        default:
            return isDark ? Color.white.opacity(0.60) : Color.black.opacity(0.56)
        }
    }

    var textBackground: NSColor {
        switch theme {
        case .tokyoBlue:
            return NSColor(calibratedRed: 0.04, green: 0.10, blue: 0.20, alpha: 0.88)
        case .dark:
            return NSColor(calibratedWhite: 0.08, alpha: 0.92)
        case .system:
            return colorScheme == .dark
                ? NSColor(calibratedWhite: 0.08, alpha: 0.88)
                : NSColor(calibratedWhite: 1.0, alpha: 0.88)
        }
    }

    var textForeground: NSColor {
        switch theme {
        case .tokyoBlue, .dark:
            return NSColor(calibratedWhite: 0.96, alpha: 1.0)
        case .system:
            return .labelColor
        }
    }

    var disabledTextForeground: NSColor {
        switch theme {
        case .tokyoBlue:
            return NSColor(calibratedRed: 0.45, green: 0.58, blue: 0.72, alpha: 1.0)
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
        theme == .dark || theme == .tokyoBlue || systemIsDark
    }

    var accent: NSColor {
        switch theme {
        case .tokyoBlue:
            return NSColor(calibratedRed: 0.27, green: 0.76, blue: 1.0, alpha: 1.0)
        case .dark:
            return NSColor(calibratedRed: 0.48, green: 0.60, blue: 1.0, alpha: 1.0)
        case .system:
            return .controlAccentColor
        }
    }

    var outerMaterial: NSVisualEffectView.Material {
        theme == .system ? .popover : .hudWindow
    }

    var border: NSColor {
        switch theme {
        case .tokyoBlue:
            return accent.withAlphaComponent(0.48)
        case .dark:
            return NSColor(calibratedRed: 0.48, green: 0.58, blue: 0.78, alpha: 0.38)
        case .system:
            return accent.withAlphaComponent(isDark ? 0.42 : 0.34)
        }
    }

    var surfaceTint: NSColor {
        switch theme {
        case .tokyoBlue:
            return NSColor(calibratedRed: 0.025, green: 0.075, blue: 0.14, alpha: 0.86)
        case .dark:
            return NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.095, alpha: 0.84)
        case .system:
            return isDark
                ? NSColor(calibratedWhite: 0.08, alpha: 0.82)
                : NSColor(calibratedWhite: 0.98, alpha: 0.86)
        }
    }

    var primaryText: NSColor {
        switch theme {
        case .tokyoBlue:
            return NSColor(calibratedRed: 0.92, green: 0.97, blue: 1.0, alpha: 1.0)
        case .dark:
            return NSColor(calibratedWhite: 0.95, alpha: 1.0)
        case .system:
            return .labelColor
        }
    }

    var secondaryText: NSColor {
        switch theme {
        case .tokyoBlue:
            return NSColor(calibratedRed: 0.72, green: 0.84, blue: 0.95, alpha: 1.0)
        case .dark:
            return NSColor(calibratedWhite: 0.76, alpha: 1.0)
        case .system:
            return .secondaryLabelColor
        }
    }

    var subtleText: NSColor {
        switch theme {
        case .tokyoBlue:
            return NSColor(calibratedRed: 0.55, green: 0.70, blue: 0.84, alpha: 1.0)
        case .dark:
            return NSColor(calibratedWhite: 0.64, alpha: 1.0)
        case .system:
            return NSColor.secondaryLabelColor.withAlphaComponent(0.90)
        }
    }

    var responseSurface: NSColor {
        switch theme {
        case .tokyoBlue:
            return NSColor(calibratedRed: 0.035, green: 0.10, blue: 0.18, alpha: 0.82)
        case .dark:
            return NSColor(calibratedRed: 0.055, green: 0.06, blue: 0.075, alpha: 0.78)
        case .system:
            return isDark
                ? NSColor(calibratedWhite: 0.035, alpha: 0.74)
                : NSColor(calibratedWhite: 1.0, alpha: 0.72)
        }
    }
}

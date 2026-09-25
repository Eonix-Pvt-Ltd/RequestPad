import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Text colors that keep at least 4.5:1 contrast (WCAG AA) on the system backgrounds in light and dark mode
/// (white, #F2F2F7 and #E5E5EA in light mode; black, #1C1C1E and #2C2C2E in dark mode). The system's secondary
/// label and its green/orange text colors fall just short of that in light mode (ADR-0038).
extension Color {
    public static let textSecondary = adaptive(light: 0x5E5E63, dark: 0xAEAEB2)
    public static let textGreen = adaptive(light: 0x146C2E, dark: 0x32D74B)
    public static let textOrange = adaptive(light: 0xA64B00, dark: 0xFF9F0A)
    public static let textRed = adaptive(light: 0xC0271D, dark: 0xFF6961)
    public static let textPurple = adaptive(light: 0x7B3FB8, dark: 0xD39BF8)
    public static let textBlue = adaptive(light: 0x0A63C9, dark: 0x5AA0FA)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
            Color(UIColor { $0.userInterfaceStyle == .dark ? platformColor(dark) : platformColor(light) })
        #else
            Color(
                NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? platformColor(dark) : platformColor(light)
                })
        #endif
    }

    #if os(iOS)
        private static func platformColor(_ rgb: UInt32) -> UIColor {
            UIColor(red: component(rgb, 16), green: component(rgb, 8), blue: component(rgb, 0), alpha: 1)
        }
    #else
        private static func platformColor(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: component(rgb, 16), green: component(rgb, 8), blue: component(rgb, 0), alpha: 1)
        }
    #endif

    private static func component(_ rgb: UInt32, _ shift: UInt32) -> CGFloat {
        CGFloat((rgb >> shift) & 0xFF) / 255
    }
}

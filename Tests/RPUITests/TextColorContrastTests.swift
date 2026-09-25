import CoreGraphics
import SwiftUI
import Testing

@testable import RPUI

/// ADR-0038: every text color keeps WCAG AA contrast (4.5:1) on the system backgrounds in both appearances.
@MainActor
@Suite("Text color contrast")
struct TextColorContrastTests {
    static let colors: [(String, Color)] = [
        ("textSecondary", .textSecondary), ("textGreen", .textGreen), ("textOrange", .textOrange),
        ("textRed", .textRed), ("textPurple", .textPurple), ("textBlue", .textBlue),
    ]
    static let lightBackgrounds: [UInt32] = [0xFFFFFF, 0xF2F2F7, 0xE5E5EA]
    static let darkBackgrounds: [UInt32] = [0x000000, 0x1C1C1E, 0x2C2C2E]

    @Test(arguments: [ColorScheme.light, .dark])
    func meetsAAOnSystemBackgrounds(scheme: ColorScheme) throws {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let backgrounds = scheme == .dark ? Self.darkBackgrounds : Self.lightBackgrounds
        for (name, color) in Self.colors {
            let foreground = try luminance(of: color.resolve(in: environment).cgColor)
            for background in backgrounds {
                let ratio = contrast(foreground, luminance(rgb: background))
                #expect(ratio >= 4.5, "\(name) on #\(String(background, radix: 16)) in \(scheme): \(ratio)")
            }
        }
    }

    @Test func darkAndLightDiffer() {
        var light = EnvironmentValues()
        light.colorScheme = .light
        var dark = EnvironmentValues()
        dark.colorScheme = .dark
        for (name, color) in Self.colors {
            #expect(color.resolve(in: light) != color.resolve(in: dark), "\(name)")
        }
    }

    private func luminance(of color: CGColor) throws -> Double {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let converted = try #require(color.converted(to: srgb, intent: .defaultIntent, options: nil))
        let components = try #require(converted.components)
        return relativeLuminance(Double(components[0]), Double(components[1]), Double(components[2]))
    }

    private func luminance(rgb: UInt32) -> Double {
        relativeLuminance(
            Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }

    private func relativeLuminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

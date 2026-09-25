import RPCore
import SwiftUI
import Testing

@testable import RPUI

@Suite("StatusBadgeStyle")
struct StatusBadgeStyleTests {
    @Test func everyClassHasADistinctSymbol() {
        let symbols = HTTPStatusClass.allCases.map { StatusBadgeStyle(statusClass: $0).systemImage }
        #expect(Set(symbols).count == HTTPStatusClass.allCases.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }

    @Test func successIsGreenAndErrorsAreRed() {
        #expect(StatusBadgeStyle(statusClass: .success).tint == .green)
        #expect(StatusBadgeStyle(statusClass: .clientError).tint == .red)
        #expect(StatusBadgeStyle(statusClass: .serverError).tint == .red)
    }

    @Test func spacingScaleIsIncreasing() {
        let scale = [Spacing.xxSmall, Spacing.xSmall, Spacing.small, Spacing.medium, Spacing.large, Spacing.xLarge]
        #expect(scale == scale.sorted())
        #expect(Set(scale).count == scale.count)
    }
}

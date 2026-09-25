import Foundation
import Testing

@testable import RPCore

/// Parsing, serializing, querying and comparing maximally nested documents must fit in the 512 KB stack of a
/// Swift concurrency thread, where the app does this work. A stack overflow would crash the test process.
@Suite("DeepNesting")
struct DeepNestingTests {
    static let cooperativeThreadStackBytes = 512 * 1024

    func runOnSmallStack(_ work: @escaping @Sendable () -> Bool) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let result = LockedFlag()
        let thread = Thread {
            result.set(work())
            done.signal()
        }
        thread.stackSize = Self.cooperativeThreadStackBytes
        thread.start()
        done.wait()
        return result.value
    }

    @Test func maximumDepthJSONFitsCooperativeThreadStack() {
        let depth = JSONParser.defaultMaximumDepth
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let objects = String(repeating: "{\"k\":", count: depth - 1) + "1" + String(repeating: "}", count: depth - 1)
        let succeeded = runOnSmallStack {
            for text in [arrays, objects] {
                guard let value = try? JSONParser().parse(text) else { return false }
                let serialized = JSONSerializer.string(from: value)
                guard (try? JSONParser().parse(serialized)) == value else { return false }
                guard value.isSemanticallyEqual(to: value), (try? JSONPath("$..*").evaluate(value))?.isEmpty == false
                else {
                    return false
                }
            }
            return true
        }
        #expect(succeeded)
    }

    @Test func maximumDepthYAMLFitsCooperativeThreadStack() {
        let limit = 64
        var block = ""
        for level in 0..<(limit - 1) { block += String(repeating: " ", count: level * 2) + "k:\n" }
        block += String(repeating: " ", count: (limit - 1) * 2) + "leaf: 1\n"
        let flow = String(repeating: "[", count: limit) + String(repeating: "]", count: limit)
        let mixed =
            "a:\n  - " + String(repeating: "{k: ", count: limit - 3) + "1" + String(repeating: "}", count: limit - 3)
        let documents = [block, flow, mixed]
        let succeeded = runOnSmallStack {
            documents.allSatisfy { (try? YAMLParser(maximumDepth: limit).parse($0)) != nil }
        }
        #expect(succeeded)
        #expect(throws: CoreError.nestingTooDeep(limit: limit)) {
            try YAMLParser(maximumDepth: limit).parse(
                String(repeating: "[", count: 500) + String(repeating: "]", count: 500))
        }
    }

    @Test func maximumDepthGraphQLFitsCooperativeThreadStack() {
        let depth = 63
        let query = String(repeating: "{ a ", count: depth) + "b" + String(repeating: " }", count: depth)
        let values = "{ f(x: " + String(repeating: "[", count: 60) + String(repeating: "]", count: 60) + ") }"
        let succeeded = runOnSmallStack {
            GraphQLValidator.diagnostics(for: query).isEmpty && GraphQLValidator.diagnostics(for: values).isEmpty
        }
        #expect(succeeded)
    }
}

final class LockedFlag: @unchecked Sendable {
    // @unchecked: all access to `stored` is serialized by `lock`.
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}

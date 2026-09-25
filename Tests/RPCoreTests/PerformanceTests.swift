import Foundation
import XCTest

@testable import RPCore

/// Hot-path budgets (Phase 2 exit, B8). Budgets are for Debug builds on Apple silicon (CI and local runs) and
/// are recorded with measured values in docs/TEST_PLAN.md. `measure` blocks report clock and memory metrics.
final class PerformanceTests: XCTestCase {
    /// Budgets are meaningless under Address/Thread Sanitizer (several times slower); those runs check memory
    /// and thread safety, and the budgets are enforced by the regular test runs.
    override func setUpWithError() throws {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        let symbols = ["__asan_init", "__tsan_init"]
        let sanitizerLoaded = symbols.contains { symbol in dlsym(defaultHandle, symbol) != nil }
        try XCTSkipIf(sanitizerLoaded, "Performance budgets are not measured under sanitizers")
    }

    static let largeJSON: Data = {
        var text = "{\"items\":["
        var index = 0
        while text.utf8.count < 10 * 1024 * 1024 {
            if index > 0 { text += "," }
            text +=
                #"{"id":\#(index),"name":"Item \#(index)","price":\#(index).99,"tags":["alpha","beta"],"active":true,"meta":{"note":"café é \#(index)","nested":[1,2,3]}}"#
            index += 1
        }
        text += "]}"
        return Data(text.utf8)
    }()

    static let largeYAML: String = {
        var text = "openapi: 3.0.0\ninfo:\n  title: Big\n  version: '1'\npaths:\n"
        for index in 0..<2_000 {
            text += """
                  /resource\(index)/{id}:
                    get:
                      summary: Get resource \(index)
                      tags: [group\(index % 20)]
                      parameters:
                        - name: id
                          in: path
                          required: true
                          schema: {type: string, format: uuid}
                      responses:
                        '200':
                          description: >
                            A folded description for
                            resource \(index).

                """
        }
        return text
    }()

    func testJSONParseThroughputAndMemory() throws {
        let data = Self.largeJSON
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = try? JSONParser().parse(data)
        }
    }

    func testJSONParseBudget() throws {
        let data = Self.largeJSON
        let start = ContinuousClock.now
        let value = try JSONParser().parse(data)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(value["items"]?.arrayValue?.isEmpty, false)
        XCTAssertLessThan(elapsed, .seconds(3), "10 MB JSON parse took \(elapsed)")
    }

    func testJSONPathOverLargeDocumentBudget() throws {
        let value = try JSONParser().parse(Self.largeJSON)
        let start = ContinuousClock.now
        let matches = try JSONPath("$.items[*].meta.note").evaluate(value)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(matches.count, JSONPath.maximumMatches)
        XCTAssertLessThan(elapsed, .seconds(2), "JSONPath took \(elapsed)")
    }

    func testYAMLParseBudget() throws {
        let text = Self.largeYAML
        let start = ContinuousClock.now
        let value = try YAMLParser().parse(text)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(value["paths"]?.objectValue?.count, 2_000)
        XCTAssertLessThan(elapsed, .seconds(2), "YAML parse of \(text.utf8.count) bytes took \(elapsed)")
    }

    func testOpenAPIImportBudget() throws {
        let data = Data(Self.largeYAML.utf8)
        let start = ContinuousClock.now
        let collection = try OpenAPIImporter.importDocument(data)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(collection.items.count, 2_000)
        XCTAssertLessThan(elapsed, .seconds(3), "OpenAPI import took \(elapsed)")
    }

    func testBruDecodeEncodeBudget() throws {
        let text = try FixtureLoader.text("bru/bruno/request.bru")
        let start = ContinuousClock.now
        for _ in 0..<1_000 {
            let (request, document) = try BruRequestCodec.decode(text)
            _ = try BruRequestCodec.encode(request, preserving: document)
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(2), "1,000 .bru round trips took \(elapsed)")
    }

    func testBruRoundTripMeasure() throws {
        let text = try FixtureLoader.text("bru/bruno/request.bru")
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<200 {
                if let (request, document) = try? BruRequestCodec.decode(text) {
                    _ = try? BruRequestCodec.encode(request, preserving: document)
                }
            }
        }
    }
}

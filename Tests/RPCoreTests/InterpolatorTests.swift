import Foundation
import Testing

@testable import RPCore

@Suite("Interpolator")
struct InterpolatorTests {
    let secretRef = SecretRef(account: "env:local:token")

    var interpolator: Interpolator {
        let reference = secretRef
        return Interpolator(
            secretResolver: { $0 == reference ? "s3cr3t" : nil },
            dynamicValues: DynamicValues(
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                uuid: { UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F") ?? UUID() },
                randomInt: { 42 }))
    }

    func context(_ scopes: [VariableScope]) -> VariableContext { VariableContext(scopes: scopes) }

    @Test func precedenceFollowsBruno() {
        let ctx = context([
            VariableScope(kind: .global, values: ["v": .plain("global"), "g": .plain("G")]),
            VariableScope(kind: .collection, values: ["v": .plain("collection")]),
            VariableScope(kind: .environment, values: ["v": .plain("env")]),
            VariableScope(kind: .folder, values: ["v": .plain("folder")]),
            VariableScope(kind: .request, values: ["v": .plain("request")]),
            VariableScope(kind: .runtime, values: ["v": .plain("runtime")]),
        ])
        #expect(interpolator.interpolate("{{v}}-{{g}}", in: ctx).text == "runtime-G")
        var withoutRuntime = ctx
        withoutRuntime.scopes.removeAll { $0.kind == .runtime }
        #expect(interpolator.interpolate("{{v}}", in: withoutRuntime).text == "request")
        #expect(ctx.lookup("v")?.scope == .runtime)
        #expect(ctx.visibleNames.map(\.name) == ["g", "v"])
    }

    @Test func unresolvedAreReportedAndLeftInPlace() {
        let result = interpolator.interpolate("{{a}}/{{ b }}/{{a}}", in: context([]))
        #expect(result.text == "{{a}}/{{ b }}/{{a}}")
        #expect(result.unresolved == ["a", "b"])
    }

    @Test func nestedAndCyclicReferences() {
        let ctx = context([
            VariableScope(
                kind: .environment,
                values: [
                    "host": .plain("{{proto}}://api"), "proto": .plain("https"), "loop": .plain("{{loop}}"),
                    "a": .plain("{{b}}"), "b": .plain("{{a}}"),
                ])
        ])
        #expect(interpolator.interpolate("{{host}}/x", in: ctx).text == "https://api/x")
        let cyclic = interpolator.interpolate("{{loop}}|{{a}}", in: ctx)
        #expect(cyclic.text == "{{loop}}|{{a}}")
        #expect(cyclic.unresolved.sorted() == ["a", "loop"])
    }

    @Test func depthLimit() {
        var values: [String: VariableValue] = [:]
        for index in 0..<20 { values["v\(index)"] = .plain("{{v\(index + 1)}}") }
        values["v20"] = .plain("end")
        let result = interpolator.interpolate("{{v0}}", in: context([VariableScope(kind: .global, values: values)]))
        #expect(result.text == "{{v8}}")
        #expect(result.unresolved == ["v8"])
    }

    @Test func secretsInSendAndDisplayModes() {
        let ctx = context([
            VariableScope(
                kind: .environment, values: ["token": .secret(secretRef), "missing": .secret(SecretRef(account: "x"))])
        ])
        let sent = interpolator.interpolate("Bearer {{token}}", in: ctx)
        #expect(sent.text == "Bearer s3cr3t")
        #expect(sent.containsSecrets)
        let shown = interpolator.interpolate("Bearer {{token}}", in: ctx, mode: .display)
        #expect(shown.text == "Bearer ••••••")
        #expect(!shown.containsSecrets)
        let missing = interpolator.interpolate("{{missing}}", in: ctx)
        #expect(missing.unresolved == ["missing"])
    }

    @Test func dynamicVariables() {
        let result = interpolator.interpolate(
            "{{$guid}} {{$timestamp}} {{$isoTimestamp}} {{$randomInt}} {{$nope}}", in: context([]))
        #expect(result.text == "e621e1f8-c36c-495a-93fc-0c247a3e6e5f 1700000000 2023-11-14T22:13:20Z 42 {{$nope}}")
        #expect(result.unresolved == ["$nope"])
    }

    @Test func tokenScanning() {
        let template = "a {{x}} {{}} {{ y }} {{bad\nname}} {{ {{z}} {{unterminated"
        #expect(Interpolator.tokens(in: template).map(\.name) == ["x", "y", "z"])
        #expect(Interpolator.tokens(in: "no tokens").isEmpty)
    }

    @Test func expansionSizeIsBounded() {
        // Each level doubles the output; the byte cap stops expansion instead of exhausting memory.
        var values: [String: VariableValue] = ["v0": .plain(String(repeating: "x", count: 1_000_000))]
        for index in 1...6 { values["v\(index)"] = .plain("{{v\(index - 1)}}{{v\(index - 1)}}") }
        let result = interpolator.interpolate(
            "{{v6}}{{v6}}", in: context([VariableScope(kind: .global, values: values)]))
        #expect(result.text.utf8.count <= Interpolator.maximumOutputBytes + 2_000_000)
    }

    @Test func scopesFromVariablesAndRows() {
        let scope = VariableScope(
            kind: .environment,
            variables: [
                .plain("a", "1"), .plain("a", "2"), .plain("off", "x", isEnabled: false), .plain("", "empty"),
            ])
        #expect(scope.values == ["a": .plain("2")])
        let rows = VariableScope(
            kind: .request, rows: [KeyValue(name: "r", value: "1"), KeyValue(name: "d", value: "2", isEnabled: false)])
        #expect(rows.values == ["r": .plain("1")])
    }

    @Test(arguments: [("valid_name-1.x", true), ("", false), ("has space", false), ("a{b", false), ("ünï", true)])
    func variableNames(name: String, valid: Bool) {
        #expect(Variable.isValidName(name) == valid)
    }

    @Test func secretRefForEnvironment() {
        #expect(SecretRef.environmentVariable(environmentKey: "k", name: "n").account == "env:k:n")
        #expect(VariableValue.secret(secretRef).isSecret)
        #expect(!VariableValue.plain("x").isSecret)
    }
}

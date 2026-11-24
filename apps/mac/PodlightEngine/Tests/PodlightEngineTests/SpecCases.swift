import Foundation
import Testing
@testable import PodlightEngine

// Runs every case in `spec/cases/scheduler*.json` against the Swift scheduler. The spec is the
// source of truth: when a case fails, fix the code, never the expected value here or there.

struct SpecCase: Sendable, CustomTestStringConvertible {
    let file: String
    let id: String
    let function: String
    let status: String?
    let input: Data
    let expected: Data

    var testDescription: String { "\(file): \(id)" }
}

enum Spec {
    /// `<repo>/spec`, found from this file's location so the tests run from any directory.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PodlightEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // PodlightEngine
        .deletingLastPathComponent()   // mac
        .deletingLastPathComponent()   // apps
        .deletingLastPathComponent()   // repo
        .appendingPathComponent("spec")

    static func load(_ names: [String]) -> [SpecCase] {
        names.flatMap { name -> [SpecCase] in
            let url = root.appendingPathComponent("cases/\(name)")
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cases = doc["cases"] as? [[String: Any]]
            else { return [SpecCase(file: name, id: "<unreadable>", function: "load", status: nil, input: Data(), expected: Data())] }
            return cases.map { c in
                SpecCase(
                    file: name,
                    id: c["id"] as? String ?? "?",
                    function: c["function"] as? String ?? "?",
                    status: c["status"] as? String,
                    input: (try? JSONSerialization.data(withJSONObject: c["input"] ?? [:], options: [.fragmentsAllowed])) ?? Data(),
                    expected: (try? JSONSerialization.data(withJSONObject: c["expected"] ?? NSNull(), options: [.fragmentsAllowed])) ?? Data()
                )
            }
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "not ISO 8601: \(text)"))
        }
        return decoder
    }()
}

private struct DecideInput: Decodable {
    var schedule: Schedule
    var pod: PodState
    var spend: Spend
    var session: Session?
    var now: Date
}

private struct WindowInput: Decodable {
    var schedule: Schedule
    var now: Date
}

private struct LocalPartsInput: Decodable {
    var instant: Date
    var timeZone: String
}

private struct WakeInput: Decodable {
    var spend: Spend
}

private struct CapacityInput: Decodable {
    var gpuMemoryGib: Double
    var weightsGib: Double
    var nativeContextTokens: Int?
    var contextTokens: Int?
    var concurrency: Int?
}

private struct Support: Decodable, Equatable { var fp8: Bool; var nvfp4: Bool }

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Suite("spec/cases")
struct SpecCaseTests {
    static let all = Spec.load(["scheduler.json", "scheduler-podlight.json", "capacity.json", "kv-profile.json", "gguf.json",
                                "gpu-suggest.json", "pod-plan.json", "hosting.json", "gateway.json", "price-guard.json"])

    @Test("every spec file was found and parsed")
    func specIsReadable() {
        #expect(!Self.all.contains { $0.id == "<unreadable>" }, "spec files missing under \(Spec.root.path)")
        #expect(Self.all.count >= 56 + 91)
    }

    @Test(arguments: all)
    func matchesSpec(_ c: SpecCase) throws {
        let d = Spec.decoder
        switch c.function {
        case "decide":
            let i = try d.decode(DecideInput.self, from: c.input)
            let got = Scheduler.decide(schedule: i.schedule, pod: i.pod, spend: i.spend, session: i.session, now: i.now)
            #expect(got == (try d.decode(Action.self, from: c.expected)))
        case "isInsideWindow":
            let i = try d.decode(WindowInput.self, from: c.input)
            #expect(Scheduler.isInsideWindow(i.schedule, now: i.now) == (try d.decode(Bool.self, from: c.expected)))
        case "minutesUntilStop":
            let i = try d.decode(WindowInput.self, from: c.input)
            #expect(Scheduler.minutesUntilStop(i.schedule, now: i.now) == (try d.decode(Int?.self, from: c.expected)))
        case "windowOpenedAt":
            let i = try d.decode(WindowInput.self, from: c.input)
            #expect(Scheduler.windowOpenedAt(i.schedule, now: i.now) == (try d.decode(Date?.self, from: c.expected)))
        case "localParts":
            let i = try d.decode(LocalPartsInput.self, from: c.input)
            #expect(Scheduler.localParts(i.instant, timeZone: i.timeZone) == (try d.decode(Scheduler.LocalParts.self, from: c.expected)))
        case "admitWake":
            let i = try d.decode(WakeInput.self, from: c.input)
            #expect(Scheduler.admitWake(spend: i.spend) == (try d.decode(WakeDecision.self, from: c.expected)))
        case "estimateKvHeadroomGib":
            let i = try d.decode(CapacityInput.self, from: c.input)
            let expected = try d.decode(Double.self, from: c.expected)
            #expect(close(Capacity.kvHeadroomGiB(gpuMemoryGiB: i.gpuMemoryGib, weightsGiB: i.weightsGib), expected))
        case "maxContextTokens":
            struct I: Decodable { var headroomGib: Double }
            let i = try d.decode(I.self, from: c.input)
            #expect(Capacity.maxContextTokens(headroomGiB: i.headroomGib) == (try d.decode(Int.self, from: c.expected)))
        case "recommendCapacity":
            let i = try d.decode(CapacityInput.self, from: c.input)
            let got = Capacity.recommend(gpuMemoryGiB: i.gpuMemoryGib, weightsGiB: i.weightsGib, nativeContextTokens: i.nativeContextTokens)
            #expect(got == (try d.decode(Capacity.Choice?.self, from: c.expected)))
        case "planCapacity":
            let i = try d.decode(CapacityInput.self, from: c.input)
            let got = Capacity.plan(gpuMemoryGiB: i.gpuMemoryGib, weightsGiB: i.weightsGib, nativeContextTokens: i.nativeContextTokens,
                                    chosen: .init(contextTokens: i.contextTokens ?? 0, concurrency: i.concurrency ?? 1))
            var expected = try d.decode(Capacity.Plan.self, from: c.expected)
            #expect(close(got.headroomGib, expected.headroomGib))
            expected.headroomGib = got.headroomGib
            #expect(got == expected)
        case "gpuSupports":
            struct I: Decodable { var gpuId: String }
            let i = try d.decode(I.self, from: c.input)
            #expect(Support(fp8: CardSupport.fp8(i.gpuId), nvfp4: CardSupport.nvfp4(i.gpuId)) == (try d.decode(Support.self, from: c.expected)))
        case "kvProfile":
            let input = try JSONSerialization.jsonObject(with: c.input) as? [String: Any]
            let got = KVProfile.from(config: input?["config"] as? [String: Any])
            if let expected = try d.decode(KVProfile?.self, from: c.expected) {
                let value = try #require(got)
                #expect(abs(value.bytesPerToken - expected.bytesPerToken) < 1e-6)
                #expect(value.attentionHeads == expected.attentionHeads && value.hybrid == expected.hybrid)
            } else {
                #expect(got == nil)
            }
        case "ggufQuants":
            struct File: Decodable { var path: String; var bytes: Double }
            struct I: Decodable { var files: [File] }
            struct E: Decodable { var names: [String]; var recommended: String? }
            let i = try d.decode(I.self, from: c.input)
            let e = try d.decode(E.self, from: c.expected)
            let quants = GGUF.quants(from: i.files.map { ($0.path, $0.bytes) })
            #expect(quants.map(\.name) == e.names)
            #expect(GGUF.recommended(quants)?.name == e.recommended)
        case "ggufKvProfile":
            let input = try JSONSerialization.jsonObject(with: c.input) as? [String: Any]
            let got = GGUF.kvProfile(from: input?["meta"] as? [String: Any] ?? [:])
            if let expected = try d.decode(KVProfile?.self, from: c.expected) {
                let value = try #require(got)
                #expect(abs(value.bytesPerToken - expected.bytesPerToken) < 1e-6)
                #expect(value.attentionHeads == expected.attentionHeads && value.hybrid == expected.hybrid)
            } else {
                #expect(got == nil)
            }
        case "gpuOptions", "podChoices", "podRequest", "hostingClouds", "needsPlacementCheck", "hostingAllows",
             "mayHaveCapacity", "dataCenterIds", "storagePricing", "systemMessagesAsReminders", "gatewayError",
             "isValidName", "summarizeEngineLog", "looksDegenerate", "priceGuard":
            try SpecRuntime.check(c)
        default:
            Issue.record("unknown function \(c.function) in \(c.file)")
        }
    }
}

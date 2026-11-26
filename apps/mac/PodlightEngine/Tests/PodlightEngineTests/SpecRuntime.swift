import Foundation
import Testing
@testable import PodlightEngine

// The runtime rules the server must share with the Mac: card suggestions, the pod request,
// hosting and the gateway's rewrites and error codes (spec/cases/{gpu-suggest,pod-plan,hosting,
// gateway}.json). JSON in, JSON out, compared as values with a tolerance for numbers.

enum SpecRuntime {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed]))
    }

    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }

    static func catalog(_ name: Any?) throws -> [RunpodGPUType] {
        let path = try #require(name as? String)
        let data = try Data(contentsOf: Spec.root.appendingPathComponent(path))
        return try JSONDecoder().decode(RunpodGPUCatalog.self, from: data).gpus
    }

    static func check(_ c: SpecCase) throws {
        let input = try object(c.input)
        let expected = try JSONSerialization.jsonObject(with: c.expected, options: [.fragmentsAllowed])
        let got: Any
        switch c.function {
        case "gpuOptions":
            let model = try decode(PodlightModel.self, input["model"])
            let options = GPUSuggestion.options(
                for: model.info, catalog: try catalog(input["catalog"]),
                goal: try decode(SuggestionGoal.self, input["goal"]), context: try decode(Int.self, input["context"]),
                concurrency: try decode(Int.self, input["concurrency"]), hosting: try decode(HostingPolicy.self, input["hosting"]))
            got = try options.map { o -> [String: Any] in
                ["choice": try json(o.choice), "pricePerHour": o.pricePerHour,
                 "estimatedTokensPerSecond": o.estimatedTokensPerSecond.map { $0 as Any } ?? NSNull(),
                 "contextTokens": o.contextTokens, "contextCeiling": o.contextCeiling, "dataCenters": o.dataCenters]
            }
        case "podChoices":
            let model = try decode(PodlightModel.self, input["model"])
            got = try json(PodPlan.choices(for: model, catalog: try catalog(input["catalog"]),
                                           hosting: try decode(HostingPolicy.self, input["hosting"])))
        case "priceGuard":
            let g = PodPlan.priceGuard(choices: try decode([GPUChoice].self, input["choices"]), catalog: try catalog(input["catalog"]),
                                       stepPercent: try decode(Int.self, input["stepPercent"]),
                                       maxPricePerHour: try decode(Double?.self, input["maxPricePerHour"]))
            got = ["wanted": try g.wanted.map { try json($0) } ?? NSNull(), "ceiling": g.ceiling as Any? ?? NSNull(),
                   "within": try json(g.within), "above": try json(g.above)]
        case "podRequest":
            let model = try decode(PodlightModel.self, input["model"])
            var request = PodPlan.request(
                for: model, podKey: try decode(String.self, input["podKey"]),
                huggingFaceToken: try decode(String?.self, input["huggingFaceToken"]),
                runUntil: try decode(Date?.self, input["runUntil"]),
                heartbeatMinutes: try decode(Int.self, input["heartbeatMinutes"]),
                dataCenterIds: try decode([String]?.self, input["dataCenterIds"]))
            #expect(request.env["PODLIGHT_WATCHDOG_B64"] == PodPlan.resource("watchdog", "py").base64EncodedString())
            request.env["PODLIGHT_WATCHDOG_B64"] = PodScriptMarker.watchdog
            request.env["PODLIGHT_BOOT_B64"] = PodScriptMarker.boot
            got = ["request": try json(request), "persistentGB": PodPlan.persistentGB(for: model),
                   "containerGB": PodPlan.containerGB(for: model), "storagePerHour": PodPlan.storagePerHour(for: model)]
        case "hostingClouds":
            got = try json(try decode(HostingPolicy.self, input["hosting"]).clouds)
        case "needsPlacementCheck":
            got = try decode(HostingPolicy.self, input["hosting"]).needsPlacementCheck
        case "hostingAllows":
            got = try decode(HostingPolicy.self, input["hosting"]).allows(dataCenterId: input["dataCenterId"] as? String)
        case "mayHaveCapacity":
            let gpu = try #require(try catalog(input["catalog"]).first { $0.id == input["gpuId"] as? String })
            got = try decode(HostingPolicy.self, input["hosting"]).mayHaveCapacity(gpu)
        case "dataCenterIds":
            got = try decode(HostingPolicy.self, input["hosting"]).dataCenterIds(in: try catalog(input["catalog"])) as Any? ?? NSNull()
        case "storagePricing":
            let container = try decode(Int.self, input["containerGB"]), volume = try decode(Int.self, input["volumeGB"])
            got = ["runningPerHour": StoragePricing.runningPerHour(containerGB: container, volumeGB: volume),
                   "stoppedPerMonth": StoragePricing.stoppedPerMonth(volumeGB: volume)]
        case "systemMessagesAsReminders":
            got = LocalGateway.systemMessagesAsReminders(try #require(input["body"] as? [String: Any])) ?? NSNull()
        case "gatewayError":
            let e = try #require(input["error"] as? [String: Any])
            let error: PodlightError = switch e["kind"] as? String {
            case "unknownModel": .unknownModel("m")
            case "missingRunpodKey": .missingRunpodKey
            case "limitReached": .limitReached(e["limit"] as? String ?? "")
            case "noCapacity": .noCapacity(e["tried"] as? [String] ?? [])
            case "noSuitableCard": .noSuitableCard
            case "notReadyInTime": .notReadyInTime
            case "wakeDisabled": .wakeDisabled
            default: .runpod(status: e["status"] as? Int ?? 0, message: e["message"] as? String ?? "")
            }
            let failure = LocalGateway.failure(for: error, model: input["model"] as? String ?? "m")
            got = input["anthropic"] as? Bool == true
                ? ["status": failure.status, "type": LocalGateway.anthropicType(failure.status)]
                : ["status": failure.status, "code": failure.code]
        case "isValidName":
            got = PodlightModel.isValidName(input["name"] as? String ?? "")
        case "summarizeEngineLog":
            got = PodManager.summarizeEngineLog(input["lines"] as? [String] ?? [])
        case "looksDegenerate":
            got = PodManager.looksDegenerate(input["text"] as? String ?? "")
        case "anthropicRequest":
            do {
                got = try normalized(AnthropicBridge.request(try #require(input["body"] as? [String: Any])))
            } catch let error as AnthropicBridge.InvalidRequest {
                got = ["thrown": error.message]
            }
        case "anthropicResponse":
            got = try normalized(AnthropicBridge.response(try #require(input["body"] as? [String: Any]),
                                                          requestModel: input["requestModel"] as? String ?? ""))
        case "anthropicStream":
            var translator = AnthropicBridge.StreamTranslator(requestModel: input["requestModel"] as? String ?? "")
            let chunks = input["chunks"] as? [[String: Any]] ?? []
            got = try normalized(chunks.flatMap { translator.feed($0) } + translator.finish())
        case "anthropicError":
            got = try normalized(AnthropicBridge.error(status: input["status"] as? Int ?? 0, body: input["body"] is NSNull ? nil : input["body"]))
        case "anthropicTokenEstimate":
            got = AnthropicBridge.estimateTokens(try #require(input["body"] as? [String: Any]))
        default:
            Issue.record("SpecRuntime has no \(c.function)")
            return
        }
        #expect(same(got, expected), "\(c.file) \(c.id): got \(got), expected \(expected)")
    }

    /// A value built in Swift as it reads after a JSON round trip (Bool and Int as NSNumber).
    static func normalized(_ value: Any) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), options: [.fragmentsAllowed])
    }

    /// Deep equality of JSON values; numbers within a relative 1e-9.
    static func same(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull): return true
        case let (x as [String: Any], y as [String: Any]):
            return Set(x.keys) == Set(y.keys) && x.allSatisfy { key, value in same(value, y[key]!) }
        case let (x as [Any], y as [Any]):
            return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case let (x as String, y as String): return x == y
        case let (x as NSNumber, y as NSNumber):
            if CFGetTypeID(x) == CFBooleanGetTypeID() || CFGetTypeID(y) == CFBooleanGetTypeID() { return x == y }
            let p = x.doubleValue, q = y.doubleValue
            return p == q || abs(p - q) <= 1e-9 * max(abs(p), abs(q))
        default: return false
        }
    }
}

@Suite("spec shared files")
struct SpecSharedFileTests {
    @Test func theBundledPodScriptsAreTheSpecOnes() throws {
        for (name, ext) in [("watchdog", "py"), ("boot", "sh")] {
            let spec = try Data(contentsOf: Spec.root.appendingPathComponent("pod/\(name).\(ext)"))
            #expect(PodPlan.resource(name, ext) == spec, "Resources/\(name).\(ext) differs from spec/pod; copy spec/pod over it")
        }
    }

    @Test func regionsAndPricesMatchRegionsJson() throws {
        let doc = try SpecRuntime.object(Data(contentsOf: Spec.root.appendingPathComponent("data/regions.json")))
        let regions = try #require(doc["regions"] as? [String: [String: Any]])
        #expect(regions["eu"]?["prefixes"] as? [String] == HostingRegion.eu.prefixes)
        #expect(regions["euEEA"]?["prefixes"] as? [String] == HostingRegion.euEEA.prefixes)
        let prices = try #require(doc["storagePricing"] as? [String: Any])
        #expect(prices["containerDiskRunningUsdPerGBMonth"] as? Double == StoragePricing.containerDiskRunning)
        #expect(prices["volumeDiskRunningUsdPerGBMonth"] as? Double == StoragePricing.volumeDiskRunning)
        #expect(prices["volumeDiskStoppedUsdPerGBMonth"] as? Double == StoragePricing.volumeDiskStopped)
        #expect(prices["hoursPerMonth"] as? Double == StoragePricing.hoursPerMonth)
    }
}

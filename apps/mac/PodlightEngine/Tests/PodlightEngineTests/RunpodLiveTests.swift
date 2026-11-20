import Foundation
import Testing
@testable import PodlightEngine

// Read-only checks against the real RunPod API: do the models decode what RunPod sends today?
// Runs only when RUNPOD_API_KEY is set, e.g.
//   RUNPOD_API_KEY=$(security find-generic-password -s <item> -w) swift test --filter Live
// Never creates, stops or deletes anything, so it costs nothing.

@Suite("RunPod live (read-only)", .enabled(if: ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil,
                                           "set RUNPOD_API_KEY to run against the real API"))
struct RunpodLiveTests {
    let client = RunpodClient(apiKey: ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] ?? "")

    @Test func keyIsAccepted() async {
        #expect(await client.checkKey() == .valid)
    }

    @Test func podListDecodes() async throws {
        let pods = try await client.listPods()
        for pod in pods { #expect(!pod.id.isEmpty) }
    }

    @Test func catalogDecodesWithPricesAndAvailability() async throws {
        let gpus = try await client.gpuCatalog()
        #expect(gpus.count > 10)
        #expect(gpus.contains { $0.availability != nil })
        #expect(gpus.contains { $0.pricePerHour(in: .community) != nil || $0.pricePerHour(in: .secure) != nil })
    }

    @Test func aWrongKeyIsReportedAsInvalid() async {
        #expect(await RunpodClient(apiKey: "definitely-not-a-key").checkKey() == .invalid)
    }
}

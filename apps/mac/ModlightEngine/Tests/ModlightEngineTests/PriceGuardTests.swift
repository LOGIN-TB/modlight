import Foundation
import Testing
@testable import ModlightEngine

// A start whose chosen card is taken may fall back to other cards, but not to any price: a start
// for a card at 0.79 $/h once ended on one at 7.99 $/h. Above the price step Modlight books
// nothing, offers the pricier cards and keeps trying within the price.

enum PriceFixture {
    /// Community-only, so the order of cards does not depend on the cloud.
    static let gpus = """
    [{"id":"NVIDIA RTX A4000","name":"RTX A4000","manufacturer":"NVIDIA","memory":16,"secure":false,"community":true,"price":{"community":0.17},"availability":"HIGH"},
     {"id":"NVIDIA RTX A5000","name":"RTX A5000","manufacturer":"NVIDIA","memory":24,"secure":false,"community":true,"price":{"community":0.22},"availability":"HIGH"},
     {"id":"NVIDIA H100 80GB HBM3","name":"H100 SXM","manufacturer":"NVIDIA","memory":80,"secure":false,"community":true,"price":{"community":2.69},"availability":"HIGH"}]
    """
    static func catalog() throws -> [RunpodGPUType] {
        try RunpodClient.decoder.decode(RunpodGPUCatalog.self, from: Data(#"{"gpus":\#(gpus)}"#.utf8)).gpus
    }
    static let a4000 = GPUChoice(gpuId: "NVIDIA RTX A4000", cloud: .community)
    static let a5000 = GPUChoice(gpuId: "NVIDIA RTX A5000", cloud: .community)
    static let h100 = GPUChoice(gpuId: "NVIDIA H100 80GB HBM3", cloud: .community)
}

@Suite("Price step for fallback cards")
struct PriceGuardTests {
    @Test func fallbacksUpToTheStepPricierOnesOffered() throws {
        let catalog = try PriceFixture.catalog()
        let g = PodPlan.priceGuard(choices: [PriceFixture.a4000, PriceFixture.h100, PriceFixture.a5000], catalog: catalog, stepPercent: 50)
        #expect(g.wanted?.pricePerHour == 0.17 && g.wanted?.name == "RTX A4000")
        #expect(g.ceiling == 0.255)
        #expect(g.within == [PriceFixture.a4000, PriceFixture.a5000], "the original order, without the pricey one")
        #expect(g.above.map(\.name) == ["H100 SXM"] && g.above.first?.pricePerHour == 2.69)
    }

    @Test func zeroMeansAnyExtraCostAsksAndAnApprovalRaisesTheCeiling() throws {
        let catalog = try PriceFixture.catalog()
        let choices = [PriceFixture.a4000, PriceFixture.a5000, PriceFixture.h100]
        let strict = PodPlan.priceGuard(choices: choices, catalog: catalog, stepPercent: 0)
        #expect(strict.within == [PriceFixture.a4000] && strict.above.map(\.name) == ["RTX A5000", "H100 SXM"])
        let approved = PodPlan.priceGuard(choices: choices, catalog: catalog, stepPercent: 0, maxPricePerHour: 2.69)
        #expect(approved.ceiling == 2.69 && approved.within == choices && approved.above.isEmpty)
    }

    @Test func severalCardsCountTimesThePriceAndAnUnknownPriceNeverBooks() throws {
        let catalog = try PriceFixture.catalog()
        let two = GPUChoice(gpuId: "NVIDIA RTX A5000", cloud: .community, count: 2)
        let unknown = GPUChoice(gpuId: "NVIDIA B200", cloud: .community)
        let g = PodPlan.priceGuard(choices: [PriceFixture.a4000, two, unknown], catalog: catalog, stepPercent: 200)
        #expect(g.ceiling == 0.51)
        #expect(g.within == [PriceFixture.a4000, two] && g.above.isEmpty, "0.44 for two cards is within; B200 has no price")
        #expect(PodPlan.priceGuard(choices: [unknown, PriceFixture.h100], catalog: catalog, stepPercent: 50).within.count == 2,
                "no reference price: nothing held back")
    }
}

@Suite("Starting when the chosen card is taken", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                                                                       "uses the login keychain; runs on a developer Mac"))
struct PriceGuardFlowTests {
    static func model() -> ModlightModel {
        ModlightModel(name: "coder", repoId: "Org/Coder-AWQ", format: .awq, weightBytes: 6e9, nativeContextTokens: 131_072,
                      toolCallParser: nil, reasoningParser: nil, contextTokens: 16_384, preferredGPU: PriceFixture.a4000)
    }

    @Test func pricierCardsAreOfferedNotBookedAndModlightWaitsWithinThePrice() async throws {
        let runpod = SharedRunPod()
        await runpod.setCatalog(PriceFixture.gpus)
        let a = try await TakeOverFlowTests.mac(runpod, tag: "mac-a-aaaa")
        let model = Self.model()
        try await a.manager.save(model)
        defer { a.cleanUp(models: [model.id]) }

        // A4000 and A5000 taken, only the H100 (16 times the price) free: nothing is booked.
        await runpod.setTaken(["NVIDIA RTX A4000", "NVIDIA RTX A5000"])
        let until = Date().addingTimeInterval(3600)
        do {
            try await a.manager.start(model.id, until: until)
            Issue.record("started although only a pricier card was free")
        } catch ModlightError.cardTooExpensive(let wanted, let ceiling, let pricier) {
            #expect(wanted?.name == "RTX A4000" && ceiling == 0.255 && pricier.map(\.name) == ["H100 SXM"])
        }
        #expect(await runpod.createdOn == [], "no pod on the H100")
        var run = await a.manager.state().run(model.id)
        #expect(run.phase == .stopped && run.lastReason == "card-too-expensive" && run.podId == nil)
        #expect(run.waitingForCard?.until == until && run.waitingForCard?.maxPricePerHour == 0.255)
        #expect(run.waitingForCard?.pricier?.first?.pricePerHour == 2.69)

        // Still taken: still waiting, still nothing booked.
        await a.manager.tick()
        #expect(await runpod.createdOn == [])
        #expect(await a.manager.state().run(model.id).waitingForCard != nil)

        // The A5000 comes free (0.22 $/h, within +50 %): the next tick starts on it.
        await runpod.setTaken(["NVIDIA RTX A4000"])
        await a.manager.tick()
        run = await a.manager.state().run(model.id)
        #expect(await runpod.createdOn == ["NVIDIA RTX A5000"])
        #expect(run.podId != nil && run.waitingForCard == nil && run.gpu == PriceFixture.a5000 && run.runUntil == until)
        #expect(run.fellBackFrom == ["RTX A4000"] && run.wantedPricePerHour == 0.17)
        try await a.manager.stop(model.id)
    }

    @Test func anApprovedPriceStartsOnThePricierCardAndAWokenStartWaitsHalfAnHour() async throws {
        let runpod = SharedRunPod()
        await runpod.setCatalog(PriceFixture.gpus)
        let a = try await TakeOverFlowTests.mac(runpod, tag: "mac-a-aaaa")
        let model = Self.model()
        try await a.manager.save(model)
        defer { a.cleanUp(models: [model.id]) }
        await runpod.setTaken(["NVIDIA RTX A4000", "NVIDIA RTX A5000"])

        // A request woke it: nobody to ask, so it waits half an hour instead of booking the H100.
        let before = Date()
        await #expect(throws: ModlightError.self) { try await a.manager.start(model.id, until: nil, manual: false) }
        let waiting = try #require(await a.manager.state().run(model.id).waitingForCard)
        #expect(waiting.manual == false && waiting.until >= before.addingTimeInterval(1790))
        #expect(LocalGateway.failure(for: .cardTooExpensive(wanted: waiting.wanted, ceiling: 0.255, pricier: waiting.pricier ?? []),
                                     model: "coder").code == "card_too_expensive")

        // The user approves the H100's price: it starts there, and the waiting ends.
        try await a.manager.start(model.id, until: Date().addingTimeInterval(3600), maxPricePerHour: 2.69)
        let run = await a.manager.state().run(model.id)
        #expect(await runpod.createdOn == ["NVIDIA H100 80GB HBM3"])
        #expect(run.gpu == PriceFixture.h100 && run.waitingForCard == nil && run.wantedPricePerHour == 0.17)
        try await a.manager.stop(model.id)
    }
}

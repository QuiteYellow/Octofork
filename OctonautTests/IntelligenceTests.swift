import XCTest
@testable import Octonaut

final class IntelligenceTests: XCTestCase {
    func testDeterministicFilterRemovesBlockedCommunitiesAndKeywords() {
        let result = DeterministicPostFilter.apply(
            FixtureData.posts,
            configuration: DeterministicFilterConfiguration(
                blockedCommunities: ["swift"],
                keywordRules: [KeywordFilterRule(terms: ["coast"], fields: [.title])]
            )
        )

        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertEqual(result.removedCount, FixtureData.posts.count)
        XCTAssertEqual(result.reasons["Community"], 2)
        XCTAssertEqual(result.reasons["Keyword"], 1)
    }

    /// Seen posts are hidden when the feed renders, never on the way in. See
    /// `testTogglingHideSeenChangesTheFeedWithoutRefetching`.
    func testTheDeterministicFilterDoesNotRemoveSeenPosts() {
        let result = DeterministicPostFilter.apply(
            FixtureData.posts,
            configuration: DeterministicFilterConfiguration()
        )

        XCTAssertEqual(result.visible.count, FixtureData.posts.count)
        XCTAssertNil(result.reasons["Seen"])
    }

    func testKeyExcerptsAreDeterministicAndOrdered() {
        let first = DeterministicExcerptEngine.excerpts(
            title: "SwiftUI updates",
            body: "First sentence explains the change. Second sentence gives the tradeoff. Third sentence describes the result."
        )
        let second = DeterministicExcerptEngine.excerpts(
            title: "SwiftUI updates",
            body: "First sentence explains the change. Second sentence gives the tradeoff. Third sentence describes the result."
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.first, "First sentence explains the change.")
    }

    func testHelpIndexWorksWithoutNetwork() {
        let results = LocalHelpIndex().search("semantic filter")
        XCTAssertEqual(results.first?.section.id, "filters")
    }

    func testPostSummaryEligibilityHidesContentBelow850Scalars() {
        var shortPost = FixtureData.posts[0]
        shortPost.title = ""
        shortPost.body = RichText(plainText: String(repeating: "a", count: 848))
        XCTAssertFalse(SummaryEligibility.post(shortPost))

        shortPost.body = RichText(plainText: String(repeating: "a", count: 849))
        XCTAssertTrue(SummaryEligibility.post(shortPost))
    }

    func testSummaryCacheReusesMatchingContentAndProvider() async {
        let cache = InMemorySummaryCache(lifetime: 60, capacity: 2)
        let summary = ContentSummary(bullets: ["A useful summary"], generatedAt: Date(timeIntervalSince1970: 1_000))
        let key = SummaryCacheKey(contentID: "post:1", title: "Title", body: "Body", modelFamily: "on-device")
        await cache.insert(summary, for: key, now: Date(timeIntervalSince1970: 1_000))

        let reused = await cache.value(for: key, now: Date(timeIntervalSince1970: 1_030))
        XCTAssertEqual(reused, summary)
        let otherProvider = SummaryCacheKey(contentID: "post:1", title: "Title", body: "Body", modelFamily: "remote-model")
        let otherContent = SummaryCacheKey(contentID: "post:1", title: "Title", body: "Updated", modelFamily: "on-device")
        let providerResult = await cache.value(for: otherProvider, now: Date(timeIntervalSince1970: 1_030))
        let contentResult = await cache.value(for: otherContent, now: Date(timeIntervalSince1970: 1_030))
        XCTAssertNil(providerResult)
        XCTAssertNil(contentResult)
        let expired = await cache.value(for: key, now: Date(timeIntervalSince1970: 1_061))
        XCTAssertNil(expired)
    }

    @MainActor
    func testRemoteSummaryAvailabilityIsSeparateFromOnDeviceFeatures() async throws {
        let apiKeys = InMemorySummaryAPIKeyStore()
        let service = ConfiguredIntelligenceService(
            onDevice: UnavailableIntelligenceService(),
            apiKeyStore: apiKeys
        ) {
            (
                .openAICompatible,
                OpenAICompatibleSummaryConfiguration(
                    endpoint: "https://openrouter.ai/api/v1",
                    model: "openai/gpt-5.6-luna"
                )
            )
        }

        let onDeviceAvailability = await service.availability
        let missingKeyAvailability = await service.summaryAvailability
        XCTAssertEqual(onDeviceAvailability, .unsupported)
        XCTAssertEqual(missingKeyAvailability, .remoteAPIKeyMissing)

        try await apiKeys.saveAPIKey("test-key")
        let configuredAvailability = await service.summaryAvailability
        XCTAssertEqual(configuredAvailability, .available)
    }
}

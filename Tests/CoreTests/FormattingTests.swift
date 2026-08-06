import Foundation
import Testing

@testable import OllamaBarCore

/// These strings sit in fixed-width columns next to each other, so their shape is part of the
/// design, not a detail.
struct FormattingTests {
    @Test(arguments: [
        (0, "0"),
        (999, "999"),
        (1_000, "1.0K"),
        (9_900, "9.9K"),
        (32_768, "32.8K"),
        (150_000, "150K"),
    ])
    func compactTokens(input: Int, expected: String) {
        #expect(Format.tokensCompact(input) == expected)
    }

    @Test(arguments: [
        (0.0, "0:00"),
        (42.0, "0:42"),
        (91.0, "1:31"),
        (3_671.0, "1:01:11"),
    ])
    func elapsedReadsLikeAStopwatch(input: Double, expected: String) {
        #expect(Format.elapsed(input) == expected)
    }

    @Test(arguments: [(5.0, "5s"), (120.0, "2m"), (7_200.0, "2h")])
    func ageIsCoarse(input: Double, expected: String) {
        #expect(Format.age(input) == expected)
    }

    @Test func evictionSwitchesToDueOncePassed() {
        #expect(Format.eviction(252) == "evicts in 4:12")
        #expect(Format.eviction(0) == "eviction due")
        #expect(Format.eviction(-30) == "eviction due")
    }

    @Test func longCountdownsGetAnHourComponent() {
        #expect(Format.eviction(3_720) == "evicts in 1h 02m")
    }

    @Test func phasesAreOneDecimalAndDashWhenAbsent() {
        #expect(Format.phase(8.42) == "8.4")
        #expect(Format.phase(0) == "—")
    }
}

struct ExchangeTimingsTests {
    /// The whole point of the breakdown: loading weights routinely dominates the request.
    @Test func dominantPhaseNamesTheExpensiveOne() {
        let timings = ExchangeTimings(load: 8.4, prompt: 1.2, generation: 1.2)

        let dominant = timings.dominantPhase
        #expect(dominant?.name == "load")
        #expect((dominant?.share ?? 0) > 0.77)
        #expect((dominant?.share ?? 0) < 0.79)
    }

    @Test func warmModelHasNoLoadPhase() {
        let timings = ExchangeTimings(load: 0, prompt: 0.4, generation: 22.6)

        #expect(timings.dominantPhase?.name == "generation")
        #expect(timings.total == 23)
    }

    @Test func emptyTimingsHaveNoDominantPhase() {
        #expect(ExchangeTimings(load: 0, prompt: 0, generation: 0).dominantPhase == nil)
    }
}

import Foundation
import Testing

import OllamaBarCore
@testable import OllamaBarInfrastructure

struct LogLineParserTests {
    @Test func parsesTimingLine() throws {
        let line = "slot print_timing: id  0 | task 8510 | n_decoded =    116, tg =   5.69 t/s, tg_3s =   5.27 t/s"

        guard case .timing(let timing)? = LogLineParser.parse(line) else {
            Issue.record("expected a timing event")
            return
        }
        #expect(timing.slotID == 0)
        #expect(timing.taskID == 8510)
        #expect(timing.tokensDecoded == 116)
        #expect(timing.tokensPerSecond == 5.69)
        #expect(timing.tokensPerSecond3s == 5.27)
    }

    @Test func parsesCheckpointLine() throws {
        let line = "slot create_check: id  0 | task 8985 | created context checkpoint 4 of 32 (pos_min = 28484, pos_max = 28484, n_tokens = 28485, size = 149.626 MiB)"

        guard case .checkpoint(let checkpoint)? = LogLineParser.parse(line) else {
            Issue.record("expected a checkpoint event")
            return
        }
        #expect(checkpoint.index == 4)
        #expect(checkpoint.total == 32)
        #expect(checkpoint.tokens == 28485)
    }

    @Test func parsesAccessLogLine() throws {
        let line = #"[GIN] 2026/08/06 - 12:32:40 | 200 |      651.25µs |       127.0.0.1 | GET      "/api/tags""#

        guard case .request(let request)? = LogLineParser.parse(line) else {
            Issue.record("expected a request event")
            return
        }
        #expect(request.status == 200)
        #expect(request.method == "GET")
        #expect(request.path == "/api/tags")
        #expect(request.clientIP == "127.0.0.1")
        #expect(abs(request.duration - 0.00065125) < 1e-9)
    }

    /// llama.cpp truncates the operation name to a fixed width, so these are the real spellings.
    @Test(arguments: [
        "slot get_availabl: id  0 | task -1 | selected slot by LCP similarity, f_sim_best = 0.976",
        "slot init_sampler: id  0 | task 8985 | init sampler, took 3.49 ms, tokens: text = 28997",
        "slot launch_slot_: id  0 | task 8510 | processing task",
        "time=2026-08-06T12:17:53.000+03:00 level=INFO source=server.go:123 msg=\"starting\"",
        "",
    ])
    func ignoresLinesWithNothingToReport(line: String) {
        #expect(LogLineParser.parse(line) == nil)
    }

    @Test(arguments: [
        ("651.25µs", 0.00065125),
        ("60.333us", 0.000060333),
        ("136ns", 1.36e-7),
        ("1.5ms", 0.0015),
        ("2s", 2.0),
        ("1m30s", 90.0),
    ])
    func parsesGoDurations(input: String, expected: Double) {
        let parsed = LogLineParser.goDuration(input)
        #expect(parsed != nil)
        #expect(abs((parsed ?? 0) - expected) < 1e-9)
    }

    @Test func rejectsGarbageDuration() {
        #expect(LogLineParser.goDuration("fast") == nil)
    }

    @Test func parsesTheRecordedLogSample() throws {
        let events = try Fixtures.lines("server-log-sample.log").compactMap(LogLineParser.parse)

        let timings = events.compactMap { if case .timing(let t) = $0 { t } else { nil } }
        let requests = events.compactMap { if case .request(let r) = $0 { r } else { nil } }

        #expect(!timings.isEmpty)
        #expect(!requests.isEmpty)
        // Nothing in a real sample should produce an absurd rate.
        #expect(timings.allSatisfy { $0.tokensPerSecond3s > 0 && $0.tokensPerSecond3s < 10_000 })
        #expect(requests.allSatisfy { $0.status >= 100 && $0.status < 600 })
    }
}

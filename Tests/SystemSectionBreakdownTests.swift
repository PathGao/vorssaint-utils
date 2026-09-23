// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Runs the System section's production breakdown refresh with a counting
/// process sampler and queues that run their work at once.
enum SystemSectionBreakdownTests {
    enum BreakdownKind { case cpu, gpu }
    enum Queue {
        enum QoS { case utility }
        static let main = Worker()
        static func global(qos: QoS) -> Worker { main }
        struct Worker { func async(execute work: () -> Void) { work() } }
    }
    final class ProcessUsageService {
        static let shared = ProcessUsageService()
        var calls: [BreakdownKind] = []
        func top(_ kind: BreakdownKind, limit: Int, sampleInterval: TimeInterval,
                 cpuPercentage: Double?, gpuPercentage: Double?) -> [String] {
            calls.append(kind)
            return ["app"]
        }
    }
    class Fixture {
        typealias DispatchQueue = Queue
        struct Snapshot { var cpuUsage: Double?; var gpuUsage: Double? }
        struct Monitor { var snapshot = Snapshot() }
        let monitor = Monitor()
        let breakdownLimit = 15
        let percentageSampleInterval: TimeInterval = 2
        var expanded: BreakdownKind?
        var cpuAppsExpanded = true
        var breakdownRows: [String] = []
        var breakdownIsLoading = false
        var lastBreakdownRefresh = Date.distantPast
    }

    static func run(_ suite: TestSuite) {
        defer { ProcessUsageService.shared.calls = [] }
        let section = Section()
        section.expanded = .cpu
        section.refreshBreakdown()
        suite.expect(ProcessUsageService.shared.calls == [.cpu] && section.breakdownRows == ["app"],
                     "an open CPU apps list samples processes")
        section.cpuAppsExpanded = false
        section.refreshBreakdown()
        suite.expect(ProcessUsageService.shared.calls == [.cpu], "a folded CPU apps list skips the process refresh")
        section.expanded = .gpu
        section.refreshBreakdown()
        suite.expect(ProcessUsageService.shared.calls == [.cpu, .gpu],
                     "folding the CPU apps list does not stop other breakdowns")
    }
}

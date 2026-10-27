import Foundation
import Testing
@testable import TimerDeskCore

/// Feeds value changes as the agent would see them: polled every 0.5 s, holding the last value.
private func replay(_ changes: [(TimeInterval, String?)], until end: TimeInterval? = nil,
                    tracker: inout TimerTracker) -> [TimerEvent] {
    var events: [TimerEvent] = []
    var index = 0
    var value: String?? = .none
    let stop = end ?? (changes.last!.0 + 1)
    var time = changes.first!.0
    while time <= stop {
        while index < changes.count && changes[index].0 <= time + 1e-9 {
            value = .some(changes[index].1)
            index += 1
        }
        if case let .some(text) = value {
            events += tracker.observe(Observation(time: time, remaining: text.flatMap(parseCountdown)))
        }
        time += 0.5
    }
    return events
}

private func countdown(from start: Int, at time: TimeInterval) -> [(TimeInterval, String?)] {
    (0...start).map { (time + Double($0), "0:\(String(format: "%02d", start - $0))") }
}

@Test func parsesMenuExtraValues() {
    #expect(parseCountdown("0:09") == 9)
    #expect(parseCountdown("24:59") == 1499)
    #expect(parseCountdown("1:00:00") == 3600)
    #expect(parseCountdown("0:9") == nil)
    #expect(parseCountdown("") == nil)
    #expect(parseCountdown("Timer") == nil)
}

/// probes/out/ax-timer-cases.log, recorded 2026-10-21 from four 10 s Clock timers.
@Test func replaysRecordedCases() throws {
    let log = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("probes/out/ax-timer-cases.log")
    let changes: [(TimeInterval, String?)] = try String(contentsOf: log, encoding: .utf8)
        .split(separator: "\n")
        .compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[1] == "poll", let time = Double(fields[0]) else { return nil }
            return (time, String(fields[2]))
        }
    var tracker = TimerTracker()
    #expect(replay(changes, until: 120, tracker: &tracker) == [
        .started(length: 10), .completed(length: 10),
        .started(length: 10), .stopped(remaining: 4), .resumed(remaining: 4), .completed(length: 10),
        .started(length: 10), .stopped(remaining: 4),
        .started(length: 10), .completed(length: 10),
        .started(length: 10), .completed(length: 10),
    ])
}

@Test func launchMidCountHasUnknownLength() {
    var tracker = TimerTracker()
    #expect(replay(Array(countdown(from: 5, at: 0)), tracker: &tracker) == [
        .started(length: nil), .completed(length: nil),
    ])
}

/// The real miss on 2026-10-27: Control Center restarted 6 minutes into a pomodoro and the
/// menu extra was unreadable for one poll.
@Test func briefReadFailureKeepsTheLength() {
    var tracker = TimerTracker()
    var changes: [(TimeInterval, String?)] = [(0, "0:00")] + countdown(from: 9, at: 1)
    changes[4] = (changes[4].0, nil)
    #expect(replay(changes, tracker: &tracker) == [
        .started(length: 10), .unavailable, .available, .completed(length: 10),
    ])
}

@Test func longReadFailureForgetsTheLength() {
    var tracker = TimerTracker()
    let changes: [(TimeInterval, String?)] = [(0, "0:00")] + countdown(from: 9, at: 1)
        .enumerated().map { $0.offset >= 3 && $0.offset < 6 ? ($0.element.0, nil) : $0.element }
    #expect(replay(changes, tracker: &tracker) == [
        .started(length: 10), .unavailable, .available, .started(length: nil), .completed(length: nil),
    ])
}

@Test func sleepingAcrossExpiryIsNotACompletion() {
    var tracker = TimerTracker()
    _ = tracker.observe(Observation(time: 0, remaining: 0))
    _ = tracker.observe(Observation(time: 0.5, remaining: 9))
    _ = tracker.observe(Observation(time: 8.5, remaining: 1))
    // Asleep for 30 s, wakes to an idle menu extra.
    #expect(tracker.observe(Observation(time: 38.5, remaining: 0)) == [.stopped(remaining: 1)])
}

@Test func reachingZeroFromMidCountIsAStop() {
    var tracker = TimerTracker()
    #expect(replay([(0, "0:00"), (1, "0:09"), (2, "0:08"), (3, "0:00")], tracker: &tracker) == [
        .started(length: 10), .stopped(remaining: 8),
    ])
}

@Test func startAfterCancelIsANewSession() {
    var tracker = TimerTracker()
    let changes: [(TimeInterval, String?)] = [(0, "0:00"), (1, "24:59"), (2, "24:58"), (3, "0:00"), (10, "0:09")]
    #expect(replay(changes, tracker: &tracker) == [
        .started(length: 1500), .stopped(remaining: 1498), .started(length: 10),
    ])
}

@Test func valueJumpingUpIsANewSession() {
    var tracker = TimerTracker()
    #expect(replay([(0, "0:00"), (1, "0:09"), (2, "0:08"), (2.5, "24:59")], tracker: &tracker) == [
        .started(length: 10), .started(length: 1500),
    ])
}

@Test func policyRaisesOnlyForMatchingUnlockedTimers() {
    let policy = TriggerPolicy(lengths: [1500], tolerance: 3)
    #expect(policy.decide(completedLength: 1500, screenLocked: false) == .raise)
    #expect(policy.decide(completedLength: 1502, screenLocked: false) == .raise)
    #expect(policy.decide(completedLength: 1510, screenLocked: false) == .ignore(reason: "length-mismatch"))
    #expect(policy.decide(completedLength: nil, screenLocked: false) == .ignore(reason: "length-unknown"))
    #expect(policy.decide(completedLength: 1500, screenLocked: true) == .ignore(reason: "screen-locked"))
}

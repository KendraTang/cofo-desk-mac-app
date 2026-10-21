import Foundation

/// Parses the timer menu extra's value ("0:09", "24:59", "1:00:00") into seconds.
public func parseCountdown(_ text: String) -> Int? {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count) else { return nil }
    var seconds = 0
    for (index, part) in parts.enumerated() {
        guard let value = Int(part), value >= 0, index == 0 || (part.count == 2 && value < 60) else { return nil }
        seconds = seconds * 60 + value
    }
    return seconds
}

/// One poll of the timer menu extra. `remaining` is nil when it could not be read.
public struct Observation: Sendable {
    public let time: TimeInterval
    public let remaining: Int?

    public init(time: TimeInterval, remaining: Int?) {
        self.time = time
        self.remaining = remaining
    }
}

public enum TimerEvent: Equatable, Sendable {
    /// `length` is nil when the start was not observed (agent launch mid-count, read gap, wake).
    case started(length: Int?)
    /// Jumped to 0:00 mid-count: paused or cancelled; the two look the same until a resume.
    case stopped(remaining: Int)
    case resumed(remaining: Int)
    /// Counted down to 0:00 with no gap in observation.
    case completed(length: Int?)
    case unavailable
    case available
}

/// Turns menu extra readings into timer events.
///
/// Idle, paused, cancelled and finished timers all read "0:00", so the state comes from the
/// sequence: a natural finish is 0:01 -> 0:00 with no gap; anything else reaching 0:00 is a stop.
/// The menu extra has no total length, so a session's length is estimated from the first value
/// seen after 0:00 (a 10 s timer first shows 0:09).
public struct TimerTracker {
    struct Session {
        let length: Int?
    }

    enum State {
        case unknown
        case idle
        case running(Session, last: Int)
        case stopped(Session, at: Int)
    }

    /// Longer than this between polls means the sequence may have skipped values (sleep, stall).
    public let maxGap: TimeInterval
    private var state = State.unknown
    private var lastTime: TimeInterval?
    private var reported = true

    public init(maxGap: TimeInterval = 2.5) {
        self.maxGap = maxGap
    }

    public mutating func observe(_ observation: Observation) -> [TimerEvent] {
        let gap = lastTime.map { observation.time - $0 } ?? .infinity
        lastTime = observation.time

        guard let remaining = observation.remaining else {
            state = .unknown
            defer { reported = false }
            return reported ? [.unavailable] : []
        }
        var events: [TimerEvent] = []
        if !reported {
            reported = true
            events.append(.available)
        }
        let continuous = gap <= maxGap

        switch state {
        case .unknown:
            if remaining == 0 {
                state = .idle
            } else {
                events.append(start(remaining, observedStart: false))
            }
        case .idle:
            if remaining > 0 { events.append(start(remaining, observedStart: continuous)) }
        case let .running(session, last):
            if remaining == 0 {
                if last <= 1 && continuous {
                    state = .idle
                    events.append(.completed(length: session.length))
                } else {
                    state = .stopped(session, at: last)
                    events.append(.stopped(remaining: last))
                }
            } else if remaining > last + 1 {
                events.append(start(remaining, observedStart: continuous))
            } else {
                state = .running(session, last: remaining)
            }
        case let .stopped(session, at):
            if remaining > 0 {
                if abs(remaining - at) <= 1 {
                    state = .running(session, last: remaining)
                    events.append(.resumed(remaining: remaining))
                } else {
                    events.append(start(remaining, observedStart: continuous))
                }
            }
        }
        return events
    }

    private mutating func start(_ remaining: Int, observedStart: Bool) -> TimerEvent {
        let length = observedStart ? remaining + 1 : nil
        state = .running(Session(length: length), last: remaining)
        return .started(length: length)
    }
}

/// Decides whether a completed timer should move the desk.
public struct TriggerPolicy: Sendable {
    public let lengths: [Int]
    public let tolerance: Int

    public init(lengths: [Int], tolerance: Int = 3) {
        self.lengths = lengths
        self.tolerance = tolerance
    }

    public enum Decision: Equatable, Sendable {
        case raise
        case ignore(reason: String)
    }

    public func matches(_ length: Int?) -> Bool {
        guard let length else { return false }
        return lengths.contains { abs($0 - length) <= tolerance }
    }

    public func decide(completedLength: Int?, screenLocked: Bool) -> Decision {
        guard completedLength != nil else { return .ignore(reason: "length-unknown") }
        guard matches(completedLength) else { return .ignore(reason: "length-mismatch") }
        if screenLocked { return .ignore(reason: "screen-locked") }
        return .raise
    }
}

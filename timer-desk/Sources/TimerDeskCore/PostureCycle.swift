import Foundation

public struct CycleSettings: Sendable {
    /// How long to sit before raising.
    public var sitSeconds = 1500.0
    /// How long to stand before lowering.
    public var standSeconds = 600.0
    /// Next try after a cancelled or failed move.
    public var snoozeSeconds = 600.0
    /// No input for this long pauses the countdown.
    public var idlePauseSeconds = 300.0
    /// This much time away during one countdown restarts it on return.
    public var awayResetSeconds = 900.0
    /// A due move waits unless there was input this recently, so the desk does not move with nobody there.
    public var movePresenceSeconds = 60.0
    /// A playing video stands in for input for at most this long.
    public var videoLimitSeconds = 1800.0
    public var pauseSeconds = 3600.0
    /// A longer gap between ticks means the Mac was asleep.
    public var maxTickGapSeconds = 5.0

    public init() {}
}

public enum Posture: Equatable, Sendable {
    case sitting, standing
}

public struct Presence: Equatable, Sendable {
    public let inputIdleSeconds: Double
    public let videoPlaying: Bool
    public let locked: Bool

    public init(inputIdleSeconds: Double, videoPlaying: Bool, locked: Bool) {
        self.inputIdleSeconds = inputIdleSeconds
        self.videoPlaying = videoPlaying
        self.locked = locked
    }
}

public enum MoveOutcome: Equatable, Sendable {
    case moved(heightMm: Int)
    /// Already at the target height.
    case skipped
    case cancelled
    case failed
    case aborted
}

public enum CycleOutput: Equatable, Sendable {
    case raise
    case lower
    case note(String)
}

public enum CycleDisplay: Equatable, Sendable {
    case disconnected
    /// The desk reported no stand or sit memory height.
    case notConfigured
    case paused(remaining: Double)
    case counting(Posture, remaining: Double)
    case away(Posture, remaining: Double)
    case waitingForUser(Posture)
    case moving(Posture)
}

/// The sit and stand countdowns: which one runs comes from the desk height, and it only runs while
/// the user is present. A due move is requested through `.raise` or `.lower`, and the next
/// countdown starts when `moveFinished` reports the result.
public struct PostureCycle {
    public let settings: CycleSettings
    private var connected = false
    private var standMm: Int?
    private var sitMm: Int?
    private var heightMm: Int?
    private var posture: Posture?
    private var remaining = 0.0
    private var moving = false
    private var pausedUntil: TimeInterval?
    private var lastTick: TimeInterval?
    private var lastActive: TimeInterval = -.infinity
    private var isAway = false
    private var awaySeconds = 0.0

    public init(settings: CycleSettings) {
        self.settings = settings
    }

    public mutating func deskConnected(heightMm: Int, standMm: Int?, sitMm: Int?) -> [CycleOutput] {
        connected = true
        self.heightMm = heightMm
        self.standMm = standMm
        self.sitMm = sitMm
        return settle()
    }

    public mutating func deskDisconnected() {
        connected = false
    }

    public mutating func heightChanged(mm: Int) -> [CycleOutput] {
        heightMm = mm
        return moving ? [] : settle()
    }

    public mutating func tick(now: TimeInterval, presence: Presence) -> [CycleOutput] {
        let elapsed = lastTick.map { now - $0 } ?? 0
        lastTick = now
        if let until = pausedUntil {
            guard now >= until else { return [] }
            pausedUntil = nil
            return (posture.map { startCountdown($0) } ?? []) + [.note("pause-ended")]
        }
        guard !moving else { return [] }

        let asleep = elapsed > settings.maxTickGapSeconds
        lastActive = max(lastActive, now - presence.inputIdleSeconds)
        if presence.videoPlaying && presence.inputIdleSeconds <= settings.videoLimitSeconds { lastActive = now }
        let idle = now - lastActive

        if presence.locked || asleep || idle > settings.idlePauseSeconds {
            var outputs: [CycleOutput] = []
            if !isAway {
                isAway = true
                outputs.append(.note("away"))
                if !presence.locked && !asleep { awaySeconds += idle }
            }
            awaySeconds += elapsed
            return outputs
        }
        // Time away counts even while disconnected: the link often drops overnight.
        guard connected, let posture else { return [] }
        var outputs: [CycleOutput] = []
        if isAway {
            isAway = false
            if awaySeconds >= settings.awayResetSeconds {
                return startCountdown(posture) + [.note("back-after-long-away")]
            }
            outputs.append(.note("back"))
        }
        remaining = max(0, remaining - elapsed)
        if remaining == 0 && idle <= settings.movePresenceSeconds {
            moving = true
            outputs.append(posture == .sitting ? .raise : .lower)
        }
        return outputs
    }

    public mutating func moveFinished(_ outcome: MoveOutcome) -> [CycleOutput] {
        moving = false
        if case let .moved(height) = outcome { heightMm = height }
        let before = posture
        let outputs = settle()
        guard posture == before, let posture else { return outputs }
        switch outcome {
        case .moved, .skipped:
            return outputs + startCountdown(posture)
        case .cancelled, .failed, .aborted:
            remaining = settings.snoozeSeconds
            return outputs + [.note("snoozed")]
        }
    }

    /// A Clock timer ran out: the sit countdown is over now.
    public mutating func clockCompleted() -> [CycleOutput] {
        guard connected, pausedUntil == nil, !moving, posture == .sitting else { return [.note("clock-ignored")] }
        remaining = 0
        return [.note("clock-completed-sit-countdown")]
    }

    /// Makes the running countdown due now (for testing).
    public mutating func expire() {
        remaining = 0
    }

    public mutating func restart() -> [CycleOutput] {
        guard !moving, let posture else { return [] }
        pausedUntil = nil
        return startCountdown(posture)
    }

    public mutating func pause(now: TimeInterval) -> [CycleOutput] {
        pausedUntil = now + settings.pauseSeconds
        return [.note("paused")]
    }

    public var isPaused: Bool { pausedUntil != nil }

    public func display(now: TimeInterval) -> CycleDisplay {
        guard connected else { return .disconnected }
        guard let posture else { return .notConfigured }
        if let until = pausedUntil { return .paused(remaining: max(0, until - now)) }
        if moving { return .moving(posture) }
        if isAway { return .away(posture, remaining: remaining) }
        return remaining == 0 ? .waitingForUser(posture) : .counting(posture, remaining: remaining)
    }

    /// Works out the posture from the height; a change of posture starts its countdown.
    private mutating func settle() -> [CycleOutput] {
        guard let standMm, let sitMm, let heightMm, standMm != sitMm else {
            posture = nil
            return []
        }
        let new: Posture = heightMm * 2 > standMm + sitMm ? .standing : .sitting
        guard new != posture else { return [] }
        posture = new
        return startCountdown(new)
    }

    private mutating func startCountdown(_ posture: Posture) -> [CycleOutput] {
        remaining = posture == .sitting ? settings.sitSeconds : settings.standSeconds
        awaySeconds = 0
        isAway = false
        return [.note(posture == .sitting ? "sit-countdown-started" : "stand-countdown-started")]
    }
}

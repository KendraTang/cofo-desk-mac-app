import Foundation

public struct DeskSettings: Sendable {
    public var standMm: Int?
    public var sitMm: Int?
    /// Warning jog before a move, in mm; 0 skips it.
    public var nudgeMm = 10
    /// How long a panel key press can cancel the move after the warning jog; 0 skips the wait.
    public var windowSeconds = 3.0
    /// Within this of the target height counts as already there.
    public var atHeightMm = 10
    /// A height change this large during the window counts as a panel key press.
    public var cancelMm = 5

    public init() {}
}

public struct DeskStatus: Equatable, Sendable {
    public let heightMm: Int
    public let limitsMm: ClosedRange<Int>?
    /// The panel's own memory heights by slot name ("M1"), only shown for comparison.
    public let memoryMm: [String: Int]

    public init(heightMm: Int, limitsMm: ClosedRange<Int>? = nil, memoryMm: [String: Int] = [:]) {
        self.heightMm = heightMm
        self.limitsMm = limitsMm
        self.memoryMm = memoryMm
    }
}

public enum DeskCommand: Equatable, Sendable {
    case status
    case goto(mm: Int)
    case watch(seconds: Double)
}

public enum CoordinatorInput: Equatable, Sendable {
    case raiseRequested
    case lowerRequested
    /// Straight to the height, without the warning: the user just asked for it.
    case manualRequested(targetMm: Int)
    case stopRequested
    case screenLocked
    case status(DeskStatus)
    case gotoFinished(heightMm: Int)
    case watchSample(heightMm: Int)
    case watchFinished
    case commandFailed(String)
}

public enum CoordinatorOutput: Equatable, Sendable {
    case run(DeskCommand)
    /// Stop the running cofo-desk; an interrupted move sends STOP.
    case cancelCommand
    case note(String)
    case notifyFailure(String)
    case finished(MoveOutcome)
    /// A manual move ended; nil when it did not report a final height.
    case manualFinished(heightMm: Int?)
}

/// The raise and lower flows: status, warning jog, cancel window, move.
///
/// A move is skipped when the desk is already at the target height. A locked screen aborts whatever
/// is running. Inputs that do not fit the current phase (such as results of a cancelled command)
/// are ignored. Every requested raise or lower ends in one `.finished`, every manual move in one
/// `.manualFinished`.
public struct DeskCoordinator {
    public enum Purpose: Equatable, Sendable {
        case raise
        case lower

        var name: String {
            self == .raise ? "raise" : "lower"
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case checking(Purpose)
        case warning(Purpose, targetMm: Int)
        /// `baselineMm` is where the warning jog stopped; `sampled` is whether the watch reported yet.
        case window(Purpose, targetMm: Int, baselineMm: Int, sampled: Bool)
        case moving(Purpose, targetMm: Int)
        case manual(targetMm: Int)
    }

    public var settings: DeskSettings
    public private(set) var phase = Phase.idle

    public init(settings: DeskSettings) {
        self.settings = settings
    }

    public mutating func handle(_ input: CoordinatorInput) -> [CoordinatorOutput] {
        switch (input, phase) {
        case (.screenLocked, .idle):
            return []
        case (.screenLocked, .manual), (.stopRequested, .manual):
            phase = .idle
            return [.cancelCommand, .note("manual-move-stopped"), .manualFinished(heightMm: nil)]
        case (.stopRequested, .idle):
            return []
        case (.stopRequested, _):
            phase = .idle
            return [.cancelCommand, .note("move-stopped"), .finished(.cancelled)]
        case (.screenLocked, _):
            phase = .idle
            return [.cancelCommand, .note("aborted-screen-locked"), .finished(.aborted)]

        case (.raiseRequested, .idle):
            phase = .checking(.raise)
            return [.run(.status)]
        case (.lowerRequested, .idle):
            phase = .checking(.lower)
            return [.run(.status)]
        case let (.manualRequested(target), .idle):
            phase = .manual(targetMm: target)
            return [.run(.goto(mm: target))]
        case (.raiseRequested, _), (.lowerRequested, _), (.manualRequested, _):
            return [.note("move-skipped-busy")]

        case let (.status(status), .checking(purpose)):
            return check(status, for: purpose)

        case let (.gotoFinished(height), .warning(purpose, target)):
            return waitForCancel(purpose, targetMm: target, heightMm: height)

        case let (.watchSample(height), .window(purpose, target, baseline, _)):
            guard abs(height - baseline) > settings.cancelMm else {
                phase = .window(purpose, targetMm: target, baselineMm: baseline, sampled: true)
                return []
            }
            phase = .idle
            return [.cancelCommand, .note("\(purpose.name)-cancelled-by-panel"), .finished(.cancelled)]

        case let (.watchFinished, .window(purpose, target, _, sampled)):
            guard sampled else { return fail(purpose, "no height during the cancel window") }
            phase = .moving(purpose, targetMm: target)
            return [.run(.goto(mm: target))]

        case let (.gotoFinished(height), .moving(purpose, _)):
            phase = .idle
            return [.note(purpose == .raise ? "raised" : "lowered"), .finished(.moved(heightMm: height))]

        case let (.gotoFinished(height), .manual):
            phase = .idle
            return [.note("manual-move-done"), .manualFinished(heightMm: height)]

        case let (.commandFailed(message), .manual):
            phase = .idle
            return [.note("manual-move-failed"), .notifyFailure("移動失敗：沒有到達目標高度，可能按了面板鍵（\(message)）"),
                    .manualFinished(heightMm: nil)]

        case let (.commandFailed(message), .moving(purpose, _)):
            // On the real desk this is usually a panel press: the desk stops short, keeps reporting
            // its height for about 10 s, then goes quiet and cofo-desk reports stale telemetry.
            return fail(purpose, "沒有到達目標高度，可能按了面板鍵（\(message)）")
        case let (.commandFailed(message), phase) where phase != .idle:
            return fail(purpose(of: phase), message)

        default:
            return []
        }
    }

    private mutating func check(_ status: DeskStatus, for purpose: Purpose) -> [CoordinatorOutput] {
        let height = status.heightMm
        switch purpose {
        case .raise:
            guard let stand = settings.standMm else { return fail(purpose, "沒有設定高度") }
            if height >= stand - settings.atHeightMm {
                phase = .idle
                return [.note("raise-skipped-already-standing"), .finished(.skipped)]
            }
            return warn(purpose, targetMm: stand, heightMm: height, jogTo: height + settings.nudgeMm)
        case .lower:
            guard let sit = settings.sitMm else { return fail(purpose, "沒有設定高度") }
            if height <= sit + settings.atHeightMm {
                phase = .idle
                return [.note("lower-skipped-already-sitting"), .finished(.skipped)]
            }
            return warn(purpose, targetMm: sit, heightMm: height, jogTo: height - settings.nudgeMm)
        }
    }

    private mutating func warn(_ purpose: Purpose, targetMm: Int, heightMm: Int, jogTo: Int) -> [CoordinatorOutput] {
        guard settings.nudgeMm > 0 else { return waitForCancel(purpose, targetMm: targetMm, heightMm: heightMm) }
        phase = .warning(purpose, targetMm: targetMm)
        return [.run(.goto(mm: jogTo))]
    }

    private mutating func waitForCancel(_ purpose: Purpose, targetMm: Int, heightMm: Int) -> [CoordinatorOutput] {
        guard settings.windowSeconds > 0 else {
            phase = .moving(purpose, targetMm: targetMm)
            return [.run(.goto(mm: targetMm))]
        }
        phase = .window(purpose, targetMm: targetMm, baselineMm: heightMm, sampled: false)
        return [.run(.watch(seconds: settings.windowSeconds))]
    }

    private mutating func fail(_ purpose: Purpose, _ message: String) -> [CoordinatorOutput] {
        phase = .idle
        return [.note("\(purpose.name)-failed"), .notifyFailure("\(purpose == .raise ? "升桌" : "降桌")失敗：\(message)"), .finished(.failed)]
    }

    private func purpose(of phase: Phase) -> Purpose {
        switch phase {
        case let .checking(purpose), let .warning(purpose, _), let .window(purpose, _, _, _), let .moving(purpose, _):
            return purpose
        case .idle, .manual:
            return .raise
        }
    }
}

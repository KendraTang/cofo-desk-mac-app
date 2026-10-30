import Foundation

public struct DeskSettings: Sendable {
    public var standSlot = "M1"
    public var sitSlot = "M2"
    /// Warning jog before a move, in mm.
    public var nudgeMm = 10
    /// How long a panel key press can cancel the move after the warning jog.
    public var windowSeconds = 3.0
    /// Within this of the target height counts as already there.
    public var atHeightMm = 10
    /// A height change this large during the window counts as a panel key press.
    public var cancelMm = 5

    public init() {}
}

public struct DeskStatus: Equatable, Sendable {
    public let heightMm: Int
    /// Panel memory heights by slot name ("M1"); missing or empty slots are absent.
    public let memoryMm: [String: Int]

    public init(heightMm: Int, memoryMm: [String: Int]) {
        self.heightMm = heightMm
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
}

/// The raise and lower flows: status, warning jog, cancel window, move.
///
/// A move is skipped when the desk is already at the target height. A locked screen aborts whatever
/// is running. Inputs that do not fit the current phase (such as results of a cancelled command)
/// are ignored. Every requested move ends in one `.finished`.
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
    }

    public let settings: DeskSettings
    public private(set) var phase = Phase.idle

    public init(settings: DeskSettings) {
        self.settings = settings
    }

    public mutating func handle(_ input: CoordinatorInput) -> [CoordinatorOutput] {
        switch (input, phase) {
        case (.screenLocked, .idle):
            return []
        case (.screenLocked, _):
            phase = .idle
            return [.cancelCommand, .note("aborted-screen-locked"), .finished(.aborted)]

        case (.raiseRequested, .idle):
            phase = .checking(.raise)
            return [.run(.status)]
        case (.lowerRequested, .idle):
            phase = .checking(.lower)
            return [.run(.status)]
        case (.raiseRequested, _), (.lowerRequested, _):
            return [.note("move-skipped-busy")]

        case let (.status(status), .checking(purpose)):
            return check(status, for: purpose)

        case let (.gotoFinished(height), .warning(purpose, target)):
            phase = .window(purpose, targetMm: target, baselineMm: height, sampled: false)
            return [.run(.watch(seconds: settings.windowSeconds))]

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

        case let (.commandFailed(message), .moving(purpose, _)):
            // On the real desk this is usually a panel press: the desk stops short, keeps reporting
            // its height for about 10 s, then goes quiet and cofo-desk reports stale telemetry.
            let slot = purpose == .raise ? settings.standSlot : settings.sitSlot
            return fail(purpose, "沒有到達 \(slot)，可能按了面板鍵（\(message)）")
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
            guard let stand = status.memoryMm[settings.standSlot] else {
                return fail(purpose, "\(settings.standSlot) memory height is not set")
            }
            if height >= stand - settings.atHeightMm {
                phase = .idle
                return [.note("raise-skipped-already-standing"), .finished(.skipped)]
            }
            phase = .warning(purpose, targetMm: stand)
            return [.run(.goto(mm: height + settings.nudgeMm))]
        case .lower:
            guard let sit = status.memoryMm[settings.sitSlot] else {
                return fail(purpose, "\(settings.sitSlot) memory height is not set")
            }
            if height <= sit + settings.atHeightMm {
                phase = .idle
                return [.note("lower-skipped-already-sitting"), .finished(.skipped)]
            }
            phase = .warning(purpose, targetMm: sit)
            return [.run(.goto(mm: height - settings.nudgeMm))]
        }
    }

    private mutating func fail(_ purpose: Purpose, _ message: String) -> [CoordinatorOutput] {
        phase = .idle
        return [.note("\(purpose.name)-failed"), .notifyFailure("\(purpose == .raise ? "升桌" : "降桌")失敗：\(message)"), .finished(.failed)]
    }

    private func purpose(of phase: Phase) -> Purpose {
        switch phase {
        case let .checking(purpose), let .warning(purpose, _), let .window(purpose, _, _, _), let .moving(purpose, _):
            return purpose
        case .idle:
            return .raise
        }
    }
}

import Foundation

public struct DeskSettings: Sendable {
    public var standSlot = "M1"
    public var sitSlot = "M2"
    /// Warning jog before a move, in mm.
    public var nudgeMm = 10
    /// How long a panel key press can cancel the move after the warning jog.
    public var windowSeconds = 3.0
    /// When an automatic raise is followed by an automatic lower.
    public var lowerAfterSeconds = 600.0
    /// Within this of the stand height counts as already standing.
    public var atHeightMm = 10
    /// Further than this from the raised height counts as adjusted by hand. goto lands within
    /// 1 mm on the real desk; a brief panel tap moved it 7 mm (2026-10-21).
    public var adjustedMm = 3
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
    /// Moves a scheduled lower to now (for testing).
    case lowerNow
    case tick
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
}

/// The raise and lower flows: status, warning jog, cancel window, move.
///
/// A raise only runs when the desk is below the stand height. After an automatic raise, a lower
/// is scheduled; it only runs if the desk is still at the raised height. A locked screen aborts
/// whatever is running and drops the scheduled lower. Inputs that do not fit the current phase
/// (such as results of a cancelled command) are ignored.
public struct DeskCoordinator {
    public enum Purpose: Equatable, Sendable {
        case raise
        case lower(raisedMm: Int)

        var name: String {
            if case .raise = self { return "raise" }
            return "lower"
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
    public private(set) var lowerDue: (raisedMm: Int, at: TimeInterval)?

    public init(settings: DeskSettings) {
        self.settings = settings
    }

    public mutating func handle(_ input: CoordinatorInput, now: TimeInterval) -> [CoordinatorOutput] {
        switch (input, phase) {
        case (.screenLocked, _):
            var outputs: [CoordinatorOutput] = []
            if lowerDue != nil {
                lowerDue = nil
                outputs.append(.note("lower-dropped-screen-locked"))
            }
            if phase != .idle {
                phase = .idle
                outputs += [.cancelCommand, .note("aborted-screen-locked")]
            }
            return outputs

        case (.raiseRequested, .idle):
            phase = .checking(.raise)
            return [.run(.status)]
        case (.raiseRequested, _):
            return [.note("raise-skipped-busy")]

        case (.lowerNow, _):
            guard let due = lowerDue else { return [.note("lower-now-ignored-none-scheduled")] }
            lowerDue = (due.raisedMm, now)
            return []

        case (.tick, .idle):
            guard let due = lowerDue, now >= due.at else { return [] }
            lowerDue = nil
            phase = .checking(.lower(raisedMm: due.raisedMm))
            return [.run(.status)]

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
            return [.cancelCommand, .note("\(purpose.name)-cancelled-by-panel")]

        case let (.watchFinished, .window(purpose, target, _, sampled)):
            guard sampled else { return fail(purpose, "no height during the cancel window") }
            phase = .moving(purpose, targetMm: target)
            return [.run(.goto(mm: target))]

        case let (.gotoFinished(height), .moving(purpose, _)):
            phase = .idle
            if case .raise = purpose {
                lowerDue = (height, now + settings.lowerAfterSeconds)
                return [.note("raised")]
            }
            return [.note("lowered")]

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
                return [.note("raise-skipped-already-standing")]
            }
            phase = .warning(purpose, targetMm: stand)
            return [.run(.goto(mm: height + settings.nudgeMm))]
        case let .lower(raised):
            guard let sit = status.memoryMm[settings.sitSlot] else {
                return fail(purpose, "\(settings.sitSlot) memory height is not set")
            }
            if abs(height - raised) > settings.adjustedMm {
                phase = .idle
                return [.note("lower-skipped-adjusted-by-hand")]
            }
            phase = .warning(purpose, targetMm: sit)
            return [.run(.goto(mm: height - settings.nudgeMm))]
        }
    }

    private mutating func fail(_ purpose: Purpose, _ message: String) -> [CoordinatorOutput] {
        phase = .idle
        return [.note("\(purpose.name)-failed"), .notifyFailure("\(purpose.name == "raise" ? "升桌" : "降桌")失敗：\(message)")]
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

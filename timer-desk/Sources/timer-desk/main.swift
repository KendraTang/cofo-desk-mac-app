// Polls Control Center's timer menu extra and, when a matching Clock timer finishes, raises the
// desk through cofo-desk (warning jog, cancel window, move to the stand slot), then lowers it later.
// Without --device or --simulate-state it only logs what it would do. Logs are JSON lines on stdout.
import AppKit
import ApplicationServices
import TimerDeskCore

struct Options {
    var lengths: [Int] = []
    var tolerance = 3
    var interval = 0.5
    var cofoDesk: String?
    var target: [String]?
    var desk = DeskSettings()

    static let usage = """
        usage: timer-desk [--length SECONDS]... [--tolerance SECONDS] [--interval SECONDS]
                          [--cofo-desk PATH (--device UUID | --simulate-state FILE)]
                          [--stand SLOT] [--sit SLOT] [--nudge MM] [--window SECONDS]
                          [--lower-after SECONDS]
          --length          timer length that raises the desk; repeatable (default 1500)
          --tolerance       allowed difference from a --length (default 3)
          --interval        poll interval (default 0.5, 0.2-2)
          --cofo-desk       cofo-desk executable; with --device or --simulate-state the desk moves
          --stand, --sit    panel memory slots (default M1, M2)
          --nudge           warning jog in mm (default 20, 5-50)
          --window          cancel window after the jog (default 10, 3-60)
          --lower-after     lower an automatic raise after this long (default 900, 10-7200)
        With a desk, the agent stays connected through `cofo-desk session` and checks the
        connection when a matching timer has 15 s left. For testing, SIGUSR1 requests a raise
        and SIGUSR2 moves a scheduled lower to now.
        """

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var rest = arguments[...]
        func number(_ text: String, _ range: ClosedRange<Double>) -> Double? {
            Double(text).flatMap { range.contains($0) ? $0 : nil }
        }
        while let flag = rest.popFirst() {
            guard flag != "--help", let text = rest.popFirst() else { return nil }
            switch flag {
            case "--length":
                guard let value = Int(text), value > 0 else { return nil }
                options.lengths.append(value)
            case "--tolerance":
                guard let value = Int(text), value >= 0 else { return nil }
                options.tolerance = value
            case "--interval":
                guard let value = number(text, 0.2...2) else { return nil }
                options.interval = value
            case "--cofo-desk":
                options.cofoDesk = text
            case "--device":
                guard options.target == nil else { return nil }
                options.target = ["--device", text]
            case "--simulate-state":
                guard options.target == nil else { return nil }
                options.target = ["--simulate", "--state-file", text]
            case "--stand", "--sit":
                guard text.range(of: "^M[1-4]$", options: .regularExpression) != nil else { return nil }
                if flag == "--stand" { options.desk.standSlot = text } else { options.desk.sitSlot = text }
            case "--nudge":
                guard let value = Int(text), (5...50).contains(value) else { return nil }
                options.desk.nudgeMm = value
            case "--window":
                guard let value = number(text, 3...60) else { return nil }
                options.desk.windowSeconds = value
            case "--lower-after":
                guard let value = number(text, 10...7200) else { return nil }
                options.desk.lowerAfterSeconds = value
            default:
                return nil
            }
        }
        if options.lengths.isEmpty { options.lengths = [1500] }
        guard (options.cofoDesk == nil) == (options.target == nil), options.desk.standSlot != options.desk.sitSlot
        else { return nil }
        return options
    }
}

// ISO8601DateFormatter is thread-safe.
nonisolated(unsafe) let timestamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    return formatter
}()

func emit(_ fields: [String: Any]) {
    var record = fields
    record["time"] = timestamp.string(from: Date())
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Reads the timer menu extra, re-finding it when Control Center restarts or the element goes stale.
@MainActor
final class MenuExtraReader {
    private var pid: pid_t?
    private var element: AXUIElement?

    enum Failure: String, Error {
        case notTrusted = "accessibility-not-granted"
        case noControlCenter = "control-center-not-running"
        case notFound = "timer-menu-extra-not-found"
        case unreadable = "timer-menu-extra-unreadable"
    }

    func read() -> Result<String, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return .failure(.noControlCenter) }
        if app.processIdentifier != pid {
            pid = app.processIdentifier
            element = nil
        }
        for _ in 0..<2 {
            if element == nil {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 1)
                element = Self.find(in: root, depth: 0)
            }
            guard let element else { return .failure(.notFound) }
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String {
                return .success(text)
            }
            self.element = nil
        }
        return .failure(.unreadable)
    }

    private static func find(in element: AXUIElement, depth: Int) -> AXUIElement? {
        var identifier: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
        if identifier as? String == "com.apple.menuextra.timer" { return element }
        guard depth < 4 else { return nil }
        var children: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] {
            if let found = find(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}

func screenIsLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

@MainActor
final class Agent {
    private let policy: TriggerPolicy
    private let reader = MenuExtraReader()
    private var tracker = TimerTracker()
    private var lastFailure: MenuExtraReader.Failure?
    private var locked = screenIsLocked()
    /// Nil in log-only mode.
    private var coordinator: DeskCoordinator?
    private var session: DeskSession?
    /// Length of the timer now counting down, from its start event.
    private var countingLength: Int?
    /// Seconds left at which the desk connection is checked before a matching timer ends.
    private static let connectionCheckSeconds = 15

    init(options: Options) {
        policy = TriggerPolicy(lengths: options.lengths, tolerance: options.tolerance)
        if let executable = options.cofoDesk, let target = options.target {
            coordinator = DeskCoordinator(settings: options.desk)
            session = DeskSession(executable: executable, target: target) { [unowned self] input in self.apply(input) }
        }
    }

    func apply(_ input: CoordinatorInput) {
        guard var coordinator else { return }
        let outputs = coordinator.handle(input, now: ProcessInfo.processInfo.systemUptime)
        self.coordinator = coordinator
        for output in outputs {
            switch output {
            case let .run(command): session?.run(command)
            case .cancelCommand: session?.cancel()
            case let .note(name): emit(["event": name])
            case let .notifyFailure(message):
                emit(["event": "failure-notified", "message": message])
                notifyFailure(message)
            }
        }
    }

    func tick() {
        let nowLocked = screenIsLocked()
        if nowLocked != locked {
            locked = nowLocked
            emit(["event": nowLocked ? "screen-locked" : "screen-unlocked"])
            if nowLocked { apply(.screenLocked) }
        }
        session?.tick(now: ProcessInfo.processInfo.systemUptime)
        apply(.tick)

        var remaining: Int?
        switch reader.read() {
        case let .success(text):
            remaining = parseCountdown(text)
            if remaining == nil { report(.unreadable, detail: text) } else { lastFailure = nil }
        case let .failure(failure):
            report(failure, detail: nil)
        }

        let observation = Observation(time: ProcessInfo.processInfo.systemUptime, remaining: remaining)
        for event in tracker.observe(observation) { log(event) }
        if remaining == Self.connectionCheckSeconds, !locked, policy.matches(countingLength) {
            session?.ensureConnected()
        }
    }

    private func report(_ failure: MenuExtraReader.Failure, detail: String?) {
        guard failure != lastFailure else { return }
        lastFailure = failure
        var fields: [String: Any] = ["event": "read-failed", "reason": failure.rawValue]
        if let detail { fields["value"] = detail }
        emit(fields)
    }

    private func log(_ event: TimerEvent) {
        switch event {
        case let .started(length):
            countingLength = length
            emit(["event": "started", "length": length ?? NSNull()])
        case let .stopped(remaining):
            emit(["event": "stopped", "remaining": remaining])
        case let .resumed(remaining):
            emit(["event": "resumed", "remaining": remaining])
        case let .completed(length):
            var fields: [String: Any] = ["event": "completed", "length": length ?? NSNull()]
            switch policy.decide(completedLength: length, screenLocked: locked) {
            case .raise:
                fields["decision"] = coordinator == nil ? "would-raise" : "raise"
                emit(fields)
                apply(.raiseRequested)
                return
            case let .ignore(reason):
                fields["decision"] = "ignore"
                fields["reason"] = reason
            }
            emit(fields)
        case .unavailable:
            emit(["event": "unavailable"])
        case .available:
            emit(["event": "available"])
        }
    }
}

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data((Options.usage + "\n").utf8))
    exit(2)
}

// The value of kAXTrustedCheckOptionPrompt, which Swift 6 rejects as shared mutable state.
let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
emit([
    "event": "agent-started", "pid": Int(getpid()), "lengths": options.lengths,
    "tolerance": options.tolerance, "interval": options.interval,
    "desk": options.target.map { $0.joined(separator: " ") } ?? "log-only",
    "accessibility": AXIsProcessTrustedWithOptions(prompt), "screen_locked": screenIsLocked(),
])

let agent = Agent(options: options)
let workspace = NSWorkspace.shared.notificationCenter
for (name, event) in [(NSWorkspace.willSleepNotification, "will-sleep"), (NSWorkspace.didWakeNotification, "did-wake")] {
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in emit(["event": event]) }
}
signal(SIGPIPE, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for (number, input, name) in [(SIGUSR1, CoordinatorInput.raiseRequested, "signal-raise"),
                              (SIGUSR2, CoordinatorInput.lowerNow, "signal-lower-now")] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            emit(["event": name])
            agent.apply(input)
        }
    }
    source.resume()
    signalSources.append(source)
}
Timer.scheduledTimer(withTimeInterval: options.interval, repeats: true) { _ in
    MainActor.assumeIsolated { agent.tick() }
}
RunLoop.main.run()

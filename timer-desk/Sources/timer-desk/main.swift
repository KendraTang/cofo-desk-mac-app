// Raises and lowers the desk through cofo-desk on a sit and stand countdown that runs while the user
// is at the Mac, and shows the countdown in the menu bar (see docs/posture-cycle.md). With --clock, a
// finished Clock timer also ends the sit countdown; it is read from Control Center's timer menu extra.
// Without --device or --simulate-state it only logs Clock timers. Logs are JSON lines on stdout.
import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import TimerDeskCore

struct Options {
    var lengths: [Int] = []
    var tolerance = 3
    var interval = 0.5
    var cofoDesk: String?
    var target: [String]?
    var desk = DeskSettings()
    var cycle = CycleSettings()
    var clock = false
    var traceDesk = false

    /// Log-only mode has nothing else to do.
    var watchesClock: Bool { clock || target == nil }

    static let usage = """
        usage: timer-desk [--cofo-desk PATH (--device UUID | --simulate-state FILE)]
                          [--stand SLOT] [--sit SLOT] [--nudge MM] [--window SECONDS]
                          [--sit-after SECONDS] [--stand-after SECONDS] [--snooze SECONDS]
                          [--idle-pause SECONDS] [--away-reset SECONDS] [--video-limit SECONDS]
                          [--clock] [--length SECONDS]... [--tolerance SECONDS]
                          [--interval SECONDS] [--trace-desk]
          --clock           a finished Clock timer also ends the sit countdown (needs Accessibility)
          --length          with --clock, only this timer length counts; repeatable (default: any length)
          --tolerance       allowed difference from a --length (default 3)
          --interval        poll interval (default 0.5, 0.2-2)
          --cofo-desk       cofo-desk executable; with --device or --simulate-state the desk moves
          --stand, --sit    panel memory slots (default M1, M2)
          --nudge           warning jog in mm (default 10, 5-50)
          --window          cancel window after the jog (default 3, 3-60)
          --sit-after       sit this long before raising (default 1500, 10-7200)
          --stand-after     stand this long before lowering (default 600, 10-7200)
          --snooze          try again after a cancelled or failed move (default 600, 10-7200)
          --idle-pause      no input for this long pauses the countdown (default 300, 10-7200)
          --away-reset      this much time away restarts the countdown (default 900, 10-86400)
          --video-limit     a playing video counts as input for at most this long (default 1800, 0-86400)
          --trace-desk      log every raw GATT write and notification (cofo-desk --trace)
        With a desk, the agent stays connected through `cofo-desk session`. For testing, SIGUSR1
        makes the running countdown due now.
        """

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var rest = arguments[...]
        func number(_ text: String, _ range: ClosedRange<Double>) -> Double? {
            Double(text).flatMap { range.contains($0) ? $0 : nil }
        }
        while let flag = rest.popFirst() {
            if flag == "--trace-desk" {
                options.traceDesk = true
                continue
            }
            if flag == "--clock" {
                options.clock = true
                continue
            }
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
            case "--sit-after":
                guard let value = number(text, 10...7200) else { return nil }
                options.cycle.sitSeconds = value
            case "--stand-after":
                guard let value = number(text, 10...7200) else { return nil }
                options.cycle.standSeconds = value
            case "--snooze":
                guard let value = number(text, 10...7200) else { return nil }
                options.cycle.snoozeSeconds = value
            case "--idle-pause":
                guard let value = number(text, 10...7200) else { return nil }
                options.cycle.idlePauseSeconds = value
            case "--away-reset":
                guard let value = number(text, 10...86400) else { return nil }
                options.cycle.awayResetSeconds = value
            case "--video-limit":
                guard let value = number(text, 0...86400) else { return nil }
                options.cycle.videoLimitSeconds = value
            default:
                return nil
            }
        }
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

func readPresence() -> Presence {
    // ~0 is kCGAnyInputEventType, which Swift does not import.
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    return Presence(inputIdleSeconds: idle, videoPlaying: !displaySleepHolders().isEmpty, locked: screenIsLocked())
}

/// Who keeps the display awake, which is how video playback shows up (see docs/posture-cycle.md).
/// Universal Control holds this on its own, with nobody watching anything (2026-10-31).
func displaySleepHolders() -> [String] {
    var unmanaged: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
          let byProcess = unmanaged?.takeRetainedValue() as? [AnyHashable: [[String: Any]]] else { return [] }
    return byProcess.flatMap { pid, assertions in
        assertions.filter { $0["AssertType"] as? String == "PreventUserIdleDisplaySleep" }
            .map { "\(pid): \($0["AssertName"] as? String ?? "?")" }
            .filter { !$0.contains("universalcontrol") }
    }.sorted()
}

/// Seconds that keep counting while the Mac sleeps, unlike systemUptime.
func monotonicNow() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
}

func menuBarTitle(_ display: CycleDisplay) -> String {
    func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    func arrow(_ posture: Posture) -> String { posture == .sitting ? "↑" : "↓" }
    switch display {
    case .disconnected: return "桌子未連線"
    case .notConfigured: return "未設定 M1／M2"
    case let .paused(remaining): return "⏸ \(clock(remaining))"
    case let .counting(posture, remaining): return "\(arrow(posture)) \(clock(remaining))"
    case let .away(posture, remaining): return "⏸ \(arrow(posture)) \(clock(remaining))"
    case let .waitingForUser(posture): return "\(arrow(posture)) 等你回來"
    case let .moving(posture): return "\(arrow(posture)) 移動中"
    }
}

@MainActor
final class Agent: NSObject {
    private static let suspendSeconds: TimeInterval = 600

    private let policy: TriggerPolicy
    /// Nil when Clock timers are not watched.
    private let reader: MenuExtraReader?
    private var tracker = TimerTracker()
    private var lastFailure: MenuExtraReader.Failure?
    private var locked = screenIsLocked()
    private var videoPlaying = false
    private let standSlot: String
    private let sitSlot: String
    /// Nil in log-only mode, like the session and the status item.
    private var coordinator: DeskCoordinator?
    private var cycle: PostureCycle?
    private var session: DeskSession?
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var suspendItem: NSMenuItem?
    /// Length of the timer now counting down, from its start event.
    private var countingLength: Int?
    /// Seconds left at which the desk connection is checked before a matching timer ends.
    private static let connectionCheckSeconds = 15

    init(options: Options) {
        policy = TriggerPolicy(lengths: options.lengths, tolerance: options.tolerance)
        reader = options.watchesClock ? MenuExtraReader() : nil
        standSlot = options.desk.standSlot
        sitSlot = options.desk.sitSlot
        super.init()
        if let executable = options.cofoDesk, let target = options.target {
            coordinator = DeskCoordinator(settings: options.desk)
            cycle = PostureCycle(settings: options.cycle)
            session = DeskSession(
                executable: executable, target: target + (options.traceDesk ? ["--trace"] : []),
                deliver: { [unowned self] input in self.apply(input) },
                connected: { [unowned self] status in
                    self.applyCycle { $0.deskConnected(heightMm: status.heightMm, standMm: status.memoryMm[self.standSlot],
                                                       sitMm: status.memoryMm[self.sitSlot]) }
                },
                disconnected: { [unowned self] in self.applyCycle { $0.deskDisconnected(); return [] } },
                heightChanged: { [unowned self] mm in self.applyCycle { $0.heightChanged(mm: mm) } })
            setUpStatusItem()
        }
    }

    private func setUpStatusItem() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
            return entry
        }
        _ = add("重新開始倒數", #selector(restartCountdown))
        pauseItem = add("暫停 1 小時", #selector(togglePause))
        suspendItem = add("暫時中斷連線 10 分鐘", #selector(toggleSuspend))
        item.menu = menu
        item.button?.title = menuBarTitle(.disconnected)
        statusItem = item
    }

    @objc private func restartCountdown() {
        applyCycle { $0.restart() }
    }

    @objc private func togglePause() {
        if cycle?.isPaused == true {
            applyCycle { $0.restart() }
        } else {
            let now = monotonicNow()
            applyCycle { $0.pause(now: now) }
        }
    }

    @objc private func toggleSuspend() {
        guard let session else { return }
        if session.isSuspended {
            session.resume()
        } else {
            session.suspend(seconds: Self.suspendSeconds)
        }
    }

    /// Requests a due move now (SIGUSR1, for testing).
    func expireCountdown() {
        cycle?.expire()
    }

    func apply(_ input: CoordinatorInput) {
        guard var coordinator else { return }
        let outputs = coordinator.handle(input)
        self.coordinator = coordinator
        for output in outputs {
            switch output {
            case let .run(command): session?.run(command)
            case .cancelCommand: session?.cancel()
            case let .note(name): emit(["event": name])
            case let .notifyFailure(message):
                emit(["event": "failure-notified", "message": message])
                notifyFailure(message)
            case let .finished(outcome):
                applyCycle { $0.moveFinished(outcome) }
            }
        }
    }

    private func applyCycle(_ change: (inout PostureCycle) -> [CycleOutput]) {
        guard var cycle else { return }
        let outputs = change(&cycle)
        self.cycle = cycle
        for output in outputs {
            switch output {
            case .raise: apply(.raiseRequested)
            case .lower: apply(.lowerRequested)
            case let .note(name): emit(["event": name])
            }
        }
    }

    func tick() {
        let now = monotonicNow()
        let presence = readPresence()
        if presence.locked != locked {
            locked = presence.locked
            emit(["event": locked ? "screen-locked" : "screen-unlocked"])
            if locked { apply(.screenLocked) }
        }
        if presence.videoPlaying != videoPlaying {
            videoPlaying = presence.videoPlaying
            var fields: [String: Any] = ["event": videoPlaying ? "video-signal-on" : "video-signal-off"]
            if videoPlaying { fields["holders"] = displaySleepHolders() }
            emit(fields)
        }
        session?.tick(now: ProcessInfo.processInfo.systemUptime)
        applyCycle { $0.tick(now: now, presence: presence) }
        watchClock()
        updateStatusItem(now: now)
    }

    private func updateStatusItem(now: TimeInterval) {
        guard let cycle, let session else { return }
        let title = session.isSuspended ? "已中斷連線" : menuBarTitle(cycle.display(now: now))
        if statusItem?.button?.title != title { statusItem?.button?.title = title }
        pauseItem?.title = cycle.isPaused ? "結束暫停" : "暫停 1 小時"
        suspendItem?.title = session.isSuspended ? "立刻重新連線" : "暫時中斷連線 10 分鐘"
    }

    private func watchClock() {
        guard let reader else { return }
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
                applyCycle { $0.clockCompleted() }
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
    "event": "agent-started", "pid": Int(getpid()), "clock": options.watchesClock, "lengths": options.lengths,
    "tolerance": options.tolerance, "interval": options.interval,
    "sit_after": options.cycle.sitSeconds, "stand_after": options.cycle.standSeconds,
    "desk": options.target.map { $0.joined(separator: " ") } ?? "log-only",
    "accessibility": options.watchesClock ? AXIsProcessTrustedWithOptions(prompt) : NSNull(),
    "screen_locked": screenIsLocked(),
])

let agent = Agent(options: options)
let workspace = NSWorkspace.shared.notificationCenter
for (name, event) in [(NSWorkspace.willSleepNotification, "will-sleep"), (NSWorkspace.didWakeNotification, "did-wake")] {
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in emit(["event": event]) }
}
signal(SIGPIPE, SIG_IGN)
signal(SIGUSR1, SIG_IGN)
let expireSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
expireSignal.setEventHandler {
    MainActor.assumeIsolated {
        emit(["event": "signal-expire"])
        agent.expireCountdown()
    }
}
expireSignal.resume()
// In the common modes so the countdown keeps running while the menu is open.
let tickTimer = Timer(timeInterval: options.interval, repeats: true) { _ in
    MainActor.assumeIsolated { agent.tick() }
}
RunLoop.main.add(tickTimer, forMode: .common)
NSApplication.shared.run()

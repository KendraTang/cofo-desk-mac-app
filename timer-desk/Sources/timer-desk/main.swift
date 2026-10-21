// Gate 2 agent: polls Control Center's timer menu extra and logs timer events and what it would do
// with the desk as JSON lines on stdout. It never moves the desk.
import AppKit
import ApplicationServices
import TimerDeskCore

struct Options {
    var lengths: [Int] = []
    var tolerance = 3
    var interval = 0.5

    static let usage = """
        usage: timer-desk [--length SECONDS]... [--tolerance SECONDS] [--interval SECONDS]
          --length     timer length that raises the desk; repeatable (default 1500)
          --tolerance  allowed difference from a --length (default 3)
          --interval   poll interval (default 0.5, 0.2-2)
        """

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var rest = arguments[...]
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
                guard let value = Double(text), (0.2...2).contains(value) else { return nil }
                options.interval = value
            default:
                return nil
            }
        }
        if options.lengths.isEmpty { options.lengths = [1500] }
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

    init(options: Options) {
        policy = TriggerPolicy(lengths: options.lengths, tolerance: options.tolerance)
    }

    func tick() {
        let nowLocked = screenIsLocked()
        if nowLocked != locked {
            locked = nowLocked
            emit(["event": nowLocked ? "screen-locked" : "screen-unlocked"])
        }

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
            emit(["event": "started", "length": length ?? NSNull()])
        case let .stopped(remaining):
            emit(["event": "stopped", "remaining": remaining])
        case let .resumed(remaining):
            emit(["event": "resumed", "remaining": remaining])
        case let .completed(length):
            var fields: [String: Any] = ["event": "completed", "length": length ?? NSNull()]
            switch policy.decide(completedLength: length, screenLocked: locked) {
            case .raise:
                fields["decision"] = "would-raise"
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
    "accessibility": AXIsProcessTrustedWithOptions(prompt), "screen_locked": screenIsLocked(),
])

let agent = Agent(options: options)
let workspace = NSWorkspace.shared.notificationCenter
for (name, event) in [(NSWorkspace.willSleepNotification, "will-sleep"), (NSWorkspace.didWakeNotification, "did-wake")] {
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in emit(["event": event]) }
}
Timer.scheduledTimer(withTimeInterval: options.interval, repeats: true) { _ in
    MainActor.assumeIsolated { agent.tick() }
}
RunLoop.main.run()

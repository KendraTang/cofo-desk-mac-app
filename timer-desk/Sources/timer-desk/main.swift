// Raises and lowers the desk through cofo-desk on a sit and stand countdown that runs while the user
// is at the Mac, and shows the countdown in the menu bar (see docs/posture-cycle.md). A finished Clock
// timer can also end the sit countdown; it is read from Control Center's timer menu extra. Settings
// come from the settings window; arguments only override them for development and testing, unsaved.
// Logs are JSON lines on stdout, which the .app points at ~/Library/Logs/timer-desk.log.
import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import ServiceManagement
import TimerDeskCore

struct Options {
    var tolerance = 3
    var interval = 0.5
    /// The repo this .app was built from (see build.sh); nil for a bare binary.
    var repo = Bundle.main.object(forInfoDictionaryKey: "TimerDeskRepo") as? String
    var cofoDesk: String?
    var simulateState: String?
    var traceDesk = false
    var overrides: [(inout AppSettings) -> Void] = []

    static let usage = """
        usage: timer-desk [--cofo-desk PATH] [--device UUID | --simulate-state FILE]
                          [--stand-mm MM] [--sit-mm MM] [--nudge | --no-nudge] [--window SECONDS]
                          [--sit-after SECONDS] [--stand-after SECONDS] [--snooze SECONDS]
                          [--idle-pause SECONDS] [--away-reset SECONDS] [--video-limit SECONDS]
                          [--clock] [--length SECONDS]... [--tolerance SECONDS]
                          [--interval SECONDS] [--trace-desk]
        Everything except these is in the settings window. These are for development and testing:
        they override the saved settings for this run and are not saved.
          --cofo-desk       cofo-desk executable (default: .venv/bin/cofo-desk in the repo the .app was built from)
          --device          the desk's address from `cofo-desk scan`
          --simulate-state  use the simulated desk with this state file
          --stand-mm, --sit-mm  heights to raise and lower to
          --no-nudge        no warning jog before a move
          --window          cancel window (0, or 3-60)
          --sit-after       sit this long before raising (10-7200)
          --stand-after     stand this long before lowering (10-7200)
          --snooze          try again after a cancelled or failed move (10-7200)
          --idle-pause      no input for this long pauses the countdown (10-7200)
          --away-reset      this much time away restarts the countdown (10-86400)
          --video-limit     a playing video counts as input for at most this long (0-86400)
          --clock           a finished Clock timer also ends the sit countdown (needs Accessibility)
          --length          only this timer length counts; repeatable (default: any length)
          --tolerance       allowed difference from a --length (default 3)
          --interval        poll interval (default 0.5, 0.2-2)
          --trace-desk      log every raw GATT write and notification (cofo-desk --trace)
        For testing, SIGUSR1 makes the running countdown due now.
        """

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var rest = arguments[...]
        func number(_ text: String, _ range: ClosedRange<Double>) -> Double? {
            Double(text).flatMap { range.contains($0) ? $0 : nil }
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--trace-desk":
                options.traceDesk = true
                continue
            case "--clock":
                options.overrides.append { $0.clock = true }
                continue
            case "--nudge":
                options.overrides.append { $0.nudge = true }
                continue
            case "--no-nudge":
                options.overrides.append { $0.nudge = false }
                continue
            default:
                break
            }
            guard flag != "--help", let text = rest.popFirst() else { return nil }
            switch flag {
            case "--length":
                guard let value = Int(text), value > 0 else { return nil }
                options.overrides.append { $0.clockLengths.append(value) }
            case "--tolerance":
                guard let value = Int(text), value >= 0 else { return nil }
                options.tolerance = value
            case "--interval":
                guard let value = number(text, 0.2...2) else { return nil }
                options.interval = value
            case "--cofo-desk":
                options.cofoDesk = text
            case "--device":
                guard options.simulateState == nil else { return nil }
                options.overrides.append { $0.deviceID = text }
            case "--simulate-state":
                options.simulateState = text
            case "--stand-mm":
                guard let value = Int(text) else { return nil }
                options.overrides.append { $0.slots[$0.raiseSlot].heightMm = value }
            case "--sit-mm":
                guard let value = Int(text) else { return nil }
                options.overrides.append { $0.slots[$0.lowerSlot].heightMm = value }
            case "--window":
                guard let value = number(text, 0...60), value == 0 || value >= 3 else { return nil }
                options.overrides.append { $0.windowSeconds = value }
            case "--sit-after":
                guard let value = number(text, 10...7200) else { return nil }
                options.overrides.append { $0.sitSeconds = value }
            case "--stand-after":
                guard let value = number(text, 10...7200) else { return nil }
                options.overrides.append { $0.standSeconds = value }
            case "--snooze":
                guard let value = number(text, 10...7200) else { return nil }
                options.overrides.append { $0.snoozeSeconds = value }
            case "--idle-pause":
                guard let value = number(text, 10...7200) else { return nil }
                options.overrides.append { $0.idlePauseSeconds = value }
            case "--away-reset":
                guard let value = number(text, 10...86400) else { return nil }
                options.overrides.append { $0.awayResetSeconds = value }
            case "--video-limit":
                guard let value = number(text, 0...86400) else { return nil }
                options.overrides.append { $0.videoLimitSeconds = value }
            default:
                return nil
            }
        }
        if options.cofoDesk == nil { options.cofoDesk = options.repo.map { "\($0)/.venv/bin/cofo-desk" } }
        guard options.cofoDesk != nil else { return nil }
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

func menuBarTitle(_ display: CycleDisplay, showCountdown: Bool) -> String {
    func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    func arrow(_ posture: Posture) -> String { posture == .sitting ? "↑" : "↓" }
    switch display {
    case .disconnected: return "桌子未連線"
    case .notConfigured: return "未設定高度"
    case let .paused(remaining): return showCountdown ? "⏸ \(clock(remaining))" : "⏸"
    case let .counting(posture, remaining): return showCountdown ? "\(arrow(posture)) \(clock(remaining))" : arrow(posture)
    case let .away(posture, remaining): return showCountdown ? "⏸ \(arrow(posture)) \(clock(remaining))" : "⏸ \(arrow(posture))"
    case let .waitingForUser(posture): return "\(arrow(posture)) 等你回來"
    case let .moving(posture): return "\(arrow(posture)) 移動中"
    }
}

@MainActor
final class Agent: NSObject {
    private static let suspendSeconds: TimeInterval = 600
    /// A connected desk does not advertise, so a scan waits for the link to drop.
    private static let scanDelaySeconds = 1.5

    private let options: Options
    private let model: SettingsModel
    private let window: SettingsWindow
    private var settings: AppSettings
    private var policy: TriggerPolicy
    /// Nil when Clock timers are not watched.
    private var reader: MenuExtraReader?
    private var tracker = TimerTracker()
    private var lastFailure: MenuExtraReader.Failure?
    private var locked = screenIsLocked()
    private var videoPlaying = false
    private var coordinator: DeskCoordinator
    private var cycle: PostureCycle
    private var session: DeskSession!
    private var scanner: DeskScanner?
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem?
    private var suspendItem: NSMenuItem?
    private var clockItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var slotItems: [NSMenuItem] = []
    private var stopItem: NSMenuItem?
    private var updating: Process?
    /// Set when a rebuild succeeded: the agent relaunches itself once no move is running.
    private var restartPending = false
    /// Length of the timer now counting down, from its start event.
    private var countingLength: Int?
    /// Seconds left at which the desk connection is checked before a matching timer ends.
    private static let connectionCheckSeconds = 15

    init(options: Options, model: SettingsModel) {
        self.options = options
        self.model = model
        window = SettingsWindow(model: model)
        settings = model.effective
        policy = TriggerPolicy(lengths: settings.clockLengths, tolerance: options.tolerance)
        reader = settings.clock ? MenuExtraReader() : nil
        coordinator = DeskCoordinator(settings: settings.deskSettings)
        cycle = PostureCycle(settings: settings.cycleSettings)
        super.init()
        session = DeskSession(
            executable: options.cofoDesk!, target: target(for: settings),
            deliver: { [unowned self] input in self.apply(input) },
            connected: { [unowned self] status in
                self.model.deskConnected(heightMm: status.heightMm, limitsMm: status.limitsMm, memoryMm: status.memoryMm)
                self.applyCycle { $0.deskConnected(heightMm: status.heightMm, standMm: self.settings.raiseMm,
                                                   sitMm: self.settings.lowerMm) }
            },
            disconnected: { [unowned self] in
                self.model.deskDisconnected()
                self.applyCycle { $0.deskDisconnected(); return [] }
            },
            heightChanged: { [unowned self] mm in
                self.model.heightMm = mm
                self.applyCycle { $0.heightChanged(mm: mm) }
            })
        model.agent = self
        setUpStatusItem()
        if settings.deviceID == nil && options.simulateState == nil { window.show(tab: .desk) }
    }

    private func target(for settings: AppSettings) -> [String]? {
        var target: [String]
        if let state = options.simulateState {
            target = ["--simulate", "--state-file", state]
        } else if let device = settings.deviceID {
            target = ["--device", device]
        } else {
            return nil
        }
        if options.traceDesk { target.append("--trace") }
        return target
    }

    private func setUpStatusItem() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Text fields only get cut, copy and paste from a main menu.
        NSApplication.shared.mainMenu = editingMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
            return entry
        }
        for index in settings.slots.indices {
            let entry = add("", #selector(moveToSlot))
            entry.tag = index
            slotItems.append(entry)
        }
        stopItem = add("停止", #selector(stopMove))
        menu.addItem(.separator())
        _ = add("重新開始倒數", #selector(restartCountdown))
        pauseItem = add("暫停 1 小時", #selector(togglePause))
        suspendItem = add("暫時中斷連線 10 分鐘", #selector(toggleSuspend))
        menu.addItem(.separator())
        clockItem = add("對齊 Mac 時鐘的倒數計時", #selector(toggleClock))
        menu.addItem(.separator())
        _ = add("設定⋯", #selector(openSettings), key: ",")
        updateItem = add("從原始碼更新並重新啟動", #selector(update))
        updateItem?.isHidden = options.repo == nil
        _ = add("結束", #selector(quit), key: "q")
        item.menu = menu
        item.button?.title = menuBarTitle(.disconnected, showCountdown: true)
        statusItem = item
    }

    private func editingMenu() -> NSMenu {
        let edit = NSMenu(title: "編輯")
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let entry = NSMenuItem()
        entry.submenu = edit
        let menu = NSMenu()
        menu.addItem(entry)
        return menu
    }

    @objc private func moveToSlot(_ sender: NSMenuItem) {
        guard coordinator.phase == .idle, let target = settings.slots[sender.tag].heightMm else { return }
        emit(["event": "manual-move", "slot": sender.tag, "target_mm": target])
        cycle.manualMoveStarted()
        apply(.manualRequested(targetMm: target))
    }

    @objc private func stopMove() {
        apply(.stopRequested)
    }

    @objc private func restartCountdown() {
        applyCycle { $0.restart() }
    }

    @objc private func togglePause() {
        if cycle.isPaused {
            applyCycle { $0.restart() }
        } else {
            let now = monotonicNow()
            applyCycle { $0.pause(now: now) }
        }
    }

    @objc private func toggleSuspend() {
        if session.isSuspended {
            session.resume()
        } else {
            session.suspend(seconds: Self.suspendSeconds)
        }
    }

    @objc private func toggleClock() {
        model.edit { $0.clock.toggle() }
    }

    @objc private func openSettings() {
        window.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// The settings window saved a change: everything takes effect now.
    func settingsChanged() {
        let new = model.effective
        emit(["event": "settings-changed"])
        cycle.update(settings: new.cycleSettings)
        coordinator.settings = new.deskSettings
        policy = TriggerPolicy(lengths: new.clockLengths, tolerance: options.tolerance)
        if new.clock != settings.clock { setClockWatch(new.clock) }
        let targetChanged = new.deviceID != settings.deviceID
        settings = new
        applyCycle { $0.setTargets(standMm: new.raiseMm, sitMm: new.lowerMm) }
        if targetChanged { session.setTarget(target(for: new)) }
    }

    private func setClockWatch(_ on: Bool) {
        reader = on ? MenuExtraReader() : nil
        tracker = TimerTracker()
        lastFailure = nil
        countingLength = nil
        // Asks for Accessibility the first time; the value of kAXTrustedCheckOptionPrompt.
        let trusted = on ? AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) : false
        emit(["event": on ? "clock-watch-on" : "clock-watch-off", "accessibility": on ? trusted : NSNull()])
    }

    /// Drops the desk connection and looks for desks; the session stays down until the scan ends.
    func startScan() {
        guard coordinator.phase == .idle, scanner == nil else { return }
        session.suspend(seconds: Self.suspendSeconds)
        model.scanStarted()
        let scanner = DeskScanner(executable: options.cofoDesk!, simulated: options.simulateState != nil) { [unowned self] found in
            self.scanner = nil
            self.model.scanFinished(found)
        }
        self.scanner = scanner
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanDelaySeconds) {
            MainActor.assumeIsolated { scanner.start() }
        }
    }

    /// Ends the scan: `desk` is the chosen one, nil goes back to the current one.
    func endScan(choosing desk: ScannedDesk?) {
        scanner?.cancel()
        scanner = nil
        model.scanEnded()
        if let desk {
            if desk.address != settings.deviceID { model.forgetDesk() }
            model.edit { $0.choose(deviceID: desk.address, name: desk.name) }
        }
        session.resume()
    }

    /// Rebuilds from the repo this .app was built in.
    @objc private func update() {
        guard updating == nil, !restartPending, let repo = options.repo else { return }
        let script = URL(fileURLWithPath: repo).appendingPathComponent("timer-desk/build.sh")
        let process = Process()
        process.executableURL = script
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self.updateFinished(status) } }
        }
        emit(["event": "update-started", "script": script.path])
        do {
            try process.run()
        } catch {
            updateFinished(-1)
            return
        }
        updating = process
        updateItem?.title = "更新中⋯⋯"
        updateItem?.isEnabled = false
    }

    private func updateFinished(_ status: Int32) {
        updating = nil
        guard status == 0 else {
            emit(["event": "update-failed", "status": Int(status)])
            notifyFailure("更新失敗，詳見 ~/Library/Logs/timer-desk.log")
            updateItem?.title = "從原始碼更新並重新啟動"
            updateItem?.isEnabled = true
            return
        }
        emit(["event": "update-built"])
        restartPending = true
        updateItem?.title = "等桌子停下後重新啟動⋯⋯"
    }

    /// Opens the new build once this process has gone: a running app would only be brought forward.
    private func relaunch() -> Never {
        emit(["event": "restarting-for-update"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"",
                             "sh", "\(getpid())", Bundle.main.bundlePath]
        try? process.run()
        exit(0)
    }

    /// Requests a due move now (SIGUSR1, for testing).
    func expireCountdown() {
        cycle.expire()
    }

    func apply(_ input: CoordinatorInput) {
        let outputs = coordinator.handle(input)
        for output in outputs {
            switch output {
            case let .run(command): session.run(command)
            case .cancelCommand: session.cancel()
            case let .note(name): emit(["event": name])
            case let .notifyFailure(message):
                emit(["event": "failure-notified", "message": message])
                notifyFailure(message)
            case let .finished(outcome):
                applyCycle { $0.moveFinished(outcome) }
            case let .manualFinished(height):
                applyCycle { $0.manualMoveFinished(heightMm: height) }
            }
        }
    }

    private func applyCycle(_ change: (inout PostureCycle) -> [CycleOutput]) {
        let outputs = change(&cycle)
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
        if restartPending && coordinator.phase == .idle { relaunch() }
        session.tick(now: ProcessInfo.processInfo.systemUptime)
        applyCycle { $0.tick(now: now, presence: presence) }
        watchClock()
        updateStatusItem(now: now)
    }

    private func updateStatusItem(now: TimeInterval) {
        let title: String
        if model.scanning {
            title = "搜尋桌子中"
        } else if session.isSuspended {
            title = "已中斷連線"
        } else if settings.deviceID == nil && options.simulateState == nil {
            title = "未選擇桌子"
        } else if session.isConnecting {
            title = "連線中"
        } else {
            title = menuBarTitle(cycle.display(now: now), showCountdown: settings.countdownInMenuBar)
        }
        if statusItem.button?.title != title { statusItem.button?.title = title }
        pauseItem?.title = cycle.isPaused ? "結束暫停" : "暫停 1 小時"
        suspendItem?.title = session.isSuspended ? "立刻重新連線" : "暫時中斷連線 10 分鐘"
        clockItem?.state = settings.clock ? .on : .off
        if session.isConnecting != (model.connectingSince != nil) {
            model.connectingSince = session.isConnecting ? Date() : nil
        }
        let trusted = settings.clock && AXIsProcessTrusted()
        if trusted != model.accessibilityGranted { model.accessibilityGranted = trusted }
        let idle = coordinator.phase == .idle
        stopItem?.isHidden = idle
        model.moving = !idle
        for (entry, slot) in zip(slotItems, settings.slots) {
            entry.isHidden = slot.heightMm == nil
            guard let target = slot.heightMm else { continue }
            let label = "移到：\(slot.name)（\(AppSettings.cm(target)) cm）"
            if entry.title != label { entry.title = label }
            let there = model.heightMm.map { abs($0 - target) <= coordinator.settings.atHeightMm } ?? false
            entry.isEnabled = idle && model.connected && !there
        }
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
            session.ensureConnected()
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
                fields["decision"] = "raise"
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

if CommandLine.arguments.dropFirst().first == "--unregister-login-item" {
    try? SMAppService.mainApp.unregister()
    exit(0)
}
guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data((Options.usage + "\n").utf8))
    exit(2)
}
// Opened from Finder or at login there is no terminal; cofo-desk inherits these too.
if Bundle.main.bundlePath.hasSuffix(".app") {
    let log = NSHomeDirectory() + "/Library/Logs/timer-desk.log"
    let descriptor = open(log, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if descriptor >= 0 {
        dup2(descriptor, STDOUT_FILENO)
        dup2(descriptor, STDERR_FILENO)
        close(descriptor)
    }
}

let model = SettingsModel(overrides: options.overrides)
// The value of kAXTrustedCheckOptionPrompt, which Swift 6 rejects as shared mutable state.
let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
emit([
    "event": "agent-started", "pid": Int(getpid()), "clock": model.effective.clock,
    "lengths": model.effective.clockLengths, "tolerance": options.tolerance, "interval": options.interval,
    "sit_after": model.effective.sitSeconds, "stand_after": model.effective.standSeconds,
    "stand_mm": model.effective.raiseMm ?? NSNull(), "sit_mm": model.effective.lowerMm ?? NSNull(),
    "desk": options.simulateState.map { "simulated: \($0)" } ?? model.effective.deviceID ?? "none",
    "accessibility": model.effective.clock ? AXIsProcessTrustedWithOptions(prompt) : NSNull(),
    "screen_locked": screenIsLocked(),
])

let agent = Agent(options: options, model: model)
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

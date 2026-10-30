import Foundation
import TimerDeskCore

/// Keeps one `cofo-desk session` process connected to the desk and turns its JSON lines into
/// coordinator inputs and connection updates. If the session exits (connection lost, desk busy with the phone app) it is
/// restarted with backoff; `ensureConnected()` restarts it at once. One command runs at a time; a
/// cancelled command's replies are dropped.
@MainActor
final class DeskSession {
    private let executable: String
    private let target: [String]
    private let deliver: (CoordinatorInput) -> Void
    private let connected: (DeskStatus) -> Void
    private let disconnected: () -> Void
    private let heightChanged: (Int) -> Void

    private var process: Process?
    private var input: FileHandle?
    private var output: Pipe?
    /// Tags each process so late callbacks from an earlier one are ignored.
    private var generation = 0
    private var buffer = Data()
    private var ready = false
    private var lastError: String?

    private var nextID = 0
    private var inFlight: (id: Int, command: DeskCommand)?
    private var cancelledID: Int?
    private var queued: DeskCommand?

    private var restartAt: TimeInterval = 0
    private var suspendedUntil: TimeInterval = 0
    private var backoff: TimeInterval = 5
    private static let maxBackoff: TimeInterval = 60

    init(executable: String, target: [String], deliver: @escaping (CoordinatorInput) -> Void,
         connected: @escaping (DeskStatus) -> Void, disconnected: @escaping () -> Void,
         heightChanged: @escaping (Int) -> Void) {
        self.executable = executable
        self.target = target
        self.deliver = deliver
        self.connected = connected
        self.disconnected = disconnected
        self.heightChanged = heightChanged
    }

    var isSuspended: Bool { ProcessInfo.processInfo.systemUptime < suspendedUntil }

    /// Restarts a stopped session when its backoff has passed.
    func tick(now: TimeInterval) {
        if process == nil && now >= restartAt && !isSuspended { start() }
    }

    /// Drops the connection for a while so another app can use the desk. EOF ends the session.
    func suspend(seconds: TimeInterval) {
        suspendedUntil = ProcessInfo.processInfo.systemUptime + seconds
        restartAt = 0
        try? input?.close()
        input = nil
        emit(["event": "desk-session-suspended", "seconds": seconds])
    }

    func resume() {
        suspendedUntil = 0
        restartAt = 0
    }

    /// Starts the session now if it is not running, skipping any backoff.
    func ensureConnected() {
        if process == nil && !isSuspended {
            emit(["event": "desk-session-ensure"])
            start()
        }
    }

    func run(_ command: DeskCommand) {
        if ready && inFlight == nil {
            send(command)
        } else {
            queued = command
            ensureConnected()
        }
    }

    /// Cancels the running command; a cancelled goto sends STOP. Drops any queued command.
    func cancel() {
        queued = nil
        guard let current = inFlight, cancelledID != current.id else { return }
        cancelledID = current.id
        write(["command": "cancel"])
        emit(["event": "desk-command-cancelled", "id": current.id])
    }

    private func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--json"] + target + ["session"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        generation += 1
        let run = generation
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self.received(data, run: run) } }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self.exited(status, run: run) } }
        }
        buffer = Data()
        ready = false
        lastError = nil
        emit(["event": "desk-session-starting"])
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            emit(["event": "desk-session-failed-to-start", "error": error.localizedDescription])
            scheduleRestart()
            failPending("cofo-desk could not start: \(error.localizedDescription)")
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output
    }

    private func send(_ command: DeskCommand) {
        nextID += 1
        inFlight = (nextID, command)
        var request: [String: Any] = ["id": nextID]
        switch command {
        case .status:
            request["command"] = "status"
        case let .goto(mm):
            request["command"] = "goto"
            request["mm"] = mm
            request["timeout"] = 40
        case let .watch(seconds):
            request["command"] = "watch"
            request["seconds"] = seconds
        }
        emit(["event": "desk-command", "request": request])
        write(request)
    }

    private func write(_ request: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        // A broken pipe shows up as an exit right after; the exit handler fails the command.
        try? input.write(contentsOf: data + Data("\n".utf8))
    }

    private func received(_ data: Data, run: Int) {
        guard run == generation else { return }
        if data.isEmpty {
            output?.fileHandleForReading.readabilityHandler = nil
            return
        }
        buffer += data
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(object) }
        }
    }

    private func handle(_ line: [String: Any]) {
        if line["event"] as? String == "ready" {
            ready = true
            backoff = 5
            let status = line["status"] as? [String: Any]
            emit(["event": "desk-session-ready", "height_mm": status?["height_mm"] ?? NSNull(),
                  "memory_mm": status?["memory_mm"] ?? NSNull()])
            if let parsed = status.flatMap(Self.deskStatus) { connected(parsed) }
            startQueued()
            return
        }
        if line["event"] as? String == "height" {
            if let height = line["height_mm"] as? Double { heightChanged(Int(height.rounded())) }
            return
        }
        if line["id"] == nil, let error = line["error"] as? String {
            lastError = error
            return
        }
        guard let current = inFlight, line["id"] as? Int == current.id else { return }
        let dropped = cancelledID == current.id
        if let sample = line["sample"] as? [String: Any] {
            if !dropped, case .watch = current.command, let height = sample["height_mm"] as? Double {
                deliver(.watchSample(heightMm: Int(height.rounded())))
            }
            return
        }
        inFlight = nil
        if let error = line["error"] as? String {
            emit(["event": "desk-command-failed", "id": current.id, "error": error])
            if !dropped { deliver(.commandFailed(error)) }
        } else if line["cancelled"] as? Bool == true {
            emit(["event": "desk-command-cancelled-ack", "id": current.id])
        } else if let result = line["result"] as? [String: Any] {
            emit(["event": "desk-command-done", "id": current.id])
            if !dropped { deliver(Self.input(for: current.command, result: result)) }
        }
        startQueued()
    }

    private func exited(_ status: Int32, run: Int) {
        guard run == generation else { return }
        output?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        ready = false
        disconnected()
        emit(["event": "desk-session-exited", "status": Int(status), "error": lastError ?? NSNull(),
              "retry_seconds": backoff])
        scheduleRestart()
        failPending("desk connection lost" + (lastError.map { ": \($0)" } ?? ""))
    }

    private func scheduleRestart() {
        restartAt = ProcessInfo.processInfo.systemUptime + backoff
        backoff = min(backoff * 2, Self.maxBackoff)
    }

    /// The running command, or a queued one that never got a connection, fails.
    private func failPending(_ message: String) {
        if let current = inFlight {
            inFlight = nil
            if cancelledID != current.id { deliver(.commandFailed(message)) }
        } else if queued != nil {
            queued = nil
            deliver(.commandFailed(message))
        }
    }

    private func startQueued() {
        guard ready, inFlight == nil, let next = queued else { return }
        queued = nil
        send(next)
    }

    private static func deskStatus(_ result: [String: Any]) -> DeskStatus? {
        guard let height = result["height_mm"] as? Double else { return nil }
        var memory: [String: Int] = [:]
        for (slot, value) in result["memory_mm"] as? [String: Any] ?? [:] {
            if let mm = value as? Double { memory[slot] = Int(mm.rounded()) }
        }
        return DeskStatus(heightMm: Int(height.rounded()), memoryMm: memory)
    }

    private static func input(for command: DeskCommand, result: [String: Any]) -> CoordinatorInput {
        switch command {
        case .status:
            guard let status = deskStatus(result) else { return .commandFailed("status had no height") }
            return .status(status)
        case .goto:
            guard let height = (result["status"] as? [String: Any])?["height_mm"] as? Double else {
                return .commandFailed("goto had no final height")
            }
            return .gotoFinished(heightMm: Int(height.rounded()))
        case .watch:
            return .watchFinished
        }
    }
}

/// A banner notification without buttons; the text goes in as an argument, not as script source.
func notifyFailure(_ message: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"timer-desk\"",
                         "-e", "end run", message]
    try? process.run()
}

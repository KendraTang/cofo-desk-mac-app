import Foundation
import TimerDeskCore

/// Runs one cofo-desk command at a time and turns its JSON output into coordinator inputs.
/// A command started while another runs waits for it; a cancelled command's results are dropped.
@MainActor
final class DeskRunner {
    private let executable: String
    private let target: [String]
    private let deliver: (CoordinatorInput) -> Void

    private var child: Process?
    private var output: Pipe?
    /// Tags each run so late callbacks from an earlier process are ignored.
    private var generation = 0
    private var command: DeskCommand?
    private var queued: DeskCommand?
    private var cancelled = false
    private var buffer = Data()
    private var lastLine: [String: Any]?
    private var reachedEOF = false
    private var exitStatus: Int32?

    init(executable: String, target: [String], deliver: @escaping (CoordinatorInput) -> Void) {
        self.executable = executable
        self.target = target
        self.deliver = deliver
    }

    func run(_ command: DeskCommand) {
        if child == nil { start(command) } else { queued = command }
    }

    /// SIGTERM: cofo-desk sends STOP if it is moving, then disconnects.
    func cancel() {
        guard let child, !cancelled else { return }
        cancelled = true
        child.terminate()
        emit(["event": "desk-command-cancelled"])
    }

    private static func arguments(for command: DeskCommand) -> [String] {
        switch command {
        case .status: return ["status"]
        case let .goto(mm): return ["goto", String(mm), "--unit", "mm", "--timeout", "40"]
        case let .watch(seconds): return ["watch", "--seconds", String(seconds)]
        }
    }

    private func start(_ command: DeskCommand) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--json"] + target + Self.arguments(for: command)
        let output = Pipe()
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
        self.output = output
        self.command = command
        child = process
        cancelled = false
        buffer = Data()
        lastLine = nil
        reachedEOF = false
        exitStatus = nil
        emit(["event": "desk-command", "arguments": Self.arguments(for: command)])
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            child = nil
            deliver(.commandFailed("cofo-desk could not start: \(error.localizedDescription)"))
            startQueued()
        }
    }

    private func received(_ data: Data, run: Int) {
        guard run == generation, child != nil, !reachedEOF else { return }
        if data.isEmpty {
            reachedEOF = true
            output?.fileHandleForReading.readabilityHandler = nil
            finishIfDone()
            return
        }
        buffer += data
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            lastLine = object
            if !cancelled, case .watch = command, let height = object["height_mm"] as? Double {
                deliver(.watchSample(heightMm: Int(height.rounded())))
            }
        }
    }

    private func exited(_ status: Int32, run: Int) {
        guard run == generation else { return }
        exitStatus = status
        finishIfDone()
    }

    private func finishIfDone() {
        guard reachedEOF, let status = exitStatus, let command else { return }
        let line = lastLine
        let wasCancelled = cancelled
        child = nil
        output = nil
        self.command = nil
        emit(["event": "desk-command-exited", "status": Int(status), "cancelled": wasCancelled])
        if !wasCancelled { deliver(Self.result(of: command, status: status, line: line)) }
        startQueued()
    }

    private func startQueued() {
        guard let next = queued else { return }
        queued = nil
        start(next)
    }

    private static func result(of command: DeskCommand, status: Int32, line: [String: Any]?) -> CoordinatorInput {
        guard status == 0, let line else {
            return .commandFailed(line?["error"] as? String ?? "cofo-desk exited with status \(status)")
        }
        switch command {
        case .status:
            guard let height = line["height_mm"] as? Double else { return .commandFailed("status had no height") }
            var memory: [String: Int] = [:]
            for (slot, value) in line["memory_mm"] as? [String: Any] ?? [:] {
                if let mm = value as? Double { memory[slot] = Int(mm.rounded()) }
            }
            return .status(DeskStatus(heightMm: Int(height.rounded()), memoryMm: memory))
        case .goto:
            guard let height = (line["status"] as? [String: Any])?["height_mm"] as? Double else {
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

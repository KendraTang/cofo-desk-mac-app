// Permission probe: run by launchd, checks that this signed binary holds Accessibility and that a
// cofo-desk child process can use Bluetooth under this binary's grant. Read-only (status only).
// Usage: perm-probe <log-file> <cofo-desk-path> <device-uuid>
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: perm-probe <log-file> <cofo-desk-path> <device-uuid>"); exit(2) }
let logURL = URL(fileURLWithPath: args[1])
var lines: [String] = []
func log(_ line: String) {
    lines.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
    try? lines.joined(separator: "\n").appending("\n").write(to: logURL, atomically: true, encoding: .utf8)
}

log("pid=\(getpid()) ppid=\(getppid()) exe=\(args[0])")
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(prompt)
log("AXIsProcessTrusted=\(trusted)")

if trusted, let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
    let app = AXUIElementCreateApplication(cc.processIdentifier)
    func find(_ e: AXUIElement, _ depth: Int) -> String? {
        var id: AnyObject?, value: AnyObject?, kids: AnyObject?
        AXUIElementCopyAttributeValue(e, "AXIdentifier" as CFString, &id)
        if id as? String == "com.apple.menuextra.timer" {
            AXUIElementCopyAttributeValue(e, "AXValue" as CFString, &value)
            return value as? String ?? "nil"
        }
        guard depth < 4 else { return nil }
        AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &kids)
        for k in kids as? [AXUIElement] ?? [] { if let v = find(k, depth + 1) { return v } }
        return nil
    }
    log("timer menu extra value=\(find(app, 0) ?? "not found")")
}

let child = Process()
child.executableURL = URL(fileURLWithPath: args[2])
child.arguments = ["--json", "--device", args[3], "status"]
let out = Pipe(), err = Pipe()
child.standardOutput = out
child.standardError = err
do {
    try child.run()
    child.waitUntilExit()
    log("cofo-desk exit=\(child.terminationStatus) reason=\(child.terminationReason.rawValue)")
    log("stdout: \(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
    log("stderr: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
} catch {
    log("cofo-desk failed to start: \(error)")
}
log("done")

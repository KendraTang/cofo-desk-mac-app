// Dumps the Accessibility tree of Clock, Control Center and SystemUIServer (including their
// menu bar extras) to probes/out/ax-<label>.txt. Read-only: it never performs AX actions.
// Usage: swift ax-dump.swift <label>
import AppKit
import ApplicationServices

let label = CommandLine.arguments.dropFirst().first ?? "snapshot"
let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("out")

let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(prompt) else {
    print("NOT TRUSTED: grant Accessibility to this terminal app in System Settings, then rerun.")
    exit(2)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ element: AXUIElement, _ name: String) -> String? {
    switch attribute(element, name) {
    case let s as String: return s.isEmpty ? nil : s
    case let n as NSNumber: return n.stringValue
    default: return nil
    }
}

let fields = [("sub", "AXSubrole"), ("id", "AXIdentifier"), ("title", "AXTitle"),
              ("value", "AXValue"), ("desc", "AXDescription"), ("help", "AXHelp")]

func dump(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
    guard depth <= 25, lines.count < 5000 else { return }
    var parts = [String(repeating: "  ", count: depth) + (text(element, "AXRole") ?? "?")]
    for (key, name) in fields {
        if let s = text(element, name) { parts.append("\(key)=\(s.debugDescription)") }
    }
    lines.append(parts.joined(separator: " "))
    var children = attribute(element, "AXChildren") as? [AXUIElement] ?? []
    if depth == 0, let extras = attribute(element, "AXExtrasMenuBar") {
        lines.append("  -- AXExtrasMenuBar")
        children.append(extras as! AXUIElement)
    }
    for child in children { dump(child, depth: depth + 1, into: &lines) }
}

var lines = ["# \(label) \(ISO8601DateFormatter().string(from: Date()))"]
for bundle in ["com.apple.clock", "com.apple.controlcenter", "com.apple.systemuiserver"] {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
    lines.append("## \(bundle) pids=\(apps.map(\.processIdentifier))")
    for app in apps {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 2)
        dump(element, depth: 0, into: &lines)
    }
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let file = outDir.appendingPathComponent("ax-\(label).txt")
try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
print("wrote \(lines.count) lines to \(file.path)")

// Prints every change of Control Center's timer menu extra (com.apple.menuextra.timer), both from
// 0.5 s polling ("poll") and from an AXObserver value-changed subscription ("notify").
// Read-only. Usage: swift ax-timer-watch.swift [seconds]
import AppKit
import ApplicationServices

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "120") ?? 120
let start = Date()

guard AXIsProcessTrusted() else {
    print("NOT TRUSTED: grant Accessibility to this terminal app in System Settings, then rerun.")
    exit(2)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func findTimerExtra(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if attribute(element, "AXIdentifier") as? String == "com.apple.menuextra.timer" { return element }
    guard depth < 4 else { return nil }
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] {
        if let found = findTimerExtra(in: child, depth: depth + 1) { return found }
    }
    return nil
}

func log(_ source: String, _ value: String) {
    print(String(format: "%7.2f %@ %@", Date().timeIntervalSince(start), source, value))
    fflush(stdout)
}

guard let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
    print("Control Center is not running"); exit(1)
}
let pid = controlCenter.processIdentifier
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
guard let extra = findTimerExtra(in: app) else { print("timer menu extra not found"); exit(1) }

var observer: AXObserver?
let callback: AXObserverCallback = { _, element, notification, _ in
    log("notify", "\(notification) \(attribute(element, "AXValue") as? String ?? "nil")")
}
if AXObserverCreate(pid, callback, &observer) == .success, let observer {
    let rc = AXObserverAddNotification(observer, extra, kAXValueChangedNotification as CFString, nil)
    print("observer add: \(rc.rawValue)")
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
}

var last: String?
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let value = attribute(extra, "AXValue") as? String ?? "nil"
    if value != last { log("poll", value); last = value }
    if Date().timeIntervalSince(start) > seconds { exit(0) }
}
print("watching \(Int(seconds)) s, pid \(pid)")
RunLoop.current.run()

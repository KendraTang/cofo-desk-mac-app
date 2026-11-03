import AppKit
import ServiceManagement
import SwiftUI
import TimerDeskCore

/// The saved settings and the desk state the window shows. Changes go to the agent at once.
@MainActor
final class SettingsModel: ObservableObject {
    private static let key = "settings"

    @Published private(set) var settings: AppSettings
    @Published private(set) var connected = false
    @Published var heightMm: Int?
    @Published private(set) var limitsMm: ClosedRange<Int>?
    @Published private(set) var panelMemoryMm: [String: Int] = [:]
    /// When the current connection attempt started; nil when not connecting.
    @Published var connectingSince: Date?
    @Published var accessibilityGranted = false
    @Published var moving = false
    @Published var heightError: String?
    @Published private(set) var scanning = false
    /// Nil before the first result of a scan.
    @Published private(set) var scanResults: [ScannedDesk]?
    @Published private(set) var scanFailed = false
    weak var agent: Agent?
    private let overrides: [(inout AppSettings) -> Void]

    init(overrides: [(inout AppSettings) -> Void]) {
        self.overrides = overrides
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = AppSettings()
            // The menu's Clock switch before there were settings.
            settings.clock = UserDefaults.standard.bool(forKey: "watchClock")
        }
    }

    /// What the agent runs with: the saved settings plus this run's arguments.
    var effective: AppSettings {
        var result = settings
        for override in overrides { override(&result) }
        return result
    }

    func edit(_ change: (inout AppSettings) -> Void) {
        var new = settings
        change(&new)
        guard new != settings else { return }
        settings = new
        if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: Self.key) }
        agent?.settingsChanged()
    }

    /// Saves the change to the heights unless it breaks a rule; the old values stay in effect then.
    func editHeights(_ change: (inout AppSettings) -> Void) {
        var new = settings
        change(&new)
        heightError = new.heightProblem(limitsMm: limitsMm)
        if heightError == nil { edit(change) }
    }

    func setHeight(slot: Int, text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            editHeights { $0.slots[slot].heightMm = nil }
        } else if let mm = AppSettings.mm(fromCm: text) {
            editHeights { $0.slots[slot].heightMm = mm }
        } else {
            heightError = "「\(settings.slots[slot].name)」的高度要填數字"
        }
    }

    func resetAdvanced() {
        let defaults = AppSettings()
        edit {
            $0.idlePauseSeconds = defaults.idlePauseSeconds
            $0.awayResetSeconds = defaults.awayResetSeconds
            $0.videoLimitSeconds = defaults.videoLimitSeconds
            $0.windowSeconds = defaults.windowSeconds
            $0.nudge = defaults.nudge
            $0.clockLengths = defaults.clockLengths
        }
    }

    func deskConnected(heightMm: Int, limitsMm: ClosedRange<Int>?, memoryMm: [String: Int]) {
        connected = true
        self.heightMm = heightMm
        self.limitsMm = limitsMm
        panelMemoryMm = memoryMm
    }

    /// Another desk was chosen: what was read from the old one no longer applies.
    func forgetDesk() {
        heightMm = nil
        limitsMm = nil
        panelMemoryMm = [:]
        heightError = nil
    }

    func deskDisconnected() {
        connected = false
    }

    func scanStarted() {
        scanning = true
        scanResults = nil
        scanFailed = false
    }

    func scanFinished(_ desks: [ScannedDesk]?) {
        scanning = false
        scanResults = desks ?? []
        scanFailed = desks == nil
    }

    func scanEnded() {
        scanning = false
        scanResults = nil
        scanFailed = false
    }
}

enum SettingsTab: Hashable {
    case general, desk, advanced, about
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private let selection = TabSelection()
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(model: model, selection: selection)))
            window.title = "timer-desk 設定"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Ends editing, so the field being typed in saves.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }
}

@MainActor
final class TabSelection: ObservableObject {
    @Published var tab = SettingsTab.general
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var selection: TabSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab(model: model).tabItem { Text("一般") }.tag(SettingsTab.general)
            DeskTab(model: model).tabItem { Text("桌子") }.tag(SettingsTab.desk)
            AdvancedTab(model: model).tabItem { Text("進階") }.tag(SettingsTab.advanced)
            AboutTab().tabItem { Text("關於") }.tag(SettingsTab.about)
        }
        .padding(12)
        .frame(width: 560, height: 520)
    }
}

/// A text field that saves when editing ends; `commit` returns what is wrong with the text, if anything.
struct CommitField: View {
    let value: String
    var width: CGFloat = 64
    var alignment = TextAlignment.trailing
    var placeholder = ""
    let commit: (String) -> String?
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Bordered: in a grouped form a plain field does not look editable, least of all when empty.
            TextField("", text: $text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(alignment)
                .frame(width: width)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, now in if !now { save() } }
                .onChange(of: value) { _, now in
                    text = now
                    problem = nil
                }
                .onAppear { text = value }
                .onDisappear(perform: save)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func save() {
        guard text != value else {
            problem = nil
            return
        }
        problem = commit(text)
    }
}

/// A length edited in `unit` seconds and saved in seconds.
struct LengthRow: View {
    @ObservedObject var model: SettingsModel
    let title: String
    let path: WritableKeyPath<AppSettings, Double>
    var unit = 60.0
    var unitName = "分鐘"
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack(alignment: .firstTextBaseline) {
                CommitField(value: String(format: "%g", model.settings[keyPath: path] / unit)) { text in
                    guard let number = Double(text), range.contains(number) else {
                        return "要填 \(String(format: "%g", range.lowerBound))–\(String(format: "%g", range.upperBound))"
                    }
                    model.edit { $0[keyPath: path] = number * unit }
                    return nil
                }
                Text(unitName)
            }
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Section {
                LengthRow(model: model, title: "坐多久", path: \.sitSeconds, range: 1...180)
                LengthRow(model: model, title: "站多久", path: \.standSeconds, range: 1...180)
                LengthRow(model: model, title: "取消後延後多久", path: \.snoozeSeconds, range: 1...180)
                Toggle("對齊 Mac 時鐘的倒數計時", isOn: Binding(
                    get: { model.settings.clock },
                    set: { on in model.edit { $0.clock = on } }))
                if model.settings.clock && !model.accessibilityGranted {
                    HStack {
                        Text("需要「輔助使用」權限才能讀到 Clock 的計時器，現在還沒有。")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("打開系統設定") {
                            NSWorkspace.shared.open(URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
            Section {
                Toggle("登入時自動啟動", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in setLoginItem(on) }))
                .disabled(!Bundle.main.bundlePath.hasSuffix(".app"))
                if let loginProblem {
                    Text(loginProblem).font(.caption).foregroundStyle(.red)
                }
                Picker("選單列顯示", selection: Binding(
                    get: { model.settings.countdownInMenuBar },
                    set: { on in model.edit { $0.countdownInMenuBar = on } })) {
                    Text("倒數時間").tag(true)
                    Text("只顯示圖示").tag(false)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginProblem = nil
            model.objectWillChange.send()
        } catch {
            loginProblem = "沒辦法設定：\(error.localizedDescription)"
            emit(["event": "login-item-failed", "error": error.localizedDescription])
        }
    }
}

struct DeskTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("桌子") { connection }
            Section("高度（cm）") {
                ForEach(model.settings.slots.indices, id: \.self) { index in
                    slotRow(index)
                }
                slotPicker("自動升起到", get: \.raiseSlot) { settings, slot in settings.raiseSlot = slot }
                slotPicker("自動降下到", get: \.lowerSlot) { settings, slot in settings.lowerSlot = slot }
                if let error = model.heightError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if !model.panelMemoryMm.isEmpty {
                    Text("參考：桌子面板上存的是 " + model.panelMemoryMm.sorted { $0.key < $1.key }
                        .map { "\($0.key) \(AppSettings.cm($0.value))" }.joined(separator: "、")
                        + " cm。那是另一組，這裡的設定不會改到面板，面板也不會改到這裡。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var connection: some View {
        LabeledContent("目前") {
            if let id = model.effective.deviceID {
                Text("\(model.effective.deviceName ?? id)（\(model.connected ? "已連線" : model.connectingSince != nil ? "連線中⋯⋯" : "未連線")）")
            } else {
                Text("還沒選擇")
            }
        }
        if let since = model.connectingSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                if context.date.timeIntervalSince(since) > 15 {
                    Text("連線通常要 5–10 秒。超過 15 秒還沒連上，請確認手機上的 COFO App 已關閉，或按一下面板任一鍵叫醒桌子。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("連線中，通常要 5–10 秒。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let height = model.heightMm, model.connected {
            LabeledContent("目前高度") { Text("\(AppSettings.cm(height)) cm") }
        }
        if let results = model.scanResults {
            if model.scanFailed {
                Text("搜尋失敗。請確認 Mac 的藍牙已開啟，並允許這個 app 使用藍牙。").foregroundStyle(.red)
            } else if results.isEmpty {
                Text("找不到桌子。請關掉手機上的 COFO App，並確認桌子的藍牙已開啟（同按面板的 1 和 3 超過 3 秒可切換）。")
            }
            ForEach(results) { desk in
                HStack {
                    Text(desk.name ?? desk.address).lineLimit(1)
                    if desk.knownService { Text("桌子").font(.caption).foregroundStyle(.green) }
                    Spacer()
                    Text("訊號 \(desk.rssi)").foregroundStyle(.secondary)
                    Button("選擇") { model.agent?.endScan(choosing: desk) }
                }
            }
            HStack {
                Button("再搜尋一次") { model.agent?.startScan() }
                Button("取消") { model.agent?.endScan(choosing: nil) }
            }
        } else if model.scanning {
            HStack {
                ProgressView().controlSize(.small)
                Text("搜尋中⋯⋯")
                Spacer()
                Button("取消") { model.agent?.endScan(choosing: nil) }
            }
        } else {
            Button(model.settings.deviceID == nil ? "搜尋桌子" : "更換桌子⋯") { model.agent?.startScan() }
                .disabled(model.moving)
        }
    }

    private func slotRow(_ index: Int) -> some View {
        let slot = model.settings.slots[index]
        return HStack(alignment: .firstTextBaseline) {
            CommitField(value: slot.name, width: 110, alignment: .leading) { text in
                let name = text.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return "名稱不能空白" }
                model.edit { $0.slots[index].name = name }
                return nil
            }
            Spacer()
            CommitField(value: slot.heightMm.map(AppSettings.cm) ?? "", placeholder: "未設定") { text in
                model.setHeight(slot: index, text: text)
                return nil
            }
            Button("用目前高度") {
                if let height = model.heightMm { model.setHeight(slot: index, text: AppSettings.cm(height)) }
            }
            .disabled(!model.connected || model.heightMm == nil)
        }
    }

    private func slotPicker(_ title: String, get: KeyPath<AppSettings, Int>,
                            set: @escaping (inout AppSettings, Int) -> Void) -> some View {
        Picker(title, selection: Binding(
            get: { model.settings[keyPath: get] },
            set: { slot in model.editHeights { set(&$0, slot) } })) {
            ForEach(model.settings.slots.indices, id: \.self) { index in
                Text(model.settings.slots[index].name).tag(index)
            }
        }
    }
}

struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("在不在座位") {
                LengthRow(model: model, title: "沒操作多久暫停倒數", path: \.idlePauseSeconds, range: 1...120)
                LengthRow(model: model, title: "離開多久回來重新倒數", path: \.awayResetSeconds, range: 1...1440)
                LengthRow(model: model, title: "影片最多代替操作多久", path: \.videoLimitSeconds, range: 0...1440)
            }
            Section("移動") {
                LabeledContent("移動前的取消時間") {
                    HStack(alignment: .firstTextBaseline) {
                        CommitField(value: String(format: "%g", model.settings.windowSeconds)) { text in
                            // Under 3 s the desk may not report its height in time to tell a key press.
                            guard let seconds = Double(text), seconds == 0 || (3...30).contains(seconds) else {
                                return "要填 0 或 3–30"
                            }
                            model.edit { $0.windowSeconds = seconds }
                            return nil
                        }
                        Text("秒")
                    }
                }
                if model.settings.windowSeconds == 0 {
                    Text("設成 0 時，移動前沒有時間取消。").font(.caption).foregroundStyle(.orange)
                }
                Toggle("移動前先微動 1 cm", isOn: Binding(
                    get: { model.settings.nudge },
                    set: { on in model.edit { $0.nudge = on } }))
            }
            Section("Clock") {
                LabeledContent("只認這些長度的計時器（分鐘）") {
                    CommitField(
                        value: model.settings.clockLengths.map { String(format: "%g", Double($0) / 60) }
                            .joined(separator: ", "),
                        width: 120, placeholder: "任何長度") { text in
                        guard let lengths = AppSettings.clockLengths(fromMinutes: text) else {
                            return "要填數字，用逗號分隔"
                        }
                        model.edit { $0.clockLengths = lengths }
                        return nil
                    }
                }
                Text("空白代表任何長度。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("打開 log") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/timer-desk.log"))
                    }
                    Spacer()
                    Button("回復預設值") { model.resetAdvanced() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let number = info?["CFBundleShortVersionString"] as? String ?? "開發版"
        return (info?["TimerDeskCommit"] as? String).map { "\(number)（\($0)）" } ?? number
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("timer-desk").font(.title2)
            Text("版本 \(version)").foregroundStyle(.secondary)
            Link("GitHub", destination: URL(string: "https://github.com/KendraTang/cofo-desk-mac-app")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

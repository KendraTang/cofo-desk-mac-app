import Foundation

public struct HeightSlot: Codable, Equatable, Sendable {
    public var name: String
    public var heightMm: Int?

    public init(name: String, heightMm: Int? = nil) {
        self.name = name
        self.heightMm = heightMm
    }
}

/// Everything the settings window edits. Saved as one JSON value in UserDefaults.
public struct AppSettings: Codable, Equatable, Sendable {
    public var deviceID: String?
    public var deviceName: String?
    /// The app's own heights, separate from the panel's memory on purpose.
    public var slots = [HeightSlot(name: "站立"), HeightSlot(name: "坐姿"), HeightSlot(name: "其他")]
    public var raiseSlot = 0
    public var lowerSlot = 1
    public var sitSeconds = 1500.0
    public var standSeconds = 600.0
    public var snoozeSeconds = 600.0
    public var idlePauseSeconds = 300.0
    public var awayResetSeconds = 900.0
    public var videoLimitSeconds = 1800.0
    public var windowSeconds = 3.0
    public var nudge = true
    public var clock = false
    /// Clock timer lengths that count, in seconds; empty means any length.
    public var clockLengths: [Int] = []
    public var countdownInMenuBar = true

    public init() {}

    public var raiseMm: Int? { slots[raiseSlot].heightMm }
    public var lowerMm: Int? { slots[lowerSlot].heightMm }

    public var cycleSettings: CycleSettings {
        var cycle = CycleSettings()
        cycle.sitSeconds = sitSeconds
        cycle.standSeconds = standSeconds
        cycle.snoozeSeconds = snoozeSeconds
        cycle.idlePauseSeconds = idlePauseSeconds
        cycle.awayResetSeconds = awayResetSeconds
        cycle.videoLimitSeconds = videoLimitSeconds
        return cycle
    }

    public var deskSettings: DeskSettings {
        var desk = DeskSettings()
        desk.standMm = raiseMm
        desk.sitMm = lowerMm
        desk.nudgeMm = nudge ? desk.nudgeMm : 0
        desk.windowSeconds = windowSeconds
        return desk
    }

    /// Why these heights cannot be saved, or nil if they can.
    public func heightProblem(limitsMm: ClosedRange<Int>?) -> String? {
        if let limitsMm {
            for slot in slots {
                if let height = slot.heightMm, !limitsMm.contains(height) {
                    return "「\(slot.name)」超出桌子的範圍（\(Self.cm(limitsMm.lowerBound))–\(Self.cm(limitsMm.upperBound)) cm）"
                }
            }
        }
        if raiseSlot == lowerSlot { return "自動升起和自動降下不能用同一個高度" }
        if let raiseMm, let lowerMm, raiseMm <= lowerMm { return "自動升起的高度要比自動降下的高" }
        return nil
    }

    /// Heights belong to one desk: another desk has other limits, so they do not carry over.
    public mutating func choose(deviceID: String, name: String?) {
        if deviceID != self.deviceID {
            for index in slots.indices { slots[index].heightMm = nil }
        }
        self.deviceID = deviceID
        deviceName = name
    }

    public static func cm(_ mm: Int) -> String {
        String(format: "%.1f", Double(mm) / 10)
    }

    /// "95.9" to 959; nil if it is not a number.
    public static func mm(fromCm text: String) -> Int? {
        Double(text.trimmingCharacters(in: .whitespaces)).map { Int(($0 * 10).rounded()) }
    }

    /// "25, 50" (minutes) to seconds; empty text means any length, nil means it does not parse.
    public static func clockLengths(fromMinutes text: String) -> [Int]? {
        var lengths: [Int] = []
        for part in text.split(whereSeparator: { ",，、 ".contains($0) }) {
            guard let minutes = Double(part), minutes > 0 else { return nil }
            lengths.append(Int((minutes * 60).rounded()))
        }
        return lengths
    }
}

import Testing
@testable import TimerDeskCore

private func settings(raise: Int?, lower: Int?) -> AppSettings {
    var settings = AppSettings()
    settings.slots[0].heightMm = raise
    settings.slots[1].heightMm = lower
    return settings
}

@Test func heightsStartEmptyAndHaveNoProblem() {
    #expect(AppSettings().raiseMm == nil)
    #expect(AppSettings().lowerMm == nil)
    #expect(AppSettings().heightProblem(limitsMm: 630...1280) == nil)
}

@Test func raiseHasToBeHigherThanLower() {
    #expect(settings(raise: 959, lower: 631).heightProblem(limitsMm: nil) == nil)
    #expect(settings(raise: 631, lower: 631).heightProblem(limitsMm: nil) == "自動升起的高度要比自動降下的高")
    #expect(settings(raise: 631, lower: 959).heightProblem(limitsMm: nil) != nil)
}

@Test func heightsHaveToBeWithinTheDeskLimits() {
    #expect(settings(raise: 1300, lower: 631).heightProblem(limitsMm: 630...1280) == "「站立」超出桌子的範圍（63.0–128.0 cm）")
    #expect(settings(raise: 1300, lower: 631).heightProblem(limitsMm: nil) == nil)
}

@Test func raiseAndLowerCannotShareASlot() {
    var same = AppSettings()
    same.lowerSlot = same.raiseSlot
    #expect(same.heightProblem(limitsMm: nil) == "自動升起和自動降下不能用同一個高度")
}

@Test func anotherDeskClearsTheHeightsAndKeepsTheNames() {
    var chosen = settings(raise: 959, lower: 631)
    chosen.slots[0].name = "午睡"
    chosen.choose(deviceID: "a", name: "A")
    #expect(chosen.raiseMm == nil)
    #expect(chosen.slots[0].name == "午睡")

    chosen.slots[0].heightMm = 959
    chosen.choose(deviceID: "a", name: "A")
    #expect(chosen.raiseMm == 959)
}

@Test func theDeskSettingsFollowTheChosenSlots() {
    var chosen = settings(raise: 959, lower: 631)
    chosen.slots[2].heightMm = 700
    chosen.lowerSlot = 2
    chosen.nudge = false
    #expect(chosen.deskSettings.standMm == 959)
    #expect(chosen.deskSettings.sitMm == 700)
    #expect(chosen.deskSettings.nudgeMm == 0)
}

@Test func textConversions() {
    #expect(AppSettings.mm(fromCm: " 95.9 ") == 959)
    #expect(AppSettings.mm(fromCm: "abc") == nil)
    #expect(AppSettings.cm(1280) == "128.0")
    #expect(AppSettings.clockLengths(fromMinutes: "") == [])
    #expect(AppSettings.clockLengths(fromMinutes: "25, 50") == [1500, 3000])
    #expect(AppSettings.clockLengths(fromMinutes: "25，x") == nil)
}

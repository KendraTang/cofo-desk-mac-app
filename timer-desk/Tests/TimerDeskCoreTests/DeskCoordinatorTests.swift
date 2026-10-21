import Testing
@testable import TimerDeskCore

private let memory = ["M1": 959, "M2": 631]

private func sitting(_ height: Int = 631) -> CoordinatorInput {
    .status(DeskStatus(heightMm: height, memoryMm: memory))
}

/// Runs a raise through the cancel window without a key press, ending at M1.
private func raise(_ coordinator: inout DeskCoordinator, now: Double = 0) {
    _ = coordinator.handle(.raiseRequested, now: now)
    _ = coordinator.handle(sitting(), now: now)
    _ = coordinator.handle(.gotoFinished(heightMm: 651), now: now)
    _ = coordinator.handle(.watchSample(heightMm: 651), now: now)
    _ = coordinator.handle(.watchFinished, now: now)
    _ = coordinator.handle(.gotoFinished(heightMm: 959), now: now)
}

@Test func raiseJogsWaitsThenMovesToStandAndSchedulesLower() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    #expect(coordinator.handle(.raiseRequested, now: 0) == [.run(.status)])
    #expect(coordinator.handle(sitting(), now: 1) == [.run(.goto(mm: 651))])
    #expect(coordinator.handle(.gotoFinished(heightMm: 651), now: 3) == [.run(.watch(seconds: 10))])
    #expect(coordinator.handle(.watchSample(heightMm: 651), now: 4) == [])
    #expect(coordinator.handle(.watchSample(heightMm: 653), now: 5) == [])
    #expect(coordinator.handle(.watchFinished, now: 14) == [.run(.goto(mm: 959))])
    #expect(coordinator.handle(.gotoFinished(heightMm: 959), now: 25) == [.note("raised")])
    #expect(coordinator.phase == .idle)
    #expect(coordinator.lowerDue?.raisedMm == 959)
    #expect(coordinator.lowerDue?.at == 925)
}

@Test func panelPressDuringWindowCancelsTheRaise() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested, now: 0)
    _ = coordinator.handle(sitting(), now: 0)
    _ = coordinator.handle(.gotoFinished(heightMm: 651), now: 0)
    _ = coordinator.handle(.watchSample(heightMm: 651), now: 0)
    #expect(coordinator.handle(.watchSample(heightMm: 640), now: 1) == [.cancelCommand, .note("raise-cancelled-by-panel")])
    // The cancelled watch's own result arrives afterwards and is ignored.
    #expect(coordinator.handle(.commandFailed("Interrupted by SIGTERM"), now: 2) == [])
    #expect(coordinator.handle(.watchFinished, now: 2) == [])
    #expect(coordinator.lowerDue == nil)
}

@Test func alreadyStandingSkipsTheRaise() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested, now: 0)
    #expect(coordinator.handle(sitting(950), now: 0) == [.note("raise-skipped-already-standing")])
    #expect(coordinator.phase == .idle)
}

@Test func missingMemoryHeightFailsWithANotification() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested, now: 0)
    #expect(coordinator.handle(.status(DeskStatus(heightMm: 631, memoryMm: [:])), now: 0) == [
        .note("raise-failed"), .notifyFailure("升桌失敗：M1 memory height is not set"),
    ])
}

@Test func commandFailureNotifiesAndReturnsToIdle() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested, now: 0)
    #expect(coordinator.handle(.commandFailed("Device disconnected"), now: 0) == [
        .note("raise-failed"), .notifyFailure("升桌失敗：Device disconnected"),
    ])
    #expect(coordinator.phase == .idle)
}

@Test func lowerRunsAfterTheDelayWhenUntouched() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    raise(&coordinator)
    #expect(coordinator.handle(.tick, now: 899) == [])
    #expect(coordinator.handle(.tick, now: 900) == [.run(.status)])
    #expect(coordinator.handle(.status(DeskStatus(heightMm: 955, memoryMm: memory)), now: 901) == [.run(.goto(mm: 935))])
    _ = coordinator.handle(.gotoFinished(heightMm: 935), now: 902)
    _ = coordinator.handle(.watchSample(heightMm: 935), now: 903)
    #expect(coordinator.handle(.watchFinished, now: 912) == [.run(.goto(mm: 631))])
    #expect(coordinator.handle(.gotoFinished(heightMm: 631), now: 920) == [.note("lowered")])
    #expect(coordinator.lowerDue == nil)
}

@Test func lowerIsSkippedWhenAdjustedByHand() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    raise(&coordinator)
    _ = coordinator.handle(.tick, now: 900)
    #expect(coordinator.handle(.status(DeskStatus(heightMm: 900, memoryMm: memory)), now: 901) == [
        .note("lower-skipped-adjusted-by-hand"),
    ])
}

@Test func lockingAbortsAMoveAndDropsTheScheduledLower() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    raise(&coordinator)
    #expect(coordinator.handle(.screenLocked, now: 10) == [.note("lower-dropped-screen-locked")])
    #expect(coordinator.handle(.tick, now: 2000) == [])

    _ = coordinator.handle(.raiseRequested, now: 2000)
    _ = coordinator.handle(sitting(), now: 2000)
    #expect(coordinator.handle(.screenLocked, now: 2001) == [.cancelCommand, .note("aborted-screen-locked")])
    #expect(coordinator.handle(.gotoFinished(heightMm: 651), now: 2002) == [])
}

@Test func raiseRequestWhileBusyIsSkipped() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested, now: 0)
    #expect(coordinator.handle(.raiseRequested, now: 1) == [.note("raise-skipped-busy")])
}

@Test func windowWithoutAnySampleFails() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested, now: 0)
    _ = coordinator.handle(sitting(), now: 0)
    _ = coordinator.handle(.gotoFinished(heightMm: 651), now: 0)
    #expect(coordinator.handle(.watchFinished, now: 10) == [
        .note("raise-failed"), .notifyFailure("升桌失敗：no height during the cancel window"),
    ])
}

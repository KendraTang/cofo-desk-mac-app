import Testing
@testable import TimerDeskCore

private let memory = ["M1": 959, "M2": 631]

private func sitting(_ height: Int = 631) -> CoordinatorInput {
    .status(DeskStatus(heightMm: height, memoryMm: memory))
}

@Test func raiseJogsWaitsThenMovesToStand() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    #expect(coordinator.handle(.raiseRequested) == [.run(.status)])
    #expect(coordinator.handle(sitting()) == [.run(.goto(mm: 641))])
    #expect(coordinator.handle(.gotoFinished(heightMm: 641)) == [.run(.watch(seconds: 3))])
    #expect(coordinator.handle(.watchSample(heightMm: 641)) == [])
    #expect(coordinator.handle(.watchSample(heightMm: 643)) == [])
    #expect(coordinator.handle(.watchFinished) == [.run(.goto(mm: 959))])
    #expect(coordinator.handle(.gotoFinished(heightMm: 959)) == [.note("raised"), .finished(.moved(heightMm: 959))])
    #expect(coordinator.phase == .idle)
}

@Test func lowerJogsWaitsThenMovesToSit() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    #expect(coordinator.handle(.lowerRequested) == [.run(.status)])
    #expect(coordinator.handle(sitting(958)) == [.run(.goto(mm: 948))])
    _ = coordinator.handle(.gotoFinished(heightMm: 948))
    _ = coordinator.handle(.watchSample(heightMm: 948))
    #expect(coordinator.handle(.watchFinished) == [.run(.goto(mm: 631))])
    #expect(coordinator.handle(.gotoFinished(heightMm: 631)) == [.note("lowered"), .finished(.moved(heightMm: 631))])
}

@Test func panelPressDuringWindowCancelsTheMove() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested)
    _ = coordinator.handle(sitting())
    _ = coordinator.handle(.gotoFinished(heightMm: 641))
    _ = coordinator.handle(.watchSample(heightMm: 641))
    #expect(coordinator.handle(.watchSample(heightMm: 630)) == [
        .cancelCommand, .note("raise-cancelled-by-panel"), .finished(.cancelled),
    ])
    // The cancelled watch's own result arrives afterwards and is ignored.
    #expect(coordinator.handle(.commandFailed("Interrupted by SIGTERM")) == [])
    #expect(coordinator.handle(.watchFinished) == [])
}

/// The real-desk miss on 2026-10-21: M2 pressed before the first watch sample arrived.
@Test func panelPressBeforeTheFirstSampleStillCancels() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested)
    _ = coordinator.handle(sitting())
    _ = coordinator.handle(.gotoFinished(heightMm: 641))
    #expect(coordinator.handle(.watchSample(heightMm: 631)) == [
        .cancelCommand, .note("raise-cancelled-by-panel"), .finished(.cancelled),
    ])
}

@Test func alreadyAtTheTargetSkipsTheMove() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested)
    #expect(coordinator.handle(sitting(950)) == [.note("raise-skipped-already-standing"), .finished(.skipped)])
    _ = coordinator.handle(.lowerRequested)
    #expect(coordinator.handle(sitting(640)) == [.note("lower-skipped-already-sitting"), .finished(.skipped)])
    #expect(coordinator.phase == .idle)
}

@Test func missingMemoryHeightFailsWithANotification() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested)
    #expect(coordinator.handle(.status(DeskStatus(heightMm: 631, memoryMm: [:]))) == [
        .note("raise-failed"), .notifyFailure("升桌失敗：M1 memory height is not set"), .finished(.failed),
    ])
}

@Test func commandFailureNotifiesAndReturnsToIdle() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested)
    #expect(coordinator.handle(.commandFailed("Device disconnected")) == [
        .note("raise-failed"), .notifyFailure("升桌失敗：Device disconnected"), .finished(.failed),
    ])
    #expect(coordinator.phase == .idle)
}

@Test func aMoveThatStopsShortNamesThePanel() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested)
    _ = coordinator.handle(sitting())
    _ = coordinator.handle(.gotoFinished(heightMm: 641))
    _ = coordinator.handle(.watchSample(heightMm: 641))
    _ = coordinator.handle(.watchFinished)
    #expect(coordinator.handle(.commandFailed("Height telemetry is stale; movement stopped")) == [
        .note("raise-failed"),
        .notifyFailure("升桌失敗：沒有到達 M1，可能按了面板鍵（Height telemetry is stale; movement stopped）"),
        .finished(.failed),
    ])
}

@Test func lockingAbortsAMove() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    #expect(coordinator.handle(.screenLocked) == [])
    _ = coordinator.handle(.raiseRequested)
    _ = coordinator.handle(sitting())
    #expect(coordinator.handle(.screenLocked) == [.cancelCommand, .note("aborted-screen-locked"), .finished(.aborted)])
    #expect(coordinator.handle(.gotoFinished(heightMm: 641)) == [])
}

@Test func moveRequestWhileBusyIsSkipped() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested)
    #expect(coordinator.handle(.lowerRequested) == [.note("move-skipped-busy")])
}

@Test func windowWithoutAnySampleFails() {
    var coordinator = DeskCoordinator(settings: DeskSettings())
    _ = coordinator.handle(.raiseRequested)
    _ = coordinator.handle(sitting())
    _ = coordinator.handle(.gotoFinished(heightMm: 641))
    #expect(coordinator.handle(.watchFinished) == [
        .note("raise-failed"), .notifyFailure("升桌失敗：no height during the cancel window"), .finished(.failed),
    ])
}

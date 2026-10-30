import Testing
@testable import TimerDeskCore

private let active = Presence(inputIdleSeconds: 0, videoPlaying: false, locked: false)

private func idle(_ seconds: Double, video: Bool = false) -> Presence {
    Presence(inputIdleSeconds: seconds, videoPlaying: video, locked: false)
}

private func connected(height: Int = 631) -> PostureCycle {
    var cycle = PostureCycle(settings: CycleSettings())
    _ = cycle.deskConnected(heightMm: height, standMm: 959, sitMm: 631)
    return cycle
}

/// Ticks once a second from `start`, returning the outputs other than notes.
private func run(_ cycle: inout PostureCycle, from start: Double, to end: Double,
                 presence: (Double) -> Presence = { _ in active }) -> [CycleOutput] {
    var outputs: [CycleOutput] = []
    var now = start
    while now <= end {
        outputs += cycle.tick(now: now, presence: presence(now)).filter {
            if case .note = $0 { return false }
            return true
        }
        now += 1
    }
    return outputs
}

@Test func sittingRaisesAfterTheSitCountdownThenStandingLowers() {
    var cycle = connected()
    #expect(cycle.display(now: 0) == .counting(.sitting, remaining: 1500))
    #expect(run(&cycle, from: 0, to: 1499) == [])
    #expect(run(&cycle, from: 1500, to: 1500) == [.raise])
    #expect(cycle.display(now: 1500) == .moving(.sitting))
    #expect(run(&cycle, from: 1501, to: 1510) == [])
    #expect(cycle.moveFinished(.moved(heightMm: 959)) == [.note("stand-countdown-started")])
    #expect(cycle.display(now: 1510) == .counting(.standing, remaining: 600))
    #expect(run(&cycle, from: 1511, to: 2110) == [.lower])
}

@Test func crossingTheMidpointByHandStartsTheOtherCountdown() {
    var cycle = connected()
    _ = run(&cycle, from: 0, to: 100)
    #expect(cycle.heightChanged(mm: 700) == [])
    #expect(cycle.display(now: 100) == .counting(.sitting, remaining: 1400))
    #expect(cycle.heightChanged(mm: 900) == [.note("stand-countdown-started")])
    #expect(cycle.display(now: 100) == .counting(.standing, remaining: 600))
}

@Test func anAdjustedStandingHeightStillLowers() {
    var cycle = connected(height: 959)
    _ = cycle.heightChanged(mm: 940)
    #expect(run(&cycle, from: 0, to: 600) == [.lower])
}

@Test func cancelAndFailureSnoozeInTheSamePosture() {
    for outcome in [MoveOutcome.cancelled, .failed, .aborted] {
        var cycle = connected()
        cycle.expire()
        _ = run(&cycle, from: 0, to: 1)
        #expect(cycle.moveFinished(outcome) == [.note("snoozed")])
        #expect(cycle.display(now: 1) == .counting(.sitting, remaining: 600))
    }
}

@Test func aCancelThatMovedAcrossTheMidpointStartsTheNewPosture() {
    var cycle = connected()
    cycle.expire()
    _ = run(&cycle, from: 0, to: 1)
    #expect(cycle.heightChanged(mm: 959) == [])
    #expect(cycle.moveFinished(.cancelled) == [.note("stand-countdown-started")])
}

@Test func theCountdownRunsForFiveIdleMinutesThenPauses() {
    var cycle = connected()
    _ = cycle.tick(now: 0, presence: active)
    _ = run(&cycle, from: 1, to: 300) { idle($0) }
    #expect(cycle.display(now: 300) == .counting(.sitting, remaining: 1200))
    _ = run(&cycle, from: 301, to: 400) { idle($0) }
    #expect(cycle.display(now: 400) == .away(.sitting, remaining: 1200))
}

@Test func aShortAbsenceResumesAndALongOneRestarts() {
    var short = connected()
    _ = short.tick(now: 0, presence: active)
    _ = run(&short, from: 1, to: 400) { idle($0) }     // 400 s since the last input
    _ = short.tick(now: 401, presence: active)
    #expect(short.display(now: 401) == .counting(.sitting, remaining: 1199))

    var long = connected()
    _ = long.tick(now: 0, presence: active)
    _ = run(&long, from: 1, to: 899) { idle($0) }
    #expect(long.tick(now: 900, presence: active).contains(.note("back-after-long-away")))
    #expect(long.display(now: 900) == .counting(.sitting, remaining: 1500))
}

@Test func absencesAddUpWithinOneCountdown() {
    var cycle = connected()
    var now = 0.0
    _ = cycle.tick(now: now, presence: active)
    for _ in 0..<2 {
        let start = now
        _ = run(&cycle, from: now + 1, to: now + 500) { idle($0 - start) }
        now += 501
        _ = cycle.tick(now: now, presence: active)
    }
    #expect(cycle.display(now: now) == .counting(.sitting, remaining: 1500))
}

@Test func lockingCountsAsAwayAtOnce() {
    var cycle = connected()
    _ = cycle.tick(now: 0, presence: active)
    let locked = Presence(inputIdleSeconds: 0, videoPlaying: false, locked: true)
    #expect(cycle.tick(now: 1, presence: locked) == [.note("away")])
    #expect(cycle.display(now: 1) == .away(.sitting, remaining: 1500))
    #expect(run(&cycle, from: 2, to: 1000) { _ in locked } == [])
}

@Test func sleepingCountsAsAwayEvenIfTheLinkDropped() {
    var cycle = connected(height: 959)
    _ = cycle.tick(now: 0, presence: active)
    cycle.deskDisconnected()
    _ = cycle.tick(now: 8 * 3600, presence: active)
    _ = cycle.deskConnected(heightMm: 959, standMm: 959, sitMm: 631)
    #expect(cycle.tick(now: 8 * 3600 + 1, presence: active).contains(.note("back-after-long-away")))
    #expect(cycle.display(now: 8 * 3600 + 1) == .counting(.standing, remaining: 600))
}

@Test func aDueMoveWaitsForInput() {
    var cycle = connected()
    cycle.expire()
    _ = cycle.tick(now: 0, presence: idle(100))
    #expect(cycle.tick(now: 1, presence: idle(101)) == [])
    #expect(cycle.display(now: 1) == .waitingForUser(.sitting))
    #expect(cycle.tick(now: 2, presence: active) == [.raise])
}

@Test func videoCountsAsInputUpToItsLimit() {
    var cycle = connected()
    cycle.expire()
    #expect(cycle.tick(now: 1000, presence: idle(1000, video: true)) == [.raise])

    var longVideo = connected()
    _ = longVideo.tick(now: 1800, presence: idle(1800, video: true))
    _ = longVideo.tick(now: 1801, presence: idle(1801, video: true))
    #expect(longVideo.display(now: 1801) == .counting(.sitting, remaining: 1499))
    _ = run(&longVideo, from: 1802, to: 2200) { idle($0, video: true) }
    #expect(longVideo.display(now: 2200) == .away(.sitting, remaining: 1200))
}

@Test func disconnectingFreezesTheCountdownAndReconnectingResumes() {
    var cycle = connected()
    _ = run(&cycle, from: 0, to: 100)
    cycle.deskDisconnected()
    #expect(cycle.display(now: 100) == .disconnected)
    _ = run(&cycle, from: 101, to: 200)
    #expect(cycle.deskConnected(heightMm: 631, standMm: 959, sitMm: 631) == [])
    _ = cycle.tick(now: 201, presence: active)
    #expect(cycle.display(now: 201) == .counting(.sitting, remaining: 1399))
}

@Test func missingMemoryHeightsShowAsNotConfigured() {
    var cycle = PostureCycle(settings: CycleSettings())
    _ = cycle.deskConnected(heightMm: 700, standMm: nil, sitMm: 631)
    #expect(cycle.display(now: 0) == .notConfigured)
    #expect(cycle.tick(now: 1, presence: active) == [])
}

@Test func pauseHoldsEverythingThenRestartsTheCountdown() {
    var cycle = connected()
    cycle.expire()
    _ = cycle.pause(now: 0)
    #expect(cycle.display(now: 10) == .paused(remaining: 3590))
    #expect(run(&cycle, from: 0, to: 3599) == [])
    #expect(cycle.clockCompleted() == [.note("clock-ignored")])
    #expect(cycle.tick(now: 3600, presence: active).contains(.note("pause-ended")))
    #expect(cycle.display(now: 3600) == .counting(.sitting, remaining: 1500))
}

@Test func restartBeginsTheCountdownAgainAndEndsAPause() {
    var cycle = connected()
    _ = run(&cycle, from: 0, to: 100)
    _ = cycle.pause(now: 100)
    #expect(cycle.restart() == [.note("sit-countdown-started")])
    #expect(cycle.display(now: 100) == .counting(.sitting, remaining: 1500))
}

@Test func aClockTimerEndsTheSitCountdownOnly() {
    var sitting = connected()
    _ = sitting.tick(now: 0, presence: active)
    #expect(sitting.clockCompleted() == [.note("clock-completed-sit-countdown")])
    #expect(sitting.tick(now: 1, presence: active) == [.raise])

    var standing = connected(height: 959)
    #expect(standing.clockCompleted() == [.note("clock-ignored")])
    #expect(standing.display(now: 0) == .counting(.standing, remaining: 600))
}

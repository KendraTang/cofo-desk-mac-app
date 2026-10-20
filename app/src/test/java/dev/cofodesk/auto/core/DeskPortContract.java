package dev.cofodesk.auto.core;

import org.junit.Before;
import org.junit.Test;
import static org.junit.Assert.*;

/** Behaviour every DeskPort must share; each transport adds a subclass. Speeds are not part of the contract. */
public abstract class DeskPortContract {
    protected DeskPort desk;
    protected abstract DeskPort create();
    /** Connects and makes travel limits known, as a transport would after its initial queries. */
    protected abstract TravelLimits connectWithLimits();
    protected abstract void injectFault();
    @Before public void createPort() { desk = create(); }

    @Test public void disconnectedPortRefusesMovementAndHasNoLimits() {
        assertThrows(IllegalStateException.class, () -> desk.moveTo(desk.state().heightMm()));
        assertThrows(IllegalStateException.class, () -> desk.startMove(DeskPort.Direction.UP));
        assertFalse(desk.state().moving()); assertFalse(desk.state().limits().isPresent());
    }
    @Test public void directionsRunToTheReportedLimits() {
        TravelLimits limits = connectWithLimits();
        assertEquals(limits, desk.state().limits().orElseThrow());
        desk.startMove(DeskPort.Direction.UP); desk.advance(100_000);
        assertEquals(limits.maxMm(), desk.state().heightMm()); assertFalse(desk.state().moving());
        desk.startMove(DeskPort.Direction.DOWN); desk.advance(100_000);
        assertEquals(limits.minMm(), desk.state().heightMm());
    }
    @Test public void targetsOutsideTheLimitsAreRefused() {
        TravelLimits limits = connectWithLimits();
        assertThrows(IllegalArgumentException.class, () -> desk.moveTo(limits.minMm() - 1));
        assertThrows(IllegalArgumentException.class, () -> desk.moveTo(limits.maxMm() + 1));
        assertFalse(desk.state().moving());
    }
    @Test public void stopHoldsPositionAndReconnectDoesNotResume() {
        connectWithLimits();
        desk.startMove(DeskPort.Direction.UP); desk.advance(500); desk.stop();
        int height = desk.state().heightMm(); desk.advance(1000);
        assertEquals(height, desk.state().heightMm());
        desk.startMove(DeskPort.Direction.UP); desk.disconnect(); desk.connect(); desk.advance(1000);
        assertFalse(desk.state().moving()); assertEquals(height, desk.state().heightMm());
    }
    @Test public void lockAndFaultStopAndRefuseMovement() {
        connectWithLimits();
        desk.startMove(DeskPort.Direction.UP); desk.setLocked(true);
        assertFalse(desk.state().moving());
        assertThrows(IllegalStateException.class, () -> desk.startMove(DeskPort.Direction.DOWN));
        desk.setLocked(false); desk.startMove(DeskPort.Direction.UP); injectFault();
        assertFalse(desk.state().moving()); assertFalse(desk.state().fault().isEmpty());
        assertThrows(IllegalStateException.class, () -> desk.startMove(DeskPort.Direction.DOWN));
    }
}

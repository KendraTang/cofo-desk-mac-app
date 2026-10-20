package dev.cofodesk.auto.core;

import org.junit.Test;
import static org.junit.Assert.*;

public class ScriptedDeskContractTest extends DeskPortContract {
    private static final TravelLimits LIMITS = new TravelLimits(600, 1200);
    @Override protected DeskPort create() { return new ScriptedDesk(); }
    @Override protected TravelLimits connectWithLimits() { desk.connect(); ((ScriptedDesk) desk).reportLimits(LIMITS); return LIMITS; }
    @Override protected void injectFault() { ((ScriptedDesk) desk).reportFault("E01"); }

    @Test public void connectedWithoutReportedLimitsRefusesMovement() {
        desk.connect();
        assertFalse(desk.state().limits().isPresent());
        IllegalStateException refused = assertThrows(IllegalStateException.class, () -> desk.startMove(DeskPort.Direction.UP));
        assertEquals("error_limits_unknown", refused.getMessage());
        assertThrows(IllegalStateException.class, () -> desk.moveTo(900));
    }
    @Test public void newlyReportedLimitsReplaceOldOnes() {
        connectWithLimits();
        ((ScriptedDesk) desk).reportLimits(new TravelLimits(700, 1000));
        assertThrows(IllegalArgumentException.class, () -> desk.moveTo(1100));
        desk.startMove(DeskPort.Direction.UP); desk.advance(100_000);
        assertEquals(1000, desk.state().heightMm());
    }
    @Test public void sessionUsesTheDesksLimitsNotTheSimulators() {
        DeskSession session = new DeskSession(desk);
        connectWithLimits();
        session.jog(true); desk.advance(100_000);
        assertEquals(1200, session.state().heightMm());
        session.nudge(true); desk.advance(1000);
        assertEquals(1200, session.state().heightMm());
        session.jog(false); desk.advance(100_000); session.nudge(false); desk.advance(1000);
        assertEquals(600, session.state().heightMm());
    }
}

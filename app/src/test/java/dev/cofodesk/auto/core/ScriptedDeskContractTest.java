package dev.cofodesk.auto.core;

import org.junit.Test;
import static org.junit.Assert.*;

public class ScriptedDeskContractTest extends DeskPortContract {
    private static final TravelLimits LIMITS = new TravelLimits(600, 1200);
    @Override protected DeskPort create() { return new ScriptedDesk(); }
    @Override protected TravelLimits connectWithLimits() { desk.connect(); ((ScriptedDesk) desk).reportLimits(LIMITS); return LIMITS; }
    @Override protected void injectFault() { ((ScriptedDesk) desk).reportFault(Fault.device("E01")); }

    @Test public void connectedWithoutReportedLimitsRefusesMovement() {
        desk.connect();
        assertFalse(desk.state().limits().isPresent());
        assertEquals(Refused.Reason.LIMITS_UNKNOWN, assertThrows(Refused.class, () -> desk.startMove(DeskPort.Direction.UP)).reason());
        assertEquals(Refused.Reason.LIMITS_UNKNOWN, assertThrows(Refused.class, () -> desk.moveTo(900)).reason());
    }
    @Test public void newlyReportedLimitsReplaceOldOnes() {
        connectWithLimits();
        ((ScriptedDesk) desk).reportLimits(new TravelLimits(700, 1000));
        assertEquals(Refused.Reason.HEIGHT, assertThrows(Refused.class, () -> desk.moveTo(1100)).reason());
        desk.startMove(DeskPort.Direction.UP); desk.advance(100_000);
        assertEquals(1000, desk.state().heightMm());
    }
    @Test public void unknownDeviceFaultIsKeptAndBlocksMovement() {
        connectWithLimits();
        ((ScriptedDesk) desk).reportFault(Fault.unknown("0x11"));
        assertEquals(new Fault(Fault.Kind.UNKNOWN, "0x11"), desk.state().fault());
        assertTrue(desk.state().fault().present());
        assertEquals(Refused.Reason.FAULT, assertThrows(Refused.class, () -> desk.moveTo(900)).reason());
    }
    @Test public void faultCodesMustMatchTheirKind() {
        assertFalse(Fault.NONE.present());
        assertThrows(IllegalArgumentException.class, () -> Fault.device(""));
        assertThrows(IllegalArgumentException.class, () -> new Fault(Fault.Kind.NONE, "E01"));
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

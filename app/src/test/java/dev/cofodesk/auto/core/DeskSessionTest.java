package dev.cofodesk.auto.core;

import org.junit.Before;
import org.junit.Test;
import java.util.Properties;
import static org.junit.Assert.*;

public class DeskSessionTest {
    private SimulatedDesk desk;
    private DeskSession app;
    @Before public void setup() { desk = new SimulatedDesk(); app = new DeskSession(desk); }
    @Test public void disconnectedCannotMove() {
        assertThrows(IllegalStateException.class, () -> app.jog(true));
        assertFalse(app.state().moving());
    }
    @Test public void movesAtSpecifiedSpeedAndStopsAtTarget() {
        app.connect(); app.moveTo(1050); app.advanceForeground(1000, 1000);
        assertEquals(755, app.state().heightMm()); assertTrue(app.state().moving());
        app.advanceForeground(20_000, 21_000);
        assertEquals(1050, app.state().heightMm()); assertFalse(app.state().moving());
    }
    @Test public void stopsDoNotResumeOnReconnectOrAdvance() {
        app.connect(); app.jog(true); desk.advance(500); app.stop();
        int height = app.state().heightMm(); desk.advance(1000); assertEquals(height, app.state().heightMm());
        app.jog(true); app.disconnect(); app.connect(); desk.advance(1000);
        assertFalse(app.state().moving()); assertEquals(height, app.state().heightMm());
    }
    @Test public void reversingDirectionReplacesOldCommand() {
        app.connect(); app.jog(true); desk.advance(1000); app.jog(false); desk.advance(1000);
        assertEquals(720, app.state().heightMm());
    }
    @Test public void limitsRejectInvalidTargetsAndClampJog() {
        app.connect();
        assertThrows(IllegalArgumentException.class, () -> app.moveTo(629));
        assertThrows(IllegalArgumentException.class, () -> app.moveTo(1281));
        app.jog(true); desk.advance(100_000); assertEquals(1280, app.state().heightMm());
        app.jog(false); desk.advance(100_000); assertEquals(630, app.state().heightMm());
    }
    @Test public void collisionAndLockStopAndBlockMovement() {
        app.connect(); app.jog(true); desk.advance(1000); desk.collide();
        int height = app.state().heightMm(); assertFalse(app.state().moving());
        assertThrows(IllegalStateException.class, () -> app.recall(1));
        desk.clearFault(); app.jog(true); app.lock(true); desk.advance(1000);
        assertEquals(height, app.state().heightMm());
        assertThrows(IllegalStateException.class, () -> app.jog(false));
        app.lock(false); app.jog(true); assertTrue(app.state().moving());
    }
    @Test public void pauseStopsMotorAndNeverAutoResumes() {
        app.connect(); app.recall(1); app.pause(); desk.advance(20_000);
        assertEquals(720, app.state().heightMm()); assertFalse(app.state().moving());
    }
    @Test public void presetsRequireStationaryConnectionAndPersist() {
        assertThrows(IllegalStateException.class, () -> app.savePreset(0));
        app.connect(); app.moveTo(900);
        assertThrows(IllegalStateException.class, () -> app.savePreset(0));
        desk.advance(20_000); app.savePreset(0); assertEquals(900, app.preset(0));
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(app.save());
        assertEquals(900, next.preset(0)); assertFalse(next.state().connected());
        assertThrows(IllegalArgumentException.class, () -> app.recall(3));
    }
    @Test public void profileUnitsAndValidation() {
        app.setProfile(180, 70.5, 1000, true);
        assertEquals("39.4 in", app.height(1000));
        assertThrows(IllegalArgumentException.class, () -> app.setProfile(180, Double.NaN, 1000, true));
        assertThrows(IllegalArgumentException.class, () -> app.setProfile(20, 70, 1000, true));
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(app.save());
        assertEquals(70.5, next.weightKg(), .001); assertEquals(180, next.bodyHeightCm());
        assertEquals(1000, next.standingThresholdMm()); assertTrue(next.inches());
    }
    @Test public void statisticsOnlyCountConnectedStandingTime() {
        app.advanceForeground(1000, 1000); assertEquals(0, app.connectedMs());
        app.connect(); app.advanceForeground(1000, 2000); assertEquals(0, app.standingMs());
        app.moveTo(1050); desk.advance(20_000);
        app.advanceForeground(60_000, 62_000);
        assertEquals(60_000, app.standingMs()); assertEquals(61_000, app.connectedMs());
        assertEquals(2.0, app.estimatedKcal(), .0001);
        assertEquals(60_000, app.history().total(ActivityHistory.Period.DAY, 62_000));
        app.disconnect(); app.advanceForeground(1000, 63_000); assertEquals(60_000, app.standingMs());
    }
    @Test public void thresholdCrossingDoesNotCountWholeMovementAsStanding() {
        app.connect(); app.moveTo(1050); app.advanceForeground(7000, 7000);
        assertTrue(app.standingMs() >= 300 && app.standingMs() <= 500);
    }
    @Test public void countdownDeadlineSurvivesRestoreAndFiresOnlyOnce() {
        app.startReminder(1, 1000);
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(app.save());
        assertEquals(1000, next.reminderRemainingMs(60_000));
        next.reconcileReminder(61_000); assertTrue(next.reminderDue()); assertEquals(0, next.reminderAtMs());
        next.cancelReminder(); next.reconcileReminder(70_000); assertFalse(next.reminderDue());
        assertThrows(IllegalArgumentException.class, () -> app.startReminder(0, 0));
    }
    @Test public void cancelAndRestartReplaceDeadline() {
        app.startReminder(1, 0); app.startReminder(2, 0); app.reconcileReminder(60_000); assertFalse(app.reminderDue());
        app.cancelReminder(); assertEquals(0, app.reminderAtMs());
    }
    @Test public void sittingReminderFiresOnceAndPauseResetsContinuousTime() {
        app.configureGoals(60, 1, 1); app.connect(); app.advanceForeground(59_000, 59_000);
        assertEquals("", app.takeAlert()); app.pause(); app.advanceForeground(2000, 61_000); assertEquals("", app.takeAlert());
        app.advanceForeground(58_000, 119_000); assertTrue(app.takeAlert().equals("alert_sitting"));
        app.advanceForeground(60_000, 179_000); assertEquals("", app.takeAlert());
    }
    @Test public void standingGoalAndReminderPersistAndCanBeDisabled() {
        app.configureGoals(1, 0, 0); app.connect(); app.moveTo(1050); desk.advance(20_000);
        long noon = java.time.LocalDate.of(2026, 10, 20).atTime(12, 0).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli();
        app.advanceForeground(60_000, noon); assertTrue(app.takeAlert().equals("alert_goal"));
        app.advanceForeground(60_000, noon + 60_000); assertEquals("", app.takeAlert());
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(app.save());
        assertEquals(1, next.dailyGoalMinutes()); assertEquals(0, next.standingReminderMinutes()); assertEquals(120_000, next.standingMs());
    }
    @Test public void standingReminderResetsWhenPostureChanges() {
        app.configureGoals(120, 0, 1); app.connect(); app.moveTo(1050); desk.advance(20_000);
        app.advanceForeground(60_000, 60_000); assertTrue(app.takeAlert().equals("alert_standing"));
        app.advanceForeground(60_000, 120_000); assertEquals("", app.takeAlert());
        app.moveTo(720); desk.advance(20_000); app.advanceForeground(1000, 121_000);
        app.moveTo(1050); desk.advance(20_000); app.advanceForeground(60_000, 181_000);
        assertTrue(app.takeAlert().equals("alert_standing"));
    }
    @Test public void corruptPreferencesRecoverWithoutDiscardingValidFields() {
        Properties p = new Properties(); p.setProperty("weightKg", "NaN"); p.setProperty("preset0", "99999");
        p.setProperty("heightCm", "180"); p.setProperty("standingMs", "-1"); p.setProperty("threshold", "bad");
        p.setProperty("day.invalid", "NaN"); app.restore(p);
        assertEquals(65, app.weightKg(), 0); assertEquals(720, app.preset(0)); assertEquals(180, app.bodyHeightCm());
        assertEquals(0, app.standingMs()); assertEquals(950, app.standingThresholdMm());
    }
}

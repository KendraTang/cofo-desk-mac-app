package dev.cofodesk.auto.core;

import org.junit.Before;
import org.junit.Test;
import java.util.OptionalDouble;
import java.util.OptionalInt;
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
        app.nudge(true); desk.advance(1000); assertEquals(1280, app.state().heightMm());
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
        app.setProfile(OptionalInt.of(180), OptionalDouble.of(70.5), 1000, true);
        assertEquals("39.4 in", app.height(1000));
        assertThrows(IllegalArgumentException.class, () -> app.setProfile(OptionalInt.of(180), OptionalDouble.of(Double.NaN), 1000, true));
        assertThrows(IllegalArgumentException.class, () -> app.setProfile(OptionalInt.of(20), OptionalDouble.of(70), 1000, true));
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(app.save());
        assertEquals(70.5, next.weightKg().getAsDouble(), .001); assertEquals(180, next.bodyHeightCm().getAsInt());
        assertEquals(1000, next.standingThresholdMm()); assertTrue(next.inches());
    }
    @Test public void newProfileIsEmptyAndCaloriesStayZeroWithoutWeight() {
        assertFalse(app.bodyHeightCm().isPresent()); assertFalse(app.weightKg().isPresent());
        app.connect(); app.moveTo(1050); desk.advance(20_000); app.advanceForeground(60_000, 60_000);
        assertEquals(0, app.estimatedKcal(), 0);
        app.setProfile(OptionalInt.empty(), OptionalDouble.empty(), 950, false);
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(app.save());
        assertFalse(next.bodyHeightCm().isPresent()); assertFalse(next.weightKg().isPresent());
    }
    @Test public void legacyStoredDefaultsAreKept() {
        Properties p = new Properties(); p.setProperty("heightCm", "170"); p.setProperty("weightKg", "65.0");
        p.setProperty("goal", "60"); p.setProperty("sitReminder", "40"); p.setProperty("standReminder", "60");
        app.restore(p);
        assertEquals(170, app.bodyHeightCm().getAsInt()); assertEquals(65, app.weightKg().getAsDouble(), 0);
        assertEquals(60, app.dailyGoalMinutes()); assertEquals(40, app.sittingReminderMinutes());
    }
    @Test public void goalsAndRemindersDefaultToZeroAndAcceptTheOriginalRange() {
        assertEquals(0, app.dailyGoalMinutes()); assertEquals(0, app.sittingReminderMinutes()); assertEquals(0, app.standingReminderMinutes());
        app.configureGoals(0, 0, 0);
        app.configureGoals(24 * 60, 24 * 60, 24 * 60);
        app.configureGoals(1490, 1490, 1490);
        assertEquals(1490, app.dailyGoalMinutes());
        assertThrows(IllegalArgumentException.class, () -> app.configureGoals(1500, 0, 0));
        assertThrows(IllegalArgumentException.class, () -> app.configureGoals(-10, 0, 0));
        assertThrows(IllegalArgumentException.class, () -> app.configureGoals(0, 15, 0));
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(app.save());
        assertEquals(1490, next.standingReminderMinutes());
    }
    @Test public void legacyOffStepValueIsKeptButNewChoicesUseTenMinuteSteps() {
        Properties p = new Properties(); p.setProperty("goal", "45"); p.setProperty("sitReminder", "25");
        app.restore(p);
        assertEquals(45, app.dailyGoalMinutes());
        app.configureGoals(45, 25, 30);
        assertEquals(25, app.sittingReminderMinutes());
        assertThrows(IllegalArgumentException.class, () -> app.configureGoals(55, 25, 30));
    }
    @Test public void goalPercentUsesTheOriginalIntegerRule() {
        long noon = java.time.LocalDate.of(2026, 10, 20).atTime(12, 0).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli();
        assertFalse(app.goalPercent(noon).isPresent());
        app.configureGoals(60, 0, 0);
        assertEquals(0, app.goalPercent(noon).getAsInt());
        app.history().add(noon, noon + 59_999);
        assertEquals(0, app.goalPercent(noon + 60_000).getAsInt());
        app.history().add(noon + 59_999, noon + 60_000);
        assertEquals(1, app.goalPercent(noon + 60_000).getAsInt());
        app.history().add(noon + 60_000, noon + 3_600_000);
        assertEquals(100, app.goalPercent(noon + 3_600_000).getAsInt());
        app.history().add(noon + 3_600_000, noon + 7_200_000);
        assertEquals(100, app.goalPercent(noon + 7_200_000).getAsInt());
        app.configureGoals(70, 0, 0);
        app.history().clear(); app.history().add(noon, noon + 61 * 60_000);
        assertEquals(87, app.goalPercent(noon + 61 * 60_000).getAsInt());
    }
    @Test public void zeroGoalNeverRaisesTheGoalAlert() {
        app.connect(); app.moveTo(1050); desk.advance(20_000);
        app.advanceForeground(120_000, 120_000);
        assertEquals("", app.takeAlert());
    }
    @Test public void simulatorRestoresOnlyAStoppedDisconnectedPosition() {
        SimulatedDesk restored = new SimulatedDesk(); restored.restore(1000);
        assertEquals(1000, restored.state().heightMm());
        assertFalse(restored.state().connected()); assertFalse(restored.state().moving());
        assertFalse(restored.state().locked()); assertEquals("", restored.state().fault());
        restored.connect(); assertFalse(restored.state().moving());
        assertThrows(IllegalStateException.class, () -> restored.restore(900));
        SimulatedDesk invalid = new SimulatedDesk(); invalid.restore(5000);
        assertEquals(720, invalid.state().heightMm());
    }
    @Test public void statisticsOnlyCountConnectedStandingTime() {
        app.setProfile(OptionalInt.empty(), OptionalDouble.of(65), 950, false);
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
        app.configureGoals(60, 10, 10); app.connect(); app.advanceForeground(599_000, 599_000);
        assertEquals("", app.takeAlert()); app.pause(); app.advanceForeground(2000, 601_000); assertEquals("", app.takeAlert());
        app.advanceForeground(598_000, 1_199_000); assertTrue(app.takeAlert().equals("alert_sitting"));
        app.advanceForeground(600_000, 1_799_000); assertEquals("", app.takeAlert());
    }
    @Test public void standingGoalAndReminderPersistAndCanBeDisabled() {
        app.configureGoals(10, 0, 0); app.connect(); app.moveTo(1050); desk.advance(20_000);
        long noon = java.time.LocalDate.of(2026, 10, 20).atTime(12, 0).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli();
        app.advanceForeground(600_000, noon); assertTrue(app.takeAlert().equals("alert_goal"));
        app.advanceForeground(60_000, noon + 60_000); assertEquals("", app.takeAlert());
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(app.save());
        assertEquals(10, next.dailyGoalMinutes()); assertEquals(0, next.standingReminderMinutes()); assertEquals(660_000, next.standingMs());
    }
    @Test public void standingReminderResetsWhenPostureChanges() {
        app.configureGoals(120, 0, 10); app.connect(); app.moveTo(1050); desk.advance(20_000);
        app.advanceForeground(600_000, 600_000); assertTrue(app.takeAlert().equals("alert_standing"));
        app.advanceForeground(600_000, 1_200_000); assertEquals("", app.takeAlert());
        app.moveTo(720); desk.advance(20_000); app.advanceForeground(1000, 1_201_000);
        app.moveTo(1050); desk.advance(20_000); app.advanceForeground(600_000, 1_801_000);
        assertTrue(app.takeAlert().equals("alert_standing"));
    }
    @Test public void corruptPreferencesRecoverWithoutDiscardingValidFields() {
        Properties p = new Properties(); p.setProperty("weightKg", "NaN"); p.setProperty("preset0", "99999");
        p.setProperty("heightCm", "180"); p.setProperty("standingMs", "-1"); p.setProperty("threshold", "bad");
        p.setProperty("day.invalid", "NaN"); app.restore(p);
        assertFalse(app.weightKg().isPresent()); assertEquals(720, app.preset(0)); assertEquals(180, app.bodyHeightCm().getAsInt());
        assertEquals(0, app.standingMs()); assertEquals(950, app.standingThresholdMm());
    }
}

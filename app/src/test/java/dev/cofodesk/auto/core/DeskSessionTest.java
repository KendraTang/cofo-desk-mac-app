package dev.cofodesk.auto.core;

import org.junit.Before;
import org.junit.Test;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.Optional;
import java.util.OptionalDouble;
import java.util.OptionalInt;
import java.util.Properties;
import static org.junit.Assert.*;

public class DeskSessionTest {
    private SimulatedDesk desk;
    private DeskSession session;
    @Before public void setup() { desk = new SimulatedDesk(); session = new DeskSession(desk); }
    @Test public void disconnectedCannotMove() {
        assertEquals(Refused.Reason.NOT_CONNECTED, assertThrows(Refused.class, () -> session.jog(true)).reason());
        assertFalse(session.state().moving());
    }
    @Test public void movesAtSpecifiedSpeedAndStopsAtTarget() {
        session.connect(); session.moveTo(1050); session.advanceForeground(1000, 1000);
        assertEquals(755, session.state().heightMm()); assertTrue(session.state().moving());
        session.advanceForeground(20_000, 21_000);
        assertEquals(1050, session.state().heightMm()); assertFalse(session.state().moving());
    }
    @Test public void stopsDoNotResumeOnReconnectOrAdvance() {
        session.connect(); session.jog(true); desk.advance(500); session.stop();
        int height = session.state().heightMm(); desk.advance(1000); assertEquals(height, session.state().heightMm());
        session.jog(true); session.disconnect(); session.connect(); desk.advance(1000);
        assertFalse(session.state().moving()); assertEquals(height, session.state().heightMm());
    }
    @Test public void reversingDirectionReplacesOldCommand() {
        session.connect(); session.jog(true); desk.advance(1000); session.jog(false); desk.advance(1000);
        assertEquals(720, session.state().heightMm());
    }
    @Test public void limitsRejectInvalidTargetsAndClampJog() {
        session.connect();
        assertThrows(Refused.class, () -> session.moveTo(629));
        assertThrows(Refused.class, () -> session.moveTo(1281));
        session.jog(true); desk.advance(100_000); assertEquals(1280, session.state().heightMm());
        session.nudge(true); desk.advance(1000); assertEquals(1280, session.state().heightMm());
        session.jog(false); desk.advance(100_000); assertEquals(630, session.state().heightMm());
    }
    @Test public void collisionAndLockStopAndBlockMovement() {
        session.connect(); session.jog(true); desk.advance(1000); desk.collide();
        int height = session.state().heightMm(); assertFalse(session.state().moving());
        assertThrows(Refused.class, () -> session.recall(1));
        desk.clearFault(); session.jog(true); session.lock(true); desk.advance(1000);
        assertEquals(height, session.state().heightMm());
        assertThrows(Refused.class, () -> session.jog(false));
        session.lock(false); session.jog(true); assertTrue(session.state().moving());
    }
    @Test public void pauseStopsMotorAndNeverAutoResumes() {
        session.connect(); session.recall(1); session.pause(); desk.advance(20_000);
        assertEquals(720, session.state().heightMm()); assertFalse(session.state().moving());
    }
    @Test public void presetsRequireStationaryConnectionAndPersist() {
        assertThrows(Refused.class, () -> session.savePreset(0));
        session.connect(); session.moveTo(900);
        assertThrows(Refused.class, () -> session.savePreset(0));
        desk.advance(20_000); session.savePreset(0); assertEquals(900, session.preset(0));
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(session.save());
        assertEquals(900, next.preset(0)); assertFalse(next.state().connected());
        assertThrows(Refused.class, () -> session.recall(3));
    }
    @Test public void profileUnitsAndValidation() {
        session.setProfile(OptionalInt.of(180), OptionalDouble.of(70.5), 1000, true);
        assertEquals("39.4 in", session.height(1000));
        assertThrows(Refused.class, () -> session.setProfile(OptionalInt.of(180), OptionalDouble.of(Double.NaN), 1000, true));
        assertThrows(Refused.class, () -> session.setProfile(OptionalInt.of(20), OptionalDouble.of(70), 1000, true));
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(session.save());
        assertEquals(70.5, next.weightKg().getAsDouble(), .001); assertEquals(180, next.bodyHeightCm().getAsInt());
        assertEquals(1000, next.standingThresholdMm()); assertTrue(next.inches());
    }
    @Test public void newProfileIsEmptyAndCaloriesStayZeroWithoutWeight() {
        assertFalse(session.bodyHeightCm().isPresent()); assertFalse(session.weightKg().isPresent());
        session.connect(); session.moveTo(1050); desk.advance(20_000); session.advanceForeground(60_000, 60_000);
        assertEquals(0, session.estimatedKcal(), 0);
        session.setProfile(OptionalInt.empty(), OptionalDouble.empty(), 950, false);
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(session.save());
        assertFalse(next.bodyHeightCm().isPresent()); assertFalse(next.weightKg().isPresent());
    }
    @Test public void legacyStoredDefaultsAreKept() {
        Properties p = new Properties(); p.setProperty("heightCm", "170"); p.setProperty("weightKg", "65.0");
        p.setProperty("goal", "60"); p.setProperty("sitReminder", "40"); p.setProperty("standReminder", "60");
        session.restore(p);
        assertEquals(170, session.bodyHeightCm().getAsInt()); assertEquals(65, session.weightKg().getAsDouble(), 0);
        assertEquals(60, session.dailyGoalMinutes()); assertEquals(40, session.sittingReminderMinutes());
    }
    @Test public void goalsAndRemindersDefaultToZeroAndAcceptTheOriginalRange() {
        assertEquals(0, session.dailyGoalMinutes()); assertEquals(0, session.sittingReminderMinutes()); assertEquals(0, session.standingReminderMinutes());
        session.configureGoals(0, 0, 0);
        session.configureGoals(24 * 60, 24 * 60, 24 * 60);
        session.configureGoals(1490, 1490, 1490);
        assertEquals(1490, session.dailyGoalMinutes());
        assertThrows(Refused.class, () -> session.configureGoals(1500, 0, 0));
        assertThrows(Refused.class, () -> session.configureGoals(-10, 0, 0));
        assertThrows(Refused.class, () -> session.configureGoals(0, 15, 0));
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(session.save());
        assertEquals(1490, next.standingReminderMinutes());
    }
    @Test public void legacyOffStepValueIsKeptButNewChoicesUseTenMinuteSteps() {
        Properties p = new Properties(); p.setProperty("goal", "45"); p.setProperty("sitReminder", "25");
        session.restore(p);
        assertEquals(45, session.dailyGoalMinutes());
        session.configureGoals(45, 25, 30);
        assertEquals(25, session.sittingReminderMinutes());
        assertThrows(Refused.class, () -> session.configureGoals(55, 25, 30));
    }
    @Test public void goalPercentUsesTheOriginalIntegerRule() {
        long noon = LocalDate.of(2026, 10, 20).atTime(12, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli();
        assertFalse(session.goalPercent(noon).isPresent());
        session.configureGoals(60, 0, 0);
        assertEquals(0, session.goalPercent(noon).getAsInt());
        session.history().add(noon, noon + 59_999);
        assertEquals(0, session.goalPercent(noon + 60_000).getAsInt());
        session.history().add(noon + 59_999, noon + 60_000);
        assertEquals(1, session.goalPercent(noon + 60_000).getAsInt());
        session.history().add(noon + 60_000, noon + 3_600_000);
        assertEquals(100, session.goalPercent(noon + 3_600_000).getAsInt());
        session.history().add(noon + 3_600_000, noon + 7_200_000);
        assertEquals(100, session.goalPercent(noon + 7_200_000).getAsInt());
        session.configureGoals(70, 0, 0);
        session.history().clear(); session.history().add(noon, noon + 61 * 60_000);
        assertEquals(87, session.goalPercent(noon + 61 * 60_000).getAsInt());
    }
    @Test public void zeroGoalNeverRaisesTheGoalAlert() {
        session.connect(); session.moveTo(1050); desk.advance(20_000);
        session.advanceForeground(120_000, 120_000);
        assertEquals(Optional.empty(), session.takeAlert());
    }
    @Test public void simulatorRestoresOnlyAStoppedDisconnectedPosition() {
        SimulatedDesk restored = new SimulatedDesk(); restored.restore(1000);
        assertEquals(1000, restored.state().heightMm());
        assertFalse(restored.state().connected()); assertFalse(restored.state().moving());
        assertFalse(restored.state().locked()); assertEquals(Fault.NONE, restored.state().fault());
        restored.connect(); assertFalse(restored.state().moving());
        assertThrows(IllegalStateException.class, () -> restored.restore(900));
        SimulatedDesk invalid = new SimulatedDesk(); invalid.restore(5000);
        assertEquals(720, invalid.state().heightMm());
    }
    @Test public void statisticsOnlyCountConnectedStandingTime() {
        session.setProfile(OptionalInt.empty(), OptionalDouble.of(65), 950, false);
        session.advanceForeground(1000, 1000); assertEquals(0, session.connectedMs());
        session.connect(); session.advanceForeground(1000, 2000); assertEquals(0, session.standingMs());
        session.moveTo(1050); desk.advance(20_000);
        session.advanceForeground(60_000, 62_000);
        assertEquals(60_000, session.standingMs()); assertEquals(61_000, session.connectedMs());
        assertEquals(2.0, session.estimatedKcal(), .0001);
        assertEquals(60_000, session.history().total(ActivityHistory.Period.DAY, 62_000));
        session.disconnect(); session.advanceForeground(1000, 63_000); assertEquals(60_000, session.standingMs());
    }
    @Test public void thresholdCrossingDoesNotCountWholeMovementAsStanding() {
        session.connect(); session.moveTo(1050); session.advanceForeground(7000, 7000);
        assertTrue(session.standingMs() >= 300 && session.standingMs() <= 500);
    }
    @Test public void countdownDeadlineSurvivesRestoreAndFiresOnlyOnce() {
        session.startReminder(1, 1000);
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(session.save());
        assertEquals(1000, next.reminderRemainingMs(60_000));
        next.reconcileReminder(61_000); assertTrue(next.reminderDue()); assertEquals(0, next.reminderAtMs());
        next.cancelReminder(); next.reconcileReminder(70_000); assertFalse(next.reminderDue());
        assertThrows(Refused.class, () -> session.startReminder(0, 0));
    }
    @Test public void cancelAndRestartReplaceDeadline() {
        session.startReminder(1, 0); session.startReminder(2, 0); session.reconcileReminder(60_000); assertFalse(session.reminderDue());
        session.cancelReminder(); assertEquals(0, session.reminderAtMs());
    }
    @Test public void sittingReminderFiresOnceAndPauseResetsContinuousTime() {
        session.configureGoals(60, 10, 10); session.connect(); session.advanceForeground(599_000, 599_000);
        assertEquals(Optional.empty(), session.takeAlert()); session.pause(); session.advanceForeground(2000, 601_000); assertEquals(Optional.empty(), session.takeAlert());
        session.advanceForeground(598_000, 1_199_000); assertEquals(Optional.of(Alert.SITTING), session.takeAlert());
        session.advanceForeground(600_000, 1_799_000); assertEquals(Optional.empty(), session.takeAlert());
    }
    @Test public void standingGoalAndReminderPersistAndCanBeDisabled() {
        session.configureGoals(10, 0, 0); session.connect(); session.moveTo(1050); desk.advance(20_000);
        long noon = LocalDate.of(2026, 10, 20).atTime(12, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli();
        session.advanceForeground(600_000, noon); assertEquals(Optional.of(Alert.GOAL), session.takeAlert());
        session.advanceForeground(60_000, noon + 60_000); assertEquals(Optional.empty(), session.takeAlert());
        DeskSession next = new DeskSession(new SimulatedDesk()); next.restore(session.save());
        assertEquals(10, next.dailyGoalMinutes()); assertEquals(0, next.standingReminderMinutes()); assertEquals(660_000, next.standingMs());
    }
    @Test public void standingReminderResetsWhenPostureChanges() {
        session.configureGoals(120, 0, 10); session.connect(); session.moveTo(1050); desk.advance(20_000);
        session.advanceForeground(600_000, 600_000); assertEquals(Optional.of(Alert.STANDING), session.takeAlert());
        session.advanceForeground(600_000, 1_200_000); assertEquals(Optional.empty(), session.takeAlert());
        session.moveTo(720); desk.advance(20_000); session.advanceForeground(1000, 1_201_000);
        session.moveTo(1050); desk.advance(20_000); session.advanceForeground(600_000, 1_801_000);
        assertEquals(Optional.of(Alert.STANDING), session.takeAlert());
    }
    @Test public void corruptPreferencesRecoverWithoutDiscardingValidFields() {
        Properties p = new Properties(); p.setProperty("weightKg", "NaN"); p.setProperty("preset0", "99999");
        p.setProperty("heightCm", "180"); p.setProperty("standingMs", "-1"); p.setProperty("threshold", "bad");
        p.setProperty("day.invalid", "NaN"); session.restore(p);
        assertFalse(session.weightKg().isPresent()); assertEquals(720, session.preset(0)); assertEquals(180, session.bodyHeightCm().getAsInt());
        assertEquals(0, session.standingMs()); assertEquals(950, session.standingThresholdMm());
    }
}

package dev.cofodesk.auto.core;

import java.util.Locale;
import java.util.Properties;
import java.time.ZoneId;

/** App state independent of Android: persistence, presets, foreground statistics and reminder. */
public final class DeskSession {
    private final DeskPort desk;
    private final int[] presets = {720, 1050, 1180};
    private boolean inches;
    private double weightKg = 65;
    private int bodyHeightCm = 170;
    private int standingThresholdMm = 950;
    private long standingMs;
    private long connectedMs;
    private long reminderAtMs;
    private boolean reminderDue;
    private final ActivityHistory history = new ActivityHistory(ZoneId.systemDefault());
    private int dailyGoalMinutes = 60;
    private int sittingReminderMinutes = 40;
    private int standingReminderMinutes = 60;
    private long postureMs;
    private boolean postureWasStanding;
    private boolean postureNotified;
    private String alert = "";

    public DeskSession(DeskPort desk) { this.desk = desk; }
    public DeskPort.State state() { return desk.state(); }
    public void connect() { desk.connect(); }
    public void disconnect() { desk.disconnect(); resetPosture(); }
    public void stop() { desk.stop(); }
    public void lock(boolean locked) { desk.setLocked(locked); }
    public void jog(boolean up) { desk.moveTo(up ? SimulatedDesk.MAX_MM : SimulatedDesk.MIN_MM); }
    public void moveTo(int mm) { desk.moveTo(mm); }
    public int preset(int slot) { checkSlot(slot); return presets[slot]; }
    public void recall(int slot) { desk.moveTo(preset(slot)); }
    public void savePreset(int slot) {
        checkSlot(slot);
        if (!state().connected() || state().moving()) throw new IllegalStateException("error_save_preset");
        presets[slot] = state().heightMm();
    }
    private static void checkSlot(int slot) {
        if (slot < 0 || slot > 2) throw new IllegalArgumentException("error_slot");
    }
    public void setProfile(int heightCm, double kg, int thresholdMm, boolean useInches) {
        if (heightCm < 80 || heightCm > 250 || !Double.isFinite(kg) || kg < 20 || kg > 300
                || thresholdMm < SimulatedDesk.MIN_MM || thresholdMm > SimulatedDesk.MAX_MM)
            throw new IllegalArgumentException("error_profile");
        bodyHeightCm = heightCm; weightKg = kg; standingThresholdMm = thresholdMm; inches = useInches;
    }
    public int bodyHeightCm() { return bodyHeightCm; }
    public double weightKg() { return weightKg; }
    public int standingThresholdMm() { return standingThresholdMm; }
    public boolean inches() { return inches; }
    public String height(int mm) { return String.format(Locale.US, "%.1f %s", inches ? mm / 25.4 : mm / 10.0, inches ? "in" : "cm"); }
    public long standingMs() { return standingMs; }
    public long connectedMs() { return connectedMs; }
    public ActivityHistory history() { return history; }
    public int dailyGoalMinutes() { return dailyGoalMinutes; }
    public int sittingReminderMinutes() { return sittingReminderMinutes; }
    public int standingReminderMinutes() { return standingReminderMinutes; }
    public void configureGoals(int goal, int sit, int stand) {
        if (goal < 1 || goal > 480 || sit < 0 || sit > 240 || stand < 0 || stand > 240)
            throw new IllegalArgumentException("error_goals");
        dailyGoalMinutes = goal; sittingReminderMinutes = sit; standingReminderMinutes = stand;
        resetPosture();
    }
    public void pause() { stop(); resetPosture(); }
    private void resetPosture() { postureMs = 0; postureNotified = false; }
    public String takeAlert() { String value = alert; alert = ""; return value; }
    public double estimatedKcal() { return StandingCalories.estimate(standingMs, weightKg); }
    public void resetStatistics() { standingMs = 0; connectedMs = 0; history.clear(); resetPosture(); }
    public void advanceForeground(long elapsedMs, long nowMs) {
        if (elapsedMs < 0) throw new IllegalArgumentException("error_time");
        // Integrate in small intervals, so time crossing the standing threshold is not overcounted.
        long remaining = elapsedMs;
        long todayBefore = history.total(ActivityHistory.Period.DAY, nowMs);
        while (remaining > 0) {
            long slice = Math.min(remaining, 100);
            DeskPort.State before = state();
            if (before.connected()) {
                connectedMs += slice;
                boolean standing = before.heightMm() >= standingThresholdMm;
                if (standing) {
                    standingMs += slice;
                    history.add(nowMs - remaining, nowMs - remaining + slice);
                }
                if (standing != postureWasStanding) resetPosture();
                postureWasStanding = standing;
                postureMs += slice;
                int limit = standing ? standingReminderMinutes : sittingReminderMinutes;
                if (limit > 0 && !postureNotified && postureMs >= limit * 60_000L) {
                    alert = standing ? "alert_standing" : "alert_sitting";
                    postureNotified = true;
                }
            }
            desk.advance(slice);
            remaining -= slice;
        }
        if (todayBefore < dailyGoalMinutes * 60_000L && history.total(ActivityHistory.Period.DAY, nowMs) >= dailyGoalMinutes * 60_000L)
            alert = "alert_goal";
        reconcileReminder(nowMs);
    }
    public void startReminder(int minutes, long nowMs) {
        if (minutes < 1 || minutes > 180) throw new IllegalArgumentException("error_reminder");
        reminderAtMs = nowMs + minutes * 60_000L; reminderDue = false;
    }
    public void cancelReminder() { reminderAtMs = 0; reminderDue = false; }
    public void reconcileReminder(long nowMs) {
        if (reminderAtMs > 0 && nowMs >= reminderAtMs) { reminderAtMs = 0; reminderDue = true; }
    }
    public long reminderAtMs() { return reminderAtMs; }
    public boolean reminderDue() { return reminderDue; }
    public long reminderRemainingMs(long nowMs) { return Math.max(0, reminderAtMs - nowMs); }
    public Properties save() {
        Properties p = new Properties();
        for (int i = 0; i < 3; i++) p.setProperty("preset" + i, "" + presets[i]);
        p.setProperty("heightCm", "" + bodyHeightCm); p.setProperty("weightKg", "" + weightKg);
        p.setProperty("threshold", "" + standingThresholdMm); p.setProperty("inches", "" + inches);
        p.setProperty("standingMs", "" + standingMs); p.setProperty("connectedMs", "" + connectedMs);
        p.setProperty("reminderAtMs", "" + reminderAtMs);
        p.setProperty("goal", "" + dailyGoalMinutes);
        p.setProperty("sitReminder", "" + sittingReminderMinutes);
        p.setProperty("standReminder", "" + standingReminderMinutes);
        history.save(p);
        return p;
    }
    public void restore(Properties p) {
        // Each field recovers independently; a corrupt value must not make the app unlaunchable.
        bodyHeightCm = integer(p, "heightCm", 170, 80, 250);
        try { double kg = Double.parseDouble(p.getProperty("weightKg", "65"));
            weightKg = Double.isFinite(kg) && kg >= 20 && kg <= 300 ? kg : 65;
        } catch (NumberFormatException e) { weightKg = 65; }
        standingThresholdMm = integer(p, "threshold", 950, SimulatedDesk.MIN_MM, SimulatedDesk.MAX_MM);
        inches = Boolean.parseBoolean(p.getProperty("inches", "false"));
        for (int i = 0; i < 3; i++) presets[i] = integer(p, "preset" + i, new int[]{720, 1050, 1180}[i], SimulatedDesk.MIN_MM, SimulatedDesk.MAX_MM);
        standingMs = nonnegative(p, "standingMs");
        connectedMs = Math.max(standingMs, nonnegative(p, "connectedMs"));
        reminderAtMs = nonnegative(p, "reminderAtMs");
        dailyGoalMinutes = integer(p, "goal", 60, 1, 480);
        sittingReminderMinutes = integer(p, "sitReminder", 40, 0, 240);
        standingReminderMinutes = integer(p, "standReminder", 60, 0, 240);
        history.restore(p);
    }
    private static int integer(Properties p, String key, int fallback, int min, int max) {
        try { int n = Integer.parseInt(p.getProperty(key, "")); return n >= min && n <= max ? n : fallback; }
        catch (NumberFormatException e) { return fallback; }
    }
    private static long nonnegative(Properties p, String key) {
        try { return Math.max(0, Long.parseLong(p.getProperty(key, "0"))); }
        catch (NumberFormatException e) { return 0; }
    }
}

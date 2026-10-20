package dev.cofodesk.auto.core;

import java.util.Locale;
import java.util.Optional;
import java.util.OptionalDouble;
import java.util.OptionalInt;
import java.util.Properties;
import java.time.ZoneId;

/** App state independent of Android: persistence, presets, foreground statistics and reminder. */
public final class DeskSession {
    /** Original reminder pickers: hour 0–24 and minute 0–50 in steps of 10. */
    public static final int MAX_REMINDER_MINUTES = 24 * 60 + 50;
    public static final int REMINDER_STEP_MINUTES = 10;
    /** Accepted range for saved presets and the standing threshold. Movement is still bounded by the desk's own limits. */
    public static final TravelLimits SETTING_RANGE = new TravelLimits(630, 1280);
    private static final int[] DEFAULT_PRESETS = {720, 1050, 1180};
    private static final int DEFAULT_THRESHOLD_MM = 950;
    private static final int NUDGE_MM = 10;
    private final DeskPort desk;
    private final int[] presets = DEFAULT_PRESETS.clone();
    private boolean inches;
    // Empty like the original app until the user enters them; no stand-in body data.
    private OptionalDouble weightKg = OptionalDouble.empty();
    private OptionalInt bodyHeightCm = OptionalInt.empty();
    private int standingThresholdMm = DEFAULT_THRESHOLD_MM;
    private long standingMs;
    private long connectedMs;
    private long reminderAtMs;
    private boolean reminderDue;
    private final ActivityHistory history = new ActivityHistory(ZoneId.systemDefault());
    // 0 means no goal / reminder off, as in the original app's initial state.
    private int dailyGoalMinutes;
    private int sittingReminderMinutes;
    private int standingReminderMinutes;
    private long postureMs;
    private boolean postureWasStanding;
    private boolean postureNotified;
    private Optional<Alert> alert = Optional.empty();

    public DeskSession(DeskPort desk) { this.desk = desk; }
    public DeskPort.State state() { return desk.state(); }
    public void connect() { desk.connect(); }
    public void disconnect() { desk.disconnect(); resetPosture(); }
    public void stop() { desk.stop(); }
    public void lock(boolean locked) { desk.setLocked(locked); }
    public void jog(boolean up) { desk.startMove(up ? DeskPort.Direction.UP : DeskPort.Direction.DOWN); }
    /** One small step for accessibility clicks, kept inside the desk's reported limits. */
    public void nudge(boolean up) {
        DeskPort.State now = state();
        int target = now.heightMm() + (up ? NUDGE_MM : -NUDGE_MM);
        desk.moveTo(now.limits().map(limits -> limits.clamp(target)).orElse(target));
    }
    public void moveTo(int mm) { desk.moveTo(mm); }
    public int preset(int slot) { checkSlot(slot); return presets[slot]; }
    public void recall(int slot) { desk.moveTo(preset(slot)); }
    public void savePreset(int slot) {
        checkSlot(slot);
        if (!state().connected() || state().moving()) throw new Refused(Refused.Reason.SAVE_PRESET);
        presets[slot] = state().heightMm();
    }
    private static void checkSlot(int slot) {
        if (slot < 0 || slot >= DEFAULT_PRESETS.length) throw new Refused(Refused.Reason.SLOT);
    }
    public void setProfile(OptionalInt heightCm, OptionalDouble kg, int thresholdMm, boolean useInches) {
        if (heightCm.isPresent() && !validHeight(heightCm.getAsInt()) || kg.isPresent() && !validWeight(kg.getAsDouble())
                || !SETTING_RANGE.contains(thresholdMm))
            throw new Refused(Refused.Reason.PROFILE);
        bodyHeightCm = heightCm; weightKg = kg; standingThresholdMm = thresholdMm; inches = useInches;
    }
    private static boolean validHeight(int cm) { return cm >= 80 && cm <= 250; }
    private static boolean validWeight(double kg) { return Double.isFinite(kg) && kg >= 20 && kg <= 300; }
    public OptionalInt bodyHeightCm() { return bodyHeightCm; }
    public OptionalDouble weightKg() { return weightKg; }
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
        if (!allowedMinutes(goal, dailyGoalMinutes) || !allowedMinutes(sit, sittingReminderMinutes)
                || !allowedMinutes(stand, standingReminderMinutes))
            throw new Refused(Refused.Reason.GOALS);
        dailyGoalMinutes = goal; sittingReminderMinutes = sit; standingReminderMinutes = stand;
        resetPosture();
    }
    /** New choices follow the 10-minute step; an unchanged legacy value is kept, not rounded away. */
    private static boolean allowedMinutes(int value, int current) {
        return value >= 0 && value <= MAX_REMINDER_MINUTES && (value % REMINDER_STEP_MINUTES == 0 || value == current);
    }
    /** Original integer rule: whole standing minutes × 100 / goal, capped at 100. Empty when no goal is set. */
    public OptionalInt goalPercent(long nowMs) {
        if (dailyGoalMinutes == 0) return OptionalInt.empty();
        long minutes = history.total(ActivityHistory.Period.DAY, nowMs) / 1000 / 60;
        return OptionalInt.of((int) Math.min(100, minutes * 100 / dailyGoalMinutes));
    }
    public void pause() { stop(); resetPosture(); }
    private void resetPosture() { postureMs = 0; postureNotified = false; }
    public Optional<Alert> takeAlert() { Optional<Alert> value = alert; alert = Optional.empty(); return value; }
    public double estimatedKcal() { return StandingCalories.estimate(standingMs, weightKg.orElse(0)); }
    public void resetStatistics() { standingMs = 0; connectedMs = 0; history.clear(); resetPosture(); }
    public void advanceForeground(long elapsedMs, long nowMs) {
        if (elapsedMs < 0) throw new IllegalArgumentException("Negative elapsed time");
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
                    alert = Optional.of(standing ? Alert.STANDING : Alert.SITTING);
                    postureNotified = true;
                }
            }
            desk.advance(slice);
            remaining -= slice;
        }
        if (dailyGoalMinutes > 0 && todayBefore < dailyGoalMinutes * 60_000L && history.total(ActivityHistory.Period.DAY, nowMs) >= dailyGoalMinutes * 60_000L)
            alert = Optional.of(Alert.GOAL);
        reconcileReminder(nowMs);
    }
    public void startReminder(int minutes, long nowMs) {
        if (minutes < 1 || minutes > 180) throw new Refused(Refused.Reason.REMINDER);
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
        for (int i = 0; i < presets.length; i++) p.setProperty("preset" + i, "" + presets[i]);
        p.setProperty("heightCm", bodyHeightCm.isPresent() ? "" + bodyHeightCm.getAsInt() : "");
        p.setProperty("weightKg", weightKg.isPresent() ? "" + weightKg.getAsDouble() : "");
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
        // Values saved by older versions are kept, even if they equal the old 170 cm / 65 kg defaults:
        // the old format cannot tell whether the user typed them.
        int cm = integer(p, "heightCm", 0, 80, 250);
        bodyHeightCm = cm == 0 ? OptionalInt.empty() : OptionalInt.of(cm);
        try { double kg = Double.parseDouble(p.getProperty("weightKg", ""));
            weightKg = validWeight(kg) ? OptionalDouble.of(kg) : OptionalDouble.empty();
        } catch (NumberFormatException e) { weightKg = OptionalDouble.empty(); }
        standingThresholdMm = integer(p, "threshold", DEFAULT_THRESHOLD_MM, SETTING_RANGE.minMm(), SETTING_RANGE.maxMm());
        inches = Boolean.parseBoolean(p.getProperty("inches", "false"));
        for (int i = 0; i < presets.length; i++) presets[i] = integer(p, "preset" + i, DEFAULT_PRESETS[i], SETTING_RANGE.minMm(), SETTING_RANGE.maxMm());
        standingMs = nonnegative(p, "standingMs");
        connectedMs = Math.max(standingMs, nonnegative(p, "connectedMs"));
        reminderAtMs = nonnegative(p, "reminderAtMs");
        dailyGoalMinutes = integer(p, "goal", 0, 0, MAX_REMINDER_MINUTES);
        sittingReminderMinutes = integer(p, "sitReminder", 0, 0, MAX_REMINDER_MINUTES);
        standingReminderMinutes = integer(p, "standReminder", 0, 0, MAX_REMINDER_MINUTES);
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

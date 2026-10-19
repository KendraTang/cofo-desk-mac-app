package dev.cofodesk.auto.core;

/** Original 1.0.10 calculateCalorie: whole standing seconds, canonical kg, truncate result.
 * Canonical decimal kg avoids the original lb-save/Integer.parseInt mismatch.
 */
public final class StandingCalories {
    private StandingCalories() {}
    public static long estimate(long standingMs, double weightKg) {
        if (standingMs < 0) throw new IllegalArgumentException("error_time");
        if (!Double.isFinite(weightKg) || weightKg <= 0) return 0;
        return (long) ((standingMs / 1000L) * (weightKg * 1.5 + 60) / 3600.0);
    }
}

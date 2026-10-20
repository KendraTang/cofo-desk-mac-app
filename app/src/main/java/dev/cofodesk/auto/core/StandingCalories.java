package dev.cofodesk.auto.core;

/** Original 1.0.10 calculateCalorie: whole standing seconds, canonical kg, truncate result.
 * Canonical decimal kg avoids the original lb-save/Integer.parseInt mismatch.
 */
public final class StandingCalories {
    private StandingCalories() {}
    public static long estimate(long standingMs, double weightKg) {
        if (standingMs < 0) throw new IllegalArgumentException("Negative standing time");
        if (!Double.isFinite(weightKg) || weightKg <= 0) return 0;
        return (long) ((standingMs / 1000L) * (weightKg * 1.5 + 60) / 3600.0);
    }
    /** Original "equivalent" figure: kcal / 200, shown with one decimal. */
    public static String drumsticks(long kcal) { return String.format(java.util.Locale.US, "%.1f", kcal / 200.0); }
}

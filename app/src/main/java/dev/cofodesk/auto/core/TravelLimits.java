package dev.cofodesk.auto.core;

/** Travel range reported by the desk, in mm. A transport must not invent one it has not observed. */
public record TravelLimits(int minMm, int maxMm) {
    public TravelLimits {
        if (minMm < 0 || maxMm <= minMm) throw new IllegalArgumentException("error_height");
    }
    public boolean contains(int mm) { return mm >= minMm && mm <= maxMm; }
    public int clamp(int mm) { return Math.max(minMm, Math.min(maxMm, mm)); }
}

package dev.cofodesk.auto.core;

/** Desk fault state. NONE is explicit; an unrecognised device code is kept, never treated as no fault. */
public record Fault(Kind kind, String code) {
    public enum Kind { NONE, COLLISION, DEVICE, UNKNOWN }
    public static final Fault NONE = new Fault(Kind.NONE, "");
    /** Simulator-only obstacle stop. */
    public static final Fault COLLISION = new Fault(Kind.COLLISION, "");
    public Fault {
        if ((kind == Kind.DEVICE || kind == Kind.UNKNOWN) == code.isEmpty()) throw new IllegalArgumentException("Fault code mismatch");
    }
    /** A code the original app displays, such as E01, H01 or LOCK. */
    public static Fault device(String displayCode) { return new Fault(Kind.DEVICE, displayCode); }
    /** A raw code the original app does not name, kept for diagnosis. */
    public static Fault unknown(String rawCode) { return new Fault(Kind.UNKNOWN, rawCode); }
    public boolean present() { return kind != Kind.NONE; }
}

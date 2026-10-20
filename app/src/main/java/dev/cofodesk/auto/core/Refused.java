package dev.cofodesk.auto.core;

/** A user request the desk or session refused. The UI maps each reason to localized text. */
public final class Refused extends RuntimeException {
    public enum Reason { NOT_CONNECTED, LOCKED, FAULT, HEIGHT, LIMITS_UNKNOWN, SAVE_PRESET, SLOT, PROFILE, GOALS, REMINDER }
    private final Reason reason;
    public Refused(Reason reason) { super(reason.name()); this.reason = reason; }
    public Reason reason() { return reason; }
}

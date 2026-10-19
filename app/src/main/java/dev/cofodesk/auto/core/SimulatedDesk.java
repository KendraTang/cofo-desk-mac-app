package dev.cofodesk.auto.core;

/** Deterministic Premium-like simulator. These limits are not a hardware protocol. */
public final class SimulatedDesk implements DeskPort {
    public static final int MIN_MM = 630;
    public static final int MAX_MM = 1280;
    private double heightMm = 720;
    private int targetMm = 720;
    private boolean connected;
    private boolean locked;
    private String fault = "";

    @Override public State state() {
        return new State(connected, (int) Math.round(heightMm), connected && Math.abs(heightMm - targetMm) > .001, locked, fault);
    }
    @Override public void connect() { connected = true; stop(); }
    @Override public void disconnect() { stop(); connected = false; }
    @Override public void moveTo(int mm) {
        if (!connected) throw new IllegalStateException("error_not_connected");
        if (locked) throw new IllegalStateException("error_locked");
        if (!fault.isEmpty()) throw new IllegalStateException("error_fault");
        if (mm < MIN_MM || mm > MAX_MM) throw new IllegalArgumentException("error_height");
        targetMm = mm;
    }
    @Override public void stop() { targetMm = (int) Math.round(heightMm); heightMm = targetMm; }
    @Override public void setLocked(boolean value) { stop(); locked = value; }
    @Override public void advance(long ms) {
        if (ms < 0) throw new IllegalArgumentException("error_time");
        if (!state().moving()) return;
        double step = Math.min(Math.abs(targetMm - heightMm), 35.0 * ms / 1000.0);
        heightMm += Math.signum(targetMm - heightMm) * step;
    }
    public void collide() { stop(); fault = "fault_collision"; }
    public void clearFault() { fault = ""; }
}

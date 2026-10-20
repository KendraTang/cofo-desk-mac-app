package dev.cofodesk.auto.core;

import java.util.Optional;

/** Deterministic Premium-like simulator. These limits are not a hardware protocol. */
public final class SimulatedDesk implements DeskPort {
    public static final TravelLimits LIMITS = new TravelLimits(630, 1280);
    public static final int START_MM = 720;
    private double heightMm = START_MM;
    private int targetMm = START_MM;
    private boolean connected;
    private boolean locked;
    private String fault = "";

    /** Like a real desk, limits are only known while connected. */
    @Override public State state() {
        return new State(connected, (int) Math.round(heightMm), connected && Math.abs(heightMm - targetMm) > .001, locked, fault,
                connected ? Optional.of(LIMITS) : Optional.empty());
    }
    @Override public void connect() { connected = true; stop(); }
    @Override public void disconnect() { stop(); connected = false; }
    @Override public void moveTo(int mm) {
        checkMovable();
        if (!LIMITS.contains(mm)) throw new IllegalArgumentException("error_height");
        targetMm = mm;
    }
    @Override public void startMove(Direction direction) {
        checkMovable();
        targetMm = direction == Direction.UP ? LIMITS.maxMm() : LIMITS.minMm();
    }
    private void checkMovable() {
        if (!connected) throw new IllegalStateException("error_not_connected");
        if (locked) throw new IllegalStateException("error_locked");
        if (!fault.isEmpty()) throw new IllegalStateException("error_fault");
    }
    @Override public void stop() { targetMm = (int) Math.round(heightMm); heightMm = targetMm; }
    @Override public void setLocked(boolean value) { stop(); locked = value; }
    @Override public void advance(long ms) {
        if (ms < 0) throw new IllegalArgumentException("error_time");
        if (!state().moving()) return;
        double step = Math.min(Math.abs(targetMm - heightMm), 35.0 * ms / 1000.0);
        heightMm += Math.signum(targetMm - heightMm) * step;
    }
    /** Restores a saved stopped position only; connection, motion, lock and fault always start cleared. */
    public void restore(int mm) {
        if (connected) throw new IllegalStateException("error_restore_connected");
        heightMm = targetMm = LIMITS.contains(mm) ? mm : START_MM;
    }
    public void collide() { stop(); fault = "fault_collision"; }
    public void clearFault() { fault = ""; }
}

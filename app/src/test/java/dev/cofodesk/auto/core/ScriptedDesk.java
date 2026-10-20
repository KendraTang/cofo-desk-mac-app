package dev.cofodesk.auto.core;

import java.util.Optional;

/** Second DeskPort for contract tests: different limits, reported only when the test says so. */
final class ScriptedDesk implements DeskPort {
    private Optional<TravelLimits> limits = Optional.empty();
    private int heightMm = 800, targetMm = 800;
    private boolean connected, locked;
    private String fault = "";

    void reportLimits(TravelLimits value) { limits = Optional.of(value); }
    void reportFault(String code) { stop(); fault = code; }
    @Override public State state() {
        return new State(connected, heightMm, connected && heightMm != targetMm, locked, fault, connected ? limits : Optional.empty());
    }
    @Override public void connect() { connected = true; stop(); }
    @Override public void disconnect() { stop(); connected = false; }
    @Override public void moveTo(int mm) {
        TravelLimits known = movable();
        if (!known.contains(mm)) throw new IllegalArgumentException("error_height");
        targetMm = mm;
    }
    @Override public void startMove(Direction direction) {
        TravelLimits known = movable();
        targetMm = direction == Direction.UP ? known.maxMm() : known.minMm();
    }
    private TravelLimits movable() {
        if (!connected) throw new IllegalStateException("error_not_connected");
        if (locked) throw new IllegalStateException("error_locked");
        if (!fault.isEmpty()) throw new IllegalStateException("error_fault");
        return limits.orElseThrow(() -> new IllegalStateException("error_limits_unknown"));
    }
    @Override public void stop() { targetMm = heightMm; }
    @Override public void setLocked(boolean value) { stop(); locked = value; }
    @Override public void advance(long ms) {
        if (ms < 0) throw new IllegalArgumentException("error_time");
        int step = (int) Math.min(Math.abs(targetMm - heightMm), 50 * ms / 1000);
        heightMm += Integer.signum(targetMm - heightMm) * step;
    }
}

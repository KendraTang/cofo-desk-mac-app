package dev.cofodesk.auto.core;

import java.util.Optional;

/** Second DeskPort for contract tests: different limits, reported only when the test says so. */
final class ScriptedDesk implements DeskPort {
    private Optional<TravelLimits> limits = Optional.empty();
    private int heightMm = 800, targetMm = 800;
    private boolean connected, locked;
    private Fault fault = Fault.NONE;

    void reportLimits(TravelLimits value) { limits = Optional.of(value); }
    void reportFault(Fault value) { stop(); fault = value; }
    @Override public State state() {
        return new State(connected, heightMm, connected && heightMm != targetMm, locked, fault, connected ? limits : Optional.empty());
    }
    @Override public void connect() { connected = true; stop(); }
    @Override public void disconnect() { stop(); connected = false; }
    @Override public void moveTo(int mm) {
        TravelLimits known = movable();
        if (!known.contains(mm)) throw new Refused(Refused.Reason.HEIGHT);
        targetMm = mm;
    }
    @Override public void startMove(Direction direction) {
        TravelLimits known = movable();
        targetMm = direction == Direction.UP ? known.maxMm() : known.minMm();
    }
    private TravelLimits movable() {
        if (!connected) throw new Refused(Refused.Reason.NOT_CONNECTED);
        if (locked) throw new Refused(Refused.Reason.LOCKED);
        if (fault.present()) throw new Refused(Refused.Reason.FAULT);
        return limits.orElseThrow(() -> new Refused(Refused.Reason.LIMITS_UNKNOWN));
    }
    @Override public void stop() { targetMm = heightMm; }
    @Override public void setLocked(boolean value) { stop(); locked = value; }
    @Override public void advance(long ms) {
        if (ms < 0) throw new IllegalArgumentException("Negative elapsed time");
        int step = (int) Math.min(Math.abs(targetMm - heightMm), 50 * ms / 1000);
        heightMm += Integer.signum(targetMm - heightMm) * step;
    }
}

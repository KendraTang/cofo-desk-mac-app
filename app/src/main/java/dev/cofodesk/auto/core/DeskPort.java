package dev.cofodesk.auto.core;

import java.util.Optional;

/** Motor boundary. A real transport must report authoritative device state. Units: mm.
 * Movement is refused while disconnected, locked, faulted or before travel limits are known.
 */
public interface DeskPort {
    enum Direction { UP, DOWN }
    /** One snapshot, so height and limits always describe the same moment. */
    record State(boolean connected, int heightMm, boolean moving, boolean locked, Fault fault, Optional<TravelLimits> limits) {}
    State state();
    void connect();
    void disconnect();
    /** Target height, for presets and explicit targets. Sending it does not mean the desk got there. */
    void moveTo(int heightMm);
    /** Continuous movement until {@link #stop()} or a limit; callers stop on release or cancel. */
    void startMove(Direction direction);
    void stop();
    void setLocked(boolean locked);
    /** Simulated time only; a hardware transport takes height from the device instead. */
    void advance(long elapsedMs);
}

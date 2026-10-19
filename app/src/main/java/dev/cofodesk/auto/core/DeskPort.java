package dev.cofodesk.auto.core;

/** Motor boundary. A real transport must report authoritative device state. Units: mm. */
public interface DeskPort {
    record State(boolean connected, int heightMm, boolean moving, boolean locked, String fault) {}
    State state();
    void connect();
    void disconnect();
    void moveTo(int heightMm);
    void stop();
    void setLocked(boolean locked);
    void advance(long elapsedMs);
}

package dev.cofodesk.auto.core;

public class SimulatedDeskContractTest extends DeskPortContract {
    @Override protected DeskPort create() { return new SimulatedDesk(); }
    @Override protected TravelLimits connectWithLimits() { desk.connect(); return SimulatedDesk.LIMITS; }
    @Override protected void injectFault() { ((SimulatedDesk) desk).collide(); }
}

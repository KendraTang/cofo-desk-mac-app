"""One control session for both Bleak and the virtual GATT client."""
import asyncio
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
import math
import time

from .protocol import (
    DOWN, LOGIN_BYTES, LOGIN_CHARACTERISTIC, LOGIN_SERVICE, PROFILES,
    QUERY_HEIGHT, QUERY_LIMITS, STOP, UP, notification_events, target_frame,
)


class DeskError(Exception):
    pass


def describe(error):
    return str(error) or type(error).__name__


@dataclass
class StopRecord:
    """What this process did about STOP. A completed write is not a physical stop ACK."""
    attempted: bool = False
    completed: bool = False
    errors: list = field(default_factory=list)

    def report(self):
        return {"stop_attempted": self.attempted, "stop_write_completed": self.completed,
                "stop_errors": list(self.errors), "physical_stop_confirmed": False}


def writable(characteristic):
    return bool({"write", "write-without-response"} & set(characteristic.properties))


def select_profile(services, name="auto", require_notify=True):
    matches = []
    for profile in PROFILES:
        if name not in ("auto", profile.name):
            continue
        for service in services:
            if service.uuid.lower() != profile.service:
                continue
            writers = [c for c in service.characteristics if c.uuid.lower() == profile.write and writable(c)]
            readers = [c for c in service.characteristics if c.uuid.lower() == profile.notify
                       and {"notify", "indicate"} & set(c.properties)]
            for writer in writers:
                if require_notify:
                    matches.extend((profile, writer, reader) for reader in readers)
                else:
                    matches.append((profile, writer, None))
    if not matches:
        raise DeskError("No supported COFO GATT profile with the required properties was found")
    if len(matches) != 1:
        raise DeskError("Ambiguous COFO GATT profile; inspect the device and select --profile")
    return matches[0]


class Desk:
    def __init__(self, client, *, profile="auto", native_unit="auto", simulated=False,
                 connect_timeout=10.0, telemetry_timeout=3.0, init_interval=0.2,
                 write_timeout=3.0, login_timeout=1.0, stop_record=None):
        self.client = client
        self.profile_name = profile
        self.native_unit = native_unit
        self.simulated = simulated
        self.connect_timeout = connect_timeout
        self.telemetry_timeout = telemetry_timeout
        self.init_interval = init_interval
        self.write_timeout = write_timeout
        self.login_timeout = login_timeout
        self.stops = stop_record if stop_record is not None else StopRecord()
        self.profile = self.writer = self.reader = None
        self.raw_height = self.reported_unit = self.limits = self.error = None
        self.height_at = None
        self.height_sequence = 0
        self._write_lock = asyncio.Lock()

    async def __aenter__(self):
        try:
            await asyncio.wait_for(self.client.connect(), self.connect_timeout)
        except BaseException as original:
            try:
                await self._disconnect()
            except Exception as error:
                original.add_note(f"Disconnect also failed: {error}")
            raise
        return self

    async def __aexit__(self, exc_type, exc, tb):
        try:
            await self._disconnect()
        except Exception as error:
            if exc is None:
                raise DeskError(f"Disconnect/cleanup failed: {error}") from error
            exc.add_note(f"Disconnect/cleanup also failed: {error}")

    async def _disconnect(self):
        # Cleanup must also run for partial connections and cancelled operations.
        await asyncio.wait_for(self.client.disconnect(), 5.0)

    def ensure_connected(self):
        if not self.client.is_connected:
            raise DeskError("Device disconnected")

    def _receive(self, sender, data):
        for event in notification_events(bytes(data)):
            if event.kind == "height":
                self.raw_height = event.value
                self.height_at = time.monotonic()
                self.height_sequence += 1
            elif event.kind == "unit":
                self.reported_unit = event.value
            elif event.kind == "limits":
                self.limits = event.value
            elif event.kind == "error":
                # The recovered protocol has no established clear-error packet.
                self.error = event.value

    async def prepare(self, *, telemetry=True, require_limits=False):
        self.profile, self.writer, self.reader = select_profile(
            self.client.services, self.profile_name, require_notify=telemetry)
        if not telemetry:
            return
        try:
            await asyncio.wait_for(self.client.start_notify(self.reader, self._receive), self.telemetry_timeout)
        except TimeoutError as error:
            raise DeskError("Timed out subscribing to notifications") from error
        if self._has_login_service():
            await self._write_to(self._login_characteristic(), LOGIN_BYTES)
        # Original app's 0/.2/.4 s height queries and .8/1/1.2 s limits queries.
        for index in range(7):
            if index in (0, 1, 2):
                await self.write(QUERY_HEIGHT)
            elif index in (4, 5, 6):
                await self.write(QUERY_LIMITS)
            if index < 6:
                await asyncio.sleep(self.init_interval)
        await self.wait_telemetry(require_limits=require_limits)

    def _has_login_service(self):
        return any(service.uuid.lower() == LOGIN_SERVICE for service in self.client.services)

    def _login_characteristic(self):
        candidates = [c for service in self.client.services if service.uuid.lower() == LOGIN_SERVICE
                      for c in service.characteristics if c.uuid.lower() == LOGIN_CHARACTERISTIC and writable(c)]
        if len(candidates) != 1:
            raise DeskError("Login service has no unambiguous writable login characteristic")
        return candidates[0]

    async def _write_to(self, characteristic, data, timeout=None):
        timeout = self.write_timeout if timeout is None else timeout
        async with self._write_lock:
            self.ensure_connected()
            try:
                await asyncio.wait_for(self.client.write_gatt_char(
                    characteristic, data, response="write" in characteristic.properties), timeout)
            except TimeoutError as error:
                raise DeskError(f"Write timed out after {timeout:g} s") from error

    async def write(self, data):
        if self.writer is None:
            raise DeskError("No control characteristic selected")
        await self._write_to(self.writer, data)

    async def wait_telemetry(self, *, require_limits=False, after_sequence=0):
        deadline = time.monotonic() + self.telemetry_timeout
        while True:
            self.ensure_connected()
            if self.height_sequence > after_sequence and (self.limits is not None or not require_limits):
                return
            if time.monotonic() >= deadline:
                raise DeskError("Timed out waiting for height" + (" and travel limits" if require_limits else ""))
            await asyncio.sleep(0.02)

    def _unit(self):
        if self.native_unit != "auto":
            return self.native_unit, "override"
        if self.reported_unit:
            return self.reported_unit, "notification"
        if self.raw_height is None:
            return None, None
        return ("cm" if self.raw_height >= 550 else "in"), "original-app heuristic"

    def height_mm(self):
        unit, _ = self._unit()
        if self.raw_height is None:
            return None
        return self.raw_height * (1 if unit == "cm" else 2.54)

    def snapshot(self):
        unit, source = self._unit()
        height = self.height_mm()
        return {
            "simulated": self.simulated,
            "connected": bool(self.client.is_connected),
            "profile": self.profile.name if self.profile else None,
            "height_mm": round(height, 2) if height is not None else None,
            "height_cm": round(height / 10, 2) if height is not None else None,
            "height_in": round(height / 25.4, 2) if height is not None else None,
            "raw_height": self.raw_height,
            "native_unit": unit,
            "unit_source": source,
            "limits_mm": list(self.limits) if self.limits else None,
            "sample_age_seconds": round(time.monotonic() - self.height_at, 3) if self.height_at else None,
            "error": self.error,
        }

    async def _ready_to_move(self):
        sequence = self.height_sequence
        await self.write(QUERY_HEIGHT)
        await self.wait_telemetry(require_limits=True, after_sequence=sequence)
        self._guard()

    def _guard(self):
        self.ensure_connected()
        if self.error:
            raise DeskError(f"Desk reported {self.error}; movement refused")
        if self.height_at is None or time.monotonic() - self.height_at > 1.5:
            raise DeskError("Height telemetry is stale; movement stopped")
        if self.limits is None:
            raise DeskError("Travel limits are unknown")
        if not self.limits[0] - 3 <= self.height_mm() <= self.limits[1] + 3:
            raise DeskError("Reported height is outside the travel limits")

    async def send_stop(self):
        if self.writer is None:
            raise DeskError("No control characteristic selected; STOP not attempted")
        self.stops.attempted = True
        try:
            await self.write(STOP)
        except Exception as error:
            self.stops.errors.append(describe(error))
            raise
        self.stops.completed = True

    async def stop_now(self):
        """Standalone stop: STOP, then conditional login and STOP again. Never waits for telemetry."""
        self.profile, self.writer, self.reader = select_profile(
            self.client.services, self.profile_name, require_notify=False)
        plan = [("stop", self.send_stop)]
        if self._has_login_service():
            async def login():
                await self._write_to(self._login_characteristic(), LOGIN_BYTES, self.login_timeout)
            plan += [("login", login), ("stop", self.send_stop)]
        steps = []
        for name, action in plan:
            # A dropped link is reported, never silently reconnected and replayed.
            if not self.client.is_connected:
                steps.append({"step": name, "completed": False, "error": "not attempted: device disconnected"})
                continue
            try:
                await action()
            except Exception as error:
                steps.append({"step": name, "completed": False, "error": describe(error)})
            else:
                steps.append({"step": name, "completed": True, "error": None})
        return steps

    @asynccontextmanager
    async def _stopping(self):
        try:
            yield
        except BaseException as original:
            try:
                await self.send_stop()
            except Exception as stop_error:
                original.add_note(f"Stop delivery also failed: {describe(stop_error)}")
            raise
        else:
            try:
                await self.send_stop()
            except Exception as error:
                raise DeskError(f"Could not deliver stop: {describe(error)}") from error

    async def jog(self, direction, seconds):
        if direction not in ("up", "down") or not math.isfinite(seconds) or not 0 < seconds <= 30:
            raise DeskError("Jog requires up/down and a duration greater than 0 and at most 30 seconds")
        await self._ready_to_move()
        reason = "duration"
        async with self._stopping():
            deadline = time.monotonic() + seconds
            next_write = 0
            while time.monotonic() < deadline:
                self._guard()
                height = self.height_mm()
                if ((direction == "up" and height >= self.limits[1] - 1) or
                        (direction == "down" and height <= self.limits[0] + 1)):
                    reason = "limit"
                    break
                if time.monotonic() >= next_write:
                    await self.write(UP if direction == "up" else DOWN)
                    next_write = time.monotonic() + 0.1
                await asyncio.sleep(min(0.025, max(0, deadline - time.monotonic())))
        return {"direction": direction, "reason": reason, "stop_sent": True, "status": self.snapshot()}

    async def go_to(self, millimetres, timeout):
        packet = target_frame(millimetres)
        if not math.isfinite(timeout) or not 0 < timeout <= 120:
            raise DeskError("Target timeout must be greater than 0 and at most 120 seconds")
        await self._ready_to_move()
        if not self.limits[0] <= millimetres <= self.limits[1]:
            raise DeskError(f"Target is outside discovered limits {self.limits[0]}–{self.limits[1]} mm")
        async with self._stopping():
            tolerance = 3 if self._unit()[0] == "in" else 1
            if abs(self.height_mm() - millimetres) > tolerance:
                sequence = self.height_sequence
                await self.write(packet)
                deadline = time.monotonic() + timeout
                while True:
                    self._guard()
                    if self.height_sequence > sequence and abs(self.height_mm() - millimetres) <= tolerance:
                        break
                    if time.monotonic() >= deadline:
                        raise DeskError("Target was not reached before timeout; stop attempted")
                    await asyncio.sleep(0.025)
        return {"target_mm": millimetres, "target_reached": True, "stop_sent": True, "status": self.snapshot()}

    def inspect(self):
        return {"simulated": self.simulated, "services": [
            {"uuid": service.uuid, "characteristics": [
                {"uuid": c.uuid, "properties": list(c.properties)} for c in service.characteristics
            ]} for service in self.client.services
        ]}

"""One control session for both Bleak and the virtual GATT client."""
import asyncio
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
import math
import time

from .protocol import (
    DOWN, LOGIN_BYTES, LOGIN_CHARACTERISTIC, LOGIN_SERVICE, PROFILES,
    NotificationReader, QUERY_HEIGHT, QUERY_LIMITS, STOP, UP, target_frame,
)

# Original app's start-up queries, one slot per init_interval: height at 0/.2/.4 s, limits at .8/1/1.2 s.
INIT_SCHEDULE = (QUERY_HEIGHT, QUERY_HEIGHT, QUERY_HEIGHT, None, QUERY_LIMITS, QUERY_LIMITS, QUERY_LIMITS)
RESEND_SECONDS = 0.1            # original app's direction resend interval
STALE_HEIGHT_SECONDS = 1.5      # stop moving if no newer height arrives
MOTION_POLL_SECONDS = 0.025
TELEMETRY_POLL_SECONDS = 0.02
DISCONNECT_TIMEOUT_SECONDS = 5.0
LIMIT_SLACK_MM = 3              # reported height may exceed the limits by rounding/sampling
JOG_LIMIT_MARGIN_MM = 1         # stop jogging this close to a limit
TARGET_TOLERANCE_MM = {"cm": 1, "in": 3}
MEMORY_SETTLE_SECONDS = 0.3     # memory frames arrived 0.14-0.25 s after the limits query on the real desk


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


@dataclass(frozen=True)
class HeightSample:
    raw: int
    at: float
    sequence: int


class Desk:
    def __init__(self, client, *, profile="auto", native_unit="auto", simulated=False,
                 connect_timeout=10.0, telemetry_timeout=3.0, init_interval=0.2,
                 write_timeout=3.0, login_timeout=1.0, stop_record=None, clock=time.monotonic, trace=None):
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
        self.clock = clock
        # Optional raw-traffic observer, called as trace(direction, uuid, data).
        self.trace = trace
        self.height = self.reported_unit = self.limits = self.error = None
        self.memory = {}  # panel slot -> raw height, 0 when empty
        self.reader_stream = NotificationReader()
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
        await asyncio.wait_for(self.client.disconnect(), DISCONNECT_TIMEOUT_SECONDS)

    def ensure_connected(self):
        if not self.client.is_connected:
            raise DeskError("Device disconnected")

    def _receive(self, sender, data):
        if self.trace:
            self.trace("notify", getattr(sender, "uuid", str(sender)), bytes(data))
        for event in self.reader_stream.feed(bytes(data)):
            if event.kind == "height":
                self.height = HeightSample(event.value, self.clock(), self._sequence() + 1)
            elif event.kind == "unit":
                self.reported_unit = event.value
            elif event.kind == "limits":
                self.limits = event.value
            elif event.kind == "memory":
                slot, raw = event.value
                self.memory[slot] = raw
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
        for index, query in enumerate(INIT_SCHEDULE):
            if query is not None:
                await self.write(query)
            if index < len(INIT_SCHEDULE) - 1:
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
            if self.trace:
                self.trace("write", characteristic.uuid, bytes(data))
            try:
                await asyncio.wait_for(self.client.write_gatt_char(
                    characteristic, data, response="write" in characteristic.properties), timeout)
            except TimeoutError as error:
                raise DeskError(f"Write timed out after {timeout:g} s") from error

    async def write(self, data):
        if self.writer is None:
            raise DeskError("No control characteristic selected")
        await self._write_to(self.writer, data)

    def _sequence(self):
        return self.height.sequence if self.height else 0

    async def wait_telemetry(self, *, require_limits=False, after_sequence=0):
        deadline = self.clock() + self.telemetry_timeout
        while True:
            self.ensure_connected()
            if self._sequence() > after_sequence and (self.limits is not None or not require_limits):
                return
            if self.clock() >= deadline:
                raise DeskError("Timed out waiting for height" + (" and travel limits" if require_limits else ""))
            await asyncio.sleep(TELEMETRY_POLL_SECONDS)

    def _unit(self):
        if self.native_unit != "auto":
            return self.native_unit, "override"
        if self.reported_unit:
            return self.reported_unit, "notification"
        if self.height is None:
            return None, None
        return ("cm" if self.height.raw >= 550 else "in"), "original-app heuristic"

    def _raw_mm(self, raw):
        unit, _ = self._unit()
        return raw * (1 if unit == "cm" else 2.54)

    def height_mm(self):
        return self._raw_mm(self.height.raw) if self.height else None

    def memory_mm(self):
        return {f"M{slot}": round(self._raw_mm(raw), 2) if raw else None
                for slot, raw in sorted(self.memory.items())}

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
            "raw_height": self.height.raw if self.height else None,
            "native_unit": unit,
            "unit_source": source,
            "limits_mm": list(self.limits) if self.limits else None,
            "memory_mm": self.memory_mm(),
            "sample_age_seconds": round(self.clock() - self.height.at, 3) if self.height else None,
            "error": self.error,
        }

    async def refresh(self):
        """Fresh height and memory heights. Keeps the limits from prepare(): on the real desk the
        limits frame only follows repeated height queries, while the limits query is answered with
        the memory heights (and unit), not the limits."""
        sequence = self._sequence()
        await self.write(QUERY_HEIGHT)
        await self.write(QUERY_LIMITS)
        await self.wait_telemetry(require_limits=True, after_sequence=sequence)
        await asyncio.sleep(MEMORY_SETTLE_SECONDS)

    async def _ready_to_move(self):
        sequence = self._sequence()
        await self.write(QUERY_HEIGHT)
        await self.wait_telemetry(require_limits=True, after_sequence=sequence)
        self._guard()

    def _guard(self):
        self.ensure_connected()
        if self.error:
            raise DeskError(f"Desk reported {self.error}; movement refused")
        if self.height is None or self.clock() - self.height.at > STALE_HEIGHT_SECONDS:
            raise DeskError("Height telemetry is stale; movement stopped")
        if self.limits is None:
            raise DeskError("Travel limits are unknown")
        if not self.limits[0] - LIMIT_SLACK_MM <= self.height_mm() <= self.limits[1] + LIMIT_SLACK_MM:
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
            deadline = self.clock() + seconds
            next_write = 0
            while self.clock() < deadline:
                self._guard()
                height = self.height_mm()
                if ((direction == "up" and height >= self.limits[1] - JOG_LIMIT_MARGIN_MM) or
                        (direction == "down" and height <= self.limits[0] + JOG_LIMIT_MARGIN_MM)):
                    reason = "limit"
                    break
                if self.clock() >= next_write:
                    await self.write(UP if direction == "up" else DOWN)
                    next_write = self.clock() + RESEND_SECONDS
                await asyncio.sleep(min(MOTION_POLL_SECONDS, max(0, deadline - self.clock())))
        return {"direction": direction, "reason": reason, "stop_sent": True, "status": self.snapshot()}

    async def go_to(self, millimetres, timeout):
        packet = target_frame(millimetres)
        if not math.isfinite(timeout) or not 0 < timeout <= 120:
            raise DeskError("Target timeout must be greater than 0 and at most 120 seconds")
        await self._ready_to_move()
        if not self.limits[0] <= millimetres <= self.limits[1]:
            raise DeskError(f"Target is outside discovered limits {self.limits[0]}–{self.limits[1]} mm")
        async with self._stopping():
            tolerance = TARGET_TOLERANCE_MM[self._unit()[0]]
            if abs(self.height_mm() - millimetres) > tolerance:
                sequence = self._sequence()
                await self.write(packet)
                deadline = self.clock() + timeout
                while True:
                    self._guard()
                    if self._sequence() > sequence and abs(self.height_mm() - millimetres) <= tolerance:
                        break
                    if self.clock() >= deadline:
                        raise DeskError("Target was not reached before timeout; stop attempted")
                    await asyncio.sleep(MOTION_POLL_SECONDS)
        return {"target_mm": millimetres, "target_reached": True, "stop_sent": True, "status": self.snapshot()}

    def inspect(self):
        return {"simulated": self.simulated, "services": [
            {"uuid": service.uuid, "characteristics": [
                {"uuid": c.uuid, "properties": list(c.properties)} for c in service.characteristics
            ]} for service in self.client.services
        ]}

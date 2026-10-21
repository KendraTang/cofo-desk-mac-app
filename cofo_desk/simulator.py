"""Virtual GATT peripheral. Generated notifications are not hardware evidence."""
import asyncio
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace

from .desk import DeskError
from .protocol import DOWN, PROFILES, QUERY_HEIGHT, QUERY_LIMITS, STOP, UP, notification_frame, target_frame


def default_state_file():
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/cofo-desk/simulator.json"
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "cofo-desk/simulator.json"


class SimulatedClient:
    def __init__(self, state_file, *, profile="ff12"):
        self.state_file = Path(state_file)
        selected = next(p for p in PROFILES if p.name == profile)
        self.writer = SimpleNamespace(uuid=selected.write, properties=["write"])
        self.reader = (self.writer if selected.notify == selected.write else
                       SimpleNamespace(uuid=selected.notify, properties=["notify"]))
        if self.reader is self.writer:
            self.reader.properties.append("notify")
        self.services = [SimpleNamespace(uuid=selected.service, characteristics=[self.writer] +
                                        ([] if self.reader is self.writer else [self.reader]))]
        self.is_connected = False
        self.height = 720.0
        self.minimum, self.maximum = 630, 1280
        self.memory = (1100, 720, 0, 0)  # panel M1-M4; not saved, the panel is not simulated
        self.direction = 0
        self.target = None
        self.callback = None
        self.writes = []
        self._task = self._lock_file = None
        self._at = 0

    async def connect(self):
        # Advisory lock covers the whole session, so two CLI processes cannot
        # silently overwrite each other's virtual position. Nothing moves on load.
        import fcntl
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self._lock_file = self.state_file.with_suffix(self.state_file.suffix + ".lock").open("a")
        try:
            fcntl.flock(self._lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            self._lock_file.close()
            self._lock_file = None
            raise DeskError("Simulator state is already in use by another process") from error
        try:
            if self.state_file.exists():
                try:
                    state = json.loads(self.state_file.read_text())
                    height = state["height_mm"]
                    if (state.get("version") != 1 or isinstance(height, bool) or
                            not isinstance(height, (int, float)) or not math.isfinite(height) or
                            not self.minimum <= height <= self.maximum):
                        raise ValueError("Invalid simulator height or version")
                    self.height = float(height)
                except (ValueError, KeyError, TypeError) as error:
                    raise DeskError(f"Invalid simulator state: {self.state_file}") from error
            self.direction, self.target = 0, None
            self.is_connected = True
            self._at = time.monotonic()
            self._task = asyncio.create_task(self._tick())
        except BaseException:
            self._unlock()
            raise

    def _unlock(self):
        if self._lock_file:
            self._lock_file.close()
            self._lock_file = None

    def _update(self):
        now = time.monotonic()
        candidate = self.height + self.direction * 35 * (now - self._at)
        self._at = now
        if self.target is not None and ((self.direction > 0 and candidate >= self.target) or
                                        (self.direction < 0 and candidate <= self.target)):
            candidate = self.target
            self.target, self.direction = None, 0
        self.height = min(self.maximum, max(self.minimum, candidate))
        if self.height in (self.minimum, self.maximum):
            self.direction, self.target = 0, None

    def _emit(self, packet):
        if self.callback:
            self.callback(self.reader, bytearray(packet))

    def _height(self):
        # Same layout as the real desk, including the uninterpreted third byte.
        self._emit(notification_frame(0x01, round(self.height).to_bytes(2, "big") + b"\x07"))

    async def _tick(self):
        while True:
            await asyncio.sleep(0.05)
            self._update()
            self._height()

    async def start_notify(self, characteristic, callback):
        self.callback = callback
        self._emit(notification_frame(0x0E, b"\x00"))

    async def write_gatt_char(self, characteristic, data, *, response):
        if not self.is_connected:
            raise DeskError("Simulator disconnected")
        self._update()
        data = bytes(data)
        self.writes.append(data)
        if data == QUERY_HEIGHT:
            self._height()
        elif data == QUERY_LIMITS:
            self._emit(notification_frame(0x07, self.maximum.to_bytes(2, "big") + self.minimum.to_bytes(2, "big")))
            for slot, raw in enumerate(self.memory):
                self._emit(notification_frame(0x25 + slot, raw.to_bytes(2, "big")))
        elif data == STOP:
            self.direction, self.target = 0, None
            self._height()
        elif data in (UP, DOWN):
            self.direction = 1 if data == UP else -1
            self.target = None
        elif len(data) == 8 and data == target_frame(int.from_bytes(data[4:6], "big")):
            # Re-encoding checks prefix, opcode, length, checksum and trailer together.
            target = int.from_bytes(data[4:6], "big")
            if not self.minimum <= target <= self.maximum:
                raise DeskError("Simulator target is outside travel limits")
            self.target = target
            self.direction = 1 if target > self.height else -1
        else:
            raise DeskError("Unsupported simulator command")

    def _save(self):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=self.state_file.parent, delete=False) as handle:
                temporary = Path(handle.name)
                json.dump({"version": 1, "height_mm": round(self.height, 3)}, handle)
                handle.write("\n")
            temporary.replace(self.state_file)
        finally:
            if temporary and temporary.exists():
                temporary.unlink()

    async def disconnect(self):
        try:
            if self.is_connected:
                self._update()
                self.direction, self.target = 0, None
                self.is_connected = False
                if self._task:
                    self._task.cancel()
                    try:
                        await self._task
                    except asyncio.CancelledError:
                        pass
                self._save()
        finally:
            self.callback = None
            self._unlock()

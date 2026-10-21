"""COFO frames from the original 1.0.10 app, checked against one real desk; see docs/reverse-engineering.md.

Outgoing and incoming frames share one layout: prefix, opcode, length, payload, checksum, 7E.
The checksum is (opcode + length + sum(payload)) & 0xFF. Only fields the original app consumes
are decoded; frames with other opcodes are valid but ignored.
"""
from dataclasses import dataclass


COMMAND_PREFIX = b"\xf1\xf1"
NOTIFY_PREFIX = b"\xf2\xf2"
TRAILER = 0x7E


def checksum(opcode: int, payload: bytes) -> int:
    return (opcode + len(payload) + sum(payload)) & 255


def frame(opcode: int, payload: bytes = b"", prefix: bytes = COMMAND_PREFIX) -> bytes:
    if not 0 <= opcode <= 255 or len(payload) > 255:
        raise ValueError("Invalid opcode or payload length")
    return prefix + bytes((opcode, len(payload))) + payload + bytes((checksum(opcode, payload), TRAILER))


def notification_frame(opcode: int, payload: bytes = b"") -> bytes:
    """A desk-to-app frame, as the real desk sends it (used by the simulator and tests)."""
    return frame(opcode, payload, NOTIFY_PREFIX)


UP = frame(0x01)
DOWN = frame(0x02)
STOP = frame(0x2B)
QUERY_HEIGHT = frame(0x0C)
QUERY_LIMITS = frame(0x07)


def target_frame(millimetres: int) -> bytes:
    if isinstance(millimetres, bool) or not isinstance(millimetres, int) or not 0 <= millimetres <= 65535:
        raise ValueError("Target must be an unsigned 16-bit integer in millimetres")
    return frame(0x1B, millimetres.to_bytes(2, "big"))


@dataclass(frozen=True)
class Profile:
    name: str
    service: str
    write: str
    notify: str


def _uuid(short: str) -> str:
    return f"0000{short}-0000-1000-8000-00805f9b34fb"


PROFILES = (
    Profile("ff12", _uuid("ff12"), _uuid("ff01"), _uuid("ff02")),
    Profile("fe60", _uuid("fe60"), _uuid("fe61"), _uuid("fe62")),
    Profile("legacy", "88121427-11e2-52a2-4615-ff00dec16800", "88121427-11e2-52a2-4615-ff00dec16801", "88121427-11e2-52a2-4615-ff00dec16801"),
)
LOGIN_SERVICE = "9e5d1e47-5c13-43a0-8635-82adffc0386f"
LOGIN_CHARACTERISTIC = "9e5d1e47-5c13-43a0-8635-82adffc1386f"
LOGIN_BYTES = bytes.fromhex("01 16 02 38 38 38 38")


@dataclass(frozen=True)
class Event:
    kind: str
    value: object


# Assumption: no valid incoming frame is longer than this. The longest observed is 10 bytes
# (limits); a claimed length beyond it is treated as a false start, not awaited.
MAX_FRAME_BYTES = 32


def _decode(opcode: int, payload: bytes):
    if opcode == 0x0E and len(payload) == 1 and payload[0] in (0, 1):
        return Event("unit", "cm" if payload[0] == 0 else "in")
    if opcode == 0x07 and len(payload) >= 4:
        maximum, minimum = int.from_bytes(payload[:2], "big"), int.from_bytes(payload[2:4], "big")
        return Event("limits", (minimum, maximum)) if 0 < minimum < maximum else None
    if opcode == 0x01 and len(payload) >= 2:
        # The real desk sends 3 bytes; the third (always 07 so far) is not interpreted.
        return Event("height", int.from_bytes(payload[:2], "big"))
    if opcode == 0x02 and len(payload) == 1:
        code = payload[0]
        if 1 <= code <= 13:
            return Event("error", f"E0{code}")  # 10-13 read E010-E013, as in the original app
        return Event("error", {14: "H01", 15: "H02", 16: "LOCK"}.get(code, f"UNKNOWN_0x{code:02X}"))
    if opcode == 0x04:
        # Assumption: RST uses the common frame layout; not yet seen on the real desk.
        return Event("error", "RST")
    if 0x25 <= opcode <= 0x28 and len(payload) == 2:
        # Panel memory heights, sent after every limits query; the original app ignores them.
        # 25 = M1 and 26 = M2 match the panel on the real desk (2026-10-21); 27/28 as M3/M4 is
        # assumed from the order. Same unit as the height field; 0 means the slot is empty.
        return Event("memory", (opcode - 0x24, int.from_bytes(payload, "big")))
    return None


class NotificationReader:
    """Joins notifications into one byte stream, so a frame split across BLE notifications still parses.

    A frame is used only if its checksum and trailer are right and its opcode and length are known.
    Anything else is skipped one byte at a time until the next F2 F2. An incomplete tail is kept for the
    next notification; it is always shorter than MAX_FRAME_BYTES.
    """
    def __init__(self):
        self.pending = b""

    def feed(self, data: bytes) -> list[Event]:
        data = self.pending + bytes(data)
        events = []
        index = 0
        while index < len(data):
            if data[index:index + 2] != NOTIFY_PREFIX[:len(data) - index]:
                index += 1
                continue
            if index + 4 > len(data):
                break  # prefix, or prefix + opcode, at the very end: wait for more
            opcode, length = data[index + 2], data[index + 3]
            end = index + 4 + length + 2
            if end > index + MAX_FRAME_BYTES:
                index += 1
                continue
            if end > len(data):
                break
            payload = data[index + 4:end - 2]
            if data[end - 2] != checksum(opcode, payload) or data[end - 1] != TRAILER:
                index += 1
                continue
            event = _decode(opcode, payload)
            if event is not None:
                events.append(event)
            index = end
        self.pending = data[index:]
        return events


def notification_events(data: bytes) -> list[Event]:
    """Events in one self-contained buffer; incomplete trailing bytes are discarded."""
    return NotificationReader().feed(data)

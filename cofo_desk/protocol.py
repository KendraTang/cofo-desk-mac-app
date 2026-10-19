"""Static 1.0.10 protocol observations; see docs/reverse-engineering.md.

Incoming parsing is limited to fields actually consumed by the original app.
It validates bounds, but does not invent an incoming checksum or ACK contract.
Each notification must contain complete fields, as with the original receiver.
"""
from dataclasses import dataclass


def frame(opcode: int, payload: bytes = b"") -> bytes:
    if not 0 <= opcode <= 255 or len(payload) > 255:
        raise ValueError("Invalid opcode or payload length")
    return bytes((0xF1, 0xF1, opcode, len(payload))) + payload + bytes(
        ((opcode + len(payload) + sum(payload)) & 255, 0x7E)
    )


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


def notification_events(data: bytes) -> list[Event]:
    """Parse complete known fields, retaining unknown/truncated packets as no events.

    A leading F2 is optional for the height/error patterns because the original
    searches F201/F20201. Unit and limits require their observed doubled prefix.
    Extra payload is retained as uninterpreted bytes rather than motor flags.
    """
    events = []
    index = 0
    while index < len(data):
        if data[index] != 0xF2:
            index += 1
            continue
        opcode_at = index + 1
        doubled = opcode_at < len(data) and data[opcode_at] == 0xF2
        if doubled:
            opcode_at += 1
        if opcode_at >= len(data):
            break
        opcode = data[opcode_at]
        if opcode == 0x04:
            events.append(Event("error", "RST"))
            index = opcode_at + 1
            continue
        if opcode_at + 1 >= len(data):
            break
        length = data[opcode_at + 1]
        end = opcode_at + 2 + length
        if end > len(data):
            index += 1
            continue
        payload = data[opcode_at + 2:end]
        event = None
        if doubled and opcode == 0x0E and length == 1 and payload[0] in (0, 1):
            event = Event("unit", "cm" if payload[0] == 0 else "in")
        elif doubled and opcode == 0x07 and length >= 4:
            maximum, minimum = int.from_bytes(payload[:2], "big"), int.from_bytes(payload[2:4], "big")
            if 0 < minimum < maximum:
                event = Event("limits", (minimum, maximum))
        elif opcode == 0x01 and length >= 2:
            event = Event("height", int.from_bytes(payload[:2], "big"))
        elif opcode == 0x02 and length == 1:
            code = payload[0]
            if 1 <= code <= 13:
                error = f"E0{code}"
            else:
                error = {14: "H01", 15: "H02", 16: "LOCK"}.get(code, f"UNKNOWN_0x{code:02X}")
            event = Event("error", error)
        if event is not None:
            events.append(event)
            index = end
        else:
            index += 1
    return events

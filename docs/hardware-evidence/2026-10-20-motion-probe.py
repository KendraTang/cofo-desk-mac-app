"""One-off real-desk probes. Every mode keeps listening after STOP so we can see when the height settles.

  jog       real Desk.jog (with resends), then listen
  goto      real Desk.go_to to current + offset mm, then listen
  single    ONE UP write, no resends, no STOP until --guard seconds unless the desk stops itself
  listen    only report heights
Every mode sends a final STOP in `finally`, including on Ctrl-C.
"""
import argparse
import asyncio
import json
import sys
import time

sys.path.insert(0, "/Users/tkain/projects/cofo-desk-auto")
from bleak import BleakClient  # noqa: E402
from cofo_desk.desk import Desk  # noqa: E402
from cofo_desk.protocol import QUERY_HEIGHT, STOP, UP  # noqa: E402

DEVICE = "24793885-E0D3-DAA3-9DD8-4271F4793A63"
SETTLED_SECONDS = 0.8        # no height change for this long counts as stopped
UPPER_SAFETY_MM = 30         # single mode stops this far below the upper limit


def trace(direction, uuid, data):
    print(f"TRACE {time.time():.3f} {direction} {uuid[4:8]} {data.hex()}", file=sys.stderr, flush=True)


class Recorder:
    """Records every new height sample with its monotonic time."""
    def __init__(self, desk):
        self.desk, self.samples, self.seen, self.stops = desk, [], 0, []
        original = desk.send_stop
        async def timed_stop():
            self.stops.append(time.monotonic())
            await original()
        desk.send_stop = timed_stop

    def poll(self):
        if self.desk.height and self.desk.height.sequence > self.seen:
            self.seen = self.desk.height.sequence
            self.samples.append((self.desk.height.at, self.desk.height.raw))

    async def run_for(self, seconds, query_every=0.3):
        deadline, next_query = time.monotonic() + seconds, 0
        while time.monotonic() < deadline:
            if time.monotonic() >= next_query:
                await self.desk.write(QUERY_HEIGHT)
                next_query = time.monotonic() + query_every
            self.poll()
            await asyncio.sleep(0.02)
        self.poll()

    def last_change(self):
        last = None
        for (_, before), (at, now) in zip(self.samples, self.samples[1:]):
            if now != before:
                last = at
        return last

    def settled_since(self, now):
        change = self.last_change()
        return change is not None and now - change >= SETTLED_SECONDS


async def single_up(desk, rec, guard):
    """One UP and nothing else, so the desk's own no-resend behaviour shows."""
    await desk._ready_to_move()
    rec.poll()
    up_at = time.monotonic()
    await desk.write(UP)
    outcome = "guard STOP (desk kept moving)"
    while time.monotonic() - up_at < guard:
        rec.poll()
        await asyncio.sleep(0.02)
        if time.monotonic() - rec.samples[-1][0] > 1.5:
            await desk.write(QUERY_HEIGHT)   # desk may only report on request
        now = time.monotonic()
        if desk.height_mm() >= desk.limits[1] - UPPER_SAFETY_MM:
            outcome = "safety STOP near upper limit"
            break
        if rec.settled_since(now):
            outcome = "desk stopped by itself"
            break
    else:
        if rec.last_change() is None:
            outcome = "desk never moved"
    return up_at, outcome


async def main(args):
    if args.simulate:
        from cofo_desk.simulator import SimulatedClient
        client = SimulatedClient(args.simulate, profile="fe60")
    else:
        client = BleakClient(DEVICE, timeout=10)
    async with Desk(client, trace=trace, init_interval=0 if args.simulate else 0.2) as desk:
        rec = Recorder(desk)
        await desk.prepare(require_limits=True)
        rec.poll()
        start = rec.samples[-1][1]
        moved_at, outcome = time.monotonic(), None
        try:
            if args.mode == "jog":
                outcome = (await desk.jog(args.direction, args.seconds))["reason"]
            elif args.mode == "goto":
                target = start + args.offset
                print(f"goto target {target} mm (start {start})", flush=True)
                try:
                    await desk.go_to(target, args.timeout)
                    outcome = "target reached"
                except Exception as error:
                    outcome = f"goto failed: {error}"
            elif args.mode == "single":
                moved_at, outcome = await single_up(desk, rec, args.guard)
            if args.mode != "single":
                rec.poll()
            if args.mode == "single":
                await desk.send_stop()
            await rec.run_for(args.listen)
        finally:
            try:
                await desk.write(STOP)
            except Exception as error:
                print(f"final STOP failed: {error}", flush=True)
    rec.poll()
    stop_at = rec.stops[0] if rec.stops else None
    change = rec.last_change()
    summary = {
        "mode": args.mode, "outcome": outcome,
        "start_raw": start, "final_raw": rec.samples[-1][1],
        "height_at_first_stop": next((raw for at, raw in reversed(rec.samples) if stop_at and at <= stop_at), None),
        "last_change_after_first_stop_s": round(change - stop_at, 3) if change and stop_at else None,
        "last_change_after_move_s": round(change - moved_at, 3) if change else None,
        "samples": [[round(at - moved_at, 3), raw] for at, raw in rec.samples],
    }
    print("SUMMARY " + json.dumps(summary), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["jog", "goto", "single", "listen"])
    p.add_argument("--direction", choices=["up", "down"], default="up")
    p.add_argument("--seconds", type=float, default=1.0)
    p.add_argument("--offset", type=int, default=5)
    p.add_argument("--timeout", type=float, default=1.0)
    p.add_argument("--guard", type=float, default=2.0)
    p.add_argument("--listen", type=float, default=2.0)
    p.add_argument("--simulate", metavar="STATE_FILE", help="test this script against the simulator")
    asyncio.run(main(p.parse_args()))

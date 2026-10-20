"""The cofo-desk console entry point."""
import argparse
import asyncio
import json
import math
from pathlib import Path
import signal
import sys
import time

from . import __version__
from .desk import Desk, DeskError, StopRecord
from .protocol import PROFILES

# Shell convention: 128 + signal number.
INTERRUPT_CODES = {signal.SIGINT: 130, signal.SIGTERM: 143}
if hasattr(signal, "SIGHUP"):
    INTERRUPT_CODES[signal.SIGHUP] = 129


def positive_number(text):
    try:
        value = float(text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return value


def bounded_number(maximum):
    def parse(text):
        value = positive_number(text)
        if value > maximum:
            raise argparse.ArgumentTypeError(f"must be at most {maximum}")
        return value
    return parse


def parser():
    result = argparse.ArgumentParser(description="COFO BLE desk controller (hardware compatibility pending validation)")
    result.add_argument("--version", action="version", version=__version__)
    result.add_argument("--json", action="store_true", help="JSON output; watch emits JSON Lines")
    result.add_argument("--simulate", action="store_true", help="use an explicit virtual BLE peripheral")
    result.add_argument("--state-file", type=Path, help="simulator state file (only with --simulate)")
    result.add_argument("--device", help="BLE address or macOS peripheral UUID from scan")
    result.add_argument("--profile", choices=["auto"] + [p.name for p in PROFILES], default="auto")
    result.add_argument("--native-unit", choices=["auto", "cm", "in"], default="auto",
                        help="override interpretation of incoming height fields")
    result.add_argument("--connect-timeout", type=bounded_number(60), default=10.0)
    result.add_argument("--telemetry-timeout", type=bounded_number(30), default=3.0)
    result.add_argument("--login-timeout", type=bounded_number(10), default=1.0,
                        help="login write timeout for the standalone stop command")
    sub = result.add_subparsers(dest="command", required=True)
    scan = sub.add_parser("scan", help="discover BLE peripherals without connecting")
    scan.add_argument("--seconds", type=bounded_number(30), default=5.0)
    sub.add_parser("inspect", help="read GATT service/characteristic metadata without writes")
    sub.add_parser("status", help="read height, unit, limits and any reported error")
    watch = sub.add_parser("watch", help="observe status for a bounded period")
    watch.add_argument("--seconds", type=bounded_number(3600), default=10.0)
    for direction in ("up", "down"):
        jog = sub.add_parser(direction, help=f"move {direction}, then send stop")
        jog.add_argument("--seconds", type=bounded_number(30), default=1.0)
    sub.add_parser("stop", help="send stop immediately after connection/profile discovery")
    target = sub.add_parser("goto", help="move to height, waiting for telemetry before stopping")
    target.add_argument("height", type=positive_number)
    target.add_argument("--unit", choices=["cm", "in", "mm"], default="cm")
    target.add_argument("--timeout", type=bounded_number(120), default=20.0)
    return result


def emit(value, as_json):
    if as_json:
        print(json.dumps(value, ensure_ascii=False, allow_nan=False), flush=True)
    elif "error" in value and "height_mm" not in value:
        print(f"Error: {value['error']}", file=sys.stderr, flush=True)
    elif "devices" in value:
        for device in value["devices"]:
            print(f"{device['address']}  {device['name'] or '(unnamed)'}  RSSI {device['rssi']}", flush=True)
        if not value["devices"]:
            print("No peripherals found.", flush=True)
    elif "services" in value:
        for service in value["services"]:
            print(service["uuid"])
            for characteristic in service["characteristics"]:
                print(f"  {characteristic['uuid']}  {', '.join(characteristic['properties'])}")
    elif "height_mm" in value:
        label = "SIMULATED" if value["simulated"] else "BLE"
        print(f"{label}  {value['height_cm']} cm / {value['height_in']} in  "
              f"limits {value['limits_mm']} mm  error {value['error'] or 'none'}  "
              f"unit {value['native_unit']} ({value['unit_source']})", flush=True)
    elif "status" in value:
        if value.get("target_reached"):
            print(f"Target {value['target_mm']} mm observed; stop sent.", flush=True)
        else:
            print(f"{value['direction']} finished ({value['reason']}); stop sent.", flush=True)
        emit(value["status"], False)
    else:
        for step in value["steps"]:
            print(f"{step['step']}: {'written' if step['completed'] else step['error']}", flush=True)
        print("Stop sent. Physical stop is not confirmed by the protocol.", flush=True)


def bleak_module():
    try:
        import bleak
    except ImportError as error:
        raise DeskError('BLE support is missing; install with: python3 -m pip install -e ".[ble]"') from error
    return bleak


async def run(args, stops=None):
    if args.command == "scan":
        if args.simulate:
            advertised = next(p for p in PROFILES if p.name == ("ff12" if args.profile == "auto" else args.profile))
            devices = [{"name": "Virtual COFO", "address": "simulated", "rssi": 0,
                        "service_uuids": [advertised.service], "supported_service_advertised": True}]
        else:
            found = await bleak_module().BleakScanner.discover(timeout=args.seconds, return_adv=True)
            known = {p.service for p in PROFILES}
            devices = [{"name": adv.local_name or device.name, "address": device.address, "rssi": adv.rssi,
                        "service_uuids": adv.service_uuids,
                        "supported_service_advertised": bool(known & {u.lower() for u in adv.service_uuids})}
                       for device, adv in found.values()]
            devices.sort(key=lambda device: device["rssi"], reverse=True)
        return {"simulated": args.simulate, "devices": devices}
    if args.simulate:
        from .simulator import SimulatedClient, default_state_file
        client = SimulatedClient(args.state_file or default_state_file(),
                                 profile="ff12" if args.profile == "auto" else args.profile)
    else:
        client = bleak_module().BleakClient(args.device, timeout=args.connect_timeout)
    async with Desk(client, profile=args.profile, native_unit=args.native_unit, simulated=args.simulate,
                    connect_timeout=args.connect_timeout, telemetry_timeout=args.telemetry_timeout,
                    init_interval=0 if args.simulate else 0.2, login_timeout=args.login_timeout,
                    stop_record=stops) as desk:
        if args.command == "inspect":
            return desk.inspect()
        if args.command == "stop":
            steps = await desk.stop_now()
            if not desk.stops.completed:
                raise DeskError("No STOP write completed: " + "; ".join(
                    f"{step['step']}: {step['error']}" for step in steps))
            return {"simulated": args.simulate, "stop_sent": True, "steps": steps, "physical_stop_confirmed": False}
        await desk.prepare(require_limits=args.command in ("goto", "up", "down"))
        if args.command == "status":
            return desk.snapshot()
        elif args.command == "watch":
            deadline = time.monotonic() + args.seconds
            while True:
                desk.ensure_connected()
                emit(desk.snapshot(), args.json)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                await asyncio.sleep(min(0.5, remaining))
        elif args.command in ("up", "down"):
            return await desk.jog(args.command, args.seconds)
        elif args.command == "goto":
            return await desk.go_to(args.target_mm, args.timeout)


class Interrupted(Exception):
    def __init__(self, received, stops, notes):
        super().__init__(signal.Signals(received[0]).name)
        self.received, self.stops, self.notes = received, stops, notes

    def report(self):
        stops = self.stops.report()
        if not stops["stop_attempted"]:
            outcome = "no STOP was attempted"
        elif stops["stop_write_completed"]:
            outcome = "STOP write completed"
        else:
            outcome = "STOP write failed: " + "; ".join(stops["stop_errors"])
        return {"error": f"Interrupted by {self}; {outcome}; physical desk state is unknown",
                "signal": str(self), "ignored_signals": [signal.Signals(s).name for s in self.received[1:]],
                **stops, "cleanup_errors": list(self.notes)}


async def supervised(args, stops):
    """The first signal cancels once; later ones are only recorded so STOP and disconnect finish."""
    loop = asyncio.get_running_loop()
    task = asyncio.current_task()
    received = []
    def handle(signum):
        received.append(signum)
        if len(received) == 1:
            task.cancel()
    for signum in INTERRUPT_CODES:
        loop.add_signal_handler(signum, handle, signum)
    try:
        return await run(args, stops)
    except asyncio.CancelledError as cancelled:
        if not received:
            raise
        raise Interrupted(received, stops, getattr(cancelled, "__notes__", [])) from None
    finally:
        for signum in INTERRUPT_CODES:
            loop.remove_signal_handler(signum)


def main(argv=None):
    arguments = parser()
    args = arguments.parse_args(argv)
    if args.state_file and not args.simulate:
        arguments.error("--state-file requires --simulate")
    if args.simulate and args.device:
        arguments.error("--simulate cannot be combined with --device")
    if not args.simulate and args.command != "scan" and not args.device:
        arguments.error("--device is required for BLE commands; use scan to discover it")
    if args.command == "goto":
        millimetres = args.height * {"mm": 1, "cm": 10, "in": 25.4}[args.unit]
        if not math.isfinite(millimetres) or not 0 < round(millimetres) <= 65535:
            arguments.error("target must fit a positive 16-bit millimetre value")
        args.target_mm = round(millimetres)
    stops = StopRecord()
    try:
        value = asyncio.run(supervised(args, stops))
        if value is not None:
            emit(value, args.json)
    except Interrupted as interrupted:
        emit(interrupted.report(), args.json)
        return INTERRUPT_CODES[interrupted.received[0]]
    except KeyboardInterrupt:
        # Only reachable outside the supervised window, where no desk session is active.
        emit({"error": "Interrupted outside the desk session; physical desk state is unknown",
              "signal": "SIGINT", **stops.report()}, args.json)
        return 130
    except Exception as error:
        message = str(error) or type(error).__name__
        notes = getattr(error, "__notes__", [])
        if notes:
            message += "; " + "; ".join(notes)
        emit({"error": message}, args.json)
        return 1
    return 0

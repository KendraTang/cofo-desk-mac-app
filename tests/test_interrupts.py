"""Real signals sent to this process while main() drives a GATT fixture."""
import asyncio
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cofo_desk.cli import main
from cofo_desk.protocol import STOP, UP
from cofo_desk.simulator import SimulatedClient
from support import Peripheral


class SignalPeripheral(Peripheral):
    def __init__(self):
        super().__init__()
        self.connecting, self.moving, self.stopping = threading.Event(), threading.Event(), threading.Event()
        self.connect_delay = self.stop_delay = 0
        self.stop_error = self.disconnect_error = None

    async def connect(self):
        self.connecting.set()
        await asyncio.sleep(self.connect_delay)
        await super().connect()

    async def disconnect(self):
        await super().disconnect()
        if self.disconnect_error:
            raise self.disconnect_error

    async def write_gatt_char(self, characteristic, data, *, response):
        if data == STOP:
            self.stopping.set()
            await asyncio.sleep(self.stop_delay)
            if self.stop_error:
                raise self.stop_error
        await super().write_gatt_char(characteristic, data, response=response)
        if data == UP:
            self.moving.set()


@unittest.skipIf(sys.platform == "win32", "POSIX signals")
class InterruptTest(unittest.TestCase):
    def interrupt(self, peripheral, arguments, *signals):
        def send():
            for event, signum in signals:
                self.assertTrue(event.wait(5))
                os.kill(os.getpid(), signum)
        sender = threading.Thread(target=send)
        output = io.StringIO()
        with patch("cofo_desk.cli.bleak_module", return_value=SimpleNamespace(BleakClient=lambda *a, **k: peripheral)), \
                redirect_stdout(output):
            sender.start()
            code = main(["--json", "--device", "fixture"] + arguments)
        sender.join(5)
        return code, json.loads(output.getvalue())

    def test_each_signal_during_movement_stops_then_disconnects(self):
        for signum, code in [(signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129)]:
            with self.subTest(signal=signum.name):
                peripheral = SignalPeripheral()
                result, report = self.interrupt(peripheral, ["up", "--seconds", "20"], (peripheral.moving, signum))
                self.assertEqual(result, code)
                self.assertEqual(report["signal"], signum.name)
                self.assertTrue(report["stop_attempted"])
                self.assertTrue(report["stop_write_completed"])
                self.assertFalse(report["physical_stop_confirmed"])
                self.assertEqual(report["ignored_signals"], [])
                self.assertEqual(peripheral.sent[-1][1], STOP)
                self.assertEqual(peripheral.disconnect_count, 1)

    def test_repeated_signal_during_stop_write_does_not_cancel_it(self):
        peripheral = SignalPeripheral()
        peripheral.stop_delay = 0.2
        code, report = self.interrupt(peripheral, ["up", "--seconds", "20"],
                                      (peripheral.moving, signal.SIGTERM), (peripheral.stopping, signal.SIGINT))
        self.assertEqual(code, 143)
        self.assertEqual(report["ignored_signals"], ["SIGINT"])
        self.assertTrue(report["stop_write_completed"])
        self.assertEqual(peripheral.sent[-1][1], STOP)
        self.assertEqual(peripheral.disconnect_count, 1)

    def test_repeated_signal_before_any_movement_reports_no_stop(self):
        peripheral = SignalPeripheral()
        peripheral.connect_delay = 0.3
        code, report = self.interrupt(peripheral, ["up", "--seconds", "20"],
                                      (peripheral.connecting, signal.SIGINT), (peripheral.connecting, signal.SIGINT))
        self.assertEqual(code, 130)
        self.assertFalse(report["stop_attempted"])
        self.assertIn("no STOP was attempted", report["error"])
        self.assertEqual(peripheral.sent, [])
        self.assertEqual(peripheral.disconnect_count, 1)

    def test_failed_stop_and_failed_cleanup_are_both_reported(self):
        peripheral = SignalPeripheral()
        peripheral.stop_delay = 0.2
        peripheral.stop_error = OSError("ATT write rejected")
        peripheral.disconnect_error = OSError("link lost")
        code, report = self.interrupt(peripheral, ["up", "--seconds", "20"],
                                      (peripheral.moving, signal.SIGINT), (peripheral.stopping, signal.SIGHUP))
        self.assertEqual(code, 130)
        self.assertEqual(report["ignored_signals"], ["SIGHUP"])
        self.assertTrue(report["stop_attempted"])
        self.assertFalse(report["stop_write_completed"])
        self.assertEqual(report["stop_errors"], ["ATT write rejected"])
        self.assertIn("STOP write failed: ATT write rejected", report["error"])
        self.assertEqual(report["cleanup_errors"], ["Stop delivery also failed: ATT write rejected",
                                                    "Disconnect/cleanup also failed: link lost"])

    def test_simulator_state_is_saved_stopped_after_sigterm(self):
        moving = threading.Event()
        original = SimulatedClient.write_gatt_char
        async def observed(client, characteristic, data, *, response):
            await original(client, characteristic, data, response=response)
            if data == UP:
                moving.set()
        with tempfile.TemporaryDirectory() as directory, patch.object(SimulatedClient, "write_gatt_char", observed):
            state = Path(directory) / "state.json"
            def send():
                self.assertTrue(moving.wait(5))
                os.kill(os.getpid(), signal.SIGTERM)
            sender = threading.Thread(target=send)
            output = io.StringIO()
            with redirect_stdout(output):
                sender.start()
                code = main(["--json", "--simulate", "--state-file", str(state), "up", "--seconds", "20"])
            sender.join(5)
            self.assertEqual(code, 143)
            self.assertTrue(json.loads(output.getvalue())["stop_write_completed"])
            saved = json.loads(state.read_text())["height_mm"]
            self.assertGreaterEqual(saved, 720)
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(main(["--json", "--simulate", "--state-file", str(state), "status"]), 0)
            self.assertAlmostEqual(json.loads(output.getvalue())["height_mm"], saved, delta=0.5)

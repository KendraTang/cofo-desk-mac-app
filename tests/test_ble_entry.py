import asyncio
from contextlib import redirect_stdout
import io
import json
import sys
from types import SimpleNamespace as Item
import unittest
from unittest.mock import AsyncMock, patch

from cofo_desk.cli import bleak_module, main, parser, run
from cofo_desk.desk import DeskError
from support import Peripheral


class BleEntryTest(unittest.IsolatedAsyncioTestCase):
    async def test_real_stop_path_constructs_bleak_client_and_skips_telemetry(self):
        peripheral = Peripheral(height=False, limits=False, notifications=False)
        constructions = []
        def factory(address, **kwargs):
            constructions.append((address, kwargs))
            return peripheral
        args = parser().parse_args(["--device", "peripheral-uuid", "stop"])
        with patch("cofo_desk.cli.bleak_module", return_value=Item(BleakClient=factory)):
            result = await run(args)
        self.assertEqual(constructions, [("peripheral-uuid", {"timeout": 10.0})])
        self.assertFalse(result["simulated"])
        self.assertFalse(result["physical_stop_confirmed"])
        self.assertEqual([data.hex() for _, data, _ in peripheral.sent], ["f1f12b002b7e"])
        self.assertEqual(peripheral.disconnect_count, 1)

    async def test_inspect_reads_metadata_without_any_writes_or_subscriptions(self):
        peripheral = Peripheral()
        args = parser().parse_args(["--device", "peripheral-uuid", "inspect"])
        with patch("cofo_desk.cli.bleak_module", return_value=Item(BleakClient=lambda *a, **k: peripheral)):
            result = await run(args)
        self.assertEqual(len(result["services"]), 1)
        self.assertEqual(peripheral.sent, [])
        self.assertEqual(peripheral.subscribe_count, 0)

    async def test_real_scan_keeps_unknown_devices_and_uses_advertisement_rssi(self):
        scanner = Item(discover=AsyncMock(return_value={
            "one": (Item(address="uuid-one", name="COFO"), Item(local_name=None, rssi=-70,
                     service_uuids=["0000ff12-0000-1000-8000-00805f9b34fb"])),
            "two": (Item(address="uuid-two", name=None), Item(local_name="Other", rssi=-50, service_uuids=[])),
        }))
        args = parser().parse_args(["scan", "--seconds", "2"])
        with patch("cofo_desk.cli.bleak_module", return_value=Item(BleakScanner=scanner)):
            result = await run(args)
        scanner.discover.assert_awaited_once_with(timeout=2, return_adv=True)
        self.assertEqual([d["address"] for d in result["devices"]], ["uuid-two", "uuid-one"])
        self.assertFalse(result["devices"][0]["supported_service_advertised"])
        self.assertTrue(result["devices"][1]["supported_service_advertised"])


class EntryErrorTest(unittest.TestCase):
    def test_optional_dependency_error_is_actionable(self):
        with patch.dict(sys.modules, {"bleak": None}), self.assertRaisesRegex(DeskError, "BLE support is missing"):
            bleak_module()

    def test_backend_failure_has_one_json_error_and_nonzero_exit(self):
        output = io.StringIO()
        with patch("cofo_desk.cli.bleak_module", side_effect=OSError("Bluetooth unavailable")), redirect_stdout(output):
            code = main(["--json", "scan"])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue()), {"error": "Bluetooth unavailable"})

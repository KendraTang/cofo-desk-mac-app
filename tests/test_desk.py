import asyncio
import time
from types import SimpleNamespace as Item
import unittest

from cofo_desk.desk import Desk, DeskError, select_profile
from cofo_desk.protocol import LOGIN_BYTES, LOGIN_CHARACTERISTIC, LOGIN_SERVICE, QUERY_HEIGHT, QUERY_LIMITS, STOP, UP


class Peripheral:
    """Independent GATT fixture: no use of the simulator's frame processing."""
    def __init__(self, *, response=True, height=True, limits=True, notifications=True):
        self.writer = Item(uuid="0000ff01-0000-1000-8000-00805f9b34fb",
                           properties=["write" if response else "write-without-response"])
        self.reader = Item(uuid="0000ff02-0000-1000-8000-00805f9b34fb",
                           properties=["notify"] if notifications else ["read"])
        self.services = [Item(uuid="0000ff12-0000-1000-8000-00805f9b34fb",
                              characteristics=[self.writer, self.reader])]
        self.is_connected = False
        self.callback = None
        self.sent = []
        self.subscribe_count = self.disconnect_count = 0
        self.height_enabled, self.limits_enabled = height, limits
        self.on_command = None
        self.writing = self.overlapped = False
        self.moved = asyncio.Event()

    async def connect(self):
        self.is_connected = True

    async def disconnect(self):
        self.is_connected = False
        self.disconnect_count += 1

    async def start_notify(self, characteristic, callback):
        self.subscribe_count += 1
        self.callback = callback

    def notify(self, hex_text):
        if self.callback:
            self.callback(self.reader, bytearray.fromhex(hex_text))

    async def write_gatt_char(self, characteristic, data, *, response):
        if self.writing:
            self.overlapped = True
        self.writing = True
        try:
            await asyncio.sleep(0)
            self.sent.append((characteristic, bytes(data), response))
            if data == bytes.fromhex("F1F10C000C7E") and self.height_enabled:
                self.notify("F2F2010202D0")
            if data == bytes.fromhex("F1F10700077E") and self.limits_enabled:
                self.notify("F2F2070405000276")
            if self.on_command:
                self.on_command(bytes(data))
            if data == UP:
                self.moved.set()
        finally:
            self.writing = False


class DeskTest(unittest.IsolatedAsyncioTestCase):
    def desk(self, peripheral, **kwargs):
        return Desk(peripheral, init_interval=0, telemetry_timeout=0.06, **kwargs)

    async def test_initialization_subscribes_and_serializes_observed_queries(self):
        peripheral = Peripheral()
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            self.assertEqual([packet for _, packet, _ in peripheral.sent],
                             [QUERY_HEIGHT] * 3 + [QUERY_LIMITS] * 3)
            self.assertEqual(desk.snapshot()["height_mm"], 720)
            self.assertEqual(desk.snapshot()["limits_mm"], [630, 1280])
            self.assertEqual(desk.snapshot()["unit_source"], "original-app heuristic")
            self.assertEqual(peripheral.subscribe_count, 1)
            self.assertTrue(all(char is peripheral.writer and response for char, _, response in peripheral.sent))
            await asyncio.gather(desk.write(QUERY_HEIGHT), desk.write(QUERY_LIMITS))
            self.assertFalse(peripheral.overlapped)
        self.assertFalse(peripheral.is_connected)

    async def test_stop_needs_no_notifications_no_login_or_height_queries(self):
        peripheral = Peripheral(notifications=False, height=False, limits=False)
        async with self.desk(peripheral) as desk:
            await desk.prepare(telemetry=False)
            await desk.write(STOP)
        self.assertEqual(peripheral.subscribe_count, 0)
        self.assertEqual([packet for _, packet, _ in peripheral.sent], [bytes.fromhex("F1F12B002B7E")])

    async def test_write_without_response_and_conditional_login(self):
        peripheral = Peripheral(response=False)
        login = Item(uuid=LOGIN_CHARACTERISTIC, properties=["write-without-response"])
        peripheral.services.append(Item(uuid=LOGIN_SERVICE, characteristics=[login]))
        async with self.desk(peripheral) as desk:
            await desk.prepare()
        self.assertEqual(peripheral.sent[0], (login, LOGIN_BYTES, False))
        self.assertTrue(all(not response for _, _, response in peripheral.sent))

    async def test_height_timeout_disconnects_without_motion(self):
        peripheral = Peripheral(height=False)
        with self.assertRaisesRegex(DeskError, "Timed out"):
            async with self.desk(peripheral) as desk:
                await desk.prepare()
        self.assertEqual(peripheral.disconnect_count, 1)
        self.assertNotIn(UP, [packet for _, packet, _ in peripheral.sent])

    async def test_notification_subscription_timeout_cleans_up_without_writes(self):
        class StalledSubscription(Peripheral):
            async def start_notify(self, characteristic, callback):
                await asyncio.Event().wait()
        peripheral = StalledSubscription()
        with self.assertRaisesRegex(DeskError, "subscribing"):
            async with self.desk(peripheral) as desk:
                await desk.prepare()
        self.assertEqual(peripheral.sent, [])
        self.assertEqual(peripheral.disconnect_count, 1)

    async def test_missing_limits_refuses_motion(self):
        peripheral = Peripheral(limits=False)
        with self.assertRaisesRegex(DeskError, "travel limits"):
            async with self.desk(peripheral) as desk:
                await desk.prepare(require_limits=True)
        self.assertNotIn(UP, [packet for _, packet, _ in peripheral.sent])

    async def test_unit_report_override_and_error_are_not_guessed_away(self):
        peripheral = Peripheral()
        async with self.desk(peripheral) as desk:
            await desk.prepare()
            peripheral.notify("F2F20E0101 F2F20102011B")  # 28.3 in
            self.assertAlmostEqual(desk.height_mm(), 718.82)
            self.assertEqual(desk.snapshot()["unit_source"], "notification")
            desk.native_unit = "cm"
            self.assertEqual(desk.height_mm(), 283)
            self.assertEqual(desk.snapshot()["unit_source"], "override")
            peripheral.notify("F2020110")
            peripheral.notify("F2F2010202D0")
            with self.assertRaisesRegex(DeskError, "LOCK"):
                await desk.jog("up", 0.1)
        self.assertNotIn(UP, [packet for _, packet, _ in peripheral.sent])

    async def test_jog_repeats_then_sends_stop(self):
        peripheral = Peripheral()
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            result = await desk.jog("up", 0.23)
        packets = [packet for _, packet, _ in peripheral.sent]
        self.assertGreaterEqual(packets.count(UP), 2)
        self.assertEqual(packets[-1], STOP)
        self.assertTrue(result["stop_sent"])

    async def test_limit_stops_without_up_packet(self):
        peripheral = Peripheral()
        def upper_limit(data):
            if data == QUERY_HEIGHT:
                peripheral.notify("F2F201020500")
        peripheral.on_command = upper_limit
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            result = await desk.jog("up", 0.2)
        self.assertEqual(result["reason"], "limit")
        self.assertNotIn(UP, [packet for _, packet, _ in peripheral.sent])
        self.assertEqual(peripheral.sent[-1][1], STOP)

    async def test_fault_during_jog_stops_and_reports_failure(self):
        peripheral = Peripheral()
        peripheral.on_command = lambda data: peripheral.notify("F2020101") if data == UP else None
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            with self.assertRaisesRegex(DeskError, "E01"):
                await desk.jog("up", 0.2)
        self.assertEqual(peripheral.sent[-1][1], STOP)

    async def test_stale_height_during_jog_stops(self):
        peripheral = Peripheral()
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            def stale(data):
                if data == UP:
                    desk.height_at = time.monotonic() - 2
            peripheral.on_command = stale
            with self.assertRaisesRegex(DeskError, "stale"):
                await desk.jog("up", 0.2)
        self.assertEqual(peripheral.sent[-1][1], STOP)

    async def test_target_is_one_shot_and_waits_for_observed_height(self):
        peripheral = Peripheral()
        packet = bytes.fromhex("F1F11B0202DAF97E")  # 730 mm; independent static vector
        peripheral.on_command = lambda data: peripheral.notify("F2F2010202DA") if data[2] == 0x1B else None
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            result = await desk.go_to(730, 0.1)
        targets = [data for _, data, _ in peripheral.sent if data[2] == 0x1B]
        self.assertEqual(targets, [packet])
        self.assertTrue(result["target_reached"])
        self.assertEqual(peripheral.sent[-1][1], STOP)

    async def test_target_timeout_and_out_of_range(self):
        peripheral = Peripheral()
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            with self.assertRaisesRegex(DeskError, "outside discovered"):
                await desk.go_to(1500, 0.05)
            self.assertFalse(any(data[2] == 0x1B for _, data, _ in peripheral.sent))
            with self.assertRaisesRegex(DeskError, "not reached"):
                await desk.go_to(1000, 0.05)
        self.assertEqual(peripheral.sent[-1][1], STOP)

    async def test_cancellation_attempts_stop_before_disconnect(self):
        peripheral = Peripheral()
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            operation = asyncio.create_task(desk.jog("up", 20))
            await asyncio.wait_for(peripheral.moved.wait(), 1)
            operation.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await operation
            self.assertTrue(peripheral.is_connected)
            self.assertEqual(peripheral.sent[-1][1], STOP)
        self.assertFalse(peripheral.is_connected)

    async def test_disconnect_during_motion_reports_failed_stop(self):
        peripheral = Peripheral()
        peripheral.on_command = lambda data: setattr(peripheral, "is_connected", False) if data == UP else None
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            with self.assertRaisesRegex(DeskError, "disconnected") as raised:
                await desk.jog("up", 0.2)
            self.assertIn("Stop delivery also failed", raised.exception.__notes__[0])

    async def test_cleanup_failure_is_not_silenced(self):
        class BrokenCleanup(Peripheral):
            async def disconnect(self):
                raise OSError("state save failed")
        with self.assertRaisesRegex(DeskError, "state save failed"):
            async with self.desk(BrokenCleanup()):
                pass


class ProfileTest(unittest.TestCase):
    def test_missing_ambiguous_or_wrong_properties_are_rejected(self):
        peripheral = Peripheral()
        with self.assertRaisesRegex(DeskError, "No supported"):
            select_profile([])
        with self.assertRaisesRegex(DeskError, "Ambiguous"):
            select_profile(peripheral.services * 2)
        with self.assertRaisesRegex(DeskError, "No supported"):
            select_profile(peripheral.services, "fe60")
        with self.assertRaisesRegex(DeskError, "No supported"):
            select_profile(Peripheral(notifications=False).services)

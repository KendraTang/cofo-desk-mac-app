import asyncio
import time
from types import SimpleNamespace as Item
import unittest

from cofo_desk.desk import Desk, DeskError, select_profile
from cofo_desk.protocol import LOGIN_BYTES, LOGIN_CHARACTERISTIC, LOGIN_SERVICE, QUERY_HEIGHT, QUERY_LIMITS, STOP, UP
from support import Peripheral


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

    async def test_stop_without_login_service_is_one_write_without_notifications_or_queries(self):
        peripheral = Peripheral(notifications=False, height=False, limits=False)
        async with self.desk(peripheral) as desk:
            steps = await desk.stop_now()
        self.assertEqual(peripheral.subscribe_count, 0)
        self.assertEqual([packet for _, packet, _ in peripheral.sent], [bytes.fromhex("F1F12B002B7E")])
        self.assertEqual(steps, [{"step": "stop", "completed": True, "error": None}])
        self.assertEqual(desk.stops.report(), {"stop_attempted": True, "stop_write_completed": True,
                                               "stop_errors": [], "physical_stop_confirmed": False})

    def with_login(self, peripheral):
        login = Item(uuid=LOGIN_CHARACTERISTIC, properties=["write"])
        peripheral.services.append(Item(uuid=LOGIN_SERVICE, characteristics=[login]))
        return login

    async def test_stop_with_login_service_is_stop_login_stop(self):
        peripheral = Peripheral(notifications=False)
        login = self.with_login(peripheral)
        async with self.desk(peripheral) as desk:
            steps = await desk.stop_now()
        self.assertEqual([(c, data) for c, data, _ in peripheral.sent],
                         [(peripheral.writer, STOP), (login, LOGIN_BYTES), (peripheral.writer, STOP)])
        self.assertTrue(all(step["completed"] for step in steps))

    async def test_login_gate_rejecting_first_stop_still_gets_final_stop(self):
        class Gated(Peripheral):
            logged_in = False
            async def write_gatt_char(self, characteristic, data, *, response):
                if data == LOGIN_BYTES:
                    self.logged_in = True
                elif data == STOP and not self.logged_in:
                    raise OSError("ATT write rejected")
                await super().write_gatt_char(characteristic, data, response=response)
        peripheral = Gated()
        self.with_login(peripheral)
        async with self.desk(peripheral) as desk:
            steps = await desk.stop_now()
        self.assertEqual([(s["step"], s["completed"]) for s in steps], [("stop", False), ("login", True), ("stop", True)])
        self.assertEqual(steps[0]["error"], "ATT write rejected")
        self.assertEqual(desk.stops.report()["stop_errors"], ["ATT write rejected"])
        self.assertTrue(desk.stops.completed)

    async def test_stuck_login_times_out_without_skipping_final_stop(self):
        class StuckLogin(Peripheral):
            async def write_gatt_char(self, characteristic, data, *, response):
                if data == LOGIN_BYTES:
                    await asyncio.Event().wait()
                await super().write_gatt_char(characteristic, data, response=response)
        peripheral = StuckLogin()
        self.with_login(peripheral)
        async with self.desk(peripheral, login_timeout=0.05) as desk:
            steps = await desk.stop_now()
        self.assertEqual(steps[1], {"step": "login", "completed": False, "error": "Write timed out after 0.05 s"})
        self.assertEqual([data for _, data, _ in peripheral.sent], [STOP, STOP])

    async def test_disconnect_mid_sequence_is_reported_not_reconnected(self):
        peripheral = Peripheral()
        self.with_login(peripheral)
        peripheral.on_command = lambda data: setattr(peripheral, "is_connected", False)
        async with self.desk(peripheral) as desk:
            steps = await desk.stop_now()
        self.assertEqual([s["completed"] for s in steps], [True, False, False])
        self.assertEqual(steps[2]["error"], "not attempted: device disconnected")
        self.assertEqual(len(peripheral.sent), 1)

    async def test_stop_is_not_attempted_before_a_control_characteristic_exists(self):
        async with self.desk(Peripheral()) as desk:
            with self.assertRaisesRegex(DeskError, "not attempted"):
                await desk.send_stop()
        self.assertFalse(desk.stops.attempted)

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
        skew = [0.0]
        # Time moves on without new height samples once UP is written.
        clock = lambda: time.monotonic() + skew[0]
        async with self.desk(peripheral, clock=clock) as desk:
            await desk.prepare(require_limits=True)
            peripheral.on_command = lambda data: skew.__setitem__(0, 2.0) if data == UP else None
            with self.assertRaisesRegex(DeskError, "stale"):
                await desk.jog("up", 20)
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

    async def test_cancelled_jog_queues_no_direction_after_stop(self):
        peripheral = Peripheral()
        async with self.desk(peripheral) as desk:
            await desk.prepare(require_limits=True)
            operation = asyncio.create_task(desk.jog("up", 20))
            await asyncio.wait_for(peripheral.moved.wait(), 1)
            operation.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await operation
            # Longer than the 100 ms resend interval: a leaked loop would write UP again.
            await asyncio.sleep(0.15)
        packets = [packet for _, packet, _ in peripheral.sent]
        self.assertEqual(packets[-1], STOP)
        self.assertEqual(packets.count(STOP), 1)

    async def test_failed_or_timed_out_direction_write_still_attempts_stop(self):
        for failure in ("error", "timeout"):
            with self.subTest(failure=failure):
                class Failing(Peripheral):
                    async def write_gatt_char(self, characteristic, data, *, response):
                        if data == UP:
                            if failure == "error":
                                raise OSError("ATT write rejected")
                            await asyncio.Event().wait()
                        await super().write_gatt_char(characteristic, data, response=response)
                peripheral = Failing()
                async with self.desk(peripheral, write_timeout=0.05) as desk:
                    await desk.prepare(require_limits=True)
                    with self.assertRaisesRegex(Exception, "rejected|timed out"):
                        await desk.jog("up", 1)
                self.assertEqual(peripheral.sent[-1][1], STOP)
                self.assertTrue(desk.stops.completed)

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

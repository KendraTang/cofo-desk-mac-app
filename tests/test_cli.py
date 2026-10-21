import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CliTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / "state.json"
        self.base = [sys.executable, "-m", "cofo_desk", "--json", "--simulate", "--state-file", str(self.state)]

    def command(self, *arguments, code=0, base=None):
        result = subprocess.run((base or self.base) + list(arguments), cwd=ROOT,
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def value(self, *arguments, code=0, base=None):
        result = self.command(*arguments, code=code, base=base)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def test_status_and_state_are_explicitly_simulated(self):
        status = self.value("status")
        self.assertTrue(status["simulated"])
        self.assertEqual(status["height_mm"], 720)
        self.assertEqual(status["limits_mm"], [630, 1280])
        self.assertEqual(status["memory_mm"], {"M1": 1100, "M2": 720, "M3": None, "M4": None})
        state = json.loads(self.state.read_text())
        self.assertEqual(state, {"version": 1, "height_mm": 720})

    def test_target_in_mm_cm_inches_and_cross_process_persistence(self):
        for target, unit, expected in [(730, "mm", 730), (72, "cm", 720), (28.5, "in", 724)]:
            with self.subTest(unit=unit):
                result = self.value("goto", str(target), "--unit", unit, "--timeout", "3")
                self.assertEqual(result["target_mm"], expected)
                self.assertTrue(result["stop_sent"])
                self.assertTrue(result["target_reached"])
                status = self.value("status")
                self.assertAlmostEqual(status["height_mm"], expected, delta=1)
        height = self.value("status")["height_mm"]
        self.assertEqual(self.value("status")["height_mm"], height)

    def test_up_down_stop_and_no_resumed_motion(self):
        result = self.value("up", "--seconds", "0.2")
        self.assertTrue(result["stop_sent"])
        raised = self.value("status")["height_mm"]
        self.assertGreater(raised, 720)
        lowered = self.value("down", "--seconds", "0.1")["status"]["height_mm"]
        self.assertLess(lowered, raised)
        self.assertEqual(self.value("stop"), {"simulated": True, "stop_sent": True, "physical_stop_confirmed": False,
                                              "steps": [{"step": "stop", "completed": True, "error": None}]})
        self.assertEqual(self.value("status")["height_mm"], self.value("status")["height_mm"])

    def test_all_profiles_and_inspect(self):
        for profile, service in [("ff12", "0000ff12"), ("fe60", "0000fe60"), ("legacy", "88121427")]:
            base = self.base + ["--profile", profile]
            self.assertEqual(self.value("status", base=base)["profile"], profile)
            self.assertTrue(self.value("inspect", base=base)["services"][0]["uuid"].startswith(service))
            self.assertTrue(self.value("scan", base=base)["devices"][0]["service_uuids"][0].startswith(service))

    def test_scan_does_not_open_state_and_watch_is_json_lines(self):
        self.assertTrue(self.value("scan")["devices"][0]["supported_service_advertised"])
        self.assertFalse(self.state.exists())
        # The sample count depends on machine speed; the contract is one JSON object per line.
        lines = self.command("watch", "--seconds", "0.08").stdout.splitlines()
        self.assertGreaterEqual(len(lines), 1)
        for line in lines:
            self.assertEqual(json.loads(line)["height_mm"], 720)

    def test_invalid_input_never_opens_state(self):
        for arguments in [("up", "--seconds", "nan"), ("down", "--seconds", "inf"),
                          ("up", "--seconds", "31"), ("goto", "-1"), ("goto", "1e308"),
                          ("goto", "0.001", "--unit", "mm")]:
            with self.subTest(arguments=arguments):
                self.command(*arguments, code=2)
                self.assertFalse(self.state.exists())

    def test_missing_device_and_invalid_backend_options(self):
        base = [sys.executable, "-m", "cofo_desk"]
        self.assertIn("--device is required", self.command("status", code=2, base=base).stderr)
        self.assertIn("requires --simulate", self.command("--state-file", str(self.state), "scan", code=2, base=base).stderr)
        self.command("--device", "not-a-device", "status", code=2)

    def test_out_of_range_and_timeout_are_errors_without_resumed_motion(self):
        self.assertIn("outside discovered limits", self.value("goto", "150", code=1)["error"])
        self.assertEqual(self.value("status")["height_mm"], 720)
        self.assertIn("not reached", self.value("goto", "120", "--timeout", "0.08", code=1)["error"])
        stopped = self.value("status")["height_mm"]
        self.assertGreater(stopped, 720)
        self.assertEqual(self.value("status")["height_mm"], stopped)

    def test_corrupt_state_is_not_overwritten(self):
        for text in ['{"version": 1, "height_mm": NaN}', '[]', '{"version": 1, "height_mm": true}']:
            with self.subTest(text=text):
                self.state.write_text(text)
                self.assertIn("Invalid simulator state", self.value("status", code=1)["error"])
                self.assertEqual(self.state.read_text(), text)

    @unittest.skipIf(sys.platform == "win32", "POSIX signal and file locking")
    def test_concurrent_state_access_is_rejected(self):
        process = subprocess.Popen(self.base + ["watch", "--seconds", "10"], cwd=ROOT,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            line = process.stdout.readline()
            self.assertEqual(json.loads(line)["height_mm"], 720)
            self.assertIn("already in use", self.value("status", code=1)["error"])
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130, stderr)
            self.assertIn("Interrupted", stdout)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    @unittest.skipIf(sys.platform == "win32", "POSIX signals")
    def test_each_signal_cancels_once_reports_and_persists_state(self):
        # Movement-time STOP is covered in-process (test_interrupts); this checks real process wiring.
        for signum, code in [(signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129)]:
            with self.subTest(signal=signum.name):
                self.state.unlink(missing_ok=True)
                process = subprocess.Popen(self.base + ["watch", "--seconds", "30"], cwd=ROOT,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    self.assertEqual(json.loads(process.stdout.readline())["height_mm"], 720)
                    process.send_signal(signum)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, code, stderr)
                    report = json.loads(stdout.splitlines()[-1])
                    self.assertEqual(report["signal"], signum.name)
                    self.assertFalse(report["stop_attempted"])
                    self.assertFalse(report["physical_stop_confirmed"])
                    self.assertEqual(json.loads(self.state.read_text())["height_mm"], 720)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate()

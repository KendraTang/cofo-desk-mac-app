from contextlib import redirect_stderr, redirect_stdout
import io
import unittest

from cofo_desk.cli import (
    Result, emit, emit_error, inspect_lines, jog_lines, scan_lines, status_lines, stop_lines, target_lines,
)


STATUS = {"simulated": True, "height_mm": 720, "height_cm": 72.0, "height_in": 28.35, "limits_mm": [630, 1280],
          "error": None, "native_unit": "cm", "unit_source": "notification"}


class TextOutputTest(unittest.TestCase):
    def text(self, value, lines=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            if lines is None:
                emit_error(value, False)
            else:
                emit(Result(value, lines), False)
        return stdout.getvalue(), stderr.getvalue()

    def test_scan_lists_devices_or_says_none(self):
        devices = {"devices": [{"address": "uuid-one", "name": None, "rssi": -60}]}
        self.assertEqual(self.text(devices, scan_lines), ("uuid-one  (unnamed)  RSSI -60\n", ""))
        self.assertEqual(self.text({"devices": []}, scan_lines), ("No peripherals found.\n", ""))

    def test_inspect_indents_characteristics(self):
        value = {"services": [{"uuid": "svc", "characteristics": [{"uuid": "chr", "properties": ["write", "notify"]}]}]}
        self.assertEqual(self.text(value, inspect_lines), ("svc\n  chr  write, notify\n", ""))

    def test_status_labels_simulation_and_units(self):
        self.assertEqual(self.text(STATUS, status_lines)[0],
                         "SIMULATED  72.0 cm / 28.35 in  limits [630, 1280] mm  error none  unit cm (notification)\n")

    def test_motion_results_name_the_outcome_then_status(self):
        jog = self.text({"direction": "up", "reason": "limit", "status": STATUS}, jog_lines)[0]
        self.assertTrue(jog.startswith("up finished (limit); stop sent.\nSIMULATED"))
        target = self.text({"target_mm": 800, "target_reached": True, "status": STATUS}, target_lines)[0]
        self.assertTrue(target.startswith("Target 800 mm observed; stop sent.\n"))

    def test_stop_lists_each_step(self):
        steps = [{"step": "stop", "completed": False, "error": "ATT write rejected"},
                 {"step": "login", "completed": True, "error": None}, {"step": "stop", "completed": True, "error": None}]
        self.assertEqual(self.text({"steps": steps}, stop_lines)[0], "stop: ATT write rejected\nlogin: written\nstop: written\n"
                         "Stop sent. Physical stop is not confirmed by the protocol.\n")

    def test_json_is_the_value_whatever_the_rendering(self):
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            emit(Result({"error": "kept as data", "height_mm": 1}, status_lines), True)
        self.assertEqual(stdout.getvalue(), '{"error": "kept as data", "height_mm": 1}\n')

    def test_errors_go_to_stderr(self):
        self.assertEqual(self.text({"error": "Interrupted by SIGTERM; no STOP was attempted"}),
                         ("", "Error: Interrupted by SIGTERM; no STOP was attempted\n"))

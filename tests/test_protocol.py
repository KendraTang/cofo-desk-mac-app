import unittest

from cofo_desk.protocol import DOWN, QUERY_HEIGHT, QUERY_LIMITS, STOP, UP, Event, PROFILES, notification_events, target_frame


class ProtocolTest(unittest.TestCase):
    def test_recovered_control_frames(self):
        for actual, expected in [
            (UP, "F1F10100017E"), (DOWN, "F1F10200027E"), (STOP, "F1F12B002B7E"),
            (QUERY_HEIGHT, "F1F10C000C7E"), (QUERY_LIMITS, "F1F10700077E"),
            (target_frame(1050), "F1F11B02041A3B7E"), (target_frame(65535), "F1F11B02FFFF1B7E"),
        ]:
            with self.subTest(expected=expected):
                self.assertEqual(actual.hex().upper(), expected)

    def test_target_field_validation(self):
        for value in [-1, 65536, 1.5, True]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                target_frame(value)

    def test_height_accepts_extra_fields_and_single_or_double_prefix(self):
        self.assertEqual(notification_events(bytes.fromhex("F2F2010302D000")), [Event("height", 720)])
        self.assertEqual(notification_events(bytes.fromhex("F2010202D0")), [Event("height", 720)])

    def test_units_limits_and_multiple_events_in_order(self):
        events = notification_events(bytes.fromhex("F2F20E0100 F2F2070405000276 F2F2010202D0"))
        self.assertEqual(events, [Event("unit", "cm"), Event("limits", (630, 1280)), Event("height", 720)])
        self.assertEqual(notification_events(bytes.fromhex("F2F20E0101")), [Event("unit", "in")])

    def test_errors_match_original_display_including_unusual_ten(self):
        for code, expected in [(1, "E01"), (10, "E010"), (13, "E013"), (14, "H01"), (15, "H02"), (16, "LOCK"), (255, "UNKNOWN_0xFF")]:
            self.assertEqual(notification_events(bytes((0xF2, 0xF2, 2, 1, code))), [Event("error", expected)])
        self.assertEqual(notification_events(bytes.fromhex("F2F204")), [Event("error", "RST")])

    def test_truncated_noise_and_invalid_limits_never_become_telemetry(self):
        for data in [b"", b"garbage", bytes.fromhex("F2"), bytes.fromhex("F2F2010302D0"), bytes.fromhex("F2F2070402000500"), bytes.fromhex("F2F20E0102")]:
            self.assertEqual(notification_events(data), [], data.hex())

    def test_profiles_match_original_uuid_families(self):
        self.assertEqual([p.name for p in PROFILES], ["ff12", "fe60", "legacy"])
        self.assertEqual(PROFILES[0].write, "0000ff01-0000-1000-8000-00805f9b34fb")
        self.assertEqual(PROFILES[1].notify, "0000fe62-0000-1000-8000-00805f9b34fb")
        self.assertEqual(PROFILES[2].write, PROFILES[2].notify)


if __name__ == "__main__":
    unittest.main()

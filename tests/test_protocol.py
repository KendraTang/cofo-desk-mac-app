import unittest

from cofo_desk.protocol import (
    DOWN, MAX_FRAME_BYTES, QUERY_HEIGHT, QUERY_LIMITS, STOP, UP, Event, NotificationReader, PROFILES,
    notification_events, notification_frame, target_frame,
)


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

    # Captured from the user's desk on 2026-10-20 (docs/hardware-evidence).
    REAL_HEIGHT = bytes.fromhex("F2F20103027607837E")
    REAL_LIMITS = bytes.fromhex("F2F2070405000276887E")
    REAL_STATUS_BURST = bytes.fromhex("F2F20E01000F7EF2F21901001A7EF2F2170101197EF2F21D0102207EF2F20103027607837E")

    def test_real_desk_frames(self):
        self.assertEqual(notification_events(self.REAL_HEIGHT), [Event("height", 630)])
        self.assertEqual(notification_events(self.REAL_LIMITS), [Event("limits", (630, 1280))])
        # Unknown opcodes 19/17/1D are valid frames but ignored.
        self.assertEqual(notification_events(self.REAL_STATUS_BURST), [Event("unit", "cm"), Event("height", 630)])
        self.assertEqual(notification_frame(0x01, bytes.fromhex("027607")), self.REAL_HEIGHT)

    # The burst after a limits query on 2026-10-21; the panel showed 96 after M1 and 63 after M2.
    REAL_MEMORY_BURST = bytes.fromhex("F2F2250203BFE97EF2F226020277A17EF2F2270205002E7EF2F2280200002A7E")

    def test_real_desk_memory_frames(self):
        self.assertEqual(notification_events(self.REAL_MEMORY_BURST), [
            Event("memory", (1, 959)), Event("memory", (2, 631)), Event("memory", (3, 1280)), Event("memory", (4, 0))])
        self.assertEqual(notification_events(notification_frame(0x25, b"\x03")), [])

    def test_frames_split_across_notifications_are_joined(self):
        reader = NotificationReader()
        # The real split seen on the desk: the height frame's 7E arrived alone.
        self.assertEqual(reader.feed(bytes.fromhex("F2F2070405000276887EF2F20103")), [Event("limits", (630, 1280))])
        self.assertEqual(reader.feed(bytes.fromhex("02760783")), [])
        self.assertEqual(reader.feed(bytes.fromhex("7E")), [Event("height", 630)])
        self.assertEqual(reader.pending, b"")

    def test_abandoned_fragment_does_not_hide_the_next_frame(self):
        reader = NotificationReader()
        self.assertEqual(reader.feed(bytes.fromhex("F2F20103")), [])
        self.assertEqual(reader.feed(self.REAL_HEIGHT), [Event("height", 630)])
        # The real desk's stray "...7E F2" followed by "CC FF".
        self.assertEqual(reader.feed(self.REAL_HEIGHT + b"\xf2"), [Event("height", 630)])
        self.assertEqual(reader.feed(bytes.fromhex("CCFF")), [])
        self.assertEqual(reader.pending, b"")
        self.assertEqual(reader.feed(self.REAL_HEIGHT), [Event("height", 630)])

    def test_bad_checksum_trailer_or_single_prefix_is_never_used(self):
        for data in [self.REAL_HEIGHT[:-2] + b"\x84\x7e", self.REAL_HEIGHT[:-1] + b"\x00",
                     bytes.fromhex("F2010202D0"), bytes.fromhex("F20103027607837E")]:
            with self.subTest(data=data.hex()):
                self.assertEqual(notification_events(data), [])

    def test_pending_tail_stays_below_the_frame_limit(self):
        reader = NotificationReader()
        # A false start claiming a 200-byte payload is skipped instead of awaited.
        self.assertEqual(reader.feed(bytes.fromhex("F2F201C8") + self.REAL_HEIGHT), [Event("height", 630)])
        reader.feed(bytes(range(256)) * 4)
        self.assertLess(len(reader.pending), MAX_FRAME_BYTES)

    def test_units_limits_and_multiple_events_in_order(self):
        events = notification_events(notification_frame(0x0E, b"\x00") + self.REAL_LIMITS + notification_frame(0x01, bytes.fromhex("02D007")))
        self.assertEqual(events, [Event("unit", "cm"), Event("limits", (630, 1280)), Event("height", 720)])
        self.assertEqual(notification_events(notification_frame(0x0E, b"\x01")), [Event("unit", "in")])

    def test_errors_match_original_display_including_unusual_ten(self):
        for code, expected in [(1, "E01"), (10, "E010"), (13, "E013"), (14, "H01"), (15, "H02"), (16, "LOCK"), (255, "UNKNOWN_0xFF")]:
            self.assertEqual(notification_events(notification_frame(0x02, bytes((code,)))), [Event("error", expected)])
        self.assertEqual(notification_events(notification_frame(0x04)), [Event("error", "RST")])

    def test_truncated_noise_and_invalid_fields_never_become_telemetry(self):
        for data in [b"", b"garbage", bytes.fromhex("F2"), self.REAL_HEIGHT[:-1],
                     notification_frame(0x07, bytes.fromhex("02000500")), notification_frame(0x0E, b"\x02"),
                     notification_frame(0x01, b"\x02")]:
            self.assertEqual(notification_events(data), [], data.hex())

    def test_profiles_match_original_uuid_families(self):
        self.assertEqual([p.name for p in PROFILES], ["ff12", "fe60", "legacy"])
        self.assertEqual(PROFILES[0].write, "0000ff01-0000-1000-8000-00805f9b34fb")
        self.assertEqual(PROFILES[1].notify, "0000fe62-0000-1000-8000-00805f9b34fb")
        self.assertEqual(PROFILES[2].write, PROFILES[2].notify)


if __name__ == "__main__":
    unittest.main()

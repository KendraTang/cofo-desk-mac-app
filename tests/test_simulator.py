from pathlib import Path
import tempfile
import unittest

from cofo_desk.desk import DeskError
from cofo_desk.protocol import STOP, UP, target_frame
from cofo_desk.simulator import SimulatedClient


class SimulatorFrameTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.client = SimulatedClient(Path(self.temporary.name) / "state.json")
        await self.client.connect()

    async def asyncTearDown(self):
        await self.client.disconnect()
        self.temporary.cleanup()

    async def write(self, data):
        await self.client.write_gatt_char(self.client.writer, data, response=True)

    async def test_target_frame_needs_valid_checksum_and_trailer(self):
        valid = target_frame(800)
        for corrupt in [valid[:6] + bytes(((valid[6] + 1) & 255, 0x7E)), valid[:7] + b"\x00",
                        valid[:6] + bytes(((valid[6] + 1) & 255,)) + b"\x00"]:
            with self.subTest(frame=corrupt.hex()), self.assertRaisesRegex(DeskError, "Unsupported"):
                await self.write(corrupt)
        self.assertIsNone(self.client.target)
        await self.write(valid)
        self.assertEqual(self.client.target, 800)
        await self.write(STOP)
        self.assertIsNone(self.client.target)

    async def test_direction_frames_are_matched_whole(self):
        with self.assertRaisesRegex(DeskError, "Unsupported"):
            await self.write(UP[:-1] + b"\x00")
        self.assertEqual(self.client.direction, 0)

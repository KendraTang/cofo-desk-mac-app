"""Shared GATT fixtures for the CLI and desk tests."""
import asyncio
from types import SimpleNamespace as Item

from cofo_desk.protocol import UP


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

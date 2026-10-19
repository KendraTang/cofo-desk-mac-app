#!/usr/bin/env python3
"""Permission/fallback smoke on an emulator. Only interacts with this app and OS permission UI.

Temporarily changes this app's runtime permissions, restores them, and cancels its countdown.
Requires a built/installed dev.cofodesk.auto and Android platform-tools.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--serial", default="emulator-5554")
args = parser.parse_args()
if not args.serial.startswith("emulator-"):
    raise SystemExit("This smoke test only runs on an Android emulator.")
sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
adb = str(sdk / "platform-tools/adb")
package = "dev.cofodesk.auto"
permissions = ["android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT", "android.permission.POST_NOTIFICATIONS"]


def run(*parts):
    return subprocess.check_output([adb, "-s", args.serial, *parts], text=True, timeout=25)


def shell(*parts):
    return run("shell", *parts)


def tree():
    shell("uiautomator", "dump", "/data/local/tmp/cofo-desk-auto-smoke.xml")
    return ET.fromstring(shell("cat", "/data/local/tmp/cofo-desk-auto-smoke.xml"))


def tap_node(node):
    owner = node.get("package", "")
    if owner != package and not owner.endswith("permissioncontroller"):
        raise AssertionError(f"Refusing to interact with unexpected package {owner}")
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "")))
    shell("input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


def tap_id(name, scroll=False):
    for _ in range(5 if scroll else 1):
        ui = tree()
        for node in ui.iter("node"):
            if node.get("resource-id") == f"{package}:id/{name}":
                tap_node(node)
                return
        if not scroll:
            break
        # Derive the swipe from the app's observed scroll view, never another app.
        view = next((n for n in ui.iter("node") if n.get("scrollable") == "true" and n.get("package") == package), None)
        if view is None:
            break
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", view.get("bounds")))
        shell("input", "swipe", str((x1+x2)//2), str(y2-80), str((x1+x2)//2), str(y1+80), "300")
    raise AssertionError(f"Control not found: {name}")


def deny_permission():
    ui = tree()
    node = next((n for n in ui.iter("node") if n.get("resource-id", "").endswith(":id/permission_deny_button")), None)
    if node is None:
        raise AssertionError("Expected OS runtime-permission dialog")
    tap_node(node)


def texts():
    return "\n".join(n.get("text", "") for n in tree().iter("node") if n.get("package") == package)


def launch():
    shell("am", "force-stop", package)
    shell("am", "start", "-W", "-n", f"{package}/.MainActivity")


api = int(shell("getprop", "ro.build.version.sdk").strip())
if api < 33:
    raise SystemExit("This permission matrix requires API 33+.")
dump = shell("dumpsys", "package", package)
original = {p: bool(re.search(re.escape(p) + r": granted=true", dump)) for p in permissions}

try:
    for p in permissions[:2]:
        shell("pm", "revoke", package, p)
    launch()
    tap_id("devices", scroll=True)
    tap_id("scan")
    deny_permission()
    tap_id("tab_control")
    tap_id("connect")
    assert "模擬桌已連線" in texts()
    print("PASS E01: BLE permission denied; simulator remains usable", flush=True)

    for p in permissions[:2]:
        shell("pm", "grant", package, p)
    tap_id("devices", scroll=True)
    tap_id("scan")
    end = time.monotonic() + 20
    report = texts()
    while "掃描中（10 秒）" in report and time.monotonic() < end:
        time.sleep(.5)
        report = texts()
    assert any(s in report for s in ["掃描結束", "藍牙不可用", "BLE 掃描器不可用", "掃描失敗"]), report
    print("PASS E02/E03: scanner terminates or reports unavailable Bluetooth", flush=True)

    shell("pm", "revoke", package, permissions[2])
    launch()
    tap_id("tab_reminders")
    tap_id("start_timer", scroll=True)
    deny_permission()
    assert "剩餘" in texts()
    tap_id("cancel_timer", scroll=True)
    assert "沒有進行中的倒數" in texts()
    print("PASS E05: notification denial preserves in-app timer; cancellation works", flush=True)
finally:
    # Cancel alarms even if a UI assertion failed, without deleting user preferences.
    shell("am", "force-stop", package)
    for p, granted in original.items():
        shell("pm", "grant" if granted else "revoke", package, p)
    launch()

package dev.cofodesk.auto;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/** BLE discovery and GATT listing; never writes to a device. */
final class DevicesPage implements Page {
    private final Views ui;
    private final BleInspector inspector;
    private final LinearLayout results;

    DevicesPage(Views ui, BleInspector inspector) {
        this.ui = ui;
        this.inspector = inspector;
        ui.title(ui.string(R.string.devices_title));
        ui.note(ui.string(R.string.devices_note));
        ui.button(ui.content, ui.string(R.string.scan), R.id.scan, () -> {
            if (inspector.permitted()) inspector.scan();
            else ui.activity.requestPermissions(BleInspector.permissions(), MainActivity.REQUEST_BLE_SCAN);
        });
        results = ui.card(ui.string(R.string.ble_results));
        showDevices();
        ui.button(ui.content, ui.string(R.string.copy_report), 0, () -> {
            ui.activity.getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("BLE GATT", inspector.report()));
            ui.toast(ui.string(R.string.copied), Toast.LENGTH_SHORT);
        });
    }
    /** Rebuilt only when the inspector reports a change, not on every tick, so the buttons stay usable. */
    void showDevices() {
        results.removeAllViews();
        TextView report = ui.text(inspector.report(), 13, ui.colors.muted());
        report.setTextIsSelectable(true);
        results.addView(report);
        for (BleInspector.Device device : inspector.devices())
            ui.button(results, device.name() + "\n" + device.address() + "   " + device.rssi() + " dBm", 0, () -> inspector.inspect(device.address()));
    }
    @Override public void refresh() { }
}

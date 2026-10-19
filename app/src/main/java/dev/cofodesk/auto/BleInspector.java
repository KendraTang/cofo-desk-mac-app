package dev.cofodesk.auto;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.*;
import java.util.*;

/** Discovery-only tool. No characteristic or descriptor write is exposed. */
@SuppressLint("MissingPermission")
final class BleInspector {
    record Device(String name, String address, int rssi) {}
    private final Context context;
    private final Runnable changed;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Map<String, Device> devices = new LinkedHashMap<>();
    private BluetoothLeScanner scanner;
    private BluetoothGatt gatt;
    private String report;
    private boolean scanning;
    private final Runnable stopScanTask = this::stopScan;
    private final Runnable connectionTimeout = this::connectionExpired;
    private void connectionExpired() { closeGatt(); report = s(R.string.ble_timeout); changed.run(); }
    BleInspector(Context context, Runnable changed) { this.context = context; this.changed = changed; report = s(R.string.ble_intro); }
    private String s(int resource, Object... values) { return context.getString(resource, values); }
    List<Device> devices() { return new ArrayList<>(devices.values()); }
    String report() { return report; }
    static String[] permissions() {
        return Build.VERSION.SDK_INT >= 31 ? new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT}
                : new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }
    boolean permitted() {
        for (String p : permissions()) if (context.checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) return false;
        return true;
    }
    void scan() {
        stopScan(); closeGatt(); devices.clear();
        if (!permitted()) { report = s(R.string.ble_permission); changed.run(); return; }
        BluetoothAdapter adapter = context.getSystemService(BluetoothManager.class).getAdapter();
        if (adapter == null || !adapter.isEnabled()) { report = s(R.string.ble_unavailable); changed.run(); return; }
        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) { report = s(R.string.ble_no_scanner); changed.run(); return; }
        try {
            scanning = true; report = s(R.string.ble_scanning);
            scanner.startScan(callback); handler.postDelayed(stopScanTask, 10_000);
        } catch (SecurityException | IllegalStateException e) { scanning = false; report = s(R.string.ble_start_failed); }
        changed.run();
    }
    private final ScanCallback callback = new ScanCallback() {
        @Override public void onScanResult(int type, ScanResult result) {
            if (!scanning) return;
            try {
                String address = result.getDevice().getAddress();
                String name = result.getScanRecord() == null ? null : result.getScanRecord().getDeviceName();
                devices.put(address, new Device(name == null ? s(R.string.ble_unnamed) : name, address, result.getRssi()));
                changed.run();
            } catch (SecurityException e) { stopScan(); report = s(R.string.ble_revoked); changed.run(); }
        }
        @Override public void onScanFailed(int code) { scanning = false; report = s(R.string.ble_failed_code, code); changed.run(); }
    };
    void stopScan() {
        handler.removeCallbacks(stopScanTask);
        if (scanning && scanner != null) try { scanner.stopScan(callback); } catch (SecurityException | IllegalStateException ignored) {}
        if (scanning) { report = devices.isEmpty() ? s(R.string.ble_empty) : s(R.string.ble_done); }
        scanning = false;
        changed.run();
    }
    void inspect(String address) {
        stopScan(); closeGatt();
        if (!permitted()) { report = s(R.string.ble_regrant); changed.run(); return; }
        report = s(R.string.ble_connecting); changed.run();
        try {
            BluetoothAdapter adapter = context.getSystemService(BluetoothManager.class).getAdapter();
            gatt = adapter.getRemoteDevice(address).connectGatt(context, false, new BluetoothGattCallback() {
                @Override public void onConnectionStateChange(BluetoothGatt device, int status, int state) {
                    handler.post(() -> {
                        if (gatt != device) { device.close(); return; }
                        if (status == BluetoothGatt.GATT_SUCCESS && state == BluetoothProfile.STATE_CONNECTED) {
                            try { if (!device.discoverServices()) fail(s(R.string.ble_discovery_failed)); }
                            catch (SecurityException e) { fail(s(R.string.ble_revoked)); }
                        } else { fail(s(R.string.ble_disconnected_code, status)); }
                    });
                }
                @Override public void onServicesDiscovered(BluetoothGatt device, int status) {
                    handler.post(() -> {
                        if (gatt != device) return;
                        handler.removeCallbacks(connectionTimeout);
                        if (status != BluetoothGatt.GATT_SUCCESS) { fail(s(R.string.ble_service_failed_code, status)); return; }
                        StringBuilder text = new StringBuilder(s(R.string.ble_report)).append('\n');
                        for (BluetoothGattService service : device.getServices()) {
                            text.append("\nService ").append(service.getUuid()).append('\n');
                            for (BluetoothGattCharacteristic c : service.getCharacteristics())
                                text.append("  ").append(c.getUuid()).append(" properties=0x").append(Integer.toHexString(c.getProperties())).append('\n');
                        }
                        report = text.toString(); closeGatt(); changed.run();
                    });
                }
            }, BluetoothDevice.TRANSPORT_LE);
            handler.postDelayed(connectionTimeout, 15_000);
        } catch (SecurityException | IllegalArgumentException | NullPointerException e) { fail(s(R.string.ble_connection_failed)); }
    }
    private void fail(String message) { closeGatt(); report = message; changed.run(); }
    private void closeGatt() {
        handler.removeCallbacks(connectionTimeout);
        if (gatt != null) { BluetoothGatt current = gatt; gatt = null;
            try { current.disconnect(); current.close(); } catch (SecurityException ignored) {} }
    }
    void close() { stopScan(); boolean connecting = gatt != null; closeGatt(); if (connecting) { report = s(R.string.ble_cancelled); changed.run(); } }
}

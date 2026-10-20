package dev.cofodesk.auto;

import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Insets;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import dev.cofodesk.auto.core.ActivityHistory;
import dev.cofodesk.auto.core.DeskSession;
import dev.cofodesk.auto.core.Refused;
import dev.cofodesk.auto.core.SimulatedDesk;

/** Native Android front end: lifecycle, the foreground tick and tab navigation. Pages build their own views. */
public final class MainActivity extends Activity {
    static final int REQUEST_BLE_SCAN = 11;
    static final int REQUEST_NOTIFICATIONS = 12;
    private static final int CONTROL = 0, HISTORY = 1, REMINDERS = 2, SETTINGS = 3, DEVICES = 4;
    private static final int[] TAB_LABELS = {R.string.nav_control, R.string.nav_history, R.string.nav_reminders, R.string.nav_settings};
    private static final int[] TAB_IDS = {R.id.tab_control, R.id.tab_history, R.id.tab_reminders, R.id.tab_settings};
    private static final long TICK_MS = 100, MAX_TICK_MS = 2000, SAVE_INTERVAL_MS = 5000;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final SimulatedDesk simulator = new SimulatedDesk();
    private final DeskSession session = new DeskSession(simulator);
    private SessionStore store;
    private BleInspector inspector;
    private Views ui;
    private Page current;
    private int page;
    private long lastTick, lastSave;
    private ActivityHistory.Period period = ActivityHistory.Period.DAY;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long now = SystemClock.elapsedRealtime();
            session.advanceForeground(Math.min(now - lastTick, MAX_TICK_MS), System.currentTimeMillis());
            lastTick = now;
            session.takeAlert().ifPresent(alert -> {
                String message = UiText.alert(MainActivity.this, alert);
                Toast.makeText(MainActivity.this, message, Toast.LENGTH_LONG).show();
                ReminderReceiver.show(MainActivity.this, message);
            });
            current.refresh();
            if (now - lastSave > SAVE_INTERVAL_MS) { store.save(session); lastSave = now; }
            handler.postDelayed(this, TICK_MS);
        }
    };

    @Override public void onCreate(Bundle saved) {
        boolean dark = UiPreferences.dark(this);
        setTheme(dark ? R.style.AppThemeDark : R.style.AppTheme);
        super.onCreate(saved);
        ui = new Views(this, Palette.of(dark), this::perform);
        store = new SessionStore(this);
        store.load(session);
        store.loadSimulator(simulator);
        inspector = new BleInspector(this, () -> runOnUiThread(() -> { if (current instanceof DevicesPage devices) devices.showDevices(); }));
        if (saved != null) page = saved.getInt("page", CONTROL);
        build();
    }
    @Override protected void attachBaseContext(Context base) { super.attachBaseContext(UiPreferences.localized(base)); }
    @Override protected void onResume() {
        super.onResume();
        session.reconcileReminder(System.currentTimeMillis());
        // Alarms do not survive a reboot; re-arm a pending deadline. An expired one only updates the UI.
        if (session.reminderAtMs() > 0) ReminderReceiver.schedule(this, session.reminderAtMs()); else ReminderReceiver.cancelAlarm(this);
        lastTick = SystemClock.elapsedRealtime();
        handler.post(tick);
    }
    @Override protected void onPause() {
        handler.removeCallbacks(tick);
        session.pause();
        store.save(session);
        store.saveSimulator(simulator);
        inspector.close();
        super.onPause();
    }
    @Override protected void onDestroy() { handler.removeCallbacksAndMessages(null); inspector.close(); super.onDestroy(); }
    @Override protected void onSaveInstanceState(Bundle out) { out.putInt("page", page); super.onSaveInstanceState(out); }

    /** Runs a user action; refusals and bad numbers become messages, anything else saves and refreshes. */
    private void perform(Runnable action) {
        try {
            action.run();
            store.save(session);
            current.refresh();
        } catch (NumberFormatException e) {
            Toast.makeText(this, getString(R.string.invalid_number), Toast.LENGTH_LONG).show();
        } catch (Refused e) {
            Toast.makeText(this, UiText.refusal(this, e.reason()), Toast.LENGTH_LONG).show();
        }
    }
    private void show(int target) {
        session.stop();
        inspector.close();
        page = target;
        build();
    }
    /** Language and theme changes stop the motor and save before the Activity is recreated. */
    private void restyle(Runnable change) {
        change.run();
        session.pause();
        store.save(session);
        recreate();
    }
    private void build() {
        LinearLayout root = ui.column();
        root.setId(R.id.app_root);
        root.setBackgroundColor(ui.colors.background());
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets edges = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                view.setPadding(edges.left, edges.top, edges.right, edges.bottom);
            } else {
                view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        TextView brand = ui.text(getString(R.string.brand), 12, ui.colors.muted());
        brand.setPadding(ui.dp(22), ui.dp(12), ui.dp(22), ui.dp(8));
        root.addView(brand);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        ui.content = ui.column();
        ui.content.setPadding(ui.dp(22), 0, ui.dp(22), ui.dp(20));
        scroll.addView(ui.content);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        current = switch (page) {
            case HISTORY -> new HistoryPage(ui, session, period, selected -> { period = selected; build(); });
            case REMINDERS -> new ReminderPage(ui, session);
            case SETTINGS -> new SettingsPage(ui, session, this::restyle, () -> store.save(session));
            case DEVICES -> new DevicesPage(ui, inspector);
            default -> new ControlPage(ui, session, simulator, () -> show(DEVICES));
        };
        LinearLayout nav = new LinearLayout(this);
        nav.setBackgroundColor(ui.colors.surface());
        for (int i = 0; i < TAB_IDS.length; i++) {
            final int tab = i;
            Button button = new Button(this);
            button.setId(TAB_IDS[i]);
            button.setText(getString(TAB_LABELS[i]));
            button.setTextColor(page == i ? ui.colors.accent() : ui.colors.muted());
            button.setTextSize(13);
            ui.styleButton(button);
            button.setBackgroundColor(ui.colors.surface());
            button.setOnClickListener(view -> show(tab));
            nav.addView(button, new LinearLayout.LayoutParams(0, ui.dp(56), 1));
        }
        root.addView(nav);
        setContentView(root);
        current.refresh();
    }
    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == REQUEST_BLE_SCAN) {
            if (inspector.permitted()) inspector.scan();
            else Toast.makeText(this, getString(R.string.permission_ble_denied), Toast.LENGTH_LONG).show();
        }
        if (requestCode == REQUEST_NOTIFICATIONS && (results.length == 0 || results[0] != PackageManager.PERMISSION_GRANTED))
            Toast.makeText(this, getString(R.string.permission_notifications_denied), Toast.LENGTH_LONG).show();
    }
}

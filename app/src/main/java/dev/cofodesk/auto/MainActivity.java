package dev.cofodesk.auto;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.text.InputType;
import android.view.*;
import android.widget.*;
import dev.cofodesk.auto.core.*;
import java.time.LocalDate;
import java.util.Locale;
import java.util.OptionalDouble;
import java.util.OptionalInt;

/** Native Android front end. All motor state comes from the selected DeskPort. */
public final class MainActivity extends Activity {
    private int BLUE, INK, MUTED, SURFACE, BACKGROUND, BUTTON, LINE, LEG;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final SimulatedDesk simulator = new SimulatedDesk();
    private final DeskSession session = new DeskSession(simulator);
    private SessionStore store;
    private BleInspector inspector;
    private LinearLayout root, content, deviceList;
    private TextView height, status, timerStatus, historySummary;
    private DeskDrawing drawing;
    private Button connect, lock;
    private int page;
    private long lastTick, lastSave;
    private ActivityHistory.Period period = ActivityHistory.Period.DAY;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long now = SystemClock.elapsedRealtime();
            session.advanceForeground(Math.min(now - lastTick, 2000), System.currentTimeMillis());
            lastTick = now;
            String alert = session.takeAlert();
            if (!alert.isEmpty()) { String message = UiText.message(MainActivity.this, alert); Toast.makeText(MainActivity.this, message, Toast.LENGTH_LONG).show(); ReminderReceiver.show(MainActivity.this, message); }
            refresh();
            if (now - lastSave > 5000) { store.save(session); lastSave = now; }
            handler.postDelayed(this, 100);
        }
    };

    @Override public void onCreate(Bundle saved) {
        boolean dark = UiPreferences.dark(this);
        setTheme(dark ? R.style.AppThemeDark : R.style.AppTheme);
        super.onCreate(saved);
        BLUE = dark ? 0xff90b8ff : 0xff246bdf;
        INK = dark ? 0xffe6edf8 : 0xff1d2a3e;
        MUTED = dark ? 0xffb0bed3 : 0xff66778e;
        SURFACE = dark ? 0xff1b2638 : Color.WHITE;
        BACKGROUND = dark ? 0xff101827 : 0xfff4f7fc;
        BUTTON = dark ? 0xff263a58 : 0xffedf3fd;
        LINE = dark ? 0xff36465e : 0xffe0e7f2;
        LEG = dark ? 0xff91a6c5 : 0xff869ec4;
        store = new SessionStore(this); store.load(session); store.loadSimulator(simulator);
        inspector = new BleInspector(this, () -> runOnUiThread(this::refreshDevices));
        if (saved != null) page = saved.getInt("page", 0);
        build();
    }
    @Override protected void attachBaseContext(Context base) { super.attachBaseContext(UiPreferences.localized(base)); }
    private String s(int resource, Object... values) { return getString(resource, values); }
    @Override protected void onResume() {
        super.onResume(); session.reconcileReminder(System.currentTimeMillis());
        // Alarms do not survive a reboot; re-arm a pending deadline. An expired one only updates the UI.
        if (session.reminderAtMs() > 0) ReminderReceiver.schedule(this, session.reminderAtMs()); else ReminderReceiver.cancelAlarm(this);
        lastTick = SystemClock.elapsedRealtime(); handler.post(tick);
    }
    @Override protected void onPause() {
        handler.removeCallbacks(tick); session.pause(); store.save(session); store.saveSimulator(simulator); inspector.close();
        super.onPause();
    }
    @Override protected void onDestroy() { handler.removeCallbacksAndMessages(null); inspector.close(); super.onDestroy(); }
    @Override protected void onSaveInstanceState(Bundle out) { out.putInt("page", page); super.onSaveInstanceState(out); }

    private int dp(float n) { return (int) (getResources().getDisplayMetrics().density * n + .5f); }
    private TextView text(String value, float size, int color) {
        TextView v = new TextView(this); v.setText(value); v.setTextSize(size); v.setTextColor(color); v.setPadding(0, dp(5), 0, dp(5)); return v;
    }
    private LinearLayout column() { LinearLayout v = new LinearLayout(this); v.setOrientation(LinearLayout.VERTICAL); return v; }
    private GradientDrawable background(int color, int radius) {
        GradientDrawable bg = new GradientDrawable(); bg.setColor(color); bg.setCornerRadius(dp(radius)); return bg;
    }
    private Button button(LinearLayout parent, String title, int id, Runnable action) {
        Button v = new Button(this); v.setText(title); v.setTextColor(BLUE); v.setAllCaps(false); v.setMinHeight(dp(48));
        styleButton(v);
        if (id != 0) v.setId(id);
        v.setOnClickListener(view -> runAction(action)); parent.addView(v); return v;
    }
    private void styleButton(Button button) {
        button.setAllCaps(false); button.setMinHeight(dp(48));
        button.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x33246BDF), background(BUTTON, 10), null));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2); lp.setMargins(0, dp(4), 0, dp(4)); button.setLayoutParams(lp);
        button.setElevation(0);
    }
    private void runAction(Runnable action) {
        try { action.run(); store.save(session); refresh(); }
        catch (NumberFormatException e) { Toast.makeText(this, s(R.string.invalid_number), Toast.LENGTH_LONG).show(); }
        catch (IllegalArgumentException | IllegalStateException e) { Toast.makeText(this, UiText.message(this, e.getMessage()), Toast.LENGTH_LONG).show(); }
    }
    private void note(String value) { content.addView(text(value, 13, MUTED)); }
    private void title(String value) { content.addView(text(value, 25, INK)); }
    private LinearLayout card(String heading) {
        LinearLayout card = column(); card.setPadding(dp(18), dp(12), dp(18), dp(14)); card.setBackground(background(SURFACE, 18));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2); lp.setMargins(0, dp(12), 0, 0); content.addView(card, lp);
        if (!heading.isEmpty()) card.addView(text(heading, 17, INK)); return card;
    }
    private void build() {
        height = status = timerStatus = historySummary = null; drawing = null; connect = lock = null; deviceList = null;
        root = column(); root.setId(R.id.app_root); root.setBackgroundColor(BACKGROUND);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets edges = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                view.setPadding(edges.left, edges.top, edges.right, edges.bottom);
            } else view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        TextView brand = text(s(R.string.brand), 12, MUTED); brand.setPadding(dp(22), dp(12), dp(22), dp(8)); root.addView(brand);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true);
        content = column(); content.setPadding(dp(22), 0, dp(22), dp(20)); scroll.addView(content); root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        switch (page) { case 1 -> historyPage(); case 2 -> reminderPage(); case 3 -> settingsPage(); case 4 -> devicesPage(); default -> controlPage(); }
        LinearLayout nav = new LinearLayout(this); nav.setBackgroundColor(SURFACE);
        String[] labels = {s(R.string.nav_control), s(R.string.nav_history), s(R.string.nav_reminders), s(R.string.nav_settings)}; int[] ids = {R.id.tab_control, R.id.tab_history, R.id.tab_reminders, R.id.tab_settings};
        for (int i = 0; i < labels.length; i++) {
            final int selected = i;
            Button b = new Button(this); b.setId(ids[i]); b.setText(labels[i]); b.setTextColor(page == i ? BLUE : MUTED); b.setTextSize(13); b.setAllCaps(false);
            styleButton(b); b.setBackgroundColor(SURFACE);
            b.setOnClickListener(v -> { session.stop(); inspector.close(); page = selected; build(); }); nav.addView(b, new LinearLayout.LayoutParams(0, dp(56), 1));
        }
        root.addView(nav); setContentView(root); refresh();
    }
    private void controlPage() {
        title(s(R.string.control_title));
        note(s(R.string.simulator_note));
        LinearLayout panel = card("");
        status = text("", 14, MUTED); status.setId(R.id.status); status.setGravity(Gravity.CENTER); panel.addView(status);
        height = text("", 52, BLUE); height.setId(R.id.height); height.setGravity(Gravity.CENTER); panel.addView(height);
        drawing = new DeskDrawing(); panel.addView(drawing, new LinearLayout.LayoutParams(-1, dp(130)));
        connect = button(panel, "", R.id.connect, () -> { if (session.state().connected()) session.disconnect(); else session.connect(); });
        LinearLayout move = new LinearLayout(this); panel.addView(move);
        jogButton(move, s(R.string.up), R.id.up, true); jogButton(move, s(R.string.down), R.id.down, false);
        Button stop = button(panel, s(R.string.stop), R.id.stop, session::stop); stop.setTextColor(Color.rgb(177, 55, 55));
        LinearLayout memories = card(s(R.string.presets));
        note(s(R.string.preset_hint));
        for (int i = 0; i < 3; i++) {
            final int slot = i;
            Button b = button(memories, "M" + (i + 1) + "    " + session.height(session.preset(i)), new int[]{R.id.preset1, R.id.preset2, R.id.preset3}[i], () -> session.recall(slot));
            b.setOnLongClickListener(v -> { runAction(() -> { session.savePreset(slot); b.setText(String.format(Locale.US, "M%d    %s", slot + 1, session.height(session.preset(slot)))); Toast.makeText(this, s(R.string.preset_saved), Toast.LENGTH_SHORT).show(); }); return true; });
        }
        LinearLayout safety = card(s(R.string.simulator_tools));
        lock = button(safety, "", R.id.lock, () -> session.lock(!session.state().locked()));
        button(safety, s(R.string.collision), R.id.collision, simulator::collide);
        button(safety, s(R.string.recover), R.id.recover, simulator::clearFault);
        button(content, s(R.string.devices), R.id.devices, () -> { page = 4; build(); });
    }
    private void jogButton(LinearLayout parent, String label, int id, boolean up) {
        Button b = new JogButton(up); b.setText(label); b.setTextSize(14); b.setTextColor(BLUE); b.setId(id); styleButton(b);
        parent.addView(b, new LinearLayout.LayoutParams(0, dp(56), 1));
    }
    private final class JogButton extends Button {
        private final boolean up;
        private boolean touchClick;
        JogButton(boolean up) { super(MainActivity.this); this.up = up; setClickable(true); }
        @Override public boolean onTouchEvent(android.view.MotionEvent event) {
            switch (event.getActionMasked()) {
                case android.view.MotionEvent.ACTION_DOWN -> { runAction(() -> session.jog(up)); setPressed(true); }
                case android.view.MotionEvent.ACTION_UP -> {
                    session.stop(); setPressed(false); touchClick = true; performClick(); touchClick = false; refresh();
                }
                case android.view.MotionEvent.ACTION_CANCEL -> { session.stop(); setPressed(false); refresh(); }
                default -> { }
            }
            return true;
        }
        @Override public boolean performClick() {
            super.performClick();
            if (!touchClick) runAction(() -> session.moveTo(Math.max(SimulatedDesk.MIN_MM, Math.min(SimulatedDesk.MAX_MM, session.state().heightMm() + (up ? 10 : -10)))));
            return true;
        }
    }
    private void historyPage() {
        title(s(R.string.history_title)); note(s(R.string.history_note));
        LinearLayout filters = card(s(R.string.history));
        LinearLayout row = new LinearLayout(this); filters.addView(row);
        String[] labels = {s(R.string.period_day), s(R.string.period_week), s(R.string.period_month), s(R.string.period_year)};
        for (int i = 0; i < labels.length; i++) {
            final ActivityHistory.Period p = ActivityHistory.Period.values()[i]; Button b = new Button(this); b.setText(labels[i]); b.setTextColor(period == p ? BLUE : MUTED);
            styleButton(b); b.setTextSize(13); b.setPadding(0, 0, 0, 0);
            b.setOnClickListener(v -> { period = p; build(); }); row.addView(b, new LinearLayout.LayoutParams(0, dp(48), 1));
        }
        historySummary = text("", 19, INK); historySummary.setId(R.id.history_summary); filters.addView(historySummary);
        LinearLayout bars = card(s(R.string.recent_days));
        LocalDate today = session.history().date(System.currentTimeMillis());
        for (int i = 6; i >= 0; i--) {
            LocalDate date = today.minusDays(i); long minutes = session.history().day(date) / 60_000;
            bars.addView(text(s(R.string.daily_minutes, date.toString(), minutes), 13, MUTED));
            if (session.dailyGoalMinutes() == 0) continue;
            ProgressBar progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal); progress.setMax(session.dailyGoalMinutes()); progress.setProgress((int) Math.min(minutes, session.dailyGoalMinutes())); bars.addView(progress);
        }
        note(s(R.string.calorie_note));
    }
    private EditText field(LinearLayout parent, String label, String value, int id, boolean decimal) {
        parent.addView(text(label, 13, MUTED)); EditText edit = new EditText(this); edit.setId(id); edit.setText(value); edit.setTextSize(17);
        edit.setSingleLine(); edit.setInputType(InputType.TYPE_CLASS_NUMBER | (decimal ? InputType.TYPE_NUMBER_FLAG_DECIMAL : 0)); parent.addView(edit); return edit;
    }
    private void reminderPage() {
        title(s(R.string.reminder_title));
        LinearLayout goals = card(s(R.string.goals));
        EditText goal = field(goals, s(R.string.goal_label), "" + session.dailyGoalMinutes(), R.id.goal, false);
        shortcuts(goals, goal, new int[]{40, 60, 120, 180, 240}, new int[]{R.id.goal_40, R.id.goal_60, R.id.goal_120, R.id.goal_180, R.id.goal_240});
        EditText sit = field(goals, s(R.string.sit_label), "" + session.sittingReminderMinutes(), R.id.sit_minutes, false);
        shortcuts(goals, sit, new int[]{40, 60, 120}, new int[]{R.id.sit_40, R.id.sit_60, R.id.sit_120});
        EditText stand = field(goals, s(R.string.stand_label), "" + session.standingReminderMinutes(), R.id.stand_minutes, false);
        shortcuts(goals, stand, new int[]{40, 60, 120}, new int[]{R.id.stand_40, R.id.stand_60, R.id.stand_120});
        button(goals, s(R.string.save_goals), R.id.save_goals, () -> { session.configureGoals(Integer.parseInt(goal.getText().toString()), Integer.parseInt(sit.getText().toString()), Integer.parseInt(stand.getText().toString())); Toast.makeText(this, s(R.string.goals_saved), Toast.LENGTH_SHORT).show(); });
        note(s(R.string.posture_note));
        LinearLayout timer = card(s(R.string.countdown));
        EditText minutes = field(timer, s(R.string.minutes_label), "40", R.id.timer_minutes, false);
        timerStatus = text("", 17, BLUE); timerStatus.setId(R.id.timer_status); timer.addView(timerStatus);
        button(timer, s(R.string.start_timer), R.id.start_timer, () -> {
            session.startReminder(Integer.parseInt(minutes.getText().toString()), System.currentTimeMillis());
            ReminderReceiver.schedule(this, session.reminderAtMs());
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 12);
        });
        button(timer, s(R.string.cancel_timer), R.id.cancel_timer, () -> { session.cancelReminder(); ReminderReceiver.cancel(this); });
        note(s(R.string.countdown_note));
    }
    /** Shortcuts only fill the field; the user still saves explicitly. */
    private void shortcuts(LinearLayout parent, EditText target, int[] minutes, int[] ids) {
        LinearLayout row = new LinearLayout(this); parent.addView(row);
        for (int i = 0; i < minutes.length; i++) {
            int value = minutes[i];
            Button b = new Button(this); b.setId(ids[i]); b.setText(value % 60 == 0 ? value / 60 + "h" : value + "m"); b.setTextSize(12); b.setPadding(0, 0, 0, 0); styleButton(b);
            b.setOnClickListener(v -> target.setText(String.valueOf(value))); row.addView(b, new LinearLayout.LayoutParams(0, dp(48), 1));
        }
    }
    private static OptionalInt optionalInt(EditText field) {
        String value = field.getText().toString().trim();
        return value.isEmpty() ? OptionalInt.empty() : OptionalInt.of(Integer.parseInt(value));
    }
    private static OptionalDouble optionalDouble(EditText field) {
        String value = field.getText().toString().trim();
        return value.isEmpty() ? OptionalDouble.empty() : OptionalDouble.of(Double.parseDouble(value));
    }
    private void settingsPage() {
        title(s(R.string.settings_title));
        LinearLayout profile = card(s(R.string.profile));
        OptionalInt bodyHeight = session.bodyHeightCm(); OptionalDouble weight = session.weightKg();
        EditText h = field(profile, s(R.string.body_height), bodyHeight.isPresent() ? "" + bodyHeight.getAsInt() : "", R.id.profile_height, false);
        EditText w = field(profile, s(R.string.weight), weight.isPresent() ? "" + weight.getAsDouble() : "", R.id.profile_weight, true);
        EditText threshold = field(profile, s(R.string.threshold), "" + session.standingThresholdMm() / 10.0, R.id.profile_threshold, true);
        Switch units = new Switch(this); units.setId(R.id.units); units.setText(s(R.string.use_inches)); units.setChecked(session.inches()); units.setPadding(0, dp(12), 0, dp(12)); profile.addView(units);
        button(profile, s(R.string.save_profile), R.id.save_profile, () -> {
            session.setProfile(optionalInt(h), optionalDouble(w), (int) Math.round(Double.parseDouble(threshold.getText().toString()) * 10), units.isChecked());
            Toast.makeText(this, s(R.string.profile_saved), Toast.LENGTH_SHORT).show();
        });
        LinearLayout appearance = card(s(R.string.appearance));
        String language = UiPreferences.language(this);
        int selected = java.util.Arrays.asList(UiPreferences.LANGUAGES).indexOf(language);
        button(appearance, s(R.string.language) + ": " + UiPreferences.LANGUAGE_NAMES[selected], R.id.language, () ->
                new AlertDialog.Builder(this).setTitle(s(R.string.language)).setSingleChoiceItems(UiPreferences.LANGUAGE_NAMES, selected, (dialog, which) -> {
                    UiPreferences.language(this, UiPreferences.LANGUAGES[which]);
                    session.pause(); store.save(session); dialog.dismiss(); recreate();
                }).setNegativeButton(s(R.string.cancel), null).show());
        String[] themes = {"system", "light", "dark"};
        String[] themeLabels = {s(R.string.mode_system), s(R.string.mode_light), s(R.string.mode_dark)};
        int chosenTheme = java.util.Arrays.asList(themes).indexOf(UiPreferences.theme(this));
        button(appearance, s(R.string.dark_mode) + ": " + themeLabels[chosenTheme], R.id.dark_mode, () ->
                new AlertDialog.Builder(this).setTitle(s(R.string.dark_mode)).setSingleChoiceItems(themeLabels, chosenTheme, (dialog, which) -> {
                    UiPreferences.theme(this, themes[which]); session.pause(); store.save(session); dialog.dismiss(); recreate();
                }).setNegativeButton(s(R.string.cancel), null).show());
        LinearLayout about = card(s(R.string.help));
        button(about, s(R.string.guide), 0, () -> new AlertDialog.Builder(this).setTitle(s(R.string.guide)).setMessage(s(R.string.guide_body)).setPositiveButton(s(R.string.okay), null).show());
        button(about, s(R.string.maintenance), 0, () -> new AlertDialog.Builder(this).setTitle(s(R.string.hardware_pending)).setMessage(s(R.string.maintenance_body)).setPositiveButton(s(R.string.okay), null).show());
        button(about, s(R.string.clear_stats), 0, () -> new AlertDialog.Builder(this).setTitle(s(R.string.clear_confirm)).setMessage(s(R.string.clear_note)).setNegativeButton(s(R.string.cancel), null).setPositiveButton(s(R.string.clear), (d, which) -> { session.resetStatistics(); store.save(session); }).show());
        button(about, s(R.string.about), 0, () -> new AlertDialog.Builder(this).setTitle("Desk Auto 0.1.0").setMessage(s(R.string.about_body)).setPositiveButton(s(R.string.okay), null).show());
        note(s(R.string.privacy_note));
    }
    private void devicesPage() {
        title(s(R.string.devices_title)); note(s(R.string.devices_note));
        button(content, s(R.string.scan), R.id.scan, () -> {
            if (inspector.permitted()) inspector.scan(); else requestPermissions(BleInspector.permissions(), 11);
        });
        deviceList = card(s(R.string.ble_results)); refreshDevices();
        button(content, s(R.string.copy_report), 0, () -> { getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("BLE GATT", inspector.report())); Toast.makeText(this, s(R.string.copied), Toast.LENGTH_SHORT).show(); });
    }
    private void refreshDevices() {
        if (deviceList == null || inspector == null) return;
        deviceList.removeAllViews(); TextView report = text(inspector.report(), 13, MUTED); report.setTextIsSelectable(true); deviceList.addView(report);
        for (BleInspector.Device device : inspector.devices()) button(deviceList, device.name() + "\n" + device.address() + "   " + device.rssi() + " dBm", 0, () -> inspector.inspect(device.address()));
    }
    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == 11 && inspector.permitted()) inspector.scan();
        else if (requestCode == 11) Toast.makeText(this, s(R.string.permission_ble_denied), Toast.LENGTH_LONG).show();
        if (requestCode == 12 && (results.length == 0 || results[0] != PackageManager.PERMISSION_GRANTED)) Toast.makeText(this, s(R.string.permission_notifications_denied), Toast.LENGTH_LONG).show();
    }
    private void refresh() {
        DeskPort.State state = session.state();
        if (height != null) height.setText(state.connected() ? session.height(state.heightMm()) : "— " + (session.inches() ? "in" : "cm"));
        if (status != null) status.setText(!state.connected() ? s(R.string.not_connected) : !state.fault().isEmpty() ? UiText.message(this, state.fault()) : state.locked() ? s(R.string.locked) : state.moving() ? s(R.string.moving) : s(R.string.connected_stopped));
        if (connect != null) connect.setText(state.connected() ? s(R.string.disconnect) : s(R.string.connect));
        if (lock != null) lock.setText(state.locked() ? s(R.string.unlock) : s(R.string.lock));
        if (drawing != null) drawing.invalidate();
        if (timerStatus != null) {
            long seconds = (session.reminderRemainingMs(System.currentTimeMillis()) + 999) / 1000;
            timerStatus.setText(session.reminderDue() ? s(R.string.timer_due) : session.reminderAtMs() == 0 ? s(R.string.timer_idle) : s(R.string.timer_remaining, seconds / 60, seconds % 60));
        }
        if (historySummary != null) {
            long now = System.currentTimeMillis(), ms = session.history().total(period, now), today = session.history().total(ActivityHistory.Period.DAY, now);
            long kcal = session.history().estimatedCalories(period, now, session.weightKg().orElse(0));
            OptionalInt percent = session.goalPercent(now);
            String goal = percent.isPresent()
                    ? s(R.string.goal_summary, session.dailyGoalMinutes(), percent.getAsInt(), Math.max(0, session.dailyGoalMinutes() * 60_000.0 - today) / 60000)
                    : s(R.string.goal_unset);
            historySummary.setText(s(R.string.history_summary, ms / 60000.0, kcal, StandingCalories.drumsticks(kcal)) + "\n\n" + goal);
        }
    }
    private final class DeskDrawing extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        DeskDrawing() { super(MainActivity.this); setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO); }
        @Override protected void onDraw(Canvas canvas) {
            float cx = getWidth() / 2f, floor = getHeight() - dp(12), top = floor - dp(50 + (session.state().heightMm() - 630) / 13f);
            paint.setColor(LINE); canvas.drawRoundRect(cx - dp(120), floor, cx + dp(120), floor + dp(3), dp(2), dp(2), paint);
            paint.setColor(BLUE); canvas.drawRoundRect(cx - dp(105), top, cx + dp(105), top + dp(9), dp(4), dp(4), paint);
            paint.setColor(LEG);
            for (int side = -1; side <= 1; side += 2) {
                float x = cx + side * dp(75); canvas.drawRect(x - dp(4), top + dp(9), x + dp(4), floor, paint);
                canvas.drawRoundRect(x - dp(24), floor - dp(5), x + dp(24), floor, dp(2), dp(2), paint);
            }
        }
    }
}

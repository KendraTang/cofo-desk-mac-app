package dev.cofodesk.auto;

import android.Manifest;
import android.content.pm.PackageManager;
import android.os.Build;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import dev.cofodesk.auto.core.DeskSession;

/** Daily goal, sit/stand reminders with shortcuts, and the one-off countdown. */
final class ReminderPage implements Page {
    private final Views ui;
    private final DeskSession session;
    private final TextView timerStatus;

    ReminderPage(Views ui, DeskSession session) {
        this.ui = ui;
        this.session = session;
        ui.title(ui.string(R.string.reminder_title));
        LinearLayout goals = ui.card(ui.string(R.string.goals));
        EditText goal = ui.field(goals, ui.string(R.string.goal_label), "" + session.dailyGoalMinutes(), R.id.goal, false);
        shortcuts(goals, goal, new int[]{40, 60, 120, 180, 240}, new int[]{R.id.goal_40, R.id.goal_60, R.id.goal_120, R.id.goal_180, R.id.goal_240});
        EditText sit = ui.field(goals, ui.string(R.string.sit_label), "" + session.sittingReminderMinutes(), R.id.sit_minutes, false);
        shortcuts(goals, sit, new int[]{40, 60, 120}, new int[]{R.id.sit_40, R.id.sit_60, R.id.sit_120});
        EditText stand = ui.field(goals, ui.string(R.string.stand_label), "" + session.standingReminderMinutes(), R.id.stand_minutes, false);
        shortcuts(goals, stand, new int[]{40, 60, 120}, new int[]{R.id.stand_40, R.id.stand_60, R.id.stand_120});
        ui.button(goals, ui.string(R.string.save_goals), R.id.save_goals, () -> {
            session.configureGoals(minutes(goal), minutes(sit), minutes(stand));
            ui.toast(ui.string(R.string.goals_saved), Toast.LENGTH_SHORT);
        });
        ui.note(ui.string(R.string.posture_note));

        LinearLayout timer = ui.card(ui.string(R.string.countdown));
        EditText countdown = ui.field(timer, ui.string(R.string.minutes_label), "40", R.id.timer_minutes, false);
        timerStatus = ui.text("", 17, ui.colors.accent());
        timerStatus.setId(R.id.timer_status);
        timer.addView(timerStatus);
        ui.button(timer, ui.string(R.string.start_timer), R.id.start_timer, () -> {
            session.startReminder(minutes(countdown), System.currentTimeMillis());
            ReminderReceiver.schedule(ui.activity, session.reminderAtMs());
            if (Build.VERSION.SDK_INT >= 33 && ui.activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                ui.activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, MainActivity.REQUEST_NOTIFICATIONS);
        });
        ui.button(timer, ui.string(R.string.cancel_timer), R.id.cancel_timer, () -> {
            session.cancelReminder();
            ReminderReceiver.cancel(ui.activity);
        });
        ui.note(ui.string(R.string.countdown_note));
    }
    private static int minutes(EditText field) { return Integer.parseInt(field.getText().toString()); }
    /** Shortcuts only fill the field; the user still saves explicitly. */
    private void shortcuts(LinearLayout parent, EditText target, int[] minutes, int[] ids) {
        LinearLayout row = new LinearLayout(ui.activity);
        parent.addView(row);
        for (int i = 0; i < minutes.length; i++) {
            int value = minutes[i];
            ui.rowButton(row, value % 60 == 0 ? value / 60 + "h" : value + "m", ids[i], () -> target.setText(String.valueOf(value)));
        }
    }
    @Override public void refresh() {
        long seconds = (session.reminderRemainingMs(System.currentTimeMillis()) + 999) / 1000;
        timerStatus.setText(session.reminderDue() ? ui.string(R.string.timer_due)
                : session.reminderAtMs() == 0 ? ui.string(R.string.timer_idle)
                : ui.string(R.string.timer_remaining, seconds / 60, seconds % 60));
    }
}

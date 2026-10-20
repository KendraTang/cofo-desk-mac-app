package dev.cofodesk.auto;

import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import dev.cofodesk.auto.core.ActivityHistory;
import dev.cofodesk.auto.core.DeskSession;
import dev.cofodesk.auto.core.StandingCalories;
import java.time.LocalDate;
import java.util.OptionalInt;
import java.util.function.Consumer;

/** Standing time, calories and goal progress for the selected period, plus the last seven days. */
final class HistoryPage implements Page {
    private static final int[] PERIOD_LABELS = {R.string.period_day, R.string.period_week, R.string.period_month, R.string.period_year};
    private final Views ui;
    private final DeskSession session;
    private final ActivityHistory.Period period;
    private final TextView summary;

    HistoryPage(Views ui, DeskSession session, ActivityHistory.Period period, Consumer<ActivityHistory.Period> select) {
        this.ui = ui;
        this.session = session;
        this.period = period;
        Palette colors = ui.colors;
        ui.title(ui.string(R.string.history_title));
        ui.note(ui.string(R.string.history_note));
        LinearLayout filters = ui.card(ui.string(R.string.history));
        LinearLayout row = new LinearLayout(ui.activity);
        filters.addView(row);
        for (ActivityHistory.Period option : ActivityHistory.Period.values()) {
            Button button = ui.rowButton(row, ui.string(PERIOD_LABELS[option.ordinal()]), 0, () -> select.accept(option));
            button.setTextSize(13);
            button.setTextColor(option == period ? colors.accent() : colors.muted());
        }
        summary = ui.text("", 19, colors.ink());
        summary.setId(R.id.history_summary);
        filters.addView(summary);
        LinearLayout bars = ui.card(ui.string(R.string.recent_days));
        LocalDate today = session.history().date(System.currentTimeMillis());
        int goal = session.dailyGoalMinutes();
        for (int i = 6; i >= 0; i--) {
            LocalDate date = today.minusDays(i);
            long minutes = session.history().day(date) / 60_000;
            bars.addView(ui.text(ui.string(R.string.daily_minutes, date.toString(), minutes), 13, colors.muted()));
            if (goal == 0) continue;
            ProgressBar progress = new ProgressBar(ui.activity, null, android.R.attr.progressBarStyleHorizontal);
            progress.setMax(goal);
            progress.setProgress((int) Math.min(minutes, goal));
            bars.addView(progress);
        }
        ui.note(ui.string(R.string.calorie_note));
    }
    @Override public void refresh() {
        long now = System.currentTimeMillis();
        long standing = session.history().total(period, now);
        long today = session.history().total(ActivityHistory.Period.DAY, now);
        long kcal = session.history().estimatedCalories(period, now, session.weightKg().orElse(0));
        OptionalInt percent = session.goalPercent(now);
        String goal = percent.isPresent()
                ? ui.string(R.string.goal_summary, session.dailyGoalMinutes(), percent.getAsInt(),
                        Math.max(0, session.dailyGoalMinutes() * 60_000.0 - today) / 60_000)
                : ui.string(R.string.goal_unset);
        summary.setText(ui.string(R.string.history_summary, standing / 60_000.0, kcal, StandingCalories.drumsticks(kcal)) + "\n\n" + goal);
    }
}

package dev.cofodesk.auto;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.text.InputType;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import java.util.function.Consumer;

/** View factory shared by the pages. Buttons run their action through the Activity's validated path. */
final class Views {
    final Activity activity;
    final Palette colors;
    private final Consumer<Runnable> perform;
    /** Scrollable container of the page being built. */
    LinearLayout content;

    Views(Activity activity, Palette colors, Consumer<Runnable> perform) {
        this.activity = activity;
        this.colors = colors;
        this.perform = perform;
    }
    void perform(Runnable action) { perform.accept(action); }
    String string(int resource, Object... values) { return activity.getString(resource, values); }
    void toast(String message, int length) { Toast.makeText(activity, message, length).show(); }
    int dp(float value) { return (int) (activity.getResources().getDisplayMetrics().density * value + .5f); }

    TextView text(String value, float size, int color) {
        TextView view = new TextView(activity);
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        view.setPadding(0, dp(5), 0, dp(5));
        return view;
    }
    LinearLayout column() {
        LinearLayout view = new LinearLayout(activity);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }
    GradientDrawable background(int color, int radius) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(color);
        shape.setCornerRadius(dp(radius));
        return shape;
    }
    Button button(LinearLayout parent, String title, int id, Runnable action) {
        Button view = new Button(activity);
        view.setText(title);
        view.setTextColor(colors.accent());
        styleButton(view);
        if (id != 0) view.setId(id);
        view.setOnClickListener(clicked -> perform(action));
        parent.addView(view);
        return view;
    }
    void styleButton(Button button) {
        button.setAllCaps(false);
        button.setMinHeight(dp(48));
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(0x33246BDF), background(colors.button(), 10), null));
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.setMargins(0, dp(4), 0, dp(4));
        button.setLayoutParams(params);
        button.setElevation(0);
    }
    void note(String value) { content.addView(text(value, 13, colors.muted())); }
    void title(String value) { content.addView(text(value, 25, colors.ink())); }
    LinearLayout card(String heading) {
        LinearLayout card = column();
        card.setPadding(dp(18), dp(12), dp(18), dp(14));
        card.setBackground(background(colors.surface(), 18));
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.setMargins(0, dp(12), 0, 0);
        content.addView(card, params);
        if (!heading.isEmpty()) card.addView(text(heading, 17, colors.ink()));
        return card;
    }
    EditText field(LinearLayout parent, String label, String value, int id, boolean decimal) {
        parent.addView(text(label, 13, colors.muted()));
        EditText edit = new EditText(activity);
        edit.setId(id);
        edit.setText(value);
        edit.setTextSize(17);
        edit.setSingleLine();
        edit.setInputType(InputType.TYPE_CLASS_NUMBER | (decimal ? InputType.TYPE_NUMBER_FLAG_DECIMAL : 0));
        parent.addView(edit);
        return edit;
    }
    /** A row of compact buttons; each takes an equal share of the width. */
    Button rowButton(LinearLayout row, String label, int id, Runnable onClick) {
        Button button = new Button(activity);
        if (id != 0) button.setId(id);
        button.setText(label);
        button.setTextSize(12);
        button.setPadding(0, 0, 0, 0);
        styleButton(button);
        button.setOnClickListener(clicked -> onClick.run());
        row.addView(button, new LinearLayout.LayoutParams(0, dp(48), 1));
        return button;
    }
}

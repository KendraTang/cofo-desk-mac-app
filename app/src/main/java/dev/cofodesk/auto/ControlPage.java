package dev.cofodesk.auto;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import dev.cofodesk.auto.core.DeskPort;
import dev.cofodesk.auto.core.DeskSession;
import dev.cofodesk.auto.core.SimulatedDesk;
import java.util.Locale;

/** Height, hold-to-move buttons, presets and simulator tools. */
final class ControlPage implements Page {
    private static final int[] PRESET_IDS = {R.id.preset1, R.id.preset2, R.id.preset3};
    private final Views ui;
    private final DeskSession session;
    private final TextView height, status;
    private final Button connect, lock;
    private final DeskDrawing drawing;

    ControlPage(Views ui, DeskSession session, SimulatedDesk simulator, Runnable openDevices) {
        this.ui = ui;
        this.session = session;
        Palette colors = ui.colors;
        ui.title(ui.string(R.string.control_title));
        ui.note(ui.string(R.string.simulator_note));
        LinearLayout panel = ui.card("");
        status = ui.text("", 14, colors.muted());
        status.setId(R.id.status);
        status.setGravity(Gravity.CENTER);
        panel.addView(status);
        height = ui.text("", 52, colors.accent());
        height.setId(R.id.height);
        height.setGravity(Gravity.CENTER);
        panel.addView(height);
        drawing = new DeskDrawing();
        panel.addView(drawing, new LinearLayout.LayoutParams(-1, ui.dp(130)));
        connect = ui.button(panel, "", R.id.connect, () -> {
            if (session.state().connected()) session.disconnect(); else session.connect();
        });
        LinearLayout move = new LinearLayout(ui.activity);
        panel.addView(move);
        jogButton(move, ui.string(R.string.up), R.id.up, true);
        jogButton(move, ui.string(R.string.down), R.id.down, false);
        Button stop = ui.button(panel, ui.string(R.string.stop), R.id.stop, session::stop);
        stop.setTextColor(Color.rgb(177, 55, 55));

        LinearLayout memories = ui.card(ui.string(R.string.presets));
        ui.note(ui.string(R.string.preset_hint));
        for (int i = 0; i < PRESET_IDS.length; i++) {
            final int slot = i;
            Button preset = ui.button(memories, presetLabel(slot), PRESET_IDS[i], () -> session.recall(slot));
            preset.setOnLongClickListener(view -> {
                ui.perform(() -> {
                    session.savePreset(slot);
                    preset.setText(presetLabel(slot));
                    ui.toast(ui.string(R.string.preset_saved), Toast.LENGTH_SHORT);
                });
                return true;
            });
        }
        LinearLayout safety = ui.card(ui.string(R.string.simulator_tools));
        lock = ui.button(safety, "", R.id.lock, () -> session.lock(!session.state().locked()));
        ui.button(safety, ui.string(R.string.collision), R.id.collision, simulator::collide);
        ui.button(safety, ui.string(R.string.recover), R.id.recover, simulator::clearFault);
        ui.button(ui.content, ui.string(R.string.devices), R.id.devices, openDevices);
    }
    private String presetLabel(int slot) {
        return String.format(Locale.US, "M%d    %s", slot + 1, session.height(session.preset(slot)));
    }
    private void jogButton(LinearLayout parent, String label, int id, boolean up) {
        Button button = new JogButton(up);
        button.setText(label);
        button.setTextSize(14);
        button.setTextColor(ui.colors.accent());
        button.setId(id);
        ui.styleButton(button);
        parent.addView(button, new LinearLayout.LayoutParams(0, ui.dp(56), 1));
    }
    @Override public void refresh() {
        DeskPort.State state = session.state();
        height.setText(state.connected() ? session.height(state.heightMm()) : "— " + (session.inches() ? "in" : "cm"));
        status.setText(!state.connected() ? ui.string(R.string.not_connected)
                : state.fault().present() ? UiText.fault(ui.activity, state.fault())
                : state.locked() ? ui.string(R.string.locked)
                : state.moving() ? ui.string(R.string.moving)
                : ui.string(R.string.connected_stopped));
        connect.setText(ui.string(state.connected() ? R.string.disconnect : R.string.connect));
        lock.setText(ui.string(state.locked() ? R.string.unlock : R.string.lock));
        drawing.invalidate();
    }

    /** Moves while held; release or cancel stops. An accessibility click moves one small step. */
    private final class JogButton extends Button {
        private final boolean up;
        private boolean touchClick;
        JogButton(boolean up) {
            super(ui.activity);
            this.up = up;
            setClickable(true);
        }
        @Override public boolean onTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN -> {
                    ui.perform(() -> session.jog(up));
                    setPressed(true);
                }
                case MotionEvent.ACTION_UP -> {
                    session.stop();
                    setPressed(false);
                    touchClick = true;
                    performClick();
                    touchClick = false;
                    refresh();
                }
                case MotionEvent.ACTION_CANCEL -> {
                    session.stop();
                    setPressed(false);
                    refresh();
                }
                default -> { }
            }
            return true;
        }
        @Override public boolean performClick() {
            super.performClick();
            if (!touchClick) ui.perform(() -> session.nudge(up));
            return true;
        }
    }

    private final class DeskDrawing extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        DeskDrawing() {
            super(ui.activity);
            setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        }
        @Override protected void onDraw(Canvas canvas) {
            float cx = getWidth() / 2f, floor = getHeight() - ui.dp(12);
            float top = floor - ui.dp(50 + (session.state().heightMm() - DeskSession.SETTING_RANGE.minMm()) / 13f);
            paint.setColor(ui.colors.line());
            canvas.drawRoundRect(cx - ui.dp(120), floor, cx + ui.dp(120), floor + ui.dp(3), ui.dp(2), ui.dp(2), paint);
            paint.setColor(ui.colors.accent());
            canvas.drawRoundRect(cx - ui.dp(105), top, cx + ui.dp(105), top + ui.dp(9), ui.dp(4), ui.dp(4), paint);
            paint.setColor(ui.colors.leg());
            for (int side = -1; side <= 1; side += 2) {
                float x = cx + side * ui.dp(75);
                canvas.drawRect(x - ui.dp(4), top + ui.dp(9), x + ui.dp(4), floor, paint);
                canvas.drawRoundRect(x - ui.dp(24), floor - ui.dp(5), x + ui.dp(24), floor, ui.dp(2), ui.dp(2), paint);
            }
        }
    }
}

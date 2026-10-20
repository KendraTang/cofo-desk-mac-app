package dev.cofodesk.auto;

import android.app.AlertDialog;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.Toast;
import dev.cofodesk.auto.core.DeskSession;
import java.util.OptionalDouble;
import java.util.OptionalInt;
import java.util.function.Consumer;

/** Profile, units, language, theme and help. */
final class SettingsPage implements Page {
    private static final int[] THEME_LABELS = {R.string.mode_system, R.string.mode_light, R.string.mode_dark};

    /**
     * @param restyle applies a language or theme change, then stops the motor, saves and recreates the Activity
     * @param save persists the session after clearing statistics
     */
    SettingsPage(Views ui, DeskSession session, Consumer<Runnable> restyle, Runnable save) {
        ui.title(ui.string(R.string.settings_title));
        LinearLayout profile = ui.card(ui.string(R.string.profile));
        OptionalInt savedHeight = session.bodyHeightCm();
        OptionalDouble savedWeight = session.weightKg();
        EditText bodyHeight = ui.field(profile, ui.string(R.string.body_height), savedHeight.isPresent() ? "" + savedHeight.getAsInt() : "", R.id.profile_height, false);
        EditText weight = ui.field(profile, ui.string(R.string.weight), savedWeight.isPresent() ? "" + savedWeight.getAsDouble() : "", R.id.profile_weight, true);
        EditText threshold = ui.field(profile, ui.string(R.string.threshold), "" + session.standingThresholdMm() / 10.0, R.id.profile_threshold, true);
        Switch units = new Switch(ui.activity);
        units.setId(R.id.units);
        units.setText(ui.string(R.string.use_inches));
        units.setChecked(session.inches());
        units.setPadding(0, ui.dp(12), 0, ui.dp(12));
        profile.addView(units);
        ui.button(profile, ui.string(R.string.save_profile), R.id.save_profile, () -> {
            int thresholdMm = (int) Math.round(Double.parseDouble(threshold.getText().toString()) * 10);
            session.setProfile(optionalInt(bodyHeight), optionalDouble(weight), thresholdMm, units.isChecked());
            ui.toast(ui.string(R.string.profile_saved), Toast.LENGTH_SHORT);
        });

        LinearLayout appearance = ui.card(ui.string(R.string.appearance));
        UiPreferences.Language[] languages = UiPreferences.Language.values();
        String[] languageNames = new String[languages.length];
        for (int i = 0; i < languages.length; i++) languageNames[i] = languages[i].displayName;
        UiPreferences.Language language = UiPreferences.language(ui.activity);
        ui.button(appearance, ui.string(R.string.language) + ": " + language.displayName, R.id.language, () ->
                new AlertDialog.Builder(ui.activity).setTitle(ui.string(R.string.language))
                        .setSingleChoiceItems(languageNames, language.ordinal(), (dialog, which) -> {
                            dialog.dismiss();
                            restyle.accept(() -> UiPreferences.language(ui.activity, languages[which]));
                        }).setNegativeButton(ui.string(R.string.cancel), null).show());
        UiPreferences.Theme[] themes = UiPreferences.Theme.values();
        String[] themeNames = new String[themes.length];
        for (int i = 0; i < themes.length; i++) themeNames[i] = ui.string(THEME_LABELS[i]);
        UiPreferences.Theme theme = UiPreferences.theme(ui.activity);
        ui.button(appearance, ui.string(R.string.dark_mode) + ": " + themeNames[theme.ordinal()], R.id.dark_mode, () ->
                new AlertDialog.Builder(ui.activity).setTitle(ui.string(R.string.dark_mode))
                        .setSingleChoiceItems(themeNames, theme.ordinal(), (dialog, which) -> {
                            dialog.dismiss();
                            restyle.accept(() -> UiPreferences.theme(ui.activity, themes[which]));
                        }).setNegativeButton(ui.string(R.string.cancel), null).show());

        LinearLayout about = ui.card(ui.string(R.string.help));
        ui.button(about, ui.string(R.string.guide), 0, () -> message(ui, ui.string(R.string.guide), ui.string(R.string.guide_body)));
        ui.button(about, ui.string(R.string.maintenance), 0, () -> message(ui, ui.string(R.string.hardware_pending), ui.string(R.string.maintenance_body)));
        ui.button(about, ui.string(R.string.clear_stats), 0, () ->
                new AlertDialog.Builder(ui.activity).setTitle(ui.string(R.string.clear_confirm)).setMessage(ui.string(R.string.clear_note))
                        .setNegativeButton(ui.string(R.string.cancel), null)
                        .setPositiveButton(ui.string(R.string.clear), (dialog, which) -> {
                            session.resetStatistics();
                            save.run();
                        }).show());
        ui.button(about, ui.string(R.string.about), 0, () -> message(ui, "Desk Auto 0.1.0", ui.string(R.string.about_body)));
        ui.note(ui.string(R.string.privacy_note));
    }
    private static void message(Views ui, String title, String body) {
        new AlertDialog.Builder(ui.activity).setTitle(title).setMessage(body).setPositiveButton(ui.string(R.string.okay), null).show();
    }
    private static OptionalInt optionalInt(EditText field) {
        String value = field.getText().toString().trim();
        return value.isEmpty() ? OptionalInt.empty() : OptionalInt.of(Integer.parseInt(value));
    }
    private static OptionalDouble optionalDouble(EditText field) {
        String value = field.getText().toString().trim();
        return value.isEmpty() ? OptionalDouble.empty() : OptionalDouble.of(Double.parseDouble(value));
    }
    @Override public void refresh() { }
}

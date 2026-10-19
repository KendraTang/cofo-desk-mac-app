package dev.cofodesk.auto;

import android.content.Context;
import android.content.res.Configuration;
import android.os.LocaleList;
import java.util.Locale;

/** App-only preferences; never changes the emulator/device language or theme. */
final class UiPreferences {
    static final String[] LANGUAGES = {"zh-TW", "en", "ja", "zh-CN", "ko"};
    static final String[] LANGUAGE_NAMES = {"繁體中文", "English", "日本語", "简体中文", "한국어"};
    static String language(Context context) {
        String selected = context.getSharedPreferences("appearance", 0).getString("language", "zh-TW");
        for (String language : LANGUAGES) if (language.equals(selected)) return selected;
        return "zh-TW";
    }
    static void language(Context context, String language) {
        for (String supported : LANGUAGES) if (supported.equals(language)) {
            context.getSharedPreferences("appearance", 0).edit().putString("language", language).apply();
            return;
        }
        throw new IllegalArgumentException("Unsupported language");
    }
    static String theme(Context context) {
        android.content.SharedPreferences p = context.getSharedPreferences("appearance", 0);
        String mode = p.getString("theme", p.contains("dark") ? (p.getBoolean("dark", false) ? "dark" : "light") : "system");
        return mode.equals("light") || mode.equals("dark") ? mode : "system";
    }
    static void theme(Context context, String mode) {
        if (!mode.equals("system") && !mode.equals("light") && !mode.equals("dark")) throw new IllegalArgumentException("Unsupported theme");
        context.getSharedPreferences("appearance", 0).edit().putString("theme", mode).remove("dark").apply();
    }
    static boolean dark(Context context) {
        return theme(context).equals("dark") || (theme(context).equals("system") &&
                (context.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES);
    }
    static Context localized(Context context) {
        Configuration config = new Configuration(context.getResources().getConfiguration());
        config.setLocales(new LocaleList(Locale.forLanguageTag(language(context))));
        return context.createConfigurationContext(config);
    }
}

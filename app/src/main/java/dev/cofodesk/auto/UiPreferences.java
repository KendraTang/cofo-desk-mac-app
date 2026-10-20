package dev.cofodesk.auto;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.os.LocaleList;
import java.util.Locale;

/** App-only preferences; never changes the emulator/device language or theme. */
final class UiPreferences {
    enum Language {
        ZH_TW("zh-TW", "繁體中文"), EN("en", "English"), JA("ja", "日本語"), ZH_CN("zh-CN", "简体中文"), KO("ko", "한국어");
        final String tag, displayName;
        Language(String tag, String displayName) { this.tag = tag; this.displayName = displayName; }
        static final Language DEFAULT = ZH_TW;
    }
    enum Theme {
        SYSTEM("system"), LIGHT("light"), DARK("dark");
        final String stored;
        Theme(String stored) { this.stored = stored; }
    }
    private static SharedPreferences prefs(Context context) { return context.getSharedPreferences("appearance", 0); }

    static Language language(Context context) {
        String selected = prefs(context).getString("language", Language.DEFAULT.tag);
        for (Language language : Language.values()) if (language.tag.equals(selected)) return language;
        return Language.DEFAULT;
    }
    static void language(Context context, Language language) { prefs(context).edit().putString("language", language.tag).apply(); }
    static Theme theme(Context context) {
        SharedPreferences p = prefs(context);
        // Versions before the three-way setting stored a "dark" boolean.
        String stored = p.getString("theme", p.contains("dark") ? (p.getBoolean("dark", false) ? "dark" : "light") : "system");
        for (Theme theme : Theme.values()) if (theme.stored.equals(stored)) return theme;
        return Theme.SYSTEM;
    }
    static void theme(Context context, Theme theme) { prefs(context).edit().putString("theme", theme.stored).remove("dark").apply(); }
    static boolean dark(Context context) {
        Theme theme = theme(context);
        return theme == Theme.DARK || (theme == Theme.SYSTEM &&
                (context.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES);
    }
    static Context localized(Context context) {
        Configuration config = new Configuration(context.getResources().getConfiguration());
        config.setLocales(new LocaleList(Locale.forLanguageTag(language(context).tag)));
        return context.createConfigurationContext(config);
    }
}

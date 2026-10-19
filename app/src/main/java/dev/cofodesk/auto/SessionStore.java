package dev.cofodesk.auto;

import android.content.Context;
import android.content.SharedPreferences;
import dev.cofodesk.auto.core.DeskSession;
import java.util.Properties;

final class SessionStore {
    private final SharedPreferences prefs;
    SessionStore(Context context) { prefs = context.getSharedPreferences("desk", Context.MODE_PRIVATE); }
    void load(DeskSession session) {
        Properties p = new Properties();
        prefs.getAll().forEach((key, value) -> p.setProperty(key, String.valueOf(value)));
        session.restore(p);
    }
    void save(DeskSession session) {
        SharedPreferences.Editor editor = prefs.edit().clear();
        session.save().forEach((key, value) -> editor.putString(key.toString(), value.toString()));
        editor.apply();
    }
}

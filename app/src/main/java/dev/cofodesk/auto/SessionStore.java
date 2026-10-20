package dev.cofodesk.auto;

import android.content.Context;
import android.content.SharedPreferences;
import dev.cofodesk.auto.core.DeskSession;
import dev.cofodesk.auto.core.SimulatedDesk;
import java.util.Properties;

final class SessionStore {
    private final SharedPreferences prefs, simulator;
    SessionStore(Context context) {
        prefs = context.getSharedPreferences("desk", Context.MODE_PRIVATE);
        simulator = context.getSharedPreferences("simulator", Context.MODE_PRIVATE);
    }
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
    /** Simulated device position only, like the CLI simulator; a real desk reports its own height. */
    void loadSimulator(SimulatedDesk desk) {
        try { desk.restore(simulator.getInt("heightMm", 720)); }
        catch (ClassCastException e) { desk.restore(720); }
    }
    void saveSimulator(SimulatedDesk desk) { simulator.edit().putInt("heightMm", desk.state().heightMm()).apply(); }
}

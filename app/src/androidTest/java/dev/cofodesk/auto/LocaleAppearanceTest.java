package dev.cofodesk.auto;

import android.app.Notification;
import android.app.NotificationManager;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Build;
import android.widget.EditText;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.*;
import org.junit.runner.RunWith;
import static androidx.test.espresso.Espresso.onView;
import static androidx.test.espresso.action.ViewActions.*;
import static androidx.test.espresso.assertion.ViewAssertions.matches;
import static androidx.test.espresso.matcher.ViewMatchers.*;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class LocaleAppearanceTest {
    private Context context;
    private ActivityScenario<MainActivity> scenario;
    @Before public void launch() {
        context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        context.getSharedPreferences("appearance", 0).edit().clear().commit();
        context.getSharedPreferences("simulator", 0).edit().clear().commit();
        context.getSharedPreferences("desk", 0).edit().clear().putString("weightKg", "75.5").putString("goal", "120").putString("preset0", "900").commit();
        if (Build.VERSION.SDK_INT >= 33) InstrumentationRegistry.getInstrumentation().getUiAutomation().grantRuntimePermission(context.getPackageName(), android.Manifest.permission.POST_NOTIFICATIONS);
        scenario = ActivityScenario.launch(MainActivity.class);
    }
    @After public void close() {
        if (scenario != null) scenario.close();
        ReminderReceiver.cancel(context);
        context.getSharedPreferences("appearance", 0).edit().clear().commit();
    }
    @Test public void allFiveLanguagesChangeVisibleUiAndPreserveData() {
        String[] names = {"English", "日本語", "简体中文", "한국어", "繁體中文"};
        String[] control = {"Control", "操作", "控制", "조작", "控制"};
        for (int i = 0; i < names.length; i++) {
            onView(withId(R.id.tab_settings)).perform(click());
            onView(withId(R.id.language)).perform(scrollTo(), click());
            onView(withText(names[i])).perform(click());
            onView(withId(R.id.tab_control)).check(matches(withText(control[i])));
            onView(withId(R.id.profile_weight)).check(matches(withText("75.5")));
            scenario.recreate();
            onView(withId(R.id.tab_control)).check(matches(withText(control[i])));
            onView(withId(R.id.tab_reminders)).perform(click());
            onView(withId(R.id.goal)).check(matches(withText("120")));
            onView(withId(R.id.tab_control)).perform(click());
            onView(withId(R.id.preset1)).check(matches(withText("M1    90.0 cm")));
            capture(new String[]{"english", "japanese", "simplified-chinese", "korean", "traditional-chinese"}[i]);
        }
    }
    @Test public void darkThemePersistsAndKeepsInputsReadable() {
        onView(withId(R.id.tab_settings)).perform(click());
        onView(withId(R.id.dark_mode)).perform(scrollTo(), click());
        onView(withText("深色")).perform(click());
        scenario.recreate();
        scenario.onActivity(activity -> {
            assertEquals("dark", UiPreferences.theme(activity));
            assertEquals(0xff101827, ((ColorDrawable) activity.findViewById(R.id.app_root).getBackground()).getColor());
            int text = ((EditText) activity.findViewById(R.id.profile_weight)).getCurrentTextColor();
            assertTrue(Color.red(text) > 150 && Color.green(text) > 150 && Color.blue(text) > 150);
        });
        onView(withId(R.id.profile_weight)).check(matches(withText("75.5")));
        onView(withId(R.id.tab_control)).perform(click());
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.height)).check(matches(withText("72.0 cm")));
        capture("dark-control");
        onView(withId(R.id.tab_settings)).perform(click());
        onView(withId(R.id.dark_mode)).perform(scrollTo(), click());
        onView(withText("淺色")).perform(click());
        scenario.onActivity(activity -> assertEquals(0xfff4f7fc, ((ColorDrawable) activity.findViewById(R.id.app_root).getBackground()).getColor()));
    }
    @Test public void followingSystemUsesNightConfigurationWithoutChangingExplicitModes() {
        android.content.res.Configuration night = new android.content.res.Configuration(context.getResources().getConfiguration());
        night.uiMode = (night.uiMode & ~android.content.res.Configuration.UI_MODE_NIGHT_MASK) | android.content.res.Configuration.UI_MODE_NIGHT_YES;
        Context dark = context.createConfigurationContext(night);
        android.content.res.Configuration day = new android.content.res.Configuration(night);
        day.uiMode = (day.uiMode & ~android.content.res.Configuration.UI_MODE_NIGHT_MASK) | android.content.res.Configuration.UI_MODE_NIGHT_NO;
        Context light = context.createConfigurationContext(day);
        UiPreferences.theme(context, "system"); assertTrue(UiPreferences.dark(dark)); assertFalse(UiPreferences.dark(light));
        UiPreferences.theme(context, "light"); assertFalse(UiPreferences.dark(dark));
        UiPreferences.theme(context, "dark"); assertTrue(UiPreferences.dark(light));
    }
    @Test public void receiverAndBleDiagnosticsUseSelectedLanguage() {
        UiPreferences.language(context, "en");
        new ReminderReceiver().onReceive(context, new android.content.Intent());
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        android.service.notification.StatusBarNotification posted = NotificationAssertions.awaitPosted(manager);
        assertEquals("Time for your sit–stand reminder", posted.getNotification().extras.getCharSequence(Notification.EXTRA_TEXT).toString());
        assertEquals("Sit–stand reminders", manager.getNotificationChannel(ReminderReceiver.CHANNEL).getName().toString());
        BleInspector inspector = new BleInspector(UiPreferences.localized(context), () -> {});
        assertTrue(inspector.report().startsWith("Scan nearby BLE devices"));
        assertEquals("Connect a desk first", UiText.refusal(UiPreferences.localized(context), dev.cofodesk.auto.core.Refused.Reason.NOT_CONNECTED));
        assertEquals("Daily standing goal reached", UiText.alert(UiPreferences.localized(context), dev.cofodesk.auto.core.Alert.GOAL));
        assertEquals("Desk reported error E01", UiText.fault(UiPreferences.localized(context), dev.cofodesk.auto.core.Fault.device("E01")));
        assertEquals("Desk reported an unknown error (0x11)", UiText.fault(UiPreferences.localized(context), dev.cofodesk.auto.core.Fault.unknown("0x11")));
    }
    @Test public void everyCoreCodeHasTextInEveryLanguage() {
        for (String language : UiPreferences.LANGUAGES) {
            UiPreferences.language(context, language);
            Context localized = UiPreferences.localized(context);
            java.util.Set<String> seen = new java.util.HashSet<>();
            for (dev.cofodesk.auto.core.Refused.Reason reason : dev.cofodesk.auto.core.Refused.Reason.values())
                assertTrue(language + " " + reason, seen.add(UiText.refusal(localized, reason)));
            for (dev.cofodesk.auto.core.Alert alert : dev.cofodesk.auto.core.Alert.values())
                assertTrue(language + " " + alert, seen.add(UiText.alert(localized, alert)));
            for (dev.cofodesk.auto.core.Fault fault : new dev.cofodesk.auto.core.Fault[]{dev.cofodesk.auto.core.Fault.NONE, dev.cofodesk.auto.core.Fault.COLLISION, dev.cofodesk.auto.core.Fault.device("E01"), dev.cofodesk.auto.core.Fault.unknown("0x11")})
                assertTrue(language + " " + fault, seen.add(UiText.fault(localized, fault)));
        }
    }
    @Test public void invalidStoredLanguageFallsBackAndParagraphsHaveLineBreaks() {
        context.getSharedPreferences("appearance", 0).edit().putString("language", "unsupported").commit();
        scenario.recreate();
        onView(withId(R.id.tab_control)).check(matches(withText("控制")));
        Context localized = UiPreferences.localized(context);
        assertTrue(localized.getString(R.string.guide_body).contains("\n"));
        assertFalse(localized.getString(R.string.guide_body).contains("\\n"));
    }
    private void capture(String name) {
        android.graphics.Bitmap image = InstrumentationRegistry.getInstrumentation().getUiAutomation().takeScreenshot();
        assertNotNull(image);
        java.io.File directory = new java.io.File(context.getExternalFilesDir(null), "locale-validation");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new AssertionError("Cannot create screenshot directory");
        try (java.io.FileOutputStream stream = new java.io.FileOutputStream(new java.io.File(directory, name + ".png"))) {
            assertTrue(image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream));
        } catch (java.io.IOException e) { throw new AssertionError("Cannot save screenshot", e); }
        finally { image.recycle(); }
    }
}

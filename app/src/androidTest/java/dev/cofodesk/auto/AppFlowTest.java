package dev.cofodesk.auto;

import androidx.test.core.app.ActivityScenario;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.lifecycle.Lifecycle;
import org.junit.*;
import org.junit.runner.RunWith;
import static androidx.test.espresso.Espresso.onView;
import static androidx.test.espresso.action.ViewActions.*;
import static androidx.test.espresso.assertion.ViewAssertions.matches;
import static androidx.test.espresso.matcher.ViewMatchers.*;
import static org.hamcrest.Matchers.*;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class AppFlowTest {
    private android.content.Context context;
    private ActivityScenario<MainActivity> scenario;
    @Before public void launch() {
        context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        if (android.os.Build.VERSION.SDK_INT >= 33) InstrumentationRegistry.getInstrumentation().getUiAutomation().grantRuntimePermission(context.getPackageName(), android.Manifest.permission.POST_NOTIFICATIONS);
        ReminderReceiver.cancel(context); context.getSharedPreferences("desk", 0).edit().clear().commit();
        context.getSharedPreferences("appearance", 0).edit().clear().commit();
        context.getSharedPreferences("simulator", 0).edit().clear().commit();
        scenario = ActivityScenario.launch(MainActivity.class);
    }
    @After public void close() { if (scenario != null) scenario.close(); ReminderReceiver.cancel(context); }
    /** UI text in the app's selected language, so copy changes do not break flow tests. */
    private String text(int resource, Object... values) { return UiPreferences.localized(context).getString(resource, values); }
    private void relaunch() { scenario.close(); scenario = ActivityScenario.launch(MainActivity.class); }

    @Test public void defaultLanguageIsTraditionalChinese() {
        assertEquals("zh-TW", UiPreferences.language(context));
        onView(withId(R.id.status)).check(matches(withText("尚未連線")));
    }
    @Test public void connectionJogPresetAndStop() {
        onView(withId(R.id.status)).check(matches(withText(text(R.string.not_connected))));
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.height)).check(matches(withText("72.0 cm")));
        onView(withId(R.id.up)).perform(longClick());
        onView(withId(R.id.status)).check(matches(withText(text(R.string.connected_stopped))));
        onView(withId(R.id.height)).check(matches(not(withText("72.0 cm"))));
        onView(withId(R.id.preset2)).perform(scrollTo(), click());
        onView(withId(R.id.stop)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(text(R.string.connected_stopped))));
        onView(withId(R.id.preset1)).perform(scrollTo(), longClick());
        onView(withId(R.id.connect)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(text(R.string.not_connected))));
    }
    @Test public void lockCollisionAndRecovery() {
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.lock)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(text(R.string.locked))));
        onView(withId(R.id.lock)).perform(scrollTo(), click());
        onView(withId(R.id.collision)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(text(R.string.fault_collision))));
        onView(withId(R.id.recover)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(text(R.string.connected_stopped))));
    }
    @Test public void profileStartsEmptyAndSurvivesActivityRecreation() {
        onView(withId(R.id.tab_settings)).perform(click());
        onView(withId(R.id.profile_height)).check(matches(withText("")));
        onView(withId(R.id.profile_weight)).check(matches(withText("")));
        onView(withId(R.id.profile_height)).perform(replaceText("180"), closeSoftKeyboard());
        onView(withId(R.id.profile_weight)).perform(replaceText("70.5"), closeSoftKeyboard());
        onView(withId(R.id.units)).perform(scrollTo(), click());
        onView(withId(R.id.save_profile)).perform(scrollTo(), click());
        scenario.recreate();
        onView(withId(R.id.profile_height)).check(matches(withText("180")));
        onView(withId(R.id.profile_weight)).check(matches(withText("70.5")));
        onView(withId(R.id.units)).check(matches(isChecked()));
        onView(withId(R.id.tab_control)).perform(click());
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.height)).check(matches(withText("28.3 in")));
    }
    @Test public void backgroundStopsMovingAndDoesNotResume() {
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.preset2)).perform(scrollTo(), click());
        scenario.moveToState(Lifecycle.State.CREATED); scenario.moveToState(Lifecycle.State.RESUMED);
        onView(withId(R.id.status)).check(matches(withText(text(R.string.connected_stopped))));
    }
    @Test public void simulatedHeightSurvivesRecreationAndRelaunchWithoutResumingMotion() {
        onView(withId(R.id.connect)).perform(click());
        scenario.onActivity(activity -> activity.findViewById(R.id.up).performClick());
        awaitHeight("73.0 cm");
        scenario.recreate();
        onView(withId(R.id.status)).check(matches(withText(text(R.string.not_connected))));
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.height)).check(matches(withText("73.0 cm")));
        relaunch();
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.height)).check(matches(withText("73.0 cm")));
        onView(withId(R.id.preset2)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(text(R.string.moving))));
        scenario.recreate();
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.status)).check(matches(withText(text(R.string.connected_stopped))));
    }
    @Test public void reminderGoalsShortcutsAndHistoryNavigation() {
        onView(withId(R.id.tab_history)).perform(click());
        onView(withId(R.id.history_summary)).check(matches(withText(endsWith(text(R.string.goal_unset)))));
        onView(withId(R.id.history_summary)).check(matches(withText(startsWith(text(R.string.history_summary, 0.0, 0L, "0.0")))));
        onView(withId(R.id.tab_reminders)).perform(click());
        onView(withId(R.id.goal)).check(matches(withText("0")));
        onView(withId(R.id.goal)).perform(replaceText("120"), closeSoftKeyboard());
        onView(withId(R.id.sit_120)).perform(scrollTo(), click());
        onView(withId(R.id.sit_minutes)).check(matches(withText("120")));
        onView(withId(R.id.stand_40)).perform(scrollTo(), click());
        onView(withId(R.id.stand_minutes)).check(matches(withText("40")));
        onView(withId(R.id.save_goals)).perform(scrollTo(), click());
        onView(withId(R.id.sit_60)).perform(scrollTo(), click());
        // Relaunch, not recreate: recreate restores unsaved EditText input by design.
        relaunch();
        onView(withId(R.id.tab_reminders)).perform(click());
        onView(withId(R.id.sit_minutes)).check(matches(withText("120")));
        onView(withId(R.id.stand_minutes)).check(matches(withText("40")));
        onView(withId(R.id.tab_history)).perform(click());
        onView(withId(R.id.history_summary)).check(matches(withText(endsWith(text(R.string.goal_summary, 120, 0, 120.0)))));
        onView(withText(text(R.string.period_week))).perform(click());
        onView(withText(text(R.string.period_month))).perform(click());
        onView(withText(text(R.string.period_year))).perform(click());
        onView(withId(R.id.tab_control)).perform(click());
        onView(withId(R.id.devices)).perform(scrollTo(), click());
        onView(withId(R.id.scan)).check(matches(isDisplayed()));
    }
    @Test public void countdownStartsRestoresAndCancels() {
        onView(withId(R.id.tab_reminders)).perform(click());
        onView(withId(R.id.timer_minutes)).perform(scrollTo(), replaceText("2"), closeSoftKeyboard());
        onView(withId(R.id.start_timer)).perform(scrollTo(), click());
        String remaining = text(R.string.timer_remaining, 0, 0).replace("00:00", "");
        onView(withId(R.id.timer_status)).check(matches(withText(startsWith(remaining))));
        scenario.recreate();
        onView(withId(R.id.timer_status)).check(matches(withText(startsWith(remaining))));
        assertTrue(ReminderReceiver.scheduled(context));
        onView(withId(R.id.cancel_timer)).perform(scrollTo(), click());
        onView(withId(R.id.timer_status)).check(matches(withText(text(R.string.timer_idle))));
        assertFalse(ReminderReceiver.scheduled(context));
        relaunch();
        assertFalse(ReminderReceiver.scheduled(context));
        onView(withId(R.id.tab_reminders)).perform(click());
        onView(withId(R.id.timer_status)).check(matches(withText(text(R.string.timer_idle))));
    }
    @Test public void pendingCountdownIsRearmedOnOpenAfterItsAlarmWasLost() {
        scenario.close();
        context.getSharedPreferences("desk", 0).edit().putString("reminderAtMs", "" + (System.currentTimeMillis() + 600_000)).commit();
        ReminderReceiver.cancelAlarm(context);  // What a reboot does to OS alarms.
        assertFalse(ReminderReceiver.scheduled(context));
        scenario = ActivityScenario.launch(MainActivity.class);
        assertTrue(ReminderReceiver.scheduled(context));
        onView(withId(R.id.tab_reminders)).perform(click());
        scenario.moveToState(Lifecycle.State.CREATED); scenario.moveToState(Lifecycle.State.RESUMED);
        scenario.moveToState(Lifecycle.State.CREATED); scenario.moveToState(Lifecycle.State.RESUMED);
        assertTrue(ReminderReceiver.scheduled(context));
        onView(withId(R.id.timer_status)).check(matches(withText(startsWith(text(R.string.timer_remaining, 0, 0).replace("00:00", "")))));
    }
    @Test public void expiredCountdownIsShownAsDueWithoutALateNotification() {
        scenario.close();
        context.getSharedPreferences("desk", 0).edit().putString("reminderAtMs", "" + (System.currentTimeMillis() - 1000)).commit();
        ReminderReceiver.schedule(context, System.currentTimeMillis() + 600_000);  // A stale alarm must be cleared.
        scenario = ActivityScenario.launch(MainActivity.class);
        onView(withId(R.id.tab_reminders)).perform(click());
        onView(withId(R.id.timer_status)).check(matches(withText(text(R.string.timer_due))));
        assertFalse(ReminderReceiver.scheduled(context));
        NotificationAssertions.assertNotPosted(context.getSystemService(android.app.NotificationManager.class));
    }
    @Test public void receiverPostsNotificationAndCancellationRemovesIt() {
        new ReminderReceiver().onReceive(context, new android.content.Intent(context, ReminderReceiver.class));
        android.app.NotificationManager manager = context.getSystemService(android.app.NotificationManager.class);
        NotificationAssertions.awaitPosted(manager);
        ReminderReceiver.cancel(context);
        NotificationAssertions.awaitRemoved(manager);
    }
    @Test public void cancelledTouchStopsAndAccessibilityClickMovesOneCm() {
        onView(withId(R.id.connect)).perform(click());
        scenario.onActivity(activity -> {
            android.view.View up = activity.findViewById(R.id.up);
            long now = android.os.SystemClock.uptimeMillis();
            android.view.MotionEvent down = android.view.MotionEvent.obtain(now, now, android.view.MotionEvent.ACTION_DOWN, 10, 10, 0);
            android.view.MotionEvent cancel = android.view.MotionEvent.obtain(now, now, android.view.MotionEvent.ACTION_CANCEL, 10, 10, 0);
            up.dispatchTouchEvent(down); up.dispatchTouchEvent(cancel); down.recycle(); cancel.recycle();
        });
        onView(withId(R.id.status)).check(matches(withText(text(R.string.connected_stopped))));
        scenario.onActivity(activity -> activity.findViewById(R.id.up).performClick());
        awaitHeight("73.0 cm");
        onView(withId(R.id.status)).check(matches(withText(text(R.string.connected_stopped))));
    }
    private void awaitHeight(String expected) {
        onView(withId(R.id.height)).perform(new androidx.test.espresso.ViewAction() {
            @Override public org.hamcrest.Matcher<android.view.View> getConstraints() { return isAssignableFrom(android.widget.TextView.class); }
            @Override public String getDescription() { return "wait up to 2 seconds for height " + expected; }
            @Override public void perform(androidx.test.espresso.UiController ui, android.view.View view) {
                long end = android.os.SystemClock.uptimeMillis() + 2000;
                while (android.os.SystemClock.uptimeMillis() < end) {
                    if (((android.widget.TextView) view).getText().toString().equals(expected)) return;
                    ui.loopMainThreadForAtLeast(50);
                }
                throw new AssertionError("Expected " + expected + ", saw " + ((android.widget.TextView) view).getText());
            }
        });
    }
}

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

@RunWith(AndroidJUnit4.class)
public class AppFlowTest {
    private ActivityScenario<MainActivity> scenario;
    @Before public void launch() {
        android.content.Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        if (android.os.Build.VERSION.SDK_INT >= 33) InstrumentationRegistry.getInstrumentation().getUiAutomation().grantRuntimePermission(context.getPackageName(), android.Manifest.permission.POST_NOTIFICATIONS);
        ReminderReceiver.cancel(context); context.getSharedPreferences("desk", 0).edit().clear().commit();
        context.getSharedPreferences("appearance", 0).edit().clear().commit();
        scenario = ActivityScenario.launch(MainActivity.class);
    }
    @After public void close() { if (scenario != null) scenario.close(); }
    @Test public void connectionJogPresetAndStop() {
        onView(withId(R.id.status)).check(matches(withText("尚未連線")));
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.height)).check(matches(withText("72.0 cm")));
        onView(withId(R.id.up)).perform(longClick());
        onView(withId(R.id.status)).check(matches(withText(containsString("已停止"))));
        onView(withId(R.id.height)).check(matches(not(withText("72.0 cm"))));
        onView(withId(R.id.preset2)).perform(scrollTo(), click());
        onView(withId(R.id.stop)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(containsString("已停止"))));
        onView(withId(R.id.preset1)).perform(scrollTo(), longClick());
        onView(withId(R.id.connect)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText("尚未連線")));
    }
    @Test public void lockCollisionAndRecovery() {
        onView(withId(R.id.connect)).perform(click());
        onView(withId(R.id.lock)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText("模擬桌已鎖定")));
        onView(withId(R.id.lock)).perform(scrollTo(), click());
        onView(withId(R.id.collision)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(containsString("障礙物"))));
        onView(withId(R.id.recover)).perform(scrollTo(), click());
        onView(withId(R.id.status)).check(matches(withText(containsString("已停止"))));
    }
    @Test public void profileAndUnitsSurviveActivityRecreation() {
        onView(withId(R.id.tab_settings)).perform(click());
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
        onView(withId(R.id.status)).check(matches(withText(containsString("已停止"))));
    }
    @Test public void reminderGoalsAndHistoryNavigation() {
        onView(withId(R.id.tab_reminders)).perform(click());
        onView(withId(R.id.goal)).perform(replaceText("120"), closeSoftKeyboard());
        onView(withId(R.id.save_goals)).perform(scrollTo(), click());
        onView(withId(R.id.tab_history)).perform(click());
        onView(withId(R.id.history_summary)).check(matches(withText(containsString("今日目標 120 分鐘"))));
        onView(withText("週")).perform(click()); onView(withText("月")).perform(click()); onView(withText("年")).perform(click());
        onView(withId(R.id.tab_control)).perform(click());
        onView(withId(R.id.devices)).perform(scrollTo(), click());
        onView(withId(R.id.scan)).check(matches(isDisplayed()));
    }
    @Test public void countdownStartsRestoresAndCancels() {
        onView(withId(R.id.tab_reminders)).perform(click());
        onView(withId(R.id.timer_minutes)).perform(scrollTo(), replaceText("2"), closeSoftKeyboard());
        onView(withId(R.id.start_timer)).perform(scrollTo(), click());
        onView(withId(R.id.timer_status)).check(matches(withText(startsWith("剩餘"))));
        scenario.recreate();
        onView(withId(R.id.timer_status)).check(matches(withText(startsWith("剩餘"))));
        onView(withId(R.id.cancel_timer)).perform(scrollTo(), click());
        onView(withId(R.id.timer_status)).check(matches(withText("沒有進行中的倒數")));
    }
    @Test public void expiredCountdownIsReconciledAfterRelaunch() {
        scenario.close();
        android.content.Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        context.getSharedPreferences("desk", 0).edit().putString("reminderAtMs", "" + (System.currentTimeMillis() - 1000)).commit();
        scenario = ActivityScenario.launch(MainActivity.class);
        onView(withId(R.id.tab_reminders)).perform(click());
        onView(withId(R.id.timer_status)).check(matches(withText("提醒時間到了，換個姿勢吧")));
    }
    @Test public void receiverPostsNotificationAndCancellationRemovesIt() {
        android.content.Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
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
        onView(withId(R.id.status)).check(matches(withText(containsString("已停止"))));
        scenario.onActivity(activity -> activity.findViewById(R.id.up).performClick());
        onView(withId(R.id.height)).perform(new androidx.test.espresso.ViewAction() {
            @Override public org.hamcrest.Matcher<android.view.View> getConstraints() { return isAssignableFrom(android.widget.TextView.class); }
            @Override public String getDescription() { return "wait up to 2 seconds for one-centimetre accessibility command"; }
            @Override public void perform(androidx.test.espresso.UiController ui, android.view.View view) {
                long end = android.os.SystemClock.uptimeMillis() + 2000;
                while (android.os.SystemClock.uptimeMillis() < end) {
                    if (((android.widget.TextView) view).getText().toString().equals("73.0 cm")) return;
                    ui.loopMainThreadForAtLeast(50);
                }
                throw new AssertionError("Expected 73.0 cm, saw " + ((android.widget.TextView) view).getText());
            }
        });
        onView(withId(R.id.status)).check(matches(withText(containsString("已停止"))));
    }
}

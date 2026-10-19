package dev.cofodesk.auto;

import android.app.NotificationManager;
import android.os.SystemClock;
import android.service.notification.StatusBarNotification;

/** Notification service work is asynchronous; observe delivery rather than racing the binder. */
final class NotificationAssertions {
    static StatusBarNotification awaitPosted(NotificationManager manager) {
        long deadline = SystemClock.elapsedRealtime() + 3000;
        do {
            for (StatusBarNotification notification : manager.getActiveNotifications())
                if (notification.getId() == ReminderReceiver.ID) return notification;
            SystemClock.sleep(20);
        } while (SystemClock.elapsedRealtime() < deadline);
        throw new AssertionError("App notification was not posted within 3 seconds");
    }
    static void awaitRemoved(NotificationManager manager) {
        long deadline = SystemClock.elapsedRealtime() + 3000;
        do {
            if (java.util.Arrays.stream(manager.getActiveNotifications()).noneMatch(n -> n.getId() == ReminderReceiver.ID)) return;
            SystemClock.sleep(20);
        } while (SystemClock.elapsedRealtime() < deadline);
        throw new AssertionError("App notification was not removed within 3 seconds");
    }
}

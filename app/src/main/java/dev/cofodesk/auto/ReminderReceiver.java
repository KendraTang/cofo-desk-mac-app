package dev.cofodesk.auto;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.Build;

public final class ReminderReceiver extends BroadcastReceiver {
    static final String CHANNEL = "desk-reminders";
    static final int ID = 10;
    @Override public void onReceive(Context context, Intent intent) { show(context, UiPreferences.localized(context).getString(R.string.notification_due)); }
    static void show(Context context, String message) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL, UiPreferences.localized(context).getString(R.string.notification_channel), NotificationManager.IMPORTANCE_DEFAULT));
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        PendingIntent open = PendingIntent.getActivity(context, 0, new Intent(context, MainActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        manager.notify(ID, new Notification.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Desk Auto").setContentText(message).setContentIntent(open).setAutoCancel(true).build());
    }
    static PendingIntent pending(Context context) {
        return PendingIntent.getBroadcast(context, 0, new Intent(context, ReminderReceiver.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
    static void schedule(Context context, long atMs) {
        // Inexact OS alarm; no exact-alarm permission or background motor commands.
        context.getSystemService(AlarmManager.class).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending(context));
    }
    static void cancel(Context context) {
        cancelAlarm(context);
        context.getSystemService(NotificationManager.class).cancel(ID);
    }
    /** Also drops the PendingIntent, so {@link #scheduled} reflects whether an alarm is armed. */
    static void cancelAlarm(Context context) {
        PendingIntent pending = pending(context);
        context.getSystemService(AlarmManager.class).cancel(pending);
        pending.cancel();
    }
    static boolean scheduled(Context context) {
        return PendingIntent.getBroadcast(context, 0, new Intent(context, ReminderReceiver.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_NO_CREATE) != null;
    }
}

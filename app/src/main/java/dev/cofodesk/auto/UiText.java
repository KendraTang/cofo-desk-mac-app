package dev.cofodesk.auto;

import android.content.Context;

/** Core message codes remain independent of Android and of the selected UI language. */
final class UiText {
    static String message(Context context, String code) {
        int resource = switch (code) {
            case "error_not_connected" -> R.string.error_not_connected;
            case "error_locked" -> R.string.error_locked;
            case "error_fault" -> R.string.error_fault;
            case "error_height" -> R.string.error_height;
            case "error_limits_unknown" -> R.string.error_limits_unknown;
            case "error_time" -> R.string.error_time;
            case "error_save_preset" -> R.string.error_save_preset;
            case "error_slot" -> R.string.error_slot;
            case "error_profile" -> R.string.error_profile;
            case "error_goals" -> R.string.error_goals;
            case "error_reminder" -> R.string.error_reminder;
            case "fault_collision" -> R.string.fault_collision;
            case "alert_standing" -> R.string.alert_standing;
            case "alert_sitting" -> R.string.alert_sitting;
            case "alert_goal" -> R.string.alert_goal;
            default -> 0;
        };
        return resource == 0 ? code : context.getString(resource);
    }
}

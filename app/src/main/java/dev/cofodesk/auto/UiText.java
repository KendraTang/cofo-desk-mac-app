package dev.cofodesk.auto;

import android.content.Context;
import dev.cofodesk.auto.core.Alert;
import dev.cofodesk.auto.core.Fault;
import dev.cofodesk.auto.core.Refused;

/** Core codes stay independent of Android; exhaustive switches make a missing translation a compile error. */
final class UiText {
    static String refusal(Context context, Refused.Reason reason) {
        return context.getString(switch (reason) {
            case NOT_CONNECTED -> R.string.error_not_connected;
            case LOCKED -> R.string.error_locked;
            case FAULT -> R.string.error_fault;
            case HEIGHT -> R.string.error_height;
            case LIMITS_UNKNOWN -> R.string.error_limits_unknown;
            case SAVE_PRESET -> R.string.error_save_preset;
            case SLOT -> R.string.error_slot;
            case PROFILE -> R.string.error_profile;
            case GOALS -> R.string.error_goals;
            case REMINDER -> R.string.error_reminder;
        });
    }
    static String alert(Context context, Alert alert) {
        return context.getString(switch (alert) {
            case STANDING -> R.string.alert_standing;
            case SITTING -> R.string.alert_sitting;
            case GOAL -> R.string.alert_goal;
        });
    }
    static String fault(Context context, Fault fault) {
        return switch (fault.kind()) {
            case NONE -> context.getString(R.string.fault_none);
            case COLLISION -> context.getString(R.string.fault_collision);
            case DEVICE -> context.getString(R.string.fault_device, fault.code());
            case UNKNOWN -> context.getString(R.string.fault_unknown, fault.code());
        };
    }
}

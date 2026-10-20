package dev.cofodesk.auto.core;

import org.junit.Test;
import static org.junit.Assert.*;

public class StandingCaloriesTest {
    @Test public void matchesOriginalFormulaAndTruncation() {
        assertEquals(157, StandingCalories.estimate(3_600_000, 65));
        assertEquals(2, StandingCalories.estimate(60_000, 65));
        assertEquals(0, StandingCalories.estimate(999, 65));
        assertEquals(0, StandingCalories.estimate(3_600_000, 0));
    }
    @Test public void canonicalDecimalKgHasNoIntegerParseFailure() {
        assertEquals(173, StandingCalories.estimate(3_600_000, 75.5));
        assertEquals(0, StandingCalories.estimate(60_000, Double.NaN));
        assertThrows(IllegalArgumentException.class, () -> StandingCalories.estimate(-1, 65));
    }
    @Test public void drumsticksAreKcalOver200WithOneDecimal() {
        assertEquals("0.0", StandingCalories.drumsticks(0));
        assertEquals("0.8", StandingCalories.drumsticks(157));
        assertEquals("0.3", StandingCalories.drumsticks(50));
        assertEquals("2.0", StandingCalories.drumsticks(400));
    }
    @Test public void historyUsesDailyRoundingForMonthAndMonthlyRoundingForYear() {
        java.time.ZoneId zone = java.time.ZoneId.of("Asia/Taipei");
        ActivityHistory history = new ActivityHistory(zone);
        long day1 = java.time.LocalDate.of(2026, 10, 19).atTime(12, 0).atZone(zone).toInstant().toEpochMilli();
        long day2 = day1 + 86_400_000;
        history.add(day1, day1 + 20_000); history.add(day2, day2 + 20_000);
        assertEquals(0, history.estimatedCalories(ActivityHistory.Period.MONTH, day2 + 60_000, 65));
        assertEquals(1, history.estimatedCalories(ActivityHistory.Period.YEAR, day2 + 60_000, 65));
    }
}

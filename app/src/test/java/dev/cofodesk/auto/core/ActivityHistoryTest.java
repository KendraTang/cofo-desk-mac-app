package dev.cofodesk.auto.core;

import org.junit.Test;
import java.time.*;
import java.util.Properties;
import static org.junit.Assert.*;

public class ActivityHistoryTest {
    private final ZoneId zone = ZoneId.of("Asia/Taipei");
    private long at(String dateTime) { return LocalDateTime.parse(dateTime).atZone(zone).toInstant().toEpochMilli(); }
    @Test public void midnightSplitsBucketsAndYearDoesNotLeak() {
        ActivityHistory history = new ActivityHistory(zone);
        history.add(at("2025-12-31T23:59:30"), at("2026-01-01T00:00:30"));
        assertEquals(30_000, history.day(LocalDate.of(2025, 12, 31)));
        assertEquals(30_000, history.total(ActivityHistory.Period.YEAR, at("2026-01-01T00:01:00")));
        assertEquals(60_000, history.total(ActivityHistory.Period.WEEK, at("2026-01-01T00:01:00")));
    }
    @Test public void weekStartsMondayAndMonthExcludesOldDays() {
        ActivityHistory history = new ActivityHistory(zone);
        history.add(at("2026-09-30T12:00:00"), at("2026-09-30T12:01:00"));
        history.add(at("2026-10-18T12:00:00"), at("2026-10-18T12:02:00"));
        history.add(at("2026-10-19T12:00:00"), at("2026-10-19T12:03:00"));
        long now = at("2026-10-20T12:00:00");
        assertEquals(180_000, history.total(ActivityHistory.Period.WEEK, now));
        assertEquals(300_000, history.total(ActivityHistory.Period.MONTH, now));
        assertEquals(360_000, history.total(ActivityHistory.Period.YEAR, now));
        assertEquals(0, history.total(ActivityHistory.Period.DAY, now));
    }
    @Test public void dstDayUsesActualElapsedTime() {
        ZoneId ny = ZoneId.of("America/New_York"); ActivityHistory history = new ActivityHistory(ny);
        LocalDate date = LocalDate.of(2026, 3, 8);
        history.add(date.atStartOfDay(ny).toInstant().toEpochMilli(), date.plusDays(1).atStartOfDay(ny).toInstant().toEpochMilli());
        assertEquals(23 * 3_600_000L, history.day(date));
    }
    @Test public void persistenceAndClear() {
        ActivityHistory history = new ActivityHistory(zone); history.add(at("2026-10-20T10:00:00"), at("2026-10-20T10:01:00"));
        Properties p = new Properties(); history.save(p); p.setProperty("day.bad", "5"); p.setProperty("day.2026-10-19", "-3");
        ActivityHistory next = new ActivityHistory(zone); next.restore(p);
        assertEquals(60_000, next.total(ActivityHistory.Period.MONTH, at("2026-10-20T12:00:00")));
        next.clear(); assertEquals(0, next.total(ActivityHistory.Period.MONTH, at("2026-10-20T12:00:00")));
    }
}

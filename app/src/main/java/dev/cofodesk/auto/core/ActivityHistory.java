package dev.cofodesk.auto.core;

import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.temporal.TemporalAdjusters;
import java.time.DayOfWeek;
import java.util.Map;
import java.util.Properties;
import java.util.TreeMap;

/** Local calendar buckets. Background time is deliberately not inferred from the last height. */
public final class ActivityHistory {
    public enum Period { DAY, WEEK, MONTH, YEAR }
    private final ZoneId zone;
    private final Map<LocalDate, Long> standing = new TreeMap<>();
    public ActivityHistory(ZoneId zone) { this.zone = zone; }
    public void add(long fromMs, long toMs) {
        if (toMs < fromMs) throw new IllegalArgumentException("Interval ends before it starts");
        while (fromMs < toMs) {
            LocalDate date = date(fromMs);
            long end = Math.min(toMs, date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli());
            standing.merge(date, end - fromMs, Long::sum);
            fromMs = end;
        }
    }
    public LocalDate date(long ms) { return Instant.ofEpochMilli(ms).atZone(zone).toLocalDate(); }
    public long total(Period period, long nowMs) {
        return selected(period, nowMs).mapToLong(Map.Entry::getValue).sum();
    }
    /** Original week/month sums truncated daily calories; year sums truncated monthly calories. */
    public long estimatedCalories(Period period, long nowMs, double weightKg) {
        if (period != Period.YEAR) return selected(period, nowMs).mapToLong(e -> StandingCalories.estimate(e.getValue(), weightKg)).sum();
        Map<java.time.YearMonth, Long> months = new TreeMap<>();
        selected(period, nowMs).forEach(e -> months.merge(java.time.YearMonth.from(e.getKey()), e.getValue(), Long::sum));
        return months.values().stream().mapToLong(ms -> StandingCalories.estimate(ms, weightKg)).sum();
    }
    private java.util.stream.Stream<Map.Entry<LocalDate, Long>> selected(Period period, long nowMs) {
        LocalDate date = date(nowMs);
        LocalDate first = switch (period) {
            case DAY -> date;
            case WEEK -> date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY));
            case MONTH -> date.withDayOfMonth(1);
            case YEAR -> date.withDayOfYear(1);
        };
        return standing.entrySet().stream().filter(e -> !e.getKey().isBefore(first) && !e.getKey().isAfter(date));
    }
    public long day(LocalDate date) { return standing.getOrDefault(date, 0L); }
    public void clear() { standing.clear(); }
    public void save(Properties p) { standing.forEach((date, ms) -> p.setProperty("day." + date, "" + ms)); }
    public void restore(Properties p) {
        standing.clear();
        for (String key : p.stringPropertyNames()) if (key.startsWith("day.")) {
            try {
                LocalDate date = LocalDate.parse(key.substring(4));
                long ms = Long.parseLong(p.getProperty(key));
                if (ms > 0 && ms <= 90_000_000) standing.put(date, ms);
            } catch (RuntimeException ignored) { /* Ignore corrupt buckets only. */ }
        }
    }
}

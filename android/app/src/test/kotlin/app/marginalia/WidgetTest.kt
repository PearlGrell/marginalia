package app.marginalia

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WidgetTest {
    private val today = LocalDate.of(2026, 10, 14)

    @Test
    fun todaysReadingShowsTheStreakAndMinutes() {
        assertEquals(
            ContinueReadingWidget.Status("5-day streak · 12/30 min today", streak = true),
            ContinueReadingWidget.statusLine(today, today, todaySeconds = 720, streak = 5, goalMinutes = 30),
        )
    }

    @Test
    fun afterMidnightTheStreakAsksForToday() {
        assertEquals(
            ContinueReadingWidget.Status("5-day streak · read today", streak = true),
            ContinueReadingWidget.statusLine(today, today.minusDays(1), todaySeconds = 900, streak = 5, goalMinutes = 30),
        )
    }

    @Test
    fun withoutAStreakItsJustTodaysMinutes() {
        assertEquals(
            ContinueReadingWidget.Status("12/30 min today", streak = false),
            ContinueReadingWidget.statusLine(today, today, todaySeconds = 720, streak = 0, goalMinutes = 30),
        )
    }

    @Test
    fun aLapsedStreakAndNoGoalSayNothing() {
        assertNull(ContinueReadingWidget.statusLine(today, today.minusDays(3), todaySeconds = 900, streak = 2, goalMinutes = 0))
    }

    @Test
    fun theHighlightOfTheDayStaysAllDayAndMovesOnTomorrow() {
        val quotes = listOf("a", "b", "c").map { QuoteWidget.Quote(it, "Book", "id", null) }
        assertEquals("b", QuoteWidget.pick(quotes, epochDay = 1)?.text)
        assertEquals("c", QuoteWidget.pick(quotes, epochDay = 2)?.text)
        assertEquals("a", QuoteWidget.pick(quotes, epochDay = 3)?.text)
        assertEquals(null, QuoteWidget.pick(emptyList(), epochDay = 3))
    }
}

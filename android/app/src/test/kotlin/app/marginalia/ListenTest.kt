package app.marginalia

import app.marginalia.listen.clauses
import app.marginalia.listen.matchKey
import app.marginalia.listen.sameSentence
import app.marginalia.listen.trimSilence
import app.marginalia.readium.Follow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ListenTest {
    @Test
    fun shortSentencesStayWhole() {
        assertEquals(listOf("She left, and he stayed."), clauses("She left, and he stayed."))
    }

    @Test
    fun longSentencesBreakAfterCommasIntoFullPieces() {
        val sentence = "When the carriage at last came round the bend in the road, " +
            "the whole household, servants and all, had gathered on the steps to watch it arrive, " +
            "though nobody had said they would."
        val pieces = clauses(sentence)
        assertTrue(pieces.size > 1)
        assertTrue(pieces.dropLast(1).all { it.length >= 50 })
        assertEquals(sentence.replace(" ", ""), pieces.joinToString("").replace(" ", ""))
    }

    @Test
    fun silenceAroundSpeechIsTrimmedToWhatIsKept() {
        val rate = 1000
        val samples = FloatArray(500) + FloatArray(100) { 0.5f } + FloatArray(400)
        val trimmed = trimSilence(samples, rate, lead = 0.02, tail = 0.1)
        assertEquals(20 + 100 + 100, trimmed.size)
    }

    @Test
    fun followingTurnsOnlyWhenTheSentenceIsOffThePage() {
        assertEquals(Follow.Visible, Follow.parse("visible"))
        assertEquals(Follow.Pages(1), Follow.parse("page:1"))
        assertEquals(Follow.Pages(-1), Follow.parse("page:-1"))
        // Far away: go straight there.
        assertEquals(Follow.Unknown, Follow.parse("page:9"))
        assertEquals(Follow.Scroll(-120), Follow.parse("scroll:-120"))
        assertEquals(Follow.Unknown, Follow.parse(null))
    }

    @Test
    fun aTappedSentenceMatchesReadiumsDespiteQuotesAndCase() {
        val page = matchKey("\u201D She said nothing at all, and went upstairs.")
        val readium = matchKey("She said nothing at all, and went upstairs.")
        assertTrue(sameSentence(readium, page))
        assertFalse(sameSentence(matchKey("He came back the next day."), page))
    }
}

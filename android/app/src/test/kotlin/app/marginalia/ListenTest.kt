package app.marginalia

import app.marginalia.listen.Gender
import app.marginalia.listen.Narrator
import app.marginalia.listen.Narrators
import app.marginalia.listen.VoiceInfo
import app.marginalia.listen.joinSentences
import app.marginalia.listen.matchKey
import app.marginalia.listen.sameSentence
import app.marginalia.listen.spokenText
import app.marginalia.readium.Follow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ListenTest {
    private fun voice(name: String, quality: Int = 3, network: Boolean = false) =
        VoiceInfo(name, name.substringBefore("-x-").replace(Regex("^([a-z]+)-([a-z]+)$")) { "${it.groupValues[1]}-${it.groupValues[2].uppercase()}" }, quality, network)

    @Test
    fun voicesAreToldApartByTheirNames() {
        assertEquals(Gender.Female, Narrators.genderOf("en-us-x-tpf-local"))
        assertEquals(Gender.Male, Narrators.genderOf("en-us-x-iom-network"))
        assertEquals(Gender.Female, Narrators.genderOf("en-US-SMTf00"))
        assertEquals(Gender.Male, Narrators.genderOf("en-GB-SMTm01"))
        assertEquals(Gender.Female, Narrators.genderOf("en-gb#female_2-local"))
        assertEquals(Gender.Male, Narrators.genderOf("en-gb#male_1-local"))
        assertEquals(null, Narrators.genderOf("en-in-x-zzz-local"))
    }

    @Test
    fun leighaAndAlexAreTheBestOfflineVoicesForTheBook() {
        val voices = listOf(
            voice("en-us-x-sfg-local"), voice("en-us-x-tpf-local"), voice("en-us-x-tpf-network", quality = 4, network = true),
            voice("en-us-x-iol-local"), voice("en-us-x-iom-local"), voice("en-gb-x-rjs-local"), voice("fr-fr-x-frb-local"),
        )
        val picked = Narrators.pick(voices, "en")
        assertEquals("en-us-x-tpf-local", picked[Narrator.Leigha]?.name)
        assertEquals("en-us-x-iom-local", picked[Narrator.Alex]?.name)
        // A British book gets British voices where there are some.
        assertEquals("en-gb-x-rjs-local", Narrators.pick(voices, "en-GB")[Narrator.Alex]?.name)
    }

    @Test
    fun voicesThatCantBeToldApartStillGiveTwoNarrators() {
        val picked = Narrators.pick(listOf(voice("hi-in-x-hia-local"), voice("hi-in-x-hie-local")), "hi")
        assertEquals(2, picked.size)
        assertTrue(picked[Narrator.Leigha] != picked[Narrator.Alex])
        assertTrue(Narrators.pick(listOf(voice("hi-in-x-hia-local")), "ja").isEmpty())
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

    /** The sentences [joinSentences] makes of [pieces] (as ICU cut them), joined by spaces. */
    private fun sentences(vararg pieces: String): List<String> {
        val text = pieces.joinToString(" ")
        var start = 0
        val ranges = pieces.map { piece -> (start until start + piece.length).also { start += piece.length + 1 } }
        return joinSentences(text, ranges).map { text.substring(it) }
    }

    @Test
    fun sentencesDontEndAtTitlesInitialsOrEllipses() {
        assertEquals(
            listOf("“Winky,” said Hermione firmly, “I’m quite sure Mr. Crouch is getting along.", "We’ve seen him."),
            sentences("“Winky,” said Hermione firmly, “I’m quite sure Mr.", "Crouch is getting along.", "We’ve seen him."),
        )
        assertEquals(listOf("By J. K. Rowling."), sentences("By J.", "K.", "Rowling."))
        assertEquals(
            listOf("But Winky is not saying . . .", "Winky keeps her secrets. . . .”"),
            sentences("But Winky is not saying .", ".", ".", "Winky keeps her secrets.", ".", ".", ".”"),
        )
        assertEquals(listOf("It was late.", "Mr. Bagman came."), sentences("It was late.", "Mr.", "Bagman came."))
    }

    @Test
    fun dashesAreSpokenAsShortPauses() {
        assertEquals("“Bagman, bad?” said Harry.", spokenText("“Bagman — bad?” said Harry."))
        assertEquals("We’ve seen him, you know”", spokenText("We’ve seen him, you know —”"))
        assertEquals("Winky, Winky keeps her master’s secrets…”", spokenText("Winky — Winky keeps her master’s secrets. . . .”"))
        assertEquals("“Well, I never.”", spokenText("“—Well—I never.”"))
        assertEquals("Pages 10–12.", spokenText("Pages 10–12."))
    }
}

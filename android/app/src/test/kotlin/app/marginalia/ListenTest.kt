package app.marginalia

import app.marginalia.listen.Gender
import app.marginalia.listen.Narrator
import app.marginalia.listen.Narrators
import app.marginalia.listen.VoiceInfo
import app.marginalia.listen.matchKey
import app.marginalia.listen.sameSentence
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
}

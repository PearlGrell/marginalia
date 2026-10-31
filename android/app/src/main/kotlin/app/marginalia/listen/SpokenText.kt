@file:OptIn(ExperimentalReadiumApi::class)

package app.marginalia.listen

import org.readium.navigator.media.tts.TtsEngine
import org.readium.navigator.media.tts.TtsEngineProvider
import org.readium.navigator.media.tts.android.AndroidTtsEngine
import org.readium.navigator.media.tts.android.AndroidTtsEngineProvider
import org.readium.navigator.media.tts.android.AndroidTtsPreferences
import org.readium.navigator.media.tts.android.AndroidTtsPreferencesEditor
import org.readium.navigator.media.tts.android.AndroidTtsSettings
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.Error
import org.readium.r2.shared.util.Language
import org.readium.r2.shared.util.Try
import org.readium.r2.shared.util.tokenizer.DefaultTextContentTokenizer
import org.readium.r2.shared.util.tokenizer.TextUnit
import org.readium.r2.shared.util.tokenizer.Tokenizer

/**
 * How the book's text is cut into sentences and spoken, so it sounds like reading rather than
 * reciting.
 *
 * Readium cuts sentences with ICU, which ends one at every "Mr." and at each dot of a spaced
 * ". . .". Each piece is a separate request to the speech engine, with a gap after it, so
 * "Mr. Crouch" came out as "Mister … Crouch". [sentenceTokenizer] joins those pieces again.
 *
 * Speech engines pause at a dash for longer than at a full stop. [spokenText] reads a dash
 * between words as a comma, and drops one at either end of a sentence (the gap between
 * sentences is pause enough). Only what's spoken changes: the sentence highlighted in the page
 * is the book's own text.
 */
fun sentenceTokenizer(language: Language?): Tokenizer<String, IntRange> {
    val icu = DefaultTextContentTokenizer(TextUnit.Sentence, language)
    return object : Tokenizer<String, IntRange> {
        override fun tokenize(data: String): List<IntRange> = joinSentences(data, icu.tokenize(data))
    }
}

/** Titles and abbreviations a sentence doesn't end at (lowercase, without the last dot). */
private val ABBREVIATIONS = setOf(
    "mr", "mrs", "ms", "mx", "messrs", "dr", "prof", "st", "mt", "sr", "jr", "rev", "hon",
    "capt", "col", "gen", "lt", "sgt", "cpl", "maj", "adm", "gov", "pres", "sen", "rep",
    "mme", "mlle", "vs", "e.g", "i.e", "cf", "fig", "vol", "ch",
)

private val LAST_WORD = Regex("""(?:^|[\s(\[“"‘'])([\p{L}][\p{L}.]*)\.$""")

/** [ranges] of [text], with a piece that doesn't end a sentence joined to the next. */
internal fun joinSentences(text: String, ranges: List<IntRange>): List<IntRange> {
    val joined = mutableListOf<IntRange>()
    for (range in ranges) {
        val previous = joined.lastOrNull()
        if (previous != null && continues(text.substring(previous), text.substring(range))) {
            joined[joined.lastIndex] = previous.first..range.last
        } else {
            joined += range
        }
    }
    return joined
}

private fun continues(previous: String, next: String): Boolean {
    val start = next.trimStart()
    // ". ." of a spaced ellipsis, a stray closing quote: nothing to say on its own.
    if (start.none { it.isLetterOrDigit() }) return true
    // ICU broke inside a sentence ("saying . . . and then").
    if (start.first().isLowerCase()) return true
    val word = LAST_WORD.find(previous.trimEnd())?.groupValues?.get(1) ?: return false
    // A title ("Mr.") or an initial ("J. K. Rowling").
    return word.lowercase() in ABBREVIATIONS || (word.length == 1 && word[0].isUpperCase())
}

private val SPACED_ELLIPSIS = Regex("""\.(?:\s?\.){2,}""")
private const val DASH = """(?:[—―]|--|\s–\s)"""
private val DASH_AT_END = Regex("""\s*$DASH+(?=[\s"”’')\]]*$)""")
private val DASH_AT_START = Regex("""^([\s"“‘'(\[]*)$DASH+\s*""")
private val DASH_BETWEEN = Regex("""\s*$DASH+\s*""")
private val COMMA_BEFORE_STOP = Regex(""",\s*([,.?!;:…])""")

/** [text] as it should be spoken. */
internal fun spokenText(text: String): String = text
    .replace(SPACED_ELLIPSIS, "…")
    .replace(DASH_AT_END, "")
    .replace(DASH_AT_START, "$1")
    .replace(DASH_BETWEEN, ", ")
    .replace(COMMA_BEFORE_STOP, "$1")

typealias PhoneEngine = TtsEngine<AndroidTtsSettings, AndroidTtsPreferences, AndroidTtsEngine.Error, AndroidTtsEngine.Voice>

/** The phone's speech engine, saying [spokenText] for each sentence. */
class SpokenTextEngineProvider(
    private val engines: AndroidTtsEngineProvider,
) : TtsEngineProvider<AndroidTtsSettings, AndroidTtsPreferences, AndroidTtsPreferencesEditor, AndroidTtsEngine.Error, AndroidTtsEngine.Voice> by engines {

    override suspend fun createEngine(publication: Publication, initialPreferences: AndroidTtsPreferences): Try<PhoneEngine, Error> =
        engines.createEngine(publication, initialPreferences).map<PhoneEngine> { SpokenTextEngine(it) }
}

private class SpokenTextEngine(private val engine: PhoneEngine) : PhoneEngine by engine {

    override fun speak(requestId: TtsEngine.RequestId, text: String, language: Language?) =
        engine.speak(requestId, spokenText(text), language)
}

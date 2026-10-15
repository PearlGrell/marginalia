package app.marginalia.listen

/**
 * Listen's two narrators, Leigha and Alex: the most natural female and male voices the phone's
 * own text-to-speech has for a book's language.
 *
 * Android doesn't say which voices are female or male, so it's read from their names: Google's
 * voices have a three-letter code ("en-us-x-iom-local"), Samsung's say f or m ("en-US-SMTf00"),
 * and some engines spell it out. A narrator whose voice can't be told falls back to the best
 * voice left, so a book in any language the phone speaks still has two.
 */
enum class Narrator(val id: String, val label: String) {
    Leigha("leigha", "Leigha"),
    Alex("alex", "Alex"),
    ;

    companion object {
        fun byId(id: String?): Narrator? = entries.firstOrNull { it.id == id }
    }
}

/** What a narrator needs to know about a voice. [quality] is Android's (higher is better). */
data class VoiceInfo(val name: String, val language: String, val quality: Int, val requiresNetwork: Boolean)

enum class Gender { Female, Male }

object Narrators {
    /** Google's voices by code, most natural first (from listening to them). */
    private val googleFemale = listOf(
        "tpf", "sfg", "iob", "iog", "tpc", // en-US
        "gbg", "gba", "gbc", "fis", // en-GB
        "afh", "aua", "auc", // en-AU
    )
    private val googleMale = listOf(
        "iom", "iol", "tpd", // en-US
        "rjs", "gbb", "gbd", // en-GB
        "aub", "aud", // en-AU
    )

    private val googleCode = Regex("-x-([a-z]{3})(?:-|$)")

    fun genderOf(name: String): Gender? {
        val n = name.lowercase()
        googleCode.find(n)?.groupValues?.get(1)?.let { code ->
            if (code in googleFemale) return Gender.Female
            if (code in googleMale) return Gender.Male
        }
        Regex("smt([fm])\\d").find(n)?.groupValues?.get(1)?.let { return if (it == "f") Gender.Female else Gender.Male }
        if (Regex("(^|[^a-z])female").containsMatchIn(n)) return Gender.Female
        if (Regex("(^|[^a-z])male").containsMatchIn(n)) return Gender.Male
        return null
    }

    /** Where a known voice comes in its gender's list (lower is more natural). */
    private fun preference(name: String): Int {
        val code = googleCode.find(name.lowercase())?.groupValues?.get(1) ?: return 100
        return (googleFemale.indexOf(code).takeIf { it >= 0 } ?: googleMale.indexOf(code).takeIf { it >= 0 } ?: 100)
    }

    private fun base(language: String) = language.lowercase().replace('_', '-').substringBefore('-')

    /**
     * The voice for each narrator reading [language] (BCP 47, "en" or "en-GB"), out of
     * [voices]. [region] is the phone's, used when the book doesn't name one. Voices that work
     * offline come first, then the book's (or phone's) region, quality, and how natural they
     * are. Empty when the phone has no voice for the language.
     */
    fun pick(voices: Collection<VoiceInfo>, language: String, region: String? = null): Map<Narrator, VoiceInfo> {
        val lang = language.lowercase().replace('_', '-')
        val wantedRegion = lang.substringAfter('-', "").ifEmpty { region?.lowercase().orEmpty() }
            .ifEmpty { if (base(lang) == "en") "us" else "" }
        val candidates = voices.filter { base(it.language) == base(lang) }
        if (candidates.isEmpty()) return emptyMap()

        val ranked = candidates.sortedWith(
            compareBy<VoiceInfo>(
                { it.requiresNetwork },
                { it.language.lowercase().replace('_', '-').substringAfter('-', "") != wantedRegion },
                { -it.quality },
                { preference(it.name) },
                { it.name },
            ),
        )
        val leigha = ranked.firstOrNull { genderOf(it.name) == Gender.Female }
        val alex = ranked.firstOrNull { genderOf(it.name) == Gender.Male }
        val left = ranked.filter { it != leigha && it != alex }
        val result = mutableMapOf<Narrator, VoiceInfo>()
        (leigha ?: left.firstOrNull())?.let { result[Narrator.Leigha] = it }
        (alex ?: left.firstOrNull { it != result[Narrator.Leigha] })?.let { result[Narrator.Alex] = it }
        return result
    }
}

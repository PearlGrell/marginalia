package app.marginalia.readium

import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.preferences.Color
import org.readium.r2.navigator.preferences.ColumnCount
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.preferences.ImageFilter
import org.readium.r2.navigator.preferences.TextAlign
import org.readium.r2.navigator.preferences.Theme

/**
 * Maps the reader preferences sent from Dart to Readium's [EpubPreferences].
 *
 * Keys: `theme` (light | sepia | dark), `backgroundColor` and `textColor` (ARGB ints),
 * `fontSize` (1.0 = 100%), `lineHeight`, `pageMargins`, `scroll`, `publisherStyles`,
 * `textAlign` (start | justify), `hyphens`, `imageFilter` (darken | invert),
 * `fontFamily` (a CSS family name, see [ReadingFonts]; absent for the book's own).
 */
object PreferencesMapper {

    fun fromMap(map: Map<String, Any?>): EpubPreferences = EpubPreferences(
        theme = when (map["theme"]) {
            "light" -> Theme.LIGHT
            "sepia" -> Theme.SEPIA
            "dark" -> Theme.DARK
            else -> null
        },
        backgroundColor = (map["backgroundColor"] as? Number)?.let { Color(it.toInt()) },
        textColor = (map["textColor"] as? Number)?.let { Color(it.toInt()) },
        fontSize = (map["fontSize"] as? Number)?.toDouble(),
        fontFamily = (map["fontFamily"] as? String)?.let(::FontFamily),
        lineHeight = (map["lineHeight"] as? Number)?.toDouble(),
        pageMargins = (map["pageMargins"] as? Number)?.toDouble(),
        scroll = map["scroll"] as? Boolean,
        publisherStyles = map["publisherStyles"] as? Boolean,
        textAlign = when (map["textAlign"]) {
            "start" -> TextAlign.START
            "justify" -> TextAlign.JUSTIFY
            else -> null
        },
        hyphens = map["hyphens"] as? Boolean,
        columnCount = when (map["columnCount"]) {
            "auto" -> ColumnCount.AUTO
            "1" -> ColumnCount.ONE
            "2" -> ColumnCount.TWO
            else -> null
        },
        imageFilter = when (map["imageFilter"]) {
            "darken" -> ImageFilter.DARKEN
            "invert" -> ImageFilter.INVERT
            else -> null
        },
    )

    /** The page color to paint behind the WebView, so there is no flash while it loads. */
    fun backgroundColor(map: Map<String, Any?>): Int =
        (map["backgroundColor"] as? Number)?.toInt() ?: android.graphics.Color.WHITE
}

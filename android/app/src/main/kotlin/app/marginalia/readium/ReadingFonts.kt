package app.marginalia.readium

import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.epub.css.FontStyle
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.shared.ExperimentalReadiumApi

/**
 * The reading fonts bundled with the app (as Flutter assets, which are Android assets under
 * `flutter_assets/`), declared to Readium so books can use them. All are variable fonts with
 * an upright and an italic file. OpenDyslexic ships with Readium itself.
 */
@OptIn(ExperimentalReadiumApi::class)
object ReadingFonts {

    private const val DIR = "flutter_assets/assets/fonts"

    /** CSS family name to the font file's base name. */
    private val fonts = mapOf(
        "Literata" to "Literata",
        "Source Serif 4" to "SourceSerif4",
        "EB Garamond" to "EBGaramond",
        "Atkinson Hyperlegible" to "AtkinsonHyperlegible",
    )

    fun configuration(): EpubNavigatorFragment.Configuration =
        EpubNavigatorFragment.Configuration {
            servedAssets = servedAssets + "$DIR/.*"
            for ((family, file) in fonts) {
                addFontFamilyDeclaration(FontFamily(family)) {
                    addFontFace {
                        addSource("$DIR/$file.ttf")
                        setFontStyle(FontStyle.NORMAL)
                        setFontWeight(200..900)
                    }
                    addFontFace {
                        addSource("$DIR/$file-Italic.ttf")
                        setFontStyle(FontStyle.ITALIC)
                        setFontWeight(200..900)
                    }
                }
            }
        }
}

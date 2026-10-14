package app.marginalia

import app.marginalia.library.bookExtension
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImportTest {
    private fun head(text: String) = text.toByteArray(Charsets.ISO_8859_1)

    @Test
    fun aBooksKindComesFromItsFirstBytes() {
        assertEquals("pdf", bookExtension(head("%PDF-1.7\n")))
        // An EPUB's first zip entry is its mimetype file, stored uncompressed.
        assertEquals("epub", bookExtension(head("PK\u0003\u0004" + "\u0000".repeat(26) + "mimetypeapplication/epub+zip")))
        assertEquals("cbz", bookExtension(head("PK\u0003\u0004" + "\u0000".repeat(26) + "page001.jpg")))
        assertNull(bookExtension(head("<html>")))
    }
}

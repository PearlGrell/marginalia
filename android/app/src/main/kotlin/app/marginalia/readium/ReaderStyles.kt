package app.marginalia.readium

import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.Try
import org.readium.r2.shared.util.resource.TransformingContainer
import org.readium.r2.shared.util.resource.TransformingResource

/**
 * Marginalia's own styles and script, added to every HTML resource of a book as it is read.
 *
 * Images: most EPUB illustrations are opaque JPEGs or PNGs with a white background, which
 * shows as a stark box on paper and sepia pages. Each image is multiplied by the page color,
 * so white becomes the page color and dark lines stay dark.
 *
 * `mix-blend-mode: multiply` isn't reliable here: Readium CSS gives the root element a
 * perspective, which can put the content on its own compositing layer, where images blend
 * with a transparent backdrop instead of the page color. An SVG color-matrix filter
 * multiplies the image's own pixels instead, with the page color read from the root element
 * and kept in step when the theme changes. Readium's own sepia blend is turned off, so the
 * page color is never applied twice.
 *
 * Dark pages are left alone (multiplying would hide the images); Readium's darken filter
 * dims them there. Readium marks dark pages with `readium-night-on` in the root's style.
 */
private const val INJECTION = """
<style id="marginalia-styles">
:root:not([style*="readium-night-on"]) img,
:root:not([style*="readium-night-on"]) svg:not(#marginalia-filters) {
  filter: url(#marginalia-paper);
  /* Readium's sepia theme multiplies images onto the page too; with the filter that
     would apply the page color twice and leave a darker box. */
  mix-blend-mode: normal !important;
}
</style>
<script id="marginalia-script">
//<![CDATA[
(function () {
  var SVG = 'http://www.w3.org/2000/svg';
  var matrix;

  function install() {
    var svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('id', 'marginalia-filters');
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('width', '0');
    svg.setAttribute('height', '0');
    svg.style.position = 'absolute';
    var filter = document.createElementNS(SVG, 'filter');
    filter.setAttribute('id', 'marginalia-paper');
    filter.setAttribute('color-interpolation-filters', 'sRGB');
    matrix = document.createElementNS(SVG, 'feColorMatrix');
    matrix.setAttribute('type', 'matrix');
    filter.appendChild(matrix);
    svg.appendChild(filter);
    document.body.insertBefore(svg, document.body.firstChild);
    update();
    new MutationObserver(update).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['style']
    });
  }

  function update() {
    var c = (getComputedStyle(document.documentElement).backgroundColor || '')
      .match(/[\d.]+/g);
    var r = 1, g = 1, b = 1;
    if (c && c.length >= 3 && (c.length === 3 || +c[3] > 0)) {
      r = c[0] / 255; g = c[1] / 255; b = c[2] / 255;
    }
    matrix.setAttribute('values',
      r + ' 0 0 0 0  0 ' + g + ' 0 0 0  0 0 ' + b + ' 0 0  0 0 0 1 0');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install);
  } else {
    install();
  }
})();
//]]>
</script>
"""

private val HEAD_END = Regex("</head\\s*>", RegexOption.IGNORE_CASE)

/** Wraps the publication's resources so HTML documents get [INJECTION]. */
fun Publication.Builder.injectReaderStyles() {
    val manifest = manifest
    container = TransformingContainer(container) { url, resource ->
        val isHtml = manifest.linkWithHref(url)?.mediaType?.isHtml
            ?: (url.path?.substringAfterLast('.')?.lowercase() in setOf("html", "htm", "xhtml"))
        if (!isHtml) {
            resource
        } else {
            TransformingResource(resource) { bytes ->
                val html = bytes.decodeToString()
                val match = HEAD_END.find(html)
                if (match == null) {
                    Try.success(bytes)
                } else {
                    val styled = StringBuilder(html).insert(match.range.first, INJECTION)
                    Try.success(styled.toString().encodeToByteArray())
                }
            }
        }
    }
}

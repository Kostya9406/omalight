// The OmaLight mark: a yin-yang drawn on a coarse pixel grid, the way the
// Omarchy logo is built from square steps. Shared by the overlay (Canvas) and
// tools/make-icon.js (icon.svg / preview), so the two can never drift apart.

// Cells of an n×n grid that are ink, as [column, row] pairs. The dark half is
// filled, the light half is only an outline, as in the Omarchy icon.
function yinYangCells(n) {
  var size = n || 16
  var c = size / 2
  var R = size / 2 - 0.5
  var ring = 1.6
  var cells = []
  for (var row = 0; row < size; row++) {
    for (var col = 0; col < size; col++) {
      var x = col + 0.5 - c, y = row + 0.5 - c
      var d = Math.sqrt(x * x + y * y)
      if (d > R) continue
      var dUp = Math.sqrt(x * x + (y + R / 2) * (y + R / 2))
      var dDown = Math.sqrt(x * x + (y - R / 2) * (y - R / 2))
      var dark = (x < 0 && dDown >= R / 2) || dUp < R / 2
      // The eyes: a light dot in the dark head, a dark dot in the light one.
      if (dUp < R / 6) dark = false
      if (dDown < R / 6) dark = true
      if (dark || d > R - ring) cells.push([col, row])
    }
  }
  return cells
}

if (typeof module !== "undefined") module.exports = { yinYangCells: yinYangCells }

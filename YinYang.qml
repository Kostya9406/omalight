import QtQuick
import "Icon.js" as Icon

// The OmaLight mark in the theme's colour. Cell edges are rounded to whole
// pixels so the steps stay crisp at any size, like the Omarchy logo.
Canvas {
  id: mark

  property color color: "white"
  property int grid: 16
  readonly property var cells: Icon.yinYangCells(grid)

  implicitWidth: 24
  implicitHeight: 24
  antialiasing: false

  onColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    var side = Math.min(width, height)
    var unit = side / mark.grid
    var left = (width - side) / 2
    var top = (height - side) / 2
    ctx.fillStyle = mark.color
    for (var i = 0; i < mark.cells.length; i++) {
      var c = mark.cells[i]
      var x0 = Math.round(left + c[0] * unit), x1 = Math.round(left + (c[0] + 1) * unit)
      var y0 = Math.round(top + c[1] * unit), y1 = Math.round(top + (c[1] + 1) * unit)
      ctx.fillRect(x0, y0, x1 - x0, y1 - y0)
    }
  }
}

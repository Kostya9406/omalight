// node tools/make-icon.js [color] > icon.svg — one path, one square per ink cell.
const { yinYangCells } = require("../Icon.js")
const color = process.argv[2] || "#7aa2f7"
const n = 16
const cells = yinYangCells(n)
const d = cells.map(([x, y]) => `M${x} ${y}h1v1h-1z`).join("")
process.stdout.write(
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-1 -1 ${n + 2} ${n + 2}" width="256" height="256" shape-rendering="crispEdges">` +
  `<path fill="${color}" d="${d}"/></svg>\n`)

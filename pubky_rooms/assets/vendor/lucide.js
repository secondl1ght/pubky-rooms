// Tailwind plugin exposing Lucide icons as `lucide-<name>` mask classes.
//
// The SVG files come from the `:lucide` mix dependency (sparse checkout of
// the icons directory). Each class paints the icon with `currentColor` via a
// CSS mask, so `<span class="lucide-house size-5 text-brand" />` renders a
// 20px lime house. Default size is 24px (Lucide's native grid); override with
// Tailwind's `size-*` utilities.
const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function ({matchComponents, theme}) {
  const iconsDir = path.join(__dirname, "../../deps/lucide/icons")
  const values = {}
  fs.readdirSync(iconsDir).forEach(file => {
    if (!file.endsWith(".svg")) return
    const name = path.basename(file, ".svg")
    values[name] = {name, fullPath: path.join(iconsDir, file)}
  })
  matchComponents(
    {
      lucide: ({name, fullPath}) => {
        let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "").replace(/\s{2,}/g, " ")
        content = encodeURIComponent(content)
        const size = theme("spacing.6")
        return {
          [`--lucide-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
          "-webkit-mask": `var(--lucide-${name})`,
          mask: `var(--lucide-${name})`,
          "mask-repeat": "no-repeat",
          "mask-size": "100% 100%",
          "background-color": "currentColor",
          "vertical-align": "middle",
          display: "inline-block",
          "flex-shrink": "0",
          width: size,
          height: size
        }
      }
    },
    {values}
  )
})

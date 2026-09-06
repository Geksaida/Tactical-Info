# AA Range

![screenshot](screenshot.png)

A widget that draws filled circles on the ground showing the engagement range of anti-air units. Enemy ranges are drawn in orange, allied ranges in blue.

Two render modes are available:

- **Overlap mode** (default) — additive blending, so overlapping circles brighten, giving a visual readout of AA coverage density.
- **Combine mode** — uses the stencil buffer to union overlapping circles. A pixel covered by one or ten circles renders at the same flat brightness, showing true coverage area instead of density. Requires stencil buffer support from the engine build.

Positions of previously sighted units are remembered, so ranges persist even after a unit has left — fading away once the spot is confirmed clear.

**Controls**

| Action | Key | Chat command |
|---|---|---|
| Toggle enemy AA ranges | `Ctrl+D` | `/aarange` |
| Toggle allied AA ranges | `Ctrl+Shift+D` | `/aaally` |
| Toggle combine mode | `Ctrl+Alt+D` | `/aacombine` |
| Clear remembered positions | — | `/aaclear` |

On-screen buttons are also available for mouse control.

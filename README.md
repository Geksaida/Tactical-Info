# AA Range PoC

A Spring-RTS widget that draws filled circles on the ground showing the engagement range of anti-air units. Enemy ranges are drawn in orange, allied ranges in blue. Overlapping circles brighten, giving a visual readout of AA coverage density.

Positions of previously sighted units are remembered and drawn for as long as the area remains visible, so ranges persist even after a unit has left — fading away once the spot is confirmed clear.

**Controls**

| Action | Key | Chat command |
|---|---|---|
| Toggle enemy AA ranges | `Ctrl+D` | `/aarange` |
| Toggle allied AA ranges | `Ctrl+Shift+D` | `/aaally` |
| Clear remembered positions | — | `/aaclear` |

On-screen buttons are also available for mouse control.

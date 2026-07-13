# Agent notes

## Workflow

- Commit and push to `origin/main` after each completed unit of work — don't
  batch a whole session into one push.
- Commit style: `scope: summary — detail` (see `git log`), lowercase scope
  matching the touched area (`README:`, `apps/kite:`, `talos:`, ...).

## Architecture diagram

The README embeds `docs/architecture.svg`, rendered from
`docs/architecture.excalidraw`. Source of truth is the Excalidraw+ scene
"CloudLab — Layer Model" (id `Amju5JWMGGU`), edited via the excalidraw MCP.

Regeneration pipeline after editing the scene:
1. `get_scene_content` → strip `isDeleted` elements, sort by `index`
2. Embed icon files as base64 `files` entries (icons come from
   homarr-labs/dashboard-icons, cncf/artwork, or GitHub org avatars;
   downscale PNGs to 128px with `sips`)
3. POST the JSON to `https://kroki.io/excalidraw/svg` → `docs/architecture.svg`
4. Verify with headless Chrome — note: images must sort *after* the band
   rectangles in z-order (fractional `index`) or they render hidden.

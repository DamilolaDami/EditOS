# EditOS — remaining work after scaffold

This document tracks gaps after the initial scaffold: structure, models, and view layout are in place; engine integration (composition rendering, exports) is wired but not yet feature-complete (see README).

Use it as a backlog for GitHub issues or Linear; split items into separate tickets when you start work.

---

## Engine & preview

- **`AVVideoComposition` / per-clip video transforms** — `CompositionBuilder` uses a single shared video track; per-clip transforms should move to an `AVVideoComposition` path.
- **Inspector transform vs preview** — Opacity, scale, and rotation sliders do not call `reloadComposition()`, so they may not affect what `AVPlayer` shows.
- **Composition build failures** — `reloadComposition()` swallows errors; preview can stay empty with no user-visible feedback.

---

## Export

- **`ExportEngine` is unused** — No menu command, save panel, or progress UI calls `ExportEngine.export(composition:settings:)`. End-to-end “render timeline to file” is not productized.

---

## Project persistence

- **Edits are not saved to `ProjectStore` after most actions** — `projectStore.update` is invoked after media import in `LibraryPanel` only. Timeline operations (trim, split, delete), inspector changes, and track toggles are not written back to disk consistently, so closing the editor can lose work.

---

## Home & navigation

- **Sidebar sections** (`Templates`, `Media`, `Design Studio`) change selection only; no distinct content per section.
- **Quick actions row** — Import media, Record screen, and Open template cards are stubbed (no actions wired).
- **Project management** — No rename, duplicate, or delete from the home grid; cards only open the editor.

---

## Editor UI gaps

- **Timeline** — Undo / Redo buttons are disabled (“coming soon”); no command stack.
- **Preview header** — Aspect-ratio and expand controls have empty button actions.
- **Tool rail** — Many `ToolCategory` values exist; the library panel is not meaningfully different per category beyond the header label.
- **Library** — Empty state mentions drag-and-drop; no drop target. Asset grid uses generic icons, not real previews (timeline filmstrips do use thumbnails).

---

## Product / repo housekeeping

- **License** — README lists license as TBD (MIT/Apache-2.0 suggested).
- **iCloud / sync** — Entitlements retained for future sync; not implemented.
- **Tests** — Unit and UI tests are minimal relative to editor complexity.

---

## Suggested priority order

1. Persist project changes from the editor (`ProjectStore.update` on meaningful mutations, debounced and/or on window close).
2. Wire **Export** from UI (`NSSavePanel` + progress and errors).
3. **Undo/redo** or document as out of scope until a command model exists.
4. **Video composition** path for transforms + inspector `reloadComposition` for visual parameters.
5. Home **quick actions** and sidebar **section** content; then polish (preview buttons, library drag-and-drop).

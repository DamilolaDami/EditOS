# Changelog

All notable changes to EditOS land here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); EditOS adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-05-16

First public release. EditOS arrives feature-complete for the
CapCut-style editing surface it set out to be.

### Editing

- Multi-track timeline with video, audio, captions, stickers, and
  filter lanes. Tracks can be added, deleted, locked, muted, hidden,
  and reordered.
- Clip operations: trim leading/trailing edges, split at the
  playhead, ripple delete, duplicate, copy / cut / paste, multi-select.
- **Drag-to-reorder with ripple insert** — drop a clip into a
  too-small gap between split halves and the trailing clips slide
  right to make room.
- Magnetic snap to clip edges, the playhead, and the timeline origin
  across every track, with a global on/off toggle.
- Undo / redo with snapshot coalescing so a continuous trim drag
  collapses to a single undo step.
- **Per-clip preferredTransform** applied in the CIFilter handler —
  portrait, landscape, and rotated sources all render correctly from
  one shared video track.

### Speed & motion

- **Speed ramping** via `SpeedKeyframe`s with linear interpolation.
  Eight one-tap presets: linear ramp up/down, slow-mo middle,
  fast→slow, slow→fast, freeze first/last second, jump cut.
- **Fade in / fade out** per video clip with adjustable duration.
- **Cross-clip transitions** (V1) — None / Crossfade / Dip-to-Black /
  Dip-to-White, with a duration slider clamped to half the shorter
  neighbouring clip.

### Filters & effects

- Curated **filter library** (vibrance, noir, sepia, chrome, fade,
  process, transfer, …) with live previews built from each project's
  first video poster frame.
- Filters can live on their own track, time-bounded — they only affect
  the underlying video while the filter clip plays.
- Per-clip intensity slider.

### Overlays

- **Text overlays** with size, color, foreground, and live drag /
  resize directly on the preview canvas.
- **SF Symbol stickers** and **animated GIPHY stickers**, the latter
  driven by `NSImageView` in preview and per-frame `CGImageSource`
  extraction (with GIF delay metadata) at export.
- Composition padding so overlays placed after the last A/V clip
  still play — AVPlayer's clock keeps ticking past the last media
  frame.

### Audio

- Volume + mute per clip, per track.
- **Voiceover recording** via `AVAudioRecorder` with live input-level
  metering. Recordings drop on the audio track at the playhead.
- **Audio ducking** — non-voiceover audio dims to 25% during voiceover
  ranges via `setVolumeRamp` with 0.25s edges.
- **Auto-captions** via `SFSpeechRecognizer` — phrases land on the
  caption track as text overlays.
- Waveform preview on every audio clip.

### Media library

- Drag-and-drop import of video, audio, and image files.
- **GIPHY** integration for stickers.
- **Freesound** integration for sound effects.
- Security-scoped bookmarks mean media references survive relaunches
  under the sandbox without making copies of the source files.

### Home & projects

- Project browser with **search + sort** (Recently Edited / Name) and
  a cover-image picker per project.
- **iCloud / CloudKit sync** of project files via SwiftData. Media
  itself stays on the originating Mac.
- **CloudKit status badge** that opens an explainer sheet showing
  account state and offering a one-tap recheck.
- Hover scrubbing on project cards.
- **Timeline markers** with rename / colour palette / drag-to-retime.
  Bound to `M` (add at playhead), `⌘⌥←` / `⌘⌥→` (jump between
  markers).
- Markers bake into the exported MP4/MOV as title metadata + a
  YouTube/podcast-style `<basename>.chapters.txt` sidecar.

### Export

- Quality presets — **480p / 720p / 1080p / 4K**.
- Codecs / containers — **MP4 (H.264)**, **MP4 (H.265 / HEVC)**, **MOV**.
- Frame rate — Match source, 24, 30, or 60 fps; applied by mutating
  the video composition's `frameDuration`.
- Audio toggle, "Open when finished" checkbox, persisted destination
  via security-scoped bookmarks.
- Smoothed progress with **ETA**, elapsed time, and **estimated file
  size**; renders run on the GPU via `AVAssetExportSession`.
- Post-export actions: Copy Path, Reveal in Finder, Open.

### Distribution

- Notarized with Apple. Hardened runtime, Developer ID signed.
- Sandboxed, with explicit microphone and speech-recognition
  permissions and matching usage descriptions.
- Reproducible `scripts/release.sh` pipeline: archive → export →
  notarize → staple → DMG, with pre-flight checks for the cert,
  notary profile, and dev-only `Secrets.plist`.

### Quality

- Three unit-test bundles (`TimelineTests`, `EditorViewModelTests`,
  `CompositionBuilderTests`) covering the timeline-math invariants,
  view-model operations (ripple insert, split, undo/redo, copy /
  paste / delete), and composition pipeline corner cases. Uses a
  `NullAssetResolver` so tests don't need media fixtures.

### Known follow-ups

- **True pixel-blended crossfade** ([#1](https://github.com/DamilolaDami/EditOS/issues/1))
  — V1 ships a dip-through-colour blend via the existing fade
  pipeline; a future PR will swap in a custom `AVVideoCompositing`
  implementation so two overlapping clip frames sample directly.
- **Keyframe animation** ([#2](https://github.com/DamilolaDami/EditOS/issues/2)),
  **manual colour grading** ([#4](https://github.com/DamilolaDami/EditOS/issues/4)),
  **proxy media for 4K editing** ([#7](https://github.com/DamilolaDami/EditOS/issues/7)),
  **localisation** ([#8](https://github.com/DamilolaDami/EditOS/issues/8)),
  and an **accessibility audit** ([#10](https://github.com/DamilolaDami/EditOS/issues/10))
  remain open for contributors.

# EditOS

An open-source, CapCut-style video editor for macOS — built with SwiftUI,
AVFoundation, SwiftData, and modern Swift concurrency.

![Status](https://img.shields.io/badge/status-active-brightgreen)
![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)
![Swift](https://img.shields.io/badge/swift-6-orange)

## What you can do today

EditOS is well past scaffold territory — it's a working video editor with
the core CapCut feature set in place.

### Editing
- **Multi-track timeline** with video, audio, captions, stickers, and
  filter lanes; tracks can be added, deleted, locked, muted, hidden, and
  reordered.
- **Clip operations**: trim leading/trailing, split at the playhead,
  ripple delete, duplicate, copy/paste/cut, multi-select.
- **Drag-to-reorder with ripple insert** — drop a clip into a too-small
  gap between split halves and the trailing clips slide right to fit.
- **Magnetic snap** to clip edges, the playhead, and the timeline origin
  across every track, with a global toggle.
- **Undo / redo** via JSON snapshots with coalesced drag windows so a
  continuous trim is a single undo step.
- **Per-clip preferredTransform** applied in the CIFilter handler, so
  mixed portrait/landscape sources all orient correctly from one shared
  video track.

### Speed & motion
- **Speed ramping** — piecewise multipliers across a clip via
  `SpeedKeyframe`s, with one-tap presets (ramp up/down, slow-mo middle,
  freeze first/last second, jump cut). Ripple-pushes following clips
  when the effective duration changes.
- **Fade in / fade out** per video clip with adjustable duration.

### Filters & effects
- Curated **filter library** (vibrance, noir, sepia, chrome, fade,
  process, transfer, …) with live previews built from each project's
  first video poster frame.
- Filters can live **on their own track**, time-bounded — they only
  affect the underlying video while the filter clip plays.
- **Intensity slider** on every filter clip.

### Overlays
- **Text overlays** with size, color, foreground, and live drag/resize
  in the preview canvas.
- **SF Symbol stickers** and **GIPHY animated stickers**, the latter
  driven by `NSImageView` in preview and per-frame `CGImageSource`
  extraction (with GIF delay metadata) at export.
- **Composition padding** so overlays placed after the last A/V clip
  still play — AVPlayer's clock keeps ticking past the last media frame.

### Audio
- **Volume + mute** per clip, per track.
- **Voiceover recording** via `AVAudioRecorder` with input-level
  metering; recordings land on the audio track at the playhead.
- **Audio ducking** — non-voiceover audio dims to 25% during voiceover
  ranges via `setVolumeRamp`, with a 0.25 s ramp at each edge.
- **Auto-captions** via `SFSpeechRecognizer` — phrases are dropped on
  the caption track as text overlays.
- **Waveform preview** on every audio clip.

### Media library
- Drag-and-drop import of video, audio, and image files.
- **GIPHY** integration for stickers (requires API key — see Setup).
- **Freesound** integration for sound effects (requires API token).
- **Security-scoped bookmarks** mean media references survive relaunches
  under the sandbox without making copies.

### Home & projects
- Project browser with **search + sort** (recently edited / name) and a
  cover-image picker.
- **iCloud / CloudKit sync** of project files via SwiftData (media
  itself stays on the originating Mac).
- **CloudKit status badge** that opens an explainer sheet showing
  account state and offering a one-tap recheck.
- **Hover scrubbing** on project cards.

### Export
- **Quality presets** — 480p / 720p / 1080p / 4K.
- **Codecs / containers** — MP4 (H.264), MP4 (H.265 / HEVC), MOV.
- **Frame rate** — match source, 24, 30, or 60 fps; applied by mutating
  the video composition's `frameDuration`.
- **Audio toggle**, **open-on-finish** option, **persisted destination**
  via security-scoped bookmarks.
- Smoothed progress with **ETA**, elapsed time, and **estimated file
  size**; renders run on the GPU via `AVAssetExportSession`.
- Post-export actions: Copy Path, Reveal in Finder, Open.

## Requirements

- macOS 26.2 (Tahoe) or later
- Xcode 26.2 or later
- Swift 6, `SWIFT_APPROACHABLE_CONCURRENCY = YES`,
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

## Setup

```bash
git clone https://github.com/DamilolaDami/EditOS.git
cd EditOS
open EditOS.xcodeproj
```

Then ⌘R in Xcode. The app will request microphone and speech-recognition
permissions on first use — both are optional unless you use the
voiceover or auto-caption features.

### API keys (optional but recommended)

EditOS reads third-party credentials from a gitignored
`EditOS/Resources/Secrets.plist`. Both integrations are optional — the
app builds and runs without keys, the corresponding panels just gray
out.

1. Copy the template:
   ```bash
   cp EditOS/Resources/Secrets.example.plist EditOS/Resources/Secrets.plist
   ```
2. Drop the file onto the EditOS target in Xcode (File → Add Files…)
   so it's bundled. The default project uses a synchronized file
   group, so it should pick it up automatically.
3. Fill in your keys:
   - **GIPHY** (animated stickers) — free key at
     [developers.giphy.com](https://developers.giphy.com/).
   - **Freesound** (sound effects) — free OAuth at
     [freesound.org/apiv2/apply](https://freesound.org/apiv2/apply/).

`Secrets.plist` is gitignored, so each contributor manages their own
keys. The example file is checked in for reference.

### iCloud sync

Sync is automatic once you sign into iCloud on your Mac. The CloudKit
container is `iCloud.com.damioffice.EditOS` — change it in
`EditOSApp.swift` if you want your own. Project files sync; source
media (videos, audio, images) stay on the Mac that imported them.

## Tests

```bash
xcodebuild test -project EditOS.xcodeproj -scheme EditOS -destination 'platform=macOS'
```

Three test bundles:

- `TimelineTests` — `TimeRange` / `Timeline` math, including the
  overlay-past-video duration regression.
- `EditorViewModelTests` — `moveClip` ripple insert, `splitClipAtPlayhead`,
  filter apply/clear/intensity, undo/redo round-trip, copy/paste, delete,
  selection. Uses a `NullAssetResolver` so no media fixtures needed.
- `CompositionBuilderTests` — empty-project handling, failed-resolve
  graceful fallback, `tunedComposition` re-wrapping invariant.

## Architecture

- **SwiftUI-first** with `NSViewRepresentable` only where AppKit gives
  us something SwiftUI doesn't (`AVPlayerView`, animated `NSImageView`).
- **`@Observable` macro** for view models — no `ObservableObject`,
  `@Published`, or `Combine` plumbing in app code.
- **`@MainActor` by default**; engines/exporters live in `actor`s or
  Sendable structs so heavy work runs off the main thread.
- **Single shared video track** in the composition with per-clip
  `preferredTransform` applied in the CIFilter handler. (The original
  approach of per-asset tracks broke `applyingCIFiltersWithHandler`
  which only reads from a single video track.)
- **Sandboxed file access** via security-scoped bookmarks
  (`BookmarkAssetResolver`). Media is referenced, not copied.
- **Projects persist via SwiftData** with CloudKit private-database
  sync. The on-disk representation is a `ProjectRecord` wrapping a
  Codable `Project` blob — keeps the model strongly typed without
  fighting SwiftData's `@Model` macro for every nested struct.

## Project layout

```
EditOS/
├── App/                       # @main entrypoint, AppEnvironment, AppCommands
├── Core/
│   ├── Models/                # Project, Timeline, Track, Clip, MediaAsset,
│   │                          # TimeRange, ClipTransform, SpeedKeyframe,
│   │                          # SpeedRampPreset — Codable, Sendable
│   ├── Engine/                # CompositionBuilder, ExportEngine,
│   │                          # PlaybackEngine, ThumbnailGenerator,
│   │                          # WaveformGenerator, VoiceoverRecorder,
│   │                          # CaptionTranscriber
│   └── Services/              # ProjectStore (SwiftData), ProjectRecord,
│                              # MediaImporter, BookmarkAssetResolver,
│                              # GiphyService, FreesoundService,
│                              # CloudKitSyncMonitor, APIKeys
├── Features/
│   ├── Home/                  # Sidebar, project grid, search/sort,
│   │                          # Templates, Media, Design Studio,
│   │                          # CloudKit sync badge + detail sheet
│   ├── Onboarding/            # First-run permissions walkthrough
│   └── Editor/
│       ├── Toolbar/           # Top bar + tool rail
│       ├── Library/           # Media / Audio / Text / Sticker / Filter panels
│       ├── Preview/           # AVPlayer-backed preview, overlay canvas,
│       │                      # transport, voiceover button
│       ├── Inspector/         # Per-kind clip inspector + speed-ramp curve
│       ├── Timeline/          # Ruler, tracks, clips, playhead, magnet snap
│       └── Export/            # Multi-format export sheet
├── UI/
│   ├── Theme/                 # Design tokens via @Environment(\.theme)
│   └── Components/            # Panel, IconButton, AnimatedImage, …
├── Assets.xcassets
├── Info.plist
└── EditOS.entitlements
```

## Build settings worth knowing

| Setting | Value |
| --- | --- |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` |
| `ENABLE_APP_SANDBOX` | `YES` |
| `ENABLE_HARDENED_RUNTIME` | `YES` |
| `ENABLE_OUTGOING_NETWORK_CONNECTIONS` | `YES` (GIPHY / Freesound) |
| `ENABLE_FILE_ACCESS_MOVIES_FOLDER` | `readwrite` (default export folder) |
| `ENABLE_USER_SELECTED_FILES` | `readwrite` (custom export destinations) |
| `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT` | `YES` (voiceover) |
| `INFOPLIST_KEY_NSMicrophoneUsageDescription` | (set) |
| `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` | (set) |

## Contributing

The fastest way in: pick a [good first issue](https://github.com/DamilolaDami/EditOS/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22).
Each open issue includes a scoped acceptance-criteria list and file
pointers.

Notable open issues:

- [#1](https://github.com/DamilolaDami/EditOS/issues/1) — Crossfade transitions between adjacent video clips
- [#2](https://github.com/DamilolaDami/EditOS/issues/2) — Keyframe animation for clip transform
- [#4](https://github.com/DamilolaDami/EditOS/issues/4) — Manual color grading panel (wheels, curves, HSL)
- [#5](https://github.com/DamilolaDami/EditOS/issues/5) — Social-media export presets (Reels/Shorts/TikTok)
- [#6](https://github.com/DamilolaDami/EditOS/issues/6) — Timeline markers & chapters
- [#7](https://github.com/DamilolaDami/EditOS/issues/7) — Proxy media generation for 4K clips
- [#8](https://github.com/DamilolaDami/EditOS/issues/8) — Localization scaffold
- [#10](https://github.com/DamilolaDami/EditOS/issues/10) — Accessibility audit

PR conventions:

- One feature per PR. Test the golden path + at least one edge case in
  the browser before opening.
- Tests welcome but not gated — pure-model changes that affect
  `TimelineTests` / `EditorViewModelTests` should ship with new coverage.
- No co-authoring trailers needed.

## License

TBD. MIT or Apache-2.0 recommended.

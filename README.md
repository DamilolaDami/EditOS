# EditOS

An open-source, CapCut-style video editor for macOS — built with SwiftUI,
AVFoundation, and modern Swift concurrency.

> Status: project scaffold. The structure, models, and view layout are in
> place; engine integration (composition rendering, exports) is wired but
> not yet feature-complete.

## Requirements

- macOS 26.2 (Tahoe) or later
- Xcode 26.2 or later
- Swift 5+, builds with `SWIFT_APPROACHABLE_CONCURRENCY` and
  `MainActor`-default isolation

## Project layout

```
EditOS/
├── App/                  # @main entrypoint, scene config, commands
├── Core/
│   ├── Models/           # Project, Timeline, Track, Clip, MediaAsset — Codable, Sendable
│   ├── Engine/           # PlaybackEngine, CompositionBuilder, ExportEngine, ThumbnailGenerator
│   └── Services/         # ProjectStore, MediaImporter, BookmarkAssetResolver
├── Features/
│   ├── Home/             # Project browser (sidebar + grid)
│   └── Editor/
│       ├── Toolbar/      # Left tool rail (Media/Audio/Text/Effects/…)
│       ├── Library/      # Media library panel
│       ├── Preview/      # AVPlayer-backed preview + transport controls
│       ├── Inspector/    # Right-side details panel
│       └── Timeline/     # Ruler, tracks, clips, playhead
├── UI/
│   ├── Theme/            # Design tokens, accessed via @Environment(\.theme)
│   └── Components/       # Panel, IconButton, …
├── Assets.xcassets
├── Info.plist
└── EditOS.entitlements
```

## Architectural choices

- **SwiftUI-first** with `NSViewRepresentable` only where AppKit gives us
  something SwiftUI doesn't (`AVPlayerView`).
- **`@Observable` macro** for view models — no `ObservableObject`,
  `@Published`, or `Combine` glue in app code.
- **`@MainActor` by default** (set in build settings); engines/exporters
  live in `actor`s so heavy work doesn't pin the UI.
- **Sandboxed file access** via security-scoped bookmarks
  (`BookmarkAssetResolver`). Media is referenced, not copied.
- **Projects persist as JSON** in Application Support. Easy to diff, easy
  to migrate, no SwiftData lock-in.
- **iCloud / CloudKit entitlements** are retained so projects can later
  sync across devices.

## Build settings worth knowing

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `ENABLE_USER_SELECTED_FILES = readwrite` (needed for export targets)
- `ENABLE_APP_SANDBOX = YES`

## License

TBD — pick a license (MIT/Apache-2.0 recommended for open source).

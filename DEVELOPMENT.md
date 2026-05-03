

### Bumping the App Version

Two files must be updated together when bumping the version:

1. **`pubspec.yaml`** — the `version:` field (e.g., `version: 8.0.4+1`)
2. **`lib/app_version.dart`** — the `_version` fallback string (e.g., `'8.0.4+1'`)

Both must match. `pubspec.yaml` is what Flutter/fastforge reads at build time. `app_version.dart` is the runtime fallback if `PackageInfo` fails.

```bash
# Example: bump from 8.6.0 to 8.6.1
sed -i 's/version: 8.6.0+1/version: 8.6.1+1/' pubspec.yaml
sed -i "s/8.6.0+1/8.6.1+1/" lib/app_version.dart
```

Don't forget to also bump `AppImageBuilder.yml` (`version:` under `app_info`) and the filename in the AppImage build command below.

### Run in Debug Mode
```bash
flutter run -d linux --debug
```

### Build Release
```bash
flutter build linux --release
```

### Build AppImage (Linux)

Requires `appimagetool` at the repo root (download from https://github.com/AppImage/appimagetool).

```bash
flutter build linux --release && \
rm -rf AppDir && \
mkdir -p AppDir/usr/bin && \
cp -r build/linux/x64/release/bundle/* AppDir/usr/bin/ && \
cp linux/nautune.desktop AppDir/ && \
cp linux/nautune.png AppDir/ && \
cd AppDir && ln -s usr/bin/nautune AppRun && cd .. && \
mkdir -p dist && \
ARCH=x86_64 ./appimagetool AppDir dist/Nautune-x86_64-8.6.0.AppImage
```

### Build Deb Package (Linux)
```bash
# Requires: dart pub global activate fastforge
fastforge package --platform linux --targets deb
```

### Static Analysis
```bash
flutter analyze
```

### Troubleshooting

**`Gdk-CRITICAL: gdk_device_get_source: assertion 'GDK_IS_DEVICE (device)' failed`**

Occasionally emitted during playback on Linux. This is GTK/Flutter embedder
log noise (fires when an input device hot-(un)plugs or a window-manager
event races). It is **not** a Nautune bug, not a crash, and not actionable
from Dart code. Safe to ignore.

**`Lost connection to device.` at the end of `flutter run`**

That's the expected output when you `Ctrl+C` or `q` out of a Flutter debug
session. Not a crash.

### Desktop Shortcut with TUI Option (KDE/GNOME)

Add a right-click menu option to launch TUI mode from your desktop shortcut.

Edit your `.desktop` file (e.g., `~/.local/share/applications/nautune.desktop`):

```ini
[Desktop Entry]
Actions=tui;
Comment=
Exec=/path/to/Nautune-x86_64.AppImage
GenericName=Jellyfin Music Player
Icon=/path/to/icon.png
Name=Nautune
NoDisplay=false
StartupNotify=true
Terminal=false
Type=Application

[Desktop Action tui]
Exec=/path/to/Nautune-x86_64.AppImage --tui
Icon=/path/to/icon.png
Name=Launch TUI Mode
```

Now you can:
- **Left-click** → Launch normal GUI
- **Right-click** → Choose "Launch TUI Mode"

### Requirements

- Linux only (TUI mode is not available on iOS/macOS/Windows)
- Must be logged in via GUI mode first (session persists)

---



## 🖥️ TUI Mode (Linux)

<img src="screenshots/tui.png" width="600" alt="Nautune TUI Mode">

A terminal-inspired interface for keyboard-driven music browsing, inspired by [jellyfin-tui](https://github.com/dhonus/jellyfin-tui) with spectrum visualizer and command palette inspired by [cliamp](https://github.com/bjarneo/cliamp).

### TUI Architecture

```
lib/tui/
├── tui_app.dart                    # Entry point, login check
├── tui_keybindings.dart            # Vim-style key parser (54 actions)
├── tui_theme.dart                  # 10 themes + manager + color extraction
├── tui_metrics.dart                # Character-based sizing
├── layout/
│   ├── tui_shell.dart              # Main layout, focus, key dispatch
│   ├── tui_sidebar.dart            # Left nav (Albums, Artists, Queue, Lyrics, Search)
│   ├── tui_content_pane.dart       # Main content area
│   ├── tui_status_bar.dart         # Bottom bar: visualizer + now playing + hints
│   ├── tui_tab_bar.dart            # Top section tabs
│   └── tui_lyrics_pane.dart        # Lyrics display
└── widgets/
    ├── tui_spectrum_visualizer.dart # ASCII spectrum analyzer (PulseAudio FFT)
    ├── tui_command_palette.dart     # Fuzzy-searchable command overlay (Ctrl+K)
    ├── tui_piano_overlay.dart       # ASCII piano keyboard overlay (P)
    ├── tui_help_overlay.dart        # Static keybinding reference (?)
    ├── tui_progress_bar.dart        # ASCII progress + volume bars
    ├── tui_box.dart                 # Box-drawing borders
    ├── tui_list.dart                # Scrollable list with cursor
    └── tui_text.dart                # Monospace text
```

### Key TUI Widgets

- **TuiSpectrumVisualizer**: Subscribes to `PulseAudioFFTService.fftStream` (or falls back to metadata-driven bands). Renders 32 bars × 2 rows using `▁▂▃▄▅▆▇█` characters with peak tracking and gravity decay. Toggle with `v`.
- **TuiCommandPalette**: 34 commands with fuzzy matching on name/description/category/shortcut. Sorted by match quality. `Ctrl+K` to open, arrow keys to navigate, Enter to execute.
- **MPRIS**: Automatic via `audio_service` — system media keys, GNOME/KDE widgets, KDE Connect all work out of the box on Linux.

### Launching TUI Mode

#### AppImage
```bash
./Nautune-x86_64.AppImage --tui
```

#### Deb Package
```bash
nautune --tui
```

#### Environment Variable (Alternative)
```bash
NAUTUNE_TUI_MODE=1 nautune
```

#### Development
```bash
flutter run -d linux --dart-define=TUI_MODE=true
```

## 🛠 Technical Foundation
- **Framework**: Flutter (Dart)
- **Local Storage**: Hive (NoSQL) for high-speed metadata caching, serialized via chained futures
- **Audio Engine**: Audioplayers with custom platform-specific optimizations, crossfade via player swapping
- **HTTP**: RobustHttpClient with retry, ETag cache (O(1) LRU eviction via LinkedHashSet)
- **Equalizer**: PulseAudio LADSPA (Linux only)
- **FFT Processing**: Custom Cooley-Tukey (Linux), Apple Accelerate vDSP (iOS)
- **Image Processing**: Material Color Utilities for vibrant palette generation, shared PaletteCacheService singleton across all screens

## 🧭 Library Data Flow

`LibraryDataProvider` is the source of truth for albums, artists, playlists, and friends. `NautuneAppState` exposes the same getters for screen code, but they delegate to the provider when present (`appState.albums => _libraryDataProvider?.albums ?? _albums`). All sort mutations flow through `LibraryDataProvider.setAlbumSort` / `setArtistSort`, which update the provider's sort state and re-fetch via `JellyfinService.loadAlbums` / `loadArtists` with the user's sort. Stale fetches are discarded via monotonic `_albumsLoadId` / `_artistsLoadId` so a slow request can't overwrite a newer one. Alphabetical headers and the alphabet scrollbar group items by `JellyfinAlbum.groupingName` / `JellyfinArtist.groupingName` (which prefer the server's `SortName`) so the visible sections match the server's sort key — articles ("The …") fall under their first letter, not the article's letter.

`OfflineRepository` honors `SortOption.year` for albums (via `productionYear`) and falls back to `groupingName` for keys that have no offline equivalent (DateAdded, PlayCount). The album/artist sort menu hides those two options when `appState.isOfflineMode` so the UI can't promise a sort it won't deliver.

## 🔁 Playlist Sync Queue

`PlaylistSyncQueue` wraps a Hive box of `PendingPlaylistAction` records. Each action carries a stable UUID (`id` field), so removal matches by `id` rather than `(type, timestamp)` — two adds enqueued in the same millisecond can no longer collapse into one removal. `add` / `remove` / `clear` are serialized behind a `Future`-chain mutex so a UI-driven enqueue can't lose its entry to a concurrent dequeue running in `_syncPendingPlaylistActions`.

## 📥 DownloadService Caching

`DownloadService.downloads`, `completedDownloads`, and `activeDownloads` are cached and invalidated on every `notifyListeners()` call. The offline repository previously hit `completedDownloads` ~9× per library refresh, allocating a fresh filtered list each time; the cache makes these getters O(1) after the first call within a notify cycle.

## 🚗 CarPlay (iOS)

CarPlay is owned end-to-end by the `flutter_carplay` package — `Info.plist` declares `flutter_carplay.FlutterCarPlaySceneDelegate` as the scene delegate, and `lib/services/carplay_service.dart` builds the templates. `CPListItem` artwork uses `JellyfinService.buildSelfContainedImageUrl` (token embedded as `api_key` query param) so the system image loader can fetch without our auth headers. Tapping a track plays it via `AudioPlayerService` and then navigates to the shared `CPNowPlayingTemplate` via `FlutterCarplay.showSharedNowPlaying`. Lock-screen and now-playing artwork is plumbed through `audio_service` via `MediaItem.artUri` set in `AudioHandler.updateNautuneMediaItem`, not through CarPlay-specific code.

`CPSearchTemplate` is not exposed by `flutter_carplay 1.3.1`, so search is replaced by a "Browse A–Z" entry on the Library tab that drills into letter-bucket lists.

## 📂 File Structure (Linux)
Nautune follows a clean data structure on Linux for easy backups and management:
- `~/Documents/nautune/`: Primary application data
- `~/Documents/nautune/downloads/`: High-quality offline audio files
- `~/Documents/nautune/downloads/artwork/`: Cached album artwork (stored per-album to save space)
- `~/Documents/nautune/network/audio/`: Network easter egg offline channels
- `~/Documents/nautune/network/images/`: Network channel artwork
- `~/Documents/nautune/charts/`: Frets on Fire cached chart data
- `~/Documents/nautune/legendary/`: Through the Fire and Flames track and unlock state
- `~/Documents/nautune/essential/audio/`: Essential Mix offline audio
- `~/Documents/nautune/waveforms/`: Extracted waveform data for visualization

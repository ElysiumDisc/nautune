# Nautune 🎵🌊

Poseidon's cross-platform Jellyfin music player. Nautune is built with Flutter and delivers a beautiful deep-sea themed experience with smooth native audio playback, animated waveform visualization, and seamless Jellyfin integration.

## ✨ Highlights

### 🎵 Audio & Playback
- **Native Audio Engine**: Powered by `just_audio` with `audio_session` for hardware-optimized playback on Linux & iOS
- **Smooth Performance**: Hardware-accelerated audio with real-time streaming from Jellyfin
- **Position Persistence**: Automatically saves and restores playback position across app restarts
- **Queue Management**: Full album playback with next/previous track navigation
- **Background Audio**: Continues playing when app is minimized (via `audio_service`)

### 🌊 Visual Experience
- **Sonic Wave Visualization**: 60 animated waveform bars that pulse with your music in real-time
- **Now Playing Bar**: Always-visible mini-player with live progress tracking and controls
- **Deep Sea Purple Theme**: Oceanic gradient color scheme defined in `lib/theme/` and applied consistently
- **Album Art Display**: Beautiful grid and list layouts with Jellyfin artwork (trident placeholder fallback)

### 📚 Library Browsing
- **Tabbed Interface**: Browse by Albums, Artists, Favorites, and Playlists with smooth navigation
- **Infinite Scroll**: Ready for pagination support as you scroll through large collections
- **Multi-Library Support**: Connect to and switch between multiple Jellyfin audio libraries
- **Smart Refresh**: Pull-to-refresh on all tabs for latest content sync

### 🎯 Jellyfin Integration
- **Direct Streaming**: Streams music directly from your Jellyfin server with adaptive quality
- **Album Browsing**: View all albums with high-quality artwork and metadata
- **Playlist Support**: Access and play your Jellyfin playlists
- **Recent Tracks**: Quick access to recently played and added music
- **Persistent Sessions**: Login once, stay connected across app launches

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (3.0+, stable channel, Dart SDK 3.9)
- A running Jellyfin server
- Linux (primary platform) or iOS

### Installation

1. **Clone the repository** (SSH recommended):
```bash
git clone git@github.com:ElysiumDisc/nautune.git
cd nautune
```

2. **Install dependencies**:
```bash
flutter pub get
```

3. **Run the app**:
```bash
flutter run -d linux
```

### First Launch
1. Enter your Jellyfin server URL (e.g., `http://192.168.1.100:8096`)
2. Enter your username and password
3. Select a music library from the available options
4. Browse albums, tap one to see tracks
5. Tap a track to start playback with waveform visualization!

## 📦 Tech Stack

```yaml
# Core Audio
just_audio: ^0.9.40        # Audio playback engine with streaming support
audio_session: ^0.1.21     # Platform-specific audio optimization (Linux/iOS)
audio_service: ^0.18.15    # Background audio and media controls

# Data & State
shared_preferences: ^2.3.2 # Persistent storage for sessions and playback state
http: ^1.2.2               # Jellyfin API communication

# Future Features
flutter_fft: ^1.0.0        # FFT audio analysis (real-time visualizations)
```

## 🏗️ Architecture

```
lib/
├── jellyfin/              # Jellyfin API client, models, session management
│   ├── jellyfin_client.dart
│   ├── jellyfin_service.dart
│   ├── jellyfin_session.dart
│   ├── jellyfin_album.dart
│   └── jellyfin_track.dart
├── models/                # App data models
│   └── playback_state.dart
├── screens/               # UI screens
│   ├── login_screen.dart
│   ├── library_screen.dart (with tabs!)
│   └── album_detail_screen.dart
├── services/              # Business logic layer
│   ├── audio_player_service.dart
│   └── playback_state_store.dart
├── widgets/               # Reusable components
│   └── now_playing_bar.dart (with waveform!)
├── theme/                 # Deep Sea Purple theme
│   └── nautune_theme.dart
├── app_state.dart         # Central state management (ChangeNotifier)
└── main.dart              # App entry point
```

## 🎨 Key Components

### Now Playing Bar (`lib/widgets/now_playing_bar.dart`)
- **Animated Waveform**: 60 bars with sine wave animation at 1.5s intervals
- **Real-time Progress**: Live position tracking with gradient progress bar
- **Mini Controls**: Play/Pause/Skip buttons always accessible
- **Tap to Expand**: (Future: full player screen)

### Library Screen (`lib/screens/library_screen.dart`)
- **Albums Tab**: Grid view with infinite scroll support, album artwork
- **Artists Tab**: Placeholder (coming soon!)
- **Favorites Tab**: Recent and favorited tracks in a list
- **Playlists Tab**: Your Jellyfin playlists with track counts
- **Header**: Library switcher and user info

### Audio Player Service (`lib/services/audio_player_service.dart`)
- Manages entire playback lifecycle
- Handles queue, seeking, and track navigation
- Auto-saves position every second during playback
- Restores queue and position on app restart
- Configures native audio session for optimal performance

### Playback State Persistence
- Saves: current track, position, queue, album context
- Stored in `SharedPreferences` as JSON
- Restores automatically on app launch
- Survives app restarts and force-closes

## 🔧 Development

### Run in Debug Mode
```bash
flutter run -d linux --debug
```

### Build Release
```bash
flutter build linux --release
```

### Static Analysis
```bash
flutter analyze
```

### Format Code
```bash
flutter format lib/
```

### Run Tests
```bash
flutter test
```

## 🌐 Building for Other Platforms

- **iOS**: Builds produced by Codemagic CI. CarPlay plugin support planned under `plugins/`
- **Windows**: `flutter build windows` (requires Windows machine with VS 2022)
- **macOS**: `flutter build macos` (requires macOS with Xcode)
- **Web**: `flutter run -d chrome` for dev, `flutter build web` for production
- **Android**: Not currently a focus; no Android SDK required for development

> **Development Tip**: Keep your Linux environment Snap-free. Use official Flutter tarball or FVM. Codemagic handles iOS builds.

## 🗺️ Roadmap

### ✅ Completed
- [x] Jellyfin authentication and session persistence
- [x] Library filtering and selection
- [x] Album browsing with artwork
- [x] Playlists and recently added tracks
- [x] Album detail view with track listings
- [x] **Audio playback with native engine**
- [x] **Persistent playback state (position, queue, track)**
- [x] **Animated waveform visualization**
- [x] **Tabbed navigation (Albums/Artists/Favorites/Playlists)**
- [x] **Now playing bar with controls**

### 🚧 In Progress / Planned
- [ ] Full player screen with album art and lyrics
- [ ] Artists view with discography
- [ ] Search functionality across library
- [ ] Download tracks for offline playback
- [ ] Equalizer and audio settings
- [ ] Real-time FFT audio visualization
- [ ] Gapless playback between tracks
- [ ] Media controls on lock screen
- [ ] Swift CarPlay plugin integration
- [ ] Cross-platform stability (Windows, macOS, Android)

## 🐛 Known Issues

- Artists tab is a placeholder (UI exists, data fetching pending)
- Infinite scrolling needs backend pagination support
- iOS build untested (Codemagic config pending)
- Album detail screen uses simplified header (full now playing screen planned)

## 📝 Development Guidelines

1. **Follow Flutter/Dart lints**: Enforced by `analysis_options.yaml`. Run `flutter analyze` before committing.
2. **Write tests**: Add unit/widget tests for new features. Run `flutter test`.
3. **Keep UI declarative**: Centralize styling in `lib/theme/nautune_theme.dart`.
4. **Jellyfin integration**: Keep all API logic in `lib/jellyfin/`. Expose state via `NautuneAppState`.
5. **Graceful error states**: Show loading spinners, error messages, and retry buttons.
6. **Document complex flows**: Add inline comments for non-obvious logic.
7. **Commit frequently**: Use descriptive commit messages. Sync via SSH.

## 🤝 Contributing & Collaboration

1. **Feature branches**: Work on branches, open PRs against `main` with screenshots/demos
2. **Coordinate platform changes**: Discuss desktop shortcuts, CarPlay hooks early
3. **Code reviews**: All PRs require review before merge
4. **Testing**: Ensure builds pass on Linux before pushing
5. **Codemagic**: Note iOS build considerations in PR descriptions

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [Jellyfin](https://jellyfin.org/) - Amazing open-source media server
- [just_audio](https://pub.dev/packages/just_audio) - Powerful audio playback engine
- [audio_session](https://pub.dev/packages/audio_session) - Native audio optimization
- Flutter team - Incredible cross-platform framework

## 💬 Support & Community

- 🐛 **Bug reports**: Open an issue with steps to reproduce
- ✨ **Feature requests**: Describe your idea in an issue
- ⭐ **Star the repo**: If you like Nautune, show your support!
- 🔔 **Follow for updates**: Watch the repo for new releases

---

**Made with 💜 by ElysiumDisc** | Dive deep into your music 🌊🎵

## Highlights
- Deep Sea Purple experience defined in `lib/theme/nautune_theme.dart` and shared across every platform target.
- Linux-first development flow (Lubuntu/Kubuntu) with Codemagic handling iOS builds — no Snap or Android toolchain required to get started.
- Planned Swift CarPlay plugin housed under `plugins/` for tight integration with Jellyfin playback.
- Cross-device sync through GitHub via SSH to keep multiple workstations aligned.
- Seamless Jellyfin login with persistent sessions managed by `lib/app_state.dart`.
- Audio library discovery and selection powered by the custom Jellyfin client (`lib/jellyfin/`) and Deep Sea themed UI screens.
- Album grid view with live Jellyfin artwork (trident placeholder when art is missing) to showcase each library’s collection.
- Curated playlists and recently added feeds cached in-memory for snappy reloads across the session.

## Roadmap
- [x] Integrate Jellyfin authentication and session persistence.
- [x] Filter and select Jellyfin audio libraries.
- [x] Surface albums from the selected Jellyfin library with artwork.
- [x] Fetch playlists and recently added tracks with lightweight caching.
- [x] Build album detail view with track listings and navigation.
- [x] Implement persistent playback state (track position, queue, current track).
- [ ] Implement audio playback with background audio and media controls.
- [ ] Build media catalog browsing (artists, playlists detail views).
- [ ] Wire the Swift CarPlay plugin into the Flutter engine.
- [ ] Build a cohesive now-playing experience and queue management UI.
- [ ] Harden multiplatform builds (Linux, Windows, macOS, iOS, Web).

## Repository Layout
- `lib/` – Flutter application code. `main.dart` boots the app and applies the custom theme defined in `theme/`.
- `lib/app_state.dart` – Central ChangeNotifier handling login state, session restoration, and library selection.
- `lib/jellyfin/` – Client, models, and persistence helpers for Jellyfin (credentials, session store, library fetching, album tracks).
- `lib/screens/` – Nautune UI screens (`login_screen.dart`, `library_screen.dart`, `album_detail_screen.dart`) backing the authentication, library picker, and album browsing flows.
- `lib/models/` – Data models including `playback_state.dart` for persistent playback tracking.
- `lib/services/` – Service layer including `playback_state_store.dart` for saving/loading playback position and queue.
- `assets/` – Images, icons, and future audio assets (empty by default).
- `plugins/` – Home for the Swift CarPlay plugin and other federated platform modules.
- `android`, `ios`, `linux`, `macos`, `windows`, `web` – Platform-specific runners generated by Flutter.
- `test/` – Widget and unit tests (add coverage as features land).
- `analysis_options.yaml` – Static analysis rules (`flutter_lints`).

## Getting Started
1. Install Flutter (stable channel, revision `adc9010`, Dart SDK 3.9). Confirm with `flutter doctor`.
2. Clone the repository over SSH: `git clone git@github.com:<org>/nautune.git`.
3. From the project root, fetch dependencies: `flutter pub get`.
4. Run the Linux desktop build: `flutter run -d linux`. Sign in with your Jellyfin server (URL, username, password), then choose the audio library Nautune should sync with.

> Tip: Development is Linux-only. Keep your environment Snap-free by using the official Flutter tarball or FVM and relying on Codemagic for iOS artifacts.

## Building for Other Platforms
- **iOS**: Builds are produced by Codemagic. Ensure the CarPlay Swift plugin is committed under `plugins/` so CI can bundle it. Refer to Codemagic workflow files (to be added) for signing and provisioning.
- **Windows / macOS**: Use `flutter build windows` or `flutter build macos` on their respective OSes once platform-specific prerequisites are installed.
- **Web**: `flutter run -d chrome` for rapid iteration, `flutter build web` to generate deployable assets.
- **Android**: Currently not a focus; no Android SDK or emulator is required for development.

## Development Guidelines
- Follow Dart/Flutter lints enforced by `analysis_options.yaml`. Run `flutter analyze` before pushing.
- Add unit/widget tests for new features: `flutter test`.
- Keep UI code declarative; centralize styling in `lib/theme/`.
- Maintain Jellyfin integrations inside `lib/jellyfin/`; expose state to widgets through `NautuneAppState`.
- Gate new UI with graceful loading/error states similar to the login and library picker.
- Document complex flows in the codebase with short comments so collaborators ramp up quickly.

## Contributing & Collaboration
- Work on feature branches synced over SSH. Open pull requests against `main` with a short demo or screenshots when UI changes.
- Coordinate multiplatform changes early (e.g., desktop shortcuts, CarPlay hooks) to avoid drift between Flutter and Swift components.
- Use descriptive commit messages and note any Codemagic considerations in PR descriptions.

## Next Steps
1. Integrate an audio engine (e.g., `just_audio` + `audio_service`) for actual playback with background audio support.
2. Wire playback state persistence to save/restore track position when user pauses or app restarts.
3. Build artist and playlist detail views with track listings sourced from Jellyfin.
4. Design the now playing UI with queue management and media controls.
5. Implement background audio service that respects playback state persistence.
6. Draft Codemagic configuration files for automated iOS packaging and CarPlay builds.

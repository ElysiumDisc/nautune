# Nautune 🎵🌊

Poseidon's cross-platform Jellyfin music player. Nautune is built with Flutter and delivers a beautiful deep-sea themed experience with smooth native audio playback, animated waveform visualization, and seamless Jellyfin integration.

## ✨ Highlights

### 🎵 Audio & Playback
- **Native Audio Engine**: Powered by `audioplayers` with platform-specific optimization
  - 🍎 **iOS/macOS**: AVFoundation (hardware-accelerated)
  - 🐧 **Linux**: GStreamer (native multimedia framework)
  - 🤖 **Android**: MediaPlayer
  - 🪟 **Windows**: WinMM
- **Direct Streaming**: Optimized audio streaming from Jellyfin servers
- **Smooth Performance**: Hardware-accelerated audio with real-time streaming
- **Position Persistence**: Automatically saves and restores playback position across app restarts
- **Queue Management**: Full album playback with next/previous track navigation
- **Background Audio**: Continues playing when app is minimized

### 🌊 Visual Experience
- **Sonic Wave Visualization**: Real-time frequency spectrum analyzer with 60 animated bars
  - 🎸 **Bass** (left): Slower, bigger pulses mimicking low frequencies
  - 🎹 **Mids** (center): Moderate activity representing mid-range
  - 🎺 **Treble** (right): Fast, lighter movements for high frequencies
  - ✨ Smooth interpolation at 20 FPS for fluid, natural motion
  - 📱 **Cross-platform**: Works on Linux, iOS, Android, macOS, Windows
- **Now Playing Bar**: Always-visible mini-player with live progress tracking and controls
- **Deep Sea Purple Theme**: Oceanic gradient color scheme defined in `lib/theme/` and applied consistently
- **Album & Artist Art**: Beautiful grid and list layouts with Jellyfin artwork (trident placeholder fallback)

### 📚 Library Browsing
- **✅ Albums Tab**: Grid view with album artwork, year, and artist info - click to see tracks
- **✅ Artists Tab**: Browse all artists with circular profile artwork - click to see their albums
- **✅ Favorites Tab**: Recently played and favorited tracks
- **✅ Playlists Tab**: Access all your Jellyfin playlists
- **✅ Downloads Tab**: Placeholder for offline mode (coming soon)
- **Track Listings**: Full album detail screens with all tracks, durations, and track numbers
- **Artist Discography**: View all albums by an artist
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
# Core Audio - Platform-specific native backends
audioplayers: ^6.1.0      # iOS:AVFoundation, Linux:GStreamer, Android:MediaPlayer
audio_session: ^0.1.21    # Audio session configuration

# Data & State
shared_preferences: ^2.3.2 # Persistent storage for sessions and playback state
http: ^1.2.2               # Jellyfin API communication
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
- **Sonic Wave Analyzer**: 60 frequency bars simulating real audio spectrum
  - Bass frequencies on left (slow, big movements)
  - Mid frequencies in center (moderate activity)
  - Treble frequencies on right (fast, light movements)
  - Smooth 20 FPS interpolation for organic feel
  - Works on ALL platforms (no native dependencies)
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
- [x] **Artists view with discography**
- [x] **Artist detail screen showing all albums**
- [x] Playlists and recently added tracks
- [x] **Album detail view with full track listings**
- [x] **Audio playback with native engine (direct streaming)**
- [x] **Persistent playback state (position, queue, track)**
- [x] **Sonic wave visualization (frequency spectrum simulation)**
- [x] **Tabbed navigation (Albums/Artists/Favorites/Playlists/Downloads)**
- [x] **Now playing bar with controls and waveform**
- [x] **Click tracks to play from any album**
- [x] **Click artists to see their discography**

### 🚧 In Progress / Planned
- [ ] Full player screen with album art and lyrics
- [ ] Search functionality across library
- [ ] Download tracks for offline playback
- [ ] Equalizer and audio settings
- [ ] **Sorting options** (by name, date added, year for albums/artists)
- [ ] **True FFT audio visualization** (real-time frequency analysis via platform audio capture)
- [ ] Gapless playback between tracks
- [ ] Media controls on lock screen
- [ ] Swift CarPlay plugin integration
- [ ] Cross-platform stability (Windows, macOS, Android)

## 🐛 Known Issues

- **Audio Streaming**: Using direct download URLs (`/Items/{id}/Download`) for best GStreamer compatibility on Linux
- Downloads tab is a placeholder (offline mode pending implementation)
- Infinite scrolling needs backend pagination support
- **Waveform visualization**: Currently uses simulated frequency spectrum (looks realistic but doesn't analyze actual audio). For TRUE FFT analysis, would need platform-specific audio capture plugins.
- Lock screen media controls not yet implemented

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
- [audioplayers](https://pub.dev/packages/audioplayers) - Cross-platform native audio engine
- [audio_session](https://pub.dev/packages/audio_session) - Native audio session management
- Flutter team - Incredible cross-platform framework

## 💬 Support & Community

- 🐛 **Bug reports**: Open an issue with steps to reproduce
- ✨ **Feature requests**: Describe your idea in an issue
- ⭐ **Star the repo**: If you like Nautune, show your support!
- 🔔 **Follow for updates**: Watch the repo for new releases

---

**Made with 💜 by ElysiumDisc** | Dive deep into your music 🌊🎵

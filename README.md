# Nautune 🎵🌊

Poseidon's cross-platform Jellyfin music player. Nautune is built with Flutter and delivers a beautiful deep-sea themed experience with smooth native audio playback, animated waveform visualization, and seamless Jellyfin integration.

## ✨ Highlights

### 🎵 Audio & Playback
- **Native Engine**: Powered by `audioplayers` with platform-specific backends
  - 🍎 **iOS/macOS**: AVFoundation (hardware-accelerated)
  - 🐧 **Linux**: GStreamer (native multimedia framework)
  - 🤖 **Android**: MediaPlayer
  - 🪟 **Windows**: WinMM
- **Direct Play First**: Streams original Jellyfin files (FLAC/AAC/etc.) when supported, with automatic MP3 fallback if the platform rejects the source
- **Album Queueing**: One tap queues the whole album in disc/track-number order with seamless previous/next navigation
- **Resume & Persist**: Playback position is saved every second and restored on launch
- **Background Audio**: Keeps playing while the app is in the background

### 🌊 Visual Experience
- **Waveform Progress**: Animated lilac waveform sourced from Jellyfin's preview API with a graceful synthetic fallback
- **Scrubbable Mini Player**: Waveform strip and slider both seek playback instantly
- **Now Playing Bar**: Always-visible controls, real-time progress indicator, and quick access to the full player
- **Deep Sea Purple Theme**: Oceanic gradient color scheme defined in `lib/theme/` and applied consistently
- **Album & Artist Art**: Beautiful grid and list layouts with Jellyfin artwork (trident placeholder fallback)

### 📚 Library Browsing
- **✅ Albums Tab**: Grid view with album artwork, year, and artist info - click to see tracks
- **✅ Artists Tab**: Browse all artists with circular profile artwork - click to see their albums
- **✅ Favorites Tab**: Recently played and favorited tracks
- **✅ Playlists Tab**: Access all your Jellyfin playlists
- **✅ Downloads Tab**: Placeholder for offline mode (coming soon)
- **Track Listings**: Full album detail screens with ordered track lists, durations, and padded numbers (multi-disc aware)
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
- **Waveform Progress Strip**: Tinted Jellyfin waveform with a synthetic fallback when the server can't provide one
- **Scrub Anywhere**: Drag the waveform or slider to seek instantly
- **Mini Controls**: Play/Pause/Stop/Skip buttons always accessible
- **Tap to Expand**: Opens the full-screen player

### Library Screen (`lib/screens/library_screen.dart`)
- **Albums Tab**: Grid view with infinite scroll support, album artwork
- **Artists Tab**: Placeholder (coming soon!)
- **Favorites Tab**: Recent and favorited tracks in a list
- **Playlists Tab**: Your Jellyfin playlists with track counts
- **Header**: Library switcher and user info

### Audio Player Service (`lib/services/audio_player_service.dart`)
- Manages playback lifecycle and queues
- Prioritises direct-play URLs with adaptive fallback to Jellyfin transcoding
- Auto-saves position every second and restores on launch
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
- [x] **REAL FFT Audio Spectrum Visualization** (true frequency analysis with flutter_audio_capture + fftea)
- [x] **Tabbed navigation (Albums/Artists/Favorites/Playlists/Downloads)**
- [x] **Now playing bar with controls and REAL-TIME waveform**
- [x] **Full-screen player with stop button and responsive design**
- [x] **Click tracks to play from any album**
- [x] **Click artists to see their discography**
- [x] **Back buttons on all detail screens**
- [x] **Responsive layout** (adapts between mobile and desktop)

### 🚧 In Progress / Planned
- [ ] Full player screen with album art and lyrics
- [ ] Search functionality across library
- [ ] Download tracks for offline playback
- [ ] Equalizer and audio settings
- [ ] **Sorting options** (by name, date added, year for albums/artists)
- [ ] Gapless playback between tracks
- [ ] Media controls on lock screen
- [ ] Swift CarPlay plugin integration
- [ ] Cross-platform stability (Windows, macOS, Android)
- [ ] **FFT optimization**: Currently uses flutter_audio_capture which may need platform-specific permissions

## 🐛 Known Issues

- **Audio Streaming**: Using direct download URLs (`/Items/{id}/Download`) for best GStreamer compatibility on Linux
- **Audio Capture Permissions**: FFT visualization requires microphone/audio capture permissions on iOS/Android
  - On **Linux**: May need PulseAudio/ALSA loopback module for system audio capture
  - On **iOS**: Requires microphone permission (will fall back to silent bars if denied)
  - On **Android**: Requires `RECORD_AUDIO` permission
- Downloads tab is a placeholder (offline mode pending implementation)
- Infinite scrolling needs backend pagination support
- **Waveform**: Now uses REAL FFT analysis but falls back to silent if audio capture unavailable
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

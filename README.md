# Nautune 🎵🌊

Poseidon's cross-platform Jellyfin music player. Nautune is built with Flutter and delivers a beautiful deep-sea themed experience with smooth native audio playback, animated waveform visualization, and seamless Jellyfin integration.

## ✨ Highlights

### 🎵 Audio & Playback
- **Native Engine**: Powered by `audioplayers` with platform-specific backends
  - 🍎 **iOS/macOS**: AVFoundation (hardware-accelerated, native FLAC support)
  - 🐧 **Linux**: GStreamer (native multimedia framework with FLAC codec)
  - 🤖 **Android**: MediaPlayer
  - 🪟 **Windows**: WinMM
- **Gapless Playback**: Seamless transitions between tracks with preloading
- **Direct Play Only**: Always streams original Jellyfin files in native format (FLAC/AAC/etc.)
  - ✅ No transcoding - preserves audio quality
  - ✅ Native platform decoders handle all formats
  - ✅ Reduced server load
- **Original Quality Downloads**: Downloads always use original lossless format (FLAC preferred)
- **Album Queueing**: One tap queues the whole album in disc/track-number order with seamless previous/next navigation
- **Resume & Persist**: Playback position is saved every second and restored on launch
- **Background Audio**: Keeps playing while the app is in the background
- **Playback Reporting**: Full Jellyfin server integration
  - ✅ Reports playback start with play method (DirectPlay/DirectStream)
  - ✅ Real-time progress updates (position, pause state)
  - ✅ Automatic "Recently Played" tracking in Jellyfin
  - ✅ Session-based reporting with unique IDs
  - ✅ Proper stop reporting with final position
- **iOS Media Integration**: Native lock screen controls and CarPlay support
  - ✅ Lock screen media controls via audio_service plugin
  - ✅ Album artwork display on lock screen
  - ✅ Play/pause, skip controls work from lock screen
  - ✅ **Full CarPlay integration** - library browsing (albums, artists, playlists, favorites, downloads)
  - ✅ CarPlay supports offline playback with downloads (airplane mode works!)
  - ✅ Simple, focused car-friendly UI with tab navigation
  - ✅ Seamless integration with iOS audio session

### 🌊 Visual Experience
- **Waveform Progress**: Real waveform from Jellyfin API with intelligent caching per track
- **Scrubbable Mini Player**: Waveform strip and slider both seek playback instantly
- **Now Playing Bar**: Always-visible controls, real-time progress indicator, and quick access to the full player
- **Full Screen Player**: Auto-updating UI with StreamBuilder - play/pause, progress bar, and track info always in sync
- **Deep Sea Purple Theme**: Oceanic gradient color scheme with light purple "Nautune" title (Pacifico font)
- **Album & Artist Art**: Beautiful grid and list layouts with Jellyfin artwork (trident placeholder fallback)

### 📚 Library Browsing
- **✅ Albums Tab**: Grid view with album artwork, year, and artist info - click to see tracks
- **✅ Artists Tab**: Browse all artists with circular profile artwork - click to see their albums
- **✅ Recent Tab**: Toggle between recently played tracks (from Jellyfin history) and recently added albums with segmented control
- **✅ Favorites Tab**: Jellyfin favorites integration with heart button in fullscreen player
  - ✅ Mark tracks/albums as favorites
  - ✅ View favorite tracks list
  - ✅ Sync favorites with Jellyfin server
  - ✅ Toggle favorite state with heart icon
- **✅ Playlists Tab**: Full playlist management with Jellyfin sync
  - ✅ Create new playlists
  - ✅ Edit/rename playlists (three-dot menu or detail screen)
  - ✅ Delete playlists with confirmation dialog
  - ✅ View all tracks in playlist detail screen
  - ✅ Add albums/tracks to playlists (long-press on albums, menu on tracks)
  - ✅ Remove tracks from playlists
  - ✅ Play playlists with queue support
  - ✅ All changes sync to Jellyfin server instantly
- **✅ Downloads Tab**: Full offline download support with original quality (FLAC/lossless), progress tracking, album batch downloads, and file management
- **✅ Offline Library**: Click wave icon (🌊) to browse downloads by album or artist - **works in airplane mode!**
- **✅ Settings**: Click "Nautune" title to view server info and about section (native quality playback always enabled)
- **✅ Favorite Button**: Heart icon in fullscreen player synced with Jellyfin favorites API
- **✅ Queue View**: Browse and reorder currently queued tracks via queue button in now playing bar
- **Track Listings**: Full album detail screens with ordered track lists, durations, and padded numbers (multi-disc aware)
- **Artist Discography**: View all albums by an artist
- **Bottom Navigation**: Icon-only rail keeps the most-used sections a single tap away on every platform
- **Library Search Tab**: Dedicated search experience for quickly finding albums by name, showing artist and year context
- **Smart Refresh**: Pull-to-refresh on all tabs for latest content sync
- **Add to Playlist**: Long-press albums, use menu button on tracks, or toolbar button in album detail to add content to any playlist

### 🎯 Jellyfin Integration
- **Direct Streaming**: Streams music directly from your Jellyfin server with adaptive quality
- **Album Browsing**: View all albums with high-quality artwork and metadata
- **Favorites API**: Full Jellyfin favorites integration
  - ✅ Mark tracks/albums as favorites from fullscreen player
  - ✅ View favorite tracks in Favorites tab
  - ✅ Favorites sync with Jellyfin server instantly
  - ✅ Heart icon toggles favorite state
- **Playlist Support**: Full Jellyfin playlist integration with real-time sync
  - ✅ Create playlists on server
  - ✅ Rename/edit playlists
  - ✅ Delete playlists
  - ✅ Add albums and tracks to playlists
  - ✅ Remove tracks from playlists
  - ✅ All changes persist on Jellyfin server
- **Recent Tracks**: Quick access to recently played and added music with Jellyfin sync
- **Persistent Sessions**: Login once, stay connected across app launches
- **Playback Reporting**: Full integration with Jellyfin's activity tracking
  - ✅ Reports play method (DirectPlay/DirectStream)
  - ✅ Real-time progress updates to server
  - ✅ Updates "Recently Played" in Jellyfin dashboard
  - ✅ Session-based reporting with proper start/stop events
- **Offline Downloads**: Download albums and tracks for offline playback
  - ✅ **Linux/Desktop**: Stored in project `downloads/` directory
  - ✅ **iOS/Android**: Stored in app documents directory (persists across updates, **airplane mode compatible**)
  - ✅ Automatic offline playback when file exists (no internet required)
  - ✅ Always downloads original format (FLAC/lossless preferred)
  - ✅ **iOS CarPlay supports offline downloads** - browse and play in car without internet
  - ✅ Download progress tracking and cancellation
  - ✅ Batch album downloads

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
audio_service: ^0.18.15   # iOS lock screen controls and media notifications

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
- **Artists Tab**: Full artist browser with discography navigation
- **Search Tab**: Search albums inside the selected library, displaying artist attribution and year
- **Favorites Tab**: Recent and favorited tracks in a list
- **Playlists Tab**: Your Jellyfin playlists with full management (create, edit, delete, add/remove tracks)
- **Bottom Navigation**: Material `NavigationBar` mirrors the tab order for quick access on mobile and desktop

### Playlist Detail Screen (`lib/screens/playlist_detail_screen.dart`)
- **Track List**: View all tracks in a playlist with play functionality
- **Remove Tracks**: Individual track removal with ❌ button
- **Edit/Rename**: Toolbar button to rename playlist
- **Delete**: Toolbar button to delete entire playlist
- **Play Queue**: Play individual tracks or queue entire playlist

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

- **iOS**: Builds produced by **Codemagic CI** with full feature support
  - ✅ **Native audio playback** via AVFoundation (FLAC/AAC/lossless support)
  - ✅ **Lock screen controls** with album artwork via audio_service
  - ✅ **Full CarPlay integration** - browse library, playlists, favorites, downloads in car mode
  - ✅ **Offline downloads** stored in app documents directory (airplane mode compatible)
  - ✅ CarPlay works fully offline with downloaded content
  - ✅ All Jellyfin features work on iOS (playback reporting, favorites sync, playlist management)
- **Windows**: `flutter build windows` (requires Windows machine with VS 2022)
- **macOS**: `flutter build macos` (requires macOS with Xcode)
- **Web**: `flutter run -d chrome` for dev, `flutter build web` for production
- **Android**: Not currently a focus; no Android SDK required for development

> **Development Tip**: Keep your Linux environment Snap-free. Use official Flutter tarball or FVM. Codemagic handles iOS builds automatically.

### 🚗 CarPlay Support (iOS Only)

Nautune includes **full CarPlay integration** for iOS with complete library access:

#### ✅ Features
- **Tab Navigation**: Library, Favorites, Downloads tabs with simple car-friendly UI
- **Library Browsing**: Browse albums, artists, and playlists while driving
- **Track Playback**: Play any track directly from CarPlay - integrates with iOS audio session
- **Offline Support**: Browse and play downloaded music in airplane mode (no internet required)
- **Native Integration**: Swift scene delegate with Flutter method channel bridge for seamless communication

#### 🔧 Implementation Details
- **Native CarPlay Scene**: `ios/Runner/CarPlaySceneDelegate.swift` - handles CarPlay UI and interactions
- **Flutter Bridge**: `lib/services/carplay_service.dart` - connects CarPlay to app state
- **Info.plist Configuration**: CarPlay scene manifest (`CPTemplateApplicationSceneSessionRoleApplication`) and audio background mode
- **Method Channel**: Bidirectional communication between Swift CarPlay UI and Flutter app logic
- **Offline Downloads**: iOS stores downloads in app documents directory - accessible even offline
- **Lock Screen Controls**: Album artwork, play/pause, skip buttons via audio_service plugin

#### 🧪 Testing CarPlay
CarPlay requires one of the following:
- **Physical Device**: iPhone with CarPlay-enabled car or CarPlay-compatible head unit
- **iOS Simulator**: Xcode → I/O → External Display → CarPlay window

The CarPlay interface automatically appears when connected to a CarPlay system. No additional setup needed!

#### 📱 iOS-Specific Features
All iOS features are built and deployed via **Codemagic CI**:
- ✅ Native AVFoundation audio engine (FLAC, AAC, all formats supported)
- ✅ Lock screen media controls with album artwork
- ✅ Background audio playback
- ✅ CarPlay full library browsing and offline playback
- ✅ Downloads stored in app documents (airplane mode compatible)
- ✅ All Jellyfin features (favorites, playlists, playback reporting)

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
- [x] **Gapless playback** with track preloading
- [x] **Jellyfin Playback Reporting integration** for activity tracking
- [x] **Offline downloads** with progress tracking and album batch downloads
- [x] **Recent tab with toggle** between recently played and recently added
- [x] **iOS CarPlay** with full library browsing (albums, artists, playlists, favorites, downloads) and **offline support**
- [x] **Waveform visualization** using Jellyfin's waveform API with per-track caching
- [x] **Tabbed navigation (Albums/Artists/Search/Favorites/Recent/Playlists/Downloads)** - 7 tabs total
- [x] **Settings screen** with transcoding options accessible from app title
- [x] **Now playing bar with controls and real-time waveform**
- [x] **Full-screen player** with auto-updating UI (play/pause state, progress bar synced)
- [x] **Favorite button** in fullscreen player (heart icon, ready for API)
- [x] **Full playlist management with Jellyfin integration**
  - [x] Create playlists on Jellyfin server
  - [x] Rename/edit playlists
  - [x] Delete playlists with confirmation
  - [x] Add albums to playlists (long-press on album cards)
  - [x] Add tracks to playlists (menu button on tracks)
  - [x] Playlist detail screen with track list
  - [x] Remove tracks from playlists
  - [x] All changes sync to server instantly
- [x] **Click tracks to play from any album**
- [x] **Click artists to see their discography**
- [x] **Back buttons on all detail screens**
- [x] **Responsive layout** (adapts between mobile and desktop)

### 🚧 In Progress / Planned
- [ ] Full player screen with lyrics display
- [ ] Enhanced search across all content types
- [ ] Equalizer and audio settings
- [ ] **Sorting options** (by name, date added, year for albums/artists)
- [ ] Cross-platform stability improvements (Windows, macOS, Android)

## 🐛 Known Issues

- **Native FLAC Playback**: Uses direct download URLs for original quality, platform decoders handle FLAC/AAC/etc. natively
- Infinite scrolling needs backend pagination support
- CarPlay testing requires physical device or iOS Simulator with CarPlay window

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

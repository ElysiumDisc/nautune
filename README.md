# Nautune 🔱🌊

**Nautune** (Poseidon Music Player) is a high-performance, visually stunning music client for Jellyfin. Built for speed, offline reliability, and an immersive listening experience.

## ✨ Key Features

- **Collaborative Playlists**: Real-time SyncPlay sessions - listen together with friends via QR code or share link
- **Custom Color Theme**: Create your own theme with primary/secondary color picker
- **10-Band Equalizer**: Full graphic EQ with 12 presets (Rock, Pop, Jazz, Classical, and more)
- **Real-Time FFT Visualizer**: True audio-reactive waves using PulseAudio (Linux) and MTAudioProcessingTap (iOS)
- **Bioluminescent Waves**: Track-reactive animation that adapts to loudness and genre
- **Smart Pre-Cache**: Configurable pre-caching of upcoming tracks (3, 5, or 10) with WiFi-only option
- **Smart Lyrics**: Multi-source lyrics with sync, caching, and pre-fetching
- **41 Nautical Milestones**: Earn achievements as you listen
- **Track Sharing**: Share downloaded audio files via AirDrop (iOS) or file manager (Linux)
- **Storage Management**: Separate views for downloads vs cache with accurate stats
- **Listening Analytics**: Heatmaps, streaks, and weekly comparisons
- **Global Search**: Unified search across your entire library with instant results
- **Smart Offline Mode**: Persistent offline preference, auto-detects airplane mode, seamless downloaded content playback
- **High-Fidelity Playback**: Native backends for Linux and iOS ensuring bit-perfect audio
- **CarPlay Support**: Take your Jellyfin library on the road with CarPlay interface
- **Personalized Home**: Discover, On This Day, and For You recommendation shelves

---

## 📋 Changelog

### v5.3.1 - Relax Mode
- **Ambient Sound Mixer**: Mix rain, thunder, and campfire sounds with vertical sliders
- **Looping Audio**: Seamless ambient loops for focus or relaxation
- **Easter Egg Access**: Search "relax" in the library to discover the feature (works in offline & demo mode too)
- **"Calm Waters" Milestone**: Unlock a special badge for discovering Relax Mode
- **Relax Mode Stats**: Track total time spent and sound usage breakdown (Rain/Thunder/Campfire %)
- Inspired by [ebithril/relax-player](https://github.com/ebithril/relax-player)

### v5.1.0 - Analytics Sync & Server Integration
- **Two-Way Analytics Sync**: Play history syncs bidirectionally with your Jellyfin server
- **Timestamped Play Reports**: Plays recorded with actual timestamps, even when offline
- **Offline Queue**: Plays made offline are queued and synced when network returns
- **Server Reconciliation**: Catch up on plays made from other devices automatically
- **Background Sync**: Automatic sync on app startup and network reconnection

### v5.0.0 - Collaborative Playlists & Smart Offline
- **SyncPlay Integration**: Create and join collaborative playlists using Jellyfin's SyncPlay
- **Real-Time Sync**: Listen together with friends - playback stays synchronized
- **QR Code Sharing**: Invite friends by scanning a QR code or share link
- **Captain/Sailor Roles**: Captain outputs audio, all participants can control playback
- **Jellyfin Profile Avatars**: Participant avatars show Jellyfin user profile pictures
- **Active Session Card**: Quick access to rejoin session from Playlists tab (even in empty state)
- **Auto-Reconnect**: Session automatically rejoins after WebSocket disconnection
- **Full Visualizer Support**: Collab tracks pre-cached for waveform, FFT visualizer, and lyrics
- **Persistent Offline Mode**: Offline preference now saved across app restarts
- **Smart Airplane Mode**: Auto-switches to offline when network lost, auto-recovers when network returns
- **Offline-Aware Collab**: Collaborative playlist features hidden when offline (requires network)
- **Library Tab Persistence**: Library remembers your last tab when navigating away and back

### v4.9.0 - Settings UI Refresh
- **Card-Based Settings Layout**: Reorganized settings into visually grouped cards for cleaner navigation
- **Section Icons**: Each settings section now has a distinctive icon header (Server, Appearance, Audio, Performance, Downloads, About)
- **Polished Spacing**: Improved padding and margins throughout the settings screen
- **Alphabet Scrollbar Fix**: Fixed zone-based hit detection for library alphabet navigation

### v4.8.0 - Custom Themes & Storage Improvements
- **Custom Color Theme**: Infinite personalization with color wheel picker
- **Nautical Milestones Expanded**: Doubled from 20 with new categories (night owl, early bird, genre exploration)
- **Storage Management Overhaul**: Separate downloads vs cache views, accurate stats, one-tap cache clearing
- **Storage Settings Moved**: Storage limit and auto-cleanup now in Storage Management screen
- **Download System Fixes**: Fixed album art duplication (now stored per-album), proper owner-based deletion, index updates
- **Lyrics Source in Menu**: Moved lyrics source indicator to three-dot menu for cleaner UI

### v4.7.0 - Equalizer & Smart Cache
- **10-Band Graphic Equalizer**: Full EQ control from 32Hz to 16kHz with 12 presets
- **Smart Pre-Cache**: Configurable track count (Off, 3, 5, 10) with WiFi-only option
- **Track Sharing**: Share downloaded tracks via AirDrop (iOS) or file manager (Linux)
- **iOS Files Integration**: Downloads folder visible in Files app
- **Theme Palettes**: 6 built-in palettes (Purple Ocean, Light Lavender, OLED Peach, etc.)

### v4.6.0 - FFT Visualizer & Lyrics
- **Real-Time FFT Visualizer**: True audio-reactive waves with bass SLAM and treble shimmer
- **Bioluminescent Visualizer**: Track-reactive animation adapting to loudness and genre
- **Smart Lyrics**: Multi-source fallback (Jellyfin → LRCLIB → lyrics.ovh) with sync and caching
- **iOS Low Power Mode**: Visualizer auto-disables when Low Power Mode is on
- **Enhanced Stats**: Listening heatmap, streak tracker, week comparison

---

## 🔊 FFT Visualizer Platform Support

| Platform | FFT Method | Status |
|----------|-----------|--------|
| Linux | PulseAudio `parec` loopback | ✅ Instant |
| iOS (downloaded) | MTAudioProcessingTap + vDSP | ✅ Instant |
| iOS (streaming) | Cache then tap | ✅ After cache |

## 🛠 Technical Foundation
- **Framework**: Flutter (Dart)
- **Local Storage**: Hive (NoSQL) for high-speed metadata caching
- **Audio Engine**: Audioplayers with custom platform-specific optimizations
- **Equalizer**: PulseAudio LADSPA (Linux), AVAudioEngine (iOS)
- **FFT Processing**: Custom Cooley-Tukey (Linux), Apple Accelerate vDSP (iOS)
- **Image Processing**: Material Color Utilities for vibrant palette generation

## 📂 File Structure (Linux)
Nautune follows a clean data structure on Linux for easy backups and management:
- `~/Documents/nautune/`: Primary application data
- `~/Documents/nautune/downloads/`: High-quality offline audio files
- `~/Documents/nautune/downloads/artwork/`: Cached album artwork (stored per-album to save space)

---

## 📸 Screenshots

### Linux / Desktop
<img src="screenshots/linux-ipad1.png" width="400" alt="Nautune on Linux">
<img src="screenshots/linux-ipad2.png" width="400" alt="Nautune on Linux">

### iOS
<img src="screenshots/ios5.png" width="250" alt="Nautune on iOS">
<img src="screenshots/ios6.png" width="250" alt="Nautune on iOS">
<img src="screenshots/ios7.jpg" width="250" alt="Nautune on iOS">
<img src="screenshots/ios9.jpg" width="250" alt="Nautune on iOS">

### CarPlay
<img src="screenshots/carplay3.png" width="300" alt="Nautune CarPlay">
<img src="screenshots/carplay5.png" width="300" alt="Nautune CarPlay">

## 🧪 Review / Demo Mode

Apple's Guideline 2.1 requires working reviewer access. Nautune includes an on-device demo that mirrors every feature—library browsing, downloads, playlists, CarPlay, and offline playback—without touching a real Jellyfin server.

1. **Credentials**: leave the server field blank, use username `tester` and password `testing`.
2. The login form detects that combo and seeds a showcase library with open-source media. Switching back to a real server instantly removes demo data (even cached downloads).

## 🔧 Development

### Run in Debug Mode
```bash
flutter run -d linux --debug
```

### Build Release
```bash
flutter build linux --release
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

## 🗺️ Roadmap

| Feature | Platform | Status |
|---------|----------|--------|
| Desktop Remote Control | iOS → Linux | 🔜 Planned |
| Additional Visualizers | All | 🔜 Planned |

- **Desktop Remote Control**: Control desktop playback from iOS device over local network.
- **Additional Visualizers**: More audio-reactive visualizer styles beyond bioluminescent waves (e.g., spectrum bars, particle effects, waveforms).

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

**Made with 💜 by ElysiumDisc** | Dive deep into your music 🌊🎵

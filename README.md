# Nautune 🔱🌊

**Nautune** (Poseidon Music Player) is a high-performance, visually stunning music client for Jellyfin. Built for speed, offline reliability, and an immersive listening experience.

## 🚀 Latest Updates (v4.4.0)

### 🎵 Real-Time FFT Audio Visualizer
- **True Audio-Reactive Waves**: Visualizer follows ACTUAL audio frequencies
- **Linux**: PulseAudio system loopback captures real audio output via `parec`
- **iOS**: MTAudioProcessingTap captures app audio via shadow AVPlayer
- **Bass SLAM**: Waves explode on bass drops with 30x boost
- **Treble Shimmer**: High frequencies create sparkle effects with 80x boost
- **Musical Smoothing**: Fast attack (0.6) / slow decay (0.12) for natural feel
- **Low Latency**: 20ms audio capture for instant response

### 🌊 Bioluminescent Visualizer
- **Track-Reactive Animation**: Visualizer intensity and speed adapt to each track's loudness (ReplayGain) and genre
- **Genre-Aware Styles**: EDM/rock tracks get energetic, bass-heavy waves; classical/jazz get smooth, flowing animation
- **iOS Low Power Mode**: Visualizer automatically disables when Low Power Mode is on, restores when off
- **Performance Optimized**: Reduced GPU work while maintaining full visual quality
- **Bass Pulse Rings**: Expanding circles on heavy bass hits
- **Sub-Bass Rumble**: Low frequency wobble effect
- **Floating Particles**: 15 bioluminescent orbs that pulse with the beat

### 🎨 Theme System
- **6 Beautiful Palettes**: Purple Ocean (default), Light Lavender, OLED Peach, Apricot Garden, Raspberry Sunset, Emerald Rose
- **OLED Support**: True black theme with salmon/peach accents for battery savings
- **Light Mode**: Clean lavender-white theme with dark purple accents
- **Live Preview**: See theme changes instantly in Settings

### 🎵 Smart Lyrics
- **Multi-Source Fallback**: Automatically fetches lyrics from Jellyfin → LRCLIB → lyrics.ovh
- **Synchronized Lyrics**: Time-synced lyrics with auto-scroll and tap-to-seek
- **Intelligent Caching**: 7-day cache with automatic refresh
- **Pre-fetching**: Lyrics for the next track load at 50% playback
- **Source Indicator**: Shows where lyrics came from with refresh button

### 🏆 Nautune Milestones
- **20 Nautical-Themed Badges**: Earn achievements as you listen
  - Voyage: "Setting Sail" → "Admiral"
  - Depths: "First Tide" → "Mariana Depths"
  - Winds: "Trade Winds" → "Eternal Voyage"
  - Explorer: "Port Explorer" → "World Voyager"
  - Treasure: "Treasure Hunter", "Chest Collector"
  - Pearls: "Shell Seeker", "Pearl Diver"
- **Progress Tracking**: See your next milestone and completion percentage

### 📊 Enhanced Stats
- **Listening Heatmap**: 7x24 grid showing when you listen most
- **Streak Tracker**: Current and longest listening streaks with flame icon
- **Week Comparison**: This week vs last week with trend indicators
- **Peak Hour**: Discover your favorite listening time

### 🏠 Revamped Home
- **Discover Shelf**: Albums you rarely play - explore your own library
- **On This Day**: What you listened to on this date in previous months
- **For You**: Personalized recommendations based on recent listening
- **Skeleton Loaders**: Smooth shimmer animations while loading

### ⚡ Performance
- **Isolate Computation**: Stats calculated off main thread for smooth UI
- **Image Pre-warming**: Album art cached ahead for instant display
- **Batch API Requests**: Reduced network calls with parallel fetching
- **Lyrics Pre-fetch**: Next track lyrics ready before you need them


## ✨ Key Features
- **Real-Time FFT Visualizer**: True audio-reactive waves using PulseAudio (Linux) and MTAudioProcessingTap (iOS)
- **Bioluminescent Waves**: Track-reactive animation that adapts to loudness and genre
- **Smart Lyrics**: Multi-source lyrics with sync, caching, and pre-fetching
- **Theme Palettes**: 6 stunning themes including OLED dark and light mode
- **Milestone Badges**: 20 nautical achievements to unlock as you listen
- **Listening Analytics**: Heatmaps, streaks, and weekly comparisons
- **Global Search**: Unified search across your entire library with instant results
- **Smart Offline Mode**: Full support for downloaded content with seamless transition
- **High-Fidelity Playback**: Native backends for all platforms ensuring bit-perfect audio
- **Visual Palette Extraction**: UI elements dynamically change color based on artwork
- **CarPlay Support**: Take your Jellyfin library on the road with CarPlay interface
- **Personalized Home**: Discover, On This Day, and For You recommendation shelves

## 🔊 FFT Visualizer Platform Support

| Platform | FFT Method | Status |
|----------|-----------|--------|
| Linux | PulseAudio `parec` loopback | ✅ Instant |
| iOS (downloaded) | MTAudioProcessingTap + vDSP | ✅ Instant |
| iOS (streaming) | Cache then tap | ✅ After cache |
| macOS | Metadata fallback | 🔄 Fallback |
| Android | Metadata fallback | 🔄 Fallback |
| Windows | Metadata fallback | 🔄 Fallback |

## 🛠 Technical Foundation
- **Framework**: Flutter (Dart)
- **Local Storage**: Hive (NoSQL) for high-speed metadata caching
- **Audio Engine**: Audioplayers with custom platform-specific optimizations
- **FFT Processing**: Custom Cooley-Tukey (Linux), Apple Accelerate vDSP (iOS)
- **Image Processing**: Material Color Utilities for vibrant palette generation

## 📂 File Structure (Linux)
Nautune follows a clean data structure on Linux for easy backups and management:
- `~/Documents/nautune/`: Primary application data
- `~/Documents/nautune/downloads/`: High-quality offline audio files
- `~/Documents/nautune/downloads/artwork/`: Cached album and artist imagery

---
*Nautune - Rule the waves of your music library.*

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

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

**Made with 💜 by ElysiumDisc** | Dive deep into your music 🌊🎵

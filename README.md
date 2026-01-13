# Nautune 🔱🌊

**Nautune** (Poseidon Music Player) is a high-performance, visually stunning music client for Jellyfin. Built for speed, offline reliability, and an immersive listening experience.

## 🚀 Latest Updates (v3.5.0)
- **👤 Immersive Profile & Stats**:
  - ✅ **Deep Listening Stats**: Track your habits with "Total Plays" and "Listening Hours" (calculated from your top 50 tracks).
  - ✅ **Dynamic Backgrounds**: The profile screen now features a beautiful background gradient extracted from your most-played track's album art.
  - ✅ **Organized Dashboard**: New 2x2 grid layout for quick stats (Total Plays, Hours, Top Artist, Top Album).
  - ✅ **Jellyfin Integration**: Personalized profile image and server info directly from your account.
- **🔍 Unified Global Search**:
  - ✅ **Instant Discovery**: Search across albums, artists, and tracks simultaneously in a single view.
  - ✅ **Clean Results**: Grouped categorization for a faster, more intuitive browsing experience.
  - ✅ **Parallel Performance**: Uses batch API calls to deliver results with near-zero latency.
- **🛠 Code Modernization**:
  - ✅ **Flutter 3.9+ Ready**: Transitioned to the latest transparency APIs (`withValues`) and removed deprecated code.
  - ✅ **Enhanced Reliability**: Safe shadowing of core services to prevent potential null-pointer crashes during background tasks.

## 📁 Smarter File Organization (v3.4.0)
- ✅ **Dedicated App Folder**: All app data now stored in `nautune/` subfolder (Linux/macOS/Windows) to keep your Documents directory clean.
- ✅ **Automatic Migration**: Your existing library and settings are moved to the new location on first launch—zero configuration required.
- ✅ **Refined Fullplayer**: Quality indicators (Direct/Transcode) moved below track info for better layout balance on small screens.

## ✨ Key Features
- **Global Search**: Unified search across your entire library with instant results.
- **Smart Offline Mode**: Full support for downloaded content with seamless transition when connectivity is lost.
- **High-Fidelity Playback**: Native backends for all platforms ensuring bit-perfect audio.
- **Visual Palette Extraction**: UI elements dynamically change color based on the current track's artwork.
- **CarPlay Support**: Take your Jellyfin library on the road with a dedicated CarPlay interface.

## 🛠 Technical Foundation
- **Framework**: Flutter (Dart)
- **Local Storage**: Hive (NoSQL) for high-speed metadata caching.
- **Audio Engine**: Audioplayers with custom platform-specific optimizations.
- **Image Processing**: Material Color Utilities for vibrant palette generation.

## 📂 File Structure (Linux)
Nautune follows a clean data structure on Linux for easy backups and management:
- `~/Documents/nautune/`: Primary application data.
- `~/Documents/nautune/downloads/`: High-quality offline audio files.
- `~/Documents/nautune/downloads/artwork/`: Cached album and artist imagery.

---
*Nautune - Rule the waves of your music library.*

## 📸 Screenshots

### Linux
<img src="screenshots/Screenshot_20251105_163913.png" width="400" alt="Nautune on Linux">
<img src="screenshots/Screenshot_20251105_164039.png" width="400" alt="Nautune on Linux">

### iOS
<img src="screenshots/IMG_9047.jpg" width="300" alt="Nautune on iOS">
<img src="screenshots/IMG_9048.jpg" width="300" alt="Nautune on iOS">
<img src="screenshots/IMG_9052.jpg" width="300" alt="Nautune on iOS">

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

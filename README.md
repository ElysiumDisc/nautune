# Nautune 🔱🌊

**Nautune** (Poseidon Music Player) is a high-performance, visually stunning music client for Jellyfin. Built for speed, offline reliability, and an immersive listening experience.

## ✨ Key Features

- **Your Rewind**: Spotify Wrapped-style yearly listening reports with shareable exports
- **ListenBrainz Integration**: Scrobble your plays and get personalized music recommendations
- **Collaborative Playlists**: Real-time SyncPlay sessions - listen together with friends via QR code or share link
- **Custom Color Theme**: Create your own theme with primary/secondary color picker
- **10-Band Equalizer** (Linux): Full graphic EQ with 12 presets (Rock, Pop, Jazz, Classical, and more)
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

### v5.5.5 - TUI Mode (Linux)
- **Terminal UI Mode**: Launch Nautune with a jellyfin-tui inspired terminal interface using `--tui` flag
- **Vim-Style Navigation**: Browse albums, artists, and queue with `j/k/h/l` keys
- **Multi-Key Sequences**: `gg` to go top, `G` to go bottom, just like Vim
- **Playback Controls**: `Space` pause, `n/p` next/prev, `+/-` volume, `S` stop, `c` clear queue
- **Search Mode**: Press `/` to search your library
- **Pane Navigation**: Sidebar and content pane with `h/l` to switch focus
- **ASCII Progress Bar**: Classic `[=========>          ]` style progress display
- **Box-Drawing Borders**: Authentic TUI aesthetic with `│ ─ ┌ ┐ └ ┘` characters
- **Linux Only**: TUI mode is exclusive to the Linux build

### v5.5.3 - View Modes & Download Cleanup
- **List Mode**: Toggle between grid view and compact list view for albums and artists
- **Grid Size Options**: Customize grid density with 2-6 columns per row in Settings > Appearance
- **Offline View Modes**: List/grid preferences apply to offline mode albums and artists
- **Artist Image Cleanup**: Deleting downloads now properly removes associated artist images
- **Download Cleanup**: "Clear All Downloads" now removes both album artwork and artist images folders
- **Backup Fix**: Stats export now properly awaits service initialization for complete data

### v5.5.2 - Stats Backup & PDF Export
- **Stats Backup**: Export all listening data (play history, Rewind stats, Relax mode, Network stats) to JSON backup file
- **Stats Restore**: Import backup file to restore listening history after app reinstall or device migration
- **PDF Rewind Export**: Your Rewind is now exported as a single PDF document instead of stacked PNGs
- **Profile Network Stats**: Network listening stats now appear in your Profile alongside other stats
- **Comprehensive Backups**: Backup includes all-time data, yearly breakdowns, achievements, and easter egg stats

### v5.5.1 - Network Stats & Artwork
- **Top 5 Channels**: Track your most listened Network channels with play count and total time
- **Listening Stats**: View total plays and listening time in Profile screen
- **Artwork Fixes**: Added correct artwork mappings for 50+ channels

### v5.5.0 - The Network (Easter Egg)
- **Other People Radio**: Hidden radio feature with 60+ channels of curated mixes from Nicolas Jaar's Other People label
- **Easter Egg Access**: Search "network" in the library to discover the feature
- **Channel Dial**: Enter any number 0-333 to tune to the nearest channel
- **Save for Offline**: Toggle auto-cache to automatically save channels as you listen
- **Offline Playback**: Downloaded channels work without internet connection
- **Storage Management**: View saved channels with channel numbers, delete individual or all downloads
- **"Signal Found" Milestone**: Unlock a badge for discovering The Network
- **Dark Interface**: Minimalist black UI with ticker-style text animations
- Content from [other-people.network](https://www.other-people.network) - see [Acknowledgments](#-acknowledgments)

### v5.4.9 - Offline Artist Images Fix
- **Offline Artist Images**: Fixed bug where artist images showed default art instead of cached images when browsing offline
- **Artist ID Resolution**: Offline artists now use actual Jellyfin UUIDs from track metadata instead of synthetic IDs, ensuring cached artwork loads correctly

### v5.4.7 - CarPlay Navigation Fix
- **CarPlay Browsing Fix**: Fixed bug where browsing lists (albums, favorites, recently played) stopped loading after playing a track or using the phone app
- **Navigation Stack Protection**: Root template refresh now uses flutter_carplay's `templateHistory` to detect navigation depth, preventing stack corruption while browsing
- **Simplified Callbacks**: Removed unnecessary state management boilerplate from all CarPlay `onPress` handlers

### v5.4.6 - Stats Accuracy, Offline & Rewind UI
- **Rewind UI Refresh**: Fresh, modern card designs with nautical wave decorations and theme-aware gradients
- **Album Color Matching**: Top Album card now extracts colors from album artwork for dynamic gradients
- **All-Time Genre Stats**: Fixed "no genre data" for All-Time Rewind by parsing genres from Jellyfin server
- **Accurate Listening Time**: Fixed bug where full track duration was recorded instead of actual listening time
- **Periodic Analytics Sync**: Play stats now sync to server every 10 minutes when online
- **CarPlay Offline Mode**: CarPlay now works properly in offline mode, showing downloaded content
- **Artist Image Caching**: Artist profile pictures are now downloaded alongside album art for offline viewing
- **2-Year Stats Retention**: Extended listening history from 180 days to 730 days for accurate yearly Rewind stats
- **Period Comparison Fix**: Month-over-month and year-over-year comparisons now use inclusive date ranges
- **Offline Artist Browsing**: Artist images and albums now display correctly when browsing downloaded content offline

### v5.4.5 - Performance Optimizations
- **LRU Cache Eviction**: Memory-bounded caches for images, HTTP ETags, and API responses prevent memory bloat in long sessions
- **List Virtualization**: Added `cacheExtent` to all scrollable lists for smoother 60fps scrolling with 1000+ items
- **Queue Performance**: Fixed-height queue items with `itemExtent: 72` for instant scroll calculations
- **Adaptive Bitrate Streaming**: Auto quality mode now checks network type (WiFi → Original, Cellular → 192kbps, Slow → 128kbps)
- **RepaintBoundary Isolation**: Track tiles wrapped to prevent unnecessary widget repaints during scrolling
- **Code Cleanup**: Fixed all analyzer warnings for clean codebase

### v5.4.0 - Rewind & ListenBrainz
- **Your Rewind**: Spotify Wrapped-style yearly listening stats with swipeable card presentation
- **Rewind Cards**: Total time, top artists, albums, tracks, genres, and listening personality
- **Listening Personality**: Discover your archetype (Explorer, Night Owl, Loyalist, Eclectic, etc.)
- **Year Selector**: View stats for any year or all-time
- **Shareable Exports**: Export Rewind cards as images for social media sharing
- **ListenBrainz Scrobbling**: Automatically log your plays to ListenBrainz
- **Smart Scrobble**: Tracks scrobbled after 50% or 4 minutes of playback
- **Now Playing**: ListenBrainz shows your currently playing track
- **Personalized Recommendations**: Get music recommendations based on your listening history
- **MusicBrainz ID Matching**: Recommendations matched to your Jellyfin library via MBIDs
- **Offline Queue**: Scrobbles queued when offline, synced when back online

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
- **10-Band Graphic Equalizer** (Linux): Full EQ control from 32Hz to 16kHz with 12 presets
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

## 📻 The Network (Easter Egg)

A hidden radio feature [other-people.network](https://www.other-people.network) - Nicolas Jaar's experimental radio project.

### How to Access

1. Go to **Library** tab
2. Search for **"network"**
3. Tap the **"The Network"** card that appears

### Using The Network

- **Channel Dial**: Enter any number between 0-333 to tune to the nearest available channel
- **Channel List**: Browse and tap any of the 60+ available channels
- **Mute**: Toggle audio with the speaker icon in the top bar

### Save for Offline

The Network supports offline listening with auto-caching:

1. Tap the **gear icon** in the top right
2. Enable **"Save for Offline"**
3. Play any channel - it automatically downloads in the background
4. View saved channels in the settings panel with channel numbers and storage size
5. Delete individual channels or clear all from settings

When offline, only your saved channels appear in the list. The app shows an "OFFLINE" indicator when auto-cache is enabled.

### Storage Location

Network downloads are stored separately from your Jellyfin library:
- **Linux**: `~/Documents/nautune/network/audio/`
- **iOS**: `Documents/network/audio/`

### Listening Stats

The Network tracks your listening history:

- **Top 5 Channels**: See your most played channels ranked by listening time
- **Total Stats**: View total play count and cumulative listening time
- Access stats via the **gear icon** in the Network screen

Stats persist across sessions and work for both online streaming and offline playback.

### "Signal Found" Milestone

Discovering The Network unlocks a special nautical milestone badge.

---

## 🖥️ TUI Mode (Linux)

<img src="screenshots/tui.png" width="600" alt="Nautune TUI Mode">

A terminal-inspired interface for keyboard-driven music browsing, inspired by [jellyfin-tui](https://github.com/dhonus/jellyfin-tui).

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

### Keyboard Bindings

| Key | Action |
|-----|--------|
| `j` / `k` | Move selection down/up |
| `h` / `l` | Navigate back/forward (switch panes) |
| `gg` | Go to top of list |
| `G` | Go to bottom of list |
| `Enter` | Play/Select item |
| `Space` | Toggle play/pause |
| `n` / `p` | Next/Previous track |
| `+` / `-` | Volume up/down |
| `m` | Toggle mute |
| `s` | Shuffle queue |
| `r` | Cycle repeat mode |
| `S` | Stop playback |
| `c` | Clear queue |
| `x` / `d` | Delete item from queue |
| `/` | Enter search mode |
| `Esc` | Exit search / Go back |
| `q` | Quit |

### Features

- **Sidebar Navigation**: Browse Albums, Artists, Queue, or Search
- **Vim-Style Movement**: Familiar keybindings for keyboard users
- **Multi-Key Sequences**: 500ms timeout for sequences like `gg`
- **ASCII Progress Bar**: `[=========>          ] 2:34 / 4:12`
- **Volume Indicator**: `Vol: [████████░░] 80%`
- **Now Playing Bar**: Track info, progress, and controls hint
- **Box-Drawing Borders**: Classic TUI aesthetic
- **JetBrains Mono Font**: Crisp monospace rendering

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

## 🔊 FFT Visualizer Platform Support

| Platform | FFT Method | Status |
|----------|-----------|--------|
| Linux | PulseAudio `parec` loopback | ✅ Instant |
| iOS (downloaded) | MTAudioProcessingTap + vDSP | ✅ Instant |
| iOS (streaming) | Cache then tap | ✅ After cache |

---

## 🎵 ListenBrainz Setup Guide

ListenBrainz is a free, open-source music listening tracker. Connect your account to scrobble plays and get personalized music recommendations.

### Step 1: Create a ListenBrainz Account

1. Go to [listenbrainz.org](https://listenbrainz.org)
2. Click **Sign In / Register** in the top right
3. Create a free account (you can use your MusicBrainz account if you have one)

### Step 2: Get Your User Token

1. Log in to [listenbrainz.org](https://listenbrainz.org)
2. Click your username in the top right corner
3. Select **Settings** from the dropdown
4. Or go directly to [listenbrainz.org/settings/](https://listenbrainz.org/settings/)
5. Find the **User Token** section
6. Your token looks like: `1a2b3c4d-5e6f-7g8h-9i0j-k1l2m3n4o5p6`
7. Click **Copy to clipboard**

### Step 3: Connect in Nautune

1. Open Nautune and go to **Settings**
2. Tap **ListenBrainz** under "Your Music"
3. Tap **Connect Account**
4. Enter your ListenBrainz **username**
5. Paste your **User Token**
6. Tap **Connect**

### That's It!

Once connected:
- Tracks automatically scrobble after playing for 50% or 4 minutes
- View your listening history at [listenbrainz.org/user/YOUR_USERNAME](https://listenbrainz.org)
- Recommendations appear based on your listening patterns
- Scrobbles work offline and sync when you're back online

### Troubleshooting

| Issue | Solution |
|-------|----------|
| "Invalid token" error | Re-copy your token from ListenBrainz settings |
| Scrobbles not appearing | Check that scrobbling is enabled in Settings > ListenBrainz |
| Offline scrobbles | They'll sync automatically when you're back online |

---

## 🛠 Technical Foundation
- **Framework**: Flutter (Dart)
- **Local Storage**: Hive (NoSQL) for high-speed metadata caching
- **Audio Engine**: Audioplayers with custom platform-specific optimizations
- **Equalizer**: PulseAudio LADSPA (Linux only)
- **FFT Processing**: Custom Cooley-Tukey (Linux), Apple Accelerate vDSP (iOS)
- **Image Processing**: Material Color Utilities for vibrant palette generation

## 📂 File Structure (Linux)
Nautune follows a clean data structure on Linux for easy backups and management:
- `~/Documents/nautune/`: Primary application data
- `~/Documents/nautune/downloads/`: High-quality offline audio files
- `~/Documents/nautune/downloads/artwork/`: Cached album artwork (stored per-album to save space)
- `~/Documents/nautune/network/audio/`: Network easter egg offline channels
- `~/Documents/nautune/network/images/`: Network channel artwork

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

## 🙏 Acknowledgments

### Other People Network
The "Network" easter egg features audio content from [www.other-people.network](https://www.other-people.network), a creative project by **Nicolas Jaar** and the **Other People** label. The original site was programmed by **Cole Brown** with design by Cole Brown and Against All Logic, featuring mixes from Nicolas Jaar, Against All Logic, and Ancient Astronaut.

All credit for the radio content, artwork, and creative vision belongs to the Other People team. Visit [other-people.network/about](https://www.other-people.network/#/about) for the full credits list.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

**Made with 💜 by ElysiumDisc** | Dive deep into your music 🌊🎵

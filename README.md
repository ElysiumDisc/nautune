# Nautune 🎵🌊

Poseidon's cross-platform Jellyfin music player. Nautune is built with Flutter and delivers a beautiful deep-sea themed experience with smooth native audio playback and seamless Jellyfin integration.

## 🚀 Latest Updates (v1.9.9+)
- **✈️ Robust Airplane Mode Support**: Bulletproof playback control
  - ✅ **Instant Stop**: "Stop" button now kills audio immediately, even without network
  - ✅ **Ghost Playback Fix**: Eliminated issues where music would keep playing if stopped while offline
  - ✅ **Safe Networking**: Network reporting calls are now fail-safe and won't crash the player
  - ✅ **Offline-First Logic**: Player operations prioritize UI responsiveness over server sync
- **🔤 Interactive Alphabet Scrollbar**: Native iOS-style navigation
  - ✅ **Slide-to-Scroll**: Drag finger along the right edge to scrub through lists instantly
  - ✅ **Pop-out Bubble**: Large letter indicator appears next to finger for clear feedback
  - ✅ **Haptic Feedback**: Subtle vibration as you scroll through letters
  - ✅ **Zoom Effect**: Active letter in the bar scales up for better visibility
  - ✅ **Unified Experience**: Available in Albums, Artists, and Genres tabs
- **🌊 Unified Offline UI**: Seamless transition between online and offline states
  - ✅ **Single UI Design**: Offline mode now reuses the main library layout (grids, sorting, design)
  - ✅ **Smart Data Source**: Automatically switches between API and local Hive database
  - ✅ **No Jarring Switches**: Toggling offline mode no longer redirects to a completely different screen
  - ✅ **Consistent Sorting**: Offline content respects the same sorting rules as online content
- **🔧 Track Duration Fix**: Solved the "100x Duration" bug
  - ✅ **Data Healing**: Automatically detects and repairs corrupted duration data in local database
  - ✅ **Standardization**: Switched internal storage to Jellyfin "Ticks" for 100% accuracy
  - ✅ **Migration**: seamless on-the-fly fix for existing users with broken durations

## 🚀 Previous Updates (v1.9.8+)
- **🔧 UI/UX Improvements**: Critical bug fixes for better user experience
  - ✅ **Alphabet scrollbar fix**: Letters in Albums/Artists/Genres tabs are now fully tappable
    - Fixed hit test behavior with `HitTestBehavior.opaque` for reliable touch detection
    - Expanded touch targets from 20px to 28px width for better accessibility
    - Each letter gets equal vertical space for easier navigation
  - ✅ **Downloaded track duration accuracy**: Durations now match actual audio files everywhere
    - Extracts real duration from downloaded audio files using `audioplayers` API
    - Updates track metadata automatically after download completes
    - Favorites tab merges accurate durations from downloaded tracks
    - Fixes issue where server-reported duration didn't match local files
  - ✅ **Fullscreen player artwork reliability**: Album art and gradients always load correctly
    - Fixed gradient extraction to use same fallback logic as artwork display
    - Now properly falls back to album art when track-specific art is missing
    - Gradient background updates immediately when tracks change
  - ✅ **Favorites tab loading performance**: Smoother list rendering without layout shifts
    - Album art wrapped in fixed 56x56 SizedBox to prevent reflow
    - Added placeholder icons that display during image loading
    - List items maintain stable layout as images load asynchronously
  - ✅ **Download queue management fix**: Can now remove items from download queue
    - Fixed bug where queued/downloading items couldn't be removed
    - Cancelling queued downloads now properly removes them from queue
    - Only completed downloads trigger physical file deletion
    - Prevents errors when attempting to delete non-existent files
- **🎵 Fullscreen Player Navigation**: Click artist/album to explore while listening
  - ✅ **Clickable artist**: Tap artist name to open artist detail screen with all their albums
  - ✅ **Clickable album**: Tap album name to see full album tracklist
  - ✅ **Visual indicators**: Underlined text + icons show items are interactive
  - ✅ **Offline support**: Works in airplane mode with downloaded content
  - ✅ **Smart fallback**: Searches online cache first, then creates synthetic objects from downloads
- **🖼️ Offline Album Artwork**: Album art now works perfectly in offline mode
  - ✅ **Auto-download**: Album art automatically downloaded when you download tracks/albums
  - ✅ **Airplane mode ready**: Fullscreen player, favorites, and all tabs show artwork without internet
  - ✅ **Smart fallback**: Checks local storage first, then falls back to network/cache
  - ✅ **Auto-cleanup**: Album art deleted automatically when tracks/albums are removed
  - ✅ **Storage efficient**: Artwork stored as optimized JPEGs in `downloads/artwork/`
- **🎨 UI/UX Refinements**: Better browsing experience
  - ✅ **Alphabet scroll bar**: Quick jump to any letter in Albums, Artists, and Genres tabs
  - ✅ **Artist pagination**: Browse ALL artists (no more stopping at "C")
  - ✅ **Favorites tab album art**: Beautiful artwork thumbnails replace generic music notes
- **🔧 Metadata Consistency**: Fixed audio quality display across all sources
  - ✅ **Consistent fields**: Favorites, playlists, and instant mix now use correct `MediaStreams` field
  - ✅ **Full audio info everywhere**: FLAC • 1411 kbps • 16-bit/44.1kHz displayed in all playback contexts
- **💾 Save Instant Mix as Playlist**: Save your favorite mixes for future listening
  - ✅ **One-tap save**: "Save as Playlist" button appears in snackbar after creating mix
  - ✅ **Smart naming**: Auto-suggests names like "Artist Mix", "Album Mix", "Track Mix"
  - ✅ **Custom names**: Edit the suggested name before saving
  - ✅ **Available everywhere**: Works from artist, album, and track instant mix buttons
  - ✅ **Jellyfin sync**: Saved playlists sync to server immediately
- **🎨 Immersive Fullscreen Player**: Dynamic gradient backgrounds from album art
  - ✅ **Color extraction**: Automatically extracts dominant colors from album artwork
  - ✅ **Gradient background**: Beautiful multi-color gradient with subtle opacity
  - ✅ **Real-time updates**: Background adapts as tracks change with smooth transitions
  - ✅ **Fixed refresh issues**: Album art and gradient now update immediately when track changes
  - ✅ **Removed visualizer**: Cleaner, more focused fullscreen experience
- **🛡️ Download Dependency Tracking**: Intelligent file management
  - ✅ **Reference counting**: Tracks ownership of downloaded files (albums vs playlists)
  - ✅ **Prevents data loss**: Deleting an album won't delete tracks that are also in your playlists
  - ✅ **Smart cleanup**: Only deletes physical files when *all* references are removed
  - ✅ **Context-aware deletion**: "Remove from Download Manager" keeps files if they belong to an album
- **🖼️ Tiered Image Loading**: High-performance artwork caching
  - ✅ **Smart resolution**: Automatically fetches thumbnails for lists and high-res for detail views
  - ✅ **Memory & Disk Caching**: Powered by `cached_network_image` for instant re-loads
  - ✅ **Offline support**: Cached images work perfectly in airplane mode
  - ✅ **Bandwidth saver**: Drastically reduces server load and data usage
- **⚡ Storage Engine Migration**: Complete move to Hive
  - ✅ **Unified storage**: Migrated SharedPreferences to Hive boxes (session, playlists, playback state)
  - ✅ **Better performance**: Faster read/write operations for large datasets
  - ✅ **Structured data**: Type-safe storage for complex objects
  - ✅ **Zero-migration**: Seamlessly transitions data for existing users
- **🍏 iOS Path Verification**: robust offline support for iPhone updates
  - ✅ **Automatic recovery**: Detects when iOS changes app container UUIDs (common on app updates)
  - ✅ **Path rescue**: Automatically finds and relinks downloaded files in the new location
  - ✅ **Self-healing**: Runs on every app startup to ensure your offline library never disappears
- **🎧 Audio Quality Display**: Audiophile-grade metadata in fullscreen player
  - ✅ **Rich audio info**: Shows format, bitrate, sample rate, bit depth, and channel layout
  - ✅ **Example output**: "FLAC • 1411 kbps • 16-bit/44.1 kHz • Stereo"
  - ✅ **Automatic parsing**: Reads MediaStreams data from Jellyfin API
  - ✅ **Beautiful design**: Rounded container with ocean theme styling
  - ✅ **Always visible**: Displayed below album name when metadata is available
- **▶️ Play Next & Queue Management**: Advanced queue control for power users
  - ✅ **Play Next**: Add tracks to play immediately after current song (without disrupting queue)
  - ✅ **Add to Queue**: Append tracks to end of queue
  - ✅ **Available everywhere**: Album tracks, favorites, search results, fullscreen player
  - ✅ **Smart queue handling**: Automatically manages queue indices and pre-loading
  - ✅ **User feedback**: Toast notifications confirm queue operations
- **✨ Instant Mix Integration**: Server-powered music discovery via Jellyfin
  - ✅ **One-tap mixes**: Create 50-track playlists from any track, album, or artist
  - ✅ **Save as playlist**: One-tap save button in snackbar after creating mix
  - ✅ **Smart naming**: Auto-suggests contextual names (Artist/Album/Track Mix)
  - ✅ **Server-side matching**: Jellyfin analyzes music similarity (genre, era, style, audio features)
  - ✅ **Multiple entry points**: Sparkle icon (✨) in album/artist detail screens
  - ✅ **Track context menus**: Instant Mix option in all three-dot menus
  - ✅ **Auto-play**: Mix starts playing immediately after generation
  - ✅ **Smart feedback**: Loading states and error handling for empty results
  - ℹ️ **Note**: Limited to 50 tracks per mix (Jellyfin API default)
- **🔀 UI Polish**: Better iconography across the app
  - ✅ **Shuffle icon**: Replaced emoji (🌊🌊) with proper Material Icons.shuffle
  - ✅ **Consistent design**: Professional icons in album and playlist screens
- **🏗️ Phase 2 Architecture Migration - 90% Complete!**: Major Provider pattern adoption
  - ✅ **9 screens migrated**: SettingsScreen, QueueScreen, FullPlayerScreen, AlbumDetailScreen, ArtistDetailScreen, PlaylistDetailScreen, GenreDetailScreen, OfflineLibraryScreen, and partial LibraryScreen
  - ✅ **Auto-refresh on connectivity**: Detail screens automatically reload when switching online/offline modes
  - ✅ **Smarter state management**: Screens use `Provider.of<NautuneAppState>` instead of parameter passing
  - ✅ **Better separation**: UI components decoupled from god object
  - ✅ **Remaining**: Final LibraryScreen migration (10% - most complex screen with 7 tabs)
- **🎨 Home Screen Redesign**: Clean horizontal-only layout with 6 discovery shelves
  - ✅ **Continue Listening**: Resume tracks from where you left off
  - ✅ **Recently Played**: Tracks you've played recently
  - ✅ **Recently Added**: Latest albums added to your library
  - ✅ **Most Played Albums**: Your most-listened albums
  - ✅ **Most Played Tracks**: Your favorite tracks
  - ✅ **Longest Tracks**: Epic tracks for long listening sessions
  - ✅ **Removed vertical clutter**: Eliminated "Explore Tracks" filter section
  - ✅ **Consistent design**: All shelves follow same horizontal scroll pattern
  - ✅ **Data loading**: Parallel loading of all shelf content on library selection
  - ✅ **Demo mode support**: All shelves work in demo mode with sample data
- **🔄 Smart Auto-Refresh**: Detail screens reactively update on connectivity changes
  - ✅ **Album details**: Automatically reload tracks when going online/offline
  - ✅ **Playlist details**: Refresh when connectivity state changes
  - ✅ **Genre details**: Auto-reload albums when network status changes
  - ✅ **No manual refresh needed**: Seamless experience when airplane mode toggles
  - ✅ **Listen-based updates**: Uses Provider pattern for reactive state changes

## 🚀 Previous Updates (v1.8.3+)
- **⚡ Smart Track Pre-Loading**: Intelligent buffering for truly gapless playback
  - ✅ **70% pre-load trigger**: Automatically loads next track when current reaches 70%
  - ✅ **Platform buffering**: Native audio decoders buffer actual audio data
  - ✅ **Instant transitions**: Near-zero gap between tracks when pre-loaded
  - ✅ **Respects queue & repeat modes**: Works with shuffle, repeat one/all
  - ✅ **Auto-cleanup**: Clears pre-load when queue changes
  - ✅ **Works offline & online**: Pre-loads both streaming and downloaded tracks
- **🧹 Codebase Cleanup**: Removed 100+ lines of dead stream caching code
  - ✅ **Before**: Cached stream URLs (text only, no actual benefit)
  - ✅ **After**: True pre-loading with platform audio buffering
  - ✅ **Result**: Cleaner codebase, better performance
- **🎨 Enhanced Home Tab UI**: Beautiful new layout with better spacing
  - ✅ **Section headers**: Clear "Explore Tracks" label with primary color
  - ✅ **FilterChips instead of SegmentedButton**: Better labels with icons
  - ✅ **Horizontal scrollable**: "Most Played", "History", "New Additions", "Longest"
  - ✅ **Better spacing**: Proper vertical spacing between shelves
  - ✅ **Improved hierarchy**: Clearer visual structure
- **📱 Fixed Demo Mode Transitions**: Seamless offline/demo mode switching
  - ✅ **Demo mode preserved**: Toggling offline library no longer exits demo mode
  - ✅ **Smart detection**: UI-only offline toggle when in demo mode
  - ✅ **No unnecessary syncs**: Demo mode doesn't attempt server refreshes
  - ✅ **Debug logging**: Clear mode transition tracking
- **🎵 Fullscreen Player Redesign**: Optimized layout for better focus
  - ✅ **Larger album art**: Up to 500px/85% width, 50% screen height
  - ✅ **Expanded layout**: Artwork gets 3x vertical space
  - ✅ **Controls pinned to bottom**: All widgets (progress, volume, playback) at bottom
  - ✅ **Better spacing**: Proper vertical distribution
  - ✅ **Enhanced lyrics**: Larger text (24px active, 18px inactive), better line height
- **🖼️ Image Caching**: Persistent disk + memory caching for artwork
  - ✅ **cached_network_image package**: Industry-standard image caching
  - ✅ **Disk cache**: Artwork persists across app restarts
  - ✅ **Memory cache**: Size-optimized for performance
  - ✅ **Reduced network**: Cached images don't re-download
  - ✅ **Faster scrolling**: Smooth album/artist grid browsing
- **🔌 Offline/Online Mode Fixes**: Auto-refresh when network returns
  - ✅ **Network monitoring**: Proper connectivity change detection
  - ✅ **Auto-refresh**: Libraries refresh when internet returns
  - ✅ **Offline mode toggle**: Properly exits offline mode when network available
  - ✅ **Demo mode safe**: Won't trigger refreshes in demo mode

## 🚀 Previous Updates (v1.5.0+)
- **🔧 Architecture Refactoring & Stability**: Major under-the-hood improvements
  - ✅ **Phase 1 Complete**: Core state logic migrated to focused providers (`SessionProvider`, `DemoModeProvider`, etc.)
  - ✅ **Demo Mode Fixed**: Resolved track listing issues, infinite loops, and startup crashes
  - ✅ **Legacy Compatibility**: Seamless bridge between legacy `NautuneAppState` and new architecture
  - ✅ **Solid Foundation**: codebase is now ready for Phase 2 widget refactoring
- **⌨️ Desktop Keyboard Shortcuts**: Full keyboard control for power users (Linux/Windows/macOS)
  - ✅ **Space** - Play/Pause
  - ✅ **Left/Right Arrows** - Seek backward/forward 10 seconds
  - ✅ **Up/Down Arrows** - Volume up/down 5%
  - ✅ **N** - Next track, **P** - Previous track
  - ✅ **R** - Toggle repeat mode
  - ✅ **L** - Toggle favorite
- **🔊 ReplayGain / Normalization**: Automatic volume leveling prevents jumps between albums
  - ✅ Reads `NormalizationGain` from Jellyfin metadata
  - ✅ Applies automatic volume adjustment (dB to linear conversion)
  - ✅ Clamped to safe range (0.1-2.0x) to prevent extremes
  - ✅ Works with streaming and offline playback
  - ✅ No more ear-blasting when switching from quiet classical to loud rock!
- **🎵 Lyrics API Integration**: Full Jellyfin lyrics support (UI coming soon)
  - ✅ `JellyfinClient.fetchLyrics()` retrieves synced lyrics from server
  - ✅ Structured data with timestamps for auto-scrolling
  - ✅ Graceful fallback when lyrics unavailable
  - ✅ Ready for Lyrics UI tab implementation
- **⚡ Crossfade Optimization**: Resource-efficient audio transitions
  - ✅ **Before**: Created new AudioPlayer for every track (memory churn)
  - ✅ **After**: Reuses single `_crossfadePlayer` instance (initialized once)
  - ✅ Drastically reduced memory usage during transitions
  - ✅ Stops/resets player instead of disposing
  - ✅ More stable on mobile devices
- **⚡ Instant Startup + Offline Cache**: Nautune now boots instantly using a local Hive cache for your libraries, playlists, "Continue Listening," and Recently Added.
  - ✅ New bootstrap service hydrates the UI from disk immediately, then refreshes Jellyfin data in the background with smart timeout + retry logic
  - ✅ Startup never blocks on album/artist fetches—slow servers simply update the cache silently once they respond
  - ✅ Library home adds cached hero shelves (“Continue Listening” + “Recently Added”) so the main menu always has content, even offline
  - ✅ Online refreshes merge back into the cache so subsequent launches stay instant
- **🔍 Track Search Toggle**: Search tab now lets you flip between albums, artists, and tracks.
  - ✅ Tracks scope hits your Jellyfin library when online for fully playable results
  - ✅ Offline mode searches downloaded tracks so airplane-mode listening still works
  - ✅ Results drop you straight into playback with one tap
  - ✅ Remembers your last few searches per scope for one-tap re-run or clearing
- **🎛️ External Media Control Stability**: Rock-solid USB-C & Bluetooth controls
  - ✅ **Crash-free skip controls**: Fixed app crashes when using car USB-C or Bluetooth headphones
  - ✅ **Error handling**: Try-catch protection for all external media control inputs
  - ✅ **Repeat mode support**: Skip controls now respect repeat all/one modes
  - ✅ **Boundary safety**: Safe queue navigation at start/end of playlist
- **🎨 Album Card Text Fix**: Perfect text rendering on all platforms
  - ✅ **iOS text overflow fixed**: Album names with long artists no longer cut off
  - ✅ **Optimized line height**: 1.2 line height ensures proper 2-line fitting
  - ✅ **Consistent across platforms**: Works on iOS, Android, Linux, all devices
- **⚡ Smart Track Pre-Loading**: True gapless playback with platform buffering
  - ✅ **Intelligent pre-loading**: Loads next track at 70% of current track
  - ✅ **Platform-level buffering**: Native audio decoders buffer actual audio data
  - ✅ **Instant transitions**: Near-zero gap when track is pre-loaded
  - ✅ **Works everywhere**: Streaming and offline tracks both pre-load
  - ✅ **Queue-aware**: Respects repeat modes and shuffle
- **🎵 Smart Crossfade (Level 2)**: Intelligent audio transitions
  - ✅ **Album-aware crossfade**: Automatically skips crossfade within same album (respects artist intent)
  - ✅ **Smooth exponential curves**: Natural-sounding quadratic fade in/out
  - ✅ **Works offline**: Crossfades both streamed and downloaded tracks
  - ✅ **Settings integration**: One-tap toggle in Audio Options
  - ✅ **Persistent**: Remembers your crossfade preference
  - ✅ **Queue-aware**: Works with repeat modes and shuffle
- **📥 Enhanced Downloads**: Individual track downloads with batch album support
  - ✅ Download single tracks from any screen (long-press or menu)
  - ✅ Download entire albums with one tap
  - ✅ **FLAC/Original Format**: Auto-detects and downloads in native format (FLAC, MP3, M4A, etc.)
  - ✅ Progress tracking for individual tracks and batches
  - ✅ Download cancellation support
  - ✅ Smart duplicate detection (won't re-download existing files)
  - ✅ **Automatic cleanup**: Verifies files on startup and removes orphaned references
  - ✅ **Better error handling**: Clear messages for missing or failed downloads
  - ✅ File format detection from Content-Type headers
- **🎵 Improved Playlist Management**: Full Jellyfin sync with offline queue
  - ✅ **Global playlist loading**: Shows all user playlists regardless of selected library
  - ✅ Create, rename, delete playlists with instant sync
  - ✅ Add tracks/albums to playlists from anywhere
  - ✅ **Offline queue system**: Operations queued when offline, auto-sync when online
  - ✅ **Local caching**: Playlists cached for offline viewing
  - ✅ Track count updates immediately after adding items
  - ✅ **Queue management**: Remove tracks, reorder, shuffle
- **❤️ Favorites Offline Support**: Heart tracks even without connection
  - ✅ Offline queue for favorite actions
  - ✅ Optimistic UI updates (immediate visual feedback)
  - ✅ Automatic sync when connection returns
  - ✅ Orange notification messages for queued actions
- **🎨 Refined Settings**: Streamlined audio options
  - ✅ Removed redundant playback/download sections
  - ✅ **Crossfade feature**: Album-aware toggle for smooth transitions
  - ✅ Cleaner, more focused settings UI
- **🗂️ Library Selection Filter**: Only music libraries shown
  - ✅ Playlists no longer appear as selectable libraries
  - ✅ Only "music" collection type shown on login
  - ✅ Cleaner library selection experience
- **💿 Multi-Disc Album Support**: Proper handling of multi-disc releases
  - ✅ Disc number grouping in album detail view
  - ✅ Disc separators with clear labeling (Disc 1, Disc 2, etc.)
  - ✅ Correct track ordering across discs
  - ✅ Preserves disc structure in queue and playback
- **🎚️ Volume Slider**: Direct audio control in now playing bar
  - ✅ Real-time volume adjustment via slider
  - ✅ Wired directly to audio player for instant response
  - ✅ Volume level persisted across sessions
- **🛫 Offline-First Boot**: App now boots directly into offline mode when no internet is available, giving instant access to downloaded music even in airplane mode or dead zones.
  - ✅ Connectivity probe (connectivity_plus + DNS lookup) detects real internet reachability before Jellyfin refreshes begin
  - ✅ 10-second timeout prevents infinite spinning on network failure
  - ✅ Graceful network failure handling during initialization
  - ✅ Cached credentials preserved for when connectivity returns
  - ✅ Offline banner with retry button shows when network is unavailable
  - ✅ Automatic sync when connectivity is restored
- **🚗 CarPlay Fix**: Fixed CarPlay not appearing on iOS devices by properly calling `FlutterCarplay.setRootTemplate()` during initialization
  - ✅ CarPlay icon now appears on CarPlay-enabled head units
  - ✅ Safe async initialization prevents iOS black screen
  - ✅ Graceful fallback if CarPlay fails
- **🐧 Linux Icon**: Added `linux/nautune.png` and desktop file for proper Linux desktop integration
- Reworked iOS bootstrap with a shared `FlutterEngine`, SceneDelegate, and Info.plist scene manifest so `flutter_carplay` can launch reliably on CarPlay-equipped head units (see `ios/Runner/AppDelegate.swift`, `SceneDelegate.swift`, and `Info.plist`).
- Deferred `NautuneAppState.initialize()` work and CarPlay setup to run after the first Flutter frame, preventing black-screen hangs caused by plugin initialization failures.
- Hardened startup logging (`Nautune initialization started/finished`) to make it easier to diagnose device issues from Xcode or `flutter logs`.
- CarPlay integrations now match Jellyfin data more accurately by tracking album artist IDs and forwarding precise playback positions to the Jellyfin server.

## 🏗️ Architecture Improvements (Phase 1 Complete, Phase 2: 90% Complete!)

Nautune has undergone a major architectural refactoring to improve performance, maintainability, and scalability:

### ✅ Phase 2: Provider Pattern Migration (90% Complete!)

**Goal**: Migrate all screens from parameter-passing to Provider pattern for better state management

**Completed Screens (9/10)**:
1. **SettingsScreen** - Uses SessionProvider + UIStateProvider
2. **QueueScreen** - Uses Provider for audio service access
3. **FullPlayerScreen** - Migrated with didChangeDependencies pattern
4. **AlbumDetailScreen** - Auto-refreshes on connectivity changes
5. **ArtistDetailScreen** - Uses Provider pattern
6. **PlaylistDetailScreen** - Auto-refreshes on connectivity changes
7. **GenreDetailScreen** - Auto-refreshes on connectivity changes
8. **OfflineLibraryScreen** - Clean Provider-based implementation
9. **LibraryScreen (Partial)** - Home tab fully refactored with 6 horizontal shelves

**Remaining**:
- **LibraryScreen (Complete)** - Most complex screen with 7 tabs, final migration pending

**Key Improvements**:
- ✅ **Auto-refresh capability**: Detail screens detect connectivity changes and reload automatically
- ✅ **Cleaner constructors**: Screens no longer need appState as parameter
- ✅ **Better testability**: Screens can be tested with mock providers
- ✅ **Reactive updates**: UI automatically rebuilds when state changes
- ✅ **Consistent pattern**: All screens follow same state access approach

### ✅ Download Service Migration to Hive
- **Before**: Entire download database stored as a single JSON string in SharedPreferences
- **After**: Hive-based structured storage with individual record access
- **Impact**: ⚡ Instant save/load even with 1000+ downloads, no more UI jank
- **Migration**: Automatic one-time migration from old format

### ✅ State Management Refactoring
The monolithic `NautuneAppState` (1674 lines) has been split into focused, testable providers:

#### **SessionProvider** (200 lines)
- Handles authentication, login/logout, session persistence
- Independent and unit-testable
- Single responsibility: auth only

#### **UIStateProvider** (120 lines)
- Manages UI-only state (volume bar, crossfade, scroll positions, tab index)
- **Key win**: Toggling volume bar now rebuilds 1 widget instead of 1000+!
- Completely independent from session/data concerns

#### **LibraryDataProvider** (600 lines)
- All library data fetching and caching (albums, artists, playlists, tracks, genres)
- Pagination support for large libraries
- Loading states and error handling
- Depends on SessionProvider for auth context

#### **ConnectivityProvider** (70 lines)
- Network connectivity monitoring
- Provider-compatible wrapper around ConnectivityService

#### **DemoModeProvider** (240 lines)
- Demo mode content and state management
- Isolated from production data
- Coordinates with SessionProvider and DownloadService

### Performance Comparison

| Action | Before | After |
|--------|--------|-------|
| Toggle volume bar | Rebuild 1000+ widgets | Rebuild 1 widget |
| Save downloads | Encode ALL downloads to JSON | Save only changed data to Hive |
| Test auth logic | Impossible (god object) | Easy (SessionProvider unit test) |
| Fetch albums | Rebuild entire app | Rebuild album list only |

### Benefits
- ⚡ **Performance**: Granular rebuilds, no more full-app updates for UI changes
- 🧪 **Testability**: Each provider can be unit tested independently
- 🔧 **Maintainability**: Small focused classes (100-600 lines vs 1674)
- 👨‍💻 **Developer Experience**: Clear separation of concerns, easy to extend
- 🚀 **Future-Proof**: Ready for Phase 2 features (EQ, Lyrics, Scrobbling)

**Status**: Phase 2 (Widget Refactoring) - **90% complete!** 9 out of 10 screens migrated to Provider pattern with auto-refresh capability.

---

## 🧪 Review / Demo Mode

Apple's Guideline 2.1 requires working reviewer access. Nautune includes an on-device demo that mirrors every feature—library browsing, downloads, playlists, CarPlay, and offline playback—without touching a real Jellyfin server.

1. **Credentials**: leave the server field blank, use username `tester` and password `testing`.
2. The login form detects that combo and seeds a showcase library with open-source media. Switching back to a real server instantly removes demo data (even cached downloads).
3. Demo mode is documented in `assets/demo/README.md`, which also lists licensing notes for the bundled tracks and artwork.

### Demo assets recap

- Streaming samples (bundled MP3s for demo mode only):
  - `assets/demo/demo_online_track.mp3` – “Ocean Vibes” from Pixabay (track: https://pixabay.com/music/beats-ocean-vibes-391210/ · Pixabay License).
  - `assets/demo/demo_offline_track.mp3` – “Sirens and Silence” from Pixabay (track: https://pixabay.com/music/modern-classical-sirens-and-silence-10036/ · Pixabay License). This file also powers the offline/download view so reviewers see a real track in airplane mode.
- Artwork: intentionally uses the shared fallbacks `assets/no_album_art.png` and `assets/no_artist_art.png`, making it easy to drop in a branded placeholder that demo + production both inherit.

## ✨ Highlights

### 🎵 Audio & Playback
- **Native Engine**: Powered by `audioplayers` with platform-specific backends
  - 🍎 **iOS/macOS**: AVFoundation (hardware-accelerated, native FLAC support)
  - 🐧 **Linux**: GStreamer (native multimedia framework with FLAC codec)
  - 🤖 **Android**: MediaPlayer
  - 🪟 **Windows**: WinMM
- **Gapless Playback**: True seamless transitions with intelligent pre-loading
  - ✅ **70% pre-load trigger**: Next track loads at 70% of current track
  - ✅ **Platform buffering**: Native decoders buffer actual audio data
  - ✅ **Instant playback**: Pre-loaded tracks start immediately
  - ✅ **Works offline**: Pre-loads both streaming and downloaded tracks
  - ✅ **Auto-cleanup**: Clears pre-load when queue changes
- **External Control Support**: Rock-solid media controls from any source
  - ✅ USB-C audio devices (car head units, dongles)
  - ✅ Bluetooth headphones and speakers
  - ✅ Lock screen controls on iOS/Android
  - ✅ Crash-proof error handling
  - ✅ Repeat mode aware navigation
- **Direct Play Only**: Always streams original Jellyfin files in native format (FLAC/AAC/etc.)
  - ✅ No transcoding - preserves audio quality
  - ✅ Native platform decoders handle all formats
  - ✅ Reduced server load
- **Original Quality Downloads**: Downloads always use original lossless format (FLAC preferred)
  - ✅ Auto-detects format from Content-Type header (FLAC, MP3, M4A, OGG, OPUS, WAV)
  - ✅ Preserves native audio quality
  - ✅ No transcoding or quality loss
  - ✅ Automatic file verification on startup
  - ✅ Cleanup of orphaned download references
- **Album Queueing**: One tap queues the whole album in disc/track-number order with seamless previous/next navigation
- **Play Next & Queue Control**: Advanced queue management for power users
  - ✅ **Play Next**: Insert tracks immediately after current song
  - ✅ **Add to Queue**: Append tracks to end of queue
  - ✅ **Available everywhere**: Three-dot menus on tracks in albums, favorites, search, fullscreen player
  - ✅ **Smart handling**: Manages queue indices and pre-loading automatically
- **Instant Mix**: AI-powered music discovery via Jellyfin
  - ✅ **One-tap radio**: Create 50-track mixes from any track, album, or artist
  - ✅ **Save as playlist**: One-tap save from snackbar after creation
  - ✅ **Smart naming**: Auto-suggests contextual playlist names
  - ✅ **Server intelligence**: Jellyfin analyzes musical similarity
  - ✅ **Multiple triggers**: Sparkle icon (✨) in detail screens + track menus
  - ✅ **Auto-play**: Starts playing immediately
- **Advanced Playback State Persistence**: Complete session restoration
  - ✅ Saves current track, position, queue, repeat mode, shuffle state
  - ✅ Preserves volume level and UI preferences (library tab, scroll positions)
  - ✅ Smart restoration: automatically resumes from last position on launch
  - ✅ **Pause preserves queue**: Pausing saves queue for next session
  - ✅ **Stop clears queue**: Stop button intentionally clears queue (fresh start)
  - ✅ **App resume**: Background/foreground restores playback exactly where you left off
  - ✅ Position saved every second for accurate resume
- **Shuffle & Repeat**: Full playback control
  - ✅ Shuffle mode: Randomizes queue while keeping current track
  - ✅ Repeat modes: Off, All (repeat queue), One (repeat current track)
  - ✅ State persisted across sessions
  - ✅ Visual indicators for active modes
- **Background Audio**: Keeps playing while the app is in the background
- **Volume Control**: Direct audio volume adjustment with persistent slider in now playing bar
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
  - ✅ Seek controls on lock screen
  - ✅ Background playback state tracking
  - ✅ **Full CarPlay integration** powered by flutter_carplay plugin
  - ✅ CarPlay library browsing (albums, artists, playlists, favorites, downloads)
  - ✅ CarPlay supports offline playback with downloads (airplane mode works!)
  - ✅ Tab-based navigation optimized for car displays
  - ✅ Seamless integration with iOS audio session
  - ✅ Clean, focused car-friendly UI

### 🌊 Visual Experience
- **Waveform Progress**: Real waveform from Jellyfin API with intelligent caching per track
- **Scrubbable Mini Player**: Waveform strip and slider both seek playback instantly
- **Now Playing Bar**: Always-visible controls, real-time progress indicator, and quick access to the full player
- **Full Screen Player**: Auto-updating UI with StreamBuilder - play/pause, progress bar, and track info always in sync
  - ✅ Compact, centered button layout optimized for mobile devices
  - ✅ All playback controls in one row (favorite, skip, stop, play/pause, next, repeat)
  - ✅ Visual indicators for active repeat/shuffle modes
  - ✅ **Dynamic Gradient Background**: Automatically extracts colors from album art and creates a beautiful blurred gradient backdrop
  - ✅ **Immersive Experience**: Gradient colors update in real-time when tracks change, matching the album artwork
- **Deep Sea Purple Theme**: Oceanic gradient color scheme with light purple "Nautune" title (Pacifico font)
- **Album & Artist Art**: Beautiful grid and list layouts with Jellyfin artwork (trident placeholder fallback)
  - ✅ **Perfect text rendering**: Fixed iOS text overflow on album cards
  - ✅ Optimized line height prevents cutoff with long artist names
  - ✅ Consistent 2-line display across all platforms
- **Smart Crossfade**: Smooth audio transitions between tracks
  - ✅ Album-aware: No crossfade within same album (preserves artist's vision)
  - ✅ Simple toggle in settings
  - ✅ Exponential fade curves for natural sound
  - ✅ Works with streaming and offline playback

### 📚 Library Browsing
- **✅ Albums Tab**: Grid view with paginated loading (50 albums per page), album artwork, year, and artist info - click to see tracks
- **✅ Artists Tab**: Browse all artists with paginated loading (50 per page) and circular profile artwork - click to see their albums
- **✅ Genres Tab**: Browse music by genre - click any genre to see all albums with that tag (server-filtered)
- **✅ Home Tab**: Beautiful discovery dashboard with 6 horizontal shelves
  - **Continue Listening**: Resume tracks from where you left off with horizontal track chips
  - **Recently Played**: Tracks you've played recently in horizontal scrollable list
  - **Recently Added**: Latest albums added to your library with album artwork
  - **Most Played Albums**: Your most-listened albums in horizontal grid
  - **Most Played Tracks**: Your favorite tracks in horizontal scrollable list
  - **Longest Tracks**: Epic tracks for long listening sessions
  - All content is playable with tap-to-play functionality
  - Horizontal-only layout for clean, consistent experience
  - **Smart Tab Switching**: Automatically becomes "Downloads" tab when in offline mode
- **✅ Instant Mix**: Server-powered music discovery creates 50-track playlists
  - ✅ **From any source**: Generate mixes from tracks, albums, or artists
  - ✅ **Save as playlist**: One-tap save button after mix creation with smart naming
  - ✅ **Sparkle icon (✨)**: Quick access in album/artist detail screens
  - ✅ **Track menus**: Instant Mix option in all three-dot menus
  - ✅ **Auto-play**: Mix starts playing immediately after generation
  - ✅ **Jellyfin matching**: Server analyzes music similarity (genre, era, style, audio features)
- **✅ Play Next & Add to Queue**: Full queue control from any track menu
  - ✅ **Play Next**: Insert track(s) immediately after current song
  - ✅ **Add to Queue**: Append track(s) to end of queue
  - ✅ **Smart feedback**: Toast notifications confirm actions
  - ✅ **Queue management**: Automatic index handling and pre-load clearing
- **✅ Offline Mode Toggle**: Wave icon (🌊) switches between online Jellyfin library and offline downloads
  - **Tap**: Toggle online/offline mode (violet = offline, light purple = online)
  - **Home Tab**: Automatically becomes Downloads management when offline
  - **Search Tab**: Searches downloaded content only when offline
  - **🛫 Offline-First Boot**: App automatically enters offline mode if network is unavailable during startup (10-second timeout)
  - **Network Banner**: Visual indicator when offline with retry button to restore connection
  - **Seamless Recovery**: Automatically syncs when internet returns
- **✅ Recent Tab**: Toggle between recently played tracks (from Jellyfin history) and recently added albums with segmented control
- **✅ Favorites Tab**: Jellyfin favorites integration with offline queue support
  - ✅ Mark tracks/albums as favorites
  - ✅ View favorite tracks list
  - ✅ Sync favorites with Jellyfin server
  - ✅ Toggle favorite state with heart icon
  - ✅ **Offline queue**: Favorite actions queued when offline, synced when connection returns
  - ✅ **Optimistic updates**: UI updates immediately even when offline
- **✅ Playlists Tab**: Full playlist management with Jellyfin sync and offline persistence
  - ✅ Create new playlists (queued when offline)
  - ✅ Edit/rename playlists (three-dot menu or detail screen)
  - ✅ Delete playlists with confirmation dialog
  - ✅ View all tracks in playlist detail screen
  - ✅ Add albums/tracks to playlists (long-press on albums, menu on tracks)
  - ✅ Remove tracks from playlists
  - ✅ Play playlists with queue support
  - ✅ All changes sync to Jellyfin server instantly
  - ✅ **Offline queue**: Playlist operations queued when offline, synced when connection returns
  - ✅ **Local cache**: Playlists cached locally for offline viewing
  - ✅ **Auto-refresh**: Track counts update immediately after adding items
- **✅ Downloads Tab**: Full offline download support with original quality (FLAC/lossless), progress tracking, album batch downloads, individual track downloads, and file management
  - ✅ **Download Albums**: Tap download icon on album cards or in album detail view
  - ✅ **Download Tracks**: Long-press or use menu button on individual tracks
  - ✅ **Progress Tracking**: Real-time progress bars for downloads
  - ✅ **Cancellation**: Cancel in-progress downloads anytime
  - ✅ **Smart Detection**: Won't re-download existing files
  - ✅ **Original Quality**: Always downloads lossless format (FLAC, MP3, M4A auto-detected)
  - ✅ **File Verification**: Checks files exist on startup, removes orphaned references
  - ✅ **Better Error Handling**: Clear messages when files are missing or unavailable
- **✅ Offline Library**: Click wave icon (🌊) to browse downloads by album or artist - **works in airplane mode!**
- **✅ Settings**: Click "Nautune" title to view server info and about section (native quality playback always enabled)
- **✅ Favorite Button**: Heart icon in fullscreen player synced with Jellyfin favorites API
- **✅ Queue View**: Browse and reorder currently queued tracks via queue button in now playing bar
- **Track Listings**: Full album detail screens with ordered track lists, durations, and padded numbers (multi-disc aware with disc separators)
  - ✅ **Multi-Disc Support**: Disc separators (Disc 1, Disc 2, etc.) for box sets and compilations
  - ✅ **Proper Ordering**: Tracks sorted by disc number then track number
  - ✅ **Disc Grouping**: Visual separation between discs for clarity
- **Artist Discography**: View all albums by an artist
- **Bottom Navigation**: Icon-only rail keeps the most-used sections a single tap away on every platform
- **Library Search Tab**: Dedicated search experience for quickly finding albums by name, showing artist and year context
- **Smart Refresh**: Pull-to-refresh on all tabs for latest content sync
- **Add to Playlist**: Long-press albums, use menu button on tracks, or toolbar button in album detail to add content to any playlist

### 🎯 Jellyfin Integration
- **Direct Streaming**: Streams music directly from your Jellyfin server with adaptive quality
- **Album Browsing**: View all albums with high-quality artwork and metadata
- **Favorites API**: Full Jellyfin favorites integration with offline queue
  - ✅ Mark tracks/albums as favorites from fullscreen player
  - ✅ View favorite tracks in Favorites tab
  - ✅ Favorites sync with Jellyfin server instantly
  - ✅ Heart icon toggles favorite state
  - ✅ **Offline queue**: Favorite actions queued when offline
  - ✅ **Optimistic UI updates**: Changes visible immediately
  - ✅ **Automatic sync** when connection returns
- **Playlist Support**: Full Jellyfin playlist integration with real-time sync and offline queue
  - ✅ Create playlists on server
  - ✅ Rename/edit playlists
  - ✅ Delete playlists
  - ✅ Add albums and tracks to playlists
  - ✅ Remove tracks from playlists
  - ✅ All changes persist on Jellyfin server
  - ✅ **Global playlist loading**: Shows all user playlists (not library-filtered)
  - ✅ **Offline operations queued** for sync when connection returns
  - ✅ **Local playlist cache** for offline viewing
  - ✅ **Automatic sync** on app startup and when going online
  - ✅ **Track count auto-refresh** after adding items
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
  - ✅ **Offline-First Boot**: App starts in offline mode automatically when no network is available
  - ✅ Automatic offline playback when file exists (no internet required)
  - ✅ Always downloads original format (FLAC, MP3, M4A auto-detected from server)
  - ✅ **File verification**: Checks files exist on startup, removes broken references
  - ✅ **Better error handling**: Shows clear messages for missing downloads
  - ✅ **iOS CarPlay supports offline downloads** - browse and play in car without internet
  - ✅ Download progress tracking and cancellation
  - ✅ Batch album downloads

### Offline Boot Troubleshooting
- If you previously ran Nautune before the new connectivity boot logic, the cached Hive data may use legacy map types. A `_Map<dynamic, dynamic>` cast error on launch means the cache needs to be cleared.
- Delete the `nautune_cache.*` files in the platform data directory (e.g., Linux: `~/.local/share/nautune/`, macOS: `~/Library/Application Support/nautune/`, Windows: `%LOCALAPPDATA%\nautune\`). The app will rebuild the cache automatically on the next successful sync.
- After clearing the cache, you can start the app offline—ConnectivityService will detect the missing network and the Library screen will immediately show downloads.

## 📸 Screenshots

### Linux
<img src="screenshots/Screenshot_20251105_163913.png" width="400" alt="Nautune on Linux">
<img src="screenshots/Screenshot_20251105_164039.png" width="400" alt="Nautune on Linux">

### iOS
<img src="screenshots/IMG_9047.jpg" width="300" alt="Nautune on iOS">
<img src="screenshots/IMG_9048.jpg" width="300" alt="Nautune on iOS">
<img src="screenshots/IMG_9052.jpg" width="300" alt="Nautune on iOS">

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
flutter_carplay: ^1.1.4   # iOS CarPlay integration with tab-based UI

# Network & Connectivity
connectivity_plus: ^7.0.0  # ConnectivityService uses DNS probes to decide if we should boot offline

# Data & State
shared_preferences: ^2.3.2 # Persistent storage for sessions and playback state
http: ^1.2.2               # Jellyfin API communication
```

## 🏗️ Architecture

```
lib/
├── providers/             # NEW! State management providers (Phase 1 refactoring)
│   ├── session_provider.dart         # Auth, login, logout (200 lines)
│   ├── ui_state_provider.dart        # UI state only (120 lines)
│   ├── library_data_provider.dart    # Data fetching & caching (600 lines)
│   ├── connectivity_provider.dart    # Network monitoring (70 lines)
│   └── demo_mode_provider.dart       # Demo mode management (240 lines)
├── jellyfin/              # Jellyfin API client, models, session management
│   ├── jellyfin_client.dart
│   ├── jellyfin_service.dart
│   ├── jellyfin_session.dart
│   ├── jellyfin_session_store.dart
│   ├── jellyfin_album.dart
│   ├── jellyfin_track.dart
│   ├── jellyfin_artist.dart
│   ├── jellyfin_playlist.dart
│   └── jellyfin_library.dart
├── models/                # App data models
│   ├── playback_state.dart
│   └── download_item.dart
├── screens/               # UI screens
│   ├── login_screen.dart
│   ├── library_screen.dart (with 7 tabs!)
│   ├── album_detail_screen.dart
│   ├── artist_detail_screen.dart
│   ├── playlist_detail_screen.dart
│   └── full_player_screen.dart
├── services/              # Business logic layer
│   ├── audio_player_service.dart      # Native audio playback
│   ├── download_service.dart          # NEW! Hive-based downloads
│   ├── local_cache_service.dart       # Hive cache for metadata
│   ├── playback_state_store.dart      # Persistent playback state
│   ├── bootstrap_service.dart         # Fast startup with caching
│   ├── connectivity_service.dart      # Network detection
│   └── carplay_service.dart           # iOS CarPlay integration
├── widgets/               # Reusable components
│   ├── now_playing_bar.dart (with waveform!)
│   ├── album_card.dart
│   └── track_list_item.dart
├── theme/                 # Deep Sea Purple theme
│   └── nautune_theme.dart
├── app_state.dart         # Legacy state (being phased out → providers)
└── main.dart              # App entry point
```

### State Management Evolution

**Before (Legacy)**:
- `app_state.dart`: 1674-line god object managing everything
- Every state change rebuilds the entire app

**After (Phase 1)**:
- **5 focused providers** with single responsibilities
- Granular rebuilds (only affected widgets update)
- Easy to test and maintain
- Clear separation of concerns

See **Architecture Improvements** section above for details!

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
- **Complete Session Restoration**: Full playback state saved and restored
  - ✅ Current track, position, queue, album context
  - ✅ Repeat mode (off/all/one) and shuffle state
  - ✅ Volume level and UI preferences (library tab, scroll positions)
  - ✅ Show/hide volume bar preference
- **Smart Restoration**: Automatically resumes from last position on app launch
- **Intelligent Queue Handling**:
  - ✅ **Pause saves queue**: Pausing preserves queue for next session
  - ✅ **Stop clears queue**: Stop button intentionally clears everything (fresh start)
  - ✅ **App resume**: Background/foreground restores playback exactly where you left off
- **Real-time Saving**: Position saved every second for accurate resume
- **Stored in Hive**: Persists across app restarts and force-closes via fast, local storage

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

- **Linux**: Builds with `flutter build linux --release`
  - ✅ Native GStreamer audio backend (FLAC/lossless support)
  - ✅ Desktop icon included (`linux/nautune.png` + `nautune.desktop`)
  - ✅ Offline downloads stored in project `downloads/` directory
  - ✅ All Jellyfin features work on Linux
- **iOS**: Builds produced by **Codemagic CI** with full feature support
  - ✅ **Native audio playback** via AVFoundation (FLAC/AAC/lossless support)
  - ✅ **Lock screen controls** with album artwork via audio_service
  - ✅ **Full CarPlay integration** - browse library, playlists, favorites, downloads in car mode
  - ✅ **Offline downloads** stored in app documents (airplane mode compatible)
  - ✅ CarPlay works fully offline with downloaded content
  - ✅ All Jellyfin features work on iOS (playback reporting, favorites sync, playlist management)
- **Windows**: `flutter build windows` (requires Windows machine with VS 2022)
- **macOS**: `flutter build macos` (requires macOS with Xcode)
- **Web**: `flutter run -d chrome` for dev, `flutter build web` for production
- **Android**: Not currently a focus; no Android SDK required for development

> **Development Tip**: Keep your Linux environment Snap-free. Use official Flutter tarball or FVM. Codemagic handles iOS builds automatically.

### 🚗 CarPlay Support (iOS Only)

Nautune includes **full CarPlay integration** for iOS powered by the `flutter_carplay` plugin:

#### ✅ Features
- **Tab Navigation**: Library, Favorites, Downloads tabs with car-friendly segmented controls
- **Library Browsing**: Browse albums, artists, and playlists while driving
- **Track Playback**: Play any track directly from CarPlay with full queue support
- **Offline Support**: Browse and play downloaded music in airplane mode (no internet required)
- **Native Integration**: Uses flutter_carplay plugin for seamless iOS integration
- **Clean UI**: Optimized for minimal distraction while driving

#### 🔧 Implementation Details
- **Flutter CarPlay Plugin**: `flutter_carplay: ^1.1.4` handles all CarPlay UI and interactions
- **CarPlay Service**: `lib/services/carplay_service.dart` - connects CarPlay to app state
- **Info.plist Configuration**: 
  - UIBackgroundModes with `audio` for background playback
  - CarPlay entitlements in `ios/Runner/Runner.entitlements`:
    - `com.apple.developer.carplay-audio`
    - `com.apple.developer.playable-content`
- **Dart-Only Implementation**: All CarPlay logic is in Dart - no custom Swift code needed
- **Offline Downloads**: iOS stores downloads in app documents directory - accessible even offline
- **Lock Screen Controls**: Album artwork, play/pause, skip buttons via audio_service plugin

#### 🧪 Testing CarPlay
CarPlay requires one of the following:
- **Physical Device**: iPhone with CarPlay-enabled car or CarPlay-compatible head unit
- **iOS Simulator**: Xcode → I/O → External Display → CarPlay window

The CarPlay interface automatically appears when connected to a CarPlay system. Uses flutter_carplay's CPTabBarTemplate for tab navigation!

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
- [x] **Multi-disc album support with disc separators**
- [x] **Audio playback with native engine (direct streaming)**
- [x] **Advanced playback state persistence** (track, position, queue, repeat, shuffle, volume, UI state)
- [x] **Intelligent queue persistence** (pause saves queue, stop clears, app resume restores perfectly)
- [x] **Shuffle mode** with queue randomization
- [x] **Repeat modes** (off/all/one) with persistence
- [x] **Gapless playback** with track preloading
- [x] **Smart stream caching** - preloads 5 upcoming tracks for smooth playback
- [x] **External media control stability** - crash-free USB-C/Bluetooth controls
- [x] **Album card text fixes** - perfect rendering on iOS and all platforms
- [x] **Native FLAC Playback**: Uses direct download URLs for original quality, platform decoders handle FLAC/AAC/etc. natively
- [x] **Jellyfin Playback Reporting integration** for activity tracking
- [x] **Individual track downloads** with progress tracking
- [x] **Album batch downloads** with cancellation support
- [x] **Smart download detection** (no duplicate downloads)
- [x] **FLAC/Original format downloads** - auto-detects format from server
- [x] **Download verification** - checks files on startup
- [x] **Orphaned reference cleanup** - removes missing downloads automatically
- [x] **Better playback error handling** - clear messages for unavailable files
- [x] **Recent tab with toggle** between recently played and recently added
- [x] **iOS CarPlay** powered by flutter_carplay plugin with full library browsing (albums, artists, playlists, favorites, downloads) and **offline support**
- [x] **Home Tab with 6 horizontal shelves**: Continue Listening, Recently Played, Recently Added, Most Played Albums, Most Played Tracks, and Longest Tracks (all playable with tap-to-play)
- [x] **Waveform visualization** using Jellyfin's waveform API with per-track caching
- [x] **Tabbed navigation (Albums/Artists/Search/Favorites/Recent/Playlists/Downloads)** - 7 tabs total
- [x] **Settings screen** with transcoding options accessible from app title
- [x] **Now playing bar with controls and real-time waveform**
- [x] **Full-screen player** with auto-updating UI (play/pause state, progress bar synced)
- [x] **Volume slider** wired directly to `audioPlayer.setVolume()` for instant gain control with persistent show/hide preference
- [x] **Headphone interruption handling** via `audio_session` (pause/resume & noisy events)
- [x] **Favorite button** in fullscreen player with offline queue support
  - [x] Heart icon synced with Jellyfin API
  - [x] Offline queue for favorite actions
  - [x] Optimistic UI updates (immediate feedback)
  - [x] Automatic sync when connection returns
- [x] **Full playlist management with Jellyfin integration and offline support**
  - [x] Create playlists on Jellyfin server
  - [x] Rename/edit playlists
  - [x] Delete playlists with confirmation
  - [x] Add albums to playlists (long-press on album cards)
  - [x] Add tracks to playlists (menu button on tracks)
  - [x] Playlist detail screen with track list
  - [x] Remove tracks from playlists
  - [x] All changes sync to server instantly
  - [x] **Global playlist loading** - shows all playlists regardless of library
  - [x] **Offline queue system** - operations queued when offline
  - [x] **Local playlist cache** for offline viewing
  - [x] **Automatic background sync** when connection returns
  - [x] **Auto-refresh** - playlist track counts update immediately
- [x] **Click tracks to play from any album**
- [x] **Click artists to see their discography**
- [x] **Back buttons on all detail screens**
- [x] **Responsive layout** (adapts between mobile and desktop)
- [x] **iOS lock screen controls** with album artwork and full playback control
- [x] **Offline album artwork** - artwork automatically downloaded with tracks and displayed in airplane mode
- [x] **Offline search** - search downloaded content without internet connection
- [x] **Fixed offline mode toggle** - wave icon tap now works correctly
- [x] **Offline album detail navigation** - tapping albums in offline mode opens detail instead of immediate playback
- [x] **🛫 Offline-first boot** - app gracefully handles no network at startup and boots directly into offline mode with downloaded content
- [x] **📄 Pagination** - albums and artists load 50 at a time with infinite scroll for smooth performance on large libraries
- [x] **🎯 Library selection filter** - only music libraries shown (no playlists, audiobooks, or videos)
- [x] **🎵 Smart Crossfade (Level 2)** - album-aware audio transitions
  - [x] Album-aware logic (no crossfade within same album)
  - [x] Exponential fade curves (natural sound)
  - [x] Settings integration with simple toggle
  - [x] Works with both streaming and offline
  - [x] Persistent preference

### 🚧 In Progress / Planned
- [ ] **AirPlay Support** (iOS/macOS) - Stream to HomePod, Apple TV, and AirPlay speakers
  - AVRoutePickerView integration for native AirPlay picker
  - System audio routing for external playback
  - Control surface in player UI
  - Platform fallback for non-Apple devices
- [ ] **Equalizer and audio settings** - Fine-tune audio output with presets and custom EQ
- [ ] **Sorting options** - Sort albums/artists by name, date added, year, or play count
- [ ] **Cross-platform stability** - Enhanced Windows, macOS, and Android support
- [ ] **Smart Downloads** - Auto-download favorites and keep last 50 played songs offline
- [ ] **Infinite Radio Mode** - Endless playback that auto-generates next track when queue is low

## 🌊 The "Poseidon Dashboard" Roadmap

Nautune is evolving into a best-in-class music player with a focus on native desktop integration and fluid mobile experiences.

### Phase 1: Navigation Overhaul (The Skeleton)
**Goal**: Make Nautune feel native on every platform

**Desktop (Linux/Windows/macOS)**:
- [ ] **Navigation Rail** - Replace BottomNavigationBar with persistent sidebar when screen width > 600
  - Gives "Pro app" feel like Spotify/Roon
  - Better use of widescreen real estate
- [ ] **Mini Player Mode** - Picture-in-picture always-on-top window
- [ ] **System Tray Icon** - Background playback control
- [ ] **Command Palette** - `/` key opens VS Code-style command search
- [x] **MPRIS Integration** - Media keys and notification center controls (already implemented!)
- [x] **Keyboard shortcuts** - Space, arrows, N/P/R/L (completed!)

**Mobile (iOS/Android)**:
- [ ] **Translucent Bottom Bar** - Glassmorphism blur effect
- [ ] **Haptic Feedback** - Vibrations on Play/Next/Seek for tactile response
- [x] **CarPlay** - Full library browsing and offline playback (completed!)
- [ ] **AirPlay** - HomePod and Apple TV integration for iOS/macOS

### Phase 2: The Dashboard (The Face)
**Goal**: Transform the Home screen into a discovery engine

- [ ] **Hero Header** - High-res artist background with "Jump Back In" button
- [ ] **Time-of-Day Greeting** - "Good Evening, [User]" with contextual playlist
- [ ] **Smart Shelves** (Netflix-style):
  - "Rediscover" - Albums you loved 3 months ago but haven't played recently
  - "On Deck" - Resume halfway-through playlists/albums
  - "Offline Mix" - Highlight 100% downloaded content for airplane mode
- [ ] **Dynamic Colors** - Extract theme from Hero album art using `ColorScheme.fromImageProvider()`
- [ ] **Animated Cards** - Hover effects with scale/preview on desktop

### Phase 3: Deep Integration (The Muscle)
**Goal**: Polish and power-user features

- [x] **ReplayGain** - Automatic volume normalization (completed!)
- [x] **Dynamic Album Art Gradients** - Fullscreen player extracts colors from album art for immersive gradient backgrounds (completed!)
- [ ] **Smart Downloads** - "Auto-download favorites" and "Keep last 50 played songs offline"
- [x] **Lyrics Support** - API integration complete, UI tab in progress
- [x] **Smart Playlists / Instant Mix** - 50-track mixes from any track/album/artist with one-tap save as playlist (completed!)
- [ ] **Infinite Radio Mode** - Endless playback that auto-generates next track when queue is low (future feature)
- [ ] **Instant Mix Enhancement** - Better integration with Jellyfin's `/InstantMix` endpoint

## 🐛 Known Issues

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
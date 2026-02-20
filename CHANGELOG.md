### v7.3.0 - Offline Network Silence, Battery Optimization & Storage Management

**Offline Mode: Complete Network Silence (P0)**
- Fixed 8 background services that continued making network requests in offline mode — the root cause of iOS cellular usage reports
- Services now fully silenced: playback reporting (POST every 10s), analytics sync (10-30min), image prewarming (per track), album art loading, Helm polling (3-10s), remote control WebSocket (20s keep-alive), SyncPlay WebSocket, and library bootstrap sync
- Added centralized offline network gate: `_applyOfflineNetworkPolicy()` / `_restoreOnlineNetworkPolicy()` in AppState
- Playback reporting service now queues start/stop events while disabled, flushes pending reports on reconnect
- Bootstrap sync uses generation counter pattern — cancelled syncs abort before persisting stale data
- Helm service gained `suspendPolling()` / `resumePolling()` — pauses adaptive polling without losing target state
- Image prewarming service respects `enabled` flag, JellyfinImage widget shows placeholder in offline mode

**Submarine Mode Merged into Offline Mode**
- Submarine mode is no longer a separate toggle — its battery-saving features activate automatically when offline mode is on (user toggle or network loss)
- All submarine features (disable visualizers, crossfade, gapless, waveform extraction, pre-caching, etc.) activate/deactivate with offline state
- Settings restored automatically when going back online — snapshot/restore behavior preserved
- Removed submarine section from Settings (toggle, detail list, icon indicator)
- Settings controls (visualizer, crossfade, gapless, pre-cache, WiFi-only) are freely adjustable again when online
- iOS Low Power Mode activates battery-saving features directly without toggling network state

**Bug Fix: CarPlay Navigation Race Condition**
- Fixed root template refresh destroying user's navigation stack during browsing
- Root cause: bootstrap service `notifyListeners()` triggers debounced `_refreshRootTemplate()` which cleared `templateHistory` — if user navigated, their stack was destroyed
- Fix: Added `_userHasNavigated` flag with 5-second cooldown, `_isRefreshing` guard to prevent concurrent refreshes
- Removed manual `templateHistory.clear()` from refresh (the API handles this internally)
- Navigation methods now call `_markUserNavigation()` to protect the stack
- Flags reset on CarPlay disconnect

**Performance & Battery Fixes**
- Sleep timer: `Timer.periodic(1s)` now only runs when a sleep timer is actually set, cancelled when it expires
- Image prewarming: replaced `Future.delayed(15s)` cleanup with tracked `Timer` objects, all cancelled in `clearTracking()`
- Relax Mode: AudioPlayer instances are now lazy-initialized (nullable, created on first volume > 0), usage timer deferred until sound is active
- Chart cache: bounded memory cache to 100 entries with LRU eviction on load
- HTTP retry: added up to 30% random jitter to exponential backoff to prevent thundering herd
- Download service: HTTP client properly closed in `dispose()`

**Enhanced Storage Management**
- Expanded from 3 tabs (Downloads, Cache, Loops) to 5 tabs (+ Waveforms, Charts)
- Switched from SegmentedButton to scrollable FilterChip row for tab navigation
- Waveforms tab: view count and total size, clear all waveform data
- Charts tab: list of Frets on Fire charts with track name, artist, score, and notes hit — individual delete and clear all
- Summary card updated with waveform size and chart stats rows

**Version**
- Bumped to 7.3.0+1

---

### v7.2.1 - iOS Lock Screen Desync & CarPlay Browse Fixes

**Bug Fix: iOS Lock Screen Play/Pause Desync**
- Fixed lock screen play button stopping working after pausing from within the app
- Root cause: `resume()` did not reactivate the iOS audio session — iOS can deactivate the session when pause originates from the app, causing subsequent lock screen play commands to silently fail
- Fix: Added audio session reactivation in `resume()` matching the existing pattern in `playTrack()`
- Also made audio handler callbacks async-aware (`Future<void>`) so iOS audio_service properly awaits player state changes before considering commands handled

**Bug Fix: CarPlay Browse Lists Not Loading on Subsequent Browses**
- Fixed album/artist/playlist lists failing to load after switching away from CarPlay (Maps) and back, or navigating back to root
- Root cause 1: Template history was not cleared on CarPlay disconnect — stale `_navigationDepth > 0` caused reconnect to skip the root template refresh
- Root cause 2: Debounced root refresh timer could race with user-initiated navigation pushes, invalidating templates mid-push
- Fix: Clear `FlutterCarPlayController.templateHistory` on disconnect so depth resets to 0
- Fix: Cancel debounce timer at the start of all navigation methods to prevent race conditions
- Simplified reconnect logic — every connect at root level gets a fresh template regardless of connection history

**Version**
- Bumped to 7.2.1+1

---

### v7.2.0 - Lyrics Sync Fix & Track Info in Album View

**Bug Fix: Lyrics Desynchronization**
- Fixed lyrics falling out of sync with playback on both iOS and Linux
- Root cause: `playerSnapshotStream` getter created a new `Rx.combineLatest4` stream on every widget build, causing `StreamBuilder` to unsubscribe and resubscribe every frame instead of receiving live position updates
- Fix: Cache the stream reference in widget state so `StreamBuilder` subscribes once and receives position events properly
- Introduced in v6.8.0 when `_positionSub` was removed in favor of `StreamBuilder<PlayerSnapshot>`

**Bug Fix: Track Info Missing from Album View**
- Added "Track Info" option to the album detail screen's track context menu (the ⋮ button)
- Previously only available in library, artist, and recently played views via the shared context menu
- Now consistent across all screens where track actions appear

**Version**
- Bumped to 7.2.0+1

---

### v7.1.0 - Health Check & Reliability Improvements

**Audio Pipeline Reliability (P0)**
- Fixed race conditions in background FFT/waveform operations when rapidly skipping tracks — added staleness checks between async operations in `_cacheTrackForIOSFFT`
- Made waveform extraction cancellable via `StreamSubscription` — previous track's extraction is now cancelled on track change and in `dispose()`
- Wrapped gapless playback FFT restart in try-catch — FFT visualization failures no longer crash gapless transitions
- Added `.catchError()` to fire-and-forget track caching — prevents unhandled future errors on disk-full or network failures

**Performance (P1)**
- Removed `AnimatedSwitcher` wrapper from Fleet Mode queue items — eliminates `FadeTransition` + `SizeTransition` overhead on reorder with 50+ items; `ReorderableListView` provides its own drag animation
- Fixed WebSocket dead connection detection — `send()` failures now trigger disconnection handling and schedule reconnect instead of silently logging

**Security (P2)**
- Redacted API tokens from WebSocket debug logs — `api_key` parameter is now masked in connection log output

**Quality of Life (P3)**
- Increased album metadata cache from 100 to 500 entries — reduces cache misses for large libraries with negligible memory impact
- Fixed high-DPI image sizing — `maxWidth`/`maxHeight` now multiplied by `devicePixelRatio` to prevent blurry images on retina displays

**Version**
- Bumped to 7.1.0+1

---

### v7.0.0 - Submarine Mode, iOS Lock Screen Fix & Performance

**New Feature: Submarine Mode (Ultra Battery Saver)**
- New toggle in Settings that aggressively reduces all power-hungry features while keeping music perfect
- Disables: visualizers, crossfade, gapless playback, waveform extraction, pre-caching, image pre-loading, lyrics prefetch, ListenBrainz scrobbling
- Reduces: position save interval (1s to 30s), playback reporting (10s to 60s), analytics sync (10min to 30min)
- Streaming quality stays at your preference — user's audio quality is never overridden
- Snapshot/restore: your original settings are captured before override and fully restored when you disable
- Green submarine icon indicator in the app bar when active
- Affected settings controls grayed out while active (visualizer, crossfade, gapless, pre-cache, WiFi-only cache)
- Persists across app restarts
- Works in both online and offline mode

**Fix: iOS Low Power Mode Detection**
- Added `WidgetsBindingObserver` to `PowerModeService` — now re-checks LPM state when app resumes from background
- Previously only detected LPM on charge state changes (plugged/unplugged), missing the most common case: user toggles LPM in iOS Settings
- iOS Low Power Mode now auto-enables Submarine Mode (does not auto-disable on LPM exit)
- Added error handling to battery state stream listener

**Fix: iOS Lock Screen Play/Pause Graying Out (5 fixes)**
- Added `forceBroadcastCurrentState()` call after `resume()` — iOS now gets immediate state update
- Made `_fadeOutAndStop()` async and await `pause()` — sleep timer fade-out now properly notifies iOS
- Added state broadcast in `stop()` — iOS media controls reflect stopped state
- Increased gapless transition delay from 50ms to 150ms — prevents iOS from deactivating media session during swap
- Added state broadcast after audio session reactivation failures — controls don't get stuck on error

**Performance: Stop Timers When Paused**
- Position save timer now starts only when playing and stops when paused (saves disk I/O)
- Sleep timer countdown pauses when playback is paused (saves CPU, prevents inaccurate timing)

**Performance: Pre-Allocated FFT Buffers**
- PulseAudio FFT service now uses pre-allocated `Float64List` buffers instead of creating new `List<double>` every ~23ms
- Reduces GC pressure during real-time audio visualization

**Performance: Configurable Reporting Interval**
- Playback reporting service interval now configurable (used by Submarine Mode to reduce from 10s to 60s)
- Battery-aware position save: 1s normally, 30s in Submarine Mode

**Version**
- Bumped to 7.0.0+1

---

### v6.9.0 - Live Search, Queue Undo & Track Info

**New Feature: Live Search with Debounce**
- Search results now appear as you type — no need to press Enter
- Uses 300ms debounce to avoid excessive API calls while typing
- Pressing Enter still triggers an immediate search (cancels pending debounce)
- Works across all search modes: online, offline, and demo

**New Feature: Queue Undo**
- Swiping a track from the queue now has a fully working UNDO action
- Tapping UNDO in the snackbar re-inserts the track at its original position
- New `insertIntoQueue()` method on AudioPlayerService handles index-aware re-insertion
- Previous snackbar is cleared when a new track is removed (no stale undo actions)

**New Feature: Track Info Bottom Sheet**
- Long-press any track → "Track Info" option in context menu
- Displays detailed audio metadata in a draggable bottom sheet:
  - **Audio Quality**: Quality summary badge, codec, container, bitrate (kbps), sample rate (kHz), bit depth, channel layout
  - **Track Info**: Title, album, artist, track/disc number, duration, genres, play count
  - **External IDs**: MusicBrainz IDs (Track, Album, Artist) — tap to copy
- Available everywhere the track context menu appears (library, albums, artists, recently played)

**Version**
- Bumped to 6.9.0+1

---

### v6.8.0 - Artist Radio, Recently Played & Reorderable Nav

**New Feature: Artist Radio**
- Start radio from any artist page via the new radio icon in the app bar
- Uses Jellyfin's Instant Mix API to seed 50 similar tracks, then enables Infinite Radio for continuous playback
- Radio indicator chip shows in the full player and a small radio icon appears in the now playing bar when active

**New Feature: Recently Played Screen**
- Full listening history screen accessible via "View All" on the Recently Played shelf
- Events grouped by day (Today, Yesterday, This Week, Older) with relative timestamps
- Tap to play, long-press for context menu (Play Next, Add to Queue, Instant Mix, etc.)
- Powered by local ListeningAnalyticsService data (up to 200 events)

**New Feature: Reorderable Navigation Tabs**
- Long-press the bottom navigation bar to reorder tabs via drag-and-drop
- Order persists across app restarts via Hive storage
- Index mapping ensures correct tab content regardless of visual position

**New Feature: Track Context Menu (Reusable)**
- Extracted common track actions into `showTrackContextMenu()` widget
- Available on artist detail screen (long-press any track), recently played screen, and existing screens
- Options: Play Next, Add to Queue, Add to Playlist, Instant Mix, Go to Artist, Go to Album, Fleet Mode support

**Performance: Image Caching**
- Replaced `Image.network()` with `CachedNetworkImage` on 4 screens that were bypassing the cache:
  - Library screen (ListenBrainz discovery cards)
  - Genre detail screen (album grid) — now uses `JellyfinImage` for proper auth + caching
  - Essential Mix screen (artwork display)
  - Network screen (radio station images)

**Reliability Fixes**
- **SyncPlay race condition**: Moved `_isInitializing = true` before the async call to prevent duplicate service creation
- **Gapless transition errors**: Added `playbackErrorStream` to AudioPlayerService — errors now surface as SnackBars via NowPlayingBar instead of silent `debugPrint` logging
- **SyncPlay join delay**: Replaced hardcoded 500ms `Future.delayed` with event-based `addPostFrameCallback`

**Helm Mode Overhaul**
- **Fixed**: Helm Mode now actually works — remote control commands are delivered via persistent WebSocket instead of being silently dropped by the server
- **RemoteControlService**: New persistent WebSocket connection to `/socket` that makes Nautune a fully controllable Jellyfin client
- **Session Capabilities**: Nautune now registers capabilities with the server at startup (`POST /Sessions/Capabilities/Full`), enabling server-pushed Playstate, Play, and GeneralCommand messages
- **Incoming Commands**: Supports Play/Pause, Next/Previous, Seek, Stop, Rewind, FastForward, SetVolume, PlayNow/PlayNext/PlayLast
- **Moved to Library Screen**: Helm Mode button (sailing icon) moved from the full player to the library screen app bar — no longer requires active playback to access
- **Transport Controls**: Helm Mode bottom sheet now shows full transport controls (play/pause, next, previous) with progress bar — control remote playback without starting local playback
- **Demo/Offline Guard**: Helm Mode button is hidden in demo and offline modes
- **Race Condition Fix**: Fixed RemoteControlService being disposed during initialization when both `_onSessionChanged` and `initialize()` tried to start it

**API Additions**
- Added `JellyfinService.getArtist(id)` and `JellyfinService.getAlbum(id)` for single-item lookups
- Added `AudioPlayerService.infiniteRadioEnabled` getter
- Added `JellyfinClient.reportCapabilities()` for session capability registration

**Version**
- Bumped to 6.8.0+1

---

### v6.7.3 - Smarter Discovery Recommendations

**Improved: "Discover New Music" Shelf**
- **Root Cause**: The CF recommendation endpoint (`/cf/recommendation/user/.../recording`) returned irrelevant tracks that didn't match the user's taste
- **Fix**: Replaced with two better ListenBrainz sources, fired in parallel:
  - **LB Radio** (`/explore/lb-radio`): Personalized unlistened recordings via Troi recommendation engine — tracks arrive with full metadata (title/artist/album) from the JSPF response, skipping expensive MusicBrainz enrichment
  - **Fresh Releases** (`/user/.../fresh_releases`): Recent releases from artists the user actually listens to, shown as album-level discovery items with "New Release" badges
- **Fallback**: If both new sources return empty, gracefully falls back to the existing CF recommendation path
- **Caching**: Both sources cached for 6 hours to avoid redundant API calls on repeat home screen visits
- **UI Badges**: Discovery chips now show source-specific badges — "Discover" with explore icon for LB Radio tracks, "New Release" with new_releases icon for fresh releases
- **Library Matching**: LB Radio tracks are matched to the Jellyfin library using existing MBID + fuzzy matching logic; fresh releases stay unmatched as external discovery items

**Version**
- Bumped to 6.7.3+1

---

### v6.7.2 - Stats, Discovery & Lock Screen Fixes

**Bug Fix: Profile Stats Infinite Loading Spinner**
- **Root Cause**: `_loadStats()` had no top-level error handling — if the Hive cache hung or threw before reaching the network refresh, `_statsLoading` was never set to `false`
- **Fix**: Added try-catch-finally with a 5-second timeout on cache load and guaranteed `_statsLoading = false` in the finally block

**Bug Fix: Total Listening Hours Inflated**
- **Root Cause**: Total hours was calculated as `trackDuration × playCount` from the server — assumed every play was a full listen (skipped tracks counted as full duration)
- **Fix**: Now uses actual listening time from the local `ListeningAnalyticsService` which records real wall-clock duration per play. Falls back to server estimate if local data is unavailable

**Bug Fix: Top Artists Missing (1000 Track Limit)**
- **Root Cause**: Stats were computed from only the top 1000 most-played tracks — artists beyond that cutoff were invisible in top artist rankings, genre breakdowns, and diversity scores
- **Fix**: Added paginated `getAllPlayedTracks()` that fetches every played track from the server (in batches of 500). Profile stats now reflect the entire library

**Bug Fix: ListenBrainz "Discover New Music" Showing Library Tracks**
- **Root Cause**: Fuzzy matching in `getRecommendationsWithMatching()` was inconsistent with `matchRecommendationsToLibrary()` — missing `.trim()` calls and minimum string length guards caused false negatives (library tracks slipping into "Discover")
- **Fix**: Added `.trim()` to all string comparisons, minimum length guards (8 chars for track/album names, 6 for artists), length guards on album matching, and a combined `"artist track"` search strategy for better Jellyfin search recall

**Bug Fix: Lock Screen Controls Greyed Out After In-App Pause**
- **Root Cause**: Pausing from the app then locking the screen caused the OS to lose the media session state — `forceBroadcastCurrentState()` only ran on app resume (too late) and only on iOS
- **Fix 1**: Broadcast paused state to OS immediately after in-app pause completes
- **Fix 2**: `reactivateAudioSession()` now broadcasts on all platforms (iOS guard only wraps audio session config)
- **Fix 3**: Added media session broadcast when app goes to background — ensures OS has latest state before app is suspended

**Version**
- Bumped to 6.7.2+1

---

### v6.7.1 - Infinite Radio Fix

**Bug Fix: Infinite Radio Not Working After Album Ends**
- **Root Cause 1**: Race condition — background fetch flag blocked subsequent fetch attempts when tracks finished quickly
- **Root Cause 2**: Duplicate filtering — InstantMix returned album tracks already in queue, nothing new was added
- **Root Cause 3**: No UI notification — queue screen didn't update when infinite radio tracks were added
- **Fix**: Wait for in-flight fetches, fallback to different seed track when all results are duplicates, notify UI after queue changes
- **Also**: Infinite Radio now works with manual skip-to-next at end of queue

---

### v6.7.0 - Helm Mode, Fleet Mode, Bug Fixes, Performance & Flatpak

**Helm Mode (Remote Control)**
- **Sessions API**: Control another Nautune instance on the same Jellyfin server
- **Device Discovery**: Automatically finds other Nautune instances via Sessions API
- **Full Remote Control**: Play, pause, seek, skip next/previous on the target device
- **Adaptive Polling**: 3s refresh when target is playing, 10s when idle (saves API calls)
- **Player Integration**: Ship's wheel icon in the full player screen header to activate Helm Mode
- **Active Banner**: Shows "Controlling: [Device Name]" banner when helm is active

**Fleet Mode (SyncPlay Rebrand + Improvements)**
- **Rebranded**: "Collaborative Playlists" is now "Fleet Mode" across all UI surfaces
- **Tighter Drift Correction**: 3-tier approach — hard seek for >500ms drift, gradual playback rate adjustment (1.02x/0.98x) for 200-500ms drift, no action below 200ms
- **Sync Quality Indicator**: Colored dot (green/yellow/red) showing sync health and average RTT
- **Shuffle/Repeat Controls**: Toggle buttons added to Fleet Mode playback controls, wired to SyncPlay API
- **Buffering State Wiring**: Audio player buffering state now reported to SyncPlay server for sailor coordination

**Performance Improvements**
- **Player Screen**: Removed redundant setState listeners — position/playing state handled solely by StreamBuilder (eliminates double-rebuilds at ~30fps)
- **Image Widget**: Converted JellyfinImage to StatefulWidget — FutureBuilder futures are cached and only recreated when IDs change (prevents re-fetching on every parent rebuild)
- **Downloads**: Reused single HTTP client for all downloads instead of creating a new one per track (connection pooling)
- **File I/O**: Replaced all synchronous `existsSync()` calls with async `exists()` in audio player and download service (unblocks main thread)
- **MusicBrainz Cache**: Capped metadata cache at 200 entries with LRU eviction (prevents unbounded memory growth)

**Visualizer Improvements**
- **Spectrum Bars**: Enhanced peak indicators — thicker (4px), brighter, with glow layer behind each peak
- **Radial Visualizer**: Larger inner core, mid-frequency reactive sizing, white highlight center on bass hits

**UI Fixes**
- **Album Grid (iOS)**: Fixed album name overlapping artist name — reduced aspect ratio (0.75 → 0.7), removed ClipRect, increased spacing
- **Infinite Radio**: Moved toggle from Settings to full player screen's "more options" menu where it's contextually relevant
- **Download Progress**: Fixed progress wheel clipped by container — centered with proper sizing and rounded corners

**Bug Fix: CarPlay Lists Stop Loading After First Browse**
- **Root Cause**: `_navigationDepth` counter was never decremented on back-press
- **Fix**: Replaced manual counter with `FlutterCarPlayController.templateHistory.length` as source of truth
- **Result**: CarPlay browsing, back navigation, and reconnects all work reliably

**Bug Fix: iOS Lock Screen Play/Pause Grayed Out**
- **Root Cause**: `reactivateAudioSession()` only broadcast state when `isPlaying` was true
- **Fix**: New `forceBroadcastCurrentState()` method broadcasts actual state (playing or paused) to iOS
- **Result**: Lock screen controls stay interactive regardless of play/pause state

**Bug Fix: ListenBrainz Discovery False Matches**
- **Fuzzy Matching**: Added minimum string length requirements (8 chars for tracks, 6 for artists) to prevent short strings like "Love" matching unrelated tracks
- **Album Art Cache**: `releaseMbid` now stored in MusicBrainz metadata cache — discovery album art persists on refresh

**Flatpak Packaging**
- **Source Build**: Built from source using [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter) (no pre-built binaries)
- **Freedesktop Runtime 25.08**: Uses latest SDK with LLVM 20 extension for clang++ compilation
- **Shared Modules**: System tray dependency (libayatana-appindicator) uses [Flathub shared-modules](https://github.com/flathub/shared-modules)
- **Pre-Sized Icons**: 512/256/128px icons pre-generated with ImageMagick (SDK 25.08 lacks PyGObject)
- **AppStream Metadata**: `com.github.ElysiumDisc.nautune.metainfo.xml` with app description and release history
- **Desktop Entry**: `com.github.ElysiumDisc.nautune.desktop` with MPRIS and system tray support
- **Permissions**: Network, PulseAudio, DRI, Wayland/X11, D-Bus for system tray and MPRIS
- **Flathub Submission**: PR [#7761](https://github.com/flathub/flathub/pull/7761) under review

**Version**
- Bumped to 6.7.0+1

---

### v6.6.0 - Artist Tracks, Adaptive Colors & Smart Mix Expansion

**Artist Page: Tracks Section**
- **Library Tracks**: Artist pages now show a "Tracks" section with all songs from your library
- **4 Sort Options**: Most Listened, Random, By Album, Alphabetical
- **Collapsible Sections**: Popular, Tracks, and Albums sections can be expanded/collapsed

**Now Playing: Adaptive Text Colors**
- **Smart Contrast**: Text color automatically adapts based on album art luminance (Gradient/Blur layouts)
- **Light Albums = Dark Text**: Albums with bright artwork get dark text for readability
- **Dark Albums = Light Text**: Albums with dark artwork get light text
- **WCAG Compliant**: Follows accessibility guidelines for contrast ratios

**Smart Mix: Expanded Genre Matching**
- **100+ Genres**: Massively expanded genre-to-mood mapping for better playlist generation
- **Subgenres**: Added lo-fi, neo-soul, psytrance, metalcore, post-punk, and many more
- **Variations**: Handles spelling variations (chill/chillout/chill-out, nu metal/nu-metal)
- **Common Abbreviations**: Recognizes alt, prog, heavy as genre shortcuts

**Smart Mix Cards: Compact Layout**
- **1x4 Grid**: Smart Mix mood cards now display in a single row of 4 compact cards
- **More Space**: Reduced card size frees up screen real estate for other content

**Album Page: Hot Tracks from Artist Popularity**
- **Artist-Based**: Hot track detection now uses artist's top tracks from ListenBrainz (more reliable)
- **Name Matching**: Fuzzy matching finds popular tracks even with slight title variations
- **Flame Indicators**: Popular tracks still display flame icon with album-palette-matched color

**Playback Bar: Visualizer Position Aware**
- **Respects Position Setting**: When visualizer position is set to "Album Art", the playback bar no longer shows the visualizer overlay
- **Avoids Duplication**: Visualizer only appears in one location based on your preference

**App Restore: Fixed Auto-Play**
- **Paused on Launch**: App now correctly restores in paused state (no more unexpected audio on startup)
- **Explicit Resume**: User must tap play to start playback after app restore

**Linux: Tray Right-Click Fix**
- **Fixed Context Menu**: Right-click on system tray icon now reliably shows the context menu
- **AppIndicator Compatibility**: Removed conflicting manual popup that blocked native menu

**Linux FFT: Code Optimization**
- **Cleaner Architecture**: FFT processing code reorganized for better maintainability
- **Consistent Performance**: Optimized processing pipeline for smooth visualization

**Theme-Aware UI Colors**
- **Library Header**: Nautune logo and wave icon now use theme colors instead of hardcoded purple
- **Playback Bar Waveform**: Waveform tint colors now match your theme

**Fixed Alphabetical Navigation**
- **Foreign Characters**: Properly handles foreign characters in alphabetical navigation

**iOS: Lock Screen Playback Fix**
- **Audio Session Recovery**: Properly reactivates audio session after interruptions (phone calls, Siri)
- **Background Playback**: Fixed greyed-out lock screen controls when returning from background
- **Reliable Resume**: Audio session now properly reconfigures when app returns to foreground

---

### v6.5.0 - Now Playing Layouts, Crossfade Fix & Battery Optimization

**Now Playing Screen Layouts**
- **6 Layout Options**: Choose from Classic, Blur, Card, Gradient, Compact, and Full Art layouts
- **Settings Picker**: New "Now Playing Layout" option in Settings > Appearance
- **Persistent Preference**: Selected layout saved and restored across app restarts
- **Classic Layout**: Current default - traditional player with album art and controls
- **Blur Layout**: Heavy frosted glass effect with blurred album art background
- **Card Layout**: Dark background with elevated album art card and large shadow
- **Gradient Layout**: Dynamic gradient background from album colors
- **Compact Layout**: Smaller artwork (35-45% reduction) with subtle gradient
- **Full Art Layout**: Black background, no rounded corners, artwork fills screen

**Crossfade: Proper Fade Out/In Behavior**
- **Fixed Overlay Issue**: Crossfade now properly fades out the current track THEN fades in the next track
- **Sequential Transition**: No more simultaneous mixing of both tracks during crossfade
- **Split Duration**: 60% of crossfade time for fade out, 40% for fade in
- **Smoother Experience**: Users get the expected radio-style sequential fade behavior

**Track Seeking Accuracy Fix**
- **Fixed Desync Issue**: Seeking now immediately updates the progress bar UI for responsive feedback
- **Position Clamping**: Seek position clamped to valid range to prevent seeking beyond track bounds
- **iOS FFT Sync**: FFT shadow player position synced after seek operations
- **Duration Priority**: Player-reported duration now prioritized over metadata to prevent "completed but still playing" issue

**Visualizer Battery Optimization (iOS)**
- **FFT Stops When Hidden**: FFT processing now stops when visualizer is toggled off (hidden behind album art)
- **No Rendering When Hidden**: Visualizer widget not rendered at all when hidden (previously rendered with opacity 0)
- **Manual FFT Control**: Toggling visualizer on/off now explicitly starts/stops iOS FFT capture
- **Fixes Battery Drain**: 20-30 minute sessions no longer heat up phone when visualizer is enabled but not visible

**iOS Low Power Mode Fix**
- **Fixed Visualizer Not Disabling**: Low Power Mode listener now initializes AFTER visualizer state is restored
- **Proper Initial Check**: If Low Power Mode is already enabled at app start, visualizer correctly disables
- **Restored on Exit**: Visualizer properly restores when Low Power Mode is turned off

**TUI Mode Improvements (Linux)**
- **Window Resizing**: Added drag handle in bottom-right corner for resizing the TUI window
- **Responsive Layout**: Tab bar and status bar now handle small window sizes gracefully
- **Overflow Protection**: No more render overflow errors when resizing to very small dimensions
- **Smart Element Hiding**: Now playing indicator and progress bar hide on narrow windows

---

### v6.4.2 - CarPlay Stability, ReplayGain & iOS Visualizer Fix

**CarPlay: Browsing Desync Fix**
- **Fixed Browsing Stops Working**: CarPlay browsing no longer breaks after phone unlock or app resume
- **Navigation State Tracking**: Internal navigation depth tracking prevents root template corruption when user is navigating
- **Smart Reconnect Handling**: Differentiates between true first connection vs resuming from background - skips disruptive refresh when user is mid-browse
- **Template History Cleanup**: Clears template history before root reset to prevent navigation stack accumulation
- **Memory Leak Fix**: CarPlayService now properly disposed when app closes

**Audio: ReplayGain Volume Jump Fix**
- **Fixed Volume Jump on Resume**: Resuming a paused track no longer causes a sudden volume increase
- **ReplayGain in Fade Methods**: Fade-out and fade-in now correctly apply ReplayGain normalization multiplier
- **Consistent Playback Volume**: Volume stays consistent before pause and after resume for tracks with ReplayGain metadata

**iOS Visualizer: Spectrum Bars & Mirror Bars Tuning**
- **Fixed "Blown Out" Visualizers**: iOS spectrum bars and mirror bars no longer look constantly maxed out
- **iOS FFT Intensity Scaling**: Raw FFT values scaled to 65% to match Linux visual output levels
- **Slower Attack on iOS**: Reduced attack factor (0.6 → 0.4) so bars rise more gradually
- **Faster Decay on iOS**: Increased decay factor (0.25 → 0.35) so bars fall back down properly
- **Visual Parity with Linux**: iOS visualizers now have similar dynamic range and responsiveness as Linux

**Album Detail: Layout Fix**
- **Fixed Title/Artist Overlap**: Added proper spacing between album artwork and album info section
- **Text Overflow Handling**: Long album titles (2 lines max) and artist names (1 line) now truncate with ellipsis instead of overflowing

---

### v6.4.1 - Alphabet Scrollbar Bugfix

**Library: Alphabet Scrollbar Fix**
- **Fixed Accented Character Bug**: Alphabet scrollbar fallback no longer jumps to accented characters (Á, †, ╚, etc.) when a letter is missing
- **Standard A-Z Fallback**: When tapping a missing letter, now correctly jumps to the next standard A-Z letter instead of Unicode characters with higher code points
- **Works Across All Views**: Fix applies to Albums, Artists, and Genres sorted by name
- **Both Sort Directions**: Ascending and descending sort orders both work correctly

---

### v6.4.0 - Alphabet Navigation & Artist Mix Fix

**Library: Alphabet Section Headers**
- **Visual Section Headers**: Albums, Artists, and Genres now display letter section headers (A, B, C...) between groups
- **Reliable Scrollbar Navigation**: Tapping letters on the alphabet scrollbar now jumps directly to section headers
- **Accurate Position Calculation**: Fixed scroll position math for both grid and list modes accounting for section padding
- **Smart Letter Jumping**: Alphabet scrollbar now intelligently jumps to the *next* available section when a letter is missing (e.g. tapping 'B' goes to 'C' if 'B' is missing), preventing loops
- **Lazy Loading Support**: Alphabet navigation now works correctly with large lists by forcing scroll to unrendered positions instead of clamping to estimated height
- **Works with Pagination**: Headers are calculated from item names, not positions, so they work correctly as more items load
- **Grid & List Mode Support**: Section headers appear in both grid view and list view
- **Sort-Aware**: Headers only appear when sorted by name; other sort orders hide the alphabet scrollbar

**Artist Page: Instant Mix Fix**
- **Fixed 400 Error**: Instant Mix on artist pages no longer fails with "jellyfin exception: unable to fetch instant mix: 400"
- **Artist Mix**: Uses random track selection by artist instead of Jellyfin's InstantMix endpoint (which doesn't support Artist items)
- **50 Track Shuffle**: Creates a shuffled playlist of up to 50 tracks from the selected artist

---

### v6.3.0 - Popular Tracks & Artist Page Redesign

**Artist Page: Top Tracks Section**
- **Top 5 Popular Tracks**: Artist pages now show a "Popular" section with the artist's most globally played songs
- **ListenBrainz Integration**: Popularity data fetched from ListenBrainz global listening statistics
- **Library Matching**: Popular tracks matched to your Jellyfin library by MusicBrainz ID or fuzzy name matching
- **Play from Section**: Tap any top track to start playback with the top tracks as your queue
- **Accent Styling**: Top 3 tracks highlighted with dynamic accent colors extracted from artist image

**Artist Page: Visual Redesign**
- **Dynamic Gradient Background**: Colors extracted from artist image create a personalized header gradient
- **Centered Artist Info**: Clean, centered layout with artist name, stats, and genre tags
- **Expandable Bio Card**: Artist biography in a collapsible card with smooth animation
- **Improved Album Grid**: Compact 3-column layout with subtle shadows and refined typography
- **Section Headers**: "Popular" and "Discography" sections with icons for better visual hierarchy
- **Styled Action Buttons**: Back and Instant Mix buttons with semi-transparent backgrounds

**Album Page: Popular Track Indicators**
- **Flame Icons**: Popular tracks (1000+ global plays) display a flame icon next to the track number
- **Tooltip with Play Count**: Hover or long-press the flame to see the exact play count (formatted as K/M)
- **Batch Popularity Lookup**: All album tracks checked in a single API call for efficiency

**Technical Details**
- **Color Extraction**: Isolate-based palette extraction from artist artwork for gradient backgrounds
- **ListenBrainz Popularity API**: Uses `/1/popularity/top-recordings-for-artist` and `/1/popularity/recording` endpoints
- **7-Day Caching**: Popularity data cached in Hive to reduce API calls
- **MusicBrainz Artist IDs**: Added `providerIds` field to JellyfinArtist model for MBID lookups
- **Non-Blocking**: All loading happens in the background, doesn't slow down page rendering

---

### v6.2.0 - Visualizer in Album Art

**New Visualizer Position Setting**
- **Album Art Visualizer**: New option to display visualizer in the album art area instead of behind controls
  - Tap or swipe on album art to toggle between artwork and visualizer
  - Smooth 300ms fade transition between states
  - Higher visualizer opacity (0.9) for better visibility in album art position
  - Mode indicator icon shows current state (equalizer/album icon)
  - Haptic feedback on toggle (iOS)
- **Position Setting**: New "Visualizer Position" option in Settings > Appearance
  - **Album Art**: Plexamp-style tap-to-toggle visualizer
  - **Controls Bar**: Traditional position behind playback controls (default)
- **Track Change Reset**: Visualizer automatically resets to show album art when track changes
- **Persisted Preference**: Position setting saved and restored across app restarts

---

### v6.1.1 - UI Polish & Settings

**Now Playing Improvements**
- **Volume Bar Toggle**: New setting to show/hide the volume slider in Now Playing
  - Found in Settings > Audio Visualizer section
  - iOS users can hide it since iOS handles volume at the system level
- **Waveform Spacing**: Added proper spacing between audio quality badges and waveform to prevent overlap

**Frets on Fire Visualizer Polish**
- **Faded FFT Bars**: Reduced spectrum visualizer opacity (15-30%) so note dots remain clearly visible
- **Gentler Gradient**: Softer fade from bottom to top for a subtle ambient backdrop effect

---

### v6.1.0 - ListenBrainz Discovery + Frets on Fire Polish

**ListenBrainz Discover New Music**
- **Discover Section**: New "Discover New Music" shelf on Home shows ListenBrainz recommendations NOT in your library
  - Browse music you might like but don't own yet
  - Album art fetched from Cover Art Archive using MusicBrainz Release IDs
  - Compact cards show track name, artist, and album art
- **Tuned Recommendations**: Improved recommendation fetching
  - Changed maxFetch from 100 to 50 for faster loading
  - Increased targetMatches from 15 to 20 for longer playlists

**Frets on Fire Polish**
- **Removed Particle Effects**: Cleaned up visual clutter from note hit particles
- **F Key / Lightning Button**: Press F (desktop) or tap the bolt icon (mobile) to activate Lightning Lane
- **Electrifying Lightning Lane**: Completely redesigned lightning effect with:
  - Glowing edge border around the lane
  - Gradient electric blue fill
  - Animated zigzag lightning bolt with jitter
  - Traveling white sparks that flow down the bolt
  - Pulsing glow intensity
  - Electric sparks dancing at the hit line

**FFT Spectrum Visualizer**
- **Real-time audio visualization**: Each lane fills up like a spectrum analyzer
  - Lanes 0-1 (left): Bass frequencies
  - Lane 2 (center): Mid frequencies
  - Lanes 3-4 (right): Treble frequencies
  - Full lane width gradient bars pulse with the music
- **Platform support**: Works on both iOS (MTAudioProcessingTap) and Linux (PulseAudio)
- **Smooth animation**: Fast attack, slow decay for responsive yet smooth visuals
- **Theme-colored**: Gradient bars match your chosen theme colors with glowing tops

---

### v6.0.0 - CarPlay/Lock Screen Sync + Frets on Fire Power-Ups

**CarPlay & Lock Screen Fixes**
- **Lock Screen Play/Pause Fix**: Fixed grayed out play/pause button during gapless playback transitions
  - Added `forcePlayingState()` to explicitly broadcast playing state to iOS media controls
  - Includes position update to force OS to re-render controls after gapless transitions
- **CarPlay Endless Loading Spinner Fix**: Fixed the main CarPlay desync issue where browsing stops working after playing a track or using the phone app
  - Root cause: `complete()` callback was called AFTER async work, blocking CarPlay UI when loading took time
  - Fix: ALL `onPress` handlers now call `complete()` IMMEDIATELY before any async operations
  - Affects: Albums, Artists, Playlists, Favorites, Recently Played, Downloads, and all "Load More" buttons
- **CarPlay Network Recovery**: Additional robustness for stuck loading states
  - `_waitFor()` now returns boolean indicating success vs timeout
  - On timeout, forces a refresh (which guarantees loading flag reset)
  - If data still empty after loading, attempts one final refresh
  - Loading flags now reset in `_handleNetworkDrop()` to prevent stuck states

**Frets on Fire Visual Feedback**
- **PERFECT/GOOD Hit Text**: Floating feedback text appears on note hits
  - Gold text for PERFECT timing, white text for GOOD timing
  - Animates upward and fades out

**Frets on Fire Bonus Power-Ups**
- **Golden Bonus Notes**: Random power-up notes spawn during gameplay (~1 per 30-60 seconds)
- **5 Unique Bonuses**:
  - **Lightning Lane** (5s): Auto-hits all notes in one random lane with lightning visual
  - **Shield**: Protects combo from 1-2 misses (doesn't reset streak)
  - **Double Points** (5s): 2x score multiplier (stacks with combo for up to 8x!)
  - **Multiplier Boost**: Instantly jump to max 4x multiplier
  - **Note Magnet** (3s): Forgiving timing window - slightly off hits still count
- **Active Bonus Indicator**: Shows current bonus with countdown timer in corner
- **Results Screen**: Now shows total bonuses collected

### v5.9.2 - ListenBrainz Reliability + Frets on Fire Stability
- **ListenBrainz API Reliability**: Added retry logic with exponential backoff to all ListenBrainz API calls
  - Recommendations, scrobble sync, and count sync now retry up to 3 times on network errors
  - Handles "Connection reset by peer" and timeout errors gracefully
  - 15-second timeout prevents hanging on slow connections
- **ListenBrainz Metadata Enrichment**: Recommendations now fetch track/artist/album names from MusicBrainz API
  - ListenBrainz only returns MBIDs - we now resolve them to actual metadata
  - In-memory cache prevents repeated lookups for the same tracks
  - Respects MusicBrainz 1 req/sec rate limit
- **Smart Library Matching**: Multi-strategy search to find more tracks from your library
  - Fetches 100 recommendations, stops early when finding 15 matches (efficient)
  - Search strategies: track name → album name → artist name
  - Album-based matching for compilations and various artists
  - Batch processing with progress logging
- **Improved Track Matching**: Fuzzy matching for recommendations
  - Name matching now uses contains-check instead of exact match
  - Handles variations like "Come as You Are" vs "Come As You Are"
  - ProviderIds now included in Jellyfin search results for MBID matching
- **Frets on Fire Duration Limits**: Prevents crashes on long tracks
  - iOS: Maximum 15 minutes (prevents memory crashes)
  - Android/Desktop: Maximum 30 minutes
  - Shows user-friendly warning when track exceeds limit

### v5.9.1 - ListenBrainz MBID Matching Fix
- **ListenBrainz Recommendations**: Fixed recommendation matching to prioritize MusicBrainz ID (MBID) over name matching
  - Tracks with proper MusicBrainz tags now match reliably (was 0/25 matches, now matches all tagged tracks)
  - Falls back to name+artist matching for tracks without MBID tags
  - Root cause: Was only using track name + artist name, ignoring the MusicBrainz IDs embedded in library metadata

### v5.8.9 - iOS FFT Desync & Waveform Fix
- **iOS FFT Skip/Next Fix**: FFT now properly stops before track changes, preventing concurrent shadow players from competing and corrupting visualization data
- **iOS FFT Gapless Playback Fix**: FFT correctly restarts with new track during gapless transitions (was analyzing old track audio)
- **iOS FFT URL Reset**: Added `resetUrl()` to ensure FFT URL is always refreshed on track changes, even when replaying the same track
- **Essential Mix Visualizer**: FFT fixes restore proper frame rate for radial visualizer (was receiving corrupted data from desync)
- **Essential Mix Performance**: Cached Paint objects in visualizer and waveform painters to eliminate per-frame allocations (~120 objects/sec saved)
- **iOS Waveform Performance**: Downsampled waveform from 720,000 → 1,000 samples for 2-hour tracks (was drawing 720k bars per frame!)
- **Waveform for Local Files**: Downloaded and cached tracks now get waveform extraction immediately (was only triggering for streaming tracks)
- **Waveform Extraction Deduplication**: Fixed duplicate waveform extraction triggers when replaying the same track multiple times
- **Frets on Fire Path Fix**: Charts and legendary track now stored in `nautune/charts` and `nautune/legendary` on desktop (was creating folders directly in Documents)
- **Root Cause**: Skip/next operations were calling `playTrack()` without stopping the previous FFT first, resulting in two concurrent MTAudioProcessingTap shadow players

### v5.8.8 - Relax Mode Expansion + Essential Mix Performance
- **Relax Mode**: Added 2 new ambient sounds
  - **Ocean Waves**: Soothing beach waves for coastal ambiance
  - **Loon Calls**: Night loon bird sounds for wilderness atmosphere
  - Now 5 total sounds: Rain, Thunder, Campfire, Waves, Loon
  - Responsive layout for narrow screens (iOS portrait mode)
  - Profile stats now show all 5 sound usage bars
- **Essential Mix Performance Overhaul**:
  - Animation controller driven interpolation (same as fullscreen visualizers)
  - FFT listener just sets targets, animation controller does smooth interpolation
  - ValueListenableBuilder for play/pause button (avoids full screen rebuilds)
  - Consistent frame rate across iOS and Linux
- **Stats Live Update**: Relax Mode stats now update in Profile when returning from session
  - ListeningAnalyticsService now extends ChangeNotifier
  - Profile screen listens for stats changes
- **Essential Mix**: Fixed playback on Linux (was throwing "Invalid URI" error)
- **Essential Mix**: Now uses AudioPlayerService (same audio pipeline as fullscreen player)
- **Virtual Tracks**: Non-Jellyfin tracks no longer try to report to server (fixes 400 errors)
- **Analytics Sync Fix**: Easter egg plays (Essential Mix, Network) marked as synced locally, not sent to Jellyfin

### v5.8.7 - Essential Mix iOS Fixes + Low Power Mode
- **Architectural Refactor**: Essential Mix now uses AudioPlayerService instead of its own AudioPlayer
  - Same audio pipeline as fullscreen player = same iOS performance
  - Virtual JellyfinTrack bridges Essential Mix with centralized audio service
  - Eliminates duplicate audio code paths and iOS-specific edge cases
- **Linux Playback Fix**: `assetPathOverride` now correctly uses `DeviceFileSource` (was using `UrlSource`)
  - Fixes "Invalid URI" error when playing Essential Mix on Linux
  - Also fixes gapless pre-loading for tracks with asset path overrides
- **Skip Jellyfin Reporting for Virtual Tracks**: Non-Jellyfin tracks (Essential Mix) no longer try to report to server
  - Fixes 400 errors for playback start, progress, and stop reporting
- **Critical iOS Fix**: Essential Mix visualizer now properly responds to music on iOS
  - Root cause: `IOSFFTService.instance.initialize()` was never called (Essential Mix uses its own AudioPlayer, not AudioPlayerService)
  - `setAudioUrl()` and `startCapture()` were silently returning early due to uninitialized service
- **Seek Fix**: FFT shadow player now syncs position when seeking in Essential Mix (was stopping after seek)
- **Low Power Mode Fix**: Both fullscreen and Essential Mix now properly disable visualizer
  - Fullscreen: App state now checks initial low power mode state on startup (was only listening for changes)
  - Essential Mix: Properly calls setState when initial state is low power mode
  - Visualizer ON by default, auto-disables when Low Power Mode is active
- **Essential Mix UI Performance**:
  - Storage stats now cached (was doing file I/O every time download sheet opened)
  - Download progress throttled to 5% increments (was rebuilding on every tick)
- **iOS Battery Optimizations**:
  - FFT sync timer reduced from 0.5s to 1.0s (shadow player sync, not audio playback)
  - SpectrumRadialVisualizer: threshold-based shouldRepaint (was always repainting)
  - ButterchurnVisualizer: threshold-based shouldRepaint (was always repainting)

### v5.8.0 - Frets on Fire Easter Egg + iOS Visualizer Fixes
- **Frets on Fire**: New Guitar Hero-style rhythm game easter egg
  - Search "fire" or "frets" in Library to discover
  - **SuperFlux-inspired algorithm**: Uses moving maximum + moving average for accurate onset detection
  - **BPM detection**: Auto-detects tempo and quantizes notes to actual beat grid (16th notes)
  - **Pitch-based lane assignment**: Spectral centroid tracks melody - notes follow the song's pitch contour
  - **Hybrid lane logic**: Bass/kick hits use frequency bands, melodic content uses pitch tracking
  - **Album art in track selection**: See album covers when choosing which track to play
  - **5-fret gameplay** with theme-derived colors (hue shifts from your primary color)
  - Keyboard controls: 1-5 or F1-F5 on desktop, tap lanes on mobile
  - **Real audio decoding**: FFmpeg on Linux/desktop, native AVFoundation on iOS
  - Scoring matches original Frets on Fire: 50 pts per note, max 4x multiplier (at 30 combo)
  - BPM-based timing windows (tighter at higher BPMs, like original)
  - Charts cached for instant replay, supports 3+ hour DJ sets (caps at 3000 notes)
  - **Streak animations**: Fire glow on hit line, pulsing multiplier, milestone flashes ("ON FIRE!", "BLAZING!", "INFERNO!", "LEGENDARY!", "GODLIKE!")
  - **Fire mode cheat**: Press 'F' on desktop to instantly activate fire mode for testing
  - **Legendary track included**: "Through the Fire and Flames" by DragonForce bundled in app
  - **Always available in demo/offline**: Legendary track playable in demo mode and offline mode
  - **Perfect score unlock (online)**: Get 100% accuracy online to permanently unlock the legendary status
  - **Profile stats**: Total songs, plays, notes hit, best score with track name displayed in fire-themed card
  - **"Rock Star" Milestone**: Unlock a badge with game controller icon for discovering the easter egg
- **iOS Visualizer Decay Fix**: Increased decay factor for iOS (0.25 vs 0.12) so spectrum/mirror bars properly fall back down
- **iOS Native FFT**: Buffer pre-allocation and native throttling for smooth Essential Mix visualizer
- **iOS Audio Decoder**: New native plugin for decoding audio files to PCM for chart generation

### v5.7.8 - iOS Native FFT Critical Performance Fix
- **Native FFT Buffer Reuse**: Pre-allocate all FFT buffers once (was allocating 40KB+ per audio callback causing GC pressure)
  - 8 arrays totaling ~40KB now allocated once at init, reused every frame
  - Eliminates memory allocation in the hot path completely
- **Native FFT Throttling**: Added ~30fps throttle at native level (was sending 40-50 events/sec before Dart throttle)
  - Skips processing entirely when emitting too fast
  - Reduces event channel flooding
- **Pre-computed Hanning Window**: Window function computed once at init (was recreated every callback)
- **Asymmetric Smoothing**: Essential Mix visualizer now uses fast attack (0.6) / slow decay (0.12) matching fullscreen visualizers
  - Was using single 0.18 factor for both (too slow on attack, too fast on decay)
  - Visualizer now reacts instantly to beats and fades smoothly
- **Result**: Essential Mix visualizer should now be smooth AND reactive on iOS

### v5.7.5 - iOS Visualizer Performance Overhaul
- **Essential Mix iOS Performance**: Complete performance overhaul for smooth playback on iOS
  - **Critical Fix**: FFT updates now use ValueNotifier instead of setState - only visualizer rebuilds, not entire screen
  - AnimationController disabled on iOS (was running 60fps idle)
  - Visualizer uses ValueListenableBuilder for isolated 30fps updates
  - Position updates throttled to 4/sec on iOS (was ~10/sec)
  - Artwork shadow reduced (blur 20 vs 40, spread 4 vs 10)
  - Play button shadow reduced (blur 10 vs 20)
  - Scrubber shadows removed entirely on iOS
  - Waveform repaint tolerance added (0.2% threshold)
- **Spectrum Bars iOS Portrait**: Fixed height scaling to 80% in portrait mode (was using broken width-based formula)
- **Mirror Bars iOS Portrait**: Fixed height scaling to 80% in portrait mode (was using broken width-based formula)
- **Spectrum Bars Performance**: Added tolerance-based shouldRepaint (0.005 threshold)
- **Mirror Bars Performance**: Added tolerance-based shouldRepaint, HSL color caching, gradient shader caching
- **Waveform Painter Optimization**: Cached Paint objects instead of creating new ones per bar

### v5.7.4 - Essential Mix Enhanced Visualizer & iOS Performance
- **Gradient Bar Colors**: Visualizer bars now use theme-based gradient colors (hue shifts ±40° around your primary color)
- **Glow Effect**: Soft blur glow behind bars for a premium neon look
- **Bass Pulse Ring**: Sonar-style pulsing ring on bass hits (nautical theme)
- **Double Ring on Heavy Bass**: Second outer ring appears on strong bass hits
- **iOS Visualizer Throttling**: FFT updates throttled to ~30fps, preventing lag
- **RepaintBoundary Isolation**: Visualizer and waveform isolated to prevent cascading repaints
- **Portrait Mode Clipping Fix**: Visualizer fits within container bounds
- **Pre-computed Geometry**: Trig values and weights computed once, reused every frame
- **Reduced Bar Count on iOS**: 32 bars on iOS vs 48 on desktop for smoother animation
- **Smart Glow on iOS**: Glow effect only renders when amplitude > 0.3 on iOS (performance)
- **iOS FFT Parity**: Removed intensity reduction - iOS FFT now matches Linux output
- **iOS Portrait Bar Scaling**: Spectrum Bars and Mirror Bars scale appropriately in portrait mode

### v5.7.3 - Readme Update

### v5.7.2 - A-B Loop Improvements & Saved Loops
- **Save Loops**: Tap the active loop indicator to save the current A-B loop for later recall
- **Saved Loops Management**: View and manage all saved loops in Settings > Storage Management > Loops tab
- **Load Saved Loops**: Tap a saved loop to instantly restore its A-B markers on the current track
- **Delete Saved Loops**: Long-press to delete individual loops, or clear all at once from Storage Management
- **A-B Loop for Cached Tracks**: A-B Loop now works for both downloaded AND cached tracks (not just downloads)
- **Current Track Caching**: The currently playing track now gets cached in the background while streaming, enabling A-B Loop mid-playback
- **A-B Loop Toggle**: Added "Show A-B Loop" toggle in the three-dot menu to show/hide the A-B Loop button
- **Desktop A-B Loop Access**: Added dedicated A-B Loop button below volume slider for easier access on desktop (no long-press needed)
- **iOS Haptic Feedback**: Long-press on progress bar now triggers haptic feedback when opening A-B loop controls
- **Scrollable Track Menu**: Fixed UI overflow in the three-dot menu by making it scrollable

### v5.7.1 - Easter Egg Demo Mode Support
- **Network in Demo Mode**: The Network easter egg now works in demo mode with downloaded channels
- **Essential Mix in Demo Mode**: Essential Mix works in demo mode if downloaded while online
- **Offline Graceful Handling**: Both easter eggs show helpful messages when offline without downloads
- **Demo Mode Detection**: Easter eggs properly detect demo mode and disable network-only features

### v5.7.0 - A-B Loop, Essential Mix & Alternate Icons
- **A-B Repeat Loop**: Set loop markers (A/B points) on downloaded/cached tracks to repeat a specific section
- **Loop GUI Controls**: Long-press progress bar to access A/B marker buttons, visual loop region overlay, and loop toggle
- **Loop TUI Controls**: `[` to set loop start (A), `]` to set loop end (B), `\` to clear loop markers
- **Loop Auto-Clear**: Loop markers automatically reset when switching tracks
- **Essential Mix Easter Egg**: Search "essential" to access the 2-hour Soulwax/2ManyDJs BBC Essential Mix (from archive.org)
- **Essential Mix Radial Visualizer**: FFT visualizer radiates around album art with smooth animations
- **Essential Mix Offline**: Download the Essential Mix for offline playback with visualizer, waveform, and seekable progress
- **Essential Mix Profile Badge**: BBC Radio 1 Essential Mix badge appears in Profile with archive.org aesthetic
- **Essential Mix Low Power Mode**: Visualizer auto-disables on iOS when Low Power Mode is enabled
- **Essential Mix Discovery**: New "Essential Discovery" milestone unlocked when you find the easter egg
- **New Alternate Icons**: Added Crimson (red) and Emerald (green) app icon options alongside Classic and Sunset
- **iOS FFT Tuning**: Reduced iOS visualizer intensity by 20% for a calmer visual experience compared to Linux

### v5.6.4 - CarPlay & Background Playback Fixes
- **CarPlay Browsing Fix**: Fixed bug where browsing stopped working after playing a track - removed blocking flag that prevented template refreshes during playback
- **CarPlay Response Time**: Track selection now signals CarPlay immediately instead of waiting for playback to start, preventing UI freezes
- **Background Playback Recovery**: Gapless transitions now auto-recover when they fail - if one track fails to load, playback automatically advances to the next track instead of stopping silently
- **Hive State Persistence**: Added retry logic (3 attempts) to state saves, preventing data loss from transient write failures
- **Hive Deadlock Prevention**: Added 2-second timeout to state update mutex, preventing infinite hangs if a previous write never completed
- **iOS Background Tasks**: Added background task management to ensure playback state is saved before iOS suspends the app

### v5.6.3 - Network Channel Verification
- **121 Total Channels**: Expanded Network with complete channel mapping from other-people.network
- **Server-Verified Audio**: All audio filenames verified against actual server directory listing
- **Server-Verified Images**: All artwork filenames verified against actual server directory listing
- **Fixed 8 Audio Mappings**: Corrected audio for Traffic Princess, Fucking Classics, The Rejects AM, The Object Spoke to Me, History Has a Way With Words, Mirrors Still Reflect, Radio 333
- **8 Image-Only Channels**: Mashcast, Science Needs a Clown, Everyone Gets Into Heaven, Young Me With Young You, Un Coup de Dés, Live from Las Vegas, Life Radio (artwork displays, no audio on website)
- **Download All Feature**: Bulk download all Network channels for complete offline experience
- **Master List Documentation**: Complete `network list.md` tracking all channel states
- **11 Extra Channels**: Bonus channels not on website preserved (Ambient Set, Cumbia Mix, Gospel Radio, etc.)

### v5.6.2 - Performance Optimizations
- **Image Memory Reduction**: Added `memCacheHeight` to image cache, reducing memory usage by ~50%
- **Duration Caching**: Cached track duration to avoid repeated async queries on every position update
- **Download Notification Throttling**: Reduced UI rebuilds during downloads with 500ms throttle (max 2Hz)
- **Visualizer Array Pooling**: Pre-allocated arrays eliminate ~1,440 allocations/second at 60fps
- **Visualizer Gradient Caching**: Shader cache prevents per-frame gradient allocations
- **HSL Color Caching**: Pre-computed color values avoid expensive HSL conversions per bar per frame
- **Artist Index Optimization**: O(1) artist lookup for deletion instead of O(n²) nested loop
- **File Size Caching**: `DownloadItem` now caches file size to avoid repeated file I/O
- **Concurrent Precaching**: Album track precaching now runs 2 concurrent downloads for faster caching
- **iOS Alternate Icon Fix**: Fixed missing alternate app icon (AppIconOrange) for App Store validation

### v5.6.1 - Profile & Stats UI Improvements
- **Library Overview Card**: New "Your Musical Ocean" section showing total tracks, albums, artists, and favorites count
- **Audiophile Stats**: New card displaying codec breakdown, most common format, and highest quality track in your library
- **Quick Stats Badges**: Inline badges below hero ring showing streak, favorites count, and discovery label
- **Enhanced Listening Patterns**: Added peak day of week and marathon session count (2+ hour sessions)
- **On This Day Section**: Collapsible section showing what you listened to on this date in previous months/years
- **Nautical Typography**: Section headers now use Pacifico font for a nautical feel
- **Wave Dividers**: Decorative wave dividers between major sections
- **Performance Improvements**: Split large sliver into multiple slivers for smoother scrolling
- **Haptic Feedback**: Added light haptic feedback on interactive elements

### v5.6.0 - Enhanced TUI Mode
- **Alternate App Icons**: Switch between Classic (purple) and Sunset (orange) icons in Settings > Appearance
- **Cross-Platform Icons**: Icon choice applies to iOS home screen, Linux/macOS system tray, and app window
- **10 Built-in Themes**: Dark, Gruvbox Dark/Light, Nord Dark/Light, Catppuccin Mocha/Latte, Light, Dracula, Solarized Dark
- **Persistent Theme Selection**: TUI theme choice saved and restored between app restarts
- **Album Art Color Extraction**: Primary color dynamically extracted from album artwork with smooth transitions
- **Lyrics Pane**: Synchronized lyrics display with multi-source fallback (Jellyfin → LRCLIB → lyrics.ovh)
- **Window Dragging**: Drag the tab bar to move the TUI window around your screen
- **Tab Bar**: Top navigation bar with section tabs and now-playing indicator
- **Help Overlay**: Press `?` to see all keybindings organized by category
- **Seek Controls**: `r/t` for ±5 second seek, `,/.` for ±60 second seek
- **Letter Jumping**: `a/A` to jump between letter groups in sorted lists
- **Queue Reordering**: `J/K` to move queue items up/down
- **Favorites**: `f` to toggle favorite on selected track
- **Add to Queue**: `e` to add selected track to queue
- **Theme Cycling**: `T` to cycle through themes
- **Section Cycling**: `Tab` to cycle through sidebar sections
- **Buffering Spinner**: Animated spinner indicator during audio buffering
- **Scrollbar Visualization**: Visual scrollbar on right edge of lists when scrollable
- **Smooth Color Transitions**: Smoothstep easing for album art color changes
- **Duration Format Fix**: Long tracks (1+ hours) now display correctly as `H:MM:SS` instead of broken format

### v5.5.7 - Multiple Visualizer Styles
- **5 Visualizer Styles**: Choose from Ocean Waves, Spectrum Bars, Mirror Bars, Radial, and Psychedelic
- **Spectrum Bars**: Classic vertical frequency bars with album art-based color gradients and peak hold indicators
- **Mirror Bars**: Symmetric bars extending from center line with bass-reactive sizing
- **Radial**: Circular bar arrangement with slow rotation and bass pulse rings
- **Psychedelic**: Milkdrop/Butterchurn-inspired effects with 3 auto-cycling presets (Neon Pulse, Cosmic Spiral, Kaleidoscope)
- **Album Art Colors**: Spectrum visualizers use dynamic colors extracted from current album artwork
- **Style Picker**: New visual picker in Settings > Appearance with live previews
- **Persistence**: Selected visualizer style saved across app restarts
- **Improved Reactivity**: All visualizers now react more dramatically to bass, mids, and treble

### v5.5.6 - Tag-Aware Smart Playlists
- **Tag-Based Mood Detection**: Smart playlists now read actual tags from your Jellyfin library instead of guessing from genres
- **Mood Keywords**: Tracks tagged with "chill", "energetic", "sad", "upbeat" (and similar) are correctly categorized
- **Genre Fallback**: Falls back to genre-based guessing when no mood tags are present
- **Tag Filtering API**: New methods for filtering tracks by custom tags (workout, party, remix, etc.)
- **Extended Metadata**: Tags field now fetched across all track API requests for consistency
- **Offline Tag Support**: Tags are persisted in offline storage for downloaded tracks
- **Queue Screen Fix**: Fixed "Every item of ReorderableListView must have a key" error when viewing queue

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
- **Bioluminescent Visualizer**: Track-reactive animation adapting to loudness and genre (now called "Ocean Waves")
- **Smart Lyrics**: Multi-source fallback (Jellyfin → LRCLIB → lyrics.ovh) with sync and caching
- **iOS Low Power Mode**: Visualizer auto-disables when Low Power Mode is on
- **Enhanced Stats**: Listening heatmap, streak tracker, week comparison

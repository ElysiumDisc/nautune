### v8.0.1 - iOS Piano Audio Fix

**Bug Fix: Piano Silent on iOS**
- Fixed piano easter egg producing no sound on iOS
- Root cause: `audioplayers` converts `BytesSource` to a temp file without a `.wav` extension — AVFoundation can't identify the format without the extension hint, resulting in silence
- Fix: Write generated WAV bytes to temp files with `.wav` extension during preload, play via `DeviceFileSource` with explicit `mimeType: 'audio/wav'` instead of `BytesSource`
- Notes are eagerly written to disk during `preloadRange` so there's no file I/O on keypress
- Temp files cleaned up on dispose

---

### v8.0.0 - Deep Bug Hunt, CarPlay Overhaul & Cross-Platform Reliability

**TUI Search Fix**
- Fixed broken search in TUI mode — `autofocus: true` was unreliable when parent `KeyboardListener` held focus
- Added dedicated `_searchFocusNode` with explicit `requestFocus()` via `addPostFrameCallback` after search mode activation
- Fixed search controller not being cleared when entering search mode
- Fixed Enter key race condition — `onSubmitted` could set `_isSearchMode = false` before the key handler fired, causing double-processing
- Fixed stream subscription leaks in `tui_shell.dart` — `queueStream` and `currentTrackStream` listeners now properly tracked and cancelled in `dispose()`

**iOS Piano Audio Fix (partial — fully fixed in v8.0.1)**
- Added `AVAudioSessionCategory.playback` with `mixWithOthers` option to piano AudioPlayer pool
- This was necessary but not sufficient — the real root cause (missing `.wav` extension on temp files) was fixed in v8.0.1

**CarPlay Overhaul (4 Fixes)**
- Replaced client-side artist album filtering with server-side `loadAlbumsByArtist()` API call — eliminates downloading entire album library just to show one artist's albums
- Fixed "Load More" pagination stacking templates on the nav stack — now pops current page before pushing replacement via `FlutterCarplay.pop(animated: false)`
- Removed dead `updateNowPlaying()` no-op method and its `_onPlaybackChanged` listener + `_playbackSubscription` — Now Playing is handled by `audio_service` automatically
- Added `if (!_isConnected) return;` guards after every async data-fetching gap — prevents pushing templates to a disconnected CarPlay session

**Audio Handler Fix**
- Fixed `awaitMediaSessionUpdate()` Completer race condition — rapid calls orphaned previous awaiters indefinitely
- Now completes any pending Completer before creating a new one

**Download Service Fix**
- Added Content-Type validation for artwork caching — prevents saving HTML error pages as image files when server returns errors

**Performance**
- Fixed pagination performance in library data provider — replaced `[..._albums!, ...newAlbums]` spread operator (O(n) copy) with `List.of(_albums!)..addAll(newAlbums)` for both albums and artists

---

### v7.9.0 - Piano Easter Egg & TUI Piano Overlay

**New Feature: Piano Easter Egg**
- Added playable synth keyboard — programmatic WAV synthesis with additive harmonics (fundamental + 2nd + 3rd) and ADSR envelope, 6-player polyphony pool, per-note caching. No new dependencies or asset files
- GUI piano screen with 2-octave visual keyboard, touch/click support, octave shifting (C2–C6), and press highlighting with theme accent color
- Desktop keyboard mapping (upiano-style): `A W S E D F T G Y H U J` (lower octave), `K O L P ; ' ] \` (upper octave)
- Search easter egg: type "piano" in Library search to reveal the Piano card — works in online, offline, and demo modes
- Analytics: "Virtuoso" milestone for discovery, tracks total notes played and session time, stats displayed in Profile screen
- Export/import support for piano discovery and stats

**TUI Piano Overlay**
- New ASCII piano overlay (`P` key) with box-drawing art, key labels, and accent-color highlighting on pressed keys
- Same keyboard mapping as GUI, `,`/`.` for octave shift, `Esc` to close
- Added to command palette (Ctrl+K) and help overlay (`?`)
- Overlay consumes all key input when active — no key leaking to TUI navigation

---

### v7.8.0 - TUI Spectrum Visualizer, Command Palette & cliamp-Inspired Enhancements

**New Features**
- Added ASCII spectrum visualizer to TUI status bar — 32-bar, 2-row real-time display using Unicode block elements (`▁▂▃▅▇█`) driven by PulseAudio FFT with peak tracking, gravity decay, and accent→primary color gradient. Toggle with `v` key
- Added command palette (Ctrl+K) — fuzzy-searchable overlay with 33 commands across 7 categories (Playback, Seek, Volume, Navigation, Queue, Loop, Other). Type to filter, arrow keys to navigate, Enter to execute. Inspired by VS Code's command palette
- Documented MPRIS integration — Linux desktop media keys, GNOME/KDE widgets, and KDE Connect already work automatically via `audio_service` package

**TUI Enhancements**
- New `TuiSpectrumVisualizer` widget with single-row and multi-row rendering modes, frequency-dependent boost, and fast attack / slow decay smoothing at ~30fps
- New `TuiCommandPalette` widget with fuzzy matching on name, description, category, and shortcut — results sorted by match quality (prefix → contains → fuzzy)
- Added `v` keybinding to toggle visualizer on/off
- Added `Ctrl+K` keybinding to open/close command palette
- Updated help overlay (`?`) with new `v` and `Ctrl+K` entries
- Updated status bar controls hint to show `v:visualizer` and `Ctrl+K:commands`

---

### v7.7.0 - Deep Quality Audit: Bug Fixes, Performance Hardening & Code Architecture

**Critical Bug Fixes**
- Fixed LibraryScreen reactivity — `Provider.of` was using `listen: false`, causing album/artist lists not to load, offline toggle delays, and airplane mode not reflecting
- Fixed alphabet scrollbar aspect ratio mismatch — itemHeight used `/ 0.75` but grid uses `childAspectRatio: 0.7`
- Fixed alphabet scrollbar SliverPadding drift in grid mode — added 16px correction per group
- Fixed alphabet accent normalization mismatch — sections now use the same `normalizeToBaseLetter` as the scrollbar
- Fixed `DownloadService._loadDownloads` crash — unsafe `as int` cast replaced with safe `as num?` pattern
- Fixed `OfflineRepository.getArtistAlbums` — was comparing artist UUIDs against display names (always failed)
- Fixed `ConnectivityService.onStatusChange` stream dying silently on `OSError` (Linux interface down)
- Fixed SyncPlay playback rate stuck at 1.02/0.98x after session cleanup — now resets to 1.0

**Performance**
- Replaced raw `NetworkImage` with `CachedNetworkImageProvider` for palette extraction in full player, album, and artist screens
- Replaced double `StreamBuilder` in `NowPlayingBar` with single `StreamBuilder<PlayerSnapshot>`
- Cached `_getAdaptiveTextColor()` luminance — no longer recomputes every ~250ms during playback
- Fixed `FullPlayerScreen` creating new `LyricsService` on every `didChangeDependencies` — guarded with `??=`
- Fixed `_showLoopOptionsSheet` FutureBuilder reconstructing future on every build
- Merged double `notifyListeners()` in `_onSessionChanged`

**Logic & Correctness**
- Fixed `repository` getter using `_userWantsOffline` instead of `isOfflineMode` — offline repository now activates when network drops
- Fixed `_fadeOutAndPause` race with rapid track skips — aborts fade if track changed mid-fade
- Fixed download progress stuck at 0% when server omits `Content-Length` — now shows indeterminate progress
- Fixed `loadMoreAlbums` potential data duplication on concurrent sort change — added load ID counter
- Fixed artist navigation in FullPlayerScreen — uses artist ID for direct lookup before falling back to name search

**Memory Leak & Dispose**
- Added `_audioPlayerService.dispose()` and `_trayService?.dispose()` to `NautuneAppState.dispose()`

**Dead Code Cleanup**
- Removed unused `_RecentTab` class (~260 lines), dead `_onPlaylistsScroll` method, commented-out offline block
- Removed dead `_isAuthenticating` field from app state
- Removed dead `getArtworkPath` method from download service

**UI Quality & Theme Consistency**
- Replaced hardcoded `Colors.red.shade300`, `Colors.green`, `Colors.red`, `Colors.grey.shade600` with theme colors throughout
- Added text overflow handling to error states
- Extracted duplicate `_extractColorsFromBytes` to shared `lib/utils/color_utils.dart`
- Added Tooltip to offline mode wave icon

**Code Architecture**
- Split `library_screen.dart` (6030 lines) into modular `part` files:
  - `tabs/albums_tab.dart`, `tabs/artists_tab.dart`, `tabs/favorites_tab.dart`, `tabs/genres_tab.dart`
  - `tabs/home_tab.dart`, `tabs/playlists_tab.dart`, `tabs/search_tab.dart`
  - `widgets/alphabet_scrollbar.dart`
- Main file reduced from 6030 to 1322 lines

---

### v7.6.0 - Deep Bug Hunt, Performance Hardening & SyncPlay/Helm Reliability

**Audio Pipeline Fixes**
- Fixed critical HTTP client leak — `httpClient` getter was creating a new `http.Client()` on every call instead of reusing the shared RobustHttpClient
- Fixed `markFavorite`, `getFavoriteAlbums`, `getFavoriteTracks` each creating a new JellyfinClient per call, bypassing the shared ETag cache
- Fixed ETag cache LRU eviction from O(n) List to O(1) LinkedHashSet
- Renamed `TimeoutException` to `HttpTimeoutException` to avoid shadowing `dart:async`
- Fixed crossfade transition — rewrote to swap players instead of stopping both and replaying from scratch, eliminating audible gap/glitch
- Fixed `_nextPlayer` not receiving ReplayGain-adjusted volume in `setVolume`
- Fixed sleep timer fade not applying ReplayGain normalization multiplier
- Fixed A-B loop seek thrashing with `_isLoopSeeking` guard
- Fixed `_clearPreload` fire-and-forget player stop — now uses `unawaited()` for explicit intent
- Refactored waveform cache from `.then().catchError()` anti-pattern to proper `async/await`
- Replaced broken Hive mutex (race-prone Completer) with chained futures for serialized read-modify-write

**Helm Mode (Remote Control) Hardening**
- Fixed async race conditions — all methods now capture `_activeTarget` to local variable before await
- Added session disappearance detection — auto-deactivates helm when target session vanishes
- Added `operator ==` and `hashCode` to HelmSession, preventing unnecessary UI rebuilds every 3s poll
- Added optimistic state updates for play/pause commands
- Removed dead `_targetController`/`targetStream` code
- Fixed memory leak — added `_helmService.dispose()` in library screen
- Added session-change detection to recreate HelmService when switching target devices
- Connected `suspendPolling()`/`resumePolling()` to connectivity changes
- Fixed `Provider.of<NautuneAppState>(context, listen: true)` to `listen: false` — eliminated full-tree rebuilds on every app state change

**Fleet Mode (SyncPlay) Reliability**
- Fixed `oderId` typo throughout models, service, and WebSocket — renamed to `orderId`
- Fixed `_wasCaption` typo — renamed to `_wasCaptain`
- Fixed auto-rejoin deadlock — `_isRejoining` now always resets in `finally` block
- Fixed `play()` — saves previous session for rollback on failure
- Fixed `removeFromQueue` — adjusts `currentTrackIndex` when tracks before/at current position are removed
- Fixed ping sending epoch milliseconds instead of `averageRtt`
- Fixed `getTrackAddedBy` — tries both `playlistItemId` and `trackId` for attribution lookup
- Added bounded attribution growth (`_maxAttributions = 500`) with FIFO eviction
- Fixed drift correction — always restores playback rate to 1.0 after correction (was conditional)
- Changed WebSocket `dispose()` to `Future<void>` with `await disconnect()` to prevent StateError
- Removed unused `_participantsSubscription` field

**UI Performance & Bug Fixes**
- Removed `UniqueKey()` from FullPlayerScreen navigation — was destroying and recreating the entire widget tree on every open
- Fixed `TextEditingController` leak in add-to-playlist dialog — added proper `dispose()` on both success and cancel paths
- Added `VolumeUp`/`VolumeDown` handlers to remote control service (were advertised in capabilities but not handled)
- Created shared `PaletteCacheService` singleton — 4 screens (FullPlayer, MiniPlayer, AlbumDetail, ArtistDetail) now share one palette cache instead of maintaining 4 independent copies, reducing memory usage ~4x

---

### v7.5.0 - Audio Performance Deep Dive & Profile Stats UI Refresh

**Audio Performance Optimizations**
- Reduced position save frequency from 1s to 5s with accurate elapsed-time tracking, cutting disk writes by 80% during playback
- Throttled position handler checks (crossfade, preload, lyrics prefetch, scrobble) to ~1Hz instead of every position tick, reducing CPU overhead on the hot path
- Implemented double-buffer strategy for visualizer frame emission using Float64List, eliminating per-frame list allocations and reducing GC pressure
- Added in-memory path index to audio cache service, replacing O(n) recursive directory scans with O(1) lookups for faster gapless preloads
- Switched network quality adaptation from 30s polling to reactive ConnectivityService stream subscription for 1-3s response to WiFi/cellular transitions
- Made gapless transition timeout platform-aware: 750ms on iOS (needs more time for audio session), 300ms on Android (faster media session updates)

**Profile Stats UI Refresh**
- Added animated count-up stat counters on key metric cards (Total Plays, Artists Explored, Albums Collected) with easeOutCubic animation
- Added weekly trend indicators with up/down arrows and percentage change on Total Plays card
- Added 28-day activity sparkline chart showing daily play trends with gradient fill in the Listening Activity section
- Replaced genre breakdown linear progress bars with a horizontal stacked bar and proportionally-sized genre chips
- Added "Your Sound DNA" concentric arc visualization showing top 5 genres as animated rings
- Redesigned listening patterns from 3+2 row layout with dividers to a compact 3x2 grid with mini circular progress indicators for Discovery and Diversity metrics

**Version**
- Bumped to 7.5.0+1

---

### v7.4.0 - Long-Press Context Menu, Frets on Fire Visual Upgrade & Offline Navigation

**Long-Press Context Menu**
- Added long-press gesture with haptic feedback to track tiles in Album Detail, Library (recent tracks), and Full Player screens for quick access to context menus

**Frets on Fire Visual Upgrade**
- Added particle bursts on note hits, comet trails at combo 5+, lane flash effects, screen shake on milestone achievements, combo intensity vignette, and fire particles rising from hit line during streaks

**Offline-Safe Navigation**
- "Go to Artist" and "Go to Album" now check the local cache before making API calls, enabling seamless navigation in offline mode

**Bug Fixes & Improvements**
- Various bug fixes and improvements

**Version**
- Bumped to 7.4.0+1

---

### v7.3.1 - Bug Fixes

**Bug Fix: Relax Mode Crash**
- Fixed AudioPlayer crash when dragging ambient sound sliders — lazy initialization caused race conditions where multiple player instances were created simultaneously, fighting over the same audio resource
- Reverted to eager initialization (all players created on screen load) while keeping the deferred analytics timer optimization

**Bug Fix: CarPlay Disconnect Race Condition**
- Removed manual `templateHistory.clear()` on CarPlay disconnect that contradicted the navigation stack protection fix in v7.3.0
- `setRootTemplate()` handles history management internally — manual clearing was the original cause of stack destruction

**Bug Fix: Sync Timer Running in Offline Mode on Startup**
- Fixed periodic analytics sync timer starting unconditionally at app launch even when user had offline mode enabled
- Timer now only starts when online, consistent with runtime offline toggle behavior

**Bug Fix: Waveform Storage Stats Display**
- Fixed crash in Storage Management waveforms tab where stale `StorageStats` parameter was used instead of freshly loaded waveform data
- Waveform file count and size now display correctly from `WaveformService` stats

**Bug Fix: Album Art Missing in Offline Mode**
- Fixed album art not displaying in offline mode for downloaded/cached content
- The offline guard was too aggressive — it blocked `CachedNetworkImage` entirely, preventing it from serving images from disk cache
- `CachedNetworkImage` now serves from disk cache (no network) and only fails gracefully for truly uncached images

**Bug Fix: Remote Control Disconnect Not Fire-and-Forget**
- Wrapped async `disconnect()` call in `unawaited()` in offline network policy to prevent potential socket leaks

**Version**
- Bumped to 7.3.1+1

---

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

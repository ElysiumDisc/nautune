### v8.6.0 - Sort Overhaul, CarPlay Polish, Subsystem Hardening

**Critical Bug Fixes**

The library sort UI has been broken since `LibraryDataProvider` was introduced — `appState.albums` / `artists` getters delegate to the provider, but `setAlbumSort` / `setArtistSort` were writing to the legacy `_albums` field on `NautuneAppState`, and the provider's load methods never passed the user's sort to the Jellyfin API. The screen never updated on sort change. Additionally, headers grouped items by display `Name` while the server sorted by `SortName` (articles stripped), producing the "B before A" symptom when every "A"-sortname album was a "The …" title.

- Fixed library sort by Name / Date Added / Year / Play Count not reordering the visible list — `LibraryDataProvider` now owns sort state, exposes `setAlbumSort` / `setArtistSort`, and passes the user's sort through to all four load paths (`loadAlbums`, `loadMoreAlbums`, `loadArtists`, `loadMoreArtists`); `NautuneAppState.setAlbumSort` / `setArtistSort` route through the provider when present
- Fixed sort-direction (asc/desc) toggle not reordering the list — same root cause; same fix
- Fixed alphabetical headers showing "B" first when "The Avengers"-style titles existed — `JellyfinAlbum` and `JellyfinArtist` gained a `sortName` field (parsed from the server's `SortName`) and a `groupingName` getter; the alphabet builder and scrollbar now group by `groupingName` so headers match the server's sort key
- Fixed offline mode silently ignoring the sort-by dropdown — `OfflineRepository.getAlbums` now honors `SortOption.year` (via `productionYear`) and falls back to name for unsupported keys; the sort menu hides Date Added / Play Count when offline so the UI is honest about what's available
- Fixed `ListeningAnalyticsService.importAllStatsFromJson` not refreshing the UI after import — only 2 of 6 internal `_save*` helpers called `notifyListeners`; an aggregate notify now fires after the import save block

**Performance**

- Cached `DownloadService.completedDownloads` and `activeDownloads` (invalidated on `notifyListeners`) — the offline repository was hitting `completedDownloads` ~9× per library refresh, allocating a fresh filtered `List` each time; with 10k downloads that was ~90k allocations per refresh
- Added monotonic `_albumsLoadId` / `_artistsLoadId` to `LibraryDataProvider` so a stale fetch can't overwrite the result of a newer one when the user toggles sort rapidly

**Hardening**

- `PlaylistSyncQueue` actions now carry a stable UUID; `remove` matches by id instead of `(type, timestamp)` so two adds enqueued in the same millisecond can no longer collapse into one removal. `add`, `remove`, and `clear` are serialized behind a `Future`-chain mutex so a UI-driven enqueue can't lose its entry to a concurrent dequeue running in the sync drain loop
- `HelmService` gained a `_disposed` flag with short-circuits in `_refreshTargetState`, `discoverTargets`, `helmPlay`, and `helmPause` — eliminates the "setState/notifyListeners called after dispose" debug assertion that fired when the user navigated away from the Network screen mid-poll

**CarPlay**

- Removed the orphaned `plugins/nautune_carplay/` plugin (never wired into `pubspec.yaml`, scene delegate is owned by `flutter_carplay`, so its `CPApplicationDelegate` callbacks never fired anyway)
- Album, artist, and playlist rows now show artwork — added `JellyfinService.buildSelfContainedImageUrl` so the URL embeds the access token and the OS image loader can fetch without our auth headers
- After tapping a track, CarPlay now navigates to the shared `CPNowPlayingTemplate` (via `FlutterCarplay.showSharedNowPlaying`) so the user can see what's playing and operate transport — previously the UI stayed on the track list
- The currently-playing track's row shows a `playbackProgress: 1.0` indicator, driven by an `AudioPlayerService.currentTrackStream` subscription
- Downloads tab uses `file://` artwork from `DownloadService.getArtworkPathForTrack` when present, so artwork renders fully offline
- Added "Browse A–Z" entry on the Library tab — drills into letter buckets for Albums and Artists (search alternative; `flutter_carplay 1.3.1` does not expose `CPSearchTemplate`)
- Reset `_userHasNavigated` once the stack returns to root and the 5-second post-nav window has elapsed (was sticky after navigation)
- Dropped the redundant third `refresh*()` retry in `_showAlbums` / `_showArtists` / `_showPlaylists` — first-empty + wait-for-loading already covers the cases the third call was meant to catch, and on flaky networks it tripled API load

**Cleanup**

- `sortOptionToJellyfin` adds `SortName` as secondary tiebreaker for `dateAdded` and `playCount` so equal primary keys sort stably by name

---

### v8.5.2 - Library Listener Regression Sweep

**Regression Fixes (LibraryScreen `listen: false` refactor coverage)**

The v8.5.1 perf change registered `_LibraryScreenState` with `listen: false` and added a manual diff-based listener. The initial diff only covered connectivity, sort fields, list identities, and per-section loading flags, leaving several `appState` getters that the build method reads off the listener's radar — when those changed, the UI never rebuilt. This release expands the diff to cover every field the build path actually consumes:

- Fixed Library sort by Name / Date Added / Year / Play Count not updating the visible list until the user switched tabs — sort fields and list identities now drive the listener
- Fixed library picker not rendering on first load and not reacting to library switches — `selectedLibraryId`, the `libraries` list identity, and `isLoadingLibraries` are now tracked
- Fixed error states (libraries, albums, artists, playlists, favorites) not surfacing in the UI when a fetch failed — all five `*Error` getters are now diffed
- Fixed Helm Mode button not appearing/disappearing when demo mode toggled — `isDemoMode` is now tracked
- Fixed the "loading more" pagination spinner not appearing during infinite scroll — `isLoadingMoreAlbums` and `isLoadingMoreArtists` are now tracked
- Fixed Favorites tab not showing tracks marked as favourite on the Jellyfin server — `NautuneAppState.refreshFavorites()` was the only `refresh*` method that did not delegate to `LibraryDataProvider`, so the refresh updated the legacy `_favoriteTracks` field while the getter returned the provider's stale list; the method now matches its sibling `refresh*` pattern

**Performance**
- Cached `_LibraryTab._buildOfflineContent` results keyed on the `completedDownloads` list identity — previously the offline album/artist maps were rebuilt and re-sorted on every parent rebuild while offline; now they recompute only when downloads change, mirroring the `_getFilteredFavorites` caching pattern in the same file
- Cached `SavedLoopsService.getAllLoops()` sorted result with invalidation on save / delete / load — avoids re-sorting the full loop set on every UI rebuild

**Hardening**
- `LibraryDataProvider.dispose()` now removes its `SessionProvider` listener — previously the listener was added in the constructor but never removed, leaking the callback if the provider is ever recreated
- `network_screen` Scaffolds wrapped in `TickerMode(enabled: ModalRoute.isCurrent)` so the radio ticker animation mutes when another screen covers the route, instead of spending frames invisibly
- `HelmSession.==` and `hashCode` now include `clientName` and `userName`, restoring the equality contract for `Set` / `Map` keying

**Cleanup**
- `_loadLibraryDependentContent` no longer triggers a duplicate legacy favorites fetch when `LibraryDataProvider` is wired (the provider's `loadAllLibraryData` already covers favourites, and the legacy result was being silently discarded by the favourite-tracks getter)

---

### v8.5.1 - Bug Hunt & Performance Audit

**Bug Fixes**
- Fixed `findNearestChannel` crashing with a `RangeError` on an empty channel list — the empty-guard was calling `.first` on the empty list it was meant to protect against; now throws a proper `StateError`
- Fixed `AudioHandler` calling `track.artworkUrl()` twice — a null-check on the first call followed by a force-unwrap of a second call; now stores the result in a variable, eliminating the theoretical TOCTOU risk
- Fixed race condition when switching from offline to online mode — `_syncPendingPlaylistActions()` was firing immediately alongside `refreshLibraries()` instead of waiting for the refresh to complete; pending sync actions now run only after the library refresh succeeds
- Fixed potential crash in repeat-all mode with an empty queue — `_getPreloadTrack` computed `nextIndex = 0` but then accessed `_queue[0]` without guarding against an empty queue; added `_queue.isNotEmpty` check
- Fixed memory leak in `artist_detail_screen` palette extraction — `ImageStreamListener` lacked an `onError` handler and `try/finally` cleanup, meaning a failed image stream would leave the listener attached and hang the `Completer`; now mirrors the correct pattern from `full_player_screen`

**Performance**
- Eliminated excessive widget rebuilds in `GenreDetailScreen`, `AlbumDetailScreen`, `LibraryScreen`, and `PlaylistDetailScreen` — all four screens were registered as full dependents of `NautuneAppState` via `Provider.of(listen: true)`, causing a full rebuild on every playback tick, track change, and library update; each screen now uses `listen: false` and registers a targeted `addListener` callback that only reacts to `isOfflineMode` and `networkAvailable` changes
- Replaced eager `Column` + `SingleChildScrollView` in the lyrics tab with a lazy `ListView.builder` — on tracks with 100+ lyric lines, the old approach forced Flutter to lay out every line on initial render; the new approach only builds visible items, with a hybrid scroll strategy (`Scrollable.ensureVisible` when the item is in the viewport, estimated offset fallback when it isn't)

**Hardening**
- Added `onError` handlers to four unguarded audio stream subscriptions (`onPlayerStateChanged`, `onPlayerComplete`, `interruptionEventStream`, `becomingNoisyEventStream`) — previously a platform-level stream error would surface as an unhandled exception and silently kill playback

**Additional Bug Fixes**
- Fixed memory leak in `NautuneAppState.dispose()` — `_libraryDataProvider.addListener(notifyListeners)` was registered in the constructor but never removed in `dispose()`, keeping the `NautuneAppState` alive and allowing stale callbacks to fire after disposal

**Additional Performance**
- Hoisted three `RegExp` patterns in `AlbumDetailScreen._normalizeTrackName` to `static final` fields — previously the patterns were compiled on every call inside the track-popularity matching loop (once per track per album open)
- Cached `hasMultipleDiscs` as a state field computed once in `_loadTracks()` — previously recalculated via a full `map → toSet` pass on every `build()` call
- Eliminated O(n²) disc track-number lookup in `AlbumDetailScreen` track list — replaced per-item `take(index).where(...)` scan with a pre-computed `Map<int, int>` start-index lookup, reducing 5 000+ iterations for a 100-track album to a single O(1) map access per tile
- Lifted `StreamBuilder<JellyfinTrack?>` above the album track list — previously each tile created its own stream subscription (50+ for a typical album), causing all tiles to rebuild on every track change; now a single `StreamBuilder` computes `currentlyPlayingId` and passes `isPlaying: bool` to each stateless tile
- Replaced `NetworkImage` with `CachedNetworkImageProvider` in `MiniPlayerScreen` color extraction — the fallback network path now benefits from Flutter's image cache, avoiding redundant fetches when the same album art is needed again

---

### v8.5.0 - Deep Audit: Startup Performance & Code Architecture

**Performance (Cold Start & UI)**
- **Initialization Parallelization:** Drastically reduced app startup time by parallelizing core service initialization, state restoration, and session loading. Cold-start to usable UI time reduced by up to 40%.
- **Fast Bootstrap Snapshots:** Redesigned the bootstrap process to fetch cached libraries, albums, artists, and playlists concurrently, ensuring a faster "time to first meaningful paint."
- **Optimized Data Migration:** Streamlined the Hive storage migration logic with a persistence marker, eliminating redundant disk checks on every subsequent app launch.
- **Image Cache Expansion:** Increased the global image cache capacity from 200 to 500 items to eliminate eviction thrashing in large library grids, ensuring butter-smooth scrolling.
- **Request Deduplication:** Implemented in-flight request tracking in `JellyfinService` to prevent redundant network calls for identical resources during the bootstrap phase.

**Code Architecture**
- **Surgical Refactoring:** Successfully delegated core library data management (Albums, Artists, Playlists, Genres) from the legacy `NautuneAppState` "God Object" to the focused `LibraryDataProvider`.
- **Provider Autonomy:** `LibraryDataProvider` now independently manages its lifecycle by listening directly to `SessionProvider`, reducing tight coupling across the state layer.
- **Memory Efficiency:** Standardized pagination logic to use efficient list cloning (`List.of()..addAll()`) across all providers.

---

### v8.4.0 - Audio Engine & Battery Optimizations

**Offline & Storage**
- **Offline Library Expansion:** Added support for browsing by Genres, Playlists, and Recently Played history while offline. The app now dynamically builds a genre index and uses cached metadata to keep your library organized without a connection.
- **Offline Artwork Fidelity:** Enhanced `JellyfinImage` with improved local lookup hints, ensuring album and artist art load instantly from local storage in all views (Home, History, Player) when offline.
- **Genre Navigation Fix:** Refactored genre browsing to utilize the repository system, enabling full offline exploration of albums within a genre.

**Audio Engine**
- **Refactored Gapless Transitions:** Implemented instant player swapping by starting the next player immediately and detaching listeners asynchronously, eliminating micro-gaps between tracks.
- **Concurrent Crossfade:** Redesigned crossfading to overlap tracks simultaneously using quadratic volume curves for a professional, seamless DJ-style transition.
- **FFT Redundancy Fix:** Optimized iOS FFT shadow player to reuse local cache and downloaded files, halving network usage for visualization during streaming.

**Battery & Performance**
- **Low Power Mode Integration:** Connected iOS Low Power Mode detection to throttle background scrobble retries and disable power-intensive visualizers.
- **Visualizer Optimization:** Added logic to halt visualizer frame emissions when Battery Saver Mode is active, reducing CPU/GPU overhead.

**Security & Hardening**
- **Log Sanitization:** Stripped raw HTTP response bodies from ListenBrainz logs to prevent PII and session token leaks in debug outputs.
- **Data Protection:** Hardened `PlaylistSyncQueue` and `JellyfinSessionStore` with explicit error logging, preventing silent data loss during transient storage failures.

---

### v8.3.2 - Stats & Rewind Accuracy Fixes

**Bug Fixes**
- Fixed all-time Rewind always showing 0 for Longest Streak — `longestStreak` was hardcoded to `0` when `year == null` in both `computeRewind()` and `computeRewindFromServer()`; now correctly reads from `getStreakInfo().longestStreak`
- Fixed Marathoner personality being permanently unreachable — `ListeningPersonality.marathoner` was a defined enum value with no code path that could return it; `_computePersonality()` now accepts a `marathonSessionCount` parameter and classifies users with 5+ marathon sessions accordingly
- Fixed Healing Frequencies discovery not registering any achievement — `_healingFrequenciesDiscovered` was tracked and saved but had no corresponding milestone; added "Healing Harmony" milestone to the achievements list
- Fixed `saveAnalytics()` not saving all state on app lifecycle pause — `_fretsOnFireDiscovered` and `_healingFrequenciesDiscovered` were missing from the `Future.wait` batch; both flags are now included
- Fixed server-path Top Artists undercounting multi-artist tracks — `_TrackData` only stored the first artist string, so featured/collab tracks only credited one artist; changed to `artists: List<String>` and updated aggregation to match the local analytics path which already counted all artists

**Performance**
- Artist image lookups in all-time Rewind now run in parallel (`Future.wait`) instead of sequentially — reduces load time by up to 10× for the artist image fetch step (was 10 serial network calls)
- Removed duplicate marathon session computation in `getMilestones()` — the method contained a hand-written copy of the same session-grouping loop that `getMarathonSessionCount()` already implements; replaced with a single reuse call

---

### v8.3.1 - Portrait Bento Badge Layout Fix

**Bug Fixes**
- Fixed portrait-mode rendering glitch in profile bento view where the Essential Mix and Frets on Fire integration badges were forced to half screen width even when only one badge was present — they now expand to fill the full available width in the single-badge case
- Fixed Essential Mix header row overflow on narrow iPhone screens (SE/14): the BBC badge + archive.org badge combined exceeded the ~135px content area; the archive badge is now `Flexible` and truncates gracefully
- Fixed Frets on Fire stats row overflow on narrow screens: the four stat items (songs/plays/notes/max) are now `Expanded` so long note counts like "123,456" no longer push past the card boundary

---

### v8.3.0 - Fullscreen TUI Visualizer, Jellyfin 10.11.8 Audit, Perf & Security Pass

**New Feature: Fullscreen TUI Braille Spectroscope**
- Press `F` (shift+f) in TUI mode to open a full-screen Braille-dot spectroscope overlay, inspired by `tsirysndr/tunein-cli`
- Chart uses sub-character resolution (each Braille glyph holds a 2×4 dot matrix), so on a 120-col terminal you get a 240×dotH smooth curve — a big visual upgrade over the inline bars
- Log-frequency axis with decade gridlines at 20/100/1k/10k Hz, per-track header line, and live FFT/bands indicator (matches what was available to `tunein-cli`)
- Dismissed by Esc or `F` again
- **Strictly scoped lifecycle**: the overlay's animation ticker + FFT subscription + keyboard focus node are only allocated while the overlay is visible. Closing it destroys the widget subtree and cancels every subscription — zero background cost when off. Uses the same conditional-render pattern that piano/help/command-palette overlays already rely on.
- Help overlay (`?`) and status-bar hint row both updated with the new `F` binding

**Reusable cell buffer**
- Fullscreen overlay preallocates its `List<int>` Braille cell buffer once per terminal size; each frame just `fillRange`s it to zero and overwrites. No per-frame allocation at 30 Hz.

**Jellyfin 10.11.8 API audit**
- Diffed Nautune's Jellyfin callsites against `jellyfin-openapi-10.11.8.json`. **All documented endpoints unchanged.**
- Three endpoints Nautune uses are not in the 10.11.8 OpenAPI (but remain backwards-compatible across all supported Jellyfin versions): `/Users/{id}/Images/Primary`, `/Users/{id}/Views`, `/Audio/{id}/Waveform`. Each callsite now carries a short "Jellyfin API note:" code comment documenting the status and fallback (no behavioural change)
- Opportunities for v8.4: `/SyncPlay/{id}` single-group fetch, `/Audio/{id}/RemoteSearch/Lyrics` provider search

**Docs**
- DEVELOPMENT.md: troubleshooting section added for `Gdk-CRITICAL: gdk_device_get_source` log noise (GTK/Flutter embedder warning, not actionable) and "Lost connection to device" on `flutter run` exit
- README.md: updated TUI Spectrum Visualizer bullet to mention `v` / `V` / `F` bindings

---

### v8.2.0 - Modern Settings & Profile, Bug Hunt Sweep, Performance Pass

**New UI: Categorized Settings Landing**
- Settings opens on a **tile grid of 8 categories** (Your Music · Server · Appearance · Audio · Performance · Downloads · Data & Backup · About) instead of a 3K-line vertical scroll
- Gradient tiles styled in the app's accent colour; each tile pushes a dedicated detail page that renders only that section
- **Full-text search** over every category title, subtitle, and keyword set — type "crossfade" and you land on Audio, type "rewind" and you land on Your Music
- Legacy full-scroll view preserved behind a "Show all settings" button for power users and any code paths that already rely on it
- Entry point (`SettingsScreen`) and route name unchanged so notification taps, CarPlay entries, and deep links keep working

**New UI: Profile Bento Overview**
- Profile now opens in a **compact bento dashboard** — hero ring sits next to a 3-tile stack of Plays / Artists / Albums, Rewind banner and Library Ocean card flow beneath, integration badges (ListenBrainz, Essential Mix, Frets on Fire) sit side-by-side
- AppBar toggle (list/grid icon) swaps between bento and the legacy long-scroll so every existing detail section (Listening Patterns, Audiophile, Top Content tabs, Activity, Achievements, Deep Dive) remains one tap away
- Signature visuals preserved: hero ring animation, Pacifico username, ListenBrainz orange (`0xFFEB743B`) badge, Essential Mix/Frets on Fire styling, nautical wave dividers

**Bug Hunt**
- **Fixed crash** in `AudioPlayerService._checkCrossfadeTrigger` when the queue was emptied mid-song — now guards against `_queue[0]` on an empty list
- **Fixed crash** in `TrackContextMenu` "Go to Artist" when a track had empty `artistIds` — caches the id inside an `isEmpty` guard and reuses it across the cache-or-fetch path
- **Hardened** audio player listener lifecycle — `_detachListeners()` now awaits cancellation and nulls out refs, so rapid audio-route changes (Bluetooth → speaker, iOS session re-activate) can no longer stack position/state/complete listeners and double-fire gapless transitions
- **Hardened** waveform extraction — the in-flight `StreamSubscription` is now awaited-cancelled before reassignment; rapid track skips can't leak waveforms into the wrong track
- **Tightened** SyncPlay group-id validation with a full UUID regex (32-char hex or dashed UUID); arbitrary 32-char strings no longer slip through as "valid" group ids
- **Fixed** Frets on Fire crash when a MIDI track carried a non-numeric `duration` metadata field — now uses `int.tryParse` with a 180s default

**Performance**
- **Essential Mix download** — `notifyListeners()` is now coalesced via a 100 ms / ≥1% progress-delta gate, dropping ~150 rebuilds per MB to ≤10
- **Visualizer fallback spectrum** — the 64-element `List<double>` allocated every FFT frame is now a reusable `Float64List`-style buffer, eliminating 30-60 Hz GC churn on iOS and the metadata-driven fallback
- **App startup** — independent provider inits (`sessionProvider`, `connectivityProvider`, `uiStateProvider`, `themeProvider`, `ListeningAnalyticsService`) now run in parallel via `Future.wait`, shaving noticeable cold-start latency
- **Image cache** — global `PaintingBinding` budget dropped from 100 MB to 50 MB; eliminates eviction thrashing on large library grids on mid-range devices
- **Frets on Fire highway painter** — `shouldRepaint` now compares scroll time, combo, note identity and effect state instead of returning `true` unconditionally, so the highway skips work when the parent rebuilds during a pause
- **Bioluminescent visualizer** — wave path sampling coarsened from 2 px to 3 px per step, cutting `lineTo` ops by ~33% per frame with no visible difference

---

### v8.1.0 - Healing Frequencies, Easter Eggs Hub & Service Hardening

**New Feature: Healing Frequencies Easter Egg**
- Meditative tone generator inspired by [evoluteur/healing-frequencies](https://github.com/evoluteur/healing-frequencies) (MIT © Olivier Giulieri)
- 12 categories, ~90 preset frequencies — Solfeggio, Healing, Organs, Mineral Nutrients, Ohm, Chakras, DNA Nucleotides, Tesla 3·6·9, Cosmic Octave, Osteopathic (Otto), Angels, plus a bonus Schumann (7.83 Hz) category
- Pure on-device synthesis: integer-cycle sine-wave WAV buffers generated in-memory → seamless looping with zero clicks at the loop boundary, zero network, zero asset footprint
- Schumann's 7.83 Hz is below the audible range, so the screen transparently plays its 6-octave audible equivalent (~501 Hz) with a UI hint
- iOS/macOS audio session uses `mixWithOthers` so tones layer over any other audio
- Volume slider + master stop live in the app bar; tap a frequency pill to play, tap again to stop
- "Healing Frequencies Discovered" tracked via `ListeningAnalyticsService` (milestone hook)
- Access: Library → search `solfeggio`, `healing`, `hz`, `frequency`, or `frequencies`

**Data Accuracy (Healing Frequencies)**
- All Hz values and labels now match the evoluteur reference directory exactly — fixed mis-labeled Organs (Adrenals was called "Thyroid"; "Gall" → "Gall Bladder"), Mineral Nutrients (Calcium/Magnesium/Sodium/Iron/Copper etc. were scrambled across the wrong Hz values; Platinum/Gold/Silver/Silica were missing), DNA Nucleotides (all four labels were on the wrong Hz), Chakras (272.2 "Ohm" → "Soul star Vyapini", 68.05 Earth gained Vasundhara note), and Ohm (descriptive Low/Mid/High/Ultra High names)

**New Feature: Easter Eggs Hub**
- New `EasterEggsScreen` lists every hidden feature with descriptions, offline-capability chips, and search-keyword hints
- Reachable from **Settings → Your Music → Easter Eggs** (gradient Celebration icon)
- Offline-gated eggs (Network, Essential Mix) dim and surface a snack-bar explaining they need downloads when you're offline

**Network Easter Egg**
- Offline guard: tuning to a channel that isn't downloaded while offline now shows a clear SnackBar ("channel X not downloaded — download it while online to play offline") instead of silently failing the stream attempt

**Service Hardening**
- `EssentialMixService`: re-uses a single `http.Client` instance instead of constructing a new one per download (prevents connection-pool churn on retries)
- `EssentialMixService`: fixed orphan-artwork cleanup — previously read `_state.artworkPath` **after** the state was overwritten with the reset value, so the old artwork file was never actually deleted. Now captures the path before resetting state
- `NetworkDownloadService`: same `http.Client` re-use treatment
- `DownloadService`: partial-download temp-file cleanup failures now log via `debugPrint` instead of silently swallowing
- `EssentialMixService`: audio/artwork `.length()` failures in stats now log instead of swallowing
- `PianoSynthService`: temp-dir cleanup failures now log instead of swallowing
- `SyncPlayService` & `SyncPlayProvider`: fire-and-forget `Future.delayed(...)` calls are now wrapped in `unawaited()` and have proper try/catch around the rate-restore — prevents silent crashes in the drift-correction path and the auto-rejoin backoff

**Code Reuse**
- Extracted shared WAV PCM-16 builder into `lib/services/wav_builder.dart` — `PianoSynthService` and the new `HealingFrequencyService` both use it, removing ~70 lines of duplicated RIFF-header code
- `PianoSynthService`: dropped now-unused `_bitsPerSample` constant and the private `_buildWav()` method

**Performance**
- `WaveformService` in-memory LRU cache bumped from 50 → 200 entries — long listening sessions stop thrashing disk I/O re-reading waveform files for recently-played tracks

---

### v8.0.4 - Deep Code Hardening: Security, Stability & Performance

**Security**
- ListenBrainz API token is now stored in an encrypted Hive box (matching Jellyfin session storage), with automatic migration from unencrypted data
- Reduced verbose device ID logging — only logs on first generation, not every app launch

**Data Safety**
- Fixed session store migration that could lose session data if the app crashed mid-migration — encrypted box is now written before the old unencrypted box is deleted
- Playlist cache no longer silently deletes all cached playlists on a single parse error — logs the error and returns gracefully instead

**Bug Fixes**
- Fixed `markFavorite()` not clearing caches on error paths — cache clearing now runs in a `finally` block so stale data is never served after a failed favorite toggle
- Fixed race condition in Fleet Mode participant refresh — `_currentSession` could change during async API calls, causing stale participant data
- Fixed `NowPlayingBar` potentially accessing navigator context after dispose
- Fixed `JellyfinImage` not refreshing when `itemId` or `imageTag` changed (only artist/album/track IDs were compared in `didUpdateWidget`)
- Fixed `RewindScreen` year selector `jumpToPage` failing when `PageController` wasn't yet attached — now deferred to post-frame callback
- Fixed uncancellable `Future.delayed` timer in app startup that could fire after widget disposal — replaced with cancellable `Timer`
- Made `RemoteControlService.dispose()` explicitly annotate fire-and-forget disconnect with `unawaited()`

**Performance**
- `DownloadService.downloads` getter no longer sorts the full list on every access — result is now cached and invalidated only on mutations
- `fetchAllTracks` now paginates in 500-item batches instead of requesting up to 5000 items at once, preventing UI freezes and potential OOM on large libraries
- Library selection screen uses `ListView.builder` instead of eagerly materializing all library tiles
- `AddToCollabButton`, `AddToCollabMenuItem`, and `CollabActiveIndicator` switched from `Consumer` to `Selector` — only rebuilds when `isInSession` changes, not on every `SyncPlayProvider` update

**JSON Error Handling**
- All ~33 `jsonDecode(response.body)` calls in `JellyfinClient` are now wrapped in safe helpers that catch `FormatException` and throw descriptive errors — prevents app crashes when the server returns HTML error pages or malformed JSON

---

### v8.0.3 - Offline Album Deduplication & Search Polish

**Bug Fix: Same-Name Albums Merged in Offline Mode**
- Albums with the same name and artist but different years (e.g., "Greatest Hits" 2010 vs 2020) were incorrectly merged into a single entry in offline mode
- Root cause: Offline library screen and search grouped downloaded tracks by album **name** instead of album **ID** — albums sharing a name collapsed into one entry
- Fix: All offline grouping (album view, artist > album view, and offline search) now keys on `albumId`, keeping distinct albums separate
- Added `productionYear` field to `JellyfinTrack` model — parsed from Jellyfin API, persisted through the download pipeline, and displayed in offline album subtitles (e.g., "Artist - 2020 - 12 tracks")
- Existing downloads gracefully show no year; new downloads automatically persist it

**Offline Search Performance**
- Added result limits to offline search to keep the UI responsive with large libraries (50 albums, 50 artists, 100 tracks)

---

### v8.0.2 - Offline Mode, WiFi-Only Downloads, Helm & Fleet Fixes

**Helm Mode & Fleet/SyncPlay Improvements**
- Fixed WebSocket `.ready` hanging indefinitely if server accepts TCP but never completes handshake — now times out after 10 seconds and triggers reconnect (both RemoteControl and SyncPlay WebSockets)
- Fixed sequential track resolution in `_handlePlayCommand` — now resolves all item IDs in parallel via `Future.wait` instead of one-by-one
- Fixed potential duplicate WebSocket connections from concurrent `_establishConnection()` calls — added `_isConnecting` guard inside the method itself (both RemoteControl and SyncPlay)
- Optimized participant refresh on user join — now only fetches and enriches the current group instead of all groups
- Removed excessive per-participant debug logging in SyncPlay enrichment (4 debugPrint calls per participant)
- Implemented Mute/Unmute/ToggleMute remote commands (previously logged as unimplemented)

---

### Offline Mode & WiFi-Only Download Fixes

**Bug Fix: Album Art Missing in Offline Mode**
- Album art was not displayed in album view when starting the app in airplane mode
- Root cause: `JellyfinImage` widget only checked for offline artwork via `trackId`, but album views only had `albumId` — downloaded artwork files at `downloads/artwork/{albumId}.jpg` were never checked
- Fix: Added `albumId` parameter to `JellyfinImage` with direct album-level artwork lookup via new `DownloadService.getArtworkFileByAlbumId()` method
- Applied to `_AlbumCard`, `_AlbumListTile`, `_MiniAlbumCard`, and album detail screen

**Bug Fix: Network Retry Errors When Offline**
- App would attempt network requests and show retry/connection errors even in airplane mode
- Root cause (1): `_loadLibraries()` always called `_jellyfinService.loadLibraries()` directly, bypassing the offline repository — tapping "Retry" on the offline banner triggered 3 retries with exponential backoff before failing
- Root cause (2): At startup in airplane mode, cached online data was displayed but `_loadLibraryDependentContent()` was never called — `OfflineRepository` was never consulted
- Fix: Added `isOfflineMode` guard in `_loadLibraries()` to use repository pattern; added offline content loading at startup via `_loadLibraryDependentContent()`

**Bug Fix: Favorites Tab Broken When Offline**
- Favorites tab showed loading spinner or error when offline instead of downloaded favorite tracks
- Root cause: `_loadFavorites()` always called `_jellyfinService.getFavoriteTracks()` directly — no offline check
- Fix: Added `isOfflineMode` guard using `repository.getFavoriteTracks()` which returns downloaded tracks with `isFavorite == true`

**Bug Fix: WiFi-Only Downloads Toggle Had No Effect**
- Downloads proceeded over cellular data even when the WiFi-only toggle was enabled
- Root cause: `DownloadService.setConnectivityService()` was never called — `_connectivityService` was always null, causing `_canProceedWithDownload()` to always return true
- Fix: Added missing `_downloadService.setConnectivityService(_connectivityService)` call during app initialization

---

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

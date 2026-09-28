### v9.0.0 - iOS Focus: Jellyfin 12.1, Solid Playback, Offline You Can Trust

Nautune is now an iOS app (iPhone, iPad and CarPlay). Dropping the other
platforms and the least-used features removed about 22,500 lines, and the
effort went into the core: the playback engine, downloads, offline mode,
CarPlay and a migration to the Jellyfin 12.1 API. The test suite grew from
58 to over 200 tests.

**Highlights**
- Jellyfin 12.1 client with modern auth. It works when legacy authorization
  is off, works behind reverse-proxy sub-paths (`https://host/jellyfin`),
  and needs Jellyfin 10.9 or newer.
- Rebuilt playback engine: gapless tracks now scrobble and report, rapid
  skips and seeks during load no longer crash or deadlock, stalled streams
  recover, and cellular data use is roughly halved.
- Downloads resume after the app is killed, can be cancelled, keep
  working after the app container moves, and are excluded from iCloud
  backup.
- CarPlay: rows no longer go dead after you switch apps, cold start works
  from CarPlay, whole libraries paginate, and errors show clear empty states.

**Removed**
- Android, Linux, macOS, Windows and web targets, including AppImage/Deb
  packaging, tray, mini player, the Linux EQ, PulseAudio FFT and the
  FFmpeg waveform and chart paths.
- TUI terminal mode.
- Helm remote control (and its websocket `RemoteControlService`).
- SyncPlay / Collab / Fleet Mode, the deep-link service and the `nautune://`
  URL scheme.
- Dependencies: `tray_manager`, `window_manager`, `app_links`,
  `web_socket_channel`.
- Dead widgets and classes, and the hidden logo-tap offline toggle.

**Playback**
- One track-began path for normal plays, gapless and crossfade. Gapless and
  crossfaded tracks now scrobble, record history, report start and stop to
  Jellyfin, reset the A-B loop and refresh their duration.
- Listening time goes to the right track. The queue is copied instead of
  aliased, and an explicit queue index stops duplicate tracks from looping.
- Rapid skips are serialized with a play-request token and a player lock.
  The lock can't deadlock on a load that never resolves (30s timeout), and
  superseded requests don't queue up.
- Seeks during load are deferred, which fixes an AVPlayerItem
  seek-before-ready crash. A pause during load is honored, and fades are
  generation-guarded.
- Gapless preload race fixed. The swap checks that the preloaded source is
  the right one.
- A failed load leaves the player paused instead of "playing" silence. A bad
  cached copy is deleted, and a failed direct stream retries as a transcode.
  If the whole queue fails, playback stops with an error and the queue is
  kept.
- Stall detector: a frozen stream reloads at the same position (up to 3
  tries).
- Crossfade: no double advance, skipped in repeat-one, repeat-all wraps
  correctly, cache and quality URLs are used, pausing mid-fade cancels the
  fade, and crossfaded tracks count toward the track-count sleep timer.
- The sleep timer no longer jumps volume to 100%. ReplayGain applies on
  gapless and crossfade.
- Interruptions resume only if audio was playing before. Ducking works, and
  an explicit play or pause clears the resume flag.
- Restore on cold start never waits for the network. Downloads restore from
  the local file, the media item is published, and there's a 5s timeout.
- Position updates every 200 ms instead of every frame. Preload, crossfade,
  scrobbling and progress now also work with the screen locked.
- Lock screen: offline artwork, and no more per-tick `playbackState` spam.
- Previous restarts the track after 3 seconds, including from the lock
  screen and CarPlay. Under repeat-all it wraps at the start of the queue.
- The now-playing bar and full player rebuild only when the track or play
  state changes. Position updates redraw just the slider, waveform, time
  labels and synced lyrics.
- The FFT shadow player, and its extra download, run only while a
  visualizer is showing.
- Quality and connectivity settings are applied before playback is
  restored.
- Piano and Healing Frequencies restore the music audio session on exit.

**Streaming and Jellyfin 12.1**
- The bundled OpenAPI spec moved to `docs/jellyfin-openapi-12.1.json` (was
  10.11.9). Audit: 0 spec mismatches across 67 call sites (previously 11+).
- Modern auth: `Authorization: MediaBrowser … Token="…"` header and the
  `ApiKey` query parameter. `X-Emby-*` and `api_key` are no longer used.
- `buildServerUri` keeps reverse-proxy base paths for API, stream, artwork
  and reporting URLs, and for profile images.
- Spec routes: `/Items?userId=`, `/UserViews`, `/UserImage`,
  `/UserFavoriteItems`, and others.
- `universal` uses `transcodingProtocol=http`. `progressive` returned HTTP
  400 on 10.11 and 12.1, which broke Opus, Vorbis, WMA and APE playback.
  Original quality uses AVPlayer-native direct streams, otherwise MP3.
- Playlists are renamed via `POST /Playlists/{id}` so metadata isn't wiped.
  Adding to a playlist supports a position.
- Reporting bodies match PlaybackStart/Progress/StopInfo, use 15s timeouts,
  get a separate reporting session per track, don't leak on session
  change, and are disabled offline.
- Stable pagination (the `paged_fetch` helper); every loop terminates.
- Non-idempotent POST/DELETE requests aren't retried once they may have
  been sent. `fetchTracksByIds` keeps the requested order.
- Only real network failures switch to offline, and a 30s reachability
  probe brings the app back online.
- Logout stops playback, clears the queue snapshot and runs session
  cleanup.
- Second streaming copy (for FFT and cache) only on Wi-Fi, not in Low Power
  Mode, and only after playback starts. Pre-cache uses streaming quality,
  runs at most 2 at a time and skips downloaded tracks. Audio cache capped
  at 2 GiB (LRU). Auto quality checks the network type before the first
  stream.
- Image size buckets improve artwork cache hits. The cache-duration setting
  now reaches `JellyfinService`, and reporting reuses the API
  `http.Client`.
- Stream tokens are no longer written to logs.

**Downloads and Offline**
- Resilient queue. Queued and in-flight downloads are re-queued on launch.
  Losing the network re-queues the batch instead of failing it (backoff
  from 5s to 2 min), and the queue resumes on a connectivity change or when
  the app resumes. Wi-Fi-only stops running transfers on cellular and
  resumes them on Wi-Fi.
- Stall and connect timeouts actually fire, and cancel aborts the socket,
  closes the file and drops the temp file. Truncated bodies are retried, a
  full disk pauses the queue, and the storage limit and auto-cleanup are
  enforced.
- Faster saves. Each track gets its own Hive record with debounced writes
  (the whole map used to be saved on every change), and the legacy map
  migrates automatically. Writes flush every 4 MB, progress ticks no longer
  invalidate list caches, and startup file checks are batched after the
  queue resumes.
- Completion is saved before the best-effort artwork fetch, which now has
  timeouts. Restored tracks pick up server, token and user from the current
  session. Orphaned artwork is cleaned up by album id.
- Paths are stored relative to the downloads root. The root moved to
  Application Support, with a one-time idempotent migration from Documents.
  Long filenames are truncated.
- Downloads, The Network, Essential Mix, waveform and chart caches are
  excluded from iCloud backup through a new `nautune/file_attributes`
  channel (App Review 2.23).
- Formats AVPlayer can't play (Opus, Vorbis, WMA, APE, …) download as a
  320 kbps MP3 transcode. That path is also the fallback when
  `/Items/{id}/Download` returns 403. A banner offers to re-download files
  that older versions saved in such formats.
- One `CollectionDownloadButton` on album, playlist and artist pages
  (progress, cancel, retry, remove, and a size-estimate confirmation for
  large or cellular downloads). Per-track download indicators, and
  Download/Cancel/Retry/Remove in the track menu.
- Rewritten Downloads screen. The Library tab has search, sort, play and
  shuffle all. The Manage tab has a queue banner explaining pauses,
  Retry all, and Quick downloads (Favorites, Top 20, Recent 20). Fixed a
  crash when opening Manage, and deletes that did nothing. Per-album and
  per-artist delete work. There's a Downloads & Queue entry in Settings.
- Album, artist and playlist screens fall back to downloads when offline.
- Offline mode: the toggle lives in the Library ⋮ menu (Go offline / Go
  online) and persists. Only real network failures switch the app offline,
  and it comes back online automatically once the server answers again.

**CarPlay**
- The root is built once and forced on screen. Foreground events only
  update row text, so rows no longer go dead after you return from another
  app.
- Cold start from CarPlay no longer waits for a connect event that the
  plugin drops.
- Albums, Artists and A-Z page through the repository instead of the
  phone's first 50 items, and page size respects the car's maximum item
  count. The A-Z rows moved to the root to stay within the template depth
  limit.
- Long playlists paginate. Added Shuffle rows, and duplicate tracks play at
  the right index.
- Empty-state pages for network errors, timeouts, no session and failures.
- Recently Played refreshes. The Downloads count updates live. Logout,
  login and library switches pop to root.
- Single-list root by default. flutter_carplay 1.3.3 forgets a tab's pushed
  pages when you switch tabs, so the tab-bar root stays behind a flag.

**iOS platform**
- Deployment target is iOS 15. There's a committed `Podfile` and a
  `PrivacyInfo.xcprivacy` privacy manifest.
- `Info.plist`: ATS exceptions for `http://` and LAN servers, a Local
  Network usage string and `ITSAppUsesNonExemptEncryption`. The Main
  storyboard keys are gone.
- Keychain items use `first_unlock`, so CarPlay can cold-start while the
  phone is locked. A keychain read error no longer regenerates or wipes the
  session key.
- `SceneDelegate` requests background time to save state. Deep-link
  forwarding is gone. `SharePlugin` presents on the phone scene, not
  CarPlay's.
- The app-lifecycle `inactive` state no longer suspends reporting or the
  session.

**Design**
- App bar: a visible Settings gear and a ⋮ menu (Go offline/online,
  Downloads, Switch library, Log out).
- Home: the mislabeled "Continue Listening" shelf is gone. The two
  ListenBrainz shelves are merged into "ListenBrainz Picks".
- Settings: the Easter Eggs hub moved to About. The Infinite Radio toggle
  now drives the audio service.
- Easter-egg keywords must match the whole search ("Arcade Fire" no longer
  opens Frets on Fire).
- One shared track context menu for album, favorites and the full player.
  One text theme; Pacifico only for the wordmark; colorScheme roles
  instead of hardcoded colors.
- The Profile screen no longer shows easter-egg stat cards.

**Developer / CI**
- Dart SDK `^3.11.0`, built on Flutter stable. Platform and build folders
  are excluded from analysis.
- Codemagic runs `flutter test` and no longer runs `pod repo update`.
- Docs consolidated: README (users), DEVELOPMENT.md (developers, including
  the release process and an on-device test checklist) and this changelog.
  Older changelog entries are condensed to one line each. `test/README.md`
  was folded into DEVELOPMENT.md. Added an MIT `LICENSE` file.
- New `test/unit/repo_consistency_test.dart` anti-drift guard. It keeps the
  version, CHANGELOG, `Info.plist`, iOS deployment target, pubspec assets,
  doc links and screenshots in sync, and CI fails on drift. See
  DEVELOPMENT.md → "Releasing and versioning".

**Known follow-ups**
- Logout doesn't revoke the access token on the server yet.
- The CarPlay tab-bar root stays off until it's tested on a device against
  flutter_carplay.
- Frets on Fire bundles a commercial MP3 ("Through the Fire and Flames")
  as its legendary unlock. This is a copyright and App Store review risk,
  and the owner needs to decide what to do with it.
- Planned dependency migrations: `hive` → `hive_ce`, `audioplayers` →
  `just_audio`, CocoaPods → Swift Package Manager.
- Redesign the FFT shadow player, which is a second stream used for
  visualizers.
- `GET /Artists` is deprecated in Jellyfin 12.x, and there's no replacement
  yet that also works on 10.11.

---

## Earlier releases

One line per release, newest first. The full notes for each release are in
git history: `git log -p CHANGELOG.md` (or `git show 182c96b:CHANGELOG.md`
for the complete file as of v8.9.7).

- **v8.9.7** — Audit Pass: Analytics Crash Guard, PulseAudio Chunker, CarPlay Polish
- **v8.9.6** — Audit Pass, Smart-Playlist Tag Filter Perf, Test Coverage, Doc Refresh
- **v8.9.5** — Slim Cleanup: Milestones & Rewind Retired, TUI Polish, Jellyfin 10.11.9
- **v8.9.0** — Full Audit Pass: Perf Hot-Path + Dispose Safety + Test Bootstrap
- **v8.8.3** — Verified Perf + Logic + Minimalist Polish (no regressions)
- **v8.8.1** — Battery, Background-Work Hygiene & Minimalist Polish
- **v8.8.0** — Download Hardening, Settings/Profile Polish
- **v8.7.0** — Audit Pass: Connectivity, Downloads, Cache, Player
- **v8.6.0** — Sort Overhaul, CarPlay Polish, Subsystem Hardening
- **v8.5.2** — Library Listener Regression Sweep
- **v8.5.1** — Bug Hunt & Performance Audit
- **v8.5.0** — Deep Audit: Startup Performance & Code Architecture
- **v8.4.0** — Audio Engine & Battery Optimizations
- **v8.3.2** — Stats & Rewind Accuracy Fixes
- **v8.3.1** — Portrait Bento Badge Layout Fix
- **v8.3.0** — Fullscreen TUI Visualizer, Jellyfin 10.11.8 Audit, Perf & Security Pass
- **v8.2.0** — Modern Settings & Profile, Bug Hunt Sweep, Performance Pass
- **v8.1.0** — Healing Frequencies, Easter Eggs Hub & Service Hardening
- **v8.0.4** — Deep Code Hardening: Security, Stability & Performance
- **v8.0.3** — Offline Album Deduplication & Search Polish
- **v8.0.2** — Offline Mode, WiFi-Only Downloads, Helm & Fleet Fixes
- **v8.0.1** — iOS Piano Audio Fix
- **v8.0.0** — Deep Bug Hunt, CarPlay Overhaul & Cross-Platform Reliability
- **v7.9.0** — Piano Easter Egg & TUI Piano Overlay
- **v7.8.0** — TUI Spectrum Visualizer, Command Palette & cliamp-Inspired Enhancements
- **v7.7.0** — Deep Quality Audit: Bug Fixes, Performance Hardening & Code Architecture
- **v7.6.0** — Deep Bug Hunt, Performance Hardening & SyncPlay/Helm Reliability
- **v7.5.0** — Audio Performance Deep Dive & Profile Stats UI Refresh
- **v7.4.0** — Long-Press Context Menu, Frets on Fire Visual Upgrade & Offline Navigation
- **v7.3.1** — Bug Fixes: Relax Mode slider crash, CarPlay disconnect race, offline sync timer
- **v7.3.0** — Offline Network Silence, Battery Optimization & Storage Management
- **v7.2.1** — iOS Lock Screen Desync & CarPlay Browse Fixes
- **v7.2.0** — Lyrics Sync Fix & Track Info in Album View
- **v7.1.0** — Health Check & Reliability Improvements
- **v7.0.0** — Submarine Mode, iOS Lock Screen Fix & Performance

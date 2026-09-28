# Nautune developer guide

Everything needed to build, test, release and find your way around Nautune.
User-facing docs are in [README.md](README.md) and release notes in
[CHANGELOG.md](CHANGELOG.md).

Nautune is **iOS-only** (iPhone, iPad, CarPlay). The Android, Linux, macOS,
Windows and web targets were removed in 9.0.

## Prerequisites

- **Flutter, stable channel.** CI tracks `flutter: stable` unpinned (see
  `codemagic.yaml`), so develop on current stable as well. The Dart SDK
  constraint is in `pubspec.yaml`.
- **Xcode** (latest) on macOS, for anything that builds or runs the iOS app.
- **CocoaPods.** `ios/Podfile` is committed. Run `pod install` from `ios/`.
- An Apple developer team with the **CarPlay audio entitlement** for signed
  builds (see [CarPlay](#carplay)).

`flutter test` and `flutter analyze` don't need Xcode, so any host where
Flutter runs will do for that work.

## Setup and run

```bash
flutter pub get
(cd ios && pod install)
flutter run            # on a connected iPhone or a booted Simulator
```

For a server-free session, sign in with the demo credentials (blank server,
`tester` / `testing`). `lib/demo/demo_content.dart` seeds the library.

For a local signed release build on a Mac, `scripts/build_ios.sh` runs pub
get, analyze, tests, `pod install` and `flutter build ipa` with
`ios/ExportOptions.plist`.

## Tests and analysis

```bash
flutter analyze
flutter test                                        # everything
flutter test test/unit/repo_consistency_test.dart   # just the anti-drift guard
```

Layout:

```
test/
  unit/
    jellyfin/    URL building, auth header, API conformance, pagination
    providers/   provider state
    services/    playback logic, reporting, bootstrap, WAV synthesis
    utils/       downloads (paths, migration, format, status), keywords, ...
    repo_consistency_test.dart   versions, deployment target, docs, CI
  widget_test.dart               smoke test
```

How tests are written here:

- **Extract pure logic into free-standing files** and test those. Examples
  are `lib/services/playback_logic.dart` (queue, crossfade and scrobble
  rules), `lib/utils/download_paths.dart`, `lib/jellyfin/server_uri.dart`
  and `lib/services/wav_builder.dart`. Then tests don't have to start the
  audio, Hive or Jellyfin subsystems.
- **Don't use the real Hive in tests.** `Hive.initFlutter` needs a writable
  path, and parallel tests clash over it. Write a thin in-memory fake.
- **Don't use a real `AudioPlayer`.** audioplayers ships no test doubles, so
  put a narrow interface at the call site and inject a fake.
- HTTP code takes an injectable `http.Client`. Use `MockClient` from
  `package:http/testing.dart`.
- Timers and retries use `fake_async`.

## Releasing and versioning

**The version lives in `pubspec.yaml` `version:` (`X.Y.Z+N`) and nowhere
else.** iOS reads it through `$(FLUTTER_BUILD_NAME)` and
`$(FLUTTER_BUILD_NUMBER)` in `ios/Runner/Info.plist`. At runtime the app
reads it from `PackageInfo` (`lib/app_version.dart`).

To cut a release:

1. Set `version: X.Y.Z+N` in `pubspec.yaml`.
2. Set the same string as the fallback in `lib/app_version.dart`.
3. Add an entry at the **top** of `CHANGELOG.md`, headed exactly
   `### vX.Y.Z - Short Title`.
4. Run `flutter analyze && flutter test`.
5. Commit and push, then start the Codemagic build.

About the build number (`+N`): App Store Connect rejects a second upload with
the same version and build number. Bump `+N` for every TestFlight upload of
the same `X.Y.Z`, and go back to `+1` when `X.Y.Z` changes.

Don't write the app version anywhere else, including README, this file,
comments and example commands. Use `X.Y.Z` placeholders.

### Anti-drift guard

`test/unit/repo_consistency_test.dart` runs with the normal suite and fails
CI when any of these drift:

- The `lib/app_version.dart` fallback doesn't equal the pubspec version.
- The first heading in `CHANGELOG.md` isn't `### v<pubspec version> - ...`,
  or a version heading appears twice.
- `Info.plist` stops using `$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`.
- README, this file or `docs/*.md` contain a `X.Y.Z+N` version string.
- `codemagic.yaml` stops running `flutter test` / `flutter analyze`, or
  overrides the version with `--build-name` / `--build-number`.
- The iOS deployment target differs between `project.pbxproj`,
  `ios/Podfile` and `AppFrameworkInfo.plist`, or README doesn't state it.
- A pubspec asset path, a relative link or image, or a backticked repo path
  (`lib/…`, `ios/…`, …) in the docs points at a missing file.
- A file in `screenshots/` isn't used by README.
- The docs mention a removed platform or feature (the list is in the
  test), or a removed platform folder comes back.

### CI: Codemagic

`codemagic.yaml` defines a single workflow, `ios_release`
("Nautune iOS → TestFlight"), on `flutter: stable` and `xcode: latest`:

1. `flutter clean`, `flutter pub get`, `flutter analyze`, `flutter test`,
   `pod install`. A failing test stops the build.
2. `flutter build ios --release --no-codesign`, which takes the version from
   pubspec.
3. `xcodebuild archive` with automatic signing for
   `$APP_STORE_CONNECT_TEAM_ID`, then `-exportArchive` with
   `ios/ExportOptions.plist` (app-store, automatic signing).
4. The `.ipa` is uploaded to App Store Connect with
   `submit_to_testflight: true` and `submit_to_app_store: false`.
   App Store submission is manual.

The workflow has no `triggering:` block, so builds are started from the
Codemagic UI (or by whatever trigger is set there). To build on every
push, add a `triggering:` section.

Secrets live in Codemagic: `APP_STORE_CONNECT_TEAM_ID`,
`APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_KEY_ID` and
`APP_STORE_CONNECT_ISSUER_ID`.

## Architecture overview

```
lib/
  main.dart          bootstrap: services → providers → NautuneAppState → runApp
  app_state.dart     NautuneAppState: session, library, offline mode, wiring
  providers/         Session, Connectivity, UIState, LibraryData, DemoMode, Theme, SyncStatus,
                     NowPlayingColors
  theme/             palettes, ThemeData builder, NautuneStyle, spacing/radius tokens
  jellyfin/          API client, service, models, URL/auth helpers
  services/          audio, CarPlay, downloads, caches, ListenBrainz, lyrics, easter eggs
  repositories/      MusicRepository: OnlineRepository / OfflineRepository
  screens/ widgets/  UI (widgets/ios/: shared iOS-style building blocks)
  utils/             pure helpers (most unit tests live against these)
ios/Runner/          AppDelegate, SceneDelegate, native plugins, Info.plist
```

**Bootstrap.** `lib/main.dart` sets image-cache limits and starts
`AppVersion`, `LocalCacheService` and a Hive migration in parallel. It then
builds `JellyfinService`, `DownloadService` and the providers, creates
`NautuneAppState`, and exposes everything through `provider`.
`NautuneAppState.initialize()` runs without being awaited, so the first
frame never waits for the network.

**State.** `NautuneAppState` (`lib/app_state.dart`) owns the session, the
selected library, offline mode and the playback settings, and it wires the
services together. `LibraryDataProvider` is the source of truth for albums,
artists and playlists. The same getters on `NautuneAppState` delegate to it.
A `RepositoryFactory` picks `OnlineRepository` or `OfflineRepository`
depending on offline mode.

**Audio.** `AudioPlayerService` (`lib/services/audio_player_service.dart`) is
the engine. It plays through `just_audio` (AVQueuePlayer), wrapped by
`EnginePlayer` (`lib/services/engine/engine_player.dart`), the only code
that talks to just_audio. It handles the queue, gapless playback,
crossfade, ReplayGain, playback speed, the sleep timer, stall recovery and
interruptions (just_audio's own interruption handling is off; the service
ducks and resumes itself). **Gapless:** at 70% the next track is queued on
the same player (`appendNext`), so AVQueuePlayer starts it with no gap and
`_onGaplessAdvance` does the per-track bookkeeping; a track-count sleep
timer ending on the current track, repeat-one and queue edits keep or take
it off the player. **Crossfade** still uses a second player with volume
curves. **Streams** without transcoding play through
`LockCachingAudioSource`, which saves them while they play; finished files
move into the audio cache (`AudioCacheService.adoptFile`), so a track is
downloaded once. The Easter egg screens still use `audioplayers`. The decision logic is pure and
lives in `lib/services/playback_logic.dart`. `NautuneAudioHandler`
(`lib/services/audio_handler.dart`, `audio_service`) publishes the lock
screen and Control Center state. `PlaybackReportingService` reports
start, progress and stop to Jellyfin, with one reporting session per
track; start and stop events recorded offline are persisted per account
(`PendingReportStore`, Hive box `playback_report_queue`, capped at 500).
While backgrounded it keeps reporting progress every 30 s during playback
and stops while paused. `AudioCacheService` keeps streamed copies in a
2 GiB LRU cache in the temporary directory, keyed `trackId@variant`
(`orig`, or `bitrate-codec`) so a lower-quality copy never stands in for a
higher streaming quality (`cacheVariantForUrl` in `playback_logic.dart`).
ReplayGain (`replayGainMultiplier`), the listened-time tracker behind play
counts and scrobbles (`ListenedTimeTracker`) and the cache-key rules are
pure functions in `playback_logic.dart` with unit tests.

**Design system.** `NautuneColorPalette` (`lib/theme/nautune_theme.dart`)
builds the whole `ThemeData`. Each palette has a native brightness; its
`variant()` generates the other brightness with WCAG-checked contrast, and
`withAccent()` swaps in the Now Playing artwork colour. `ThemeProvider`
turns the user's choices (palette, Light / Dark mode, accent source,
corner style, frosted glass, artwork tint) into `theme`, `darkTheme` and
`themeMode` for `MaterialApp`. Choices that have no Material slot travel
in the `NautuneStyle` theme extension: read them with
`NautuneStyle.of(context)`, and use `style.shape(radius)` for corners so the
corner setting is honoured. Use the iOS type roles on `TextTheme`
(`headline`, `body`, `footnote`, …) instead of hard-coded font sizes. Build
new UI from `lib/widgets/ios/`: `FrostedBar`, `LargeTitleScrollView`,
`GroupedSection` / `GroupedTile` and `showNautuneActionSheet`.
`NowPlayingColorsProvider` extracts artwork colours once per artwork, in an
isolate, for every screen that tints from the artwork.

**Library lists.** Albums, artists and genres render through
`IndexedCollectionView` (`lib/widgets/indexed_collection_view.dart`):
fixed-extent rows and grid cells, sticky letter headers, and an A-Z strip.
The strip's scroll offsets come from `sectionOffsets()` in
`lib/utils/letter_index.dart`, computed from the same `SectionGeometry` the
slivers use, so any change to row heights, padding or headers must go
through that geometry. Tiles (`LibraryListRow`, `ArtworkGridTile`) size
themselves with `LibraryTileMetrics`, which scales with the text size.

**Player chrome.** The full player opens with `NowPlayingRoute`
(`lib/widgets/ios/now_playing_route.dart`), which drives its own animation
from vertical drags. The mini player and full player artwork share
`kNowPlayingArtworkHeroTag`. Track rows get queue swipes from
`TrackSwipeActions` and multi-select from `TrackSelection` /
`SelectionActionBar`.

**Remote control and Last.fm.** `RemoteControlService` registers
capabilities (`/Sessions/Capabilities/Full`) and listens on the server's
`/socket` websocket (`dart:io`, reconnects with backoff); the pure
`parseRemoteMessage()` is unit-tested, and `NautuneAppState` executes the
commands. It runs only online, outside demo mode, and while enabled in
Settings. `LastFmService` signs requests with the user's own API key and
secret (`lastFmSignature()`), keeps credentials in the Keychain and queues
failed scrobbles in the `lastfm_queue` Hive box. Scrobbles to both services
fire from `AudioPlayerService._checkPlayThreshold()`.

**CarPlay.** `CarPlayService` (`lib/services/carplay_service.dart`) builds
the `flutter_carplay` templates. See [CarPlay](#carplay).

**Jellyfin.** `JellyfinService` (`lib/jellyfin/jellyfin_service.dart`) is
the app-facing API: caching, pagination, favorites, playlists and
session handling. `JellyfinClient` (`lib/jellyfin/jellyfin_client.dart`)
makes the HTTP calls through `RobustHttpClient`
(`lib/jellyfin/robust_http_client.dart`). It retries with backoff, but
it doesn't retry a POST or DELETE once the request may have been sent.
Every URL goes through `buildServerUri` (`lib/jellyfin/server_uri.dart`)
so reverse-proxy base paths survive. The
auth header comes from `lib/jellyfin/jellyfin_auth_header.dart`. Stream,
download and image URLs are built on `JellyfinTrack`
(`lib/jellyfin/jellyfin_track.dart`).

**Downloads.** `DownloadService` (`lib/services/download_service.dart`).
Downloads are stored in `Application Support/downloads/` (audio, plus `artwork/` per
album). Each track has its own record in the `nautune_downloads` Hive box
(debounced writes). Records keep paths *relative* to that root, so they
survive the app-container UUID changing. The legacy
`Documents/downloads` folder is migrated once, idempotently
(`lib/utils/download_migration.dart`). The root is excluded from iCloud
backup through the `nautune/file_attributes` channel
(`lib/utils/backup_exclusion.dart`, App Review 2.23). AVPlayer-native
originals come from `/Items/{id}/Download`. Other formats come from
`/Audio/{id}/universal` as 320 kbps MP3 (`lib/utils/download_format.dart`).
Queued and in-flight items are re-queued on launch. Cancellation uses
cancel tokens, aborts the socket and removes the temp file. Network loss
re-queues items with backoff (5s up to 2 min) and resumes on connectivity or
app resume. The pause reason (waiting for Wi-Fi or network, storage full or at its
limit) comes from `lib/utils/download_status.dart`. The offline library
grouping and sorting are in `lib/utils/download_library.dart`. The UI
widgets are in `lib/widgets/download_indicators.dart`.

**Offline mode.** `NautuneAppState.isOfflineMode` is
`userWantsOffline || !networkAvailable`. The user preference is toggled
from the Library app bar ⋮ menu (**Go offline** / **Go online**) and
persisted. `networkAvailable` drops only on genuine network failures (see
`BootstrapService.isNetworkFailure`) or an OS connectivity change. While
the server is unreachable, a probe checks it every 30 s and restores the
online state automatically, unless the user chose offline. Going offline
silences all background traffic (reporting, sync timers, image
prewarming) and engages the battery saver. `RepositoryFactory` then serves
`OfflineRepository` (downloads only). `OfflineLibraryScreen` has a Library
tab (offline browsing) and a Manage tab (queue). While offline, the Home
bottom tab turns into a Downloads tab that shows the same browsing view.

**Persistence.** Hive boxes live under `Documents/nautune/`, opened through
`ensureHiveInitialized()` (`lib/services/hive_init.dart`). The session box
(`nautune_session`) and the ListenBrainz box (`listenbrainz_config`) are
AES-encrypted. Their keys are in the Keychain via `flutter_secure_storage`,
with `first_unlock` accessibility so CarPlay can cold-start while the
phone is locked. Other boxes include `nautune_downloads`,
`nautune_playback` (queue and UI state), `nautune_cache` (library cache),
`nautune_playlists`, `nautune_sync_queue` (offline playlist edits),
`nautune_lyrics`, `nautune_analytics`, `nautune_saved_loops` and
`playback_report_queue` (offline Jellyfin start/stop reports) and
`lastfm_queue` (Last.fm scrobbles waiting to be sent).

**On-device storage.**

| Path | Contents | iCloud backup |
|------|----------|---------------|
| `Application Support/downloads/` | offline audio, `artwork/` per album | excluded |
| `Documents/nautune/` | Hive boxes | included |
| `Documents/network/`, `Documents/essential/` | Network and Essential Mix offline audio | excluded |
| `Documents/waveforms/`, `Documents/charts/` | waveform and Frets on Fire chart caches | excluded |
| `tmp/` | streaming audio cache (2 GiB LRU) | n/a |

**Native iOS code** (`ios/Runner/`). All of it is registered in
`AppDelegate.swift` on the shared engine:

| Component | Channel | Purpose |
|-----------|---------|---------|
| `AudioFFTPlugin.swift` | `com.nautune.audio_fft/methods`, `/events` | real-time FFT (MTAudioProcessingTap + vDSP) for visualizers, on its own muted shadow AVPlayer |
| `AudioEffectsPlugin.swift` | `com.nautune.audio_effects` | 10-band equalizer: swizzles `AVQueuePlayer insertItem:afterItem:` (only just_audio uses AVQueuePlayer) and taps each queued item with `vDSP_biquadm` peaking filters. Settings from `EqualizerService` |
| `AudioDecoderPlugin.swift` | `com.elysiumdisc.nautune/audio_decoder` | PCM decoding for Frets on Fire chart generation |
| `SharePlugin.swift` | `com.nautune.share/methods` | share sheet / AirDrop (uses the phone scene, not CarPlay's) |
| `AppIconPlugin.swift` | `com.nautune.app_icon/methods` | alternate app icons |
| `AppDelegate.swift` | `nautune/file_attributes` | `excludeFromBackup` (`isExcludedFromBackup`) |

`SceneDelegate.swift` asks for background time when the app goes to the
background, so playback state gets saved. `ios/Runner/PrivacyInfo.xcprivacy`
is the privacy manifest.

## Jellyfin API notes

- **Spec.** The client is written against the Jellyfin 12.1.0 OpenAPI
  document bundled at `docs/jellyfin-openapi-12.1.json`. Check any new call
  site against it.
- **Minimum server: 10.9.** The client uses the user-scoped routes
  introduced in 10.9: `/UserViews`, `/UserItems/...`,
  `/UserFavoriteItems/{id}`, `/UserImage` and `/Items?userId=`. It doesn't
  use the legacy `/Users/{id}/...` aliases, which aren't in the spec.
- **Auth.** Requests send `Authorization: MediaBrowser Client="Nautune",
  Device=…, DeviceId=…, Version=…, Token=…` with percent-encoded values.
  URLs that can't carry headers (AVPlayer streams, CarPlay and system
  artwork loaders) use the `ApiKey` query parameter. `X-Emby-*` headers and
  `api_key` aren't used, because 12.x gates them behind
  `EnableLegacyAuthorization`.
- **Streaming.** Direct streams are used when AVPlayer can play the format.
  Otherwise playback falls back to `/Audio/{id}/universal` with
  `transcodingProtocol=http` (`progressive` isn't a valid value and gets a
  400).
- **Known deprecation.** `GET /Artists` is deprecated in 12.x, but it
  works for the whole 12.x cycle, and `/Persons` isn't a drop-in
  replacement on 10.11. Revisit once 10.11 support is dropped.
- Log tokens only in redacted form.

## CarPlay

CarPlay is handled end to end by `flutter_carplay`. `Info.plist` declares its
scene delegate, and `lib/services/carplay_service.dart` builds the
templates.

- **Single-list root.** The root is one `CPListTemplate` with the
  sections Library, Listening and Offline. A tab-bar root is still in the
  code behind `static const bool _useTabBarRoot = false`. It's off because
  flutter_carplay 1.3.3 forgets a tab's pushed pages when you switch tabs,
  which leaves their rows dead when you come back. Turn it on only after
  testing on a real head unit.
- The root is built once. Foreground, login, logout and library switches
  only update row text and pop to root.
- Long lists page through the repository, and page sizes respect the car's
  maximum item count. The A-Z indexes are root rows so navigation stays
  within CarPlay's template depth limit.
- Artwork URLs have the token embedded (`ApiKey`) so the system image
  loader can fetch them. Downloaded music uses local files.
- Cold start from CarPlay doesn't wait for a connect event, because the
  plugin can drop that event before Dart starts listening.

### Verifying the CarPlay entitlement survived signing

CarPlay needs the special `com.apple.developer.carplay-audio` entitlement
(Apple-approved, granted per team). `ios/Runner/Runner.entitlements`
declares it, but if Codemagic's automatic signing picks a provisioning
profile that doesn't carry it, the entitlement is **silently stripped**.
CarPlay then never connects, although the app still installs and plays
audio. Before shipping, confirm that the signed IPA carries it:

```bash
unzip -p build/ios/ipa/*.ipa Payload/Runner.app/embedded.mobileprovision \
  | security cms -D | plutil -p - | grep -i carplay
```

The expected output is `"com.apple.developer.carplay-audio" => 1`. If it's
empty, the signing team or bundle ID isn't approved, or the profile is
stale. Re-issue the profile from the Apple Developer portal and run the
Codemagic build again.

## On-device test checklist

Run through this on a real iPhone (and a CarPlay unit or the CarPlay
Simulator) before promoting a TestFlight build:

**Jellyfin servers**
- [ ] Log in to an `https://` server and a LAN `http://` server (Local
      Network prompt appears once).
- [ ] Log in to a reverse-proxy sub-path server (`https://host/jellyfin`):
      browsing, artwork, streaming and profile image all work.
- [ ] Test on the oldest supported server (10.9 or 10.10), on 10.11 and on
      12.x, with legacy authorization disabled.
- [ ] Log out, then log in as another user: queue cleared, no stale
      artwork or library.

**Playback**
- [ ] Gapless album and crossfade transitions; each track scrobbles and
      reports to Jellyfin (Dashboard → Activity).
- [ ] Rapid skip and seek while a track is still loading, with no crash
      and no stuck spinner.
- [ ] Opus, Vorbis or WMA file plays (universal fallback).
- [ ] Phone call or Siri interruption resumes only if it was playing
      before.
- [ ] Lock screen: artwork, scrubbing, next/previous. Sleep timer by time
      and by tracks.
- [ ] Kill the app during playback and relaunch: queue and position are
      restored without waiting on the network.
- [ ] Gapless album (live album or classical): no gap between tracks, and
      every track still scrobbles and reports to Jellyfin.
- [ ] Streamed track: the seek bar's buffered track fills in; after the
      track, replaying it plays from the cache.
- [ ] Playback speed (⋯ menu in the player) and the Equalizer (Settings →
      Audio): presets are clearly audible, Off bypasses it.
- [ ] Visualizer reacts on downloaded, cached and streamed tracks.
- [ ] Easter eggs (Relax Mode, Network, Piano, Frets on Fire) still play.
- [ ] Lock the phone for a few minutes while playing: the Jellyfin
      dashboard shows the current position.
- [ ] Skip a track after a few seconds: its play count doesn't go up.
      Seek past halfway: no scrobble until you've listened long enough.
- [ ] ReplayGain Track/Album with a -6 dB preamp: quiet and loud tracks
      play at a similar level.
- [ ] Transcode Format AAC: an Opus or FLAC track at 128k plays and seeks.
- [ ] Raise streaming quality to Original: a track cached at 128k is
      streamed again rather than replayed from cache.

**Browsing and remote**
- [ ] A-Z index on albums and artists (grid and list, ascending and
      descending) lands on the tapped letter, including letters beyond the
      first page of a large library.
- [ ] Swipe a song right/left in an album, favorites and search; select
      several songs on an album and add them to a playlist.
- [ ] Control Nautune from the Jellyfin web dashboard (play/pause, next,
      seek, send an album); turn off Allow Remote Control and confirm it
      stops.
- [ ] Connect Last.fm with a test API account; a play shows up after the
      threshold, and an offline play is sent after reconnecting.
- [ ] Drag the full player down to close it; the artwork flies back to the
      mini player.

**Look and feel**
- [ ] Each preset and a custom palette in Light / Dark: Palette, System
      (toggle iOS appearance), Light and Dark. Text stays readable.
- [ ] Accent from artwork changes with each album; corners and frosted
      glass toggles apply everywhere.

**Downloads and offline**
- [ ] Download an album and a playlist, kill the app mid-download, and
      relaunch: downloads resume.
- [ ] Cancel a download; retry a failed one.
- [ ] Airplane mode: the library shows downloads only and playback works.
      Turn networking back on: the app reconnects by itself.
- [ ] **Go offline** / **Go online** from the Library ⋮ menu; the choice
      persists across relaunch.
- [ ] Settings → iCloud backup size doesn't include downloads.

**CarPlay**
- [ ] Every root row opens and plays. Switch to Maps and back, and rows
      still respond.
- [ ] Start CarPlay with the phone locked and the app not running (cold
      start).
- [ ] Browse a library with more than 500 albums (pagination) and a long
      playlist.
- [ ] Downloaded Music plays with the phone offline.

## Troubleshooting

- **`pod install` fails or plugins are missing** – run `flutter clean &&
  flutter pub get`, then `cd ios && pod install --repo-update`.
- **CarPlay never shows the app** – check the entitlement (above) and that
  the build is signed with the approved team.
- **"Lost connection to device." at the end of `flutter run`** – expected
  after quitting a debug session. It isn't a crash.
- **HTTP 401 right after upgrading a server** – the session token was
  revoked. Log out and log in again.
- **The Downloads banner says tracks are incompatible** – an older build
  saved them in a format AVPlayer can't open (Opus, WMA, …). Tap
  **Re-download** in the banner to get a playable MP3.

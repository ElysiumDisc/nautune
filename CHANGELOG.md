### v9.1.5 - Bug Hunt: Library, Offline, CarPlay and Easter Eggs

A second full audit. Genre pages work again, offline mode now really
means offline, downloads survive interruptions and device restores,
scrobbles are no longer lost, and every Easter egg got a pass. The player,
visualizers and Frets on Fire use far less battery on 120 Hz iPhones.

**Fixes: library and search**
- Genre pages show their albums again (they were always empty online), with
  a Retry button if loading fails.
- The A-Z index files "The Beatles" under B, matching the server's order,
  and no longer jumps to the wrong letter after loading the rest of the
  library.
- Artist pages list the artist's whole catalogue (it was a random 500
  songs), so Most Listened, Play All and Download cover every song.
- Pull to refresh on Genres and the Recently Added refresh button work.
- The ListenBrainz shelf appears right after connecting, without a
  restart.
- Removing a song from a playlist keeps your place in the list.
- The Easter egg card shows at once instead of waiting behind the search
  spinner.
- Offline, songs with several artists are listed and searchable under
  each artist's own name, and albums without an album ID open.
- Album and artist sort orders are remembered across launches.
- Home shelves never show another library's or account's songs after a
  quick switch.

**Fixes: playback**
- Pausing or unplugging headphones while a track is still loading keeps it
  paused.
- Skipping in the last second of a song no longer lands one track past
  your choice, and starting an album while Infinite Radio tops up the
  queue no longer stops it.
- A track that failed to load, or was restored at launch, resumes where it
  was instead of from 0:00.
- Editing the queue near the end of a song no longer restarts the next
  song.
- Seeking during a crossfade cancels it; an A-B loop no longer triggers a
  crossfade.
- Removing the last song in the queue no longer replays the one before.
- Lock screen and CarPlay show the right elapsed time at other playback
  speeds, and the right length after gapless changes.
- The Essential Mix in a saved queue still plays after an app update.

**Fixes: player**
- Full Art is readable in light mode, and text and icons follow the
  artwork's brightness in Classic, Gradient and Blur.
- The A-B loop bar and the sleep timer sheet fit small iPhones, landscape
  and large text.
- Playback errors show once instead of once per open page.
- Tapping the artist or album in the player shows a cancellable spinner,
  skips the server offline and can't open the page twice.
- The mini player's artwork only flies to and from the player it opened.
- VoiceOver: labels on remaining buttons, the mini player's waveform is a
  slider, and seeking stops at the end of the track.

**Fixes: offline and downloads**
- **Go offline** now also pauses downloads, artwork and home-shelf
  requests. Downloads resume when you go back online.
- Offline albums play in track order after a relaunch (downloads now keep
  track numbers, genres, favorites and ReplayGain; older downloads are
  filled in automatically).
- Interrupted downloads continue where they stopped when the server
  allows it, instead of starting over.
- After restoring an iPhone from a backup, missing downloads show as
  "File missing" so they can be retried, instead of vanishing.
- Removing an album or artist (Downloads or Settings → Storage) keeps
  songs a downloaded playlist still needs.
- Downloads started at launch respect Wi-Fi-only and the concurrency
  setting, and the storage limit counts downloads in progress.
- Changing your server's address keeps your downloads.
- Another account's downloads no longer show in your library.
- Download-complete notifications appear.
- Artwork is cached for large libraries (up to 4,000 images instead of
  200) and downloaded artwork no longer flickers in from the server.
- Storage cleanups ask before deleting.

**Fixes: accounts and privacy**
- Your Jellyfin token no longer ends up in saved download errors or device
  logs.
- Logging out clears search history, and a different account no longer
  inherits the previous one's queue, Last.fm or ListenBrainz links, or
  "Go offline".
- The app's data files are no longer exposed in the Files app.
- Passwordless Jellyfin accounts can sign in, sign-in errors are readable,
  and iOS offers to save your password.

**Fixes: scrobbling and stats**
- Offline and Low Power Mode plays are scrobbled again (they were
  silently dropped).
- Songs of 30 seconds or less aren't sent to Last.fm, and Last.fm gets the
  primary artist instead of a combined "A, B" artist.
- ListenBrainz receives correct MusicBrainz IDs.
- Adding songs to a playlist offline no longer adds them twice when the
  sync is retried.
- Listening time no longer counts paused time, and skips don't count as
  plays. Week, month and year comparisons use the same span of the
  previous period, and last year is kept whole.
- Synced lyrics keep instrumental breaks and read every timestamp format.
- Mood mixes match whole words ("funeral doom" is no longer Upbeat).

**Fixes: CarPlay and iOS**
- Albums and Artists A-Z load each letter from the server, so large
  libraries are complete and letters open quickly.
- Artist pages page past 100 albums.
- Shuffle and repeat buttons show the app's state.
- Pages no longer open on top of Now Playing, or after switching account
  or going offline.
- Rows without artwork no longer request it.
- Low Power Mode at launch turns on the battery saver straight away.
- The chosen app icon no longer triggers "You have changed the icon" at
  launch.

**Fixes: Easter eggs**
- The Network:
  - Channels 7, 162, 170, 178 and 237 play again. Channels whose audio is
    gone from Other People (including 333 and 999) show "Signal lost", and
    Download All can finish.
  - A play/pause button, a download button per channel, and Download All
    asks first, shows the size and respects Wi-Fi-only.
  - Recovers after calls and Siri, and cancelling a download never leaves
    files behind.
- Essential Mix: the download sheet updates live, a failed download can
  be resumed or discarded, the size reads 233.6 MB, and a paused mix no
  longer counts listening time or animates.
- The Easter egg hub opens The Network and Essential Mix offline when
  they're downloaded, and its labels no longer get cut off.
- Relax Mode: sounds recover after calls, a quick slider flick can't leave
  a sound stuck, and the haptic only ticks on and off.
- Healing Frequencies: gapless loops (no dropout every 30 s), recovery
  after calls, and pills with the same frequency no longer light up
  together.
- Frets on Fire:
  - Chords and two-thumb play register every finger.
  - Bonus notes no longer steal taps, notes stay visible until they can no
    longer be hit, and the last note keeps its full timing window.
  - Charts line up with the beat better; existing charts are regenerated.
  - Analyzing long tracks uses far less memory, and one analysis runs at a
    time.
  - A swipe-back mid-song pauses instead of leaving; the cheat no longer
    counts toward records; results add up.
- Piano: repeated notes no longer click or go silent, octave changes are
  instant, and AZERTY/QWERTZ keyboards play the right notes.

**Performance**
- The screen under the full player is no longer redrawn while the player
  is open.
- Visualizers render at 30 fps instead of every display refresh, and stop
  when hidden, paused or in the background.
- Frets on Fire redraws only the note highway each frame.
- Loading skeletons share one animation, and progress bars repaint on
  their own.
- Brief connection drops no longer reload the whole library.

### v9.1.2 - Bug Hunt: Playback, Privacy, Scrobbling and Easter Eggs

A full audit of the app. It fixes crashes in the player, plays counted
twice on the server, lost scrobbles, account data leaking between logins,
and a long list of Easter egg bugs, and makes scrolling and the player
lighter on the battery.

**Fixes: playback**
- Leaving the Lyrics tab no longer breaks the Now Playing tab, and the mini
  player's progress bar no longer breaks after clearing the queue.
- Favoriting a song just as the next one starts no longer puts the old song
  back in its place.
- Skipping near the end of a gapless track no longer skips an extra track.
  Pausing, seeking or unplugging headphones while the next track loads now
  applies to that track.
- Stalled streams recover again. A network dead zone (for example driving
  with CarPlay) waits for the connection instead of stopping, and playback
  resumes by itself when it's back.
- Tracks whose reported length is too short are no longer cut off.
- Turning crossfade off mid-fade no longer leaves playback stuck.
- Removing the current song while paused no longer starts playback.
- Infinite Radio keeps topping up the queue, and no longer adds songs to an
  album you just started.
- "Go offline" is remembered after an album ends or the queue is cleared.
- Battery-saver overrides no longer stick after a restart. Changing
  crossfade, gapless, pre-cache or the visualizer while it's on is kept.
- Saved playback state is written in batches, keeps your queue when
  upgrading, and is never overwritten with defaults after a failed read.
- Clearing the audio cache no longer deletes artwork.
- Streams are saved while they play only on Wi-Fi (or on cellular while
  the visualizer is showing), so skipped songs no longer use cellular data
  to finish downloading.
- The equalizer no longer crackles while you drag a band.

**Fixes: player**
- The player fits small iPhones, large text sizes and landscape; iPhone
  landscape gets a side-by-side layout.
- Dragging the player down no longer jumps when you let go.
- Lyrics no longer show the previous song's words after a quick skip, and
  no longer reload when you favorite a song.
- The mini player's waveform seeks once when you let go instead of on
  every move.
- Opening an album or artist from the player and tapping the mini player
  returns to the open player instead of stacking another one.
- iPad keyboard: holding an arrow keeps seeking or changing volume, and
  held keys no longer trigger other buttons.
- Spectrum visualizers no longer freeze, no longer jump every 10 seconds,
  and fall back to track data when live analysis isn't available.
- Visualizers pause while hidden behind the player or another page, which
  saves battery.

**Fixes: library and search**
- Home shelves (For You, Discover, On This Day, and so on) update when
  their data arrives, and their refresh buttons work.
- Retrying while offline no longer replaces the library with an error
  screen. Cached playlists and favorites stay visible when a refresh fails.
- The Favorites tab no longer refetches on every visit or empties itself
  offline. Tapping a favorite plays the list in the order shown.
- Multi-select → Add to Playlist → Create New Playlist creates the
  playlist.
- Removing or reordering playlist songs works on Jellyfin 10.9 and 10.10,
  and with the same song in a playlist twice.
- CarPlay albums and "add album to playlist" keep track order instead of
  A-Z.
- The Favorites "Recently added" sort is now called "Default": it is the
  server's name order.
- Search keeps your query and results when you switch tabs, only saves
  finished searches to history, and handles large libraries.
- Albums and artists no longer repeat after a failed page load, and the
  loading spinner no longer sticks after a sort change.
- Long playlists and large selections no longer fail with URL-too-long
  errors.
- The Add to Playlist dialog, genre tiles and Storage screen no longer
  overflow on small phones.
- Artwork is loaded at the size it's shown (it was up to three times too
  large), and grids are sharp on iPad.

**Fixes: accounts, privacy and security**
- Your Jellyfin access token is no longer saved in plain text with queues,
  caches and profile stats, and logging out now revokes it on the server.
- Switching accounts no longer carries over the previous account's play
  history, offline playlist edits, cached playlists or queued downloads.
- The remote-control connection no longer puts your token in the URL,
  where it could reach device logs.
- `http://` servers on public hostnames work for streaming and CarPlay
  artwork (the network security settings only allowed local servers).
- Remote-control commands no longer run twice after a brief network drop.
- A turned-off Remote Control setting is respected from launch.

**Fixes: scrobbling and stats**
- Plays are no longer counted twice on the server.
- ListenBrainz scrobbles are no longer lost after a cold launch (the
  service wasn't started until you opened its settings), and queued
  scrobbles are sent when you're back online.
- Songs with several artists scrobble under their real artists instead of
  "Artist & 1 more".
- Connecting ListenBrainz uses the account the token belongs to, and says
  so when the problem is the network rather than the token.
- Last.fm: disconnecting during a send no longer crashes, and one bad
  scrobble no longer blocks the queue.
- Offline start and stop reports are no longer lost when the server is
  briefly unreachable after reconnecting.
- Lyrics are no longer hidden for three days after a failed lookup, and
  aren't fetched offline.
- Profile: artwork colours are no longer swapped (red covers came out
  blue, across the whole app too). Streaks, the week start and the daily
  chart are correct across daylight-saving changes. Revisiting the page no
  longer shows 0 tracks, and it loads faster.
- Light Lavender and custom themes keep secondary text readable.
- The login form scrolls above the keyboard and submits with Return.

**Fixes: downloads and offline**
- A login page from an expired reverse-proxy session is no longer saved as
  a song.
- Removing a playlist's downloads keeps songs that another downloaded
  album or playlist still needs.
- A finished download no longer goes back to the queue when Wi-Fi drops.
- Truncated transcodes are retried instead of kept.
- Album artwork is written safely, so a crash can't leave a broken image.
- Download records are no longer deleted when the downloads folder can't
  be found at launch.
- A server on a network without internet access no longer leaves the app
  stuck offline, and launch no longer waits on a connectivity check.
- Offline playlist edits and favorites are no longer dropped after a few
  failed sync attempts, and are never replayed into another account.

**Fixes: CarPlay and iOS**
- The CarPlay playing indicator follows the current song.
- CarPlay offline pages no longer request artwork from the server.
- The visualizer works for downloaded songs on iOS 15 and 16.
- Fixed rare crashes in the visualizer and the share sheet.

**Fixes: Easter eggs**
- Frets on Fire:
  - The legendary unlock can be earned; bonus notes no longer count
    against a perfect run.
  - Analyzing a song uses a fraction of the memory, so long tracks (and the
    legendary track itself) no longer crash the app.
  - Notes land on the beat, chords can be played fully, and Lightning no
    longer counts one note several times.
  - Play Again no longer misses hundreds of notes at once, the game pauses
    when you leave the app, and your music pauses when a game starts.
  - Scores, play counts and the best multiplier are saved correctly.
- The Network:
  - Interrupted downloads are no longer saved as complete, and downloads
    carry on correctly when you leave the screen.
  - Downloads survive app updates.
  - Channel 999 plays.
  - Tuning in pauses your music.
- Essential Mix: download progress updates, a stalled download can be
  cancelled, and an interrupted download resumes where it stopped.
- Piano keys respond immediately.
- Healing Frequencies no longer clicks every 2 seconds, and the Solfeggio
  syllables are labelled correctly.
- Relax Mode sounds set to zero stop instead of playing silently.

**Performance**
- The full player, the visualizers and Frets on Fire redraw only what
  changes, which matters most on 120 Hz iPhones.
- Skipping no longer resends the whole queue to the lock screen, and
  sliders no longer rewrite all saved state on every move.
- Large server responses and listening history are processed off the main
  thread.

### v9.1.0 - iOS-Native Design, Smarter Audio

Nautune now looks and behaves like an iOS app, keeps every theme you had
(now in light and dark), and fixes several long-standing audio issues.

**Design**
- iOS-native look: Cupertino page transitions, no Android ink ripples,
  grouped-list surfaces, floating snackbars and rounded sheets, all
  coloured from your palette.
- Every palette, including custom ones, has a light and a dark version.
  **Settings → Appearance → Light / Dark** chooses Palette (as before),
  System, Light or Dark. Generated colours are checked for readable
  contrast.
- New customisation: accent colour from the palette or from the playing
  artwork, continuous (iOS) or circular corners, frosted glass on or off,
  and artwork tint on or off.
- Artwork colours are extracted once per album for the whole app, not
  separately by the full player.

**Library**
- The A-Z index lands exactly on the letter you pick, in grid and list
  view, for albums, artists and genres. Letters beyond what's loaded load
  the rest of the library first (it used to jump to the wrong place or
  the end of the first 50 items).
- Smoother scrolling: fixed-height rows and cells, sticky letter headers,
  and no per-row section search. Rows and cells grow with your text size.
- Apple Music-style tiles: artwork with the title and artist underneath,
  round artist photos, action sheet on long press, iOS segmented control
  and pull to refresh, placeholder grid while loading.
- Artist page: Play and Shuffle buttons, Radio and Instant Mix under one
  ⋯ menu, and Top Songs / Songs / Albums sections.
- Search: iOS search field, All / Artists / Albums / Songs filters with
  counts, a Top Result card for the best name match, See All, and artwork
  on every row. Long-press a song for its menu.
- Swipe a song right to play it next, or left to add it to the queue
  (albums, favorites and search). Main tabs no longer switch on a sideways
  swipe, so row swipes don't change tabs by accident.
- Select several songs on an album (checklist button) to play, play next,
  queue, add to a playlist or download them together.
- Favorites sort by recently added, title, artist or album, and playlists
  by name or size. The choice is remembered.
- iPad and other wide windows get a sidebar instead of the tab bar.
- VoiceOver: labelled player controls, and a seek bar you can adjust in
  10-second steps.

**Player**
- The mini player floats above a translucent iOS tab bar, tinted from the
  artwork. Tap or swipe up to open the player, swipe sideways to skip. It
  shows the sleep timer countdown and a thin progress line (or the
  waveform, when the visualizer sits in the controls bar).
- The full player slides up like a sheet and closes by dragging it down,
  with the artwork flying between the mini player and the player.
- Shuffle button in the player. Turning shuffle off restores the original
  order, and the current track keeps playing. Stop moved to the ⋯ menu.
- Shuffle and repeat stay in sync with CarPlay's Now Playing screen and
  Siri.
- Sleep timer: "End of this track" option.
- Smart Shuffle (on by default, Settings → Audio): songs you heard in the
  last few days come later, and the same artist rarely plays twice in a
  row. Turn it off for plain random order.

**Audio engine**
- Music now plays through just_audio. Gapless albums are truly seamless:
  the next track is queued on the same player instead of being swapped in
  after the previous one ends.
- 10-band equalizer (Settings → Audio → Equalizer) with Flat, Bass Boost,
  Treble Boost, Vocal, Rock, Electronic, Acoustic and Late Night presets.
  Boosts get a matching volume cut so they never distort.
- Playback speed from 0.75× to 2× (⋯ menu in the player).
- Streams are saved while they play and then kept in the cache, so a track
  is downloaded once. The seek bar shows real buffering progress.
- The visualizer and the Easter eggs work as before.

**Playback**
- Volume levelling: ReplayGain Off / Track / Album (album uses Jellyfin's
  `AlbumNormalizationGain`) with a preamp from -15 to 0 dB. A negative
  preamp gives quiet tracks room to be raised, which the old full-scale
  cap never allowed.
- Plays and ListenBrainz scrobbles count time actually listened (50% or
  4 minutes). Skipped tracks no longer count as plays, and seeking past
  the halfway point no longer scrobbles.

**Streaming and Jellyfin**
- Progress keeps reporting every 30s while the screen is locked and audio
  plays, so the server's resume position stays current. Paused in the
  background, it sends nothing.
- Offline start and stop reports are saved per account (up to 500) and
  survive the app being killed before it reconnects.
- The audio cache is keyed by track and quality, so raising the streaming
  quality no longer replays a low-bitrate cached copy.
- Transcode Format setting: MP3 (default) or AAC.
- Remote control: the Jellyfin dashboard and other clients can play,
  pause, skip, seek, set volume, shuffle, repeat and send songs or a queue
  to Nautune. It can be turned off with Settings → Audio → Allow Remote
  Control.

**Scrobbling**
- Last.fm scrobbling (Settings → Your Music → Last.fm) using your own free
  Last.fm API account, with now playing and an offline queue that retries,
  alongside ListenBrainz.

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
- Offline, playback never tries to stream: next, previous, gapless and
  auto-advance skip to the nearest downloaded or cached track with a short
  message, and a queue with nothing playable parks paused with a reason.
  Crossfade, Infinite Radio and pre-caching stand down while offline.
- Pending playlist edits and favorites sync automatically on reconnect
  (one sync at a time, so "Go online" no longer sends duplicate creates).
- Offline playlists list every downloaded member in playlist order, not
  just tracks downloaded through that playlist.

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

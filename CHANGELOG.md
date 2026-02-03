### v6.4.2 - CarPlay Stability & ReplayGain Fix

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

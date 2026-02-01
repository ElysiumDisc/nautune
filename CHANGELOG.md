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

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_state.dart';
import '../../jellyfin/jellyfin_album.dart';
import '../../jellyfin/jellyfin_artist.dart';
import '../../jellyfin/jellyfin_track.dart';
import '../tui_keybindings.dart';
import '../tui_metrics.dart';
import '../tui_theme.dart';
import '../widgets/tui_box.dart';
import '../widgets/tui_command_palette.dart';
import '../widgets/tui_help_overlay.dart';
import '../widgets/tui_piano_overlay.dart';
import '../widgets/tui_list.dart';
import 'tui_content_pane.dart';
import 'tui_lyrics_pane.dart';
import 'tui_sidebar.dart';
import 'tui_status_bar.dart';
import 'tui_tab_bar.dart';

/// The focus pane in the TUI.
enum TuiFocus {
  sidebar,
  content,
}

/// The main TUI shell layout manager.
/// Manages panes, keyboard navigation, and state.
class TuiShell extends StatefulWidget {
  const TuiShell({super.key});

  @override
  State<TuiShell> createState() => _TuiShellState();
}

class _TuiShellState extends State<TuiShell> with SingleTickerProviderStateMixin {
  final FocusNode _focusNode = FocusNode();
  final TuiKeyBindings _keyBindings = TuiKeyBindings();

  TuiFocus _focus = TuiFocus.content;
  TuiSidebarItem _selectedSection = TuiSidebarItem.albums;

  // List states for each section
  late TuiListState<JellyfinAlbum> _albumListState;
  late TuiListState<JellyfinArtist> _artistListState;
  late TuiListState<JellyfinTrack> _trackListState;
  late TuiListState<JellyfinTrack> _queueListState;

  // Navigation state
  JellyfinAlbum? _selectedAlbum;
  JellyfinArtist? _selectedArtist;

  // Search state
  bool _isSearchMode = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // Help overlay state
  bool _showHelp = false;

  // Command palette state
  bool _showCommandPalette = false;

  // Visualizer state (persisted via Hive in status bar)
  bool _showVisualizer = true;

  // Piano overlay state
  bool _showPiano = false;

  // Stream subscriptions from _loadInitialData
  StreamSubscription? _queueSubscription;
  StreamSubscription? _trackColorSubscription;

  // Animation ticker for color lerp
  late Ticker _colorTicker;
  Duration _lastTickTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    TuiMetrics.initialize();

    // Initialize theme manager (loads saved theme)
    TuiThemeManager.instance.initialize();

    _albumListState = TuiListState<JellyfinAlbum>(
      nameGetter: (album) => album.name,
    );
    _artistListState = TuiListState<JellyfinArtist>(
      nameGetter: (artist) => artist.name,
    );
    _trackListState = TuiListState<JellyfinTrack>(
      nameGetter: (track) => track.name,
    );
    _queueListState = TuiListState<JellyfinTrack>(
      nameGetter: (track) => track.name,
    );

    // Color transition ticker
    _colorTicker = createTicker(_onColorTick);
    _colorTicker.start();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _loadInitialData();
    });
  }

  void _onColorTick(Duration elapsed) {
    final delta = elapsed - _lastTickTime;
    _lastTickTime = elapsed;
    TuiThemeManager.instance.tickLerp(delta);
  }

  void _loadInitialData() {
    final appState = context.read<NautuneAppState>();

    // Load albums
    final albums = appState.albums ?? [];
    _albumListState.setItems(albums);

    // Load artists
    final artists = appState.artists ?? [];
    _artistListState.setItems(artists);

    // Listen to queue changes
    _queueSubscription = appState.audioPlayerService.queueStream.listen((queue) {
      if (mounted) {
        setState(() {
          _queueListState.setItems(queue);
        });
      }
    });

    // Listen to track changes for color extraction
    _trackColorSubscription = appState.audioPlayerService.currentTrackStream.listen((track) {
      if (mounted && track != null) {
        _extractColorFromTrack(track, appState);
      }
    });
  }

  void _extractColorFromTrack(JellyfinTrack track, NautuneAppState appState) {
    final imageUrl = track.artworkUrl();
    final headers = appState.jellyfinService.imageHeaders();
    TuiThemeManager.instance.extractPrimaryColor(imageUrl, headers);
  }

  @override
  void dispose() {
    _queueSubscription?.cancel();
    _trackColorSubscription?.cancel();
    _colorTicker.dispose();
    _focusNode.dispose();
    _searchFocusNode.dispose();
    _keyBindings.dispose();
    _albumListState.dispose();
    _artistListState.dispose();
    _trackListState.dispose();
    _queueListState.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TuiThemeManager.instance,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: TuiColors.background,
          body: KeyboardListener(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: Stack(
              children: [
                // ClipRect prevents overflow errors on very small windows
                ClipRect(
                  child: Column(
                    children: [
                      // Tab bar (draggable for window movement)
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanStart: (_) => windowManager.startDragging(),
                        child: TuiTabBar(
                          selectedSection: _selectedSection,
                          onSectionSelected: _onSidebarItemSelected,
                        ),
                      ),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Sidebar
                            TuiSidebar(
                              selectedItem: _selectedSection,
                              onItemSelected: _onSidebarItemSelected,
                              focused: _focus == TuiFocus.sidebar,
                            ),
                            // Vertical divider
                            const TuiVerticalDivider(),
                            // Content pane
                            Expanded(
                              child: _buildContentPane(),
                            ),
                          ],
                        ),
                      ),
                      // Status bar
                      TuiStatusBar(showVisualizer: _showVisualizer),
                    ],
                  ),
                ),
                // Search overlay
                if (_isSearchMode) _buildSearchOverlay(),
                // Help overlay
                if (_showHelp)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => setState(() => _showHelp = false),
                      child: const TuiHelpOverlay(),
                    ),
                  ),
                // Command palette overlay
                if (_showCommandPalette)
                  Positioned.fill(
                    child: TuiCommandPalette(
                      onAction: (action) {
                        setState(() => _showCommandPalette = false);
                        _focusNode.requestFocus();
                        _handleAction(action);
                      },
                      onDismiss: () {
                        setState(() => _showCommandPalette = false);
                        _focusNode.requestFocus();
                      },
                    ),
                  ),
                // Piano overlay
                if (_showPiano)
                  Positioned.fill(
                    child: TuiPianoOverlay(
                      onDismiss: () {
                        setState(() => _showPiano = false);
                        _focusNode.requestFocus();
                      },
                    ),
                  ),
                // Resize handle (bottom-right corner)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onPanStart: (_) => windowManager.startResizing(ResizeEdge.bottomRight),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeDownRight,
                      child: Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.bottomRight,
                        child: Icon(
                          Icons.drag_handle,
                          size: 12,
                          color: TuiColors.dim,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContentPane() {
    // Special handling for lyrics section
    if (_selectedSection == TuiSidebarItem.lyrics) {
      return TuiLyricsPane(
        focused: _focus == TuiFocus.content,
      );
    }

    return TuiContentPane(
      section: _selectedSection,
      focused: _focus == TuiFocus.content,
      albumListState: _albumListState,
      artistListState: _artistListState,
      trackListState: _trackListState,
      queueListState: _queueListState,
      onAlbumSelected: _onAlbumSelected,
      onArtistSelected: _onArtistSelected,
      onTrackSelected: _onTrackSelected,
      onQueueTrackSelected: _onQueueTrackSelected,
      selectedAlbum: _selectedAlbum,
      selectedArtist: _selectedArtist,
      searchQuery: _searchQuery,
    );
  }

  Widget _buildSearchOverlay() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: TuiColors.background,
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Text('/ ', style: TuiTextStyles.accent),
            Expanded(
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                autofocus: true,
                style: TuiTextStyles.normal,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Search...',
                  hintStyle: TuiTextStyles.dim,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                cursorColor: TuiColors.accent,
                onSubmitted: _onSearchSubmit,
              ),
            ),
            Text(' (Esc to cancel)', style: TuiTextStyles.dim),
          ],
        ),
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    // Dismiss help on any key
    if (_showHelp) {
      if (event is KeyDownEvent) {
        setState(() => _showHelp = false);
      }
      return;
    }

    // Command palette handles its own keys
    if (_showCommandPalette) {
      return;
    }

    // Piano overlay handles its own keys
    if (_showPiano) {
      return;
    }

    // Handle search mode separately - guard against Enter key race condition
    // (onSubmitted may have already set _isSearchMode = false before this fires)
    if (_isSearchMode || _searchFocusNode.hasFocus) {
      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          _isSearchMode = false;
          _searchController.clear();
        });
        _focusNode.requestFocus();
      }
      return;
    }

    final action = _keyBindings.handleKeyEvent(event);
    _handleAction(action);
  }

  void _handleAction(TuiAction action) {
    final appState = context.read<NautuneAppState>();
    final audioService = appState.audioPlayerService;

    switch (action) {
      case TuiAction.none:
        break;

      case TuiAction.quit:
        exit(0);

      case TuiAction.escape:
        _handleEscape();
        break;

      case TuiAction.moveUp:
        _handleMoveUp();
        break;

      case TuiAction.moveDown:
        _handleMoveDown();
        break;

      case TuiAction.moveLeft:
        _handleMoveLeft();
        break;

      case TuiAction.moveRight:
        _handleMoveRight();
        break;

      case TuiAction.goToTop:
        _handleGoToTop();
        break;

      case TuiAction.goToBottom:
        _handleGoToBottom();
        break;

      case TuiAction.pageUp:
        _handlePageUp();
        break;

      case TuiAction.pageDown:
        _handlePageDown();
        break;

      case TuiAction.select:
        _handleSelect();
        break;

      case TuiAction.playPause:
        audioService.playPause();
        break;

      case TuiAction.nextTrack:
        audioService.next();
        break;

      case TuiAction.previousTrack:
        audioService.previous();
        break;

      case TuiAction.volumeUp:
        final currentVol = audioService.volume;
        audioService.setVolume((currentVol + 0.05).clamp(0.0, 1.0));
        break;

      case TuiAction.volumeDown:
        final currentVol = audioService.volume;
        audioService.setVolume((currentVol - 0.05).clamp(0.0, 1.0));
        break;

      case TuiAction.toggleMute:
        final currentVol = audioService.volume;
        audioService.setVolume(currentVol > 0 ? 0.0 : 1.0);
        break;

      case TuiAction.toggleShuffle:
        audioService.shuffleQueue();
        break;

      case TuiAction.toggleRepeat:
        audioService.toggleRepeatMode();
        break;

      case TuiAction.search:
        setState(() {
          _isSearchMode = true;
          _selectedSection = TuiSidebarItem.search;
          _focus = TuiFocus.content;
          _searchController.clear();
        });
        // Explicitly request focus for the search field after rebuild
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
        break;

      case TuiAction.stop:
        audioService.stop();
        break;

      case TuiAction.clearQueue:
        audioService.stop();
        break;

      case TuiAction.deleteFromQueue:
        if (_selectedSection == TuiSidebarItem.queue) {
          final index = _queueListState.cursorIndex;
          audioService.removeFromQueue(index);
        }
        break;

      // Seek controls
      case TuiAction.seekForward:
        _seekBy(const Duration(seconds: 5));
        break;

      case TuiAction.seekBackward:
        _seekBy(const Duration(seconds: -5));
        break;

      case TuiAction.seekForwardLarge:
        _seekBy(const Duration(seconds: 60));
        break;

      case TuiAction.seekBackwardLarge:
        _seekBy(const Duration(seconds: -60));
        break;

      // Letter jumping
      case TuiAction.jumpNextLetter:
        _currentListState?.jumpNextLetter();
        break;

      case TuiAction.jumpPrevLetter:
        _currentListState?.jumpPrevLetter();
        break;

      // Favorite
      case TuiAction.toggleFavorite:
        _handleToggleFavorite();
        break;

      // Queue operations
      case TuiAction.addToQueue:
        _handleAddToQueue();
        break;

      case TuiAction.moveQueueUp:
        _handleMoveQueueUp();
        break;

      case TuiAction.moveQueueDown:
        _handleMoveQueueDown();
        break;

      // Full reset
      case TuiAction.fullReset:
        audioService.stop();
        break;

      // Help
      case TuiAction.toggleHelp:
        setState(() => _showHelp = !_showHelp);
        break;

      // Theme cycling
      case TuiAction.cycleTheme:
        TuiThemeManager.instance.cycleTheme();
        break;

      // Section cycling
      case TuiAction.cycleSection:
        _handleCycleSection();
        break;

      // A-B loop controls
      case TuiAction.setLoopStart:
        if (audioService.isLoopAvailable) {
          audioService.setLoopStart();
        }
        break;

      case TuiAction.setLoopEnd:
        if (audioService.isLoopAvailable) {
          audioService.setLoopEnd();
        }
        break;

      case TuiAction.clearLoop:
        audioService.clearLoop();
        break;

      // Visualizer toggle
      case TuiAction.toggleVisualizer:
        _handleToggleVisualizer();
        break;

      // Command palette
      case TuiAction.commandPalette:
        setState(() => _showCommandPalette = !_showCommandPalette);
        break;

      // Piano
      case TuiAction.togglePiano:
        setState(() => _showPiano = !_showPiano);
        break;
    }
  }

  void _seekBy(Duration delta) {
    final appState = context.read<NautuneAppState>();
    final audioService = appState.audioPlayerService;
    final currentPosition = audioService.currentPosition;
    final currentTrack = audioService.currentTrack;
    final trackDuration = currentTrack?.duration;

    if (trackDuration == null) return;

    final newPosition = (currentPosition + delta).inMilliseconds.clamp(
      0,
      trackDuration.inMilliseconds,
    );
    audioService.seek(Duration(milliseconds: newPosition));
  }

  void _handleToggleFavorite() async {
    final appState = context.read<NautuneAppState>();
    JellyfinTrack? track;

    // Get selected track based on current context
    if (_selectedSection == TuiSidebarItem.queue) {
      track = _queueListState.selectedItem;
    } else if (_selectedAlbum != null || _selectedSection == TuiSidebarItem.search) {
      track = _trackListState.selectedItem;
    }

    if (track == null) return;

    try {
      final isFavorite = track.isFavorite;
      await appState.jellyfinService.markFavorite(track.id, !isFavorite);
    } catch (e) {
      debugPrint('TUI: Failed to toggle favorite: $e');
    }
  }

  void _handleAddToQueue() {
    final appState = context.read<NautuneAppState>();
    final audioService = appState.audioPlayerService;
    JellyfinTrack? track;

    if (_selectedAlbum != null || _selectedSection == TuiSidebarItem.search) {
      track = _trackListState.selectedItem;
    }

    if (track != null) {
      audioService.addToQueue([track]);
    }
  }

  void _handleMoveQueueUp() {
    if (_selectedSection != TuiSidebarItem.queue) return;

    final appState = context.read<NautuneAppState>();
    final audioService = appState.audioPlayerService;
    final index = _queueListState.cursorIndex;

    if (index > 0) {
      audioService.reorderQueue(index, index - 1);
      _queueListState.moveUp();
    }
  }

  void _handleMoveQueueDown() {
    if (_selectedSection != TuiSidebarItem.queue) return;

    final appState = context.read<NautuneAppState>();
    final audioService = appState.audioPlayerService;
    final index = _queueListState.cursorIndex;

    if (index < _queueListState.length - 1) {
      audioService.reorderQueue(index, index + 1);
      _queueListState.moveDown();
    }
  }

  void _handleToggleVisualizer() {
    setState(() {
      _showVisualizer = !_showVisualizer;
    });
  }

  void _handleCycleSection() {
    final items = TuiSidebarItem.values;
    final currentIndex = items.indexOf(_selectedSection);
    final nextIndex = (currentIndex + 1) % items.length;
    setState(() {
      _selectedSection = items[nextIndex];
      _focus = TuiFocus.content;
      _onSectionChanged();
    });
  }

  void _handleEscape() {
    setState(() {
      if (_selectedAlbum != null) {
        _selectedAlbum = null;
        _trackListState.setItems([]);
      } else if (_selectedArtist != null) {
        _selectedArtist = null;
        _reloadAlbums();
      } else if (_focus == TuiFocus.content) {
        _focus = TuiFocus.sidebar;
      }
    });
  }

  void _handleMoveUp() {
    if (_focus == TuiFocus.sidebar) {
      final items = TuiSidebarItem.values;
      final currentIndex = items.indexOf(_selectedSection);
      if (currentIndex > 0) {
        setState(() {
          _selectedSection = items[currentIndex - 1];
          _onSectionChanged();
        });
      }
    } else {
      _currentListState?.moveUp();
    }
  }

  void _handleMoveDown() {
    if (_focus == TuiFocus.sidebar) {
      final items = TuiSidebarItem.values;
      final currentIndex = items.indexOf(_selectedSection);
      if (currentIndex < items.length - 1) {
        setState(() {
          _selectedSection = items[currentIndex + 1];
          _onSectionChanged();
        });
      }
    } else {
      _currentListState?.moveDown();
    }
  }

  void _handleMoveLeft() {
    if (_focus == TuiFocus.content) {
      if (_selectedAlbum != null) {
        setState(() {
          _selectedAlbum = null;
          _trackListState.setItems([]);
        });
      } else if (_selectedArtist != null) {
        setState(() {
          _selectedArtist = null;
          _reloadAlbums();
        });
      } else {
        setState(() {
          _focus = TuiFocus.sidebar;
        });
      }
    }
  }

  void _handleMoveRight() {
    if (_focus == TuiFocus.sidebar) {
      setState(() {
        _focus = TuiFocus.content;
      });
    } else {
      _handleSelect();
    }
  }

  void _handleGoToTop() {
    if (_focus == TuiFocus.sidebar) {
      setState(() {
        _selectedSection = TuiSidebarItem.values.first;
        _onSectionChanged();
      });
    } else {
      _currentListState?.goToTop();
    }
  }

  void _handleGoToBottom() {
    if (_focus == TuiFocus.sidebar) {
      setState(() {
        _selectedSection = TuiSidebarItem.values.last;
        _onSectionChanged();
      });
    } else {
      _currentListState?.goToBottom();
    }
  }

  void _handlePageUp() {
    _currentListState?.pageUp();
  }

  void _handlePageDown() {
    _currentListState?.pageDown();
  }

  void _handleSelect() {
    if (_focus == TuiFocus.sidebar) {
      setState(() {
        _focus = TuiFocus.content;
      });
      return;
    }

    switch (_selectedSection) {
      case TuiSidebarItem.albums:
        if (_selectedAlbum != null) {
          final track = _trackListState.selectedItem;
          if (track != null) {
            _onTrackSelected(track);
          }
        } else {
          final album = _albumListState.selectedItem;
          if (album != null) {
            _onAlbumSelected(album);
          }
        }
        break;

      case TuiSidebarItem.artists:
        if (_selectedArtist != null) {
          final album = _albumListState.selectedItem;
          if (album != null) {
            _onAlbumSelected(album);
          }
        } else {
          final artist = _artistListState.selectedItem;
          if (artist != null) {
            _onArtistSelected(artist);
          }
        }
        break;

      case TuiSidebarItem.queue:
        final track = _queueListState.selectedItem;
        if (track != null) {
          _onQueueTrackSelected(track);
        }
        break;

      case TuiSidebarItem.lyrics:
        // Lyrics pane has no selection
        break;

      case TuiSidebarItem.search:
        final track = _trackListState.selectedItem;
        if (track != null) {
          _onTrackSelected(track);
        }
        break;
    }
  }

  TuiListState? get _currentListState {
    switch (_selectedSection) {
      case TuiSidebarItem.albums:
        return _selectedAlbum != null ? _trackListState : _albumListState;
      case TuiSidebarItem.artists:
        return _selectedArtist != null ? _albumListState : _artistListState;
      case TuiSidebarItem.queue:
        return _queueListState;
      case TuiSidebarItem.lyrics:
        return null;
      case TuiSidebarItem.search:
        return _trackListState;
    }
  }

  void _onSidebarItemSelected(TuiSidebarItem item) {
    setState(() {
      _selectedSection = item;
      _focus = TuiFocus.content;
      _onSectionChanged();
    });
  }

  void _onSectionChanged() {
    // Reset navigation state when switching sections
    _selectedAlbum = null;
    _selectedArtist = null;
    _trackListState.setItems([]);

    if (_selectedSection == TuiSidebarItem.albums) {
      _reloadAlbums();
    } else if (_selectedSection == TuiSidebarItem.artists) {
      _reloadArtists();
    }
  }

  void _reloadAlbums() {
    final appState = context.read<NautuneAppState>();
    final albums = appState.albums ?? [];
    _albumListState.setItems(albums);
  }

  void _reloadArtists() {
    final appState = context.read<NautuneAppState>();
    final artists = appState.artists ?? [];
    _artistListState.setItems(artists);
  }

  void _onAlbumSelected(JellyfinAlbum album) async {
    setState(() {
      _selectedAlbum = album;
    });

    final appState = context.read<NautuneAppState>();
    try {
      final tracks = await appState.getAlbumTracks(album.id);
      if (mounted) {
        setState(() {
          _trackListState.setItems(tracks);
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch album tracks: $e');
    }
  }

  void _onArtistSelected(JellyfinArtist artist) async {
    setState(() {
      _selectedArtist = artist;
    });

    final appState = context.read<NautuneAppState>();
    try {
      final albums = await appState.jellyfinService.loadAlbumsByArtist(artistId: artist.id);
      if (mounted) {
        setState(() {
          _albumListState.setItems(albums);
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch artist albums: $e');
    }
  }

  void _onTrackSelected(JellyfinTrack track) {
    final appState = context.read<NautuneAppState>();
    final audioService = appState.audioPlayerService;

    // Get all tracks in current list and play from selected
    final tracks = _trackListState.items;

    audioService.playTrack(track, queueContext: tracks);
  }

  void _onQueueTrackSelected(JellyfinTrack track) {
    final appState = context.read<NautuneAppState>();
    final audioService = appState.audioPlayerService;

    final queue = _queueListState.items;
    final index = queue.indexWhere((t) => t.id == track.id);

    if (index >= 0) {
      audioService.jumpToQueueIndex(index);
    }
  }

  void _onSearchSubmit(String query) {
    setState(() {
      _isSearchMode = false;
      _searchQuery = query;
    });
    _focusNode.requestFocus();

    if (query.isEmpty) {
      _trackListState.setItems([]);
      return;
    }

    _performSearch(query);
  }

  void _performSearch(String query) async {
    final appState = context.read<NautuneAppState>();
    try {
      // Get current library ID
      final libraries = appState.libraries;
      if (libraries == null || libraries.isEmpty) {
        debugPrint('No libraries available for search');
        return;
      }
      final libraryId = libraries.first.id;

      final results = await appState.jellyfinService.searchTracks(
        libraryId: libraryId,
        query: query,
      );
      if (mounted) {
        setState(() {
          _trackListState.setItems(results);
        });
      }
    } catch (e) {
      debugPrint('Search failed: $e');
    }
  }
}

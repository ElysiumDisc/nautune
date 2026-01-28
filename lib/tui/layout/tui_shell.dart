import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../jellyfin/jellyfin_album.dart';
import '../../jellyfin/jellyfin_artist.dart';
import '../../jellyfin/jellyfin_track.dart';
import '../tui_keybindings.dart';
import '../tui_metrics.dart';
import '../tui_theme.dart';
import '../widgets/tui_box.dart';
import '../widgets/tui_list.dart';
import 'tui_content_pane.dart';
import 'tui_sidebar.dart';
import 'tui_status_bar.dart';

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

class _TuiShellState extends State<TuiShell> {
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

  @override
  void initState() {
    super.initState();
    TuiMetrics.initialize();

    _albumListState = TuiListState<JellyfinAlbum>();
    _artistListState = TuiListState<JellyfinArtist>();
    _trackListState = TuiListState<JellyfinTrack>();
    _queueListState = TuiListState<JellyfinTrack>();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _loadInitialData();
    });
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
    appState.audioPlayerService.queueStream.listen((queue) {
      if (mounted) {
        setState(() {
          _queueListState.setItems(queue);
        });
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
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
    return Scaffold(
      backgroundColor: TuiColors.background,
      body: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Stack(
          children: [
            Column(
              children: [
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
                        child: TuiContentPane(
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
                        ),
                      ),
                    ],
                  ),
                ),
                // Status bar
                const TuiStatusBar(),
              ],
            ),
            // Search overlay
            if (_isSearchMode) _buildSearchOverlay(),
          ],
        ),
      ),
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
    // Handle search mode separately
    if (_isSearchMode) {
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
    }
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

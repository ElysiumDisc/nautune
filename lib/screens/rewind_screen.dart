import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/rewind_data.dart';
import '../services/rewind_service.dart';
import '../services/rewind_export_service.dart';
import '../widgets/rewind/rewind_cards.dart';
import '../widgets/rewind/rewind_year_picker.dart';

/// Full-screen Rewind experience with swipeable cards
class RewindScreen extends StatefulWidget {
  final int? initialYear;

  const RewindScreen({super.key, this.initialYear});

  @override
  State<RewindScreen> createState() => _RewindScreenState();
}

class _RewindScreenState extends State<RewindScreen> with TickerProviderStateMixin {
  late final PageController _pageController;
  late final RewindService _rewindService;
  late AnimationController _fadeController;

  int? _selectedYear;
  RewindData? _data;
  int _currentPage = 0;
  bool _isLoading = true;
  final List<GlobalKey> _cardKeys = [];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _rewindService = RewindService();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    // Default to previous year (Rewind shows last year's data)
    _selectedYear = widget.initialYear ?? DateTime.now().year - 1;
    _loadRewindData();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _loadRewindData() async {
    setState(() {
      _isLoading = true;
    });

    // Try to get server data for accurate stats (only for All Time)
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final libraryId = appState.selectedLibraryId;

    RewindData? data;
    if (libraryId != null) {
      // Use server data for accurate play counts
      data = await _rewindService.computeRewindFromServer(
        jellyfinService: appState.jellyfinService,
        libraryId: libraryId,
        year: _selectedYear,
      );
    } else {
      // Fallback to local analytics
      data = _rewindService.computeRewind(_selectedYear);
    }

    if (!mounted) return;

    setState(() {
      _data = data;
      _cardKeys.clear();
      // Generate keys for each card
      for (int i = 0; i < 11; i++) {
        _cardKeys.add(GlobalKey());
      }
      _isLoading = false;
    });
    _fadeController.forward(from: 0);
  }

  void _onYearSelected(int? year) {
    if (year == _selectedYear) return;
    setState(() {
      _selectedYear = year;
      _currentPage = 0;
    });
    // Defer jump until after the next frame when controller is attached
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    });
    _loadRewindData();
  }

  Future<void> _shareAllCards() async {
    if (_cardKeys.isEmpty || !_pageController.hasClients) return;

    final originalPage = _currentPage;

    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Exporting all pages...'),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 60),
      ),
    );

    // Capture each page by navigating to it
    final List<Uint8List> pageImages = [];
    for (int i = 0; i < _cardKeys.length; i++) {
      // Jump to page (no animation for speed)
      _pageController.jumpToPage(i);

      // Wait for the page to render
      await Future.delayed(const Duration(milliseconds: 150));
      await WidgetsBinding.instance.endOfFrame;

      // Capture the page
      final imageBytes = await RewindExportService.instance.captureWidget(
        _cardKeys[i],
        pixelRatio: 3.0,
      );

      if (imageBytes != null) {
        pageImages.add(imageBytes);
        debugPrint('RewindExportService: Captured page ${i + 1}/${_cardKeys.length}');
      } else {
        debugPrint('RewindExportService: Failed to capture page ${i + 1}');
      }
    }

    // Return to original page
    _pageController.jumpToPage(originalPage);

    if (!mounted) return;

    // Export as PDF
    ExportResult result;
    if (pageImages.isEmpty) {
      result = ExportResult.error;
    } else {
      final pdfFile = await RewindExportService.instance.exportAllPagesAsPdf(
        pageImages: pageImages,
        year: _selectedYear,
      );

      if (pdfFile != null) {
        final yearStr = _selectedYear?.toString() ?? 'All Time';
        result = await RewindExportService.instance.shareFile(
          pdfFile,
          title: 'My $yearStr Nautune Rewind',
        );
      } else {
        result = ExportResult.error;
      }
    }

    if (!mounted) return;

    // Clear the loading snackbar
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (result == ExportResult.success) {
      final yearStr = _selectedYear?.toString() ?? 'All Time';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$yearStr Rewind exported!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (result == ExportResult.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to export Rewind'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final availableYears = _rewindService.getAvailableYears();

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: GestureDetector(
          onTap: () => _showYearPicker(context, availableYears),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _selectedYear?.toString() ?? 'All Time',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down, size: 24),
            ],
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Export all pages',
            onPressed: _shareAllCards,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _data == null || !_data!.hasEnoughData
              ? _buildNoDataView(context)
              : _buildRewindView(context),
    );
  }

  Widget _buildNoDataView(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_off,
              size: 80,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 24),
            Text(
              'Not Enough Data',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Keep listening to build your Rewind!\nYou need at least 10 plays to generate stats.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _goToPreviousPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToNextPage() {
    if (_currentPage < 10) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Widget _buildRewindView(BuildContext context) {
    final theme = Theme.of(context);
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final isDesktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;

    return Column(
      children: [
        // Main card view with optional arrow navigation
        Expanded(
          child: Stack(
            children: [
              PageView(
                controller: _pageController,
                onPageChanged: (page) {
                  setState(() => _currentPage = page);
                },
                children: [
                  // 0: Welcome card
                  RewindWelcomeCard(
                    data: _data!,
                    repaintBoundaryKey: _cardKeys[0],
                  ),
                  // 1: Total Time
                  RewindTotalTimeCard(
                    data: _data!,
                    repaintBoundaryKey: _cardKeys[1],
                  ),
                  // 2: Top Artist
                  RewindTopArtistCard(
                    data: _data!,
                    jellyfinService: appState.jellyfinService,
                    repaintBoundaryKey: _cardKeys[2],
                  ),
                  // 3: Top 5 Artists
                  RewindTopArtistsListCard(
                    data: _data!,
                    jellyfinService: appState.jellyfinService,
                    repaintBoundaryKey: _cardKeys[3],
                  ),
                  // 4: Top Album
                  RewindTopAlbumCard(
                    data: _data!,
                    jellyfinService: appState.jellyfinService,
                    repaintBoundaryKey: _cardKeys[4],
                  ),
                  // 5: Top 5 Albums
                  RewindTopAlbumsGridCard(
                    data: _data!,
                    jellyfinService: appState.jellyfinService,
                    repaintBoundaryKey: _cardKeys[5],
                  ),
                  // 6: Top Track
                  RewindTopTrackCard(
                    data: _data!,
                    jellyfinService: appState.jellyfinService,
                    repaintBoundaryKey: _cardKeys[6],
                  ),
                  // 7: Top Genre
                  RewindTopGenreCard(
                    data: _data!,
                    repaintBoundaryKey: _cardKeys[7],
                  ),
                  // 8: Personality
                  RewindPersonalityCard(
                    data: _data!,
                    repaintBoundaryKey: _cardKeys[8],
                  ),
                  // 9: Summary Stats
                  RewindSummaryCard(
                    data: _data!,
                    repaintBoundaryKey: _cardKeys[9],
                  ),
                  // 10: Share card
                  RewindShareCard(
                    data: _data!,
                    onShare: _shareAllCards,
                    repaintBoundaryKey: _cardKeys[10],
                  ),
                ],
              ),
              // Arrow navigation for desktop
              if (isDesktop) ...[
                // Left arrow
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _currentPage > 0 ? 1.0 : 0.3,
                      duration: const Duration(milliseconds: 200),
                      child: IconButton.filled(
                        onPressed: _currentPage > 0 ? _goToPreviousPage : null,
                        icon: const Icon(Icons.chevron_left, size: 32),
                        style: IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
                          foregroundColor: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
                // Right arrow
                Positioned(
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _currentPage < 10 ? 1.0 : 0.3,
                      duration: const Duration(milliseconds: 200),
                      child: IconButton.filled(
                        onPressed: _currentPage < 10 ? _goToNextPage : null,
                        icon: const Icon(Icons.chevron_right, size: 32),
                        style: IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
                          foregroundColor: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        // Page indicator
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Dots indicator
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(11, (index) {
                    final isActive = index == _currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      height: 8,
                      width: isActive ? 24 : 8,
                      decoration: BoxDecoration(
                        color: isActive
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 8),
                Text(
                  isDesktop ? 'Use arrows to navigate' : 'Swipe to explore',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showYearPicker(BuildContext context, List<int> availableYears) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => RewindYearPicker(
        availableYears: availableYears,
        selectedYear: _selectedYear,
        onYearSelected: (year) {
          Navigator.pop(context);
          _onYearSelected(year);
        },
      ),
    );
  }
}

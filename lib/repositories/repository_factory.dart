import '../jellyfin/jellyfin_playlist_store.dart';
import '../jellyfin/jellyfin_service.dart';
import '../services/download_service.dart';
import 'music_repository.dart';
import 'offline_repository.dart';
import 'online_repository.dart';

/// Factory for creating the appropriate MusicRepository based on mode.
class RepositoryFactory {
  /// Creates a repository based on offline mode state.
  ///
  /// Returns OnlineRepository when online, OfflineRepository when offline.
  static MusicRepository create({
    required bool isOfflineMode,
    required JellyfinService jellyfinService,
    required DownloadService downloadService,
    JellyfinPlaylistStore? playlistStore,
  }) {
    if (isOfflineMode) {
      return OfflineRepository(
        downloadService: downloadService,
        playlistStore: playlistStore,
      );
    } else {
      return OnlineRepository(jellyfinService: jellyfinService);
    }
  }
}

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../app_state.dart';

class CarPlayService {
  static const MethodChannel _channel = MethodChannel('com.nautune/carplay');
  final NautuneAppState appState;
  
  CarPlayService({required this.appState}) {
    if (Platform.isIOS) {
      _setupMethodCallHandler();
    }
  }
  
  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'getAlbums':
          return await _getAlbums();
        case 'getArtists':
          return await _getArtists();
        case 'getPlaylists':
          return await _getPlaylists();
        case 'getFavorites':
          return await _getFavorites();
        case 'getDownloads':
          return await _getDownloads();
        case 'getAlbumTracks':
          final albumId = call.arguments['albumId'] as String;
          return await _getAlbumTracks(albumId);
        case 'getArtistAlbums':
          final artistId = call.arguments['artistId'] as String;
          return await _getArtistAlbums(artistId);
        case 'getPlaylistTracks':
          final playlistId = call.arguments['playlistId'] as String;
          return await _getPlaylistTracks(playlistId);
        case 'playTrack':
          final trackId = call.arguments['trackId'] as String;
          await _playTrack(trackId);
          return null;
        default:
          throw PlatformException(
            code: 'Unimplemented',
            details: 'Method ${call.method} not implemented',
          );
      }
    });
  }
  
  Future<List<Map<String, dynamic>>> _getAlbums() async {
    final albumsList = appState.albums ?? [];
    return albumsList.map((album) => {
      'id': album.id,
      'name': album.name,
      'artist': album.artists.join(', '),
    }).toList();
  }
  
  Future<List<Map<String, dynamic>>> _getArtists() async {
    final artistsList = appState.artists ?? [];
    return artistsList.map((artist) => {
      'id': artist.id,
      'name': artist.name,
    }).toList();
  }
  
  Future<List<Map<String, dynamic>>> _getPlaylists() async {
    final playlistsList = appState.playlists ?? [];
    return playlistsList.map((playlist) => {
      'id': playlist.id,
      'name': playlist.name,
      'trackCount': playlist.trackCount,
    }).toList();
  }
  
  Future<List<Map<String, dynamic>>> _getFavorites() async {
    final albumsList = appState.albums ?? [];
    final favorites = albumsList
        .where((album) => album.isFavorite)
        .toList();
    
    // Get all tracks from favorite albums
    final List<Map<String, dynamic>> favoriteTracks = [];
    for (final album in favorites) {
      final tracks = await appState.getAlbumTracks(album.id);
      favoriteTracks.addAll(tracks.map((track) => {
        'id': track.id,
        'name': track.name,
        'artist': track.artists.join(', '),
        'album': track.album,
      }));
    }
    
    return favoriteTracks;
  }
  
  Future<List<Map<String, dynamic>>> _getDownloads() async {
    final downloads = appState.downloadService.completedDownloads;
    
    return downloads.map((download) => {
      'id': download.track.id,
      'name': download.track.name,
      'artist': download.track.artists.join(', '),
      'album': download.track.album,
    }).toList();
  }
  
  Future<List<Map<String, dynamic>>> _getAlbumTracks(String albumId) async {
    final tracks = await appState.getAlbumTracks(albumId);
    
    return tracks.map((track) => {
      'id': track.id,
      'name': track.name,
      'artist': track.artists.join(', '),
      'album': track.album,
    }).toList();
  }
  
  Future<List<Map<String, dynamic>>> _getArtistAlbums(String artistId) async {
    final albumsList = appState.albums ?? [];
    final albums = albumsList.where((album) => 
      album.artists.contains(artistId)
    ).toList();
    
    return albums.map((album) => {
      'id': album.id,
      'name': album.name,
      'artist': album.artists.join(', '),
    }).toList();
  }
  
  Future<List<Map<String, dynamic>>> _getPlaylistTracks(String playlistId) async {
    final tracks = await appState.getPlaylistTracks(playlistId);
    
    return tracks.map((track) => {
      'id': track.id,
      'name': track.name,
      'artist': track.artists.join(', '),
      'album': track.album,
    }).toList();
  }
  
  Future<void> _playTrack(String trackId) async {
    // Find track across all albums
    final albumsList = appState.albums ?? [];
    for (final album in albumsList) {
      final tracks = await appState.getAlbumTracks(album.id);
      final track = tracks.where((t) => t.id == trackId).firstOrNull;
      if (track != null) {
        await appState.audioPlayerService.playTrack(track);
        return;
      }
    }
  }
  
  Future<void> updateNowPlaying({
    required String trackId,
    required String title,
    required String artist,
    String? album,
  }) async {
    if (!Platform.isIOS) return;
    
    try {
      await _channel.invokeMethod('updateNowPlaying', {
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'album': album,
      });
    } catch (e) {
      debugPrint('Error updating CarPlay now playing: $e');
    }
  }
}

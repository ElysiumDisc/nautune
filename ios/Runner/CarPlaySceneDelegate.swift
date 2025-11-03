import CarPlay
import Flutter
import UIKit

@available(iOS 14.0, *)
@objc class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var methodChannel: FlutterMethodChannel?
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                 didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        
        let rootTemplate = createLibraryTemplate()
        interfaceController.setRootTemplate(rootTemplate, animated: true, completion: nil)
        
        setupMethodChannel()
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                 didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }
    
    private func setupMethodChannel() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
              let window = appDelegate.window,
              let controller = window.rootViewController as? FlutterViewController else {
            print("CarPlay: Failed to get FlutterViewController")
            return
        }
        
        methodChannel = FlutterMethodChannel(name: "com.nautune/carplay", binaryMessenger: controller.binaryMessenger)
        
        methodChannel?.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "updateNowPlaying":
                self?.updateNowPlaying(arguments: call.arguments as? [String: Any])
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
    
    private func createLibraryTemplate() -> CPTabBarTemplate {
        let libraryTab = CPListTemplate(title: "Library", sections: [
            createAlbumsSection(),
            createArtistsSection(),
            createPlaylistsSection()
        ])
        libraryTab.tabImage = UIImage(systemName: "music.note.house")
        
        let favoritesTab = CPListTemplate(title: "Favorites", sections: [
            createFavoritesSection()
        ])
        favoritesTab.tabImage = UIImage(systemName: "heart.fill")
        
        let downloadsTab = CPListTemplate(title: "Downloads", sections: [
            createDownloadsSection()
        ])
        downloadsTab.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        
        return CPTabBarTemplate(templates: [libraryTab, favoritesTab, downloadsTab])
    }
    
    private func createAlbumsSection() -> CPListSection {
        let albumsItem = CPListItem(text: "Albums", detailText: "Browse all albums")
        albumsItem.handler = { [weak self] item, completion in
            self?.showAlbums()
            completion()
        }
        return CPListSection(items: [albumsItem])
    }
    
    private func createArtistsSection() -> CPListSection {
        let artistsItem = CPListItem(text: "Artists", detailText: "Browse all artists")
        artistsItem.handler = { [weak self] item, completion in
            self?.showArtists()
            completion()
        }
        return CPListSection(items: [artistsItem])
    }
    
    private func createPlaylistsSection() -> CPListSection {
        let playlistsItem = CPListItem(text: "Playlists", detailText: "Your playlists")
        playlistsItem.handler = { [weak self] item, completion in
            self?.showPlaylists()
            completion()
        }
        return CPListSection(items: [playlistsItem])
    }
    
    private func createFavoritesSection() -> CPListSection {
        let favItem = CPListItem(text: "Favorite Tracks", detailText: "Your hearted songs")
        favItem.handler = { [weak self] item, completion in
            self?.showFavorites()
            completion()
        }
        return CPListSection(items: [favItem])
    }
    
    private func createDownloadsSection() -> CPListSection {
        let downloadItem = CPListItem(text: "Downloaded Music", detailText: "Available offline")
        downloadItem.handler = { [weak self] item, completion in
            self?.showDownloads()
            completion()
        }
        return CPListSection(items: [downloadItem])
    }
    
    private func showAlbums() {
        methodChannel?.invokeMethod("getAlbums", arguments: nil) { [weak self] result in
            guard let albums = result as? [[String: Any]] else { return }
            self?.displayAlbumsList(albums: albums)
        }
    }
    
    private func showArtists() {
        methodChannel?.invokeMethod("getArtists", arguments: nil) { [weak self] result in
            guard let artists = result as? [[String: Any]] else { return }
            self?.displayArtistsList(artists: artists)
        }
    }
    
    private func showPlaylists() {
        methodChannel?.invokeMethod("getPlaylists", arguments: nil) { [weak self] result in
            guard let playlists = result as? [[String: Any]] else { return }
            self?.displayPlaylistsList(playlists: playlists)
        }
    }
    
    private func showFavorites() {
        methodChannel?.invokeMethod("getFavorites", arguments: nil) { [weak self] result in
            guard let tracks = result as? [[String: Any]] else { return }
            self?.displayTracksList(tracks: tracks, title: "Favorites")
        }
    }
    
    private func showDownloads() {
        methodChannel?.invokeMethod("getDownloads", arguments: nil) { [weak self] result in
            guard let tracks = result as? [[String: Any]] else { return }
            self?.displayTracksList(tracks: tracks, title: "Downloads")
        }
    }
    
    private func displayAlbumsList(albums: [[String: Any]]) {
        let items = albums.map { album -> CPListItem in
            let item = CPListItem(
                text: album["name"] as? String ?? "",
                detailText: album["artist"] as? String
            )
            item.handler = { [weak self] _, completion in
                if let albumId = album["id"] as? String {
                    self?.showAlbumTracks(albumId: albumId, albumName: album["name"] as? String ?? "Album")
                }
                completion()
            }
            return item
        }
        
        let template = CPListTemplate(title: "Albums", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func displayArtistsList(artists: [[String: Any]]) {
        let items = artists.map { artist -> CPListItem in
            let item = CPListItem(text: artist["name"] as? String ?? "", detailText: nil)
            item.handler = { [weak self] _, completion in
                if let artistId = artist["id"] as? String {
                    self?.showArtistAlbums(artistId: artistId, artistName: artist["name"] as? String ?? "Artist")
                }
                completion()
            }
            return item
        }
        
        let template = CPListTemplate(title: "Artists", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func displayPlaylistsList(playlists: [[String: Any]]) {
        let items = playlists.map { playlist -> CPListItem in
            let item = CPListItem(
                text: playlist["name"] as? String ?? "",
                detailText: "\(playlist["trackCount"] as? Int ?? 0) tracks"
            )
            item.handler = { [weak self] _, completion in
                if let playlistId = playlist["id"] as? String {
                    self?.showPlaylistTracks(playlistId: playlistId, playlistName: playlist["name"] as? String ?? "Playlist")
                }
                completion()
            }
            return item
        }
        
        let template = CPListTemplate(title: "Playlists", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func showAlbumTracks(albumId: String, albumName: String) {
        methodChannel?.invokeMethod("getAlbumTracks", arguments: ["albumId": albumId]) { [weak self] result in
            guard let tracks = result as? [[String: Any]] else { return }
            self?.displayTracksList(tracks: tracks, title: albumName)
        }
    }
    
    private func showArtistAlbums(artistId: String, artistName: String) {
        methodChannel?.invokeMethod("getArtistAlbums", arguments: ["artistId": artistId]) { [weak self] result in
            guard let albums = result as? [[String: Any]] else { return }
            self?.displayAlbumsList(albums: albums)
        }
    }
    
    private func showPlaylistTracks(playlistId: String, playlistName: String) {
        methodChannel?.invokeMethod("getPlaylistTracks", arguments: ["playlistId": playlistId]) { [weak self] result in
            guard let tracks = result as? [[String: Any]] else { return }
            self?.displayTracksList(tracks: tracks, title: playlistName)
        }
    }
    
    private func displayTracksList(tracks: [[String: Any]], title: String) {
        let items = tracks.map { track -> CPListItem in
            let item = CPListItem(
                text: track["name"] as? String ?? "",
                detailText: track["artist"] as? String
            )
            item.handler = { [weak self] _, completion in
                if let trackId = track["id"] as? String {
                    self?.playTrack(trackId: trackId)
                }
                completion()
            }
            return item
        }
        
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
    
    private func playTrack(trackId: String) {
        methodChannel?.invokeMethod("playTrack", arguments: ["trackId": trackId])
    }
    
    private func updateNowPlaying(arguments: [String: Any]?) {
        // Updates handled by audio_service and native media player
    }
}

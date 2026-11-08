// Local-file lookup and metadata helpers used by lyrics, artwork, and playback features.
//
//     LocalFiles.m       local names and general per-track/per-album artwork data, kept by the mod
//     LocalFileInfo.x    track metadata, artwork loading and system now playing info
//     LocalLyrics.h      the user's own .lrc files, linked to a local file or matched by its names
//     LocalCover.m       the file's own cover, found where Spotify's player shows a placeholder
//
// Lyrics: Spotify never asks spclient for a local file's lyrics, so the lyrics engine keeps them under
// SGLocalFileLyricsKey and asks the sources by the names here (Shared/Lyrics/KaraokeSource.x).
#import <UIKit/UIKit.h>
@class SPTPlayerTrack;

// URI -> {title, artist, album, cover (a file name in SGLocalFileCoversDirectory), number}.
#define SGKeyLocalFileEdits @"spotifyglass.localFiles.edits"
#define SGKeyTrackEdits @"spotifyglass.trackInfo.edits"

// A local file's URI, or a lyrics key made from one.
BOOL SGLocalFileIs(NSString *uri);
// What the lyrics engine keeps a local file under: its URI, and once its names are edited the edit's
// number after a "#", so a rename reads as a new track and its lyrics are looked up again under the new
// names. A new cover alone keeps the key. Posting SGLocalFileEditsDidChangeNotification is what has the
// lyrics engine ask for the new key while the file plays.
// nil for anything but a local file.
NSString *SGLocalFileLyricsKey(NSString *uri);
// The names a local file goes by, the user's edits over its own tags: title, artist, album (each
// present only when not empty) and seconds. Takes a URI or a lyrics key; nil for anything else.
NSDictionary<NSString *, id> *SGLocalFileInfo(NSString *uri);
// The file's own names, as its URI carries them, with no edit over them.
NSDictionary<NSString *, id> *SGLocalFileTags(NSString *uri);

// The user's local-file edit, nil when there is none. Safe from any thread.
NSDictionary<NSString *, id> *SGLocalFileEditFor(NSString *uri);
// Stores the local names (an empty or missing one, or one the file already has, falls back to the file's
// own) and a new cover when `cover` is set; `keepCover` NO drops the stored one. The file's own names
// with no cover remove the edit. Returns NO with the file or image error. Main thread.
BOOL SGLocalFileSaveEdit(NSString *uri, NSDictionary<NSString *, NSString *> *names, UIImage *cover, BOOL keepCover, NSError **error);
// The small local-file info editor: title, artist and album only. No cover, motion or album-wide controls.
UIViewController *SGLocalFileEditCanvasPage(NSString *uri);
// Where the stored covers are, and the one an edit names; nil when it names none.
NSString *SGLocalFileCoversDirectory(void);
NSString *SGLocalFileCoverPath(NSDictionary<NSString *, id> *edit);
NSDictionary<NSString *, id> *SGTrackEditFor(NSString *uri, NSString *albumURI);
NSDictionary *SGTrackOriginalMetadata(SPTPlayerTrack *track);
NSString *SGTrackArtworkCoverPath(NSDictionary<NSString *, id> *edit);
NSString *SGTrackArtworkMotionPath(NSDictionary<NSString *, id> *edit);
NSString *SGTrackArtworkDirectory(void);
NSURL *SGTrackPrepareMotion(NSURL *motion, BOOL *temporary, NSError **error);
BOOL SGTrackSaveEdit(NSString *uri, NSString *albumURI, NSDictionary<NSString *, NSString *> *names,
                     UIImage *cover, BOOL coverChanged, BOOL coverAlbumWide,
                     NSURL *motion, BOOL motionChanged, BOOL motionAlbumWide, NSError **error);
// A stored cover as the image address Spotify's loader takes for a local file, spotify:localfileimage:
// and the path percent escaped, ":" too, since the loader splits the address on it; and back, nil for
// an address that is not one of these covers.
NSString *SGLocalFileCoverURL(NSString *path);
NSString *SGLocalFileCoverInURL(NSString *url);
// Posted on the main thread after an edit is stored or forgotten, object the URI.
extern NSNotificationName const SGLocalFileEditsDidChangeNotification;

// LocalCover.m: the file's own cover for a local track whose player shows Spotify's placeholder, from the
// image fields of its metadata or the system's now playing artwork; nil for any other track or until one is found. Main thread.
UIImage *SGLocalFileFallbackCover(SPTPlayerTrack *track);

#define SGKeyLocalFilesPage @"spotifyglass.localfiles.page"
#define SGKeyLocalFilesAnimatedOffline @"spotifyglass.localfiles.animatedOffline"

UIViewController *SGLocalFilesSettingsPage(void);
UIViewController *SGYourFilesBrowserPage(void);

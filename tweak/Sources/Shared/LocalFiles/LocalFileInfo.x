// A track's edit laid over what Spotify read from it (LocalFiles.h).
//
// -[SPTPlayerTrack metadata] is the one place: trackTitle, artistName, albumTitle and imageURL each read
// self.metadata and take title, artist_name, album_title and image_url from it (their code in the
// binary, through NSDictionary's spt_metadata_* in IDZKAdditions), and the player, the now playing bar
// and the system's now playing info are built from the player's track. So the names go in there, and
// the cover as an image address of the kind Spotify gives a local file, spotify:localfileimage:<path>.
//
// Spotify's loader hands such an address (three parts, no ipod-library in it) to
// SPTLocalAVAssetImageLoaderRequest, whose -loadLocalFileImage reads the cover out of the file at the
// path with AVAsset and passes its bytes to -dispatchSuccess:, which gives them to the delegate's
// imageLoaderRequest:didLoadImageData:. The request caches nothing (preventInMemoryCaching and
// preventPersistentCaching answer YES), so a stored cover is read from disk each time and passed on
// the same way. The system's now playing artwork is added too, in case Spotify fetches it apart.
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Headers/SPTLocalAVAssetImageLoaderRequest.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"
#import "LocalFiles.h"

static char kOriginalMetadataKey;

NSDictionary *SGTrackOriginalMetadata(SPTPlayerTrack *track) {
    id metadata = track ? objc_getAssociatedObject(track, &kOriginalMetadataKey) : nil;
    return [metadata isKindOfClass:NSDictionary.class] ? metadata : nil;
}

// Called for every track in every list many times a second: one prefix check for any other track.
static NSDictionary *withEdit(NSDictionary *metadata, NSString *uri) {
    NSString *albumURI = [metadata[@"album_uri"] isKindOfClass:NSString.class] ? metadata[@"album_uri"] : nil;
    NSDictionary *edit = SGTrackEditFor(uri, albumURI);
    if (!edit) return metadata;
    NSString *coverPath = SGTrackArtworkCoverPath(edit);
    if (![edit[@"title"] length] && ![edit[@"artist"] length] && ![edit[@"album"] length] && !coverPath) return metadata;
    NSMutableDictionary *edited = metadata ? [metadata mutableCopy] : [NSMutableDictionary dictionary];
    if ([edit[@"title"] length]) edited[@"title"] = edit[@"title"];
    if ([edit[@"artist"] length]) edited[@"artist_name"] = edit[@"artist"];
    if ([edit[@"album"] length]) edited[@"album_title"] = edit[@"album"];
    NSString *cover = SGLocalFileCoverURL(coverPath);
    // Every size, since Spotify's player and artwork loaders can ask for any one of them.
    if (cover) {
        for (NSString *field in @[@"image_small_url", @"image_url", @"image_large_url", @"image_xlarge_url"]) edited[field] = cover;
    }
    return edited;
}

#pragma mark - the system's now playing artwork

@interface SGTrackNowPlaying : NSObject <SGPlayerStateObserver>
@end

@implementation SGTrackNowPlaying {
    NSString *_track;
}

// Spotify's info is matched by its title, which is the edited one when Spotify built it from the
// player's track and the file's own when it did not, so the artwork rides on either.
- (void)show:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    NSDictionary *metadata = [state.track.metadata isKindOfClass:NSDictionary.class] ? state.track.metadata : nil;
    NSDictionary *edit = SGTrackEditFor(uri, metadata[@"album_uri"]);
    NSString *path = SGTrackArtworkCoverPath(edit);
    UIImage *cover = path ? [UIImage imageWithContentsOfFile:path] : nil;
    if (!cover) {
        SGNowPlayingSetExtras(@"localFiles", nil, nil);
        SGNowPlayingSetExtras(@"localFiles.tags", nil, nil);
        return;
    }
    MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:cover.size requestHandler:^UIImage *(CGSize size) {
        return cover;
    }];
    NSString *title = [metadata[@"title"] isKindOfClass:NSString.class] ? metadata[@"title"] : state.track.trackTitle;
    SGNowPlayingSetExtras(@"localFiles", @{MPMediaItemPropertyArtwork: artwork}, title);
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *track = SGURIString(state.track.URI);
    if (!track || [track isEqualToString:_track]) return;
    _track = track;
    [self show:state];
}

- (void)editsChanged:(NSNotification *)note {
    SPTPlayerState *state = SGPlayerState();
    NSString *albumURI = state.track.metadata[@"album_uri"];
    if ([note.object isEqual:_track] || [note.userInfo[@"albumURI"] isEqual:albumURI]) [self show:state];
}

@end

#pragma mark - hooks

%hook SPTPlayerTrack
- (NSDictionary *)metadata {
    NSDictionary *metadata = %orig;
    if ([metadata isKindOfClass:NSDictionary.class]) objc_setAssociatedObject(self, &kOriginalMetadataKey, metadata, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *uri = SGURIString(self.URI);
    return withEdit(metadata, uri);
}
- (NSString *)trackTitle {
    NSString *original = %orig;
    NSDictionary *metadata = self.metadata;
    NSString *albumURI = [metadata[@"album_uri"] isKindOfClass:NSString.class] ? metadata[@"album_uri"] : nil;
    NSString *edited = SGTrackEditFor(SGURIString(self.URI), albumURI)[@"title"];
    return edited.length ? edited : original;
}
- (NSString *)artistName {
    NSString *original = %orig;
    NSDictionary *metadata = self.metadata;
    NSString *albumURI = [metadata[@"album_uri"] isKindOfClass:NSString.class] ? metadata[@"album_uri"] : nil;
    NSString *edited = SGTrackEditFor(SGURIString(self.URI), albumURI)[@"artist"];
    return edited.length ? edited : original;
}
%end

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    NSDictionary *source = [info isKindOfClass:NSDictionary.class] ? info : @{};
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *track = state.track;
    NSString *uri = SGURIString(track.URI);
    if (!uri.length) {
        %orig(source);
        return;
    }
    NSDictionary *original = SGTrackOriginalMetadata(track);
    NSDictionary *metadata = [original isKindOfClass:NSDictionary.class] ? original
        : [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : nil;
    NSString *albumURI = [metadata[@"album_uri"] isKindOfClass:NSString.class] ? metadata[@"album_uri"] : nil;
    NSDictionary *edit = SGTrackEditFor(uri, albumURI);
    if (!edit.count) {
        %orig(source);
        return;
    }

    NSMutableDictionary *shown = [source mutableCopy];
    NSString *title = [edit[@"title"] isKindOfClass:NSString.class] && [edit[@"title"] length]
        ? edit[@"title"] : ([metadata[@"title"] isKindOfClass:NSString.class] ? metadata[@"title"] : nil);
    NSString *artist = [edit[@"artist"] isKindOfClass:NSString.class] && [edit[@"artist"] length]
        ? edit[@"artist"] : ([metadata[@"artist_name"] isKindOfClass:NSString.class] ? metadata[@"artist_name"] : nil);
    NSString *album = [edit[@"album"] isKindOfClass:NSString.class] && [edit[@"album"] length]
        ? edit[@"album"] : ([metadata[@"album_title"] isKindOfClass:NSString.class] ? metadata[@"album_title"] : nil);
    if (title.length) shown[MPMediaItemPropertyTitle] = title;
    if (artist.length) shown[MPMediaItemPropertyArtist] = artist;
    if (album.length) shown[MPMediaItemPropertyAlbumTitle] = album;

    NSString *coverPath = SGTrackArtworkCoverPath(edit);
    UIImage *cover = coverPath ? [UIImage imageWithContentsOfFile:coverPath] : nil;
    if (cover) {
        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:cover.size requestHandler:^UIImage *(CGSize size) {
            return cover;
        }];
        shown[MPMediaItemPropertyArtwork] = artwork;
    }
    %orig(shown);
}
%end

%hook SPTLocalAVAssetImageLoaderRequest
- (void)loadLocalFileImage {
    NSString *path = SGLocalFileCoverInURL(self.URL.absoluteString);
    if (!path) {
        %orig;
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        SGLog(@"local files: the cover %@ is gone, the track shows none", path.lastPathComponent);
        %orig;
        return;
    }
    [self dispatchSuccess:data];
}
%end

%ctor {
    %init;
    static SGTrackNowPlaying *nowPlaying;
    nowPlaying = [SGTrackNowPlaying new];
    SGAddPlayerStateObserver(nowPlaying);
    [NSNotificationCenter.defaultCenter addObserver:nowPlaying selector:@selector(editsChanged:) name:SGLocalFileEditsDidChangeNotification object:nil];
    SGRequireClasses(@[@"SPTPlayerTrack", @"SPTLocalAVAssetImageLoaderRequest"]);
}

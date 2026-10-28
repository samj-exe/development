// LocalFiles.h says what is kept and why the file is not written.
//
// Threading: the edits are read on whatever thread Spotify reads a track's metadata on, so the table is
// swapped whole under a lock; they are written on the main thread.
#import <os/lock.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <unistd.h>
#import "Core/SGCore.h"
#import "LocalFiles.h"

static NSString *const kLocalPrefix = @"spotify:local:";
// A cover is kept no larger than this on its longer side; the player draws it at under half that.
static const CGFloat kCoverSide = 1200;

NSNotificationName const SGLocalFileEditsDidChangeNotification = @"spotifyglass.localFiles.editsDidChange";

static NSDictionary<NSString *, NSDictionary *> *sg_edits;
static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;
static NSDictionary<NSString *, NSDictionary *> *sg_trackEdits;
static os_unfair_lock sg_trackLock = OS_UNFAIR_LOCK_INIT;

BOOL SGLocalFileIs(NSString *uri) {
    return [uri isKindOfClass:NSString.class] && [uri hasPrefix:kLocalPrefix];
}

static NSDictionary<NSString *, NSDictionary *> *allEdits(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyLocalFileEdits];
        os_unfair_lock_lock(&sg_lock);
        sg_edits = [stored isKindOfClass:NSDictionary.class] ? stored : @{};
        os_unfair_lock_unlock(&sg_lock);
    });
    os_unfair_lock_lock(&sg_lock);
    NSDictionary *edits = sg_edits;
    os_unfair_lock_unlock(&sg_lock);
    return edits;
}

static void storeEdits(NSDictionary<NSString *, NSDictionary *> *edits) {
    os_unfair_lock_lock(&sg_lock);
    sg_edits = [edits copy];
    os_unfair_lock_unlock(&sg_lock);
    if (edits.count) [NSUserDefaults.standardUserDefaults setObject:edits forKey:SGKeyLocalFileEdits];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyLocalFileEdits];
}

NSDictionary<NSString *, id> *SGLocalFileEditFor(NSString *uri) {
    if (!SGLocalFileIs(uri)) return nil;
    id edit = allEdits()[uri];
    return [edit isKindOfClass:NSDictionary.class] ? edit : nil;
}

NSString *SGLocalFileLyricsKey(NSString *uri) {
    if (!SGLocalFileIs(uri)) return nil;
    id number = SGLocalFileEditFor(uri)[@"number"];
    return number ? [NSString stringWithFormat:@"%@#%@", uri, number] : uri;
}

#pragma mark - the URI's own names

// Form encoded: "+" is a space and the rest percent escapes, so a part never holds a raw ":".
static NSString *decoded(NSString *part) {
    NSString *spaced = [part stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return spaced.stringByRemovingPercentEncoding ?: spaced;
}

NSDictionary<NSString *, id> *SGLocalFileTags(NSString *uri) {
    if (!SGLocalFileIs(uri)) return nil;
    NSArray<NSString *> *parts = [[uri substringFromIndex:kLocalPrefix.length] componentsSeparatedByString:@":"];
    if (parts.count != 4) return nil;
    NSMutableDictionary<NSString *, id> *tags = [NSMutableDictionary dictionary];
    NSString *artist = decoded(parts[0]), *album = decoded(parts[1]), *title = decoded(parts[2]);
    if (title.length) tags[@"title"] = title;
    if (artist.length) tags[@"artist"] = artist;
    if (album.length) tags[@"album"] = album;
    // A lyrics key carries "#<number>" after the seconds, which integerValue stops at.
    tags[@"seconds"] = @(MAX(parts[3].integerValue, 0));
    return tags;
}

NSDictionary<NSString *, id> *SGLocalFileInfo(NSString *uri) {
    NSDictionary *tags = SGLocalFileTags(uri);
    if (!tags) return nil;
    NSRange mark = [uri rangeOfString:@"#" options:NSBackwardsSearch];
    NSDictionary *edit = SGLocalFileEditFor(mark.location == NSNotFound ? uri : [uri substringToIndex:mark.location]);
    if (!edit) return tags;
    NSMutableDictionary<NSString *, id> *info = [tags mutableCopy];
    for (NSString *field in @[@"title", @"artist", @"album"]) {
        if ([edit[field] length]) info[field] = edit[field];
    }
    return info;
}

#pragma mark - storing an edit

NSString *SGLocalFileCoversDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Application Support rather than Documents: Spotify scans Documents for music, and the Files app shows it.
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        directory = [support stringByAppendingPathComponent:@"spoti.pw/Local file covers"];
    });
    return directory;
}

NSString *SGLocalFileCoverPath(NSDictionary<NSString *, id> *edit) {
    NSString *name = edit[@"cover"];
    return [name isKindOfClass:NSString.class] && name.length ? [SGLocalFileCoversDirectory() stringByAppendingPathComponent:name] : nil;
}

NSString *SGTrackArtworkDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        directory = [support stringByAppendingPathComponent:@"spoti.pw/Track artwork"];
    });
    return directory;
}

NSString *SGTrackArtworkCoverPath(NSDictionary<NSString *, id> *edit) {
    NSString *name = edit[@"cover"];
    if (![name isKindOfClass:NSString.class] || !name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]
        || name.pathComponents.count != 1) return nil;
    return [SGLocalFileCoversDirectory() stringByAppendingPathComponent:name];
}

NSString *SGTrackArtworkMotionPath(NSDictionary<NSString *, id> *edit) {
    NSString *name = edit[@"motion"];
    if (![name isKindOfClass:NSString.class] || !name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]
        || name.pathComponents.count != 1) return nil;
    return [SGTrackArtworkDirectory() stringByAppendingPathComponent:name];
}

static NSString *trackEditKey(NSString *kind, NSString *uri) {
    return uri.length ? [NSString stringWithFormat:@"%@:%@", kind, uri] : nil;
}

static NSDictionary<NSString *, NSDictionary *> *trackEdits(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyTrackEdits];
        os_unfair_lock_lock(&sg_trackLock);
        sg_trackEdits = [stored isKindOfClass:NSDictionary.class] ? stored : @{};
        os_unfair_lock_unlock(&sg_trackLock);
    });
    os_unfair_lock_lock(&sg_trackLock);
    NSDictionary *edits = sg_trackEdits;
    os_unfair_lock_unlock(&sg_trackLock);
    return edits;
}

static void storeTrackEdits(NSDictionary<NSString *, NSDictionary *> *edits) {
    os_unfair_lock_lock(&sg_trackLock);
    sg_trackEdits = [edits copy];
    os_unfair_lock_unlock(&sg_trackLock);
    if (edits.count) [NSUserDefaults.standardUserDefaults setObject:edits forKey:SGKeyTrackEdits];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyTrackEdits];
}

NSDictionary<NSString *, id> *SGTrackEditFor(NSString *uri, NSString *albumURI) {
    NSDictionary *stored = trackEdits();
    BOOL local = SGLocalFileIs(uri);
    if (!stored.count && !local) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSString *albumKey = trackEditKey(@"album", albumURI);
    NSString *trackKey = trackEditKey(@"track", uri);
    NSDictionary *album = albumKey ? stored[albumKey] : nil;
    NSDictionary *track = trackKey ? stored[trackKey] : nil;
    if ([album isKindOfClass:NSDictionary.class]) [result addEntriesFromDictionary:album];
    if ([track isKindOfClass:NSDictionary.class]) [result addEntriesFromDictionary:track];
    NSDictionary *local = SGLocalFileEditFor(uri);
    if ([local isKindOfClass:NSDictionary.class]) [result addEntriesFromDictionary:local];
    return result.count ? result : nil;
}

static NSString *writeTrackCover(UIImage *image, NSError **error) {
    if (image.size.width <= 0 || image.size.height <= 0) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The selected cover image is empty."}];
        return nil;
    }
    CGFloat scale = MIN(1, kCoverSide / MAX(image.size.width, image.size.height));
    CGSize size = CGSizeMake(round(image.size.width * scale), round(image.size.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage *drawn = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:(CGRect){CGPointZero, size}];
    }];
    NSData *data = UIImageJPEGRepresentation(drawn, 0.9);
    if (!data) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:12
            userInfo:@{NSLocalizedDescriptionKey: @"The selected cover image could not be encoded."}];
        return nil;
    }
    NSString *name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"jpg"];
    NSString *directory = SGLocalFileCoversDirectory();
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]
        || ![data writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:error]) return nil;
    return name;
}

static BOOL appendGIFFrame(CGImageRef image, CGSize canvas, AVAssetWriterInputPixelBufferAdaptor *adaptor, CMTime time, NSError **error) {
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &buffer);
    if (status != kCVReturnSuccess || !buffer) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:5
            userInfo:@{NSLocalizedDescriptionKey: @"A GIF frame could not be prepared for video."}];
        return NO;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), (size_t)canvas.width, (size_t)canvas.height,
        8, CVPixelBufferGetBytesPerRow(buffer), colorSpace, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    if (context) {
        CGContextSetFillColorWithColor(context, UIColor.blackColor.CGColor);
        CGContextFillRect(context, CGRectMake(0, 0, canvas.width, canvas.height));
        CGContextTranslateCTM(context, 0, canvas.height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, canvas.width, canvas.height), image);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (!context) {
        CVPixelBufferRelease(buffer);
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:6
            userInfo:@{NSLocalizedDescriptionKey: @"A GIF frame could not be drawn."}];
        return NO;
    }
    BOOL appended = [adaptor appendPixelBuffer:buffer withPresentationTime:time];
    CVPixelBufferRelease(buffer);
    if (!appended && error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:7
        userInfo:@{NSLocalizedDescriptionKey: @"GIF frames could not be encoded into a video."}];
    return appended;
}

static BOOL convertGIFToMovie(NSURL *sourceURL, NSURL *destinationURL, NSError **error) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, NULL);
    size_t count = source ? CGImageSourceGetCount(source) : 0;
    CGImageRef first = count ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (!first) {
        if (source) CFRelease(source);
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:8
            userInfo:@{NSLocalizedDescriptionKey: @"The selected GIF could not be read."}];
        return NO;
    }
    CGFloat scale = MIN(1, 1080.0 / MAX(CGImageGetWidth(first), CGImageGetHeight(first)));
    size_t width = MAX(2, ((size_t)(CGImageGetWidth(first) * scale)) & ~1);
    size_t height = MAX(2, ((size_t)(CGImageGetHeight(first) * scale)) & ~1);
    CGImageRelease(first);

    NSError *writerError = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:destinationURL fileType:AVFileTypeMPEG4 error:&writerError];
    if (!writer) {
        if (source) CFRelease(source);
        if (error) *error = writerError;
        return NO;
    }
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @4000000},
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32ARGB),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:attributes];
    if (![writer canAddInput:input]) {
        if (source) CFRelease(source);
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:9
            userInfo:@{NSLocalizedDescriptionKey: @"This GIF cannot be converted to animated artwork."}];
        return NO;
    }
    [writer addInput:input];
    BOOL ok = [writer startWriting];
    if (ok) [writer startSessionAtSourceTime:kCMTimeZero];
    double elapsed = 0;
    CGSize canvas = CGSizeMake(width, height);
    for (size_t index = 0; ok && index < count; index++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) usleep(1000);
        CGImageRef frame = CGImageSourceCreateImageAtIndex(source, index, NULL);
        if (!frame) {
            ok = NO;
            writerError = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:10
                userInfo:@{NSLocalizedDescriptionKey: @"A frame in the selected GIF could not be read."}];
            break;
        }
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
        NSDictionary *gif = properties[(__bridge id)kCGImagePropertyGIFDictionary];
        NSNumber *delay = gif[(__bridge id)kCGImagePropertyGIFUnclampedDelayTime] ?: gif[(__bridge id)kCGImagePropertyGIFDelayTime];
        double duration = delay.doubleValue;
        if (!delay || !isfinite(duration)) duration = 0.1;
        duration = MAX(0.02, duration);
        NSError *frameError = nil;
        ok = appendGIFFrame(frame, canvas, adaptor, CMTimeMakeWithSeconds(elapsed, 600), &frameError);
        CGImageRelease(frame);
        if (!ok) writerError = frameError;
        elapsed += duration;
    }
    [input markAsFinished];
    if (ok) {
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
        dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
        ok = writer.status == AVAssetWriterStatusCompleted;
        if (!ok) writerError = writer.error;
    } else {
        [writer cancelWriting];
    }
    if (source) CFRelease(source);
    if (!ok) {
        [NSFileManager.defaultManager removeItemAtURL:destinationURL error:nil];
        if (error) *error = writerError ?: writer.error;
    }
    return ok;
}

NSURL *SGTrackPrepareMotion(NSURL *motion, BOOL *temporary, NSError **error) {
    if (temporary) *temporary = NO;
    NSString *extension = motion.pathExtension.lowercaseString;
    if (!motion.isFileURL || ![NSFileManager.defaultManager isReadableFileAtPath:motion.path]
        || ![@[@"mp4", @"m4v", @"mov", @"gif"] containsObject:extension]) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Choose a readable MP4, M4V, MOV or GIF file."}];
        return nil;
    }
    if (![extension isEqualToString:@"gif"]) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:motion options:nil];
        if (![asset tracksWithMediaType:AVMediaTypeVideo].count) {
            if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:11
                userInfo:@{NSLocalizedDescriptionKey: @"The selected file does not contain a playable video."}];
            return nil;
        }
        return motion;
    }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mp4"]];
    NSURL *output = [NSURL fileURLWithPath:path];
    if (!convertGIFToMovie(motion, output, error)) return nil;
    if (temporary) *temporary = YES;
    return output;
}

static NSString *copyTrackMotion(NSURL *motion, NSError **error) {
    NSString *extension = motion.pathExtension.lowercaseString;
    if (!motion.isFileURL || ![NSFileManager.defaultManager isReadableFileAtPath:motion.path]
        || ![@[@"mp4", @"m4v", @"mov"] containsObject:extension]) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"The prepared animated artwork is not a readable video."}];
        return nil;
    }
    NSString *directory = SGTrackArtworkDirectory();
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSString *name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension];
    if (![NSFileManager.defaultManager copyItemAtURL:motion toURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]] error:error]) return nil;
    return name;
}

static void changed(NSString *uri);
static void changedTrack(NSString *uri, NSString *albumURI);

BOOL SGTrackSaveEdit(NSString *uri, NSString *albumURI, NSDictionary<NSString *, NSString *> *names,
                     UIImage *cover, BOOL coverChanged, BOOL coverAlbumWide,
                     NSURL *motion, BOOL motionChanged, BOOL motionAlbumWide, NSError **error) {
    if (!uri.length) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:3 userInfo:@{NSLocalizedDescriptionKey: @"The selected song could not be identified."}];
        return NO;
    }
    if (((coverChanged && coverAlbumWide) || (motionChanged && motionAlbumWide)) && !albumURI.length) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Spotify did not provide an album ID for this song."}];
        return NO;
    }
    BOOL local = SGLocalFileIs(uri);
    BOOL localTrackCover = local && !coverAlbumWide;
    NSString *newCover = coverChanged && cover && !localTrackCover ? writeTrackCover(cover, error) : nil;
    if (coverChanged && cover && !localTrackCover && !newCover) return NO;
    NSString *newMotion = motionChanged && motion ? copyTrackMotion(motion, error) : nil;
    if (motionChanged && motion && !newMotion) {
        if (newCover) [NSFileManager.defaultManager removeItemAtPath:[SGLocalFileCoversDirectory() stringByAppendingPathComponent:newCover] error:nil];
        return NO;
    }

    NSString *trackKey = trackEditKey(@"track", uri);
    NSString *albumKey = trackEditKey(@"album", albumURI);
    NSMutableDictionary *edits = [trackEdits() mutableCopy];
    NSMutableDictionary *trackEdit = [edits[trackKey] isKindOfClass:NSDictionary.class] ? [edits[trackKey] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *albumEdit = albumKey && [edits[albumKey] isKindOfClass:NSDictionary.class]
        ? [edits[albumKey] mutableCopy] : [NSMutableDictionary dictionary];
    if (SGLocalFileIs(uri)) {
        for (NSString *field in @[@"title", @"artist", @"album"]) [trackEdit removeObjectForKey:field];
    } else {
        for (NSString *field in @[@"title", @"artist", @"album"]) {
            NSString *value = [names[field] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (value.length) trackEdit[field] = value;
            else [trackEdit removeObjectForKey:field];
        }
    }

    NSMutableDictionary *coverEdit = coverAlbumWide ? albumEdit : trackEdit;
    NSMutableDictionary *motionEdit = motionAlbumWide ? albumEdit : trackEdit;
    NSString *oldCover = SGTrackArtworkCoverPath(coverEdit);
    NSString *oldMotion = SGTrackArtworkMotionPath(motionEdit);
    NSString *oldTrackCover = SGTrackArtworkCoverPath(trackEdit);
    NSString *oldTrackMotion = SGTrackArtworkMotionPath(trackEdit);
    if (coverChanged) {
        if (coverAlbumWide) {
            [trackEdit removeObjectForKey:@"cover"];
            if (newCover) albumEdit[@"cover"] = newCover;
            else [albumEdit removeObjectForKey:@"cover"];
        } else if (local) {
            [trackEdit removeObjectForKey:@"cover"];
        } else if (newCover) trackEdit[@"cover"] = newCover;
        else [trackEdit removeObjectForKey:@"cover"];
    }
    if (motionChanged) {
        if (motionAlbumWide) {
            [trackEdit removeObjectForKey:@"motion"];
            if (newMotion) albumEdit[@"motion"] = newMotion;
            else [albumEdit removeObjectForKey:@"motion"];
        } else if (newMotion) trackEdit[@"motion"] = newMotion;
        else [trackEdit removeObjectForKey:@"motion"];
    }
    if (trackEdit.count) edits[trackKey] = trackEdit;
    else [edits removeObjectForKey:trackKey];
    if (albumKey) {
        if (albumEdit.count) edits[albumKey] = albumEdit;
        else [edits removeObjectForKey:albumKey];
    }
    if (local) {
        UIImage *localCover = coverChanged && !coverAlbumWide ? cover : nil;
        NSError *localError = nil;
        if (!SGLocalFileSaveEdit(uri, names, localCover, !coverChanged, &localError)) {
            if (newCover) [NSFileManager.defaultManager removeItemAtPath:[SGLocalFileCoversDirectory() stringByAppendingPathComponent:newCover] error:nil];
            if (newMotion) [NSFileManager.defaultManager removeItemAtPath:[SGTrackArtworkDirectory() stringByAppendingPathComponent:newMotion] error:nil];
            if (error) *error = localError;
            return NO;
        }
    }
    storeTrackEdits(edits);

    NSString *savedTrackCover = SGTrackArtworkCoverPath(edits[trackKey]);
    NSString *savedTrackMotion = SGTrackArtworkMotionPath(edits[trackKey]);
    NSString *savedAlbumCover = albumKey ? SGTrackArtworkCoverPath(edits[albumKey]) : nil;
    NSString *savedAlbumMotion = albumKey ? SGTrackArtworkMotionPath(edits[albumKey]) : nil;
    for (id old in @[oldCover ?: NSNull.null, oldTrackCover ?: NSNull.null]) {
        if ([old isKindOfClass:NSString.class] && coverChanged && ![old isEqualToString:savedTrackCover] && ![old isEqualToString:savedAlbumCover])
            [NSFileManager.defaultManager removeItemAtPath:old error:nil];
    }
    for (id old in @[oldMotion ?: NSNull.null, oldTrackMotion ?: NSNull.null]) {
        if ([old isKindOfClass:NSString.class] && motionChanged && ![old isEqualToString:savedTrackMotion] && ![old isEqualToString:savedAlbumMotion])
            [NSFileManager.defaultManager removeItemAtPath:old error:nil];
    }
    changedTrack(uri, albumURI);
    return YES;
}

static NSString *const kImagePrefix = @"spotify:localfileimage:";

NSString *SGLocalFileCoverURL(NSString *path) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSCharacterSet.URLPathAllowedCharacterSet mutableCopy];
        // -[NSURL spotifyURIComponents] splits the address on ":"; "/" goes too, so the path is one plain part.
        [set removeCharactersInString:@":/"];
        allowed = set;
    });
    NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return escaped ? [kImagePrefix stringByAppendingString:escaped] : nil;
}

NSString *SGLocalFileCoverInURL(NSString *url) {
    if (![url isKindOfClass:NSString.class] || ![url hasPrefix:kImagePrefix]) return nil;
    NSString *path = [url substringFromIndex:kImagePrefix.length].stringByRemovingPercentEncoding;
    NSString *directory = [SGLocalFileCoversDirectory() stringByAppendingString:@"/"];
    // Only a file of the covers' own, by its name alone, so no address reaches anything else.
    if (![path hasPrefix:directory] || [path substringFromIndex:directory.length].pathComponents.count != 1) return nil;
    return path;
}

static NSString *writeCover(UIImage *image, NSError **error) {
    if (image.size.width <= 0 || image.size.height <= 0) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:13
            userInfo:@{NSLocalizedDescriptionKey: @"The selected cover image is empty."}];
        return nil;
    }
    CGFloat scale = MIN(1, kCoverSide / MAX(image.size.width, image.size.height));
    CGSize size = CGSizeMake(round(image.size.width * scale), round(image.size.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage *drawn = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:(CGRect){CGPointZero, size}];
    }];
    NSData *data = UIImageJPEGRepresentation(drawn, 0.9);
    NSString *name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"jpg"];
    if (!data) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:14
            userInfo:@{NSLocalizedDescriptionKey: @"The selected cover image could not be encoded."}];
        return nil;
    }
    if (![NSFileManager.defaultManager createDirectoryAtPath:SGLocalFileCoversDirectory() withIntermediateDirectories:YES attributes:nil error:error]
        || ![data writeToFile:[SGLocalFileCoversDirectory() stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:error]) {
        return nil;
    }
    return name;
}

static void changed(NSString *uri) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalFileEditsDidChangeNotification object:uri];
}

static void changedTrack(NSString *uri, NSString *albumURI) {
    NSDictionary *info = albumURI.length ? @{@"albumURI": albumURI} : nil;
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalFileEditsDidChangeNotification object:uri userInfo:info];
}

BOOL SGLocalFileSaveEdit(NSString *uri, NSDictionary<NSString *, NSString *> *names, UIImage *cover, BOOL keepCover, NSError **error) {
    if (!SGLocalFileIs(uri)) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.trackInfo" code:15
            userInfo:@{NSLocalizedDescriptionKey: @"The selected item is not a local file."}];
        return NO;
    }
    NSDictionary *tags = SGLocalFileTags(uri), *old = SGLocalFileEditFor(uri);
    NSMutableDictionary<NSString *, id> *edit = [NSMutableDictionary dictionary];
    for (NSString *field in @[@"title", @"artist", @"album"]) {
        NSString *name = [names[field] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length && ![name isEqualToString:tags[field]]) edit[field] = name;
    }
    NSString *oldCover = SGLocalFileCoverPath(old);
    NSString *newCover = cover ? writeCover(cover, error) : nil;
    if (cover && !newCover) return NO;
    if (newCover) edit[@"cover"] = newCover;
    else if (keepCover && oldCover) edit[@"cover"] = old[@"cover"];
    if (oldCover && ![edit[@"cover"] isEqual:old[@"cover"]]) [NSFileManager.defaultManager removeItemAtPath:oldCover error:nil];

    // The lyrics key changes with the names only: a cover alone leaves the lyrics where they are, and the
    // file's own names go back to the bare URI, whose lyrics may still be kept.
    BOOL named = NO, renamed = NO;
    for (NSString *field in @[@"title", @"artist", @"album"]) {
        named = named || edit[field];
        renamed = renamed || !(edit[field] == old[field] || [edit[field] isEqual:old[field]]);
    }
    // Milliseconds, so no two renames of a track share a lyrics key, a reset in between or not.
    if (named) edit[@"number"] = renamed || !old[@"number"] ? @((long long)(NSDate.date.timeIntervalSince1970 * 1000)) : old[@"number"];

    NSMutableDictionary *edits = [allEdits() mutableCopy];
    if (edit.count) {
        edits[uri] = edit;
    } else {
        [edits removeObjectForKey:uri];
    }
    storeEdits(edits);
    SGLog(@"local files: %@ %@", uri, edit.count ? [NSString stringWithFormat:@"edited: %@", edit] : @"back to its own tags");
    changed(uri);
    return YES;
}

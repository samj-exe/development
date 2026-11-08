#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "LocalFiles.h"
#import "LocalLyrics.h"

@interface SGScannedLocalSong : NSObject
@property (nonatomic, copy) NSString *path, *filename, *title, *artist, *album, *uri;
@property (nonatomic) NSInteger seconds;
@end

@implementation SGScannedLocalSong
@end

static NSString *formEncodeLocalPart(NSString *text) {
    if (!text.length) return @"";
    NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [allowed addCharactersInString:@"-._* "];
    NSString *enc = [text stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: text;
    return [enc stringByReplacingOccurrencesOfString:@" " withString:@"+"];
}

static NSArray<SGScannedLocalSong *> *scanDocumentsSongs(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) return @[];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:docs];
    NSSet<NSString *> *audioExts = [NSSet setWithObjects:@"mp3", @"m4a", @"flac", @"wav", @"aac", @"ogg", @"alac", nil];
    NSMutableArray<SGScannedLocalSong *> *songs = [NSMutableArray array];

    for (NSString *rel in enumerator) {
        if ([rel hasPrefix:@"spoti.pw/"] || [rel hasPrefix:@"."]) continue;
        NSString *ext = rel.pathExtension.lowercaseString;
        if (![audioExts containsObject:ext]) continue;
        NSString *fullPath = [docs stringByAppendingPathComponent:rel];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:fullPath] options:nil];
        NSString *title = nil, *artist = nil, *album = nil;
        for (AVMetadataItem *item in asset.commonMetadata) {
            if ([item.commonKey isEqualToString:AVMetadataCommonKeyTitle]) title = item.stringValue;
            else if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtist]) artist = item.stringValue;
            else if ([item.commonKey isEqualToString:AVMetadataCommonKeyAlbumName]) album = item.stringValue;
        }
        NSString *base = rel.lastPathComponent.stringByDeletingPathExtension;
        if (!title.length) {
            NSRange dash = [base rangeOfString:@" - "];
            if (dash.location != NSNotFound) {
                if (!artist.length) artist = [base substringToIndex:dash.location];
                title = [base substringFromIndex:NSMaxRange(dash)];
            } else {
                title = base;
            }
        }
        CMTime dur = asset.duration;
        NSInteger secs = CMTIME_IS_NUMERIC(dur) ? MAX(0, (NSInteger)llround(CMTimeGetSeconds(dur))) : 0;
        NSString *uri = [NSString stringWithFormat:@"spotify:local:%@:%@:%@:%ld",
                         formEncodeLocalPart(artist ?: @""),
                         formEncodeLocalPart(album ?: @""),
                         formEncodeLocalPart(title ?: base),
                         (long)secs];
        NSDictionary *info = SGLocalFileInfo(uri);
        SGScannedLocalSong *song = [SGScannedLocalSong new];
        song.path = fullPath;
        song.filename = rel.lastPathComponent;
        song.uri = uri;
        song.title = info[@"title"] ?: title ?: base;
        song.artist = info[@"artist"] ?: artist ?: @"Unknown Artist";
        song.album = info[@"album"] ?: album ?: @"";
        song.seconds = secs;
        [songs addObject:song];
    }
    [songs sortUsingComparator:^NSComparisonResult(SGScannedLocalSong *a, SGScannedLocalSong *b) {
        return [a.title localizedCaseInsensitiveCompare:b.title];
    }];
    return songs;
}

@interface SGLocalAudioImportDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^imported)(void);
@end

@implementation SGLocalAudioImportDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    for (NSURL *url in urls) {
        if (!url.lastPathComponent.length) continue;
        NSString *dest = [docs stringByAppendingPathComponent:url.lastPathComponent];
        [NSFileManager.defaultManager copyItemAtPath:url.path toPath:dest error:nil];
    }
    if (self.imported) self.imported();
}
@end

static SGLocalAudioImportDelegate *sg_audioImporter;

UIViewController *SGYourFilesBrowserPage(void) {
    __block __weak SGModPage *weakPage;
    void (^rebuild)(void) = ^{
        SGModPage *page = weakPage;
        if (!page) return;
        NSArray<SGScannedLocalSong *> *songs = scanDocumentsSongs();
        NSMutableArray<SGModRow *> *songRows = [NSMutableArray array];
        for (SGScannedLocalSong *song in songs) {
            NSString *sub = song.album.length ? [NSString stringWithFormat:@"%@ • %@", song.artist, song.album] : song.artist;
            SGModRow *row = SGWithSymbol(SGActionRow(song.title, sub, ^{
                UIAlertController *sheet = [UIAlertController alertControllerWithTitle:song.title message:song.filename preferredStyle:UIAlertControllerStyleActionSheet];
                [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                sheet.popoverPresentationController.sourceView = weakPage.view;
                [weakPage presentViewController:sheet animated:YES completion:nil];
            }), @"music.note");
            [songRows addObject:row];
        }
        if (!songRows.count) {
            [songRows addObject:SGStatRow(@"No results in your files.", nil)];
        }
        SGModRow *importBtn = SGWithSymbol(SGActionRow(@"Import audio files…", @"Copy MP3, M4A, FLAC or WAV files into Spotify's Documents folder", ^{
            sg_audioImporter = [SGLocalAudioImportDelegate new];
            sg_audioImporter.imported = ^{ if (weakPage) [weakPage viewWillAppear:NO]; };
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
            picker.allowsMultipleSelection = YES;
            picker.delegate = sg_audioImporter;
            [weakPage presentViewController:picker animated:YES completion:nil];
        }), @"plus.circle");
        [page setSections:@[
            SGSection(@"Import", @[importBtn]),
            SGSection([NSString stringWithFormat:@"Songs (%lu)", (unsigned long)songs.count], songRows),
        ]];
    };

    SGModPage *page = [[SGModPage alloc] initWithTitle:@"Your Files"
                                                 intro:@"Browse and import the audio files in your Spotify Documents folder."
                                              sections:@[]
                                                footer:nil];
    weakPage = page;
    rebuild();
    [NSNotificationCenter.defaultCenter addObserverForName:SGLocalFileEditsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        rebuild();
    }];
    return page;
}

UIViewController *SGLocalFilesSettingsPage(void) {
    SGModRow *openYourFiles = SGWithSymbol(SGPageRow(@"Open Your Files", ^UIViewController *{ return SGYourFilesBrowserPage(); }), @"folder");
    SGModRow *yourFilesToggle = SGOptionRow(@"Your Files Page", @"Dedicated page for your local songs, albums and artists", SGKeyLocalFilesPage);
    SGModRow *animatedCovers = SGOptionRow(@"Download Animated Covers", @"Keep animated covers offline for your local albums", SGKeyLocalFilesAnimatedOffline);
    SGModRow *importedLrc = SGWithSymbol(SGPageRow(@"Imported lyrics files", ^UIViewController *{ return SGImportedLRCPage(); }), @"quote.bubble");
    SGModRow *clearCovers = SGWithSymbol(SGActionRow(@"Clear Downloaded Covers and Artist Photos", nil, ^{
        [NSFileManager.defaultManager removeItemAtPath:SGLocalFileCoversDirectory() error:nil];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Cleared"
                                                                   message:@"Downloaded local file covers and artist photos have been removed."
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:a animated:YES completion:nil];
    }), @"trash");
    clearCovers.color = SGRed();

    return [[SGModPage alloc] initWithTitle:@"Your files"
                                      intro:@"Your own songs get a Your Files page with synced .lrc or .ttml lyrics."
                                   sections:@[
                                       SGSection(nil, @[openYourFiles, importedLrc]),
                                       SGNotedSection(@"Options", @[yourFilesToggle, animatedCovers, clearCovers],
                                                      @"Your Files Page needs Redesigned UI. The other settings work with either look."),
                                   ]
                                     footer:nil];
}

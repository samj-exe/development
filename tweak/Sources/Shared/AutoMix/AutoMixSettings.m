#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "AutoMix.h"

static SGModRow *contextRow(NSString *title, NSString *key) {
    SGModRow *row = SGSwitchRow(title, nil, key);
    row.waitsOn = SGKeyAutoMix;
    row.changed = ^(BOOL on) { SGAutoMixSettingsChanged(); };
    return row;
}

// The server's own config on the two mechanisms this page drives, out of the file Premium.m keeps for a support
// request: a crossfade that sounds like nothing while these lines say the flags are on is the difference between
// a config the core ignores and a preference the core never reads.
static NSString *configLines(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *file = [[caches URLByAppendingPathComponent:@"spoti.pw/AdBlock" isDirectory:YES] URLByAppendingPathComponent:@"live-config.txt"];
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @"No config recorded yet: Spoof Premium off, or nothing fetched this launch.";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *lower = line.lowercaseString;
        if (![lower containsString:@"crossfade"] && ![lower containsString:@"automix"] && ![lower containsString:@"gapless"]) continue;
        [lines addObject:line];
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"The config says nothing about crossfade or automix.";
}

UIViewController *SGAutoMixSettingsPage(void) {
    SGModRow *enabled = SGOptionRow(@"AutoMix", @"Spotify transitions with a crossfade fallback", SGKeyAutoMix);
    enabled.changed = ^(BOOL on) { SGAutoMixSettingsChanged(); };
    SGModRow *style = SGChoiceRow(@"Style", nil, SGKeyAutoMixStyle, @[@"Smart blend", @"Crossfade"], 0);
    style.choiceNotes = @[@"Use Spotify's transition plan when available, with crossfade for other songs.",
                          @"Use the selected crossfade duration."];
    style.waitsOn = SGKeyAutoMix;
    style.chosen = ^(NSInteger index) { SGAutoMixSettingsChanged(); };
    SGModRow *length = SGSliderRow(@"Crossfade length", @"Also used when no Spotify transition is available",
        1, 12, 1, ^double { return SGAutoMixBlendSeconds(); }, ^(double value) {
            SGSetInt(SGKeyAutoMixLength, (NSInteger)llround(value)); SGAutoMixSettingsChanged();
        }, ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f s", value]; });
    length.waitsOn = SGKeyAutoMix;
    SGModRow *status = SGStatRow(@"Current playback", ^NSString *{ return SGAutoMixStatus(); });
    status.refreshOn = SGAutoMixStatusDidChangeNotification;
    SGModRow *last = SGStatRow(@"Last track change", ^NSString *{
        return SGAutoMixLastTransition() ?: @"None yet this launch";
    });
    last.refreshOn = SGAutoMixStatusDidChangeNotification;
    SGModRow *apply = SGActionRow(@"Apply to current playback", @"Use this style and duration for the playlist already playing", ^{
        BOOL applied = SGAutoMixApplyCurrentPlayback();
        UIViewController *top = SGTopController();
        if (!top || top.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:applied ? @"Playback settings applied" : @"AutoMix is waiting"
            message:applied ? @"The transition happens near the end of the song. Use Preview next transition to jump to its last 15 seconds. Smart blend uses Spotify's plan when one is available; otherwise it crossfades." : SGAutoMixStatus()
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
    apply.waitsOn = SGKeyAutoMix;
    SGModRow *preview = SGActionRow(@"Preview next transition", @"Jump to the last 15 seconds of this song", ^{
        BOOL started = SGAutoMixPreviewTransition();
        UIViewController *top = SGTopController();
        if (!top || top.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:started ? @"Preview started" : @"Can't preview yet"
            message:started ? @"The song is moving to its final 15 seconds. Listen for the next song to fade in before this one ends. For a clear comparison, choose Crossfade with a 12-second length."
                : @"Play a music playlist or album on this iPhone with another song queued. The current song must be longer than 15 seconds."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
    preview.waitsOn = SGKeyAutoMix;
    SGModRow *details = SGStatActionRow(@"Transition details", @"What Spotify has supplied for this song", nil, ^{
        UIViewController *top = SGTopController();
        if (!top || top.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Transition details"
            message:SGAutoMixTransitionDetails() preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
    SGModRow *config = SGStatActionRow(@"Spotify's config", @"Crossfade and automix as the server sent them", nil, ^{
        UIViewController *top = SGTopController();
        if (!top || top.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Crossfade and automix in Spotify's config"
            message:configLines() preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
    return [[SGModPage alloc] initWithTitle:@"AutoMix"
        intro:@"Restart Spotify after enabling AutoMix, then start playback from a playlist or album. Start playback again after changing the context options."
        sections:@[
            SGSection(nil, @[enabled, style, length]),
            SGNotedSection(@"Apply to", @[
                contextRow(@"Playlists", SGKeyAutoMixPlaylists), contextRow(@"Albums", SGKeyAutoMixAlbums),
                contextRow(@"Liked Songs", SGKeyAutoMixLikedSongs), contextRow(@"Artists and radio", SGKeyAutoMixRadio),
                contextRow(@"Queued songs", SGKeyAutoMixQueue), contextRow(@"Autoplay", SGKeyAutoMixAutoplay),
            ], @"Other playback keeps Spotify's own settings. Podcasts, audiobooks, local files and ads are left alone."),
            SGSection(@"Try it", @[apply, preview]),
            SGSection(@"Status", @[status, last, details, config]),
        ] footer:@"Spotify supplies beat-matched transitions for supported songs and contexts. The selected crossfade fills gaps where no transition plan is available. Bluetooth works as local playback; a separate Spotify Connect device controls its own playback capabilities."];
}

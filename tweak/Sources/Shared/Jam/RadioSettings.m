#import "Radio.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"

UIViewController *SGICYRadioSettingsPage(void) {
    SGModRow *enabled = SGOptionRow(@"Enable ICY radio",
        @"Share Spotify playback as a local MP3 radio stream", SGKeyICYRadio);
    enabled.changed = ^(BOOL on) { SGICYRadioSetEnabled(on); };
    enabled.info = @"The local listener is available to devices on this Wi-Fi while Spotify is running. It starts again when Spotify launches if left enabled.";

    SGModRow *status = SGStatRow(@"Radio status", ^NSString *{ return SGICYRadioStatus(); });
    status.refreshOn = SGICYRadioDidChangeNotification;

    SGModRow *copyStream = SGActionRow(@"Copy stream URL", @"Add this URL as a radio stream in Music Assistant", ^{
        NSString *url = SGICYRadioStreamURL();
        if (url) UIPasteboard.generalPasteboard.string = url;
    });
    copyStream.visible = ^BOOL { return SGICYRadioStreamURL() != nil; };

    SGModRow *copyToken = SGActionRow(@"Copy Home Assistant token",
        @"Required to control Spotify from Home Assistant", ^{
            UIPasteboard.generalPasteboard.string = SGICYRadioControlToken();
        });

    return [[SGModPage alloc] initWithTitle:@"ICY Radio" intro:nil sections:@[
        SGNotedSection(@"Local stream", @[enabled, status, copyStream],
            @"MP3 audio and ICY track metadata are served on port 8788. Add the copied URL to Music Assistant as a local radio stream. Spotify must be playing on this iPhone; audio from a Spotify Connect receiver is not captured."),
        SGNotedSection(@"Playback controls", @[copyToken],
            @"The token grants playback control to anyone who has it. Keep it private and use it only on a trusted local network. Home Assistant can send play, pause, toggle, next, previous and seek commands; see docs/tweaks.md for REST examples."),
    ] footer:nil];
}

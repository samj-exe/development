#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "MatrixDisplay.h"

static void selectFromScan(UIViewController *owner) {
    SGMatrixScanDisplays(^(NSArray<NSDictionary *> *displays) {
        if (!displays.count) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No displays found" message:@"Turn on the iDotMatrix display and scan again." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            if (owner.presentedViewController) owner = owner.presentedViewController;
            [owner presentViewController:alert animated:YES completion:nil];
            return;
        }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Choose a display" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *display in displays) {
            NSString *name = display[@"name"] ?: @"iDotMatrix";
            [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:display[@"id"]];
                if (identifier) SGMatrixSelectDisplay(identifier, name);
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        if (owner.presentedViewController) owner = owner.presentedViewController;
        [owner presentViewController:sheet animated:YES completion:nil];
    });
}

UIViewController *SGMatrixSettingsPage(void) {
    SGModRow *enabled = SGOptionRow(@"Stream album artwork", @"Send Spotify's current cover to an iDotMatrix display", SGKeyMatrixEnabled);
    enabled.changed = ^(BOOL on) { (void)on; if (on) SGMatrixSendCurrentTrack(); };
    SGModRow *scan = SGActionRow(@"Choose display", @"Scan for an iDotMatrix or iPixel device", ^{
        UIViewController *owner = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                owner = ((UIWindowScene *)scene).windows.firstObject.rootViewController;
                break;
            }
        }
        if (!owner) return;
        selectFromScan(owner);
    });
    SGModRow *send = SGActionRow(@"Send current artwork", @"Update the display from the track playing now", ^{ SGMatrixSendCurrentTrack(); });
    SGModRow *selected = SGStatRow(@"Selected display", ^NSString *{ return SGMatrixSelectedDisplayName() ?: @"None selected"; });
    NSArray<SGModRow *> *rows = @[
        SGWithSymbol(enabled, @"rectangle.3.group.bubble.left"),
        SGWithSymbol(selected, @"dot.radiowaves.left.and.right"),
        SGWithSymbol(scan, @"antenna.radiowaves.left.and.right"),
        SGWithSymbol(send, @"square.and.arrow.up")
    ];
    return [[SGModPage alloc] initWithTitle:@"iDotMatrix" intro:nil sections:@[SGNotedSection(nil, rows, @"Uses the same 32 × 32 RGB frame and Bluetooth protocol as OpenMatrix. No Last.fm account is used.")] footer:nil];
}

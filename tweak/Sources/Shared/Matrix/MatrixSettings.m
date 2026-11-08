#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "MatrixDisplay.h"

static void selectFromScan(UIViewController *owner) {
    SGMatrixScanDisplays(^(NSArray<NSDictionary *> *displays) {
        if (!displays.count) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No displays found" message:@"Turn on the iDotMatrix display and scan again." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *presenter = owner.presentedViewController ?: owner;
            [presenter presentViewController:alert animated:YES completion:nil];
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
        UIViewController *presenter = owner.presentedViewController ?: owner;
        [presenter presentViewController:sheet animated:YES completion:nil];
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

    SGModRow *saturation = SGSliderRow(@"Saturation boost", @"OpenMatrix-style colour boost",
        0, 3, 0.1,
        ^double { id value = [NSUserDefaults.standardUserDefaults objectForKey:SGKeyMatrixSaturation]; return value ? [(NSNumber *)value doubleValue] : 1.0; },
        ^(double value) { [NSUserDefaults.standardUserDefaults setDouble:value forKey:SGKeyMatrixSaturation]; SGMatrixSendCurrentTrack(); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%.2f×", value]; });
    SGModRow *contrast = SGSliderRow(@"Contrast", @"OpenMatrix-style tonal contrast",
        0, 3, 0.1,
        ^double { id value = [NSUserDefaults.standardUserDefaults objectForKey:SGKeyMatrixContrast]; return value ? [(NSNumber *)value doubleValue] : 1.0; },
        ^(double value) { [NSUserDefaults.standardUserDefaults setDouble:value forKey:SGKeyMatrixContrast]; SGMatrixSendCurrentTrack(); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%.2f×", value]; });
    SGModRow *sharpness = SGSliderRow(@"Sharpness", @"Neighbour-based edge enhancement",
        0, 3, 0.1,
        ^double { id value = [NSUserDefaults.standardUserDefaults objectForKey:SGKeyMatrixSharpness]; return value ? [(NSNumber *)value doubleValue] : 0.0; },
        ^(double value) { [NSUserDefaults.standardUserDefaults setDouble:value forKey:SGKeyMatrixSharpness]; SGMatrixSendCurrentTrack(); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%.2f", value]; });
    SGModRow *orientation = SGMenuRow(@"Orientation", @[@"0°", @"90°", @"180°", @"270°"],
        ^NSString *{ NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:SGKeyMatrixOrientation]; switch (value) { case 90: return @"90°"; case 180: return @"180°"; case 270: return @"270°"; default: return @"0°"; } },
        ^(NSInteger index) { NSInteger values[] = {0, 90, 180, 270}; [NSUserDefaults.standardUserDefaults setInteger:values[index] forKey:SGKeyMatrixOrientation]; SGMatrixSendCurrentTrack(); });
    SGModRow *mirror = SGOptionRow(@"Mirror horizontally", @"Flip the album artwork horizontally", SGKeyMatrixMirrored);
    mirror.changed = ^(BOOL on) { (void)on; SGMatrixSendCurrentTrack(); };

    NSArray<SGModRow *> *connection = @[
        SGWithSymbol(enabled, @"rectangle.3.group.bubble.left"),
        SGWithSymbol(selected, @"dot.radiowaves.left.and.right"),
        SGWithSymbol(scan, @"antenna.radiowaves.left.and.right"),
        SGWithSymbol(send, @"square.and.arrow.up")
    ];
    NSArray<SGModRow *> *adjustments = @[
        SGWithSymbol(saturation, @"circle.lefthalf.filled"),
        SGWithSymbol(contrast, @"circle.hexagongrid.fill"),
        SGWithSymbol(sharpness, @"sparkles.rectangle.stack"),
        SGWithSymbol(orientation, @"rotate.right"),
        SGWithSymbol(mirror, @"rectangle.lefthalf.inset.filled")
    ];
    return [[SGModPage alloc] initWithTitle:@"iDotMatrix" intro:nil sections:@[
        SGNotedSection(@"Display", connection, nil),
        SGNotedSection(@"Image adjustments", adjustments, @"Matches the OpenMatrix cover crop and post-processing controls.")
    ] footer:nil];
}

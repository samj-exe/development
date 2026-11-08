#import <Foundation/Foundation.h>

#define SGKeyMatrixEnabled @"spotifyglass.matrix.enabled"
#define SGKeyMatrixDisplayID @"spotifyglass.matrix.displayID"
#define SGKeyMatrixDisplayName @"spotifyglass.matrix.displayName"
#define SGKeyMatrixSaturation @"saturationBoost"
#define SGKeyMatrixContrast @"imageContrast"
#define SGKeyMatrixSharpness @"imageSharpness"
#define SGKeyMatrixOrientation @"imageOrientation"
#define SGKeyMatrixMirrored @"imageMirrored"

NSString *SGMatrixSelectedDisplayName(void);
void SGMatrixSelectDisplay(NSUUID *identifier, NSString *name);
void SGMatrixScanDisplays(void (^done)(NSArray<NSDictionary *> *displays));
void SGMatrixSendCurrentTrack(void);
@class UIViewController;
UIViewController *SGMatrixSettingsPage(void);

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define SGKeyICYRadio @"spotifyglass.jam.icyRadio"
#define SGICYRadioPort 8788

extern NSNotificationName const SGICYRadioDidChangeNotification;

BOOL SGICYRadioEnabled(void);
BOOL SGICYRadioRunning(void);
NSString *SGICYRadioStatus(void);
NSString *SGICYRadioStreamURL(void);
NSString *SGICYRadioControlToken(void);
void SGICYRadioSetEnabled(BOOL on);
void SGICYRadioRuntimeStart(void);
UIViewController *SGICYRadioSettingsPage(void);

#import <Foundation/Foundation.h>

void SGWebJamAudioStart(void);
void SGWebJamAudioStop(void);
void SGWebJamAudioICYStart(void);
void SGWebJamAudioICYStop(void);
// Main thread: invalidates buffered audio on pause, track changes and seeks.
void SGWebJamAudioUpdate(BOOL playing, NSString *uri, double position);
NSDictionary *SGWebJamAudioStatus(void);
// Completion runs on the audio worker. WJAM envelope followed by a complete PCM WAV.
void SGWebJamAudioNext(uint32_t epoch, uint32_t after, void (^done)(NSData *packet));
// Reads one live MP3 frame; the caller owns the returned data.
NSData *SGWebJamAudioICYNext(uint32_t epoch, uint32_t after, uint32_t *currentEpoch, uint32_t *sequence);
NSDictionary *SGWebJamAudioICYStatus(void);

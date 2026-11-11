#import "Radio.h"
#import "Core/SGLog.h"
#import "Core/SGPrefs.h"
#import "Shared/Jam/WebJamAudio.h"
#import "Shared/Jam/WebJamRules.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"
#import <Network/Network.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>

NSNotificationName const SGICYRadioDidChangeNotification = @"spotifyglass.jam.icyRadio.changed";

static const NSUInteger kHeaderLimit = 8192, kBodyLimit = 4096;
static NSString *sg_radioStatus;
static NSTimeInterval sg_lastControl;

static dispatch_data_t dataMessage(NSData *data) {
    return dispatch_data_create(data.bytes, data.length, nil, ^{ (void)data; });
}

static NSString *wifiAddress(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return nil;
    NSString *address = nil;
    for (struct ifaddrs *at = interfaces; at; at = at->ifa_next) {
        if (!at->ifa_addr || at->ifa_addr->sa_family != AF_INET || !at->ifa_name ||
            strcmp(at->ifa_name, "en0") != 0) continue;
        char text[INET_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET, &((struct sockaddr_in *)at->ifa_addr)->sin_addr, text, sizeof text)) continue;
        NSString *candidate = [NSString stringWithUTF8String:text];
        if (candidate.length && ![candidate hasPrefix:@"127."] && ![candidate hasPrefix:@"169.254."]) {
            address = candidate;
            break;
        }
    }
    freeifaddrs(interfaces);
    return address;
}

static NSString *newToken(void) {
    uint8_t bytes[32];
    arc4random_buf(bytes, sizeof bytes);
    NSMutableString *token = [NSMutableString stringWithCapacity:sizeof bytes * 2];
    for (NSUInteger i = 0; i < sizeof bytes; i++) [token appendFormat:@"%02x", bytes[i]];
    return token;
}

NSString *SGICYRadioControlToken(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *token = [defaults stringForKey:@"spotifyglass.jam.icyRadio.token"];
    if (token.length != 64) {
        token = newToken();
        [defaults setObject:token forKey:@"spotifyglass.jam.icyRadio.token"];
    }
    return token;
}

BOOL SGICYRadioEnabled(void) { return SGFlag(SGKeyICYRadio, NO); }

static void setStatus(NSString *status) {
    if ([sg_radioStatus isEqualToString:status]) return;
    sg_radioStatus = [status copy] ?: @"";
    SGLog(@"icy radio: %@", sg_radioStatus);
    [NSNotificationCenter.defaultCenter postNotificationName:SGICYRadioDidChangeNotification object:nil];
}

NSString *SGICYRadioStatus(void) { return sg_radioStatus ?: @"Off"; }
BOOL SGICYRadioRunning(void);

NSString *SGICYRadioStreamURL(void) {
    if (!SGICYRadioRunning()) return nil;
    NSString *address = wifiAddress();
    return address ? [NSString stringWithFormat:@"http://%@:%d/stream", address, SGICYRadioPort] : nil;
}

static NSString *cleanText(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    text = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
    if (text.length <= limit) return text;
    return [text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, limit)]];
}

static NSString *albumName(NSDictionary *metadata) {
    for (NSString *key in @[@"album_name", @"album_title", @"album"]) {
        id value = metadata[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return cleanText(value, 256);
        if ([value isKindOfClass:NSDictionary.class]) {
            id title = value[@"name"] ?: value[@"title"];
            if ([title isKindOfClass:NSString.class] && [title length]) return cleanText(title, 256);
        }
    }
    return @"";
}

static NSDictionary *trackMetadata(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSUInteger count = 0;
    for (id key in metadata) {
        if (![key isKindOfClass:NSString.class] || [(NSString *)key length] > 100 || count >= 64) continue;
        id value = metadata[key];
        if (![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSNumber.class]) continue;
        result[key] = cleanText([value description], 256);
        count++;
    }
    return result;
}

static NSDictionary *playbackSnapshot(void) {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *track = state.track;
    NSDictionary *metadata = [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : @{};
    NSString *title = cleanText(track.trackTitle, 256);
    NSString *artist = cleanText(track.artistName, 256);
    double position = state.isPaused ? state.positionAsOfTimestamp : state.position;
    double duration = state.duration;
    double speed = state.playbackSpeed;
    if (!isfinite(position) || position < 0) position = 0;
    if (!isfinite(duration) || duration < 0) duration = 0;
    if (!isfinite(speed) || speed <= 0 || speed > 4) speed = 1;
    NSString *uri = SGURIString(track.URI) ?: @"";
    return @{
        @"title": title, @"artist": artist, @"album": albumName(metadata), @"uri": uri,
        @"artwork": SGWebJamCoverURL(metadata) ?: @"",
        @"playing": @(state && state.isPlaying && !state.isPaused),
        @"paused": @(state && state.isPaused), @"position": @(position), @"position_ms": @((long long)llround(position * 1000)),
        @"duration": @(duration), @"duration_ms": @((long long)llround(duration * 1000)),
        @"playback_speed": @(speed), @"position_updated_at": @([NSDate.date timeIntervalSince1970]),
        @"metadata": trackMetadata(metadata)
    };
}

@class SGICYRadioHTTP;

@interface SGICYRadioServer : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (atomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL wanted;
@property (nonatomic, assign) BOOL listening;
@property (nonatomic, strong) nw_listener_t listener;
@property (nonatomic, strong) NSMutableSet<SGICYRadioHTTP *> *connections;
@property (atomic, assign) NSUInteger generation;
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) NSTimer *ticker;
- (void)start;
- (void)stop;
- (void)accept:(nw_connection_t)connection;
- (void)finished:(SGICYRadioHTTP *)connection;
- (void)createListener:(NSUInteger)generation;
- (void)listenerState:(nw_listener_state_t)state generation:(NSUInteger)generation;
- (void)refreshSnapshot;
@end

static SGICYRadioServer *sg_radioServer;

static SGICYRadioServer *radioServer(void) {
    if (!sg_radioServer) sg_radioServer = [SGICYRadioServer new];
    return sg_radioServer;
}

@interface SGICYRadioHTTP : NSObject
- (instancetype)initWithConnection:(nw_connection_t)connection server:(SGICYRadioServer *)server;
- (void)begin;
- (void)cancel;
+ (BOOL)tokenMatches:(NSString *)header;
@end

@implementation SGICYRadioHTTP {
    nw_connection_t _connection;
    __weak SGICYRadioServer *_server;
    dispatch_queue_t _queue;
    NSMutableData *_buffer;
    BOOL _finished, _reading, _headersRead, _routed, _streaming;
    BOOL _wantsICYMetadata;
    _Atomic BOOL _rejected;
    NSUInteger _generation, _headerEnd;
    NSInteger _contentLength;
    NSString *_method, *_path, *_contentType, *_host, *_origin, *_authorization;
    uint32_t _audioEpoch, _audioSequence;
    NSUInteger _metadataRemaining, _frameOffset;
    NSData *_pendingFrame;
}

- (instancetype)initWithConnection:(nw_connection_t)connection server:(SGICYRadioServer *)server {
    if (!(self = [super init])) return nil;
    _connection = connection;
    _server = server;
    _queue = server.queue;
    _generation = server.generation;
    _buffer = [NSMutableData new];
    _metadataRemaining = 16000;
    return self;
}

- (void)begin {
    dispatch_queue_t queue = _queue;
    __weak SGICYRadioHTTP *weakSelf = self;
    nw_connection_set_queue(_connection, _queue);
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        (void)error;
        if (state == nw_connection_state_failed || state == nw_connection_state_cancelled)
            dispatch_async(queue, ^{ [weakSelf connectionEnded]; });
    });
    nw_connection_start(_connection);
    [self receiveMore];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), _queue, ^{ [weakSelf timeOut]; });
}

- (void)connectionEnded {
    if (_finished) return;
    _finished = YES;
    _rejected = YES;
    [_server finished:self];
}

- (void)timeOut {
    if (_finished || _streaming) return;
    [self respond:408 body:@{@"error": @"request timed out"}];
}

- (void)cancel {
    _rejected = YES;
    _finished = YES;
    nw_connection_cancel(_connection);
    [_server finished:self];
}

- (void)receiveMore {
    if (_finished || _reading || _routed) return;
    _reading = YES;
    dispatch_queue_t queue = _queue;
    __weak SGICYRadioHTTP *weakSelf = self;
    nw_connection_receive(_connection, 1, 4096, ^(dispatch_data_t content,
        nw_content_context_t context, bool complete, nw_error_t error) {
        (void)context;
        NSMutableData *chunk = [NSMutableData new];
        if (content) dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
            const void *bytes, size_t size) {
            (void)region; (void)offset;
            [chunk appendBytes:bytes length:size];
            return true;
        });
        dispatch_async(queue, ^{
            SGICYRadioHTTP *strong = weakSelf;
            if (!strong) return;
            strong->_reading = NO;
            if (error) { [strong cancel]; return; }
            [strong->_buffer appendData:chunk];
            [strong parse];
            if (complete && !strong->_routed && !strong->_finished)
                [strong respond:400 body:@{@"error": @"incomplete request"}];
            else [strong receiveMore];
        });
    });
}

- (void)parse {
    if (_finished || _routed) return;
    if (!_headersRead) {
        NSData *mark = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange range = [_buffer rangeOfData:mark options:0 range:NSMakeRange(0, _buffer.length)];
        if (range.location == NSNotFound) {
            if (_buffer.length > kHeaderLimit) [self respond:431 body:@{@"error": @"headers too large"}];
            return;
        }
        _headerEnd = NSMaxRange(range);
        if (_headerEnd > kHeaderLimit) { [self respond:431 body:@{@"error": @"headers too large"}]; return; }
        [self readHeaders:[_buffer subdataWithRange:NSMakeRange(0, range.location)]];
        _headersRead = YES;
        if (_finished) return;
    }
    NSUInteger bodyLength = _buffer.length - _headerEnd;
    if (bodyLength > kBodyLimit) { [self respond:413 body:@{@"error": @"body too large"}]; return; }
    if (bodyLength < (NSUInteger)_contentLength) return;
    NSData *body = [_buffer subdataWithRange:NSMakeRange(_headerEnd, (NSUInteger)_contentLength)];
    _routed = YES;
    [self route:body];
}

- (void)readHeaders:(NSData *)data {
    NSString *head = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *request = [lines.firstObject componentsSeparatedByString:@" "];
    if (request.count != 3 ||
        (![request[2] isEqualToString:@"HTTP/1.0"] && ![request[2] isEqualToString:@"HTTP/1.1"]) ||
        ![request[1] hasPrefix:@"/"] || request[1].length > 512) {
        [self respond:400 body:@{@"error": @"bad request line"}]; return;
    }
    _method = request[0];
    _path = request[1];
    BOOL sawLength = NO, sawType = NO, sawHost = NO, sawAuthorization = NO, sawOrigin = NO;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (!line.length || colon.location == NSNotFound || colon.location == 0) continue;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            [self respond:400 body:@{@"error": @"invalid header"}]; return;
        }
        if ([name isEqualToString:@"transfer-encoding"] || [name isEqualToString:@"expect"]) {
            [self respond:400 body:@{@"error": @"unsupported transfer encoding"}]; return;
        }
        if ([name isEqualToString:@"host"]) {
            if (sawHost) { [self respond:400 body:@{@"error": @"duplicate host"}]; return; }
            sawHost = YES; _host = value;
        } else if ([name isEqualToString:@"authorization"]) {
            if (sawAuthorization) { [self respond:400 body:@{@"error": @"duplicate authorization"}]; return; }
            sawAuthorization = YES; _authorization = value;
        } else if ([name isEqualToString:@"origin"]) {
            if (sawOrigin) { [self respond:400 body:@{@"error": @"duplicate origin"}]; return; }
            sawOrigin = YES; _origin = value;
        } else if ([name isEqualToString:@"content-type"]) {
            if (sawType) { [self respond:400 body:@{@"error": @"duplicate content type"}]; return; }
            sawType = YES; _contentType = value;
        } else if ([name isEqualToString:@"content-length"]) {
            if (sawLength || !value.length ||
                [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) {
                [self respond:400 body:@{@"error": @"invalid content length"}]; return;
            }
            sawLength = YES;
            long long length = value.longLongValue;
            if (length > kBodyLimit) { [self respond:413 body:@{@"error": @"body too large"}]; return; }
            _contentLength = (NSInteger)length;
        } else if ([name isEqualToString:@"icy-metadata"]) {
            _wantsICYMetadata = [value isEqualToString:@"1"];
        }
    }
    NSString *address = wifiAddress();
    NSString *authority = address ? [NSString stringWithFormat:@"%@:%d", address, SGICYRadioPort] : nil;
    if (!_host || ![_host isEqualToString:authority]) { [self respond:403 body:@{@"error": @"host must be this Wi-Fi address"}]; return; }
    if (![_method isEqualToString:@"GET"] && ![_method isEqualToString:@"POST"]) {
        [self respond:405 body:@{@"error": @"method not allowed"}]; return;
    }
    if ([_method isEqualToString:@"POST"] && !sawLength) [self respond:411 body:@{@"error": @"content length required"}];
}

- (void)route:(NSData *)body {
    if (_finished || _rejected || !_server.enabled || _server.generation != _generation) return;
    NSURLComponents *parts = [NSURLComponents componentsWithString:_path];
    NSString *path = parts.path;
    if ([_method isEqualToString:@"GET"] && [path isEqualToString:@"/stream"]) {
        [self beginStream];
        return;
    }
    if ([_method isEqualToString:@"GET"] && [path isEqualToString:@"/"]) {
        [self respond:200 body:@{@"name": @"Spotify Local Radio", @"stream": @"/stream",
            @"state": @"/api/state", @"control": @"/api/control"}];
        return;
    }
    if (![[self class] tokenMatches:_authorization]) { [self respond:401 body:@{@"error": @"bearer token required"}]; return; }
    if ([_method isEqualToString:@"GET"] && [path isEqualToString:@"/api/state"]) {
        [self respond:200 body:_server.snapshot ?: @{}];
        return;
    }
    if ([_method isEqualToString:@"POST"] && [path isEqualToString:@"/api/control"]) {
        NSString *type = [[_contentType.lowercaseString componentsSeparatedByString:@";"].firstObject
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![type isEqualToString:@"application/json"]) { [self respond:415 body:@{@"error": @"send application/json"}]; return; }
        if (_origin.length && ![_origin isEqualToString:[@"http://" stringByAppendingString:_host]]) {
            [self respond:403 body:@{@"error": @"cross-origin controls are not allowed"}]; return;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        NSDictionary *object = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        [self control:object];
        return;
    }
    [self respond:404 body:@{@"error": @"not found"}];
}

+ (BOOL)tokenMatches:(NSString *)header {
    if (![header hasPrefix:@"Bearer "]) return NO;
    NSData *provided = [[header substringFromIndex:7] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *expected = [SGICYRadioControlToken() dataUsingEncoding:NSUTF8StringEncoding];
    if (provided.length != expected.length) return NO;
    const uint8_t *a = provided.bytes, *b = expected.bytes;
    uint8_t difference = 0;
    for (NSUInteger i = 0; i < expected.length; i++) difference |= a[i] ^ b[i];
    return difference == 0;
}

- (void)control:(NSDictionary *)object {
    __block NSString *action = [object isKindOfClass:NSDictionary.class] && [object[@"action"] isKindOfClass:NSString.class]
        ? object[@"action"] : nil;
    if (![@[@"play", @"pause", @"toggle", @"next", @"previous", @"seek"] containsObject:action]) {
        [self respond:400 body:@{@"error": @"action must be play, pause, toggle, next, previous, or seek"}]; return;
    }
    NSNumber *positionValue = object[@"position"];
    double position = [positionValue isKindOfClass:NSNumber.class] ? positionValue.doubleValue : NAN;
    if ([action isEqualToString:@"seek"] && (!isfinite(position) || position < 0)) {
        [self respond:400 body:@{@"error": @"seek requires a non-negative position in seconds"}]; return;
    }
    __block NSInteger result = 200;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!self->_server.enabled || self->_server.generation != self->_generation) { result = 503; return; }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now - sg_lastControl < 0.25) { result = 429; return; }
        sg_lastControl = now;
        id<SPTPlayer> player = SGPlaybackPlayer();
        SPTPlayerState *state = SGPlayerState();
        if (!player) { result = 503; return; }
        if ([action isEqualToString:@"toggle"]) action = state.isPlaying && !state.isPaused ? @"pause" : @"play";
        if ([action isEqualToString:@"play"]) {
            if (![player respondsToSelector:@selector(resume:)]) { result = 503; return; }
            [player resume:nil];
        } else if ([action isEqualToString:@"pause"]) {
            if (![player respondsToSelector:@selector(pause:)]) { result = 503; return; }
            [player pause:nil];
        } else if ([action isEqualToString:@"next"]) {
            if (![player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) { result = 503; return; }
            [player skipToNextTrackWithOptions:nil];
        } else if ([action isEqualToString:@"previous"]) {
            if (![player respondsToSelector:@selector(skipToPreviousTrackWithOptions:)]) { result = 503; return; }
            [player skipToPreviousTrackWithOptions:nil];
        } else if ([action isEqualToString:@"seek"]) {
            if (!state || (state.duration > 0 && position > state.duration)) { result = 400; return; }
            if (![player respondsToSelector:@selector(seekTo:)]) { result = 503; return; }
            [player seekTo:position];
        }
    });
    if (result == 200) [self respond:200 body:@{@"ok": @YES, @"action": action}];
    else [self respond:result body:@{@"error": result == 429 ? @"control rate limited" :
        result == 400 ? @"position is outside the current track" : @"Spotify player is not ready"}];
}

- (void)beginStream {
    NSDictionary *audio = SGWebJamAudioICYStatus();
    if (![audio[@"supported"] boolValue]) {
        [self respond:503 body:@{@"error": @"MP3 capture is unavailable for the current audio format"}];
        return;
    }
    NSString *metadataHeader = _wantsICYMetadata ? @"icy-metaint: 16000\r\n" : @"";
    NSString *headers = [NSString stringWithFormat:
        @"HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\n"
         "icy-name: Spotify Local Radio\r\nicy-genre: Spotify\r\nicy-br: 128\r\n"
         "%@Cache-Control: no-store\r\nConnection: close\r\n\r\n", metadataHeader];
    NSData *data = [headers dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_data_t content = dataMessage(data);
    _streaming = YES;
    dispatch_queue_t queue = _queue;
    __weak SGICYRadioHTTP *weakSelf = self;
    nw_connection_send(_connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        if (error) { dispatch_async(queue, ^{ [weakSelf cancel]; }); return; }
        dispatch_async(queue, ^{ [weakSelf streamNext]; });
    });
}

- (NSData *)metadataBlock {
    NSDictionary *snapshot = _server.snapshot ?: @{};
    NSString *artist = cleanText(snapshot[@"artist"], 256), *title = cleanText(snapshot[@"title"], 256);
    NSString *uri = cleanText(snapshot[@"uri"], 256);
    NSMutableString *streamTitle = [NSMutableString new];
    if (artist.length && title.length) [streamTitle appendFormat:@"%@ - %@", artist, title];
    else [streamTitle appendString:title.length ? title : artist.length ? artist : @"Spotify Local Radio"];
    [streamTitle replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, streamTitle.length)];
    [streamTitle replaceOccurrencesOfString:@"'" withString:@"\\'" options:0 range:NSMakeRange(0, streamTitle.length)];
    NSMutableString *metadata = [NSMutableString stringWithFormat:@"StreamTitle='%@';", streamTitle];
    if (uri.length) [metadata appendFormat:@"StreamUrl='%@';", uri];
    NSData *bytes = [metadata dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length > 4080) bytes = [[@"StreamTitle='Spotify Local Radio';" dataUsingEncoding:NSUTF8StringEncoding] copy];
    NSUInteger padded = (bytes.length + 15) & ~((NSUInteger)15);
    NSMutableData *block = [NSMutableData dataWithLength:1 + padded];
    ((uint8_t *)block.mutableBytes)[0] = (uint8_t)(padded / 16);
    if (bytes.length) [block replaceBytesInRange:NSMakeRange(1, bytes.length) withBytes:bytes.bytes];
    return block;
}

- (void)streamNext {
    if (!_streaming || _finished || _rejected || !_server.enabled || _server.generation != _generation) {
        [self cancel]; return;
    }
    if (!_pendingFrame || _frameOffset >= _pendingFrame.length) {
        uint32_t epoch = 0, sequence = _audioSequence;
        NSData *frame = SGWebJamAudioICYNext(_audioEpoch, _audioSequence, &epoch, &sequence);
        if (!frame) {
            if (![SGWebJamAudioICYStatus()[@"supported"] boolValue]) { [self cancel]; return; }
            __weak SGICYRadioHTTP *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), _queue, ^{ [weakSelf streamNext]; });
            return;
        }
        _audioEpoch = epoch;
        _audioSequence = sequence;
        _pendingFrame = frame;
        _frameOffset = 0;
    }
    NSUInteger available = _pendingFrame.length - _frameOffset;
    NSUInteger length = _wantsICYMetadata ? MIN(available, _metadataRemaining) : available;
    NSData *chunk = [_pendingFrame subdataWithRange:NSMakeRange(_frameOffset, length)];
    dispatch_data_t content = dataMessage(chunk);
    dispatch_queue_t queue = _queue;
    __weak SGICYRadioHTTP *weakSelf = self;
    nw_connection_send(_connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        if (error) { dispatch_async(queue, ^{ [weakSelf cancel]; }); return; }
        dispatch_async(queue, ^{
            SGICYRadioHTTP *strong = weakSelf;
            if (!strong || !strong->_streaming) return;
            strong->_frameOffset += length;
            if (strong->_wantsICYMetadata) strong->_metadataRemaining -= length;
            if (strong->_wantsICYMetadata && strong->_metadataRemaining == 0) [strong sendMetadata];
            else [strong streamNext];
        });
    });
}

- (void)sendMetadata {
    NSData *block = [self metadataBlock];
    dispatch_data_t content = dataMessage(block);
    dispatch_queue_t queue = _queue;
    __weak SGICYRadioHTTP *weakSelf = self;
    nw_connection_send(_connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        if (error) { dispatch_async(queue, ^{ [weakSelf cancel]; }); return; }
        dispatch_async(queue, ^{
            SGICYRadioHTTP *strong = weakSelf;
            if (!strong || !strong->_streaming) return;
            strong->_metadataRemaining = 16000;
            [strong streamNext];
        });
    });
}

- (void)respond:(NSInteger)code body:(NSDictionary *)object {
    if (_finished) return;
    NSData *body = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:0 error:nil] ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *reason = code == 200 ? @"OK" : code == 400 ? @"Bad Request" : code == 401 ? @"Unauthorized" :
        code == 403 ? @"Forbidden" : code == 404 ? @"Not Found" : code == 405 ? @"Method Not Allowed" :
        code == 411 ? @"Length Required" : code == 413 ? @"Payload Too Large" : code == 415 ? @"Unsupported Media Type" :
        code == 429 ? @"Too Many Requests" : code == 431 ? @"Request Header Fields Too Large" :
        code == 503 ? @"Service Unavailable" : @"Internal Server Error";
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Type: application/json; charset=utf-8\r\n"
        "Content-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n",
        (long)code, reason, (unsigned long)body.length];
    NSMutableData *response = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:body];
    dispatch_data_t content = dataMessage(response);
    _finished = YES;
    dispatch_queue_t queue = _queue;
    __weak SGICYRadioHTTP *weakSelf = self;
    nw_connection_send(_connection, content, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        (void)error;
        dispatch_async(queue, ^{ [weakSelf cancel]; });
    });
}

@end

@implementation SGICYRadioServer

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("spotifyglass.icyRadio", DISPATCH_QUEUE_SERIAL);
    _connections = [NSMutableSet set];
    return self;
}

- (void)start {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    if (self.enabled) return;
    self.enabled = YES;
    self.generation++;
    NSUInteger generation = self.generation;
    self.snapshot = playbackSnapshot();
    setStatus(@"Starting…");
    dispatch_async(self.queue, ^{ self.wanted = YES; [self createListener:generation]; });
}

- (void)createListener:(NSUInteger)generation {
    if (!self.wanted || self.listener) return;
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    if (parameters) nw_parameters_set_required_interface_type(parameters, nw_interface_type_wifi);
    NSString *port = [NSString stringWithFormat:@"%d", SGICYRadioPort];
    nw_listener_t listener = parameters ? nw_listener_create_with_port(port.UTF8String, parameters) : NULL;
    if (!listener) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (generation == self.generation) [self unavailable]; });
        return;
    }
    self.listener = listener;
    nw_listener_set_queue(listener, self.queue);
    __weak SGICYRadioServer *weakSelf = self;
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        (void)error;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf listenerState:state generation:generation]; });
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        if (!weakSelf || generation != weakSelf.generation) nw_connection_cancel(connection);
        else [weakSelf accept:connection];
    });
    nw_listener_start(listener);
    self.listening = YES;
}

- (void)listenerState:(nw_listener_state_t)state generation:(NSUInteger)generation {
    if (generation != self.generation || !self.enabled) return;
    if (state == nw_listener_state_ready) {
        SGWebJamAudioICYStart();
        [self refreshSnapshot];
        __weak SGICYRadioServer *weakSelf = self;
        self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            SGICYRadioServer *strong = weakSelf;
            if (!strong || !strong.enabled) return;
            [strong refreshSnapshot];
        }];
        setStatus(@"On · MP3 stream available on this Wi-Fi");
    } else if (state == nw_listener_state_waiting) {
        setStatus(@"On · waiting for this Wi-Fi");
    } else if (state == nw_listener_state_failed) {
        [self unavailable];
    } else if (state == nw_listener_state_cancelled) {
        [self stop];
    }
}

- (void)refreshSnapshot {
    SPTPlayerState *state = SGPlayerState();
    NSString *uri = SGURIString(state.track.URI) ?: @"";
    double position = state.isPaused ? state.positionAsOfTimestamp : state.position;
    SGWebJamAudioUpdate(state && state.isPlaying && !state.isPaused, uri, position);
    self.snapshot = playbackSnapshot();
}

- (void)unavailable {
    [self stop];
    setStatus(@"ICY radio unavailable");
}

- (void)stop {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; });
        return;
    }
    self.enabled = NO;
    self.generation++;
    SGWebJamAudioICYStop();
    [self.ticker invalidate];
    self.ticker = nil;
    SGSetEnabled(SGKeyICYRadio, NO);
    self.snapshot = @{};
    setStatus(@"Off");
    __weak SGICYRadioServer *weakSelf = self;
    dispatch_async(self.queue, ^{
        weakSelf.wanted = NO;
        for (SGICYRadioHTTP *connection in weakSelf.connections.allObjects) [connection cancel];
        [weakSelf.connections removeAllObjects];
        if (weakSelf.listener) {
            nw_listener_cancel(weakSelf.listener);
            weakSelf.listener = nil;
        }
        weakSelf.listening = NO;
    });
}

- (void)accept:(nw_connection_t)connection {
    if (!self.wanted || !self.listening || self.connections.count >= 8) {
        nw_connection_cancel(connection);
        return;
    }
    SGICYRadioHTTP *http = [[SGICYRadioHTTP alloc] initWithConnection:connection server:self];
    [self.connections addObject:http];
    [http begin];
}

- (void)finished:(SGICYRadioHTTP *)connection {
    [self.connections removeObject:connection];
}

@end

BOOL SGICYRadioRunning(void) { return radioServer().enabled; }

void SGICYRadioSetEnabled(BOOL on) {
    SGSetEnabled(SGKeyICYRadio, on);
    if (on) [radioServer() start];
    else [radioServer() stop];
}

void SGICYRadioRuntimeStart(void) {
    if (SGICYRadioEnabled()) [radioServer() start];
}

__attribute__((constructor)) static void SGICYRadioInstall(void) {
    SGICYRadioRuntimeStart();
}

#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MediaPlayer/MediaPlayer.h>
#import <string.h>
#import <math.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "MatrixDisplay.h"

static CBUUID *SGMatrixServiceUUID(void) {
    return [CBUUID UUIDWithString:@"000000FA-0000-1000-8000-00805F9B34FB"];
}
static CBUUID *SGMatrixWriteUUID(void) {
    return [CBUUID UUIDWithString:@"0000FA02-0000-1000-8000-00805F9B34FB"];
}

@interface SGMatrixBluetooth : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@end

@implementation SGMatrixBluetooth {
    CBCentralManager *_central;
    NSMutableDictionary<NSUUID *, CBPeripheral *> *_found;
    CBPeripheral *_peripheral;
    CBCharacteristic *_characteristic;
    NSData *_sendData;
    NSString *_pendingTrack;
    void (^_scanDone)(NSArray<NSDictionary *> *);
    dispatch_source_t _scanTimer;
}

+ (instancetype)shared {
    static SGMatrixBluetooth *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [SGMatrixBluetooth new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _found = [NSMutableDictionary dictionary];
    _central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    return self;
}

- (void)scanWithCompletion:(void (^)(NSArray<NSDictionary *> *))done {
    _scanDone = [done copy];
    [_found removeAllObjects];
    if (_central.state == CBManagerStatePoweredOn) {
        [self startScan];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ if (_scanDone) {
            void (^call)(NSArray<NSDictionary *> *) = _scanDone; _scanDone = nil; call(@[]);
        }});
    }
}

- (void)startScan {
    [_central stopScan];
    [_central scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    __weak typeof(self) weakSelf = self;
    _scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_scanTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
    dispatch_source_set_event_handler(_scanTimer, ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        [self->_central stopScan];
        NSMutableArray *result = [NSMutableArray array];
        NSArray *peripherals = self->_found.allValues;
        for (CBPeripheral *peripheral in peripherals) {
            NSString *name = peripheral.name ?: @"Bluetooth display";
            NSString *normalized = name.lowercaseString;
            BOOL likely = [normalized containsString:@"idotmatrix"] || [normalized containsString:@"idot"] ||
                          [normalized hasPrefix:@"idm"] || [normalized hasPrefix:@"ipixel"];
            NSArray *services = peripheral.services;
            for (CBService *service in services ?: @[]) if ([service.UUID isEqual:SGMatrixServiceUUID()]) likely = YES;
            if (likely) [result addObject:@{ @"id": peripheral.identifier.UUIDString, @"name": name }];
        }
        void (^done)(NSArray<NSDictionary *> *) = self->_scanDone;
        self->_scanDone = nil;
        if (done) done([result copy]);
        dispatch_source_cancel(self->_scanTimer);
        self->_scanTimer = nil;
    });
    dispatch_resume(_scanTimer);
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBManagerStatePoweredOn && _scanDone) [self startScan];
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI {
    NSString *name = advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name ?: @"";
    NSString *normalized = name.lowercaseString;
    NSArray *services = advertisementData[CBAdvertisementDataServiceUUIDsKey] ?: @[];
    BOOL likely = [normalized containsString:@"idotmatrix"] || [normalized containsString:@"idot"] ||
                  [normalized hasPrefix:@"idm"] || [normalized hasPrefix:@"ipixel"];
    for (CBUUID *uuid in services) if ([uuid isEqual:SGMatrixServiceUUID()]) likely = YES;
    if (likely) _found[peripheral.identifier] = peripheral;
}

- (void)sendImageData:(NSData *)rgb track:(NSString *)track {
    if (!rgb.length || rgb.length != 32 * 32 * 3) return;
    NSString *identifier = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyMatrixDisplayID];
    if (!identifier.length) return;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid) return;
    _pendingTrack = [track copy];

    CBPeripheral *peripheral = _found[uuid] ?: [_central retrievePeripheralsWithIdentifiers:@[uuid]].firstObject;
    if (!peripheral) { SGLog(@"matrix: selected peripheral not available"); return; }

    _peripheral = peripheral;
    _peripheral.delegate = self;
    if (_peripheral.state == CBPeripheralStateConnected) {
        [_peripheral discoverServices:@[SGMatrixServiceUUID()]];
    } else {
        [_central connectPeripheral:_peripheral options:nil];
    }
    _sendData = [self packetize:rgb];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    [peripheral discoverServices:@[SGMatrixServiceUUID()]];
}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral == _peripheral) { _characteristic = nil; SGLog(@"matrix: display disconnected %@", error); }
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    SGLog(@"matrix: display connection failed %@", error);
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) return;
    CBService *service = nil;
    for (CBService *candidate in peripheral.services) if ([candidate.UUID isEqual:SGMatrixServiceUUID()]) { service = candidate; break; }
    if (service) [peripheral discoverCharacteristics:@[SGMatrixWriteUUID()] forService:service];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) return;
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:SGMatrixWriteUUID()]) {
            _characteristic = characteristic;
            [self writeInitializationAndFrame];
            break;
        }
    }
}

- (void)writeInitializationAndFrame {
    if (!_characteristic || !_sendData) return;
    NSData *init = [NSData dataWithBytes:(uint8_t[]){0x05,0x00,0x04,0x01,0x01} length:5];
    CBPeripheral *peripheral = _peripheral;
    if (_characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)
        [peripheral writeValue:init forCharacteristic:_characteristic type:CBCharacteristicWriteWithoutResponse];
    else [peripheral writeValue:init forCharacteristic:_characteristic type:CBCharacteristicWriteWithResponse];

    NSData *packet = _sendData;
    NSUInteger max = MAX(20, [peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse]);
    __weak typeof(self) weakSelf = self;
    NSUInteger offset = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        self->_sendData = nil;
        [self writePacket:packet fromOffset:offset maximum:max];
    });
}

- (void)writePacket:(NSData *)packet fromOffset:(NSUInteger)offset maximum:(NSUInteger)maximum {
    if (offset >= packet.length || !_characteristic) return;
    NSUInteger length = MIN(maximum, packet.length - offset);
    NSData *chunk = [packet subdataWithRange:NSMakeRange(offset, length)];
    CBCharacteristicWriteType type = (_characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)
        ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
    [_peripheral writeValue:chunk forCharacteristic:_characteristic type:type];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.025 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf writePacket:packet fromOffset:offset + length maximum:maximum];
    });
}

- (NSData *)packetize:(NSData *)rgb {
    NSMutableData *packet = [NSMutableData data];
    const uint32_t total = (uint32_t)rgb.length;
    for (NSUInteger offset = 0; offset < rgb.length; offset += 4096) {
        NSData *chunk = [rgb subdataWithRange:NSMakeRange(offset, MIN(4096, rgb.length - offset))];
        uint16_t length = (uint16_t)(chunk.length + 9);
        uint8_t low = length & 0xff, high = (length >> 8) & 0xff;
        uint8_t head[9] = {low, high, 0x00, 0x00, offset == 0 ? 0x00 : 0x02,
                           (uint8_t)(total), (uint8_t)(total >> 8), (uint8_t)(total >> 16), (uint8_t)(total >> 24)};
        [packet appendBytes:head length:9];
        [packet appendData:chunk];
    }
    return packet;
}

@end

static UIImage *MatrixStillArtwork(void);
static NSString *MatrixCoverURL(NSDictionary *metadata);
static NSData *MatrixRGBFrame(UIImage *image);

static SGMatrixBluetooth *MatrixBluetooth(void) { return SGMatrixBluetooth.shared; }

NSString *SGMatrixSelectedDisplayName(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:SGKeyMatrixDisplayName];
}
void SGMatrixSelectDisplay(NSUUID *identifier, NSString *name) {
    if (!identifier) return;
    [NSUserDefaults.standardUserDefaults setObject:identifier.UUIDString forKey:SGKeyMatrixDisplayID];
    [NSUserDefaults.standardUserDefaults setObject:name ?: @"" forKey:SGKeyMatrixDisplayName];
}
void SGMatrixScanDisplays(void (^done)(NSArray<NSDictionary *> *displays)) {
    [MatrixBluetooth() scanWithCompletion:done];
}

static UIImage *MatrixStillArtwork(void) {
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    MPMediaItemArtwork *artwork = [info[MPMediaItemPropertyArtwork] isKindOfClass:MPMediaItemArtwork.class]
        ? info[MPMediaItemPropertyArtwork] : nil;
    return artwork ? [artwork imageWithSize:CGSizeMake(512, 512)] : nil;
}
static NSString *MatrixCoverURL(NSDictionary *metadata) {
    for (NSString *key in @[@"image_xlarge_url", @"image_large_url", @"image_url"]) {
        NSString *raw = [metadata[key] isKindOfClass:NSString.class] ? metadata[key] : nil;
        if (!raw.length) continue;
        if ([raw hasPrefix:@"spotify:image:"]) raw = [@"https://i.scdn.co/image/" stringByAppendingString:[raw substringFromIndex:14]];
        NSURL *url = [NSURL URLWithString:raw];
        if (url.host && [url.scheme isEqual:@"https"] && url.port == nil) return url.absoluteString;
    }
    return nil;
}
static double MatrixSavedDouble(NSString *key, double fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    if (!value) return fallback;
    double saved = [(NSNumber *)value doubleValue];
    return isfinite(saved) ? saved : fallback;
}
static NSInteger MatrixSavedOrientation(void) {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:SGKeyMatrixOrientation];
    return value == 90 || value == 180 || value == 270 ? value : 0;
}
static uint8_t MatrixAdjustedContrast(double component, double amount) {
    double adjusted = fmin(255.0, fmax(0.0, (component * 255.0 - 127.5) * amount + 127.5));
    return (uint8_t)lround(adjusted);
}
static void MatrixAdjustedColor(uint8_t red, uint8_t green, uint8_t blue, double saturation, double contrast, uint8_t *out) {
    double r = red / 255.0, g = green / 255.0, b = blue / 255.0;
    double maximum = fmax(r, fmax(g, b));
    double minimum = fmin(r, fmin(g, b));
    double delta = maximum - minimum;
    if (delta <= 0) {
        out[0] = MatrixAdjustedContrast(r, contrast);
        out[1] = MatrixAdjustedContrast(g, contrast);
        out[2] = MatrixAdjustedContrast(b, contrast);
        return;
    }
    double hue;
    if (maximum == r) hue = fmod((g - b) / delta, 6.0);
    else if (maximum == g) hue = (b - r) / delta + 2.0;
    else hue = (r - g) / delta + 4.0;
    hue /= 6.0;
    if (hue < 0) hue += 1.0;
    double boostedSaturation = fmin(1.0, fmax(0.0, (delta / maximum) * saturation));
    double chroma = maximum * boostedSaturation;
    double remainder = fmod(hue * 6.0, 2.0);
    double intermediate = chroma * (1.0 - fabs(remainder - 1.0));
    double match = maximum - chroma;
    int sector = (int)(hue * 6.0);
    double components[3];
    switch (sector) {
        case 0: components[0] = chroma; components[1] = intermediate; components[2] = 0; break;
        case 1: components[0] = intermediate; components[1] = chroma; components[2] = 0; break;
        case 2: components[0] = 0; components[1] = chroma; components[2] = intermediate; break;
        case 3: components[0] = 0; components[1] = intermediate; components[2] = chroma; break;
        case 4: components[0] = intermediate; components[1] = 0; components[2] = chroma; break;
        default: components[0] = chroma; components[1] = 0; components[2] = intermediate; break;
    }
    out[0] = MatrixAdjustedContrast(components[0] + match, contrast);
    out[1] = MatrixAdjustedContrast(components[1] + match, contrast);
    out[2] = MatrixAdjustedContrast(components[2] + match, contrast);
}
static CGRect MatrixSourceDrawRect(CGRect logical, NSInteger orientation) {
    if (orientation == 90) return CGRectMake(logical.origin.y, 32.0 - logical.origin.x - logical.size.width, logical.size.height, logical.size.width);
    if (orientation == 180) return CGRectMake(32.0 - logical.origin.x - logical.size.width, 32.0 - logical.origin.y - logical.size.height, logical.size.width, logical.size.height);
    if (orientation == 270) return CGRectMake(32.0 - logical.origin.y - logical.size.height, logical.origin.x, logical.size.height, logical.size.width);
    return logical;
}
static NSData *MatrixRGBFrame(UIImage *image) {
    if (!image.CGImage) return nil;
    NSInteger orientation = MatrixSavedOrientation();
    BOOL quarterTurn = orientation == 90 || orientation == 270;
    CGFloat sourceWidth = image.size.width, sourceHeight = image.size.height;
    if (sourceWidth < 1 || sourceHeight < 1) return nil;
    CGFloat orientedWidth = quarterTurn ? sourceHeight : sourceWidth;
    CGFloat orientedHeight = quarterTurn ? sourceWidth : sourceHeight;
    CGFloat scale = MAX(32.0 / orientedWidth, 32.0 / orientedHeight);
    CGRect logical = CGRectMake((32.0 - orientedWidth * scale) / 2.0, (32.0 - orientedHeight * scale) / 2.0,
                                orientedWidth * scale, orientedHeight * scale);
    CGRect drawn = MatrixSourceDrawRect(logical, orientation);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1; format.opaque = YES;
    UIImage *rendered = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(32, 32) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        CGContextSetFillColorWithColor(ctx, UIColor.blackColor.CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, 32, 32));
        CGContextSaveGState(ctx);
        if (orientation == 90) { CGContextTranslateCTM(ctx, 32, 0); CGContextRotateCTM(ctx, M_PI_2); }
        else if (orientation == 180) { CGContextTranslateCTM(ctx, 32, 32); CGContextRotateCTM(ctx, M_PI); }
        else if (orientation == 270) { CGContextTranslateCTM(ctx, 0, 32); CGContextRotateCTM(ctx, -M_PI_2); }
        [image drawInRect:drawn];
        CGContextRestoreGState(ctx);
    }];

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    UInt8 pixels[32 * 32 * 4]; memset(pixels, 0, sizeof(pixels));
    CGContextRef ctx = CGBitmapContextCreate(pixels, 32, 32, 8, 32*4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) { CGColorSpaceRelease(space); return nil; }
    CGContextTranslateCTM(ctx, 0, 32); CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 32, 32), rendered.CGImage);
    CGContextRelease(ctx); CGColorSpaceRelease(space);

    double saturation = MatrixSavedDouble(SGKeyMatrixSaturation, 1.0);
    double contrast = MatrixSavedDouble(SGKeyMatrixContrast, 1.0);
    double sharpness = MatrixSavedDouble(SGKeyMatrixSharpness, 0.0);
    BOOL mirrored = [NSUserDefaults.standardUserDefaults boolForKey:SGKeyMatrixMirrored];
    uint8_t adjusted[32 * 32 * 3];
    for (NSUInteger y = 0; y < 32; y++) for (NSUInteger x = 0; x < 32; x++) {
        NSUInteger sourceX = mirrored ? 31 - x : x;
        NSUInteger offset = (y * 32 + sourceX) * 4;
        MatrixAdjustedColor(pixels[offset], pixels[offset + 1], pixels[offset + 2], saturation, contrast, adjusted + (y * 32 + x) * 3);
    }
    if (sharpness != 0) {
        uint8_t sharpened[32 * 32 * 3]; memcpy(sharpened, adjusted, sizeof(sharpened));
        for (NSUInteger y = 0; y < 32; y++) for (NSUInteger x = 0; x < 32; x++) for (NSUInteger channel = 0; channel < 3; channel++) {
            NSUInteger yStart = y > 0 ? y - 1 : 0, yEnd = y < 31 ? y + 1 : 31;
            NSUInteger xStart = x > 0 ? x - 1 : 0, xEnd = x < 31 ? x + 1 : 31;
            NSInteger total = 0; NSUInteger count = 0;
            for (NSUInteger ny = yStart; ny <= yEnd; ny++) for (NSUInteger nx = xStart; nx <= xEnd; nx++) {
                if (nx == x && ny == y) continue;
                total += adjusted[(ny * 32 + nx) * 3 + channel]; count++;
            }
            double original = adjusted[(y * 32 + x) * 3 + channel];
            double average = count ? (double)total / count : original;
            double value = original + sharpness * (original - average);
            sharpened[(y * 32 + x) * 3 + channel] = (uint8_t)fmin(255.0, fmax(0.0, lround(value)));
        }
        memcpy(adjusted, sharpened, sizeof(adjusted));
    }
    return [NSData dataWithBytes:adjusted length:sizeof(adjusted)];
}

static NSString *sg_lastMatrixTrack;
static void MatrixBroadcastTrack(SPTPlayerTrack *track, BOOL force) {
    if (!force && ![NSUserDefaults.standardUserDefaults boolForKey:SGKeyMatrixEnabled]) return;
    NSString *uri = SGURIString(track.URI);
    if (!uri.length || [uri isEqualToString:sg_lastMatrixTrack]) return;
    sg_lastMatrixTrack = uri;
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    NSString *urlString = MatrixCoverURL(metadata);
    if (!urlString.length) {
        UIImage *still = MatrixStillArtwork();
        NSData *rgb = MatrixRGBFrame(still);
        if (rgb) [MatrixBluetooth() sendImageData:rgb track:uri];
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length ? [UIImage imageWithData:data] : MatrixStillArtwork();
        NSData *rgb = MatrixRGBFrame(image);
        dispatch_async(dispatch_get_main_queue(), ^{ if ([sg_lastMatrixTrack isEqualToString:uri] && rgb) [MatrixBluetooth() sendImageData:rgb track:uri]; });
    }];
    [task resume];
}

@interface SGMatrixObserver : NSObject <SGPlayerStateObserver>
@end
@implementation SGMatrixObserver
- (void)playerStateDidChange:(SPTPlayerState *)state { if (state.track) MatrixBroadcastTrack(state.track, NO); }
@end
static SGMatrixObserver *sg_matrixObserver;

void SGMatrixSendCurrentTrack(void) {
    sg_lastMatrixTrack = nil;
    SPTPlayerState *state = SGPlayerState();
    if (state.track) MatrixBroadcastTrack(state.track, YES);
}

static __attribute__((constructor)) void SGMatrixConstruct(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_matrixObserver = [SGMatrixObserver new];
        SGAddPlayerStateObserver(sg_matrixObserver);
        [MatrixBluetooth() class];
        SPTPlayerState *state = SGPlayerState(); if (state.track) MatrixBroadcastTrack(state.track, NO);
    });
}

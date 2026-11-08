#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MediaPlayer/MediaPlayer.h>
#import <string.h>
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
static NSData *MatrixRGBFrame(UIImage *image) {
    if (!image.CGImage) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1; format.opaque = YES;
    __block UIImage *rendered = nil;
    rendered = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(32, 32) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat iw = image.size.width, ih = image.size.height;
        if (iw < 1 || ih < 1) return;
        CGFloat scale = MAX(32.0 / iw, 32.0 / ih);
        CGRect drawn = CGRectMake((32.0 - iw * scale) / 2.0, (32.0 - ih * scale) / 2.0, iw * scale, ih * scale);
        [image drawInRect:drawn];
    }];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    UInt8 pixels[32 * 32 * 4]; memset(pixels, 0, sizeof(pixels));
    CGContextRef ctx = CGBitmapContextCreate(pixels, 32, 32, 8, 32*4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) { CGColorSpaceRelease(space); return nil; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, 32, 32), rendered.CGImage);
    CGContextRelease(ctx); CGColorSpaceRelease(space);
    NSMutableData *rgb = [NSMutableData dataWithCapacity:32*32*3];
    for (NSUInteger i = 0; i < 32*32; i++) { uint8_t value[3] = {pixels[i*4], pixels[i*4+1], pixels[i*4+2]}; [rgb appendBytes:value length:3]; }
    return rgb;
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
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length ? [UIImage imageWithData:data] : MatrixStillArtwork();
        NSData *rgb = MatrixRGBFrame(image);
        dispatch_async(dispatch_get_main_queue(), ^{ if ([sg_lastMatrixTrack isEqualToString:uri] && rgb) [MatrixBluetooth() sendImageData:rgb track:uri]; });
    }] resume;
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

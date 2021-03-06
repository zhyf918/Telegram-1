#import "TGChatListAvatarSignal.h"

#import "TGColor.h"
#import "TGRoundImage.h"

#import <libkern/OSAtomic.h>
#import <CommonCrypto/CommonDigest.h>

static OSSpinLock imageDataLock;

@implementation TGChatListAvatarSignal

+ (SSignal *)remoteChatListAvatarWithContext:(TGShareContext *)context location:(TGFileLocation *)location imageSize:(CGSize)imageSize
{
    NSString *key = [NSString stringWithFormat:@"%@-%d", [location description], (int)imageSize.width];
    Api86_InputFileLocation_inputFileLocation *inputFileLocation = [Api86_InputFileLocation inputFileLocationWithVolumeId:@(location.volumeId) localId:@(location.localId) secret:@(location.secret) fileReference:location.fileReference];
    return [[context datacenter:location.datacenterId function:[Api86 upload_getFileWithLocation:inputFileLocation offset:@(0) limit:@(1024 * 1024)]] map:^id(Api86_upload_File *result)
    {
        if ([result isKindOfClass:[Api86_upload_File_upload_file class]]) {
            [context.persistentCache setValue:((Api86_upload_File_upload_file *)result).bytes forKey:[[location description] dataUsingEncoding:NSUTF8StringEncoding]];
            
            OSSpinLockLock(&imageDataLock);
            UIImage *image = [[UIImage alloc] initWithData:((Api86_upload_File_upload_file *)result).bytes];
            OSSpinLockUnlock(&imageDataLock);
            
            image = TGRoundImage(image, imageSize);
            [context.memoryImageCache setImage:image forKey:key attributes:nil];
            return image;
        } else {
            return nil;
        }
    }];
}

+ (SSignal *)chatListAvatarWithContext:(TGShareContext *)context location:(TGFileLocation *)location imageSize:(CGSize)imageSize
{
    NSString *key = [NSString stringWithFormat:@"%@-%d", [location description], (int)imageSize.width];
    UIImage *image = [context.memoryImageCache imageForKey:key attributes:NULL];
    if (image != nil)
        return [SSignal single:image];
    
    SSignal *loadFromCacheSignal = [[[SSignal alloc] initWithGenerator:^id<SDisposable>(SSubscriber *subscriber)
    {
        NSData *data = [context.persistentCache getValueForKey:[location.description dataUsingEncoding:NSUTF8StringEncoding]];
        if (data == nil)
            [subscriber putError:nil];
        else
        {
            OSSpinLockLock(&imageDataLock);
            UIImage *image = [[UIImage alloc] initWithData:data];
            OSSpinLockUnlock(&imageDataLock);
            
            image = TGRoundImage(image, imageSize);
            [context.memoryImageCache setImage:image forKey:key attributes:nil];
            [subscriber putNext:image];
            [subscriber putCompletion];
        }
        return nil;
    }] startOnThreadPool:[context sharedThreadPool]];
    
    return [loadFromCacheSignal catch:^SSignal *(__unused id error)
    {
        return [self remoteChatListAvatarWithContext:context location:location imageSize:imageSize];
    }];
}

#define TGColorWithHex(x) [UIColor hexColor:x]

+ (NSArray *)gradientColorsForPeerId:(TGPeerId)peerId myUserId:(int32_t)myUserId
{
    static OSSpinLock lock = 0;
    static NSMutableDictionary *dict = nil;
    static NSArray *colors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        dict = [[NSMutableDictionary alloc] init];
        colors = @[
            @[TGColorWithHex(0xff516a), TGColorWithHex(0xff885e)],
            @[TGColorWithHex(0xffa85c), TGColorWithHex(0xffcd6a)],
            @[TGColorWithHex(0x665fff), TGColorWithHex(0x82b1ff)],
            @[TGColorWithHex(0x54cb68), TGColorWithHex(0xa0de7e)],
            @[TGColorWithHex(0x28c9b7), TGColorWithHex(0x53edd6)],
            @[TGColorWithHex(0x2a9ef1), TGColorWithHex(0x72d5fd)],
            @[TGColorWithHex(0xd669ed), TGColorWithHex(0xe0a2f3)],
        ];
    });
    
    OSSpinLockLock(&lock);
    NSNumber *key = [NSNumber numberWithLongLong:(((long long)peerId.namespaceId) << 32) | ((long long)peerId.peerId)];
    NSNumber *index = dict[key];
    if (index == nil)
    {
        index = @(labs(peerId.peerId) % 7);
        dict[key] = index;
    }
    OSSpinLockUnlock(&lock);
    
    return colors[[index intValue] % 6];
}

+ (SSignal *)chatListAvatarWithContext:(TGShareContext *)context letters:(NSString *)letters peerId:(TGPeerId)peerId imageSize:(CGSize)imageSize
{
    NSString *key = [[NSString alloc] initWithFormat:@"GradientAvatar-%d.%d-%@-%d", (int)peerId.namespaceId, (int)peerId.peerId, letters, (int)imageSize.width];
    UIImage *image = [context.memoryImageCache imageForKey:key attributes:NULL];
    if (image != nil)
        return [SSignal single:image];
    
    return [[[SSignal alloc] initWithGenerator:^id<SDisposable>(SSubscriber *subscriber)
    {
        UIGraphicsBeginImageContextWithOptions(imageSize, false, 0.0f);
        CGContextRef contextRef = UIGraphicsGetCurrentContext();
        
        CGContextBeginPath(contextRef);
        CGContextAddEllipseInRect(contextRef, CGRectMake(0.0f, 0.0f, imageSize.width, imageSize.height));
        CGContextClip(contextRef);
        
        NSArray *gradientColors = peerId.peerId == 0 ? @[TGColorWithHex(0xb1b1b1), TGColorWithHex(0xcdcdcd)] : [self gradientColorsForPeerId:peerId myUserId:context.clientUserId];
        CGColorRef colors[2] = {
            CGColorRetain(((UIColor *)gradientColors[1]).CGColor),
            CGColorRetain(((UIColor *)gradientColors[0]).CGColor)
        };
        
        CFArrayRef colorsArray = CFArrayCreate(kCFAllocatorDefault, (const void **)&colors, 2, NULL);
        CGFloat locations[2] = {0.0f, 1.0f};
        
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, colorsArray, (CGFloat const *)&locations);
        
        CFRelease(colorsArray);
        CFRelease(colors[0]);
        CFRelease(colors[1]);
        
        CGColorSpaceRelease(colorSpace);
        
        CGContextDrawLinearGradient(contextRef, gradient, CGPointMake(0.0f, 0.0f), CGPointMake(0.0f, imageSize.height), 0);
        
        CFRelease(gradient);
        
        CGFloat fontSize = 18.0f;
        if (imageSize.width > 56.0f)
            fontSize = 28.0f;
        else if (imageSize.width > 40.0f)
            fontSize = 24.0f;
        
        UIFont *font = [UIFont fontWithName:@".SFCompactRounded-Semibold" size:fontSize];
        
        CGSize lettersSize = [letters sizeWithAttributes:@{NSFontAttributeName: font}];
        [letters drawAtPoint:CGPointMake((CGFloat)(floor(imageSize.width - lettersSize.width) / 2.0f), (CGFloat)(floor(imageSize.height - lettersSize.height) / 2.0f)) withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]}];
        
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        [context.memoryImageCache setImage:image forKey:key attributes:nil];
        
        [subscriber putNext:image];
        [subscriber putCompletion];
        
        return nil;
    }] startOnThreadPool:context.sharedThreadPool];
}

+ (SSignal *)chatListAvatarForSavedMessagesWithContext:(TGShareContext *)context imageSize:(CGSize)imageSize
{
    NSString *key = [[NSString alloc] initWithFormat:@"SavedMessages-%d", (int)imageSize.width];
    UIImage *image = [context.memoryImageCache imageForKey:key attributes:NULL];
    if (image != nil)
        return [SSignal single:image];
    
    return [[[SSignal alloc] initWithGenerator:^id<SDisposable>(SSubscriber *subscriber)
    {
        UIGraphicsBeginImageContextWithOptions(imageSize, false, 0.0f);
        CGContextRef contextRef = UIGraphicsGetCurrentContext();
        
        CGContextBeginPath(contextRef);
        CGContextAddEllipseInRect(contextRef, CGRectMake(0.0f, 0.0f, imageSize.width, imageSize.height));
        CGContextClip(contextRef);
        
        NSArray *gradientColors = @[TGColorWithHex(0x2a9ef1), TGColorWithHex(0x72d5fd)];
        CGColorRef colors[2] = {
            CGColorRetain(((UIColor *)gradientColors[0]).CGColor),
            CGColorRetain(((UIColor *)gradientColors[1]).CGColor)
        };
        
        CFArrayRef colorsArray = CFArrayCreate(kCFAllocatorDefault, (const void **)&colors, 2, NULL);
        CGFloat locations[2] = {0.0f, 1.0f};
        
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, colorsArray, (CGFloat const *)&locations);
        
        CFRelease(colorsArray);
        CFRelease(colors[0]);
        CFRelease(colors[1]);
        
        CGColorSpaceRelease(colorSpace);
        
        CGContextDrawLinearGradient(contextRef, gradient, CGPointMake(0.0f, 0.0f), CGPointMake(0.0f, imageSize.height), 0);
        
        CFRelease(gradient);
        
        UIImage *icon = [UIImage imageNamed:@"SavedMessagesIcon"];
        CGSize ratios = CGSizeMake(22.0f / 60.0f, 27.0f / 60.0f);
        CGSize iconSize = CGSizeMake(round(imageSize.width * ratios.width), round(imageSize.height * ratios.height));
        [icon drawInRect:CGRectMake((imageSize.width - iconSize.width) / 2.0f, ceil((imageSize.height - iconSize.height) / 2.0f) + 1.0f, iconSize.width, iconSize.height)];
        
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        [context.memoryImageCache setImage:image forKey:key attributes:nil];
        
        [subscriber putNext:image];
        [subscriber putCompletion];
        
        return nil;
    }] startOnThreadPool:context.sharedThreadPool];
}

@end

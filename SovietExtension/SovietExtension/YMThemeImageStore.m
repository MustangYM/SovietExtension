#import "YMThemeImageStore.h"
#import "MistyModeSettingsWindowController.h"
#import <CommonCrypto/CommonDigest.h>

@implementation YMThemeImageStore

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)galleryEntries {
    static NSArray *entries;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *url = [[NSBundle bundleForClass:self] URLForResource:@"ThemeConfig" withExtension:@"plist"];
        NSDictionary *config = url ? [NSDictionary dictionaryWithContentsOfURL:url] : nil;
        NSMutableArray *valid = [NSMutableArray array];
        for (id item in config[@"data"]) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *address = item[@"pic"];
            NSURL *imageURL = [address isKindOfClass:NSString.class] ? [NSURL URLWithString:address] : nil;
            if (![@[@"https", @"http"] containsObject:imageURL.scheme.lowercaseString]) continue;
            NSString *caption = [item[@"desc"] isKindOfClass:NSString.class] ? item[@"desc"] : @"";
            [valid addObject:@{@"pic": address, @"desc": caption}];
        }
        entries = valid.copy;
    });
    return entries;
}

+ (NSURL *)ym_cacheDirectory {
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [[support URLByAppendingPathComponent:@"SovietExtension" isDirectory:YES]
                         URLByAppendingPathComponent:@"ThemeImages" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

+ (NSURL *)selectedImageURL {
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:kThemeBackgroundImagePath];
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path];
}

+ (NSURL *)ym_cachedURLForRemoteURL:(NSURL *)remoteURL {
    NSData *data = [remoteURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *name = [NSMutableString string];
    for (NSUInteger index = 0; index < sizeof(hash); ++index) [name appendFormat:@"%02x", hash[index]];
    NSString *extension = remoteURL.pathExtension.lowercaseString;
    if (![@[@"jpg", @"jpeg", @"png", @"heic", @"webp"] containsObject:extension]) extension = @"jpg";
    return [[[self ym_cacheDirectory] URLByAppendingPathComponent:name] URLByAppendingPathExtension:extension];
}

+ (NSURL *)saveLocalImageAtURL:(NSURL *)source error:(NSError **)error {
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:source];
    if (!image || image.size.width < 1 || image.size.height < 1) {
        if (error) *error = [NSError errorWithDomain:@"YMThemeImageStore" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"无法读取所选图片"}];
        return nil;
    }
    NSString *extension = source.pathExtension.lowercaseString;
    if (!extension.length) extension = @"png";
    NSURL *destination = [[[self ym_cacheDirectory] URLByAppendingPathComponent:NSUUID.UUID.UUIDString]
                           URLByAppendingPathExtension:extension];
    if (![[NSFileManager defaultManager] copyItemAtURL:source toURL:destination error:error]) return nil;
    return destination;
}

+ (void)fetchGalleryImage:(NSURL *)remoteURL
               completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    NSURL *cached = [self ym_cachedURLForRemoteURL:remoteURL];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cached.path]) {
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:cached];
        if (image && image.size.width > 0 && image.size.height > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
            return;
        }
        [[NSFileManager defaultManager] removeItemAtURL:cached error:nil];
    }
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:remoteURL
        completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *downloadError) {
            NSError *error = downloadError;
            NSURL *result = nil;
            if (!error && [response isKindOfClass:NSHTTPURLResponse.class] &&
                ((NSHTTPURLResponse *)response).statusCode / 100 != 2) {
                error = [NSError errorWithDomain:@"YMThemeImageStore" code:3
                                        userInfo:@{NSLocalizedDescriptionKey: @"图库图片暂不可用"}];
            }
            if (!error && temporary) {
                NSNumber *size = nil;
                [temporary getResourceValue:&size forKey:NSURLFileSizeKey error:&error];
                NSImage *image = !error && size.longLongValue <= 20 * 1024 * 1024
                    ? [[NSImage alloc] initWithContentsOfURL:temporary] : nil;
                if (!image || image.size.width < 1 || image.size.height < 1) {
                    error = [NSError errorWithDomain:@"YMThemeImageStore" code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"图库图片无法加载"}];
                } else if ([[NSFileManager defaultManager] copyItemAtURL:temporary toURL:cached error:&error] ||
                           [[NSFileManager defaultManager] fileExistsAtPath:cached.path]) {
                    result = cached;
                    error = nil;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
        }];
    [task resume];
}

@end

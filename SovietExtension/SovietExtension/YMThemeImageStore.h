#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface YMThemeImageStore : NSObject

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)galleryEntries;
+ (nullable NSURL *)selectedImageURL;
+ (nullable NSURL *)saveLocalImageAtURL:(NSURL *)source error:(NSError **)error;
+ (void)fetchGalleryImage:(NSURL *)remoteURL
               completion:(void (^)(NSURL * _Nullable localURL, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

// Public Obj-C surface for the LiteRT-LM bridge. The Swift app target imports this
// via the LiteRtLmBridge module. Wiring to the C API in Vendor/litert_lm/c/engine.h
// happens in Phase A step 2.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const LRTLMErrorDomain;

typedef NS_ENUM(NSInteger, LRTLMErrorCode) {
    LRTLMErrorCodeNotImplemented = -1,
    LRTLMErrorCodeInitFailed     = 1,
    LRTLMErrorCodeInferenceFailed = 2,
    LRTLMErrorCodeCancelled      = 3,
};

typedef NS_ENUM(NSInteger, LRTLMBackend) {
    LRTLMBackendCPU = 0,
    LRTLMBackendGPU = 1,
};

@interface LRTLMSamplerParams : NSObject
@property (nonatomic) int topK;
@property (nonatomic) float topP;
@property (nonatomic) float temperature;
@end

@interface LRTLMConversation : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// Streams tokens via @c onToken until @c onDone fires (with non-nil error on failure).
- (void)sendMessage:(NSString *)text
            onToken:(void (^)(NSString * _Nonnull chunk, NSString * _Nullable thought))onToken
             onDone:(void (^)(NSError * _Nullable error))onDone;
/// Multimodal variant — text + zero or more image file paths. The bridge
/// builds a JSON message of the form
///   {"role":"user","content":[{"type":"image","path":"..."}, ..., {"type":"text","text":"..."}]}
/// Image paths must point at readable PNG/JPEG files on disk; callers
/// typically write a UIImage to NSTemporaryDirectory and pass that path.
- (void)sendMessage:(NSString *)text
         imagePaths:(nullable NSArray<NSString *> *)imagePaths
            onToken:(void (^)(NSString * _Nonnull chunk, NSString * _Nullable thought))onToken
             onDone:(void (^)(NSError * _Nullable error))onDone;

/// Full multimodal variant — text + image paths + audio paths. Audio items
/// follow the same JSON shape as image items:
///   {"type":"audio","path":"/path/to/audio.m4a"}
- (void)sendMessage:(NSString *)text
         imagePaths:(nullable NSArray<NSString *> *)imagePaths
         audioPaths:(nullable NSArray<NSString *> *)audioPaths
            onToken:(void (^)(NSString * _Nonnull chunk, NSString * _Nullable thought))onToken
             onDone:(void (^)(NSError * _Nullable error))onDone;
- (void)cancel;
- (void)close;
@end

@interface LRTLMEngine : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// Loads a .litertlm model from disk. Returns nil on failure with @c outError populated.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                   backend:(LRTLMBackend)backend
                                 maxTokens:(int)maxTokens
                                  cacheDir:(nullable NSString *)cacheDir
                                     error:(NSError **)outError;

- (nullable LRTLMConversation *)createConversationWithSystemPrompt:(nullable NSString *)systemPrompt
                                                             sampler:(LRTLMSamplerParams *)sampler
                                                               error:(NSError **)outError;
- (void)close;
@end

NS_ASSUME_NONNULL_END

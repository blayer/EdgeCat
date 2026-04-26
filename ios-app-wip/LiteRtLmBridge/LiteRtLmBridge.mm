// Phase A step 2: real bridge over the LiteRT-LM C API in Vendor/litert_lm/c/engine.h.
// The static archive libLiteRtLm.a (built from source via Bazel for iOS arm64)
// provides every symbol below.
//
// JSON shape for send_message_stream is taken from runtime/conversation/conversation_test.cc:
//   {"role": "user", "content": "Hello world!"}                  // text-only (Phase A)
//   {"role": "user", "content": [{"type":"text","text":"..."}]}  // multimodal (later phases)

#import "LiteRtLmBridge.h"
#import <Foundation/Foundation.h>
#include "c/engine.h"

NSString * const LRTLMErrorDomain = @"com.mobileclaw.litertlmbridge";

static NSError *MakeError(LRTLMErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:LRTLMErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - JSON message builders

static NSString *BuildMessageJson(NSString *text,
                                  NSArray<NSString *> *imagePaths,
                                  NSArray<NSString *> *audioPaths) {
    // Format mirrors runtime/conversation/model_data_processor/data_utils.h:
    //   text-only:     {"role":"user","content":"hi"}
    //   multimodal:    {"role":"user","content":[
    //                      {"type":"image","path":"..."},
    //                      {"type":"audio","path":"..."},
    //                      {"type":"text","text":"..."}]}
    if (imagePaths.count == 0 && audioPaths.count == 0) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"role": @"user", @"content": text ?: @""}
                                                       options:0 error:nil];
        return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    }
    NSMutableArray<NSDictionary *> *content =
        [NSMutableArray arrayWithCapacity:imagePaths.count + audioPaths.count + 1];
    for (NSString *p in imagePaths) {
        [content addObject:@{@"type": @"image", @"path": p}];
    }
    for (NSString *p in audioPaths) {
        [content addObject:@{@"type": @"audio", @"path": p}];
    }
    if (text.length > 0) {
        [content addObject:@{@"type": @"text", @"text": text}];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"role": @"user", @"content": content}
                                                   options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

#pragma mark - LRTLMSamplerParams

@implementation LRTLMSamplerParams
@end

@interface LRTLMConversation ()
- (instancetype)initWithRaw:(LiteRtLmConversation *)conversation
                   convConfig:(LiteRtLmConversationConfig *)convConfig
                sessionConfig:(LiteRtLmSessionConfig *)sessionConfig;
@end

#pragma mark - Stream context (passed as callback_data)

namespace {
struct StreamContext {
    void (^onToken)(NSString *, NSString * _Nullable);
    void (^onDone)(NSError * _Nullable);
};

// Each chunk from litert_lm_conversation_send_message_stream is a full assistant
// message JSON like: {"role":"assistant","content":[{"type":"text","text":"…"}, …]}
// where each subsequent chunk's text is the NEW token only (not the accumulated
// transcript). We parse the JSON here so Swift sees clean (text, thought) tokens.
static void ExtractTextAndThought(NSString *json, NSString **outText, NSString **outThought) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *dict = [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
    NSArray *content = dict[@"content"];
    if (![content isKindOfClass:[NSArray class]]) {
        *outText = json; *outThought = nil; return;
    }
    NSMutableString *text = [NSMutableString string];
    NSMutableString *thought = [NSMutableString string];
    for (NSDictionary *part in content) {
        if (![part isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = part[@"type"];
        NSString *t = part[@"text"];
        if (![t isKindOfClass:[NSString class]]) continue;
        if ([type isEqualToString:@"thought"]) {
            [thought appendString:t];
        } else {
            [text appendString:t];
        }
    }
    *outText = text;
    *outThought = thought.length ? thought : nil;
}

void StreamCallbackThunk(void *userData, const char *chunk, bool isFinal, const char *errorMsg) {
    auto *ctx = static_cast<StreamContext *>(userData);
    if (!ctx) return;
    if (errorMsg) {
        if (ctx->onDone) {
            ctx->onDone(MakeError(LRTLMErrorCodeInferenceFailed,
                                  [NSString stringWithUTF8String:errorMsg]));
        }
    } else if (chunk && ctx->onToken) {
        NSString *raw = [NSString stringWithUTF8String:chunk];
        NSString *text = nil, *thought = nil;
        ExtractTextAndThought(raw, &text, &thought);
        ctx->onToken(text ?: @"", thought);
    }
    if (isFinal) {
        if (ctx->onDone) ctx->onDone(nil);
        delete ctx;  // single-shot: stream ends after isFinal=true
    }
}
}  // namespace

#pragma mark - LRTLMConversation

@implementation LRTLMConversation {
    LiteRtLmConversation *_conversation;
    LiteRtLmConversationConfig *_convConfig;
    LiteRtLmSessionConfig *_sessionConfig;
}

- (instancetype)initWithRaw:(LiteRtLmConversation *)conversation
                   convConfig:(LiteRtLmConversationConfig *)convConfig
                sessionConfig:(LiteRtLmSessionConfig *)sessionConfig {
    self = [super init];
    if (self) {
        _conversation = conversation;
        _convConfig = convConfig;
        _sessionConfig = sessionConfig;
    }
    return self;
}

- (void)sendMessage:(NSString *)text
            onToken:(void (^)(NSString *, NSString * _Nullable))onToken
             onDone:(void (^)(NSError * _Nullable))onDone {
    [self sendMessage:text imagePaths:nil audioPaths:nil onToken:onToken onDone:onDone];
}

- (void)sendMessage:(NSString *)text
         imagePaths:(NSArray<NSString *> *)imagePaths
            onToken:(void (^)(NSString *, NSString * _Nullable))onToken
             onDone:(void (^)(NSError * _Nullable))onDone {
    [self sendMessage:text imagePaths:imagePaths audioPaths:nil onToken:onToken onDone:onDone];
}

- (void)sendMessage:(NSString *)text
         imagePaths:(NSArray<NSString *> *)imagePaths
         audioPaths:(NSArray<NSString *> *)audioPaths
            onToken:(void (^)(NSString *, NSString * _Nullable))onToken
             onDone:(void (^)(NSError * _Nullable))onDone {
    if (!_conversation) {
        if (onDone) onDone(MakeError(LRTLMErrorCodeInferenceFailed, @"Conversation already closed"));
        return;
    }
    NSString *messageJson = BuildMessageJson(text, imagePaths, audioPaths);
    auto *ctx = new StreamContext{[onToken copy], [onDone copy]};
    int rc = litert_lm_conversation_send_message_stream(
        _conversation,
        messageJson.UTF8String,
        /*extra_context=*/"{}",
        StreamCallbackThunk,
        ctx);
    if (rc != 0) {
        delete ctx;
        if (onDone) {
            onDone(MakeError(LRTLMErrorCodeInferenceFailed,
                             [NSString stringWithFormat:@"send_message_stream failed: %d", rc]));
        }
    }
}

- (void)cancel {
    if (_conversation) litert_lm_conversation_cancel_process(_conversation);
}

- (void)close {
    if (_conversation) {
        litert_lm_conversation_delete(_conversation);
        _conversation = nullptr;
    }
    if (_convConfig) {
        litert_lm_conversation_config_delete(_convConfig);
        _convConfig = nullptr;
    }
    if (_sessionConfig) {
        litert_lm_session_config_delete(_sessionConfig);
        _sessionConfig = nullptr;
    }
}

- (void)dealloc { [self close]; }

@end

#pragma mark - LRTLMEngine

@implementation LRTLMEngine {
    LiteRtLmEngine *_engine;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                   backend:(LRTLMBackend)backend
                                 maxTokens:(int)maxTokens
                                  cacheDir:(nullable NSString *)cacheDir
                                     error:(NSError **)outError {
    self = [super init];
    if (!self) return nil;

    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed,
                                            [NSString stringWithFormat:@"Model file not found at %@", modelPath]);
        return nil;
    }

    const char *backendStr = (backend == LRTLMBackendGPU) ? "gpu" : "cpu";
    LiteRtLmEngineSettings *settings = litert_lm_engine_settings_create(
        modelPath.UTF8String, backendStr, /*vision_backend=*/nullptr, /*audio_backend=*/nullptr);
    if (!settings) {
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"engine_settings_create failed");
        return nil;
    }
    if (maxTokens > 0) {
        litert_lm_engine_settings_set_max_num_tokens(settings, maxTokens);
    }
    if (cacheDir) {
        litert_lm_engine_settings_set_cache_dir(settings, cacheDir.UTF8String);
    }

    _engine = litert_lm_engine_create(settings);
    litert_lm_engine_settings_delete(settings);

    if (!_engine) {
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"engine_create returned NULL");
        return nil;
    }
    return self;
}

- (nullable LRTLMConversation *)createConversationWithSystemPrompt:(nullable NSString *)systemPrompt
                                                             sampler:(LRTLMSamplerParams *)sampler
                                                               error:(NSError **)outError {
    if (!_engine) {
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"Engine already closed");
        return nil;
    }

    LiteRtLmSessionConfig *sessionConfig = litert_lm_session_config_create();
    if (!sessionConfig) {
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"session_config_create failed");
        return nil;
    }
    LiteRtLmSamplerParams params{};
    // The engine impl currently only ships TopP/Greedy samplers (TopK returns
    // "Sampler type 1 not implemented yet"). Match what the Gemma 4 metadata
    // declares: TOP_P with k=1, p=0.95, temperature=1.
    params.type = kLiteRtLmSamplerTypeTopP;
    params.top_k = sampler.topK;
    params.top_p = sampler.topP;
    params.temperature = sampler.temperature;
    params.seed = 0;
    litert_lm_session_config_set_sampler_params(sessionConfig, &params);

    LiteRtLmConversationConfig *convConfig = litert_lm_conversation_config_create();
    if (!convConfig) {
        litert_lm_session_config_delete(sessionConfig);
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"conversation_config_create failed");
        return nil;
    }
    litert_lm_conversation_config_set_session_config(convConfig, sessionConfig);
    if (systemPrompt.length > 0) {
        // System prompt is a JSON-encoded message: {"role":"system","content":"..."}
        NSData *sysData = [NSJSONSerialization dataWithJSONObject:@{@"role": @"system", @"content": systemPrompt}
                                                          options:0
                                                            error:nil];
        if (sysData) {
            NSString *sysJson = [[NSString alloc] initWithData:sysData encoding:NSUTF8StringEncoding];
            litert_lm_conversation_config_set_system_message(convConfig, sysJson.UTF8String);
        }
    }

    LiteRtLmConversation *raw = litert_lm_conversation_create(_engine, convConfig);
    if (!raw) {
        litert_lm_conversation_config_delete(convConfig);
        litert_lm_session_config_delete(sessionConfig);
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"conversation_create returned NULL");
        return nil;
    }
    return [[LRTLMConversation alloc] initWithRaw:raw convConfig:convConfig sessionConfig:sessionConfig];
}

- (void)close {
    if (_engine) {
        litert_lm_engine_delete(_engine);
        _engine = nullptr;
    }
}

- (void)dealloc { [self close]; }

@end

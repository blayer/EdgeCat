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

NSString * const LRTLMErrorDomain = @"com.mobileclawapp.litertlmbridge";

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
- (instancetype)init {
    if ((self = [super init])) {
        // Match Gemma 4 metadata defaults — TopP nucleus sampling.
        _type = LRTLMSamplerTypeTopP;
        _topK = 40;
        _topP = 0.95f;
        _temperature = 1.0f;
        _seed = 0;
    }
    return self;
}
@end

#pragma mark - LRTLMEngineSettings

@implementation LRTLMEngineSettings
- (instancetype)initWithModelPath:(NSString *)modelPath {
    if ((self = [super init])) {
        _modelPath = [modelPath copy];
        // Match Android's DEFAULT_ACCELERATORS = listOf(GPU). The actual
        // backend string is resolved by the LRTLMEngine initializer.
        _backend = LRTLMBackendGPU;
        _visionBackend = LRTLMBackendDefault;
        _audioBackend  = LRTLMBackendDefault;
        _maxTokens = 0;
        _cacheDir = nil;
        _parallelFileSectionLoading = YES;
        _activationDataType = LRTLMActivationDtypeDefault;
        _prefillChunkSize = 0;
        _enableSpeculativeDecoding = NO;
        _logLevel = LRTLMLogLevelSilent;
    }
    return self;
}
@end

@class LRTLMEngine;

@interface LRTLMConversation ()
- (instancetype)initWithRaw:(LiteRtLmConversation *)conversation
                   convConfig:(LiteRtLmConversationConfig *)convConfig
                sessionConfig:(LiteRtLmSessionConfig *)sessionConfig
                       owner:(LRTLMEngine *)owner;
@end

#pragma mark - Stream context (passed as callback_data)

namespace {
struct StreamContext {
    void (^onToken)(NSString *, NSString * _Nullable);
    void (^onDone)(NSError * _Nullable);
    // Signaled from the final callback. close() waits on this so the C++
    // streaming thread is guaranteed to be done with our pointers before
    // litert_lm_conversation_delete() runs. Without this, navigating away
    // mid-stream produced a use-after-free in the engine teardown path.
    dispatch_semaphore_t doneSem;
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
        // Signal close()-waiters BEFORE delete: the semaphore is owned by ctx,
        // so signaling first guarantees no race against close() observing the
        // signal and then close() racing the delete.
        if (ctx->doneSem) dispatch_semaphore_signal(ctx->doneSem);
        delete ctx;  // single-shot: stream ends after isFinal=true
    }
}
}  // namespace

#pragma mark - LRTLMConversation

@implementation LRTLMConversation {
    LiteRtLmConversation *_conversation;
    LiteRtLmConversationConfig *_convConfig;
    LiteRtLmSessionConfig *_sessionConfig;
    // Strong ref to the parent engine. Conversations call into the engine via
    // litert_lm_conversation_*; the engine must outlive every conversation,
    // otherwise the C++ runtime UAFs when the engine is deleted before the
    // conversation finishes its delete path.
    LRTLMEngine *_owner;
    // Signaled from the stream's final callback. close() blocks on this so
    // we don't delete the C-side conversation while a stream is still in
    // flight from a background thread.
    dispatch_semaphore_t _streamDone;
    BOOL _streamInFlight;
}

- (instancetype)initWithRaw:(LiteRtLmConversation *)conversation
                   convConfig:(LiteRtLmConversationConfig *)convConfig
                sessionConfig:(LiteRtLmSessionConfig *)sessionConfig
                       owner:(LRTLMEngine *)owner {
    self = [super init];
    if (self) {
        _conversation = conversation;
        _convConfig = convConfig;
        _sessionConfig = sessionConfig;
        _owner = owner;
        _streamDone = dispatch_semaphore_create(0);
        _streamInFlight = NO;
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
    void (^doneWrapper)(NSError * _Nullable) = ^(NSError *err) {
        // Reset the in-flight flag on the conversation when the C-side stream
        // finishes (success or error). The semaphore is always signaled by
        // the thunk after this callback returns.
        self->_streamInFlight = NO;
        if (onDone) onDone(err);
    };
    auto *ctx = new StreamContext{[onToken copy], [doneWrapper copy], _streamDone};
    _streamInFlight = YES;
    int rc = litert_lm_conversation_send_message_stream(
        _conversation,
        messageJson.UTF8String,
        /*extra_context=*/"{}",
        StreamCallbackThunk,
        ctx);
    if (rc != 0) {
        _streamInFlight = NO;
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
        // If a stream is still mid-flight on a background thread, request
        // cancellation and wait for the final callback before deleting the
        // C-side conversation. Otherwise the streaming thread can call into
        // a freed conversation and crash. 3s upper bound — beyond that, the
        // process is likely deadlocked elsewhere; better to risk the UAF
        // than freeze the UI.
        if (_streamInFlight) {
            litert_lm_conversation_cancel_process(_conversation);
            dispatch_semaphore_wait(_streamDone,
                                    dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        }
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
    // Drop the strong ref to the engine last, so engine_delete only runs
    // after every conversation has been fully torn down.
    _owner = nil;
}

- (void)dealloc { [self close]; }

@end

#pragma mark - LRTLMEngine

@implementation LRTLMEngine {
    LiteRtLmEngine *_engine;
}

// Resolve LRTLMBackend → backend string accepted by the C API. Returns
// nullptr for `Default` so the C side falls back to its own default.
static const char *BackendCString(LRTLMBackend backend) {
    switch (backend) {
        case LRTLMBackendCPU:     return "cpu";
        case LRTLMBackendGPU:     return "gpu";
        case LRTLMBackendDefault: return nullptr;
    }
    return nullptr;
}

- (nullable instancetype)initWithSettings:(LRTLMEngineSettings *)settings
                                    error:(NSError **)outError {
    self = [super init];
    if (!self) return nil;

    if (settings.modelPath.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:settings.modelPath]) {
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed,
                                            [NSString stringWithFormat:@"Model file not found at %@",
                                             settings.modelPath ?: @"(empty path)"]);
        return nil;
    }

    // Apply log level before any C-side work so init-path messages are
    // observable when the user dials the level up.
    litert_lm_set_min_log_level((int)settings.logLevel);

    const char *backendStr       = BackendCString(settings.backend);
    const char *visionBackendStr = BackendCString(settings.visionBackend);
    const char *audioBackendStr  = BackendCString(settings.audioBackend);
    LiteRtLmEngineSettings *cSettings = litert_lm_engine_settings_create(
        settings.modelPath.UTF8String, backendStr, visionBackendStr, audioBackendStr);
    if (!cSettings) {
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"engine_settings_create failed");
        return nil;
    }
    if (settings.maxTokens > 0) {
        litert_lm_engine_settings_set_max_num_tokens(cSettings, settings.maxTokens);
    }
    if (settings.cacheDir.length > 0) {
        litert_lm_engine_settings_set_cache_dir(cSettings, settings.cacheDir.UTF8String);
    }
    // The C default for parallel section loading is true; only call when the
    // user has explicitly opted out, to keep our calls surface tight.
    if (!settings.parallelFileSectionLoading) {
        litert_lm_engine_settings_set_parallel_file_section_loading(cSettings, false);
    }
    if (settings.activationDataType != LRTLMActivationDtypeDefault) {
        litert_lm_engine_settings_set_activation_data_type(cSettings,
                                                           (int)settings.activationDataType);
    }
    if (settings.prefillChunkSize > 0) {
        litert_lm_engine_settings_set_prefill_chunk_size(cSettings, settings.prefillChunkSize);
    }
    if (settings.enableSpeculativeDecoding) {
        litert_lm_engine_settings_set_enable_speculative_decoding(cSettings, true);
    }

    _engine = litert_lm_engine_create(cSettings);
    litert_lm_engine_settings_delete(cSettings);

    if (!_engine) {
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"engine_create returned NULL");
        return nil;
    }
    return self;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                   backend:(LRTLMBackend)backend
                                 maxTokens:(int)maxTokens
                                  cacheDir:(nullable NSString *)cacheDir
                                     error:(NSError **)outError {
    LRTLMEngineSettings *settings = [[LRTLMEngineSettings alloc] initWithModelPath:modelPath];
    settings.backend = backend;
    settings.maxTokens = maxTokens;
    settings.cacheDir = cacheDir;
    return [self initWithSettings:settings error:outError];
}

- (nullable LRTLMConversation *)createConversationWithSystemPrompt:(nullable NSString *)systemPrompt
                                                             sampler:(LRTLMSamplerParams *)sampler
                                                 applyPromptTemplate:(BOOL)applyPromptTemplate
                                          enableConstrainedDecoding:(BOOL)enableConstrainedDecoding
                                                     maxOutputTokens:(int)maxOutputTokens
                                                               error:(NSError **)outError {
    return [self createConversationWithSystemPrompt:systemPrompt
                                    initialMessages:nil
                                            sampler:sampler
                                applyPromptTemplate:applyPromptTemplate
                          enableConstrainedDecoding:enableConstrainedDecoding
                                    maxOutputTokens:maxOutputTokens
                                              error:outError];
}

- (nullable LRTLMConversation *)createConversationWithSystemPrompt:(nullable NSString *)systemPrompt
                                                  initialMessages:(nullable NSString *)initialMessagesJson
                                                             sampler:(LRTLMSamplerParams *)sampler
                                                 applyPromptTemplate:(BOOL)applyPromptTemplate
                                          enableConstrainedDecoding:(BOOL)enableConstrainedDecoding
                                                     maxOutputTokens:(int)maxOutputTokens
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
    // Map LRTLMSamplerType → LiteRtLmSamplerType. TopK returns "not
    // implemented yet" upstream so it's intentionally not exposed.
    switch (sampler.type) {
        case LRTLMSamplerTypeGreedy: params.type = kLiteRtLmSamplerTypeGreedy; break;
        case LRTLMSamplerTypeTopP:
        default:                     params.type = kLiteRtLmSamplerTypeTopP;   break;
    }
    params.top_k = sampler.topK;
    params.top_p = sampler.topP;
    params.temperature = sampler.temperature;
    params.seed = sampler.seed;
    litert_lm_session_config_set_sampler_params(sessionConfig, &params);

    if (maxOutputTokens > 0) {
        litert_lm_session_config_set_max_output_tokens(sessionConfig, maxOutputTokens);
    }
    // Only call when the user has explicitly opted out — the C default is
    // already true for chat-template-aware models.
    if (!applyPromptTemplate) {
        litert_lm_session_config_set_apply_prompt_template(sessionConfig, false);
    }

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
    if (initialMessagesJson.length > 0) {
        // JSON array of {"role":"user|assistant","content":"..."} objects.
        // Used to warm a fresh KV cache with prior chat history after the
        // orchestrator wipes the conversation slot.
        litert_lm_conversation_config_set_messages(convConfig,
                                                    initialMessagesJson.UTF8String);
    }
    if (enableConstrainedDecoding) {
        litert_lm_conversation_config_set_enable_constrained_decoding(convConfig, true);
    }

    LiteRtLmConversation *raw = litert_lm_conversation_create(_engine, convConfig);
    if (!raw) {
        litert_lm_conversation_config_delete(convConfig);
        litert_lm_session_config_delete(sessionConfig);
        if (outError) *outError = MakeError(LRTLMErrorCodeInitFailed, @"conversation_create returned NULL");
        return nil;
    }
    return [[LRTLMConversation alloc] initWithRaw:raw
                                       convConfig:convConfig
                                    sessionConfig:sessionConfig
                                            owner:self];
}

- (nullable LRTLMConversation *)createConversationWithSystemPrompt:(nullable NSString *)systemPrompt
                                                             sampler:(LRTLMSamplerParams *)sampler
                                                               error:(NSError **)outError {
    return [self createConversationWithSystemPrompt:systemPrompt
                                            sampler:sampler
                                applyPromptTemplate:YES
                         enableConstrainedDecoding:NO
                                    maxOutputTokens:0
                                              error:outError];
}

- (void)close {
    if (_engine) {
        litert_lm_engine_delete(_engine);
        _engine = nullptr;
    }
}

- (void)dealloc { [self close]; }

@end

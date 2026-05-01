// Public Obj-C surface for the LiteRT-LM bridge. The Swift app target imports this
// via the LiteRtLmBridge module. Wiring to the C API in Vendor/litert_lm/c/engine.h
// happens in LiteRtLmBridge.mm.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const LRTLMErrorDomain;

typedef NS_ENUM(NSInteger, LRTLMErrorCode) {
    LRTLMErrorCodeNotImplemented = -1,
    LRTLMErrorCodeInitFailed     = 1,
    LRTLMErrorCodeInferenceFailed = 2,
    LRTLMErrorCodeCancelled      = 3,
};

/// Maps to the `backend_str` argument of `litert_lm_engine_settings_create`.
/// `LRTLMBackendDefault` skips passing the parameter — the C side then falls
/// back to the model's preferred backend.
typedef NS_ENUM(NSInteger, LRTLMBackend) {
    LRTLMBackendDefault = -1,
    LRTLMBackendCPU = 0,
    LRTLMBackendGPU = 1,
};

/// Maps to `LiteRtLmSamplerType` in `c/engine.h`. Only TopP and Greedy are
/// implemented in the runtime today (TopK returns "not implemented yet").
typedef NS_ENUM(NSInteger, LRTLMSamplerType) {
    LRTLMSamplerTypeTopP   = 0,
    LRTLMSamplerTypeGreedy = 1,
};

/// Maps to `litert_lm_engine_settings_set_activation_data_type`.
/// `LRTLMActivationDtypeDefault` (-1) means leave the model's own default.
typedef NS_ENUM(NSInteger, LRTLMActivationDtype) {
    LRTLMActivationDtypeDefault = -1,
    LRTLMActivationDtypeF32 = 0,
    LRTLMActivationDtypeF16 = 1,
    LRTLMActivationDtypeI16 = 2,
    LRTLMActivationDtypeI8  = 3,
};

/// Maps to `litert_lm_set_min_log_level`. The LiteRT-LM C API documents:
/// 0=VERBOSE, 1=DEBUG, 2=INFO, 3=WARNING, 4=ERROR, 5=FATAL, 1000=SILENT.
typedef NS_ENUM(NSInteger, LRTLMLogLevel) {
    LRTLMLogLevelVerbose = 0,
    LRTLMLogLevelDebug   = 1,
    LRTLMLogLevelInfo    = 2,
    LRTLMLogLevelWarning = 3,
    LRTLMLogLevelError   = 4,
    LRTLMLogLevelFatal   = 5,
    LRTLMLogLevelSilent  = 1000,
};

/// Sampler parameters for a chat session. Maps to `LiteRtLmSamplerParams` in
/// `c/engine.h`. Defaults match the Gemma 4 metadata (TopP, k=1, p=0.95,
/// temperature=1, seed=0). See `litert_lm_session_config_set_sampler_params`.
@interface LRTLMSamplerParams : NSObject
@property (nonatomic) LRTLMSamplerType type;     // C: LiteRtLmSamplerType
@property (nonatomic) int topK;                  // C: top_k
@property (nonatomic) float topP;                // C: top_p
@property (nonatomic) float temperature;         // C: temperature
@property (nonatomic) int32_t seed;              // C: seed (0 = non-deterministic)
@end

/// Bag-of-options for `litert_lm_engine_settings_*` plus
/// `litert_lm_set_min_log_level`. Construct, set the fields you care about,
/// pass to `LRTLMEngine -initWithSettings:error:`. Anything left at its
/// default skips the corresponding C setter so the runtime falls back to its
/// own internal default.
///
/// Android parity reference: `android-app/.../data/Config.kt::ConfigKeys`.
/// Defaults below match Android's `DEFAULT_ACCELERATORS = listOf(GPU)` and
/// the LiteRT-LM C-side defaults documented in `c/engine.h`.
@interface LRTLMEngineSettings : NSObject
- (instancetype)initWithModelPath:(NSString *)modelPath;

/// `litert_lm_engine_settings_create` — `model_path`. Required.
@property (nonatomic, copy)   NSString *modelPath;
/// `litert_lm_engine_settings_create` — `backend_str`. Default `GPU`
/// (Android `DEFAULT_ACCELERATORS = [GPU]`). `LRTLMBackendDefault` skips the
/// argument so the model file's preferred backend wins.
@property (nonatomic) LRTLMBackend backend;
/// `litert_lm_engine_settings_create` — `vision_backend_str`. Default
/// follows compute backend by leaving it `LRTLMBackendDefault`.
@property (nonatomic) LRTLMBackend visionBackend;
/// `litert_lm_engine_settings_create` — `audio_backend_str`. Default
/// follows compute backend by leaving it `LRTLMBackendDefault`.
@property (nonatomic) LRTLMBackend audioBackend;
/// `litert_lm_engine_settings_set_max_num_tokens`. KV-cache cap shared
/// across sessions. `0` = leave default.
@property (nonatomic) int maxTokens;
/// `litert_lm_engine_settings_set_cache_dir`. The Swift wrapper passes
/// `Application Support/litertlm-cache/<modelHash>/` so prefill caches
/// survive launches; `nil` skips the call.
@property (nonatomic, copy, nullable) NSString *cacheDir;
/// `litert_lm_engine_settings_set_parallel_file_section_loading`. Default
/// `YES` matches the C-side default; only false-valued calls reach the C
/// API.
@property (nonatomic) BOOL parallelFileSectionLoading;
/// `litert_lm_engine_settings_set_activation_data_type`.
/// `LRTLMActivationDtypeDefault` skips the call — model picks.
@property (nonatomic) LRTLMActivationDtype activationDataType;
/// `litert_lm_engine_settings_set_prefill_chunk_size`. `0` = unset; only
/// honored on CPU dynamic models.
@property (nonatomic) int prefillChunkSize;
/// `litert_lm_engine_settings_set_enable_speculative_decoding`. Default off.
@property (nonatomic) BOOL enableSpeculativeDecoding;
/// `litert_lm_set_min_log_level`. Default `Silent` keeps prod logs clean;
/// the Settings → Advanced → "Debug log level" picker bumps it.
@property (nonatomic) LRTLMLogLevel logLevel;
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
/// Same as the 4-arg multimodal variant plus an optional extra-context
/// dict. The dict is JSON-serialized and passed to the underlying C API
/// as `extra_context` (see `litert_lm_conversation_send_message_stream`).
/// Mirrors the Android `sendMessageAsync(..., extraContext: Map<String, String>)`
/// hook that the Android Gallery uses to toggle `enable_thinking`. nil
/// or empty dict matches the existing default of `"{}"`.
- (void)sendMessage:(NSString *)text
         imagePaths:(nullable NSArray<NSString *> *)imagePaths
         audioPaths:(nullable NSArray<NSString *> *)audioPaths
       extraContext:(nullable NSDictionary<NSString *, NSString *> *)extraContext
            onToken:(void (^)(NSString * _Nonnull chunk, NSString * _Nullable thought))onToken
             onDone:(void (^)(NSError * _Nullable error))onDone;
- (void)cancel;
- (void)close;
@end

@interface LRTLMEngine : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// Rich initializer covering every engine knob.
/// @param settings The engine settings. `modelPath` must point at a readable
///   .litertlm file; everything else has a sensible default.
/// @param outError Populated with a `LRTLMErrorDomain` error on init failure.
- (nullable instancetype)initWithSettings:(LRTLMEngineSettings *)settings
                                    error:(NSError **)outError;

/// Legacy initializer kept for callers that haven't migrated yet. Internally
/// builds an `LRTLMEngineSettings` and forwards. New code should prefer
/// `-initWithSettings:error:`.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                   backend:(LRTLMBackend)backend
                                 maxTokens:(int)maxTokens
                                  cacheDir:(nullable NSString *)cacheDir
                                     error:(NSError **)outError;

/// Creates a conversation against the loaded engine. The optional flags map
/// 1:1 to `litert_lm_session_config_*` and
/// `litert_lm_conversation_config_*` calls in `c/engine.h`:
///   - `applyPromptTemplate`         → set_apply_prompt_template (default YES)
///   - `enableConstrainedDecoding`   → set_enable_constrained_decoding (default NO)
///   - `maxOutputTokens`             → set_max_output_tokens (0 = unset)
- (nullable LRTLMConversation *)createConversationWithSystemPrompt:(nullable NSString *)systemPrompt
                                                             sampler:(LRTLMSamplerParams *)sampler
                                                 applyPromptTemplate:(BOOL)applyPromptTemplate
                                          enableConstrainedDecoding:(BOOL)enableConstrainedDecoding
                                                     maxOutputTokens:(int)maxOutputTokens
                                                               error:(NSError **)outError;

/// Full form — same as the overload above but also seeds the new conversation
/// with prior chat turns via `litert_lm_conversation_config_set_messages`.
/// `initialMessagesJson` must be a JSON array of `{"role":"user|assistant",
/// "content":"..."}` objects, or nil to skip seeding. Used by the chat layer
/// to warm a fresh KV cache after an agentic turn so post-task chat can still
/// reason against earlier visible bubbles.
- (nullable LRTLMConversation *)createConversationWithSystemPrompt:(nullable NSString *)systemPrompt
                                                  initialMessages:(nullable NSString *)initialMessagesJson
                                                             sampler:(LRTLMSamplerParams *)sampler
                                                 applyPromptTemplate:(BOOL)applyPromptTemplate
                                          enableConstrainedDecoding:(BOOL)enableConstrainedDecoding
                                                     maxOutputTokens:(int)maxOutputTokens
                                                               error:(NSError **)outError;

/// Convenience overload — kept for callers that want today's defaults
/// (apply_prompt_template=YES, no constrained decoding, no per-turn cap).
- (nullable LRTLMConversation *)createConversationWithSystemPrompt:(nullable NSString *)systemPrompt
                                                             sampler:(LRTLMSamplerParams *)sampler
                                                               error:(NSError **)outError;

- (void)close;
@end

#pragma mark - Deferred LiteRT-LM C API surface
//
// The following knobs are deliberately not bridged today:
//
// - `litert_lm_conversation_config_set_tools(...)` — tool/function-calling
//   format. We will land it together with the orchestration completion phase
//   so the planner can emit tool definitions in the model's native format.
// - `litert_lm_conversation_config_set_messages(...)` — prefilled history.
//   We replay history client-side via ConversationStore + sendMessage; using
//   this would duplicate state.
// - `litert_lm_engine_settings_enable_benchmark` /
//   `..._set_num_prefill_tokens` / `..._set_num_decode_tokens` — eval-only
//   knobs surfaced through `edgecat://eval` instead.
// - `litert_lm_engine_tokenize` / `..._detokenize` /
//   `..._get_start_token` / `..._get_stop_tokens` — power-user introspection,
//   no Settings UI.

NS_ASSUME_NONNULL_END

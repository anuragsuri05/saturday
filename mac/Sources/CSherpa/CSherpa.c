#include "CSherpa.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// sherpa-onnx's public C API (Apache-2.0, https://github.com/k2-fsa/sherpa-onnx), used only for its
// type definitions; the functions are looked up at runtime.
#include "vendor/sherpa-onnx-c-api.h"

typedef const SherpaOnnxOfflineTts *(*CreateFn)(const SherpaOnnxOfflineTtsConfig *);
typedef void (*DestroyFn)(const SherpaOnnxOfflineTts *);
typedef int32_t (*SampleRateFn)(const SherpaOnnxOfflineTts *);
typedef const SherpaOnnxGeneratedAudio *(*GenerateFn)(const SherpaOnnxOfflineTts *, const char *,
                                                      const SherpaOnnxGenerationConfig *,
                                                      SherpaOnnxGeneratedAudioProgressCallbackWithArg, void *);
typedef void (*DestroyAudioFn)(const SherpaOnnxGeneratedAudio *);

struct SaturdayTTS {
    void *library;
    const SherpaOnnxOfflineTts *engine;
    DestroyFn destroy;
    SampleRateFn sample_rate;
    GenerateFn generate;
    DestroyAudioFn destroy_audio;
};

static void write_error(char *error, int32_t error_len, const char *message) {
    if (error && error_len > 0) snprintf(error, (size_t)error_len, "%s", message);
}

/// Loads the library and looks up the functions. On success returns a TTS shell without an engine.
static SaturdayTTS *load(const char *lib_dir, CreateFn *create, char *error, int32_t error_len) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/libsherpa-onnx-c-api.dylib", lib_dir);
    // The library finds libonnxruntime.dylib next to itself (@loader_path).
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        const char *reason = dlerror();
        write_error(error, error_len, reason ? reason : "Couldn't load the voice engine.");
        return NULL;
    }
    SaturdayTTS *tts = calloc(1, sizeof(SaturdayTTS));
    tts->library = library;
    *create = (CreateFn)dlsym(library, "SherpaOnnxCreateOfflineTts");
    tts->destroy = (DestroyFn)dlsym(library, "SherpaOnnxDestroyOfflineTts");
    tts->sample_rate = (SampleRateFn)dlsym(library, "SherpaOnnxOfflineTtsSampleRate");
    tts->generate = (GenerateFn)dlsym(library, "SherpaOnnxOfflineTtsGenerateWithConfig");
    tts->destroy_audio = (DestroyAudioFn)dlsym(library, "SherpaOnnxDestroyOfflineTtsGeneratedAudio");
    if (!*create || !tts->destroy || !tts->sample_rate || !tts->generate || !tts->destroy_audio) {
        write_error(error, error_len, "The voice engine library is missing functions (unsupported version).");
        dlclose(library);
        free(tts);
        return NULL;
    }
    return tts;
}

static SaturdayTTS *finish(SaturdayTTS *tts, CreateFn create, const SherpaOnnxOfflineTtsConfig *config,
                           char *error, int32_t error_len) {
    tts->engine = create(config);
    if (!tts->engine) {
        write_error(error, error_len, "The voice model couldn't be loaded. Try downloading it again.");
        dlclose(tts->library);
        free(tts);
        return NULL;
    }
    return tts;
}

SaturdayTTS *saturday_tts_create(const char *lib_dir, const char *model, const char *voices,
                                 const char *tokens, const char *lexicon, const char *lang,
                                 int32_t num_threads, char *error, int32_t error_len) {
    CreateFn create = NULL;
    SaturdayTTS *tts = load(lib_dir, &create, error, error_len);
    if (!tts) return NULL;

    SherpaOnnxOfflineTtsConfig config;
    memset(&config, 0, sizeof(config));
    config.model.kokoro.model = model;
    config.model.kokoro.voices = voices;
    config.model.kokoro.tokens = tokens;
    config.model.kokoro.lexicon = lexicon;
    config.model.kokoro.lang = lang;
    config.model.kokoro.length_scale = 1.0f;
    config.model.num_threads = num_threads;
    config.model.provider = "cpu";
    config.max_num_sentences = 1;
    config.silence_scale = 0.2f;
    return finish(tts, create, &config, error, error_len);
}

SaturdayTTS *saturday_tts_create_supertonic(const char *lib_dir, const char *model_dir,
                                            int32_t num_threads, char *error, int32_t error_len) {
    CreateFn create = NULL;
    SaturdayTTS *tts = load(lib_dir, &create, error, error_len);
    if (!tts) return NULL;

    char duration[4096], encoder[4096], estimator[4096], vocoder[4096], json[4096], indexer[4096], style[4096];
    snprintf(duration, sizeof(duration), "%s/duration_predictor.int8.onnx", model_dir);
    snprintf(encoder, sizeof(encoder), "%s/text_encoder.int8.onnx", model_dir);
    snprintf(estimator, sizeof(estimator), "%s/vector_estimator.int8.onnx", model_dir);
    snprintf(vocoder, sizeof(vocoder), "%s/vocoder.int8.onnx", model_dir);
    snprintf(json, sizeof(json), "%s/tts.json", model_dir);
    snprintf(indexer, sizeof(indexer), "%s/unicode_indexer.bin", model_dir);
    snprintf(style, sizeof(style), "%s/voice.bin", model_dir);

    SherpaOnnxOfflineTtsConfig config;
    memset(&config, 0, sizeof(config));
    config.model.supertonic.duration_predictor = duration;
    config.model.supertonic.text_encoder = encoder;
    config.model.supertonic.vector_estimator = estimator;
    config.model.supertonic.vocoder = vocoder;
    config.model.supertonic.tts_json = json;
    config.model.supertonic.unicode_indexer = indexer;
    config.model.supertonic.voice_style = style;
    config.model.num_threads = num_threads;
    config.model.provider = "cpu";
    return finish(tts, create, &config, error, error_len);
}

int32_t saturday_tts_sample_rate(SaturdayTTS *tts) {
    return tts ? tts->sample_rate(tts->engine) : 0;
}

float *saturday_tts_generate_ex(SaturdayTTS *tts, const char *text, int32_t sid, float speed,
                                int32_t num_steps, const char *extra, int32_t *out_count) {
    if (out_count) *out_count = 0;
    if (!tts || !text) return NULL;

    SherpaOnnxGenerationConfig config;
    memset(&config, 0, sizeof(config));
    config.sid = sid;
    config.speed = speed;
    config.silence_scale = 0.2f;
    config.num_steps = num_steps;
    config.extra = extra;

    const SherpaOnnxGeneratedAudio *audio = tts->generate(tts->engine, text, &config, NULL, NULL);
    if (!audio) return NULL;
    float *samples = NULL;
    if (audio->n > 0 && audio->samples) {
        samples = malloc(sizeof(float) * (size_t)audio->n);
        if (samples) {
            memcpy(samples, audio->samples, sizeof(float) * (size_t)audio->n);
            if (out_count) *out_count = audio->n;
        }
    }
    tts->destroy_audio(audio);
    return samples;
}

float *saturday_tts_generate(SaturdayTTS *tts, const char *text, int32_t sid, float speed, int32_t *out_count) {
    return saturday_tts_generate_ex(tts, text, sid, speed, 0, NULL, out_count);
}

void saturday_tts_free_samples(float *samples) {
    free(samples);
}

void saturday_tts_destroy(SaturdayTTS *tts) {
    if (!tts) return;
    if (tts->engine) tts->destroy(tts->engine);
    if (tts->library) dlclose(tts->library);
    free(tts);
}

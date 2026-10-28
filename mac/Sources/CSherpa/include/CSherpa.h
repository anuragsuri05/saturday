// A tiny bridge to sherpa-onnx's on-device neural voices (Kokoro and Supertonic). The sherpa-onnx library is
// loaded at runtime (with dlopen) from the folder Saturday downloads it to, so the app builds and runs without it.

#ifndef CSHERPA_H
#define CSHERPA_H

#include <stdint.h>

typedef struct SaturdayTTS SaturdayTTS;

/// Loads libsherpa-onnx-c-api.dylib from `lib_dir` and creates a Kokoro engine.
/// Returns NULL on failure and writes a message into `error`.
SaturdayTTS *saturday_tts_create(const char *lib_dir, const char *model, const char *voices,
                                 const char *tokens, const char *lexicon, const char *lang,
                                 int32_t num_threads, char *error, int32_t error_len);

/// Creates a Supertonic engine from the model files in `model_dir`.
SaturdayTTS *saturday_tts_create_supertonic(const char *lib_dir, const char *model_dir,
                                            int32_t num_threads, char *error, int32_t error_len);

/// Output sample rate in Hz.
int32_t saturday_tts_sample_rate(SaturdayTTS *tts);

/// Synthesizes `text` with speaker `sid`. Returns a malloc'd buffer of mono float samples in [-1, 1]
/// and its length in `out_count`, or NULL on failure. Free it with saturday_tts_free_samples().
float *saturday_tts_generate(SaturdayTTS *tts, const char *text, int32_t sid, float speed, int32_t *out_count);

/// Like saturday_tts_generate, with the model's step count (0 for its default) and extra JSON options.
float *saturday_tts_generate_ex(SaturdayTTS *tts, const char *text, int32_t sid, float speed,
                                int32_t num_steps, const char *extra, int32_t *out_count);

void saturday_tts_free_samples(float *samples);

void saturday_tts_destroy(SaturdayTTS *tts);

#endif

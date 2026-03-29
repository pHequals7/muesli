#ifndef WEBRTC_AEC3_BRIDGE_H
#define WEBRTC_AEC3_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WebRTCAec3Handle WebRTCAec3Handle;

WebRTCAec3Handle *WebRTCAec3Create(int sample_rate_hz,
                                   int render_channels,
                                   int capture_channels);
void WebRTCAec3Destroy(WebRTCAec3Handle *handle);

bool WebRTCAec3AnalyzeRender(WebRTCAec3Handle *handle,
                             const int16_t *samples,
                             int sample_count);
bool WebRTCAec3SetAudioBufferDelay(WebRTCAec3Handle *handle,
                                   int delay_ms);
bool WebRTCAec3ProcessCapture(WebRTCAec3Handle *handle,
                              const int16_t *input_samples,
                              int sample_count,
                              int16_t *output_samples);

#ifdef __cplusplus
}
#endif

#endif

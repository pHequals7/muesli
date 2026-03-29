#include "WebRTCAec3Bridge.h"

#include <cstring>
#include <memory>

#include "api/audio/audio_frame.h"
#include "api/audio/echo_canceller3_config.h"
#include "api/audio/echo_canceller3_factory.h"
#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/high_pass_filter.h"
#include "modules/audio_processing/include/audio_processing.h"

namespace {

constexpr int kFrameDurationMs = 10;

void SplitIfNeeded(webrtc::AudioBuffer* buffer) {
  if (buffer && buffer->num_bands() > 1) {
    buffer->SplitIntoFrequencyBands();
  }
}

void MergeIfNeeded(webrtc::AudioBuffer* buffer) {
  if (buffer && buffer->num_bands() > 1) {
    buffer->MergeFrequencyBands();
  }
}

bool UpdateFrame(webrtc::AudioFrame &frame,
                 const int16_t *samples,
                 int sample_count,
                 int sample_rate_hz,
                 int channels) {
  if (!samples || sample_count <= 0 || channels <= 0) {
    return false;
  }

  frame.UpdateFrame(
      0,
      samples,
      sample_count / channels,
      sample_rate_hz,
      webrtc::AudioFrame::kNormalSpeech,
      webrtc::AudioFrame::kVadActive,
      channels);
  return true;
}

}  // namespace

struct WebRTCAec3Handle {
  int sample_rate_hz = 0;
  int channels = 0;
  int samples_per_frame = 0;
  int audio_buffer_delay_ms = 0;
  webrtc::StreamConfig stream_config = webrtc::StreamConfig(16000, 1, false);
  webrtc::AudioFrame render_frame;
  webrtc::AudioFrame capture_frame;
  std::unique_ptr<webrtc::AudioBuffer> render_audio;
  std::unique_ptr<webrtc::AudioBuffer> capture_audio;
  std::unique_ptr<webrtc::HighPassFilter> high_pass_filter;
  std::unique_ptr<webrtc::EchoControl> echo_control;
};

WebRTCAec3Handle *WebRTCAec3Create(int sample_rate_hz,
                                   int render_channels,
                                   int capture_channels) {
  if (sample_rate_hz <= 0 || render_channels <= 0 || capture_channels <= 0) {
    return nullptr;
  }

  auto *handle = new WebRTCAec3Handle();
  handle->sample_rate_hz = sample_rate_hz;
  handle->channels = capture_channels;
  handle->samples_per_frame = sample_rate_hz * kFrameDurationMs / 1000;
  handle->stream_config =
      webrtc::StreamConfig(sample_rate_hz, capture_channels, false);

  webrtc::EchoCanceller3Config config;
  webrtc::EchoCanceller3Factory factory(config);
  handle->echo_control = factory.Create(sample_rate_hz);
  handle->high_pass_filter =
      std::make_unique<webrtc::HighPassFilter>(capture_channels);
  handle->render_audio = std::make_unique<webrtc::AudioBuffer>(
      sample_rate_hz, render_channels,
      sample_rate_hz, render_channels,
      sample_rate_hz, render_channels);
  handle->capture_audio = std::make_unique<webrtc::AudioBuffer>(
      sample_rate_hz, capture_channels,
      sample_rate_hz, capture_channels,
      sample_rate_hz, capture_channels);

  if (!handle->echo_control || !handle->high_pass_filter ||
      !handle->render_audio || !handle->capture_audio) {
    delete handle;
    return nullptr;
  }

  return handle;
}

void WebRTCAec3Destroy(WebRTCAec3Handle *handle) {
  delete handle;
}

bool WebRTCAec3AnalyzeRender(WebRTCAec3Handle *handle,
                             const int16_t *samples,
                             int sample_count) {
  if (!handle || sample_count != handle->samples_per_frame) {
    return false;
  }

  if (!UpdateFrame(handle->render_frame,
                   samples,
                   sample_count,
                   handle->sample_rate_hz,
                   handle->stream_config.num_channels())) {
    return false;
  }

  handle->render_audio->CopyFrom(&handle->render_frame);
  SplitIfNeeded(handle->render_audio.get());
  handle->echo_control->AnalyzeRender(handle->render_audio.get());
  MergeIfNeeded(handle->render_audio.get());
  return true;
}

bool WebRTCAec3SetAudioBufferDelay(WebRTCAec3Handle *handle,
                                   int delay_ms) {
  if (!handle || delay_ms < 0) {
    return false;
  }

  handle->audio_buffer_delay_ms = delay_ms;
  return true;
}

bool WebRTCAec3ProcessCapture(WebRTCAec3Handle *handle,
                              const int16_t *input_samples,
                              int sample_count,
                              int16_t *output_samples) {
  if (!handle || !output_samples || sample_count != handle->samples_per_frame) {
    return false;
  }

  if (!UpdateFrame(handle->capture_frame,
                   input_samples,
                   sample_count,
                   handle->sample_rate_hz,
                   handle->stream_config.num_channels())) {
    return false;
  }

  handle->capture_audio->CopyFrom(&handle->capture_frame);
  handle->echo_control->AnalyzeCapture(handle->capture_audio.get());
  SplitIfNeeded(handle->capture_audio.get());
  handle->high_pass_filter->Process(handle->capture_audio.get());
  handle->echo_control->SetAudioBufferDelay(handle->audio_buffer_delay_ms);
  handle->echo_control->ProcessCapture(handle->capture_audio.get(), false);
  MergeIfNeeded(handle->capture_audio.get());
  handle->capture_audio->CopyTo(&handle->capture_frame);
  std::memcpy(output_samples,
              handle->capture_frame.data(),
              static_cast<size_t>(sample_count) * sizeof(int16_t));
  return true;
}

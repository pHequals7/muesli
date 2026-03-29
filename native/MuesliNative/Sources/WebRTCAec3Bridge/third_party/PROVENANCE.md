# WebRTC AEC Provenance

This bridge vendors only the source needed for local meeting echo cancellation.

## WebRTC
- Source: `https://webrtc.googlesource.com/src`
- Commit: `0aefbf0ec47c018bf2a4cd520c93f72908af2b56`
- Import method: official source tarball from
  `https://webrtc.googlesource.com/src/+archive/0aefbf0ec47c018bf2a4cd520c93f72908af2b56.tar.gz`
- Vendored paths:
  - `common_audio/`
  - `api/`
  - `modules/audio_processing/`
  - `rtc_base/`
  - `system_wrappers/`
- License files copied into `third_party/webrtc/`:
  - `LICENSE`
  - `AUTHORS`
  - `PATENTS`

## Abseil
- Source: `https://github.com/abseil/abseil-cpp`
- Commit: `0093ac6cac892086a6d7d09c55421a2a4c2cdb2e`
- Vendored path:
  - `absl/`
- License files copied into `third_party/abseil-cpp/`:
  - `LICENSE`
  - `AUTHORS`

## JsonCpp
- Source: `https://github.com/open-source-parsers/jsoncpp`
- Commit: `cdc84831f1861c4372cc2ced8284f0b5d0bcec5a`
- Vendored paths:
  - `include/`
  - `src/`
- License files copied into `third_party/jsoncpp/`:
  - `LICENSE`
  - `AUTHORS`

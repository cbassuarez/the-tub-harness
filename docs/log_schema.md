# Training Substrate Log Schema

## Session Artifacts (`sessions/<session_id>/`)

- `frames_<session_id>.jsonl`
- `events_<session_id>.jsonl`
- `session_meta_<session_id>.json`
- `input_<session_id>.caf` (or `.wav`, optional when input recording is enabled)

## Frame Log (`frames_<session_id>.jsonl`)

One JSON object per 10 Hz frame:

- `ts_ms`: frame timestamp
- `frame_index`: monotonic frame number within session
- `session_id`: session identifier used in `ModelIn`
- `frame_hz`: expected frame rate (10)
- `replay_mode`: `true|false`
- `input_source`: `"live" | "replay_file"`
- `mode`: mode used for this frame
- `buttons`: `{jolt, clear}`
- `features`: feature vector used for this frame
- `state`: optional harness state sent in `ModelIn`
- `model_in`: exact `ModelIn` payload sent to model
- `model_out`: model response payload (nullable on timeout/failure)
- `diagnostics`: request id, send/recv timestamps, latency, timeout/decode status
- `interventions`:
  - `limiter_hit`, `density_cap`, `voice_cap`, `cpu_guard`
  - plus `timeout`, `decode_error`, `contract_violation`, `pick_fallback`, `feature_fallback`, `extras`
- `label`: `null | "good" | "too_much" | "too_flat"`
- `bundle_id`: active bundle id for this run

## Events Log (`events_<session_id>.jsonl`)

Bundle header event on startup:
- `ts_ms`
- `event = "bundle_header"`
- `bundle_id`
- `session_id`

## Session Metadata (`session_meta_<session_id>.json`)

- `session_id`
- `bundle_id`
- `created_at` (ISO8601)
- `sample_rate`
- `channels`
- `input_audio_format` (`caf` or `wav`)
- `input_audio_path` (nullable when recording disabled)
- `frames_path`
- `events_path`
- `frame_hz` (10)
- `record_input_audio_enabled`
- `replay_mode`
- `replayed_session_id` (nullable)
- `replay_audio_missing`
- `alignment.start_ts_ms`
- `alignment.audio_start_host_time`
- `alignment.audio_start_sample_index`
- `bundle` metadata payload

Label change events:
- `ts_ms`
- `event = "label_change"`
- `from`: previous label (nullable)
- `to`: new label (nullable)
- `bundle_id`
- `session_id`

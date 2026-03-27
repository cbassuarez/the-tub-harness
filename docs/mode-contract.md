# THE TUB Mode Contract (Protocol v1, Locked)

## Locking
- `protocol_version`: `1`
- `contract_version`: `control_surface_v1`
- `contract_fingerprint`: emitted in every run bundle (`bundles/*.json`) and startup banner.
- Startup banner also emits `lock=ok|mismatch` by checking runtime fingerprint against `ModeContract.lockedContractFingerprint`.
- Fingerprint source: deterministic hash of mode params, aliases, required picks, bounds, and safe defaults in `ModeContract`.
- Change policy: if contract tables change, intentionally update lock/fingerprint and coordinate with model repo before merge.

## Protocol Rules
- `ModelIn` and `ModelOut` require `protocol_version`.
- Unsupported protocol versions are rejected.
- Unknown JSON keys are rejected in strict packet decode.
- `mode` must be in `0...10`.

## Canonical Params By Mode
- `0`: `dry_level`, `reverb_mix`, `reverb_decay_s`, `pre_delay_ms`, `tone_db`
- `1`: `fracture`, `mutation`, `pitch_lock`, `hold_len_s`, `tail_fade_ms`, `scene_rate_hz`, `motion_speed`, `spread`
- `2`: `grain_size_ms`, `grain_density`, `scan_rate`, `freeze_prob`, `freeze_len_s`, `pitch_spread_cents`
- `3`: `drive`, `bit_depth_bits`, `downsample_amt`, `res_shift`, `tone_db`
- `4`: `density`, `gesture_rate_hz`, `sample_mix`, `dry_level`, `stability`
- `5`: `note_rate_notes_per_s`, `voice_cap`, `pitch_follow`, `velocity_bias`, `level`, `stability`
- `6`: `note_rate_notes_per_s`, `voice_cap`, `pitch_follow`, `velocity_bias`, `level`, `stability`, `dry_level`
- `7`: `swap_rate_hz`, `crossfade_ms`, `bucket_sharpness`, `mapping_entropy`, `mix`
- `8`: `reverb_rand_amt`, `reverb_decay_base_s`, `reverb_decay_range_s`, `reverb_color`, `twitchiness`, `motion_speed`, `spread`
- `9`: `particle_density`, `particle_voice_cap`, `particle_decay_s`, `particle_brightness`, `motion_speed`, `spread`
- `10`: `scene_len_s`, `chaos`, `blend`, `stability`

## Legacy Alias Support (Examples)
- Mode `1`: `repeat_prob -> fracture`, `jitter_ms -> mutation`, `stutter_len_ms -> scene_rate_hz`, `feedback -> hold_len_s`
- Mode `3`: `bit_depth -> bit_depth_bits`, `downsample -> downsample_amt`, `resonance -> res_shift`
- Mode `4`: `gesture_rate -> gesture_rate_hz`, `sample_level -> sample_mix`
- Mode `7`: `swap_rate -> swap_rate_hz`, `crossfade -> crossfade_ms`, `bias -> mapping_entropy`

## Required Picks
- All modes: `preset_id`, `spatial_pattern_id`
- Mode `1`: `grid_div`, `repeat_style_id`
- Mode `4`: `bank_id`, `sample_id`
- Mode `5`: `midi_inst_id`, `chord_set_id`
- Mode `6`: `midi_inst_id`, `chord_set_id`
- Mode `9`: `bank_id`, `midi_inst_id`
- Mode `10`: `scene_id`

## Bounds / Clamping
- Params are clamped per-mode (`ModeContract.modeBounds`).
- Non-finite params are rejected.
- Unknown params are rejected.
- Hard violations trigger deterministic safe defaults for current mode.

## Additional Fields
- `ModelIn.features`: `pitch_hz?`, `pitch_conf`, `key_estimate?`, `key_conf`
- `ModelOut.picks` can include: `chord_set_id`, `motif_id`, `articulation_id`, `mapping_id`, `mapping_family`, etc.
- `ModelOut.flags` can include: `reset_voices` (CLEAR/reset hint).

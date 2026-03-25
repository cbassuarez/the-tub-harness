# THE TUB Mode Contract (Protocol v1)

## Protocol
- `protocol_version` is required on `ModelIn` and `ModelOut`.
- Supported value: `1`.
- Missing/mismatched protocol versions are rejected.
- Contract identifier: `contract_v1`.

## Allowed Params
Global (all modes):
- `level`, `wet`, `density`, `brightness`, `aggression`, `stability`

Mode-specific:
- `0`: `dry_level`, `reverb_wet`, `reverb_decay`, `pre_delay`, `motion_speed`
- `1`: `repeat_prob`, `threshold_bias`, `window_norm`, `stutter_len_norm`, `gate_sharpness`, `wet`, `dry_level`, `motion_intensity`
- `2`: `grain_size`, `grain_density`, `scan_rate`, `scan_jump_prob`, `freeze_prob`, `wet_level`, `dry_level`, `motion_speed`, `spread`
- `3`: `excite_amount`, `resonance`, `drive`, `bit_depth`, `downsample`, `wet_level`, `dry_level`, `motion_speed`, `spread`
- `4`: `gesture_rate`, `interruptiveness`, `call_response_bias`, `memory_weight`, `similarity_target`, `dry_level`, `gesture_level`, `wet`
- `5`: `note_rate`, `voice_cap`, `velocity_bias`, `pitch_follow`, `inharmonicity`
- `6`: `note_rate`, `voice_cap`, `velocity_bias`, `pitch_follow`, `inharmonicity`, `dry_level`
- `7`: `wet`, `morph_rate`, `crossfade`, `sharpness`, `bias`
- `8`: `motion_speed`, `motion_radius`, `reverb_wet`, `reverb_decay`, `pre_delay`, `damping`, `reverb_xfade_time`
- `9`: `band_low_level`, `band_mid_level`, `band_high_level`, `spread`, `band_motion_speed`, `reverb_wet`, `reverb_decay`, `pre_delay`, `damping`, `reverb_xfade_time`
- `10`: `chaos`, `blend`, `scene_len`

## Required Picks
Always required:
- `preset_id`, `spatial_pattern_id`

Additional requirements:
- `1`: `grid_div`, `repeat_style_id`
- `4`: `bank_id`, `gesture_type_id`
- `5`: `bank_id`, `midi_inst_id`, `chord_set_id`
- `6`: `bank_id`, `midi_inst_id`, `chord_set_id`
- `7`: `mapping_id`
- `10`: `scene_id`

## Bounds
- All params are normalized `0.0..1.0`.
- Harness clamps incoming params before apply.
- Model server clamps outgoing params before send.

## Additional v1 Fields
- `ModelIn.features` includes pitch/key fields:
  - `pitch_hz` (nullable), `pitch_conf`, `key_estimate` (nullable), `key_conf`
- `ModelOut.picks` may include:
  - `chord_set_id`, `motif_id`, `articulation_id`
- `ModelOut.flags` may include:
  - `reset_voices` (CLEAR/reset hint)

## Failure Behavior
- Model side:
  - If contract validation fails, emits safe defaults for requested mode.
  - Sets `flags.prefer_stability=true` and `flags.thin_events=true`.
  - Logs contract violation details.
- Harness side:
  - If protocol/contract validation fails, ignores raw packet and applies deterministic safe defaults for current mode.
  - Logs violation details in trace/interventions.

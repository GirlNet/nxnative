#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// low/high are Switch amplitudes (0..1); frequencies are Hz.
void dm_haptic_update(float low_amp, float low_hz, float high_amp, float high_hz);

#ifdef __cplusplus
}
#endif

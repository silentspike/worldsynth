#!/usr/bin/env python3
"""WorldSynth Audio Analyzer v2 — Comprehensive Digital Ears.

Professional-grade audio quality analysis for synthesizer development.
Uses flattop window for accurate amplitude measurement, librosa for
perceptual analysis, and scipy for signal processing.

Metrics: THD, THD+N, SINAD, SFDR, ENOB, SNR, inter-harmonic noise,
pitch stability, aliasing detection, HPSS ratio, onset/stutter detection,
waveform shape fidelity, LUFS, spectral flatness, RMS stability.

Usage:
    python3 tools/audio-analyze.py /tmp/worldsynth-single.wav
    python3 tools/audio-analyze.py /tmp/worldsynth-single.wav --expected-freq 261.63
    python3 tools/audio-analyze.py /tmp/worldsynth-single.wav --plot --plot-dir /tmp/plots
    python3 tools/audio-analyze.py /tmp/worldsynth-single.wav --reference /tmp/golden.wav
"""

import sys
import argparse
import warnings
import numpy as np
from pathlib import Path

warnings.filterwarnings('ignore')


# ── WAV Loading ─────────────────────────────────────────────────────

def load_wav(path: str) -> tuple:
    """Load WAV file, return (samples_f64, sample_rate)."""
    import soundfile as sf
    data, sr = sf.read(path, dtype='float64')
    return data, sr


def get_active_region(mono: np.ndarray, threshold: float = 0.001) -> tuple:
    """Find onset/offset of active audio, return (start_idx, end_idx, active_slice)."""
    above = np.abs(mono) > threshold
    if not np.any(above):
        return 0, len(mono), mono
    start = np.argmax(above)
    end = len(mono) - 1 - np.argmax(above[::-1])
    return start, end, mono[start:end+1]


# ═══════════════════════════════════════════════════════════════════
# 1. LEVEL ANALYSIS
# ═══════════════════════════════════════════════════════════════════

def analyze_levels(samples: np.ndarray, sr: int) -> dict:
    """Peak, RMS, crest factor, DC offset, LUFS."""
    mono = samples[:, 0] if samples.ndim == 2 else samples

    peak = np.max(np.abs(mono))
    rms = np.sqrt(np.mean(mono ** 2))
    dc_offset = np.mean(mono)
    crest = peak / rms if rms > 1e-10 else 0.0

    # LUFS (BS.1770-4)
    try:
        import pyloudnorm as pyln
        meter = pyln.Meter(sr)
        stereo = samples if samples.ndim == 2 else np.column_stack([mono, mono])
        lufs = meter.integrated_loudness(stereo)
    except Exception:
        lufs = None

    return {
        "peak": peak,
        "peak_dB": 20 * np.log10(peak) if peak > 1e-10 else -120.0,
        "rms": rms,
        "rms_dB": 20 * np.log10(rms) if rms > 1e-10 else -120.0,
        "crest": crest,
        "crest_dB": 20 * np.log10(crest) if crest > 0.01 else 0,
        "dc_offset": dc_offset,
        "lufs": lufs,
    }


# ═══════════════════════════════════════════════════════════════════
# 2. SPECTRAL ANALYSIS (Flattop window for amplitude accuracy)
# ═══════════════════════════════════════════════════════════════════

def analyze_spectrum(mono: np.ndarray, sr: int, expected_freq: float = None) -> dict:
    """FFT with flattop window: THD, THD+N, SINAD, SFDR, ENOB, SNR, harmonics."""
    from scipy.signal.windows import flattop

    n = len(mono)
    win = flattop(n)
    win_norm = np.sum(win)

    fft_vals = np.fft.rfft(mono * win)
    magnitude = np.abs(fft_vals) * 2 / win_norm
    freqs = np.fft.rfftfreq(n, 1.0 / sr)

    # Find fundamental (50-2000 Hz range)
    min_bin = max(1, int(50 * n / sr))
    max_bin = min(len(magnitude) - 1, int(2000 * n / sr))
    fund_bin = min_bin + np.argmax(magnitude[min_bin:max_bin])
    fund_amp = magnitude[fund_bin]
    fund_freq = freqs[fund_bin]

    # Pitch accuracy
    cent_error = 0.0
    if expected_freq and expected_freq > 0:
        cent_error = 1200 * np.log2(fund_freq / expected_freq) if fund_freq > 0 else 999

    # Collect harmonics with wider search window
    harmonics = []
    harmonic_amps = [fund_amp]
    for k in range(2, 50):
        target = fund_freq * k
        if target > sr / 2:
            break
        h_bin = int(round(target * n / sr))
        search = max(3, int(k * 0.02 * n / sr))
        lo = max(0, h_bin - search)
        hi = min(len(magnitude) - 1, h_bin + search)
        peak_bin = lo + np.argmax(magnitude[lo:hi + 1])
        h_amp = magnitude[peak_bin]
        harmonic_amps.append(h_amp)
        h_db = 20 * np.log10(h_amp / fund_amp) if h_amp > 1e-30 else -120
        expected_db = -20 * np.log10(k)  # ideal saw: 1/k
        harmonics.append({
            "k": k, "freq": freqs[peak_bin], "amp": h_amp,
            "rel_dB": h_db, "expected_dB": expected_db,
            "deviation_dB": h_db - expected_db,
        })

    harmonic_amps = np.array(harmonic_amps)

    # THD = sqrt(sum(H2..Hn)^2) / H1
    if len(harmonic_amps) > 1:
        thd = np.sqrt(np.sum(harmonic_amps[1:] ** 2)) / fund_amp * 100
        thd_dB = 20 * np.log10(np.sqrt(np.sum(harmonic_amps[1:] ** 2)) / fund_amp)
    else:
        thd, thd_dB = 0, -120

    # Noise mask: exclude all harmonic peaks (+/- 4 bins each)
    noise_mask = np.ones(len(magnitude), dtype=bool)
    noise_mask[:max(5, int(20 * n / sr))] = False  # DC + sub-bass
    for k in range(1, 50):
        target = fund_freq * k
        if target > sr / 2:
            break
        h_bin = int(round(target * n / sr))
        lo = max(0, h_bin - 4)
        hi = min(len(noise_mask), h_bin + 5)
        noise_mask[lo:hi] = False

    noise_rms = np.sqrt(np.mean(magnitude[noise_mask] ** 2)) if np.any(noise_mask) else 1e-30

    # SNR = fundamental / noise
    snr_dB = 20 * np.log10(fund_amp / noise_rms) if noise_rms > 1e-30 else 120

    # THD+N = (harmonics + noise) / fundamental
    thdn_rms = np.sqrt(np.sum(harmonic_amps[1:] ** 2) + noise_rms ** 2 * np.sum(noise_mask))
    thdn_dB = 20 * np.log10(thdn_rms / fund_amp) if fund_amp > 1e-30 else -120

    # SINAD = fundamental / (noise + distortion)
    # All energy except fundamental
    non_fund = magnitude.copy()
    for k in range(1, 2):  # only mask fundamental
        h_bin = int(round(fund_freq * k * n / sr))
        lo = max(0, h_bin - 4)
        hi = min(len(non_fund), h_bin + 5)
        non_fund[lo:hi] = 0
    non_fund[:5] = 0
    nd_rms = np.sqrt(np.mean(non_fund ** 2))
    sinad_dB = 20 * np.log10(fund_amp / nd_rms) if nd_rms > 1e-30 else 120

    # SFDR = fundamental / strongest spurious (non-harmonic peak)
    spurs = magnitude.copy()
    for k in range(1, 50):
        target = fund_freq * k
        if target > sr / 2:
            break
        h_bin = int(round(target * n / sr))
        lo = max(0, h_bin - 4)
        hi = min(len(spurs), h_bin + 5)
        spurs[lo:hi] = 0
    spurs[:5] = 0
    max_spur = np.max(spurs) if np.max(spurs) > 1e-30 else 1e-30
    sfdr_dB = 20 * np.log10(fund_amp / max_spur)

    # ENOB = (SINAD - 1.76) / 6.02
    enob = (sinad_dB - 1.76) / 6.02

    # Inter-harmonic noise (energy between harmonics)
    peak_width_hz = 15
    h_energy = 0
    n_energy = 0
    for i, (f, m) in enumerate(zip(freqs, magnitude)):
        if f < 20 or f > 20000:
            continue
        nearest_h = round(f / fund_freq) if fund_freq > 0 else 0
        if nearest_h > 0 and abs(f - fund_freq * nearest_h) < peak_width_hz:
            h_energy += m ** 2
        else:
            n_energy += m ** 2
    inter_harm_snr = 10 * np.log10(h_energy / n_energy) if n_energy > 1e-30 else 120

    return {
        "fundamental_hz": fund_freq,
        "fund_amp": fund_amp,
        "cent_error": cent_error,
        "harmonics": harmonics,
        "thd_percent": thd,
        "thd_dB": thd_dB,
        "thdn_dB": thdn_dB,
        "snr_dB": snr_dB,
        "sinad_dB": sinad_dB,
        "sfdr_dB": sfdr_dB,
        "enob": enob,
        "inter_harmonic_snr_dB": inter_harm_snr,
        "noise_floor_rms": noise_rms,
        "fft_magnitude": magnitude,
        "fft_freqs": freqs,
    }


# ═══════════════════════════════════════════════════════════════════
# 3. PITCH TRACKING (pyin — probabilistic YIN)
# ═══════════════════════════════════════════════════════════════════

def analyze_pitch(mono: np.ndarray, sr: int, expected_freq: float = 261.63) -> dict:
    """Track pitch over time: stability, drift, glitches."""
    import librosa

    f0, voiced_flag, voiced_prob = librosa.pyin(
        mono.astype(np.float32), fmin=max(50, expected_freq * 0.5),
        fmax=min(sr / 2, expected_freq * 2), sr=sr,
        frame_length=2048, hop_length=512
    )
    valid_f0 = f0[~np.isnan(f0)]
    if len(valid_f0) == 0:
        return {"voiced_frames": 0, "total_frames": len(f0), "stable": False}

    cents = 1200 * np.log2(valid_f0 / expected_freq)
    cent_diffs = np.abs(np.diff(cents)) if len(cents) > 1 else np.array([0])
    glitches = int(np.sum(cent_diffs > 50))

    return {
        "voiced_frames": len(valid_f0),
        "total_frames": len(f0),
        "mean_f0": float(np.mean(valid_f0)),
        "median_f0": float(np.median(valid_f0)),
        "f0_stddev": float(np.std(valid_f0)),
        "cent_mean": float(np.mean(cents)),
        "cent_stddev": float(np.std(cents)),
        "cent_max_deviation": float(np.max(np.abs(cents))),
        "pitch_glitches": glitches,
        "stable": float(np.std(cents)) < 5.0 and glitches == 0,
    }


# ═══════════════════════════════════════════════════════════════════
# 4. HARMONIC-PERCUSSIVE SEPARATION (noise/artifact isolation)
# ═══════════════════════════════════════════════════════════════════

def analyze_hpss(mono: np.ndarray, sr: int) -> dict:
    """Separate harmonic from percussive/noise content."""
    import librosa

    y = mono.astype(np.float32)
    harmonic, percussive = librosa.effects.hpss(y, margin=3.0)
    residual = y - harmonic

    h_rms = np.sqrt(np.mean(harmonic ** 2))
    p_rms = np.sqrt(np.mean(percussive ** 2))
    r_rms = np.sqrt(np.mean(residual ** 2))

    h_db = 20 * np.log10(h_rms + 1e-30)
    p_db = 20 * np.log10(p_rms + 1e-30)
    r_db = 20 * np.log10(r_rms + 1e-30)

    return {
        "harmonic_rms": h_rms,
        "percussive_rms": p_rms,
        "residual_rms": r_rms,
        "hp_ratio_dB": h_db - p_db,
        "hr_snr_dB": h_db - r_db,
        "harmonic_dB": h_db,
        "percussive_dB": p_db,
    }


# ═══════════════════════════════════════════════════════════════════
# 5. ALIASING DETECTION
# ═══════════════════════════════════════════════════════════════════

def analyze_aliasing(mono: np.ndarray, sr: int, fund_freq: float) -> dict:
    """Detect aliased harmonics (folded from above Nyquist)."""
    from scipy.signal.windows import flattop

    n = len(mono)
    win = flattop(n)
    fft_vals = np.fft.rfft(mono * win)
    magnitude = np.abs(fft_vals) * 2 / np.sum(win)
    freqs = np.fft.rfftfreq(n, 1.0 / sr)

    fund_bin = int(round(fund_freq * n / sr))
    fund_amp = magnitude[max(0, min(fund_bin, len(magnitude)-1))]

    nyquist = sr / 2
    max_harmonic = int(nyquist / fund_freq)

    # Check mirror frequencies (aliasing = sr - harmonic)
    aliases = []
    for h in range(max_harmonic + 1, max_harmonic + 20):
        alias_freq = sr - fund_freq * h
        if alias_freq < 20 or alias_freq >= nyquist:
            continue
        a_bin = int(round(alias_freq * n / sr))
        if 0 <= a_bin < len(magnitude):
            search = max(2, int(3 * n / sr))
            lo = max(0, a_bin - search)
            hi = min(len(magnitude) - 1, a_bin + search)
            level = np.max(magnitude[lo:hi+1])
            level_dB = 20 * np.log10(level / fund_amp) if level > 1e-30 else -120
            if level_dB > -80:
                aliases.append({
                    "harmonic": h,
                    "source_freq": fund_freq * h,
                    "alias_freq": alias_freq,
                    "level_dB": level_dB,
                })

    # Also check: energy in non-harmonic regions near Nyquist (>15kHz)
    high_noise_mask = (freqs > 15000) & (freqs < nyquist - 100)
    high_region_mag = magnitude[high_noise_mask] if np.any(high_noise_mask) else np.array([0])
    high_noise_db = 20 * np.log10(np.max(high_region_mag) + 1e-30) - 20 * np.log10(fund_amp + 1e-30)

    return {
        "alias_count": len(aliases),
        "aliases": aliases[:10],
        "high_freq_noise_dB": high_noise_db,
        "has_aliasing": len(aliases) > 0 and aliases[0]["level_dB"] > -60,
        "max_harmonic_before_nyquist": max_harmonic,
    }


# ═══════════════════════════════════════════════════════════════════
# 6. ONSET / STUTTER DETECTION
# ═══════════════════════════════════════════════════════════════════

def analyze_onsets(mono: np.ndarray, sr: int) -> dict:
    """Detect unexpected transients (stutters, clicks, re-triggers)."""
    import librosa

    y = mono.astype(np.float32)
    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=512)
    onsets = librosa.onset.onset_detect(y=y, sr=sr, hop_length=512, backtrack=False)
    onset_times = librosa.frames_to_time(onsets, sr=sr, hop_length=512)

    unexpected = []
    if len(onsets) > 1:
        for i, (frame, t) in enumerate(zip(onsets[1:], onset_times[1:])):
            unexpected.append({
                "time_ms": float(t * 1000),
                "strength": float(onset_env[frame]),
            })

    return {
        "onset_count": len(onsets),
        "unexpected_onsets": len(unexpected),
        "onsets": unexpected[:20],
        "has_stutters": len(unexpected) > 0,
    }


# ═══════════════════════════════════════════════════════════════════
# 7. RMS ENVELOPE STABILITY
# ═══════════════════════════════════════════════════════════════════

def analyze_envelope(mono: np.ndarray, sr: int) -> dict:
    """Check RMS envelope for drops, stutters, instability."""
    import librosa

    rms = librosa.feature.rms(y=mono.astype(np.float32),
                               frame_length=1024, hop_length=256)[0]
    rms_db = 20 * np.log10(rms + 1e-30)

    # Skip attack (first 10 frames ~26ms)
    stable = rms_db[10:] if len(rms_db) > 10 else rms_db
    if len(stable) == 0:
        return {"frames": len(rms_db), "stable": True}

    median_level = float(np.median(stable))
    dips = np.where(stable < median_level - 6)[0]
    drops = np.where(stable < median_level - 12)[0]

    return {
        "frames": len(rms_db),
        "median_dB": median_level,
        "stddev_dB": float(np.std(stable)),
        "min_dB": float(np.min(stable)),
        "max_dB": float(np.max(stable)),
        "dips_6dB": len(dips),
        "drops_12dB": len(drops),
        "stable": float(np.std(stable)) < 2.0 and len(drops) == 0,
    }


# ═══════════════════════════════════════════════════════════════════
# 8. WAVEFORM SHAPE FIDELITY (vs ideal saw)
# ═══════════════════════════════════════════════════════════════════

def analyze_waveform_shape(mono: np.ndarray, sr: int, fund_freq: float) -> dict:
    """Compare one period with ideal saw wave."""
    # Find stable region (skip first 1000 samples)
    stable = mono[1000:] if len(mono) > 2000 else mono
    period_samples = int(round(sr / fund_freq))

    # Find saw resets (large negative jumps)
    diffs = np.diff(stable[:5000])
    resets = np.where(diffs < -0.3)[0]

    if len(resets) < 3:
        return {"shape_snr_dB": 0, "measured": False}

    start = resets[2] + 1
    end = start + period_samples
    if end >= len(stable):
        return {"shape_snr_dB": 0, "measured": False}

    one_period = stable[start:end]
    t = np.linspace(0, 1, period_samples, endpoint=False)
    ideal_saw = (2 * t - 1) * np.max(np.abs(one_period))

    error = one_period - ideal_saw
    sig_rms = np.sqrt(np.mean(one_period ** 2))
    err_rms = np.sqrt(np.mean(error ** 2))
    shape_snr = 20 * np.log10(sig_rms / (err_rms + 1e-30))

    return {
        "shape_snr_dB": shape_snr,
        "period_samples": period_samples,
        "error_rms": err_rms,
        "measured": True,
    }


# ═══════════════════════════════════════════════════════════════════
# 9. PERCEPTUAL FEATURES
# ═══════════════════════════════════════════════════════════════════

def analyze_perceptual(mono: np.ndarray, sr: int) -> dict:
    """Spectral centroid, rolloff, flatness, contrast, ZCR, MFCCs."""
    import librosa

    y = mono.astype(np.float32)

    centroid = librosa.feature.spectral_centroid(y=y, sr=sr)[0]
    rolloff85 = librosa.feature.spectral_rolloff(y=y, sr=sr, roll_percent=0.85)[0]
    rolloff99 = librosa.feature.spectral_rolloff(y=y, sr=sr, roll_percent=0.99)[0]
    flatness = librosa.feature.spectral_flatness(y=y)[0]
    contrast = librosa.feature.spectral_contrast(y=y, sr=sr, n_bands=6)
    zcr = librosa.feature.zero_crossing_rate(y, frame_length=1024, hop_length=256)[0]
    mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)

    # Skip attack frames
    stable_cent = centroid[2:] if len(centroid) > 2 else centroid
    stable_flat = flatness[2:] if len(flatness) > 2 else flatness
    stable_zcr = zcr[5:] if len(zcr) > 5 else zcr

    # Brightness: energy above 3kHz
    n = len(y)
    fft = np.fft.rfft(y)
    mag_sq = np.abs(fft) ** 2
    fft_freqs = np.fft.rfftfreq(n, 1.0 / sr)
    bright_mask = fft_freqs >= 3000
    brightness = float(np.sum(mag_sq[bright_mask]) / (np.sum(mag_sq) + 1e-30))

    return {
        "centroid_hz": float(np.mean(stable_cent)),
        "centroid_stddev_hz": float(np.std(stable_cent)),
        "rolloff_85_hz": float(np.mean(rolloff85[2:])) if len(rolloff85) > 2 else 0,
        "rolloff_99_hz": float(np.mean(rolloff99[2:])) if len(rolloff99) > 2 else 0,
        "flatness": float(np.mean(stable_flat)),
        "flatness_max": float(np.max(stable_flat)),
        "zcr_mean": float(np.mean(stable_zcr)),
        "zcr_stddev": float(np.std(stable_zcr)),
        "brightness": brightness,
        "contrast_mean": [float(np.mean(contrast[i])) for i in range(contrast.shape[0])],
        "mfcc_fingerprint": [float(np.mean(mfcc[i])) for i in range(mfcc.shape[0])],
    }


# ═══════════════════════════════════════════════════════════════════
# 10. TEMPORAL ANALYSIS (clicks, zeros, stuck samples)
# ═══════════════════════════════════════════════════════════════════

def analyze_temporal(mono: np.ndarray, sr: int) -> dict:
    """Detect clicks, dropouts, stuck samples, discontinuities."""
    diffs = np.diff(mono)
    abs_diffs = np.abs(diffs)

    median_diff = np.median(abs_diffs)
    if median_diff < 1e-10:
        median_diff = 1e-6

    # Clicks: large jumps relative to median
    click_threshold = max(0.05, median_diff * 10)
    clicks = int(np.sum(abs_diffs > click_threshold))

    # Zero runs
    is_zero = np.abs(mono) < 1e-8
    zero_runs = 0
    max_zero_run = 0
    current_run = 0
    for z in is_zero:
        if z:
            current_run += 1
        else:
            if current_run > 4:
                zero_runs += 1
                max_zero_run = max(max_zero_run, current_run)
            current_run = 0

    # Stuck samples
    stuck = int(np.sum(diffs == 0))
    stuck_ratio = stuck / len(diffs) if len(diffs) > 0 else 0

    return {
        "click_count": clicks,
        "click_threshold": click_threshold,
        "zero_runs": zero_runs,
        "max_zero_run": max_zero_run,
        "stuck_samples": stuck,
        "stuck_ratio": stuck_ratio,
        "max_diff": float(np.max(abs_diffs)),
        "median_diff": float(median_diff),
    }


# ═══════════════════════════════════════════════════════════════════
# 11. STEREO ANALYSIS
# ═══════════════════════════════════════════════════════════════════

def analyze_stereo(samples: np.ndarray) -> dict:
    """L/R correlation, balance, phase."""
    if samples.ndim < 2 or samples.shape[1] < 2:
        return {"stereo": False}

    left, right = samples[:, 0], samples[:, 1]
    corr = float(np.corrcoef(left, right)[0, 1]) if np.std(left) > 1e-10 else 0
    rms_l = np.sqrt(np.mean(left ** 2))
    rms_r = np.sqrt(np.mean(right ** 2))
    balance = 20 * np.log10(rms_l / rms_r) if rms_r > 1e-10 and rms_l > 1e-10 else 0

    return {"stereo": True, "correlation": corr, "balance_dB": balance}


# ═══════════════════════════════════════════════════════════════════
# 12. REFERENCE COMPARISON
# ═══════════════════════════════════════════════════════════════════

def compare_reference(test: np.ndarray, ref: np.ndarray, sr: int) -> dict:
    """Compare test WAV with golden reference."""
    n = min(len(test), len(ref))
    win = np.hanning(n)

    fft_t = np.abs(np.fft.rfft(test[:n] * win))
    fft_r = np.abs(np.fft.rfft(ref[:n] * win))

    fft_t = np.maximum(fft_t, 1e-30)
    fft_r = np.maximum(fft_r, 1e-30)

    diff_dB = 20 * np.log10(fft_t / fft_r)

    # MFCC distance (timbre comparison)
    import librosa
    mfcc_t = np.mean(librosa.feature.mfcc(y=test[:n].astype(np.float32), sr=sr, n_mfcc=13), axis=1)
    mfcc_r = np.mean(librosa.feature.mfcc(y=ref[:n].astype(np.float32), sr=sr, n_mfcc=13), axis=1)
    mfcc_dist = float(np.linalg.norm(mfcc_t - mfcc_r))

    return {
        "max_deviation_dB": float(np.max(np.abs(diff_dB))),
        "rms_deviation_dB": float(np.sqrt(np.mean(diff_dB ** 2))),
        "mfcc_distance": mfcc_dist,
        "pass_1dB": float(np.max(np.abs(diff_dB))) <= 1.0,
        "pass_3dB": float(np.max(np.abs(diff_dB))) <= 3.0,
    }


# ═══════════════════════════════════════════════════════════════════
# PLOTS
# ═══════════════════════════════════════════════════════════════════

def save_plots(samples: np.ndarray, sr: int, spectrum: dict, output_dir: str):
    """Save comprehensive analysis plots."""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import librosa
    import librosa.display

    mono = (samples[:, 0] if samples.ndim == 2 else samples).astype(np.float32)
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    fig, axes = plt.subplots(4, 1, figsize=(14, 16))

    # 1. Waveform
    n_show = min(4000, len(mono))
    t = np.arange(n_show) / sr * 1000
    axes[0].plot(t, mono[:n_show], linewidth=0.4)
    axes[0].set_xlabel("Time (ms)")
    axes[0].set_ylabel("Amplitude")
    axes[0].set_title("Waveform")
    axes[0].grid(True, alpha=0.3)

    # 2. Spectrum (flattop, log scale)
    freqs = spectrum["fft_freqs"]
    mag_db = 20 * np.log10(spectrum["fft_magnitude"] + 1e-30)
    axes[1].plot(freqs[1:], mag_db[1:], linewidth=0.4)
    axes[1].set_xlabel("Frequency (Hz)")
    axes[1].set_ylabel("Magnitude (dB)")
    axes[1].set_title(f"Spectrum (flattop) — THD={spectrum['thd_percent']:.2f}%, "
                      f"SNR={spectrum['snr_dB']:.1f}dB, SINAD={spectrum['sinad_dB']:.1f}dB")
    axes[1].set_xlim(20, sr / 2)
    axes[1].set_ylim(-100, np.max(mag_db) + 5)
    axes[1].set_xscale('log')
    axes[1].grid(True, alpha=0.3)
    for h in spectrum["harmonics"][:20]:
        if h["rel_dB"] > -60:
            axes[1].axvline(h["freq"], color='red', alpha=0.2, linewidth=0.5)

    # 3. Spectrogram
    S = librosa.stft(mono, n_fft=2048, hop_length=512)
    S_db = librosa.amplitude_to_db(np.abs(S), ref=np.max)
    librosa.display.specshow(S_db, sr=sr, hop_length=512, x_axis='time',
                             y_axis='log', ax=axes[2])
    axes[2].set_title("Spectrogram (STFT)")

    # 4. RMS envelope
    rms = librosa.feature.rms(y=mono, frame_length=1024, hop_length=256)[0]
    rms_t = librosa.frames_to_time(np.arange(len(rms)), sr=sr, hop_length=256)
    rms_db = 20 * np.log10(rms + 1e-30)
    axes[3].plot(rms_t, rms_db, linewidth=0.8)
    axes[3].set_xlabel("Time (s)")
    axes[3].set_ylabel("RMS (dB)")
    axes[3].set_title("RMS Envelope")
    axes[3].grid(True, alpha=0.3)

    fig.tight_layout()
    fig.savefig(str(out / "analysis.png"), dpi=150)
    plt.close()
    print(f"  Plots saved to {out}/analysis.png")


# ═══════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════

def print_report(wav_path: str, levels: dict, spectrum: dict, pitch: dict,
                 hpss: dict, aliasing: dict, onsets: dict, envelope: dict,
                 shape: dict, perceptual: dict, temporal: dict, stereo: dict,
                 sr: int, n_samples: int, ref_result: dict = None):
    """Print comprehensive analysis report with professional grading."""

    duration_s = n_samples / sr
    print()
    print("  " + "=" * 70)
    print("  WORLDSYNTH AUDIO ANALYSIS v2 — COMPREHENSIVE REPORT")
    print("  " + "=" * 70)
    print(f"  File: {wav_path}")
    print(f"  {sr}Hz | {duration_s:.3f}s | {n_samples} samples | "
          f"{'stereo' if stereo.get('stereo') else 'mono'}")

    # ── LEVELS ──
    print()
    print("  ── LEVELS " + "─" * 58)
    print(f"  Peak:        {levels['peak']:.4f}  ({levels['peak_dB']:.1f} dBFS)")
    print(f"  RMS:         {levels['rms']:.4f}  ({levels['rms_dB']:.1f} dBFS)")
    print(f"  Crest:       {levels['crest']:.2f}   ({levels['crest_dB']:.1f} dB)")
    print(f"  DC offset:   {levels['dc_offset']:.8f}"
          f"  {'*** HIGH ***' if abs(levels['dc_offset']) > 0.01 else 'OK'}")
    if levels['lufs'] is not None:
        print(f"  LUFS:        {levels['lufs']:.1f} LUFS")

    # ── SPECTRAL (the main course) ──
    print()
    print("  ── SPECTRAL QUALITY " + "─" * 48)
    grade_thd = "EXCELLENT" if spectrum['thd_percent'] < 0.1 else \
                "GUT" if spectrum['thd_percent'] < 1 else \
                "OK" if spectrum['thd_percent'] < 5 else "SCHLECHT"
    grade_snr = "EXCELLENT" if spectrum['snr_dB'] > 90 else \
                "GUT" if spectrum['snr_dB'] > 80 else \
                "OK" if spectrum['snr_dB'] > 60 else "SCHLECHT"
    grade_sinad = "EXCELLENT" if spectrum['sinad_dB'] > 90 else \
                  "GUT" if spectrum['sinad_dB'] > 80 else \
                  "OK" if spectrum['sinad_dB'] > 70 else "SCHLECHT"
    grade_sfdr = "EXCELLENT" if spectrum['sfdr_dB'] > 100 else \
                 "GUT" if spectrum['sfdr_dB'] > 90 else \
                 "OK" if spectrum['sfdr_dB'] > 80 else "SCHLECHT"
    grade_ih = "EXCELLENT" if spectrum['inter_harmonic_snr_dB'] > 80 else \
               "GUT" if spectrum['inter_harmonic_snr_dB'] > 60 else \
               "OK" if spectrum['inter_harmonic_snr_dB'] > 40 else "SCHLECHT"

    print(f"  Fundamental: {spectrum['fundamental_hz']:.2f} Hz "
          f"(error: {spectrum['cent_error']:+.2f} cent)")
    print(f"  THD:         {spectrum['thd_percent']:.3f}%  ({spectrum['thd_dB']:.1f} dB)"
          f"    [{grade_thd}]")
    print(f"  THD+N:       {spectrum['thdn_dB']:.1f} dB")
    print(f"  SNR:         {spectrum['snr_dB']:.1f} dB"
          f"                          [{grade_snr}]")
    print(f"  SINAD:       {spectrum['sinad_dB']:.1f} dB"
          f"                        [{grade_sinad}]")
    print(f"  SFDR:        {spectrum['sfdr_dB']:.1f} dB"
          f"                         [{grade_sfdr}]")
    print(f"  ENOB:        {spectrum['enob']:.1f} bit"
          f"  ({'16-bit CD' if spectrum['enob'] > 16 else '14-bit' if spectrum['enob'] > 14 else 'LOW'})")
    print(f"  Inter-H SNR: {spectrum['inter_harmonic_snr_dB']:.1f} dB"
          f"                   [{grade_ih}]")

    # Harmonics table (first 12)
    print()
    print("  Harm | Freq (Hz) | Level (dB) | Saw ideal | Deviation")
    print("  " + "-" * 60)
    for h in spectrum["harmonics"][:12]:
        dev = h['deviation_dB']
        flag = " ***" if abs(dev) > 3 else ""
        print(f"  H{h['k']:2d}  | {h['freq']:8.1f}  | {h['rel_dB']:+7.1f} dB "
              f"| {h['expected_dB']:+7.1f} dB | {dev:+5.1f} dB{flag}")

    # ── PITCH ──
    print()
    print("  ── PITCH STABILITY " + "─" * 48)
    if pitch.get("voiced_frames", 0) > 0:
        grade_pitch = "EXCELLENT" if pitch['cent_stddev'] < 0.5 else \
                      "GUT" if pitch['cent_stddev'] < 2 else \
                      "OK" if pitch['cent_stddev'] < 5 else "SCHLECHT"
        print(f"  Mean F0:     {pitch['mean_f0']:.2f} Hz (stddev: {pitch['f0_stddev']:.4f} Hz)")
        print(f"  Cent error:  {pitch['cent_mean']:+.2f} (stddev: {pitch['cent_stddev']:.2f})"
              f"    [{grade_pitch}]")
        print(f"  Max dev:     {pitch['cent_max_deviation']:.2f} cent")
        print(f"  Glitches:    {pitch['pitch_glitches']}"
              f"  {'OK' if pitch['pitch_glitches'] == 0 else '*** GLITCH ***'}")
    else:
        print("  No voiced frames detected")

    # ── HPSS ──
    print()
    print("  ── HARMONIC/NOISE SEPARATION " + "─" * 39)
    grade_hpss = "EXCELLENT" if hpss['hp_ratio_dB'] > 40 else \
                 "GUT" if hpss['hp_ratio_dB'] > 30 else \
                 "OK" if hpss['hp_ratio_dB'] > 20 else "SCHLECHT"
    grade_snr2 = "EXCELLENT" if hpss['hr_snr_dB'] > 40 else \
                 "GUT" if hpss['hr_snr_dB'] > 30 else \
                 "OK" if hpss['hr_snr_dB'] > 20 else "SCHLECHT"
    print(f"  H/P ratio:   {hpss['hp_ratio_dB']:.1f} dB"
          f"                       [{grade_hpss}]")
    print(f"  H/R SNR:     {hpss['hr_snr_dB']:.1f} dB"
          f"                       [{grade_snr2}]")
    print(f"  Harmonic:    {hpss['harmonic_dB']:.1f} dB | "
          f"Percussive: {hpss['percussive_dB']:.1f} dB")

    # ── ALIASING ──
    print()
    print("  ── ALIASING " + "─" * 55)
    print(f"  Max harmonic: H{aliasing['max_harmonic_before_nyquist']} "
          f"({aliasing['max_harmonic_before_nyquist'] * spectrum['fundamental_hz']:.0f}Hz)")
    print(f"  Aliases:     {aliasing['alias_count']}"
          f"  {'*** ALIASING ***' if aliasing['has_aliasing'] else 'CLEAN'}")
    print(f"  HF noise:    {aliasing['high_freq_noise_dB']:.1f} dB rel"
          f"  {'OK' if aliasing['high_freq_noise_dB'] < -60 else '*** HIGH ***'}")
    if aliasing['aliases']:
        for a in aliasing['aliases'][:5]:
            print(f"    H{a['harmonic']} ({a['source_freq']:.0f}Hz) → "
                  f"{a['alias_freq']:.0f}Hz: {a['level_dB']:.1f} dB")

    # ── ONSETS / STUTTERS ──
    print()
    print("  ── STUTTER DETECTION " + "─" * 47)
    print(f"  Onsets:      {onsets['onset_count']} total, "
          f"{onsets['unexpected_onsets']} unexpected"
          f"  {'*** STUTTER ***' if onsets['has_stutters'] else 'OK'}")
    for o in onsets.get('onsets', [])[:5]:
        print(f"    @{o['time_ms']:.0f}ms (strength: {o['strength']:.2f})")

    # ── ENVELOPE ──
    print()
    print("  ── RMS ENVELOPE " + "─" * 51)
    print(f"  Median:      {envelope['median_dB']:.1f} dB | "
          f"Stddev: {envelope['stddev_dB']:.2f} dB"
          f"  {'STABLE' if envelope['stable'] else '*** UNSTABLE ***'}")
    print(f"  Range:       {envelope['min_dB']:.1f} → {envelope['max_dB']:.1f} dB")
    print(f"  Dips >6dB:   {envelope['dips_6dB']}  |  Drops >12dB: {envelope['drops_12dB']}")

    # ── WAVEFORM SHAPE ──
    print()
    print("  ── WAVEFORM SHAPE " + "─" * 49)
    if shape.get("measured"):
        grade_shape = "EXCELLENT" if shape['shape_snr_dB'] > 35 else \
                      "GUT" if shape['shape_snr_dB'] > 25 else \
                      "OK" if shape['shape_snr_dB'] > 15 else "SCHLECHT"
        print(f"  Shape SNR:   {shape['shape_snr_dB']:.1f} dB (vs ideal saw)"
              f"     [{grade_shape}]")
        print(f"  (Note: BLEP/ADAA anti-aliasing naturally deviates ~15-25dB)")
    else:
        print("  Could not extract one period for shape analysis")

    # ── PERCEPTUAL ──
    print()
    print("  ── PERCEPTUAL " + "─" * 53)
    print(f"  Centroid:    {perceptual['centroid_hz']:.0f} Hz "
          f"(stddev: {perceptual['centroid_stddev_hz']:.0f}Hz)")
    print(f"  Rolloff 85%: {perceptual['rolloff_85_hz']:.0f} Hz | "
          f"99%: {perceptual['rolloff_99_hz']:.0f} Hz")
    print(f"  Flatness:    {perceptual['flatness']:.6f} "
          f"{'TONAL' if perceptual['flatness'] < 0.001 else 'MIXED' if perceptual['flatness'] < 0.05 else 'NOISY'}")
    print(f"  Brightness:  {perceptual['brightness']*100:.1f}% energy >3kHz")
    print(f"  ZCR:         {perceptual['zcr_mean']:.4f} (stddev: {perceptual['zcr_stddev']:.4f})")

    # ── TEMPORAL ──
    print()
    print("  ── TEMPORAL " + "─" * 55)
    print(f"  Clicks:      {temporal['click_count']}"
          f"  {'OK' if temporal['click_count'] == 0 else '*** CLICKS ***'}")
    print(f"  Zero runs:   {temporal['zero_runs']}"
          f"  {'OK' if temporal['zero_runs'] == 0 else '*** DROPOUTS ***'}")
    print(f"  Stuck:       {temporal['stuck_samples']} ({temporal['stuck_ratio']*100:.1f}%)")

    # ── STEREO ──
    if stereo.get("stereo"):
        print()
        print("  ── STEREO " + "─" * 57)
        print(f"  Correlation: {stereo['correlation']:.4f} "
              f"({'mono' if stereo['correlation'] > 0.99 else 'stereo'})")
        print(f"  Balance:     {stereo['balance_dB']:+.2f} dB")

    # ── REFERENCE ──
    if ref_result:
        print()
        print("  ── REFERENCE COMPARISON " + "─" * 44)
        print(f"  Max spectral deviation: {ref_result['max_deviation_dB']:.1f} dB"
              f"  {'PASS' if ref_result['pass_1dB'] else 'FAIL >1dB'}")
        print(f"  RMS deviation: {ref_result['rms_deviation_dB']:.1f} dB")
        print(f"  MFCC distance: {ref_result['mfcc_distance']:.2f}"
              f"  ({'identical' if ref_result['mfcc_distance'] < 5 else 'similar' if ref_result['mfcc_distance'] < 20 else 'different'})")

    # ═══════════════════════════════════════════════════════════════
    # SCORECARD
    # ═══════════════════════════════════════════════════════════════
    print()
    print("  " + "=" * 70)
    print("  SCORECARD")
    print("  " + "=" * 70)

    metrics = [
        ("THD",            spectrum['thd_dB'],                 -60, -40, "dB", True),
        ("SNR",            spectrum['snr_dB'],                  80,  60, "dB", False),
        ("SINAD",          spectrum['sinad_dB'],                80,  60, "dB", False),
        ("SFDR",           spectrum['sfdr_dB'],                 90,  70, "dB", False),
        ("Inter-H SNR",    spectrum['inter_harmonic_snr_dB'],   60,  40, "dB", False),
        ("Pitch (cents)",  abs(pitch.get('cent_mean', 99)),    0.5, 2.0, "ct", True),
        ("H/P Ratio",      hpss['hp_ratio_dB'],                40,  20, "dB", False),
        ("Spectral Flat.",  perceptual['flatness'],          0.001, 0.01, "",  True),
        ("Shape SNR",       shape.get('shape_snr_dB', 0),      35,  15, "dB", False),
        ("Envelope Std",    envelope.get('stddev_dB', 99),     1.0, 3.0, "dB", True),
    ]

    total_score = 0
    max_score = 0
    for name, val, excellent, good, unit, lower_is_better in metrics:
        max_score += 10
        if lower_is_better:
            if val <= excellent:
                grade, score = "EXCELLENT", 10
            elif val <= good:
                grade, score = "GUT", 7
            else:
                grade, score = "SCHLECHT", 3
        else:
            if val >= excellent:
                grade, score = "EXCELLENT", 10
            elif val >= good:
                grade, score = "GUT", 7
            else:
                grade, score = "SCHLECHT", 3

        total_score += score
        bar = "#" * score + "." * (10 - score)
        print(f"  {name:16s} {val:8.2f} {unit:2s}  [{bar}] {grade}")

    pct = total_score / max_score * 100
    print(f"\n  TOTAL: {total_score}/{max_score} ({pct:.0f}%)"
          f"  {'PROFESSIONAL' if pct >= 90 else 'GUT' if pct >= 70 else 'VERBESSERUNGSBEDARF'}")
    print("  " + "=" * 70)
    print()


# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="WorldSynth Audio Analyzer v2 — Comprehensive Digital Ears")
    parser.add_argument("wav_file", help="Path to WAV file")
    parser.add_argument("--expected-freq", type=float, default=261.63,
                        help="Expected fundamental frequency (default: 261.63 = C4)")
    parser.add_argument("--plot", action="store_true", help="Save analysis plots")
    parser.add_argument("--plot-dir", default="/tmp/worldsynth-plots",
                        help="Plot output directory")
    parser.add_argument("--reference", help="Golden reference WAV for comparison")
    parser.add_argument("--active-only", action="store_true",
                        help="Analyze only the active audio region (skip silence)")
    args = parser.parse_args()

    if not Path(args.wav_file).exists():
        print(f"Error: {args.wav_file} not found")
        sys.exit(1)

    # Load
    samples, sr = load_wav(args.wav_file)
    n_samples = samples.shape[0]
    mono = samples[:, 0] if samples.ndim == 2 else samples

    print(f"  Loaded: {args.wav_file} ({sr}Hz, {n_samples} samples, "
          f"{n_samples/sr:.3f}s, {'stereo' if samples.ndim == 2 else 'mono'})")

    # Optionally crop to active region
    if args.active_only:
        start, end, mono = get_active_region(mono)
        # Skip 1000 samples of attack transient for stable analysis
        skip = min(1000, len(mono) // 4)
        mono = mono[skip:]
        print(f"  Active region: samples {start+skip}..{end} ({len(mono)} samples)")

    # Run all analyses
    levels = analyze_levels(samples, sr)
    spectrum = analyze_spectrum(mono, sr, args.expected_freq)
    pitch = analyze_pitch(mono, sr, args.expected_freq)
    hpss = analyze_hpss(mono, sr)
    aliasing = analyze_aliasing(mono, sr, spectrum['fundamental_hz'])
    onsets = analyze_onsets(mono, sr)
    envelope = analyze_envelope(mono, sr)
    shape = analyze_waveform_shape(mono, sr, spectrum['fundamental_hz'])
    perceptual = analyze_perceptual(mono, sr)
    temporal = analyze_temporal(mono, sr)
    stereo = analyze_stereo(samples)

    # Reference comparison
    ref_result = None
    if args.reference and Path(args.reference).exists():
        ref_samples, ref_sr = load_wav(args.reference)
        ref_mono = ref_samples[:, 0] if ref_samples.ndim == 2 else ref_samples
        ref_result = compare_reference(mono, ref_mono, sr)

    # Report
    print_report(args.wav_file, levels, spectrum, pitch, hpss, aliasing,
                 onsets, envelope, shape, perceptual, temporal, stereo,
                 sr, n_samples, ref_result)

    # Plots
    if args.plot:
        save_plots(samples, sr, spectrum, args.plot_dir)

    # Exit code
    issues = sum([
        abs(levels['dc_offset']) > 0.01,
        temporal['click_count'] > 5,
        temporal['zero_runs'] > 0,
        spectrum['snr_dB'] < 40,
        aliasing['has_aliasing'],
    ])
    sys.exit(1 if issues > 0 else 0)


if __name__ == "__main__":
    main()

# WorldSynth

[![Status: Pre-Alpha](https://img.shields.io/badge/Status-Pre--Alpha-red.svg)]()
[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-red.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-orange.svg)]()
[![Plugin: CLAP](https://img.shields.io/badge/Plugin-CLAP%201.2-blue.svg)](https://cleveraudio.org/)
[![DSP: Zig](https://img.shields.io/badge/DSP-Zig%200.14-orange.svg)](https://ziglang.org/)
[![UI: Svelte 5](https://img.shields.io/badge/UI-Svelte%205-ff3e00.svg)](https://svelte.dev/)

Professional multi-engine synthesizer with 11 synthesis engines, Zig DSP backend, Svelte 5 UI, and CLAP plugin support.

> **Status: Pre-Alpha** — WorldSynth is currently in active development. No public builds are available yet.
> Watch this repository or follow the [Releases](https://github.com/silentspike/worldsynth/releases) page
> to be notified when the first builds become available.

## Features

### 11 Synthesis Engines

| Engine | Description |
|--------|-------------|
| Subtractive | Hybrid anti-aliased oscillators (ADAA + BLEP) with ZDF filters |
| FM | Free 3x3 operator matrix, PM + true FM |
| Wavetable | Mip-mapped, ADAA, Hermite interpolation, in-app editor |
| Granular | Grain synthesis with real-time cloud visualizer and live capture |
| Spectral | FFT freeze/blur/shift/gate/morph with resynthesis |
| Physical Modeling | Karplus-Strong, bow, blow, strike |
| Phase Distortion | CZ-style synthesis |
| Formant | Vowel synthesis with morphable vocal targets |
| Sample | Single-cycle, multi-sample, loop playback |
| Neural (RAVE/DDSP) | Latent-space navigation with GPU inference (CUDA) |
| Genetic Breed | Evolutionary sound design via crossover and mutation |

### Sound Architecture

- **64 voices** with 16 unison per note, per-voice panning and analog drift
- **6 filter types**: SVF, Moog Ladder, Comb, Formant, Phaser, Diode (ZDF topology, f64 precision)
- **Modulation**: 256-slot matrix, 32 audio-rate LFOs, 16 MSEGs, chaos modulators, 8 macros
- **Effects**: FDN reverb, convolution (GPU), delay, chorus, distortion, EQ, vocoder, stereo widener
- **Arpeggiator** with ratchet and probability, **clip sequencer** with parameter locks
- **8 scenes** with morphing, N-preset morph space (Wasserstein optimal transport)
- **Quality governor**: Live / Studio / Render modes

### Technology

- **DSP**: Zig 0.14.x — f32 pipeline, f64 ZDF filter integrators, SIMD vectorization, comptime LUTs
- **UI**: Svelte 5 (Runes) + Vite + TypeScript, WebKitGTK WebView, dark theme with neon accents
- **Plugin**: CLAP 1.2.7 with hand-written bindings, per-note modulation, thread-pool extension
- **Audio**: JACK (PipeWire), ALSA direct, multi-output (stereo + 8 aux)
- **Threading**: Lock-free work-stealing thread pool, dual-mode scheduling

### Accessibility

- Native screenreader support (ARIA labels on all controls)
- Full keyboard navigation (Tab/Shift-Tab/Arrows/Enter)
- High-contrast and colorblind modes
- Scalable UI (125%/150%/200%)

## Download

> No builds available yet. WorldSynth is in active development.

When builds become available, they will be published on the [Releases](https://github.com/silentspike/worldsynth/releases) page.

### System Requirements

- Linux (x86_64) with JACK or PipeWire
- NVIDIA GPU with CUDA 12.x (optional, for neural engine and GPU convolution)

### Formats

- **CLAP Plugin** (Bitwig, REAPER, and other CLAP-compatible DAWs)
- **Standalone** application with JACK/ALSA support

## Community

- **Bug Reports**: Use [Issues](https://github.com/silentspike/worldsynth/issues/new?template=bug_report.yml) to report bugs
- **Feature Requests**: Use [Issues](https://github.com/silentspike/worldsynth/issues/new?template=feature_request.yml) to suggest features
- **Security**: See [SECURITY.md](SECURITY.md) for vulnerability reporting

## License

WorldSynth is proprietary software. See [LICENSE](LICENSE) for the full End User License Agreement.

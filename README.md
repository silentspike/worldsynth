# WorldSynth

[![Status: Pre-Alpha](https://img.shields.io/badge/Status-Pre--Alpha-red.svg)]()
[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-red.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-orange.svg)]()

> **Project Status: Pre-Alpha / Planning Phase**
>
> This repository currently contains project infrastructure (CI/CD, issue templates, governance).
> No production code has been written yet. The [143 open issues](https://github.com/silentspike/worldsynth/issues)
> represent the planned work packages across 4 sprints. Implementation starts with Sprint 1.

Professional multi-engine synthesizer with Zig DSP backend, Svelte 5 UI, and CLAP plugin support.

## Planned Features

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
- **DSP**: Zig 0.14.x — f32 pipeline, f64 ZDF filter integrators, `@Vector` SIMD, comptime LUTs
- **UI**: Svelte 5 (Runes) + Vite + TypeScript strict, WebKitGTK WebView
- **Plugin**: CLAP 1.2.7 with hand-written bindings, per-note modulation, thread-pool extension
- **Audio**: JACK (PipeWire), ALSA direct, multi-output (stereo + 8 aux)
- **Threading**: Lock-free work-stealing thread pool, dual-mode scheduling (standalone SCHED_FIFO / plugin CLAP thread-pool)
- **IPC**: WebKitGTK UserMessage API, CQRS + MVCC, FlatBuffers, triple-buffered scope rendering

### Accessibility
- Native screenreader support (ARIA labels on all controls)
- Full keyboard navigation (Tab/Shift-Tab/Arrows/Enter)
- High-contrast and colorblind modes
- Scalable UI (125%/150%/200%)

## Requirements

- [Zig 0.14.x](https://ziglang.org/download/)
- [Node.js 22+](https://nodejs.org/) (for UI development)
- Linux with JACK or PipeWire
- NVIDIA GPU with CUDA 12.x (optional, for neural engine)

## Build (once code is available)

```bash
# DSP backend
zig build

# Run tests
zig build test

# UI (development)
cd ui
npm ci
npm run dev

# UI (production build)
cd ui
npm run build
npm run check
```

> **Note:** These commands will work once Sprint 1 implementation begins.
> See the [milestone tracker](https://github.com/silentspike/worldsynth/milestones) for progress.

## Architecture

```
Svelte 5 UI (WebKitGTK WebView)
    |  WebKitGTK UserMessage API (CQRS + MVCC)
    |  Triple-Buffered Scope Rendering
DSP Engine (Zig, f32 pipeline, f64 ZDF filters)
    |  Lock-free Work-Stealing Thread Pool
    |  @Vector SIMD, comptime LUTs, 128-sample blocks
Audio I/O (JACK / PipeWire / ALSA)
    |  CLAP Plugin  |  Standalone
    |  thread-pool  |  SCHED_FIFO
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow and guidelines.

## License

This project is proprietary software. See [LICENSE](LICENSE) for the full End User License Agreement.

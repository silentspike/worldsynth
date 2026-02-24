# WorldSynth - Project Instructions

## TL;DR
- Zig 0.14.x, f32 pipeline, f64 ONLY for ZDF filter integrators
- Svelte 5 with Runes ($state/$derived/$effect), TypeScript strict
- CLAP hand-written bindings (NEVER @cImport)
- Verify: `zig build` + `zig build test` + `cd ui && npm run build` + `cd ui && npm run check`
- Conventional Commits, feature branches, PRs against main
- ZERO heap allocation in audio thread
- Production-First: no mocks, no stubs, no placeholders

## Quick Reference

| Action | Command |
|--------|---------|
| Zig Build | `zig build` |
| Zig Test | `zig build test` |
| UI Build | `cd ui && npm run build` |
| UI TypeCheck | `cd ui && npm run check` |
| UI Dev Server | `cd ui && npm run dev` |
| Full Verify | `zig build && zig build test && cd ui && npm run build && cd ui && npm run check` |

## Critical Rules

### NEVER
- Heap allocate in the audio thread (no allocator.alloc, no ArrayList.append in RT path)
- Use @cImport (hand-written bindings for CLAP, ALSA, JACK, WebKitGTK)
- Use f64 outside ZDF filter integrators and slow LFOs
- Use blocking calls in audio thread (no mutex.lock, no file I/O, no syscalls)
- Share mutable state between audio and UI threads (use MVCC / atomic swap)
- Write UI code that fails `npm run check`
- Use Svelte 4 syntax (only Runes: $state, $derived, $effect)
- Commit directly to main
- Commit secrets (.env, *.key, *.pem, API keys)

### ALWAYS
- Use preallocated buffers and arenas for RT code
- Use @Vector SIMD for block processing (128 samples)
- Use comptime for LUTs and lookup tables
- Add ARIA labels to all interactive UI elements
- Run all 4 verify commands before every commit
- Use Conventional Commits (feat/fix/docs/refactor/test/ci/chore/deps/security)
- Write tests for new functionality

## Architecture

```
Svelte 5 UI (WebKitGTK WebView, Dark Theme, Neon-Mix Colors)
    |  WebKitGTK UserMessage API
    |  Commands (UI->DSP): FlatBuffers
    |  Queries (DSP->UI): Triple-Buffered Atomic Swap
DSP Engine (Zig, f32 pipeline, f64 ZDF filters)
    |  11 Engines, 6 Filters, 64 Voices, 16 Unison
    |  Mod-Matrix (256 slots, preallocated arena)
    |  Lock-free Work-Stealing Thread Pool
    |  @Vector SIMD, comptime LUTs, 128-sample blocks
Audio I/O
    |  CLAP Plugin (thread-pool ext)  |  Standalone (SCHED_FIFO)
    |  JACK / PipeWire / ALSA         |  MIDI 1.0 + MPE + MIDI 2.0
```

### Thread Model
- **Audio Thread**: Dispatcher, SCHED_FIFO (standalone) / CLAP thread-pool (plugin)
- **Worker Threads**: Voice/layer processing, lock-free work-stealing
- **GPU Thread**: CUDA - neural inference, convolution, spectral (double-buffered)
- **IO Thread**: io_uring file I/O, OSC, Ableton Link

### Precision Rules
- f32: oscillators, effects, mixing, modulation, SIMD blocks
- f64: ZDF filter integrators (SVF, Ladder, Diode, Phaser, Formant), slow LFOs

### UI Theme
- Dark only: #252525 base
- Cyan (#00e5ff) = oscillators
- Magenta (#e040fb) = filters
- Green (#69f0ae) = modulation
- Orange (#ff9100) = effects
- Yellow (#ffea00) = master

## Naming Conventions

| Context | Convention | Example |
|---------|-----------|---------|
| Zig functions/variables | snake_case | `process_block`, `sample_rate` |
| Zig types/structs | PascalCase | `VoicePool`, `FilterState` |
| Svelte components | PascalCase | `Knob.svelte`, `Oscilloscope.svelte` |
| TypeScript functions | camelCase | `sendCommand`, `getParamValue` |
| CSS classes | kebab-case | `knob-container`, `mod-matrix` |
| File names (Zig) | snake_case.zig | `voice_pool.zig`, `fm_engine.zig` |
| File names (Svelte) | PascalCase.svelte | `ModMatrix.svelte` |

## Commit Convention

| Prefix | Usage |
|--------|-------|
| feat | New feature |
| fix | Bug fix |
| docs | Documentation only |
| style | Formatting, no logic change |
| refactor | Code restructuring |
| perf | Performance improvement |
| test | Adding or updating tests |
| build | Build system changes |
| ci | CI/CD configuration |
| chore | Other maintenance |
| deps | Dependency updates |
| security | Security fixes |

## Branch Naming
- `feat/description` - new features
- `fix/description` - bug fixes
- `docs/description` - documentation
- `ci/description` - CI/CD changes
- `refactor/description` - refactoring

## File Structure

```
/work/daw/synth/
  build.zig                  # Zig build system
  build.zig.zon              # Dependencies + Zig version pin
  src/
    main.zig                 # Standalone entry point
    engine/                  # Audio engine, tables, params, presets
    dsp/                     # Oscillators, filters, envelopes, effects, voices
    io/                      # CLAP, JACK, ALSA, MIDI, IPC, OSC
    threading/               # Thread pool, ring buffer, barrier, deque
    platform/                # RT-thread, hardware detection
  ui/
    package.json             # Svelte 5 + Vite + TypeScript
    src/
      App.svelte             # Root component
      lib/                   # Reusable components (Knob, Slider, Scopes, etc.)
      sections/              # Tab layouts (SynthTab, FxTab, ModTab)
      stores/                # CQRS parameter state, MIDI, presets
  clap-sdk/                  # CLAP C headers (git submodule)
```

## Evidence Protocol

Every claim of "working" or "tested" requires:
- Exact command executed
- Actual output received
- NOT evidence: "code looks correct", line number references, "structure exists"
- Default status of any acceptance criterion: UNTESTED
- No command executed = UNTESTED, not PASS

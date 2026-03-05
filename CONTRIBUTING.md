# Contributing

Thank you for considering contributing to WorldSynth.

## Development Setup

### Requirements
- [Zig 0.14.x](https://ziglang.org/download/)
- [Node.js 22+](https://nodejs.org/)
- Linux with JACK or PipeWire

### Build & Test
```bash
# DSP backend
zig build
scripts/test-parallel.sh

# UI
cd ui
npm ci
npm run build
npm run check
```

### Parallel Test Runner

`scripts/test-parallel.sh` splits the Zig test suite into deterministic shards
and runs them in parallel. The `build-zig` CI job on the self-hosted
`worldsynth` runner uses the same script, so local and remote behavior match.

```bash
# Default (auto workers, capped to keep runners stable)
scripts/test-parallel.sh

# Baseline timing (serial)
scripts/test-parallel.sh --jobs 1

# Explicit worker count
scripts/test-parallel.sh --jobs "$(nproc)"

# Run only specific shards
scripts/test-parallel.sh --jobs 4 --shards "engine.,io.midi.test,dsp.utilities.oversampling.test"
```

Troubleshooting:
- Failing shard output is printed automatically (first lines of log).
- To isolate a flaky module, rerun only that shard via `--shards`.
- Shard definitions live in `scripts/test-shards.txt`.

## How to Contribute

### Reporting Bugs
- Use the [Bug Report](../../issues/new?template=bug_report.yml) template
- Include steps to reproduce with exact commands
- Include expected vs actual behavior (measurable)

### Suggesting Features
- Use the [Feature Request](../../issues/new?template=feature_request.yml) template
- Describe the problem you are solving, not just the solution

### Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Make your changes
4. Run all quality gates:
   ```bash
   zig build
   scripts/test-parallel.sh
   cd ui && npm run build
   cd ui && npm run check
   ```
5. Commit using [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat: add wavetable morph curves`
   - `fix: resolve SVF filter stability at low cutoff`
   - `docs: update MIDI configuration guide`
6. Push and create a Pull Request against `main`

### Commit Convention

| Prefix | Usage |
|--------|-------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Formatting, no code change |
| `refactor` | Code refactoring |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `build` | Build system or dependencies |
| `ci` | CI/CD configuration |
| `chore` | Other maintenance |
| `deps` | Dependency updates |
| `security` | Security fixes |

### Code Style

- **Zig**: `snake_case` for functions/variables, `PascalCase` for types
- **Svelte/TypeScript**: `PascalCase` for components, `camelCase` for functions
- **CSS**: `kebab-case`
- Run linters before committing
- Follow existing code patterns

### Audio Thread Rules

Code running in the audio thread must:
- Never allocate heap memory
- Never use blocking calls (mutex, file I/O)
- Use preallocated buffers and arenas
- Process in 128-sample blocks with `@Vector` SIMD

## License

By contributing, you agree that your contributions will be licensed under the project's proprietary license. See [LICENSE](LICENSE) for details.

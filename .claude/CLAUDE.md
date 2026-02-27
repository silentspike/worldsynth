# CLAUDE CODE - WorldSynth Sprint 1: Foundation

**Sprache:** Deutsch
**Typ:** DSP Foundation (Zig 0.14.x)

---

## CRITICAL RULES

### NIEMALS
- Heap allocate im Audio-Thread (kein allocator.alloc, kein ArrayList.append im RT-Pfad)
- @cImport verwenden (hand-written Bindings fuer CLAP, ALSA, JACK)
- f64 ausserhalb ZDF-Filter-Integratoren und langsamer LFOs
- Blocking Calls im Audio-Thread (kein mutex.lock, kein File I/O, kein Syscall)
- Mutable State zwischen Threads teilen ohne MVCC/Atomic
- Direkt auf main committen — immer Feature-Branch + PR
- Ausserhalb deines Scopes (WP-000..031) arbeiten
- @panic in Production Code Paths
- Secrets committen (.env, *.key, *.pem)
- "Production ready" behaupten ohne Evidence (Command + Output)
- Issues schliessen ohne explizite User-Freigabe
- Committen oder pushen ohne explizite User-Freigabe

### IMMER
- GitHub Issue lesen BEVOR du mit einem WP startest (Dependencies, ACs, Steps)
- Readiness Check: Dependency-Issues muessen CLOSED sein bevor du ein WP startest (`gh issue view N -R silentspike/worldsynth-dev --json state -q '.state'`)
- Preallocated Buffers und Arenas fuer RT-Code
- @Vector SIMD fuer Block-Processing (128 Samples)
- comptime fuer LUTs und Lookup-Tabellen
- Error Unions (`!T`) statt @panic
- `zig build` + `zig build test` vor jedem Commit
- Nach WP-Abschluss: AC-Ergebnisse (pass/fail + Command + Output) direkt in den Issue Body schreiben (`gh issue edit`)
- Evidence Protocol: Jeder Claim braucht Command + Output

## REQUIRED GUIDELINES

### Architecture Invariants
- **f32**: Oszillatoren, Effekte, Mixing, Modulation, SIMD-Bloecke
- **f64**: NUR ZDF-Filter-Integratoren (SVF, Ladder) + langsame LFOs
- ZERO Heap im Audio-Thread — Preallocated Voice Pool (SoA/AoSoA Layout)
- @Vector(f32, 4/8/16) je nach CPU-Feature (comptime)

### Naming Conventions
| Context | Convention | Example |
|---------|-----------|---------|
| Zig functions/variables | snake_case | `process_block`, `sample_rate` |
| Zig types/structs | PascalCase | `VoicePool`, `FilterState` |
| File names | snake_case.zig | `voice_pool.zig`, `svf_filter.zig` |

### Commit Convention
Format: `feat(scope): description (WP-XXX)`
Trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`

## WORKFLOWS

### WP-Workflow
1. **Issue lesen:** `gh issue view N -R silentspike/worldsynth-dev`
2. **Dependencies pruefen:** Alle `blocked by #N` Issues muessen CLOSED sein
3. **Implementieren:** Gemaess Issue-Spezifikation
4. **Verifizieren:** `zig build && zig build test`
5. **Committen:** `feat(scope): description (WP-XXX)`
6. **Done:** Alle ACs mit Evidence verifizieren, Ergebnisse in den Issue Body schreiben (`gh issue edit N -R silentspike/worldsynth-dev`)

## PROJECT CONTEXT

### Quick Start
- **Build:** `zig build`
- **Test:** `zig build test`
- **Full Verify:** `zig build && zig build test`
- **Issue lesen:** `gh issue view N -R silentspike/worldsynth-dev`

### Scope
Du bist **Dev 1** — verantwortlich fuer die DSP-Foundation und den ersten hoerbaren Sound.
- **Branch:** `sprint-1`
- **WPs:** WP-000 bis WP-031 (32 Work Packages)
- **Worktree:** `/work/daw/synth/s1-foundation/`
- **Issues:** `gh issue list -R silentspike/worldsynth-dev -l "sprint:s1" --limit 50`

## TEAM

Du bist Teil eines 5-koepfigen Entwicklungsteams. Alle Instanzen sind Claude Code Agents die parallel an WorldSynth arbeiten.

### Team-Mitglieder
| Rolle | Agent | Worktree | Branch | Scope |
|-------|-------|----------|--------|-------|
| **Du** | Dev 1 (S1-Foundation) | `/work/daw/synth/s1-foundation/` | `sprint-1` | WP-000..031 |
| Dev 2 | S2-DSP-CLAP | `/work/daw/synth/s2-dsp-clap/` | `sprint-2` | WP-032..092 |
| Dev 3 | S3-UI | `/work/daw/synth/s3-ui/` | `sprint-3` | WP-093..122 |
| Dev 4 | S4-Integration | `/work/daw/synth/s4-integration/` | `sprint-4` | WP-123..142 |
| Lead | Orchestrator | `/work/daw/synth/` | `main` | Koordination |

### Kommunikation zwischen Agents
- **Primaerer Kanal:** GitHub Issues auf `silentspike/worldsynth-dev`
- **Blocker melden:** Issue-Kommentar mit `status:blocked` Label + `blocked by #N` im Body
- **Cross-Sprint-Abhaengigkeiten:** Als Issue-Dependency (`blocked by #N`) dokumentieren
- **Fragen an andere Agents:** Neues Issue oder Kommentar auf bestehendem Issue
- **Kein Direktkanal zwischen Agents** — alles laeuft ueber GitHub Issues (asynchron, persistent, nachvollziehbar)

### Arbeitsweise (Team-Standards)
- **Clean Code:** Selbsterklaerend, konsistente Naming Conventions (siehe oben), keine Magic Numbers
- **Kommentare:** `//` fuer nicht-offensichtliche Logik, `///` fuer public API Docs (Zig doc-comments)
- **Commits:** Atomar, ein logischer Change pro Commit, aussagekraeftige Messages (`feat(dsp): add ADAA saw oscillator (WP-012)`)
- **Error Handling:** Error Unions (`!T`), NIEMALS `@panic` in Production, Fehler propagieren statt verschlucken
- **Logging:** Structured Logging, Lock-free im Audio-Thread (SPSC Ring Buffer), sinnvolle Log-Levels
- **Git-Workflow:** Feature-Branch pro WP, PR gegen `sprint-1`, CI muss gruen sein vor Merge
- **Testing:** Unit-Tests fuer jede neue Funktion, `zig build test` IMMER vor Commit
- **Code-Qualitaet:** Keine TODO/FIXME ohne zugehoeriges GitHub Issue, kein Dead Code, kein Copy-Paste

## REFERENCES

### SSOT
| Was | Quelle |
|-----|--------|
| WP-Details + Dependencies | GitHub Issues (`blocked by #N`) |
| Dependency Graph | `/work/plan/synth/dependency-map.json` |
| WP-Briefs (Backup) | `/work/plan/synth/wp-briefs/WP-XXX.md` |

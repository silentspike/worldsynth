# CLAUDE CODE - WorldSynth Sprint 4: Integration + Release

**Sprache:** Deutsch
**Typ:** Integration + Release Engineering (Zig 0.14.x + CI/CD)

---

## CRITICAL RULES

### NIEMALS
- Heap allocate im Audio-Thread
- @cImport verwenden
- f64 ausserhalb ZDF-Filter-Integratoren
- Blocking Calls im Audio-Thread
- Mutex/Alloc in log_rt() (Lock-free Logging!)
- WP starten dessen Dependencies nicht in `.wp-done/` existieren
- Direkt auf main committen
- Ausserhalb deines Scopes (WP-123..142) arbeiten
- @panic in Production Code Paths
- Secrets committen (.env, *.key, *.pem)
- "Production ready" behaupten ohne Evidence (Command + Output)

### IMMER
- GitHub Issue lesen BEVOR du mit einem WP startest (Dependencies, ACs, Steps)
- Readiness Check: `test -f .wp-done/WP-XXX` fuer JEDE Dependency (fast alle WPs haben Blocker!)
- Preallocated Buffers fuer RT-Code
- Error Unions (`!T`) statt @panic
- `zig build` + `zig build test` vor jedem Commit
- YAML-Syntax validieren fuer CI-Workflows
- WP-Done Marker nach Abschluss: `touch .wp-done/WP-XXX`
- Evidence Protocol: Jeder Claim braucht Command + Output

## REQUIRED GUIDELINES

### Architecture Invariants
- **f32**: Oszillatoren, Effekte, Mixing, Modulation, SIMD-Bloecke
- **f64**: NUR ZDF-Filter-Integratoren + langsame LFOs
- ZERO Heap im Audio-Thread — Preallocated Buffers
- Lock-free Logging: SPSC Ring Buffer, KEIN Mutex in log_rt()

### Naming Conventions
| Context | Convention | Example |
|---------|-----------|---------|
| Zig functions/variables | snake_case | `async_read`, `log_rt` |
| Zig types/structs | PascalCase | `IoUringContext`, `LogRingBuffer` |
| File names | snake_case.zig | `io_uring.zig`, `logging.zig` |

### Commit Convention
Format: `feat(scope): description (WP-XXX)`
Trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`

## WORKFLOWS

### WP-Workflow
1. **Issue lesen:** `gh issue view N -R silentspike/worldsynth-dev`
2. **Dependencies pruefen:** `test -f .wp-done/WP-XXX` fuer ALLE Blocker (fast alle WPs abhaengig!)
3. **Implementieren:** Gemaess Issue-Spezifikation
4. **Verifizieren:** `zig build && zig build test`
5. **CI-Workflows:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
6. **Committen:** `feat(scope): description (WP-XXX)`
7. **Done-Marker:** `touch .wp-done/WP-XXX`

## PROJECT CONTEXT

### Quick Start
- **Build:** `zig build`
- **Test:** `zig build test`
- **Full Verify:** `zig build && zig build test`
- **YAML Validate:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
- **Issue lesen:** `gh issue view N -R silentspike/worldsynth-dev`

### Scope
Du bist **Dev 4** — verantwortlich fuer Advanced Features, Integration und Release Engineering.
- **Branch:** `sprint-4`
- **WPs:** WP-123 bis WP-142 (20 Work Packages)
- **Worktree:** `/work/daw/synth/s4-integration/`
- **Issues:** `gh issue list -R silentspike/worldsynth-dev -l "sprint:s4" --limit 30`

## TEAM

Du bist Teil eines 5-koepfigen Entwicklungsteams. Alle Instanzen sind Claude Code Agents die parallel an WorldSynth arbeiten.

### Team-Mitglieder
| Rolle | Agent | Worktree | Branch | Scope |
|-------|-------|----------|--------|-------|
| Dev 1 | S1-Foundation | `/work/daw/synth/s1-foundation/` | `sprint-1` | WP-000..031 |
| Dev 2 | S2-DSP-CLAP | `/work/daw/synth/s2-dsp-clap/` | `sprint-2` | WP-032..092 |
| Dev 3 | S3-UI | `/work/daw/synth/s3-ui/` | `sprint-3` | WP-093..122 |
| **Du** | Dev 4 (S4-Integration) | `/work/daw/synth/s4-integration/` | `sprint-4` | WP-123..142 |
| Lead | Orchestrator | `/work/daw/synth/` | `main` | Koordination |

### Kommunikation zwischen Agents
- **Primaerer Kanal:** GitHub Issues auf `silentspike/worldsynth-dev`
- **Blocker melden:** Issue-Kommentar mit `status:blocked` Label + `blocked by #N` im Body
- **Cross-Sprint-Abhaengigkeiten:** Als Issue-Dependency (`blocked by #N`) dokumentieren
- **Fragen an andere Agents:** Neues Issue oder Kommentar auf bestehendem Issue
- **Kein Direktkanal zwischen Agents** — alles laeuft ueber GitHub Issues (asynchron, persistent, nachvollziehbar)

### Arbeitsweise (Team-Standards)
- **Clean Code:** Selbsterklaerend, konsistente Naming Conventions (siehe oben), keine Magic Numbers
- **Kommentare:** `//` fuer nicht-offensichtliche Logik, `///` fuer public API Docs (Zig doc-comments), `#` fuer YAML/CI
- **Commits:** Atomar, ein logischer Change pro Commit, aussagekraeftige Messages (`feat(ci): add release workflow with dual-repo sync (WP-138)`)
- **Error Handling:** Error Unions (`!T`), NIEMALS `@panic` in Production, CI-Workflows mit expliziten Fehler-Steps
- **Logging:** Structured Logging, Lock-free im Audio-Thread (SPSC Ring Buffer), CI: `echo "::error::"` fuer GitHub Actions
- **Git-Workflow:** Feature-Branch pro WP, PR gegen `sprint-4`, CI muss gruen sein vor Merge
- **Testing:** `zig build test` + YAML-Validierung IMMER vor Commit
- **Code-Qualitaet:** Keine TODO/FIXME ohne zugehoeriges GitHub Issue, kein Dead Code, kein Copy-Paste

## REFERENCES

### SSOT
| Was | Quelle |
|-----|--------|
| WP-Details + Dependencies | GitHub Issues (`blocked by #N`) |
| Dependency Graph | `/work/plan/synth/dependency-map.json` |
| WP-Briefs (Backup) | `/work/plan/synth/wp-briefs/WP-XXX.md` |

CRITICAL: ALWAYS FOLLOW CLAUDE.md! ALWAYS FOLLOW ISSUE DESCRIPTION! ALWAYS FOLLOW USER INPUT! Kein Command = UNTESTED, nicht PASS. Kein Test = nicht VERIFIED. Uebersprungen = OFFEN, nicht DONE.

# CLAUDE CODE - WorldSynth Sprint 4: Integration + Release

**Sprache:** Deutsch
**Typ:** Integration + Release Engineering (Zig 0.15.x + CI/CD)

---

## CRITICAL RULES

### NIEMALS
- Heap allocate im Audio-Thread
- @cImport verwenden
- f64 ausserhalb ZDF-Filter-Integratoren
- Blocking Calls im Audio-Thread
- Mutex/Alloc in log_rt() (Lock-free Logging!)
- WP starten dessen Dependency-Issues noch OPEN sind
- Direkt auf main committen
- Ausserhalb deines Scopes (WP-123..142) arbeiten
- @panic in Production Code Paths
- Secrets committen (.env, *.key, *.pem)
- "Production ready" behaupten ohne Evidence (Command + Output)
- Issues schliessen ohne explizite User-Freigabe
- Committen oder pushen ohne explizite User-Freigabe
- "verified"/"complete" markieren wenn Tests/Benchmarks fehlschlagen oder uebersprungen wurden — uebersprungen = OFFEN
- Reference Code aus dem Issue kopieren ohne den tatsaechlichen Code im Repo zu lesen und zu verstehen
- Tests/Benchmarks ueberspringen — Blocker FIXEN statt umgehen
- ACs als PASS markieren ohne den dazugehoerigen Command + Output — UNTESTED ist nicht PASS
- Lokales `zig build` verwenden — IMMER `zig-remote` nutzen (Remote Build Server)

### SPRACHE
- **GitHub Issues:** Deutsch (Issue Body, Kommentare, Verify-Reports)
- **ALLES ANDERE auf GitHub:** Englisch! (Commit Messages, PR Titles, PR Bodies, Branch Names, Code Comments, Doc Comments, CHANGELOG, README)
- **Lokal:** Deutsch (Kommunikation mit User, CLAUDE.md)

### IMMER
- GitHub Issue lesen BEVOR du mit einem WP startest (Dependencies, ACs, Steps)
- Readiness Check: Dependency-Issues muessen CLOSED sein bevor du ein WP startest (`gh issue view N -R silentspike/worldsynth-dev --json state -q '.state'`)
- Preallocated Buffers fuer RT-Code
- Error Unions (`!T`) statt @panic
- `zig-remote build` + `zig-remote "build test"` vor jedem Commit (IMMER remote!)
- YAML-Syntax validieren fuer CI-Workflows
- Nach WP-Abschluss: AC-Ergebnisse (pass/fail + Command + Output) direkt in den Issue Body schreiben (`gh issue edit`)
- Evidence Protocol: Jeder Claim braucht Command + Output
- Existierenden Code im Repo lesen BEVOR neuer Code geschrieben wird der darauf aufbaut (API-Signaturen verifizieren!)
- Bei Evidence ehrlich dokumentieren was NICHT getestet wurde (NOT Tested Feld)
- JEDE AC einzeln verifizieren — keine AC ueberspringen, keine AC ohne Command + Output als PASS melden

## EVIDENCE TEMPLATE (Pflicht bei jedem Verify-Report!)

Jeder Verify-Report MUSS pro AC dieses Format verwenden:
```
| Feld | Inhalt |
|------|--------|
| Command | Exakter Befehl der ausgefuehrt wurde |
| Output | Tatsaechliche Ausgabe (gekuerzt wenn noetig) |
| Scope | Was wurde getestet |
| NOT Tested | Was wurde NICHT getestet (ehrlich!) |
```
**"NOT Tested" ist PFLICHT** — zwingt zur Ehrlichkeit ueber Testabdeckung.
Fehlende Felder = Evidence unvollstaendig = AC bleibt UNTESTED.

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
2. **Dependencies pruefen:** Alle `blocked by #N` Issues muessen CLOSED sein
3. **Implementieren:** Gemaess Issue-Spezifikation
4. **Verifizieren:** `zig-remote build && zig-remote "build test"`
5. **CI-Workflows:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
6. **Committen:** `feat(scope): description (WP-XXX)`
7. **Done:** Alle ACs mit Evidence verifizieren, Ergebnisse in den Issue Body schreiben (`gh issue edit N -R silentspike/worldsynth-dev`)

## PROJECT CONTEXT

### Quick Start
- **Build:** `zig-remote build`
- **Test:** `zig-remote "build test"`
- **ReleaseFast Test:** `zig-remote "build test -Doptimize=ReleaseFast"`
- **Full Verify:** `zig-remote build && zig-remote "build test"`
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
- **Testing:** `zig-remote "build test"` + YAML-Validierung IMMER vor Commit
- **Code-Qualitaet:** Keine TODO/FIXME ohne zugehoeriges GitHub Issue, kein Dead Code, kein Copy-Paste

## BENCHMARKS (PFLICHT!)

### Warum Benchmarks?
Wir bauen einen Echtzeit-Audio-Synthesizer. Jeder Nanosekunde zaehlt — ein 128-Sample-Block bei 44.1kHz hat nur 2.9ms Budget. Integration-Module (Logging, IO, CI) duerfen das Audio-Budget nicht belasten. Benchmarks sind deshalb kein Nice-to-Have, sondern ein harter Gate fuer jedes WP.

### Was bezwecken wir damit?
1. **Bottlenecks finden**: Messen welche Integration-Module wie viel vom Audio-Budget verbrauchen
2. **Optimieren**: IO-Strategien aendern, Benchmark wiederholen, vorher/nachher vergleichen
3. **Overhead reduzieren**: Lock-free Logging, io_uring statt blocking IO — Overhead messen und minimieren
4. **Regressionen verhindern**: Neue Aenderungen duerfen bestehende Performance nicht verschlechtern
5. **Budget-Planung**: Wissen wie viel CPU-Budget Integration-Overhead verbraucht

### Regeln fuer alle Agents
- **AC-B1 ist PFLICHT**: Jedes Issue mit `## Benchmarks` Sektion hat eine `AC-B1` in den Akzeptanzkriterien — diese MUSS bestanden werden
- **Schwellwerte sind hart**: Die Schwellwerte im Issue sind Obergrenzen, nicht Richtwerte
- **Evidence**: Benchmark-Ergebnisse muessen als Command + Output dokumentiert werden
- **Kein Issue-Close ohne Benchmarks**: Wenn AC-B1 im Issue steht, ist es ein harter Gate — Benchmarks uebersprungen = Issue bleibt offen
- **Verify-Report**: Benchmark-Werte gehoeren in den Verify-Report (Tabelle mit gemessenen Werten)

### Benchmark-Typen (S4-relevant)
| Typ | Beschreibung | Typische Module |
|-----|-------------|-----------------|
| throughput | ops/s oder msg/s | Logging, OSC, MIDI-Routing |
| latency | ns pro Operation | io_uring Submission, Log-Write, State Save/Load |
| cycles/block | ns pro 128-Sample Block | Audio-Thread Logging-Overhead |
| CI duration | Sekunden | Build-Zeit, Test-Suite, Release-Pipeline |
| accuracy | Drift, Sync-Fehler | Ableton Link Sync, MIDI Clock |

### Performance-Budgets (S4-Scope)
| Metrik | Ziel |
|--------|------|
| Lock-free Log Write (RT-Thread) | < 50ns pro Message |
| io_uring File Read (4KB) | < 100us |
| OSC Message Dispatch | < 10us |
| State Save (Full Preset) | < 5ms |
| State Load (Full Preset) | < 10ms |
| CI Build + Test (Full) | < 120s |

### Dein Scope: Was du benchmarken musst
- **Logging** (WP-123..124): Lock-free Write Latenz im Audio-Thread, Throughput Consumer-Thread
- **io_uring** (WP-125..126): Submission-Latenz, File Read/Write Throughput
- **OSC** (WP-127..128): Message-Parsing, Dispatch-Latenz, Bidirektional-Throughput
- **Ableton Link** (WP-129): Sync-Genauigkeit, Drift ueber Zeit
- **CI/CD** (WP-136..140): Build-Zeit, Test-Suite-Dauer, Release-Pipeline End-to-End
- **State Management** (WP-130..132): Preset Save/Load Latenz, Schema-Migration Overhead

## ZIG REMOTE BUILD (PFLICHT!)

**Build-Server:** LXC `zigbuild` (CT 183) auf Proxmox 10.0.0.69
**Adresse:** `builder@10.0.0.73`
**Specs:** 4 Cores (P-Cores, 4.4 GHz), 4GB RAM, 10GB Disk, Debian 13, Zig 0.15.2
**tmpfs:** 2GB auf `/opt/zig-builds` (Build-Artefakte im RAM)

### Regeln
- **IMMER** `zig-remote` statt `zig build` fuer WorldSynth und andere Zig-Projekte unter /work
- Entlastet den Laptop, Build laeuft auf Proxmox-Server
- Config `.zig-remote.toml` liegt im Projekt-Root (neben build.zig)

### Verwendung
```bash
# Statt: zig build
zig-remote build

# Tests remote
zig-remote "build test"

# ReleaseFast Tests
zig-remote "build test -Doptimize=ReleaseFast"
```

### Benchmarks + Tests: DOPPELT ausfuehren!
- Benchmarks laufen bei `zig-remote` auf dem **Build-Server (Intel i5-1235U)**, nicht auf dem Laptop (Ryzen 9 5900HS)
- **IMMER doppelt testen** — Remote fuer stabile Baseline + Lokal fuer reale Ziel-Performance
- **IMMER Binaries verwenden** (`zig-out/`) fuer Benchmarks und Tests, nicht `zig build test` direkt
- Schwellwerte muessen fuer **beide Umgebungen** passen (max beider * 2x Headroom)
- Beide Ergebnisse (remote + lokal) im Verify-Report dokumentieren

### Troubleshooting
- Build-Server nicht erreichbar? Proxmox pruefen: `ssh root@10.0.0.69 "pct status 183"`
- Container starten: `ssh root@10.0.0.69 "pct start 183"`
- Zig-Version pruefen: `ssh zigbuild "zig version"`
- tmpfs voll? Build-Cache leeren: `ssh zigbuild "rm -rf /opt/zig-builds/*"`

---

## REFERENCES

### SSOT
| Was | Quelle |
|-----|--------|
| WP-Details + Dependencies | GitHub Issues (`blocked by #N`) |
| Dependency Graph | `/work/plan/synth/dependency-map.json` |
| WP-Briefs (Backup) | `/work/plan/synth/wp-briefs/WP-XXX.md` |

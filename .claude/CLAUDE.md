# CLAUDE CODE - WorldSynth Sprint 1: Foundation

**Sprache:** Deutsch
**Typ:** DSP Foundation (Zig 0.15.x)

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
- `zig-remote build` + `zig-remote "build test"` vor jedem Commit (NIEMALS lokales `zig build`!)
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

### Git-Workflow (LESSONS LEARNED — 2026-03-01)

**Branch-Strategie:**
```
feat/wp-XXX-name  (Feature-Branch, von private/main erstellt)
        ↓ PR gegen main
      main  (Haupt-Branch, autoritativ)
        ↓ sync nach jedem Merge!
    sprint-1  (muss mit main synchron gehalten werden)
```

**Korrekter Ablauf pro WP:**
1. Feature-Branch von `private/main` erstellen: `git checkout -b feat/wp-XXX-name private/main`
2. Implementieren, testen, committen
3. PR gegen `main` erstellen (NICHT gegen sprint-1)
4. Nach PR-Merge: sprint-1 mit main synchronisieren:
   ```bash
   git checkout sprint-1 && git pull private sprint-1
   git merge private/main --no-edit
   git push private sprint-1
   ```

**FEHLER der gemacht wurde:** WP-003..007 wurden korrekt nach main gemergt, aber sprint-1 wurde NICHT synchronisiert. Dadurch hatten andere Sessions veralteten Code auf sprint-1.

### Issue-Close Workflow (LESSONS LEARNED — 2026-03-01)

**PFLICHT-Reihenfolge:**
1. `status:verified` Label auf dem Issue setzen
2. DANN Issue schliessen

**FEHLER der gemacht wurde:** Issues #4-#9 ohne `status:verified` Label geschlossen. Die `issue-close-guard` GitHub Action hat sie automatisch ~8 Sekunden spaeter wieder geoeffnet.

### WP-Workflow
1. **Issue lesen:** `gh issue view N -R silentspike/worldsynth-dev`
2. **Dependencies pruefen:** Alle `blocked by #N` Issues muessen CLOSED sein
3. **Implementieren:** Gemaess Issue-Spezifikation
4. **Verifizieren:** `zig-remote build && zig-remote "build test"`
5. **Committen:** `feat(scope): description (WP-XXX)`
6. **PR erstellen:** `gh pr create -R silentspike/worldsynth-dev --base main`
7. **Nach Merge:** sprint-1 mit main synchronisieren (siehe Git-Workflow)
8. **Done:** Alle ACs mit Evidence verifizieren, `status:verified` Label setzen, Issue schliessen

## PROJECT CONTEXT

### Quick Start
- **Build:** `zig-remote build`
- **Test:** `zig-remote "build test"`
- **Build + JACK:** `zig-remote "build -Djack=true"`
- **ReleaseFast Tests:** `zig-remote "build test -Doptimize=ReleaseFast"`
- **Full Verify:** `zig-remote build && zig-remote "build test"`
- **Issue lesen:** `gh issue view N -R silentspike/worldsynth-dev`

### Scope
Du bist **Dev 1** — verantwortlich fuer die DSP-Foundation und den ersten hoerbaren Sound.
- **Branch:** `sprint-1`
- **WPs:** WP-000 bis WP-031 (32 Work Packages)
- **Worktree:** `/work/daw/synth/s1-foundation/`
- **Issues:** `gh issue list -R silentspike/worldsynth-dev -l "sprint:s1" --limit 50`

### Benchmark-Schwellwerte (LESSONS LEARNED — 2026-03-01)

- Issue-Schwellwerte sind oft fuer Server-Hardware kalibriert, nicht fuer Laptop (Ryzen 9 5900HS)
- LLVM optimiert `@sin(f32)` in ReleaseFast auf ~10-cycle Polynomial → LUT Speedup nur ~2.5x statt 5x
- Bei Messwerten < 20ns dominiert Timer-Overhead → Speedup-Ratios instabil
- Angepasste Schwellwerte: siehe PR #173
- Bei neuen Benchmarks: realistischen Schwellwert auf Laptop messen, dann 2x Headroom einplanen

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
- **Git-Workflow:** Feature-Branch pro WP, PR gegen `main`, nach Merge sprint-1 synchronisieren
- **Testing:** Unit-Tests fuer jede neue Funktion, `zig-remote "build test"` IMMER vor Commit
- **Code-Qualitaet:** Keine TODO/FIXME ohne zugehoeriges GitHub Issue, kein Dead Code, kein Copy-Paste

## ZIG REMOTE BUILD

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

# Mit JACK-Flag
zig-remote "build -Djack=true"
```

### Neue Zig-Projekte einrichten
`.zig-remote.toml` im Projekt-Root (neben build.zig) anlegen:
```toml
[remote]
host = "zigbuild"
temp_dir = "/opt/zig-builds"
```

### Benchmarks und Tests: Remote + Lokal

**WICHTIG:** `zig-remote "build test"` kompiliert UND fuehrt Tests auf dem Build-Server aus!
Die Benchmarks laufen also auf dem Build-Server (Intel i5-1235U P-Cores), NICHT auf dem Laptop (Ryzen 9 5900HS).

**Konsequenzen:**
- Build-Server hat andere CPU → andere Benchmark-Werte als lokal
- Build-Server ist stabiler (kein Desktop, kein Browser) → weniger Varianz, reproduzierbarere Ergebnisse
- Laptop ist das echte Ziel-System → lokale Werte sind relevanter fuer Praxis

**CPU-Target Problem:**
- Build-Server (Intel Alder Lake) baut mit `-march=native` → Binary enthaelt Instruktionen die Ryzen 9 5900HS (Zen 3) NICHT hat → `Illegal instruction` lokal!
- Remote-Binaries NIEMALS lokal ausfuehren!
- Fuer lokale Integration-Tests (JACK, PipeWire): `zig build` lokal ist erlaubt (Ausnahme!)

**Strategie: IMMER doppelt testen!**
1. `zig-remote "build test"` — Remote: Unit-Tests + Benchmarks auf Build-Server
2. `zig build -Djack=true && ./zig-out/bin/worldsynth` — Lokal: Integration mit JACK/PipeWire

**Ausnahme von "immer zig-remote":** Integration-Tests die lokale Services brauchen (JACK/PipeWire/Audio-Hardware) werden lokal gebaut und getestet mit `zig build`.

**Binaries verwenden:** Fuer Benchmarks und alle Tests IMMER die kompilierten Binaries aus `zig-out/` verwenden. Das stellt sicher dass das tatsaechliche Artefakt getestet wird.

**Schwellwerte:** Muessen fuer BEIDE Umgebungen passen. Bei neuen Benchmarks:
1. Auf Build-Server messen (Remote-Baseline)
2. Auf Laptop messen (Lokal-Baseline, x86_64_v3 Binary)
3. Schwellwert = max(beide) * 2x Headroom

### Troubleshooting
- Build-Server nicht erreichbar? Proxmox pruefen: `ssh root@10.0.0.69 "pct status 183"`
- Container starten: `ssh root@10.0.0.69 "pct start 183"`
- Zig-Version pruefen: `ssh zigbuild "zig version"`
- tmpfs voll? Build-Cache leeren: `ssh zigbuild "rm -rf /opt/zig-builds/*"`

## REFERENCES

### SSOT
| Was | Quelle |
|-----|--------|
| WP-Details + Dependencies | GitHub Issues (`blocked by #N`) |
| Dependency Graph | `/work/plan/synth/dependency-map.json` |
| WP-Briefs (Backup) | `/work/plan/synth/wp-briefs/WP-XXX.md` |

## Description

<!-- Concise summary of the changes and their purpose. -->



## Closes

<!-- Link the issue(s) this PR resolves. -->

Closes #

## Type of Change

- [ ] `fix` -- Bug fix (non-breaking change that resolves an issue)
- [ ] `feat` -- New feature (non-breaking change that adds functionality)
- [ ] `refactor` -- Code refactoring (no functional change, no API change)
- [ ] `perf` -- Performance improvement (measurable, with benchmark evidence)
- [ ] `test` -- Adding or updating tests only
- [ ] `docs` -- Documentation only
- [ ] `build` -- Build system, CI/CD, or dependency changes
- [ ] `breaking` -- Breaking change (fix or feature that changes existing behavior)

## Evidence: Test Matrix

<!-- Fill in EVERY row. Use one of: PASS (with evidence), FAIL (with details), N/A (with justification), UNTESTED (with reason). -->
<!-- "Code looks correct" is NOT evidence. A test must RUN, a measurement must be TAKEN. -->

| Level                    | What was tested                          | Command / Method | Result     |
|--------------------------|------------------------------------------|------------------|------------|
| **Static Analysis**      | `zig build` compiles without warnings    |                  |            |
| **Unit / Integration**   | Relevant test filters                    |                  |            |
| **Contract / API**       | CLAP parameter validation, host compat   |                  |            |
| **System / Artifact**    | CLAP plugin loads in host DAW            |                  |            |
| **E2E / Smoke**          | End-to-end audio path verification       |                  |            |
| **Non-Functional**       | CPU benchmark, memory, binary size       |                  |            |

## NOT Tested

<!-- MANDATORY: List what was NOT tested and why. Empty section = PR not ready. -->

-

## Checklist

- [ ] All existing tests pass (`zig build test`) -- paste output or CI link
- [ ] No new compiler warnings or errors introduced
- [ ] CHANGELOG updated (if user-facing change)
- [ ] Documentation updated (if API or behavior changed)
- [ ] CLAP plugin artifact builds successfully (`zig build -Dclap`)
- [ ] Plugin tested in at least one CLAP host (state which host and version)
- [ ] Acceptance criteria from linked issue verified with evidence
- [ ] Negative criteria from linked issue verified with evidence

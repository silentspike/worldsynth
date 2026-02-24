# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | Yes       |
| < latest | No       |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **DO NOT** create a public GitHub issue
2. Use GitHub's private vulnerability reporting:
   **Settings > Security > Advisories > [Report a vulnerability](https://github.com/silentspike/worldsynth/security/advisories/new)**

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Assessment**: Within 7 days
- **Fix timeline**: Depends on severity
  - Critical: 72 hours
  - High: 2 weeks
  - Medium: 4 weeks
  - Low: Next release cycle

## Security Measures

### Active

- GitHub Secret Scanning with push protection enabled
- Hidden Unicode/Bidi character detection in CI (CVE-2021-42574)
- Secret scanning in CI via [gitleaks](https://github.com/gitleaks/gitleaks) (MIT-licensed CLI)
- CodeQL SAST scanning on push/PR to `ui/**` paths and weekly schedule
- Dependencies monitored via Dependabot (GitHub Actions ecosystem)
- No secrets in source code (enforced via `.gitignore` and CI checks)
- Hand-written bindings instead of `@cImport` for supply chain control

### Planned (once code exists)

- Dependabot for npm dependencies (ui/)
- npm audit in CI pipeline
- Additional CodeQL language coverage as codebase grows

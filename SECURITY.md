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

- Dependencies regularly updated via Dependabot
- CodeQL SAST scanning on every push and pull request
- Hidden Unicode/Bidi character detection in CI
- No secrets in source code (enforced via `.gitignore` and CI checks)
- Hand-written bindings instead of `@cImport` for supply chain control

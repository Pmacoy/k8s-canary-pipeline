# Security Policy

This is a portfolio/demo project, not a production service. That said:

## Reporting a vulnerability

If you find a security issue in this repository (in the demo app, the
Dockerfile, or the Kubernetes manifests), please open a
[GitHub issue](../../issues/new) describing it. There's no user data or
production deployment at stake here, so there's no need for a private
disclosure channel — but flag it clearly as a security finding in the title.

## What's actually scanned here

- **Dependencies** — [pip-audit](https://github.com/pypa/pip-audit) against
  both the runtime and dev dependency sets, on every push/PR and weekly.
- **Container image** — [Trivy](https://github.com/aquasecurity/trivy),
  both a filesystem scan (this repo's own files) and an image scan (the
  actual built container, including OS-level packages) in `release.yml`.
- **Static analysis** — [Semgrep](https://semgrep.dev/) (`p/ci` ruleset) and
  [CodeQL](https://codeql.github.com/) for the Python app.
- **Secrets** — [gitleaks](https://github.com/gitleaks/gitleaks) across full
  git history on every push/PR.
- **Dockerfile** — [hadolint](https://github.com/hadolint/hadolint).
- **Supply chain** — every published image is signed keylessly with
  [cosign](https://github.com/sigstore/cosign) via GitHub OIDC and shipped
  with an attached SPDX SBOM ([anchore/sbom-action](https://github.com/anchore/sbom-action)).

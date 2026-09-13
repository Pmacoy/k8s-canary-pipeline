# k8s-canary-pipeline

A canary deployment pipeline that actually proves itself. [Argo Rollouts](https://argoproj.github.io/rollouts/)
shifts traffic to a new revision in stages, pauses to let an automated
[AnalysisTemplate](https://argoproj.github.io/rollouts/features/analysis/)
query live Prometheus metrics, and either promotes the revision to 100% or
aborts it and rolls traffic back — with no human clicking "promote" in
between. The [`canary-e2e` GitHub Actions workflow](.github/workflows/canary-e2e.yml)
runs this against a real, disposable Kubernetes cluster on every push: it
deploys a **good** revision and asserts it gets promoted, then deploys a
**bad** one and asserts it gets aborted automatically, before the traffic
ever fully reaches it.

## Why a fake app with a `FAIL_RATE` knob

The demo app ([`app/main.py`](app/main.py)) is deliberately tiny: three
routes and one environment variable, `FAIL_RATE`, that controls how often
`/` returns a 500. That's the entire "bug" a canary is meant to catch. A
more elaborate app would just be more code between you and the part that
matters — the rollout strategy itself.

- `/` — the "business logic." Fails `FAIL_RATE` of the time.
- `/healthz` — liveness/readiness. **Never** gated on `FAIL_RATE`, so a bad
  canary still passes its Kubernetes probes and stays in rotation long
  enough for the analysis to catch it via real traffic, rather than being
  pulled out by its own probe before it can prove anything.
- `/metrics` — Prometheus format, via [`prometheus_client`](https://github.com/prometheus/client_python).
  Every request increments `shrtn_requests_total{path,status,version}`.

## Architecture

```
                          ┌─────────────────────┐
   client traffic  ─────▶ │  ingress-nginx       │
                          │  (canary-weight %)   │
                          └──────────┬───────────┘
                          20% ──┐    │    ┌── 80%
                                ▼    │    ▼
                     ┌────────────┐  │  ┌────────────┐
                     │  canary    │  │  │  stable     │
                     │  Service   │  │  │  Service    │
                     └─────┬──────┘  │  └─────┬──────┘
                           │         │        │
                     ┌─────▼──────┐  │  ┌─────▼──────┐
                     │ new pods   │  │  │ old pods    │
                     │ (v-next)   │  │  │ (v-current) │
                     └─────┬──────┘  │  └────────────┘
                           │  metrics (rollouts-pod-template-hash)
                           ▼
                     ┌────────────┐        ┌─────────────────┐
                     │ Prometheus │◀───────│ AnalysisTemplate │
                     │            │  query │ success-rate     │
                     └────────────┘        └────────┬─────────┘
                                                     │ pass/fail
                                            ┌────────▼─────────┐
                                            │  Argo Rollouts    │
                                            │  controller       │
                                            │  (promote/abort)  │
                                            └───────────────────┘
```

The Rollout ([`k8s/rollout.yaml`](k8s/rollout.yaml)) defines the steps:
20% weight → pause → automated analysis → 50% → pause → 100%. The
AnalysisTemplate ([`k8s/analysis-template.yaml`](k8s/analysis-template.yaml))
queries the *specific new revision's* success rate — isolated by the
`rollouts-pod-template-hash` label Argo Rollouts stamps onto each
ReplicaSet's pods, which our minimal in-cluster Prometheus
([`k8s/prometheus.yaml`](k8s/prometheus.yaml)) picks up automatically via
annotation-based pod discovery. No app code has to know anything about
rollouts for this to work.

## Run it yourself

Requires `docker`, `kind`, and `kubectl`.

```bash
make cluster   # kind cluster + ingress-nginx + Argo Rollouts controller
make demo      # builds the app, deploys it, runs a good canary then a bad one
```

`make demo` runs [`scripts/demo-canary.sh`](scripts/demo-canary.sh), which:

1. Builds the image and loads it into the kind cluster.
2. Applies the manifests and waits for the initial (`v1`) rollout to be healthy.
3. Starts a background traffic generator against the ingress.
4. Rolls out `v2-good` (`FAIL_RATE=0`) and asserts it reaches **Healthy** (fully promoted).
5. Rolls out `v3-bad` (`FAIL_RATE=1`) and asserts it reaches **Degraded** (aborted).
6. Confirms the ingress is still serving `v2-good` — the aborted revision never got real traffic.

Watch it live in a second terminal while `make demo` runs:

```bash
kubectl argo rollouts get rollout canary-demo -n canary-demo --watch
```

Tear down when you're done: `make destroy`.

## What each workflow does

| Workflow | What it proves |
|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | The app's tests pass, lint/type-check clean, and the Kubernetes manifests render. |
| [`security.yml`](.github/workflows/security.yml) | No known-vulnerable dependencies, no secrets, no Dockerfile misconfigurations, clean SAST/filesystem scan. |
| [`codeql.yml`](.github/workflows/codeql.yml) | Static analysis for the Python app. |
| [`canary-e2e.yml`](.github/workflows/canary-e2e.yml) | **The rollout strategy actually works** — a real cluster, a real promote, a real abort. |
| [`release.yml`](.github/workflows/release.yml) | The image is built, Trivy-scanned, signed with [cosign](https://github.com/sigstore/cosign) (keyless, via GitHub OIDC), and published to GHCR with an attached SPDX SBOM. |

## What this deliberately doesn't do

There's no real production cluster or cloud account behind this — `canary-e2e.yml`
stands up and tears down its own disposable `kind` cluster on the runner. In
a real deployment, `release.yml`'s signed, SBOM-attested image would be what
a GitOps controller (Argo CD, watching this repo or a separate manifests
repo) picks up and applies via the same `Rollout` object — the strategy and
the analysis logic here transfer directly; only the "who applies the YAML"
part changes.

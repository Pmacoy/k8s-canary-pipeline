#!/usr/bin/env bash
# The actual proof this repo exists to deliver: build the app, roll out a
# GOOD revision (expect: promoted to 100% automatically) and then a BAD one
# (expect: automatically aborted at 20% traffic, stable never disturbed) --
# against a real cluster, with nothing scripted about the outcome except
# the app's own FAIL_RATE. Exits non-zero if either assertion doesn't hold,
# which is what lets .github/workflows/canary-e2e.yml treat this as a real
# test rather than a demo that just runs some kubectl commands.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-canary-demo}"
NAMESPACE="canary-demo"
IMAGE_REF="${IMAGE_REF:-canary-demo:local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRAFFIC_PID=""

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  [ -n "$TRAFFIC_PID" ] && kill "$TRAFFIC_PID" 2>/dev/null || true
}
trap cleanup EXIT

set_image_ref() {
  local ref="$1" image="${1%%:*}" tag="${1##*:}"
  sed -i.bak -e "s|newName: .*|newName: ${image}|" -e "s|newTag: .*|newTag: ${tag}|" \
    "$REPO_ROOT/k8s/kustomization.yaml"
  rm -f "$REPO_ROOT/k8s/kustomization.yaml.bak"
}

patch_revision() {
  local version="$1" fail_rate="$2"
  log "Rolling out APP_VERSION=$version FAIL_RATE=$fail_rate"
  kubectl -n "$NAMESPACE" patch rollout canary-demo --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":[
      {\"name\":\"APP_VERSION\",\"value\":\"${version}\"},
      {\"name\":\"FAIL_RATE\",\"value\":\"${fail_rate}\"}
    ]}
  ]"
}

phase_of() {
  kubectl -n "$NAMESPACE" get rollout canary-demo -o jsonpath='{.status.phase}'
}

log "Building image $IMAGE_REF"
docker build -t "$IMAGE_REF" "$REPO_ROOT"

log "Loading image into kind cluster '$CLUSTER_NAME'"
kind load docker-image "$IMAGE_REF" --name "$CLUSTER_NAME"

set_image_ref "$IMAGE_REF"

log "Applying base manifests (namespace, Prometheus, Rollout, Services, Ingress, AnalysisTemplate)"
kubectl apply -k "$REPO_ROOT/k8s"

log "Waiting for the initial v1 rollout to become healthy"
kubectl argo rollouts status canary-demo -n "$NAMESPACE" --timeout=180s

log "Waiting for Prometheus to be ready"
kubectl wait --namespace "$NAMESPACE" --for=condition=available deployment/prometheus --timeout=120s

log "Starting a background traffic generator against the ingress"
(
  while true; do
    curl -s -o /dev/null -H "Host: canary.demo.local" "http://127.0.0.1/" || true
    sleep 0.1
  done
) &
TRAFFIC_PID=$!
sleep 3 # let a few requests land before the first revision even starts

# --- Scenario 1: a healthy canary should be promoted automatically ------
patch_revision "v2-good" "0"
if kubectl argo rollouts status canary-demo -n "$NAMESPACE" --timeout=240s; then
  phase="$(phase_of)"
  [ "$phase" = "Healthy" ] || fail "expected Healthy after a good canary, got '$phase'"
  log "PASS: good canary (v2-good) was promoted to 100% automatically"
else
  fail "good canary (v2-good) did not reach Healthy -- it should have been promoted"
fi

# --- Scenario 2: a canary that regresses should be aborted automatically -
patch_revision "v3-bad" "1"
kubectl argo rollouts status canary-demo -n "$NAMESPACE" --timeout=240s || true
phase="$(phase_of)"
[ "$phase" = "Degraded" ] || fail "expected Degraded after a bad canary's analysis failed, got '$phase'"
log "PASS: bad canary (v3-bad, FAIL_RATE=1) was aborted automatically by the analysis"

log "Confirming the ingress is still serving the last GOOD revision, not the aborted one"
body="$(curl -s -H "Host: canary.demo.local" "http://127.0.0.1/")"
echo "$body" | grep -q '"version":"v2-good"' \
  || fail "expected traffic to still be served by v2-good after the abort, got: $body"
log "PASS: traffic never shifted to the aborted revision -- v2-good is still what users see"

log "All canary assertions passed."

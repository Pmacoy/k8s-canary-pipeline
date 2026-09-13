#!/usr/bin/env bash
# Stands up everything a real canary rollout needs, from nothing: a kind
# cluster, ingress-nginx (for the traffic-shifting), and the Argo Rollouts
# controller + CLI plugin. Idempotent-ish -- re-running it against an
# existing cluster of the same name just skips cluster creation.
#
# Requires: docker, kind, kubectl, curl. On a fresh machine, kind + kubectl
# are the only two you're likely missing -- see README.md for install links.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-canary-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Checking for required tools"
for bin in docker kind kubectl curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin"; exit 1; }
done

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> kind cluster '$CLUSTER_NAME' already exists, reusing it"
else
  echo "==> Creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --config "$REPO_ROOT/k8s/kind-config.yaml"
fi

kubectl config use-context "kind-$CLUSTER_NAME"

echo "==> Installing ingress-nginx (kind provider manifest)"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml

echo "==> Waiting for ingress-nginx admission webhook and controller"
kubectl wait --namespace ingress-nginx \
  --for=condition=Complete job/ingress-nginx-admission-patch \
  --timeout=180s || true
kubectl wait --namespace ingress-nginx \
  --for=condition=available deployment/ingress-nginx-controller \
  --timeout=180s

echo "==> Installing Argo Rollouts controller"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
# --server-side is required here, not optional: Argo Rollouts' CRDs carry a
# large enough OpenAPI schema that a normal `kubectl apply` -- which stores
# the whole previous config in a kubectl.kubernetes.io/last-applied-
# configuration annotation -- blows past Kubernetes' 256KiB annotation
# limit ("Too long: may not be more than 262144 bytes"). Server-side apply
# tracks changes via managed fields instead of that annotation, which is
# exactly what avoids the problem; --force-conflicts lets a re-run of this
# script against an existing cluster take ownership back cleanly.
kubectl apply --server-side --force-conflicts \
  -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl wait --namespace argo-rollouts \
  --for=condition=available deployment/argo-rollouts \
  --timeout=180s

echo "==> Installing the kubectl argo rollouts plugin (for status/get output)"
if ! command -v kubectl-argo-rollouts >/dev/null 2>&1; then
  PLUGIN_OS="$(uname | tr '[:upper:]' '[:lower:]')"
  PLUGIN_ARCH="$(uname -m)"
  case "$PLUGIN_ARCH" in
    x86_64) PLUGIN_ARCH="amd64" ;;
    aarch64|arm64) PLUGIN_ARCH="arm64" ;;
  esac
  curl -fsSL -o /tmp/kubectl-argo-rollouts \
    "https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-${PLUGIN_OS}-${PLUGIN_ARCH}"
  chmod +x /tmp/kubectl-argo-rollouts
  if sudo mv /tmp/kubectl-argo-rollouts /usr/local/bin/kubectl-argo-rollouts 2>/dev/null; then
    :
  else
    mkdir -p "$HOME/.local/bin"
    mv /tmp/kubectl-argo-rollouts "$HOME/.local/bin/kubectl-argo-rollouts"
    echo "Installed to $HOME/.local/bin -- make sure that's on your PATH."
  fi
fi

echo "==> Cluster ready. Context: kind-$CLUSTER_NAME"

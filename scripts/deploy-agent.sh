#!/usr/bin/env bash
# Build the fbi-crime-analyst-agent on-cluster from its GitHub repo and deploy
# its Helm chart pointed at the cluster's internal image registry.
#
# Mirrors the MCP-server deploy pattern: cluster fetches source from git via
# BuildConfig, no Mac→x86 cross-build needed.
#
# Required env: AGENT_REPO_URL, AGENT_REPO_REF, KUBECONFIG (or active oc context)
# Optional env: AGENT_LOCAL_PATH (used only for chart vendoring during dev)
# Required args: --namespace --mcp-url --llm-url --llm-model

set -euo pipefail

NAMESPACE=""
MCP_URL=""
LLM_URL=""
LLM_MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --mcp-url)   MCP_URL="$2"; shift 2 ;;
    --llm-url)   LLM_URL="$2"; shift 2 ;;
    --llm-model) LLM_MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$NAMESPACE" ]] && { echo "missing --namespace" >&2; exit 2; }
[[ -z "$MCP_URL" ]]   && { echo "missing --mcp-url"   >&2; exit 2; }
[[ -z "$LLM_URL" ]]   && { echo "missing --llm-url"   >&2; exit 2; }
[[ -z "$LLM_MODEL" ]] && { echo "missing --llm-model" >&2; exit 2; }
[[ -z "${AGENT_REPO_URL:-}" ]] && { echo "AGENT_REPO_URL env var not set" >&2; exit 2; }

OC=(oc)
HELM_CTX_ARGS=()
if [[ -n "${OC_CONTEXT:-}" ]]; then
  OC+=("--context=$OC_CONTEXT")
  HELM_CTX_ARGS=(--kube-context "$OC_CONTEXT")
fi

IMAGE_NAME="fbi-crime-analyst-agent"
IMAGE_TAG="latest"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
RESOLVED_IMAGE="$INTERNAL_REGISTRY/$NAMESPACE/$IMAGE_NAME"

echo "==> ensuring namespace $NAMESPACE"
"${OC[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || "${OC[@]}" create namespace "$NAMESPACE"

# ─── ImageStream + BuildConfig ────────────────────────────────────────────
echo "==> applying ImageStream + BuildConfig"
"${OC[@]}" apply -n "$NAMESPACE" -f - <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: $IMAGE_NAME
  labels:
    app.kubernetes.io/name: $IMAGE_NAME
    app.kubernetes.io/part-of: fbi-ucr-demo
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: $IMAGE_NAME
  labels:
    app.kubernetes.io/name: $IMAGE_NAME
    app.kubernetes.io/part-of: fbi-ucr-demo
spec:
  output:
    to:
      kind: ImageStreamTag
      name: $IMAGE_NAME:$IMAGE_TAG
  source:
    type: Git
    git:
      uri: $AGENT_REPO_URL
      ref: ${AGENT_REPO_REF:-main}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Containerfile
  triggers:
    - type: ConfigChange
EOF

echo "==> starting agent build (this may take a few minutes)"
"${OC[@]}" -n "$NAMESPACE" start-build "$IMAGE_NAME" --wait --follow=false

# ─── Helm install / upgrade ───────────────────────────────────────────────
# We need the chart sources from somewhere. Either:
#   - AGENT_LOCAL_PATH points at a local checkout (dev)
#   - clone the repo to a tmp dir
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
if [[ -n "${AGENT_LOCAL_PATH:-}" && -d "$AGENT_LOCAL_PATH/chart" ]]; then
  CHART_DIR="$AGENT_LOCAL_PATH/chart"
  echo "==> using local chart at $CHART_DIR"
else
  echo "==> cloning $AGENT_REPO_URL@${AGENT_REPO_REF:-main} for chart"
  git clone --depth 1 --branch "${AGENT_REPO_REF:-main}" "$AGENT_REPO_URL" "$WORKDIR/agent"
  CHART_DIR="$WORKDIR/agent/chart"
fi

echo "==> helm upgrade --install $IMAGE_NAME"
helm upgrade --install "$IMAGE_NAME" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  "${HELM_CTX_ARGS[@]}" \
  --set image.repository="$RESOLVED_IMAGE" \
  --set image.tag="$IMAGE_TAG" \
  --set image.pullPolicy=Always \
  --set config.MCP_FBI_URL="$MCP_URL" \
  --set config.MODEL_ENDPOINT="$LLM_URL" \
  --set config.MODEL_NAME="$LLM_MODEL" \
  --set route.enabled=true \
  --wait --timeout 5m

echo "==> done. Route:"
"${OC[@]}" -n "$NAMESPACE" get route -l "app.kubernetes.io/name=$IMAGE_NAME" \
  -o jsonpath='https://{.items[0].spec.host}{"\n"}' || true

#!/usr/bin/env bash
# Build a fips-agents component (agent | gateway | ui) on-cluster from its
# GitHub repo and deploy it via Helm against the cluster's internal registry.
#
# All three component types share the same deploy shape: ImageStream +
# Git-source BuildConfig + oc start-build --wait + helm upgrade --install
# with image.repository pointed at the internal registry.
#
# Usage:
#   deploy-fips-component.sh \
#     --name fbi-crime-analyst-agent \
#     --namespace fbi-agent \
#     --repo https://github.com/redhat-ai-americas/fbi-crime-analyst-agent.git \
#     --ref main \
#     --config MCP_FBI_URL=http://fbi-crime-stats-mcp.fbi-mcp.svc:8080/mcp/ \
#     --config MODEL_ENDPOINT=http://gpt-oss-20b.gpt-oss-model.svc:80/v1 \
#     --config MODEL_NAME=RedHatAI/gpt-oss-20b
#
# --config FOO=BAR is repeatable; each maps to `helm --set config.FOO=BAR`.
# Optional env: OC_CONTEXT  AGENT_LOCAL_PATH (uses local chart instead of clone)

set -euo pipefail

NAME=""
NAMESPACE=""
REPO=""
REF="main"
CONFIG_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      NAME="$2";      shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --repo)      REPO="$2";      shift 2 ;;
    --ref)       REF="$2";       shift 2 ;;
    --config)    CONFIG_ARGS+=(--set "config.$2"); shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$NAME" ]]      && { echo "missing --name"      >&2; exit 2; }
[[ -z "$NAMESPACE" ]] && { echo "missing --namespace" >&2; exit 2; }
[[ -z "$REPO" ]]      && { echo "missing --repo"      >&2; exit 2; }

OC=(oc)
HELM_CTX_ARGS=()
if [[ -n "${OC_CONTEXT:-}" ]]; then
  OC+=("--context=$OC_CONTEXT")
  HELM_CTX_ARGS=(--kube-context "$OC_CONTEXT")
fi

INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
RESOLVED_IMAGE="$INTERNAL_REGISTRY/$NAMESPACE/$NAME"

echo "==> ensuring namespace $NAMESPACE"
"${OC[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || "${OC[@]}" create namespace "$NAMESPACE"

echo "==> applying ImageStream + BuildConfig for $NAME"
"${OC[@]}" -n "$NAMESPACE" apply -f - <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${NAME}
  labels:
    app.kubernetes.io/name: ${NAME}
    app.kubernetes.io/part-of: fbi-ucr-demo
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: ${NAME}
  labels:
    app.kubernetes.io/name: ${NAME}
    app.kubernetes.io/part-of: fbi-ucr-demo
spec:
  output:
    to:
      kind: ImageStreamTag
      name: ${NAME}:latest
  source:
    type: Git
    git:
      uri: ${REPO}
      ref: ${REF}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Containerfile
EOF

echo "==> starting build for $NAME (this may take a few minutes)"
"${OC[@]}" -n "$NAMESPACE" start-build "$NAME" --wait --follow=false

# Source the chart from the same repo we just built from.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
if [[ -n "${AGENT_LOCAL_PATH:-}" && -d "$AGENT_LOCAL_PATH/chart" ]]; then
  CHART_DIR="$AGENT_LOCAL_PATH/chart"
  echo "==> using local chart at $CHART_DIR"
else
  echo "==> cloning $REPO@$REF for chart"
  git clone --depth 1 --branch "$REF" "$REPO" "$WORKDIR/src"
  CHART_DIR="$WORKDIR/src/chart"
fi

echo "==> helm upgrade --install $NAME"
helm upgrade --install "$NAME" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  "${HELM_CTX_ARGS[@]}" \
  --set image.repository="$RESOLVED_IMAGE" \
  --set image.tag=latest \
  --set image.pullPolicy=Always \
  "${CONFIG_ARGS[@]}" \
  --wait --timeout 5m

echo "==> deployed; route(s):"
"${OC[@]}" -n "$NAMESPACE" get route -l "app.kubernetes.io/name=$NAME" \
  -o jsonpath='https://{.items[0].spec.host}{"\n"}' || true

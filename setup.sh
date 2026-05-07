#!/usr/bin/env bash
# FBI UCR demo — one-shot setup.
#
# Prereqs:
#   - You are logged into the target cluster (`oc login ...`)
#   - `ansible` and the kubernetes.core collection are installed
#
# What this does:
#   1. Generates ansible/inventory/clusters.yml from your active oc context
#   2. Runs site.yml (NFD + GPU operator + RHOAI + GPU MachineSet) — ~15-20m
#   3. Runs fbi-deploy.yml (gpt-oss-20b LLM + predictive service + MCP + agent)
#
# Optional flags:
#   --skip-cluster-setup  Skip site.yml (cluster already has RHOAI + GPU)
#   --no-gpu              Run without GPU (LLM phase will be skipped)
#   --enable-htpasswd     Add admin1/wfcatalog HTPasswd identity provider
#   --fbi-api-key KEY     Inject FBI Crime Data Explorer API key into the MCP server
#   --agent-local PATH    Use a local agent repo path instead of cloning from GitHub

set -euo pipefail

SKIP_CLUSTER=0
ENABLE_GPU=true
ENABLE_HTPASSWD=false
FBI_API_KEY=""
AGENT_LOCAL_PATH=""
OC_CONTEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-cluster-setup) SKIP_CLUSTER=1; shift ;;
    --no-gpu)             ENABLE_GPU=false; shift ;;
    --enable-htpasswd)    ENABLE_HTPASSWD=true; shift ;;
    --fbi-api-key)        FBI_API_KEY="$2"; shift 2 ;;
    --agent-local)        AGENT_LOCAL_PATH="$2"; shift 2 ;;
    --oc-context)         OC_CONTEXT="$2"; shift 2 ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

# ─── Preflight ─────────────────────────────────────────────────────────────
command -v oc        >/dev/null || { echo "ERROR: oc not installed";        exit 1; }
command -v ansible-playbook >/dev/null || { echo "ERROR: ansible-playbook not installed"; exit 1; }

oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged into a cluster. oc login first."; exit 1; }

echo "==> logged in as $(oc whoami) on $(oc whoami --show-server)"

# ─── Inventory ─────────────────────────────────────────────────────────────
echo "==> generating ansible inventory from active oc context"
./scripts/generate_inventory.sh

EXTRA_VARS=(
  "enable_gpu=$ENABLE_GPU"
  "enable_htpasswd=$ENABLE_HTPASSWD"
  "fbi_api_key=$FBI_API_KEY"
  "agent_local_path=$AGENT_LOCAL_PATH"
  "oc_context=$OC_CONTEXT"
)
EXTRA_ARGS=()
for v in "${EXTRA_VARS[@]}"; do EXTRA_ARGS+=(-e "$v"); done

cd ansible

# ─── Cluster setup (NFD + GPU + RHOAI) ─────────────────────────────────────
if (( SKIP_CLUSTER == 0 )); then
  echo "==> [1/2] cluster setup (site.yml)"
  ansible-playbook site.yml "${EXTRA_ARGS[@]}"
else
  echo "==> [1/2] cluster setup SKIPPED"
fi

# ─── FBI demo workloads ────────────────────────────────────────────────────
echo "==> [2/2] FBI demo workloads (fbi-deploy.yml)"
ansible-playbook fbi-deploy.yml "${EXTRA_ARGS[@]}"

echo
echo "==> done."

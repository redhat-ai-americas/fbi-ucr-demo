# FBI UCR Crime Forecasting Demo

A repeatable OpenShift demo that stands up:

1. **gpt-oss-20b** — vLLM-served LLM with tool-calling support (GPU)
2. **FBI UCR predictive service** — Prophet/ARIMA models for 5 offenses × national + 5 states
3. **FBI Crime Stats MCP server** — exposes `ucr_forecast`, `ucr_history`, `ucr_compare`, `ucr_info` tools
4. **Crime analyst agent** — `fipsagents` BaseAgent wired to the MCP server and the LLM
5. **Gateway** — fips-agents API gateway in front of the agent (anonymous auth, /v1/* proxy)
6. **Chat UI** — fips-agents web UI talking to the gateway

End-to-end runtime: ~30–40 minutes from logged-in cluster to working chat UI.

---

## Prerequisites

- A fresh OpenShift 4 cluster (see **Cluster sizing** below)
- Local tools: `oc`, `ansible` (with the `kubernetes.core` collection), `helm`, `git`, `bash`
- An [FBI Crime Data Explorer API key](https://api.data.gov/signup/) (free, ~30 sec) — required for the `ucr_history` tool. The other three tools (`ucr_forecast`, `ucr_compare`, `ucr_info`) work without it.

```bash
pip install ansible kubernetes
ansible-galaxy collection install kubernetes.core
```

### Getting an FBI API key

1. Visit https://api.data.gov/signup/ and submit your email.
2. The key arrives by email immediately (one-line value, ~40 chars).
3. Pass it to `setup.sh` (see below) — it's stored in a Kubernetes Secret in the `fbi-mcp` namespace and read by the MCP server's `ucr_history` tool.

Without a key, `ucr_history` returns a clear `403 API_KEY_MISSING` error to the agent, which surfaces it to the user. Forecasts (`ucr_forecast`, `ucr_compare`, `ucr_info`) still work — they hit the in-cluster predictive service, not the public FBI API.

---

## Get a cluster

Order an **OCP4 Sandbox** from the Red Hat Demo System:

[catalog.demo.redhat.com — sandboxes-gpte.sandbox-ocp.prod](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/sandboxes-gpte.sandbox-ocp.prod&utm_source=webapp&utm_medium=share-link)

### Cluster sizing

| Setting | Value |
|---|---|
| Control plane nodes | 3 |
| Control plane instance type | `m6a.xlarge` |
| Worker nodes | 3 |
| Worker instance type | `m6a.4xlarge` |

The demo automation creates a separate **GPU MachineSet** (`g6e.4xlarge`, NVIDIA L40S) at deploy time — you don't need to add GPU workers up front.

Provisioning takes ~45–60 minutes.

---

## Run the demo

Once the cluster is up, log in as `kubeadmin` (credentials are in the demo system order page):

```bash
oc login --server=https://api.cluster-XXXXX.sandbox-ocp.opentlc.com:6443 \
         --username=kubeadmin --password=<from-order-page>
```

Then from the repo root, with your FBI API key:

```bash
./setup.sh --fbi-api-key YOUR_FBI_KEY_HERE
```

(You can omit `--fbi-api-key` if you don't plan to use the `ucr_history` tool — see prereqs.)

That's it. The script:

1. Generates an Ansible inventory from your active `oc` context (no `cluster_list.txt` needed for single-cluster demos).
2. Runs `ansible/site.yml` — installs NFD + NVIDIA GPU operator + RHOAI 3.3, creates the GPU MachineSet, waits for `nvidia.com/gpu` capacity (~15–20 min).
3. Runs `ansible/fbi-deploy.yml` — deploys gpt-oss-20b, predictive service, MCP server (built from upstream Git), and the chatbot agent (~10–15 min).
4. Prints the routes for everything at the end.

### Optional flags

```bash
./setup.sh --fbi-api-key YOUR_KEY        # Required for ucr_history; optional for the rest
./setup.sh --enable-htpasswd             # Workshop mode: requires you to provide your own auth/*.yaml manifests
./setup.sh --no-gpu                      # CPU-only (skips LLM serving)
./setup.sh --skip-cluster-setup          # Cluster already has RHOAI + GPU
./setup.sh --agent-local /path/to/agent  # Use a local agent repo (dev mode)
./setup.sh --oc-context fbi-ucr          # Pin to a specific oc context (multi-session safety)
```

### Adding the FBI API key after the fact

If you ran `setup.sh` without `--fbi-api-key` and the user hits `403 API_KEY_MISSING` from `ucr_history`, patch the Secret and roll the pod:

```bash
oc --context=fbi-ucr -n fbi-mcp patch secret fbi-crime-stats-mcp-secrets \
  --type=merge -p '{"stringData":{"FBI_API_KEY":"YOUR_KEY_HERE"}}'
oc --context=fbi-ucr -n fbi-mcp rollout restart deployment/fbi-crime-stats-mcp
oc --context=fbi-ucr -n fbi-agent rollout restart deployment/fbi-crime-analyst-agent
```

The agent restart is needed so it re-establishes its MCP session against the rebuilt server.

---

## What gets deployed

| Workload | Namespace | Image / Source |
|---|---|---|
| gpt-oss-20b (vLLM) | `gpt-oss-model` | `registry.redhat.io/rhaiis/vllm-cuda-rhel9:3` serving `RedHatAI/gpt-oss-20b` |
| Predictive service | `fbi-ucr` | `quay.io/wjackson/crime-stats-api:latest` |
| MCP server | `fbi-mcp` | BuildConfig from [`fbi-crime-stats-mcp`](https://github.com/rdwj/fbi-crime-stats-mcp) |
| Agent | `fbi-agent` | BuildConfig from [`fbi-crime-analyst-agent`](https://github.com/redhat-ai-americas/fbi-crime-analyst-agent) |
| Gateway | `fbi-gateway` | BuildConfig from [`fbi-crime-analyst-gateway`](https://github.com/redhat-ai-americas/fbi-crime-analyst-gateway) |
| UI | `fbi-ui` | BuildConfig from [`fbi-crime-analyst-ui`](https://github.com/redhat-ai-americas/fbi-crime-analyst-ui) |

Source repos are pinned in `ansible/group_vars/all.yml` — change them in one place when the upstream repos move.

---

## Repo layout

```
.
├── setup.sh                  # one-shot entry point
├── scripts/
│   ├── generate_inventory.sh    # turn `oc whoami` into ansible inventory
│   └── deploy-fips-component.sh # generic agent/gateway/UI deploy via on-cluster BuildConfig + helm
├── ansible/
│   ├── site.yml              # cluster bring-up (NFD + GPU + RHOAI)
│   ├── fbi-deploy.yml        # FBI workloads
│   ├── group_vars/all.yml    # all knobs
│   └── roles/workshop_cluster/...  # 10-phase cluster setup role
├── operators/                # Subscription manifests (NFD, GPU, RHOAI)
├── operands/                 # DataScienceCluster, NFDInstance
├── gpu-operand/              # NVIDIA ClusterPolicy
├── namespaces/               # operator namespaces
├── auth/                     # HTPasswd OAuth (only used with --enable-htpasswd)
├── model/                    # gpt-oss-20b vLLM serving
└── manifests/
    ├── predictive-service/   # ns + deployment + service + route
    └── mcp-server/           # ns + deployment + service + route (BuildConfig is inline in fbi-deploy.yml)
```

---

## Provenance

The cluster bring-up automation (`ansible/`, `operators/`, `operands/`, `gpu-operand/`, `namespaces/`, `auth/`, `model/gpt-oss-20b.yaml`) is vendored from [redhat-ai-americas/openshift-ai-workshop-setup](https://github.com/redhat-ai-americas/openshift-ai-workshop-setup) (or wherever workshop-setup lives at vendoring time). Cluster-prep changes that aren't FBI-specific should go upstream there first.

The chatbot agent's system prompt is the canonical version maintained in [`fbi-crime-stats-mcp/system_prompts/fbi_crime_analyst_system_prompt.md`](https://github.com/rdwj/fbi-crime-stats-mcp/blob/main/system_prompts/fbi_crime_analyst_system_prompt.md). The agent repo vendors a copy.

---

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md).

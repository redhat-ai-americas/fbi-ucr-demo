# Troubleshooting

## Cluster bring-up

### `oc login` token rotates mid-run

If `setup.sh` was started with a kubeadmin token that subsequently rotates,
the inventory in `ansible/inventory/clusters.yml` will go stale. Re-run
`./scripts/generate_inventory.sh` and rerun `setup.sh --skip-cluster-setup`.

### GPU MachineSet stuck pending

Sandboxes-gpte clusters in `us-east-2` have intermittent `g6e.4xlarge` capacity.
If the GPU node never reports `nvidia.com/gpu` capacity, request a fresh sandbox
in `us-east-1` or `us-west-2`.

### RHOAI install plan stays unapproved

The role auto-approves the first unapproved plan. If a stale, already-rejected
plan blocks new ones, delete the Subscription and re-run `site.yml`.

## Predictive service

### `ImagePullBackOff` for `quay.io/wjackson/crime-stats-api:latest`

The image is currently on a personal quay namespace. If pulling fails (rate
limit / private), either: (a) push it to your own registry and update
`predictive_image` in `ansible/group_vars/all.yml`, or (b) build it from
[`fbi-ucr-predictive-service`](https://github.com/rdwj/fbi-ucr-predictive-service)
via a BuildConfig.

## MCP server

### Build fails because hardcoded URL

Until the upstream patch lands, the MCP server's `PREDICTION_API_URL` is
hardcoded in `src/tools/ucr_forecast.py` and `src/tools/ucr_compare.py`. The
demo expects an env-driven version. Track this in the demo TODO list; in the
meantime, set `mcp_repo_ref` to a branch that has the patch.

### `ucr_history` returns 401

You didn't pass `--fbi-api-key`. Get a free key from
<https://api.data.gov/signup/> and re-run with the flag.

## Agent

### Helm chart not deploying

The agent repo is created with `fips-agents create agent`. If the chart at
`chart/` is missing values that the demo passes in (`MCP_URL`, `LLM_URL`,
`LLM_MODEL`), edit `chart/values.yaml` in the agent repo to read those env
vars into its agent.yaml ConfigMap.

### Route 504 / timeout

Tool chains can take >30s. The MCP route is annotated with
`haproxy.router.openshift.io/timeout: 300s`; do the same on the agent's
route in its chart.

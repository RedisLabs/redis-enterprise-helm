# AI Helm Repository

This directory contains the AI-owned Helm charts in this monorepo.

Current chart layout:

- `ai/charts/redis-agent-memory`

## Making Changes

Update only the target chart directory for normal chart work.

Typical files:

- `Chart.yaml` for chart metadata and `version`
- `values.yaml` for defaults
- `templates/` for rendered Kubernetes resources
- `README.md` for chart-specific usage notes

When preparing a release, bump `version:` in `ai/charts/<chart-name>/Chart.yaml`. The Git tag is derived from that value as `<chart-name>-<version>`.

## Local Validation

Run validation before opening or merging changes:

```bash
helm lint ai/charts/redis-agent-memory
helm template redis-agent-memory ai/charts/redis-agent-memory
```

If the chart adds templates, make sure rendered output matches the expected resources and values.

## Release Process

AI chart releases are manual and run only from `master`.

Current release workflow:

- workflow: `.github/workflows/release-redis-agent-memory.yaml`
- chart: `ai/charts/redis-agent-memory`
- publication target: `gh-pages/ai/index.yaml`

Release steps:

1. Merge the chart change to `master`.
2. Confirm the desired chart version in `ai/charts/redis-agent-memory/Chart.yaml`.
3. In GitHub Actions, run `Release Redis Agent Memory Chart`.
4. Select the `master` branch when dispatching the workflow.

The workflow will:

- read the chart version from `Chart.yaml`
- create the tag `redis-agent-memory-<version>`
- package and publish the chart
- update the AI Helm repository index under `gh-pages/ai/`

## Consuming The Repo

Consumers can add the AI Helm repository with:

```bash
helm repo add redis-ai https://helm.redis.io/ai
helm repo update redis-ai
helm search repo redis-ai/redis-agent-memory --versions
```

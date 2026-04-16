# Repository Guidelines

## Project Structure & Module Organization

This Git repository is a monorepo containing separate Helm repositories. The existing Redis Enterprise Helm repo lives under `charts/`, with the operator chart at `charts/redis-enterprise-operator/`. The AI Helm repo lives under `ai/`, starting with `ai/charts/redis-agent-memory/`. Chart metadata belongs in `Chart.yaml`, defaults in `values.yaml`, docs in `README.md`, and rendered resources in `templates/`. Keep AI and non-AI chart content isolated.

## Build, Test, and Development Commands

Use Helm CLI commands against the specific chart path you are changing:

- `helm lint charts/redis-enterprise-operator` validates chart structure and templates.
- `helm lint ai/charts/redis-agent-memory` validates the AI chart.
- `helm template redis-enterprise-operator charts/redis-enterprise-operator` renders the operator chart locally.
- `helm template redis-agent-memory ai/charts/redis-agent-memory` renders the AI chart locally.
- `helm package <chart-path>` builds a distributable chart archive for a single chart.

For local verification, render with realistic overrides when needed, for example:
`helm template test charts/redis-enterprise-operator --set openshift.mode=true`.

## Coding Style & Naming Conventions

Write YAML and Helm templates with two-space indentation. Keep values keys lowercase camelCase, matching established patterns such as `imagePullSecrets`, `limitToNamespace`, and `operator.image.tag`. Template filenames should describe the resource they render. Reuse chart-local helpers rather than duplicating naming or annotation logic across repositories.

## Testing Guidelines

There is no dedicated test suite checked in, so treat `helm lint` and `helm template` as the baseline gate for every change. Validate only the chart you are changing. For AI releases, changes must stay inside `ai/charts/<chart-name>/` unless the work explicitly targets shared AI release workflow files. For operator changes, verify affected feature flags such as OpenShift mode and inspect rendered CRDs or jobs directly.

## Commit & Pull Request Guidelines

Recent history uses short imperative subjects such as `promoting version 8.0.16-25 (#38)`. Keep commit messages concise and scoped to a single chart or workflow change. Use `git town` when configured for the repo; otherwise use plain Git commands. PRs should explain which Helm repository is affected, note any value or release-flow changes, and include validation commands. Release triggers are chart-specific: `/release` for the Redis Enterprise operator flow and `/release-redis-agent-memory` for the AI chart flow.

## Agent-Specific Notes

Follow any rules defined under `.augment/rules/` when present in this repository or its subprojects. Do not introduce unrelated tooling or repo-wide conventions unless they are already in use here.

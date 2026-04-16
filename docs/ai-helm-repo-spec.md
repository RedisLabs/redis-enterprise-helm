# AI Helm Repository Spec

## Purpose

This document defines the target design for a dedicated Helm repository for AI-related products. The goal is to isolate AI chart ownership and release flow from unrelated product teams and repositories.

This git monorepo already contains a Helm repository for Redis Enterprise. The AI Helm repository will live alongside it as a separate Helm repository rooted under `ai/`.

## Scope

The new repository will host Helm charts for AI products only. It is expected to start with `redis-agent-memory` and may later include additional AI-owned charts if they share the same department, release governance, and publication destination.

This spec does not cover application image build pipelines. It covers chart source layout, validation, release gating, and Helm repository publication.

## Chart Repository Model

The monorepo contains multiple Helm repositories. The AI Helm repository is a dedicated area for AI-owned charts and must not contain non-AI product charts.

Initial structure to accommodate AI-owned charts:

```text
.github/
  workflows/
ai/charts/
  redis-agent-memory/
```

Each chart directory must contain at least:

- `Chart.yaml`
- `values.yaml`
- `README.md`
- `templates/` when the chart begins rendering resources

## Ownership and Change Boundaries

Each chart release PR must be chart-scoped.

Required rules:

- By default, the release workflow should fail if a release-triggered PR changes files outside `ai/charts/<chart-name>/`.
- CODEOWNERS should list the AI team members that are responsible for the AI chart repository.

## Versioning

Chart version is the source of truth for releases.

Rules:

- Release automation reads `version:` from `ai/charts/<chart-name>/Chart.yaml`.
- Git tag format is `<chart-name>-<version>`.
- `appVersion` may differ from chart version, but chart release automation keys off `version` only.

Example:

- Chart: `redis-agent-memory`
- Version: `0.3.4`
- Tag: `redis-agent-memory-0.3.4`

## Release Trigger

Each chart uses an explicit slash-command trigger on a pull request comment.

For `redis-agent-memory`, the release trigger is:

```text
/release-redis-agent-memory
```

Trigger requirements:

- The comment must be on a PR, not an issue.
- The PR must be open.
- The PR diff must be restricted to the target chart path.

The workflow must fail fast with a clear error if any condition is not satisfied.

## Release Workflow

The release implementation should use a reusable workflow plus thin product-specific wrappers.

Required behavior:

1. Wrapper workflow listens for the chart-specific slash command.
2. Reusable workflow validates PR state and changed-file scope.
3. Workflow checks out the PR head SHA.
4. Workflow reads the chart version from `Chart.yaml`.
5. Workflow creates and pushes the chart-specific Git tag.
6. Workflow packages and publishes only the target chart.
7. Workflow updates the Helm repository index and any generated HTML landing page if used.

The packaging step must isolate the target chart so multi-chart repo growth does not accidentally release unrelated charts.

## Validation Requirements

Minimum validation before release:

- `helm lint ai/charts/<chart-name>`
- `helm template <release-name> ai/charts/<chart-name>` for render validation

If templates or values files are still placeholders, lint warnings may be allowed, but lint or template failures must block release.

## Publication Model

The AI Helm repository is published separately from the existing Redis Enterprise Helm repository, even though both live in the same git monorepo.

The publication target uses GitHub Pages plus the reusable release workflow in `.github/workflows/release-chart-reusable.yaml`. That workflow is based on the existing `.github/workflows/release.yaml` flow, but it must publish AI chart artifacts and index content into a separate AI repository under `gh-pages/ai/`.

Required publication behavior:

- versioned `.tgz` chart packages are published for AI charts only
- an AI-specific `index.yaml` is maintained under `gh-pages/ai/`
- optional landing content such as `gh-pages/ai/index.html` may be generated
- release artifacts are attached to GitHub releases
- release artifacts are immutable once published

The implementation must not overwrite or regenerate the existing Redis Enterprise Helm repository index as part of an AI chart release.

Implementation requirement:

- `.github/workflows/release-chart-reusable.yaml` is the mechanism that packages the target AI chart, updates `gh-pages/ai/index.yaml`, and writes any optional AI landing-page content.
- The reusable AI release flow must preserve the current Redis Enterprise release behavior defined in `.github/workflows/release.yaml`.

## Non-Goals

The release workflow must not:

- release all charts in the repository by default
- infer the target chart from any changed folder automatically without an explicit trigger
- share a generic `/release` command across unrelated products

## Acceptance Criteria

The implementation is complete when:

- the AI repository lives under `ai/` and is clearly separated from the existing Redis Enterprise Helm repository
- the existing Redis Enterprise chart contents and release behavior remain unchanged
- `ai/charts/redis-agent-memory` exists as a valid chart
- a chart-scoped release workflow exists for `redis-agent-memory`
- the workflow fails if the PR touches files outside `ai/charts/redis-agent-memory/`
- the workflow tags releases as `redis-agent-memory-<version>`
- only the target chart is packaged and published
- the AI Helm repository publishes its own `gh-pages/ai/index.yaml` without modifying the Redis Enterprise Helm repository index

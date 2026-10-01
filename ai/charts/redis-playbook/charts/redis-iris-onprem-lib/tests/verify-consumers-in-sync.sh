#!/usr/bin/env bash
set -euo pipefail

# redis-iris-onprem-lib is a normal, independently-versioned, published
# Helm chart (see MOD-18434 / AGENTS.md's "Helm Releases" section):
# langcache/helm and memory/helm each pin an exact version of it in their
# own Chart.yaml, resolved from https://helm.redis.io/ai via `helm
# dependency build/update` -- exactly like depending on any third-party
# chart. Bumping the lib requires: bump this chart's own version, publish
# it via onprem-helm-lib-release.yml, then bump the pinned version (and
# re-run `helm dependency update`) in each consumer.
#
# A version MISMATCH between this chart and a consumer's pin is normal and
# expected while that bump is pending -- it only means the consumer hasn't
# picked up a newer release yet. What must never happen is a version
# MATCH with different content: that means someone edited this chart's
# templates without bumping its Chart.yaml version and republishing,
# silently violating the chart's version immutability. Every consumer
# that still has that same version vendored would then be carrying stale,
# unreviewed content under a version number that's supposed to be fixed.
#
# Consumers still resolving redis-iris-onprem-lib via a local file://
# dependency (before the follow-up PR repoints them at the published repo)
# are skipped, not diffed: `helm dependency build` would just repackage
# the vendored .tgz from this same local source, so any diff would always
# be a no-op comparison against itself.
#
# Usage: verify-consumers-in-sync.sh <consumer-chart-dir> [<consumer-chart-dir> ...]
# e.g.:  verify-consumers-in-sync.sh langcache/helm memory/helm

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <consumer-chart-dir> [<consumer-chart-dir> ...]" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$(cd "${script_dir}/.." && pwd)"
lib_version="$(grep -E '^version:' "${lib_dir}/Chart.yaml" | awk '{print $2}')"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

echo "==> Packaging local redis-iris-onprem-lib source (version ${lib_version})"
helm package "${lib_dir}" -d "${work_dir}/local" >/dev/null
mkdir -p "${work_dir}/local-extracted"
tar -xzf "${work_dir}/local/redis-iris-onprem-lib-${lib_version}.tgz" -C "${work_dir}/local-extracted"

status=0
for consumer_dir in "$@"; do
  consumer_chart="${consumer_dir}/Chart.yaml"
  if [[ ! -f "${consumer_chart}" ]]; then
    echo "ERROR: ${consumer_chart} not found" >&2
    status=1
    continue
  fi

  pinned_version="$(awk '
    /- name: redis-iris-onprem-lib/ { found=1; next }
    found && /- name:/ { found=0 }
    found && /version:/ { print $2; exit }
  ' "${consumer_chart}")"

  pinned_repository="$(awk '
    /- name: redis-iris-onprem-lib/ { found=1; next }
    found && /- name:/ { found=0 }
    found && /repository:/ { print $2; exit }
  ' "${consumer_chart}")"

  if [[ -z "${pinned_version}" ]]; then
    echo "ERROR: ${consumer_chart} does not declare a redis-iris-onprem-lib dependency version" >&2
    status=1
    continue
  fi

  # While the consumer still resolves redis-iris-onprem-lib via a file://
  # path (pre-MOD-18434-follow-up), `helm dependency build` always
  # repackages the vendored .tgz straight from this same local source tree
  # -- so comparing it back against a fresh local package can never detect
  # drift, it just diffs a source against itself. Skip rather than print a
  # false OK; this activates for real once the consumer is repointed at the
  # published https://helm.redis.io/ai repository, where `dependency build`
  # fetches an independently-published artifact to diff against.
  if [[ "${pinned_repository}" == file://* ]]; then
    echo "SKIP: ${consumer_dir} still resolves redis-iris-onprem-lib via ${pinned_repository} -- drift detection needs the published repository (pending follow-up PR)"
    continue
  fi

  if [[ "${pinned_version}" != "${lib_version}" ]]; then
    echo "SKIP: ${consumer_dir} pins redis-iris-onprem-lib ${pinned_version}, local source is ${lib_version} (pending bump, not a drift)"
    continue
  fi

  vendored_tgz="${consumer_dir}/charts/redis-iris-onprem-lib-${pinned_version}.tgz"
  if [[ ! -f "${vendored_tgz}" ]]; then
    echo "ERROR: ${consumer_dir} pins redis-iris-onprem-lib ${pinned_version} but ${vendored_tgz} is missing -- run 'helm dependency build ${consumer_dir}'" >&2
    status=1
    continue
  fi

  vendored_extracted="${work_dir}/vendored-$(basename "${consumer_dir}")"
  mkdir -p "${vendored_extracted}"
  tar -xzf "${vendored_tgz}" -C "${vendored_extracted}"

  if diff -r "${work_dir}/local-extracted/redis-iris-onprem-lib" "${vendored_extracted}/redis-iris-onprem-lib" >/dev/null 2>&1; then
    echo "OK: ${consumer_dir} pins redis-iris-onprem-lib ${pinned_version}, content matches local source"
  else
    echo "ERROR: ${consumer_dir} pins redis-iris-onprem-lib ${pinned_version}, but common/helm/lib/onprem's" >&2
    echo "       content no longer matches what's vendored at that version. common/helm/lib/onprem was" >&2
    echo "       edited without bumping its Chart.yaml version and republishing via" >&2
    echo "       onprem-helm-lib-release.yml. Bump the version, publish it, then bump the pinned" >&2
    echo "       version in ${consumer_chart} and run 'helm dependency update ${consumer_dir}'." >&2
    diff -r "${work_dir}/local-extracted/redis-iris-onprem-lib" "${vendored_extracted}/redis-iris-onprem-lib" >&2 || true
    status=1
  fi
done

exit "${status}"

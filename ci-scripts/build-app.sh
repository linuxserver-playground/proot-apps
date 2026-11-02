#! /bin/bash
set -e

# Build one app, record its packages in package_versions.txt and push it to GHCR, in one pass:
#   build-app.sh <name> <platforms> push    always push: its files changed, or someone asked for it
#   build-app.sh <name> <platforms> check   push only when its packages changed (the daily package check)
# amd64 is built and scanned first; the push then builds the other arches and takes amd64 from the builder's
# cache, so the image pushed is the image scanned. package_versions.txt changes only once the push succeeded, and
# the workflow commits it with GITHUB_TOKEN, which starts no second run.
# Registry pulls and pushes (the app's base image, syft) retry on GHCR rate limits, and each build is tried once
# more when an upstream download failed for a reason outside the app (upstream_retry).

NAME=$1
PLATFORMS=$2
MODE=$3
SYFT=ghcr.io/anchore/syft:v1.26.1
REPO="${GITHUB_REPOSITORY,,}"

# shellcheck source=ci-scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# What a failed upstream download looks like in the build output. Most Dockerfiles ask api.github.com for the
# latest release without a token, and a runner over GitHub's unauthenticated limit gets no tag_name back: the
# asset URL then names release "null", GitHub answers 404 with the 9 bytes "Not Found", and the build fails on
# that body as a .deb (apt) or as an AppImage run by sh. The curl codes are connection, TLS and transfer errors.
UPSTREAM_FLAKE='Could not read meta data from /tmp/|: 1: Not: not found|curl: \((5|6|7|16|18|28|35|52|55|56|92)\)'
# The longest wait for the runner's API limit to reset before the one retry; past it the retry is not made.
UPSTREAM_MAX_WAIT=600

# Run a build; when it fails with UPSTREAM_FLAKE in its output, run it once more after a pause: until the
# runner's GitHub API limit resets when that is spent, else a minute. Anything else fails at once.
upstream_retry() {
  local log status limit remaining reset pause=60
  log=$(mktemp)
  set +e
  "$@" 2>&1 | tee "${log}"
  status=${PIPESTATUS[0]}
  set -e
  if (( status == 0 )) || ! grep -q -E "${UPSTREAM_FLAKE}" "${log}"; then
    rm -f "${log}"
    return "${status}"
  fi
  rm -f "${log}"
  # /rate_limit does not count against the limit; it says whether this runner's address has spent it
  limit=$(curl -s --max-time 10 https://api.github.com/rate_limit || true)
  remaining=$(jq -r '.resources.core.remaining // empty' <<< "${limit}" 2>/dev/null || true)
  reset=$(jq -r '.resources.core.reset // empty' <<< "${limit}" 2>/dev/null || true)
  if [[ "${reset}" =~ ^[0-9]+$ ]]; then
    echo "GitHub API from this runner: ${remaining:-?} requests left, resets $(date -u -d "@${reset}" +%H:%M:%S) UTC"
  fi
  if [[ "${remaining}" == "0" && "${reset}" =~ ^[0-9]+$ ]]; then
    pause=$(( reset - $(date +%s) + 5 ))
    (( pause < 5 )) && pause=5
    if (( pause > UPSTREAM_MAX_WAIT )); then
      echo "::warning title=${NAME}::upstream download failed and this runner's GitHub API limit resets in ${pause}s; not retrying"
      return "${status}"
    fi
  fi
  echo "::warning title=${NAME}::upstream download failed outside the app; building once more in ${pause}s"
  sleep "${pause}"
  "$@"
}

cd "apps/${NAME}"
upstream_retry retry_ghcr docker buildx build --load \
  --platform linux/amd64 \
  --build-arg "REPO=${REPO}" \
  --tag "${NAME}:scan" .
retry_ghcr docker pull -q "${SYFT}"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v "$(pwd)":/tmp \
  "${SYFT}" \
  "${NAME}:scan" -o table=/tmp/package_versions_check.txt
if [[ -f package_versions.txt ]] && diff -q package_versions_check.txt package_versions.txt > /dev/null; then
  if [[ "${MODE}" == "check" ]]; then
    echo "No package changes in ${NAME}: nothing to push"
    rm -f package_versions_check.txt
    exit 0
  fi
else
  echo "Package changes in ${NAME}:"
  diff package_versions.txt package_versions_check.txt || true
fi
upstream_retry retry_ghcr docker buildx build --push \
  --platform "${PLATFORMS}" \
  --build-arg "REPO=${REPO}" \
  --tag "ghcr.io/${REPO}:${NAME}" .
mv package_versions_check.txt package_versions.txt

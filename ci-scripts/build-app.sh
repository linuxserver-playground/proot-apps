#! /bin/bash
set -e

# Build one app, record its packages in package_versions.txt and push it to GHCR, in one pass:
#   build-app.sh <name> <platforms> push    always push: its files changed, or someone asked for it
#   build-app.sh <name> <platforms> check   push only when its packages changed (the daily package check)
# amd64 is built and scanned first; the push then builds the other arches and takes amd64 from the builder's
# cache, so the image pushed is the image scanned. package_versions.txt changes only once the push succeeded, and
# the workflow commits it with GITHUB_TOKEN, which starts no second run.
# Registry pulls and pushes (the app's base image, syft) retry on GHCR rate limits.

NAME=$1
PLATFORMS=$2
MODE=$3
SYFT=ghcr.io/anchore/syft:v1.26.1
REPO="${GITHUB_REPOSITORY,,}"

# shellcheck source=ci-scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cd "apps/${NAME}"
retry_ghcr docker buildx build --load \
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
retry_ghcr docker buildx build --push \
  --platform "${PLATFORMS}" \
  --build-arg "REPO=${REPO}" \
  --tag "ghcr.io/${REPO}:${NAME}" .
mv package_versions_check.txt package_versions.txt

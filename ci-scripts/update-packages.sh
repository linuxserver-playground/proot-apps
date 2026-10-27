#! /bin/bash
set -e

# Rebuild one app and record its packages in package_versions.txt.
# Registry pulls (the app's base image, syft) retry on GHCR rate limits.

IMAGE=$1
SYFT=ghcr.io/anchore/syft:v1.26.1

# shellcheck source=ci-scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cd "apps/${IMAGE}"
retry_ghcr docker build --build-arg "REPO=${GITHUB_REPOSITORY,,}" -t "${IMAGE}:latest" .
retry_ghcr docker pull -q "${SYFT}"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v "$(pwd)":/tmp \
  "${SYFT}" \
  "${IMAGE}:latest" -o table=/tmp/package_versions_check.txt
if [ ! -f 'package_versions.txt' ]; then
  mv package_versions_check.txt package_versions.txt
elif ! diff -q package_versions_check.txt package_versions.txt; then
  mv package_versions_check.txt package_versions.txt
else
  rm -f package_versions_check.txt
fi

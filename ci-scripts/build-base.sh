#! /bin/bash
set -e

# Build and push one base image (base-images/Dockerfile.<name>) for both arches; the apps build FROM these tags.

NAME=$1

# shellcheck source=ci-scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cd base-images
retry_ghcr docker buildx build --push \
  --file "Dockerfile.${NAME}" \
  --platform linux/amd64,linux/arm64 \
  --build-arg "REPO=${GITHUB_REPOSITORY,,}" \
  --tag "ghcr.io/${GITHUB_REPOSITORY,,}:${NAME}" .

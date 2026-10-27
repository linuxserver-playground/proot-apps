#!/bin/bash

set -e

GH_USER=$(echo ${GITHUB_REPOSITORY,,} | awk -F'/' '{print $1}')
GH_REPO=$(echo ${GITHUB_REPOSITORY,,} | awk -F'/' '{print $2}')

# proot binaries come prebuilt from proot-next
# PROOT_CHANNEL=prerelease ingests the build of the latest commit to main
# PROOT_CHANNEL=release ingests the latest stable release
# PROOT_TAG pins a specific proot-next release tag and overrides both
PROOT_REPO=selkies-project/proot-next
PROOT_CHANNEL=${PROOT_CHANNEL:-release}

# Every download retries, so a network flake does not fail the release
CURL_RETRY=(--retry 5 --retry-delay 5 --retry-all-errors)

# Authenticate API calls when a token is available to avoid rate limits
gh_api() {
  if [ -n "${GITHUB_TOKEN}" ]; then
    curl -fsSL "${CURL_RETRY[@]}" -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/${1}"
  else
    curl -fsSL "${CURL_RETRY[@]}" "https://api.github.com/${1}"
  fi
}

if [ -z "${PROOT_TAG}" ]; then
  if [ "${PROOT_CHANNEL}" == "prerelease" ]; then
    # proot-next names pre-releases by the short sha of the commit they were built from
    PROOT_TAG=$(gh_api repos/${PROOT_REPO}/commits/main \
      | awk '/"sha"/ && !f{print $4;f=1}' FS='[""]' | cut -c1-7)
  else
    PROOT_TAG=$(gh_api repos/${PROOT_REPO}/releases/latest \
      | awk '/tag_name/ && !f{print $4;f=1}' FS='[""]')
  fi
fi
if [ -z "${PROOT_TAG}" ]; then
  echo "Unable to resolve a proot-next ${PROOT_CHANNEL} tag"
  exit 1
fi
echo "Using proot-next ${PROOT_TAG}"
if [ -n "${GITHUB_OUTPUT}" ]; then
  echo "proot_tag=${PROOT_TAG}" >> "${GITHUB_OUTPUT}"
fi

PROOT_URL=https://github.com/${PROOT_REPO}/releases/download/${PROOT_TAG}

for ARCH in amd64 arm64; do

  UNAME_ARCH=$(echo $ARCH | sed -e 's/amd64/x86_64/g' -e 's/arm64/aarch64/g')

  # Add jq and our script
  rm -Rf dist/ proot/
  mkdir -p dist
  cp proot-apps dist/
  sed -i \
    -e "s/REPLACE_USER/${GH_USER}/g" \
    -e "s/REPLACE_REPO/${GH_REPO}/g" \
    dist/proot-apps
  JQ_RELEASE=$(gh_api repos/jqlang/jq/releases/latest \
    | awk '/tag_name/ && !f{print $4;f=1}' FS='[""]');
  curl -fL "${CURL_RETRY[@]}" \
    -o dist/jq \
    https://github.com/jqlang/jq/releases/download/${JQ_RELEASE}/jq-linux-${ARCH}
  curl -fL "${CURL_RETRY[@]}" \
    -o dist/ncat \
    https://github.com/${GH_USER}/${GH_REPO}/raw/bins/ncat/ncat-${ARCH}

  # Ingest proot and verify it against the published checksum
  mkdir -p proot
  curl -fL "${CURL_RETRY[@]}" \
    -o proot/proot-${UNAME_ARCH} \
    ${PROOT_URL}/proot-${UNAME_ARCH}
  curl -fL "${CURL_RETRY[@]}" \
    -o proot/proot-${UNAME_ARCH}.sha256 \
    ${PROOT_URL}/proot-${UNAME_ARCH}.sha256
  (cd proot && sha256sum -c proot-${UNAME_ARCH}.sha256)
  mv proot/proot-${UNAME_ARCH} dist/proot

  # Create dist tarball
  cd dist/
  chmod +x * || :
  tar -czf proot-apps-${UNAME_ARCH}.tar.gz *
  mv proot-apps-${UNAME_ARCH}.tar.gz ../
  cd ..

  # Cleanup
  rm -Rf proot/ dist/
done

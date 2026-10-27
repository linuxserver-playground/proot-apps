#!/usr/bin/env bash
# Retry helpers for the workflows and ci-scripts. Source it; do not execute it.
#
#   source ci-scripts/lib.sh
#   retry_ghcr docker buildx build --push ...
#   retry 5 10 curl -fsSL ...
#
# Vendored from linuxserver-playground/workflows scripts/lib.sh (retry_ghcr and retry, as of a0046b4), which
# every image build uses. Keep the two in step: fix a bug there first, then copy it here.

# retry_ghcr <command...>: run a registry-touching command, retrying on rate
# limits with exponential backoff and jitter. Modelled on the Jenkinsfile's
# function of the same name: any failure that does not look like a rate limit
# is returned immediately. RETRY_ALSO adds one more error pattern to retry on.
retry_ghcr() {
  local max_attempts="${RETRY_MAX_ATTEMPTS:-7}"
  local base_delay="${RETRY_BASE_DELAY:-10}"
  local max_delay="${RETRY_MAX_DELAY:-90}"
  local attempt=1
  local errfile exit_code delay pause
  local retry_on='retry-after:|toomanyrequests|too many requests|429 Too Many|rate limit|403 Forbidden|^denied$'
  retry_on+="${RETRY_ALSO:+|${RETRY_ALSO}}"
  errfile=$(mktemp)
  while true; do
    # Run inside an if so a caller's set -e cannot abort before we get to retry. stderr is teed into
    # errfile so the rate-limit check can read it while the caller still sees it live.
    local tee_pid=""
    if "$@" 2> >(tee "${errfile}" >&2); then
      exit_code=0
    else
      exit_code=$?
    fi
    # Make sure tee has finished writing before we read the file. Under set -u, $! is unset when bash
    # did not record the process substitution's pid, so guard it.
    tee_pid="${!:-}"
    if [[ -n "${tee_pid}" ]]; then
      wait "${tee_pid}" 2>/dev/null || true
    fi
    if [[ "${exit_code}" == "0" ]]; then
      rm -f "${errfile}"
      return 0
    # 403 "denied" is retried too: when two runs of one repo create a new GHCR package at the same moment,
    # the loser's manifest PUT is refused for a few seconds while GHCR grants the repository access.
    # Only registry wording counts: a bare "429" also matches the digests BuildKit prints, which once retried a
    # deterministic build failure seven times.
    elif ! grep -q -i -E "${retry_on}" "${errfile}"; then
      rm -f "${errfile}"
      return "${exit_code}"
    elif (( attempt >= max_attempts )); then
      rm -f "${errfile}"
      echo "retry: $* failed after ${attempt} attempts (exit ${exit_code})" >&2
      return "${exit_code}"
    else
      # Exponential delay: base * 2^(attempt-1), capped at max_delay.
      delay=$(( base_delay * 2 ** (attempt - 1) ))
      (( delay > max_delay )) && delay="${max_delay}"
      # Jitter between half and full delay so parallel builds spread out.
      pause=$(( delay / 2 + RANDOM % (delay / 2 + 1) ))
      echo "retry: attempt ${attempt}/${max_attempts} failed (exit ${exit_code}); waiting ${pause}s..." >&2
      sleep "${pause}"
      ((attempt++))
    fi
  done
}

# retry <attempts> <delay> <command...>: plain fixed-delay retry for flaky
# network calls (git push, gh api) where the error text is not informative.
retry() {
  local attempts="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    if (( n >= attempts )); then
      echo "retry: $* failed after ${n} attempts" >&2
      return 1
    fi
    echo "retry: attempt ${n}/${attempts} failed; waiting ${delay}s..." >&2
    sleep "${delay}"
    ((n++))
  done
}

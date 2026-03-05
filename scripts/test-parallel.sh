#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_SHARDS_FILE="${SCRIPT_DIR}/test-shards.txt"
DEFAULT_BUILD_OPTIONS="${SCRIPT_DIR}/build_options.test.zig"
DEFAULT_CACHE_DIR="${REPO_ROOT}/.zig-cache"
DEFAULT_GLOBAL_CACHE_DIR="${REPO_ROOT}/.zig-global-cache"

if command -v nproc >/dev/null 2>&1; then
  DEFAULT_JOBS="$(nproc)"
elif command -v getconf >/dev/null 2>&1; then
  DEFAULT_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
else
  DEFAULT_JOBS=4
fi

# Cap default fan-out to keep self-hosted runners stable.
if (( DEFAULT_JOBS > 8 )); then
  DEFAULT_JOBS=8
fi
if (( DEFAULT_JOBS < 1 )); then
  DEFAULT_JOBS=1
fi

JOBS="${WS_TEST_JOBS:-$DEFAULT_JOBS}"
SHARDS_FILE="${WS_TEST_SHARDS_FILE:-$DEFAULT_SHARDS_FILE}"
BUILD_OPTIONS="${WS_TEST_BUILD_OPTIONS:-$DEFAULT_BUILD_OPTIONS}"
CACHE_DIR="${WS_TEST_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
GLOBAL_CACHE_DIR="${WS_TEST_GLOBAL_CACHE_DIR:-$DEFAULT_GLOBAL_CACHE_DIR}"
ZIG_BIN="${ZIG_BIN:-zig}"
SHARDS_CSV="${WS_TEST_SHARDS:-}"
LIST_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/test-parallel.sh [options]

Options:
  -j, --jobs <N>          Number of shards to run in parallel
  -f, --shards-file <P>   Path to shards list file
  -s, --shards <CSV>      Comma-separated shard filters (overrides file)
      --build-options <P> Path to build_options module
      --cache-dir <P>     Local zig cache dir (default: .zig-cache)
      --global-cache-dir <P>
                           Local zig global cache dir (default: .zig-global-cache)
      --list              Print resolved shards and exit
  -h, --help              Show this help

Environment overrides:
  WS_TEST_JOBS, WS_TEST_SHARDS_FILE, WS_TEST_SHARDS, WS_TEST_BUILD_OPTIONS,
  WS_TEST_CACHE_DIR, WS_TEST_GLOBAL_CACHE_DIR, ZIG_BIN
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -j|--jobs)
      JOBS="${2:-}"
      shift 2
      ;;
    -f|--shards-file)
      SHARDS_FILE="${2:-}"
      shift 2
      ;;
    -s|--shards)
      SHARDS_CSV="${2:-}"
      shift 2
      ;;
    --build-options)
      BUILD_OPTIONS="${2:-}"
      shift 2
      ;;
    --cache-dir)
      CACHE_DIR="${2:-}"
      shift 2
      ;;
    --global-cache-dir)
      GLOBAL_CACHE_DIR="${2:-}"
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! [[ "${JOBS}" =~ ^[0-9]+$ ]] || (( JOBS < 1 )); then
  echo "Invalid --jobs value: ${JOBS}" >&2
  exit 2
fi

if [[ ! -f "${BUILD_OPTIONS}" ]]; then
  echo "build_options file not found: ${BUILD_OPTIONS}" >&2
  exit 2
fi

mkdir -p "${CACHE_DIR}" "${GLOBAL_CACHE_DIR}"

declare -a SHARDS=()
if [[ -n "${SHARDS_CSV}" ]]; then
  IFS=',' read -r -a SHARDS <<< "${SHARDS_CSV}"
else
  if [[ ! -f "${SHARDS_FILE}" ]]; then
    echo "shards file not found: ${SHARDS_FILE}" >&2
    exit 2
  fi
  mapfile -t SHARDS < <(grep -E -v '^[[:space:]]*($|#)' "${SHARDS_FILE}")
fi

if (( ${#SHARDS[@]} == 0 )); then
  echo "No shards configured." >&2
  exit 2
fi

if (( LIST_ONLY == 1 )); then
  printf '%s\n' "${SHARDS[@]}"
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ws-test-parallel.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "${REPO_ROOT}"

run_shard() {
  local shard="$1"
  local safe
  local log_file
  local status_file
  local start_ns
  local end_ns
  local elapsed_ms

  safe="$(printf '%s' "${shard}" | tr -c 'A-Za-z0-9_.-' '_')"
  log_file="${TMP_DIR}/${safe}.log"
  status_file="${TMP_DIR}/${safe}.status"
  start_ns="$(date +%s%N)"

  if "${ZIG_BIN}" test \
    --dep build_options \
    -Mroot="${REPO_ROOT}/src/main.zig" \
    -Mbuild_options="${BUILD_OPTIONS}" \
    --cache-dir "${CACHE_DIR}" \
    --global-cache-dir "${GLOBAL_CACHE_DIR}" \
    --test-filter "${shard}" \
    >"${log_file}" 2>&1; then
    end_ns="$(date +%s%N)"
    elapsed_ms="$(( (end_ns - start_ns) / 1000000 ))"
    printf 'PASS\t%s\t%s\t%s\n' "${shard}" "${elapsed_ms}" "${log_file}" > "${status_file}"
    return 0
  fi

  end_ns="$(date +%s%N)"
  elapsed_ms="$(( (end_ns - start_ns) / 1000000 ))"
  printf 'FAIL\t%s\t%s\t%s\n' "${shard}" "${elapsed_ms}" "${log_file}" > "${status_file}"
  return 1
}

export -f run_shard
export REPO_ROOT BUILD_OPTIONS CACHE_DIR GLOBAL_CACHE_DIR TMP_DIR ZIG_BIN

echo "Running ${#SHARDS[@]} shards with ${JOBS} parallel workers"
echo "Repo: ${REPO_ROOT}"
echo "Build options: ${BUILD_OPTIONS}"
echo "Cache dir: ${CACHE_DIR}"
echo "Global cache dir: ${GLOBAL_CACHE_DIR}"

START_ALL_NS="$(date +%s%N)"
set +e
printf '%s\n' "${SHARDS[@]}" | xargs -I{} -P "${JOBS}" bash -c 'run_shard "$@"' _ {}
XARGS_EXIT=$?
set -e
END_ALL_NS="$(date +%s%N)"
TOTAL_MS="$(( (END_ALL_NS - START_ALL_NS) / 1000000 ))"

mapfile -t STATUS_FILES < <(find "${TMP_DIR}" -maxdepth 1 -type f -name '*.status' | sort)

if (( ${#STATUS_FILES[@]} == 0 )); then
  echo "No shard status files generated." >&2
  exit 1
fi

echo
echo "Shard results:"
for file in "${STATUS_FILES[@]}"; do
  IFS=$'\t' read -r state shard elapsed_ms log_file < "${file}"
  printf '  %-4s %7sms  %s\n' "${state}" "${elapsed_ms}" "${shard}"
done

echo
echo "Total wall time: ${TOTAL_MS}ms"

if (( XARGS_EXIT != 0 )); then
  echo
  echo "Failed shard logs:"
  for file in "${STATUS_FILES[@]}"; do
    IFS=$'\t' read -r state shard elapsed_ms log_file < "${file}"
    if [[ "${state}" == "FAIL" ]]; then
      echo "----- ${shard} (${elapsed_ms}ms) -----"
      sed -n '1,120p' "${log_file}"
    fi
  done
  exit 1
fi

echo "All shards passed."

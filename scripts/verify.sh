#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required_swift_version="6.3.2"
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift ${required_swift_version} is required, but swift was not found." >&2
    exit 1
fi

if ! swift_version_output="$(swift --version 2>&1)"; then
    printf '%s\n' "$swift_version_output" >&2
    exit 1
fi
if ! printf '%s\n' "$swift_version_output" | grep -Eq "Swift version ${required_swift_version//./\\.}([[:space:]]|$)"; then
    printf 'Swift %s is required; detected:\n%s\n' "$required_swift_version" "$swift_version_output" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for the smoke checks, but it was not found." >&2
    exit 1
fi

cleanup_scratch=0
if [[ -n "${VERIFY_SCRATCH_PATH:-}" ]]; then
    scratch_path="$VERIFY_SCRATCH_PATH"
else
    scratch_path="$(mktemp -d "${TMPDIR:-/tmp}/gh-assigned-verify.XXXXXX")"
    cleanup_scratch=1
fi
mkdir -p "$scratch_path"

cleanup() {
    if ((cleanup_scratch)); then
        rm -rf -- "$scratch_path"
    fi
}
trap cleanup EXIT

echo "Using Swift ${required_swift_version}; scratch path: ${scratch_path}"
swift build --scratch-path "$scratch_path"
swift test --scratch-path "$scratch_path"
swift build --configuration release --scratch-path "$scratch_path"
python3 "$ROOT/scripts/smoke.py" \
    "$scratch_path/debug/gh-assigned" \
    "$scratch_path/release/gh-assigned"
python3 "$ROOT/scripts/screen_smoke.py" "$scratch_path/release/gh-assigned"

#!/usr/bin/env bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck disable=SC1090
source "${project_dir}/scripts/e2e.sh"

for version in 31.0 31.1 31.2 32.0 32.0.50 32.1 33.0 34.1; do
  if ! supported_emacs_version "${version}"; then
    echo "Expected Emacs ${version} to be supported." >&2
    exit 1
  fi
done

for version in 29.4 30.2 31 32 invalid; do
  if supported_emacs_version "${version}"; then
    echo "Expected Emacs ${version} to be rejected." >&2
    exit 1
  fi
done

if BRUTAL_PAPER_E2E_SEED=invalid bash "${project_dir}/scripts/e2e.sh" \
  >/dev/null 2>&1; then
  echo "Expected the E2E launcher to reject an invalid seed." >&2
  exit 1
fi

echo "E2E launcher checks passed."

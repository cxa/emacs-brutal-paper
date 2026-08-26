#!/usr/bin/env bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture_file="${project_dir}/scripts/e2e-init.el"
minimum_emacs_version="31.0"
theme_seed="${BRUTAL_PAPER_E2E_SEED:-$(( (RANDOM << 16) ^ RANDOM ^ $$ ))}"
yabai_bin=""
yabai_rule_label=""
ready_dir=""

supported_emacs_version() {
  local version="$1"
  local major minor

  if [[ ! "${version}" =~ ^([0-9]+)\.([0-9]+)(\.|$) ]]; then
    return 1
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  (( major >= 31 ))
}

discover_emacs_apps() {
  local -a search_roots=(
    "${HOME}/Application"
    "${HOME}/Applications"
    "/Applications"
  )
  local brew_prefix=""
  local candidate real_app bundle_id version existing
  local -a real_apps=()
  local -a records=()

  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "${brew_prefix}" ]]; then
      search_roots+=("${brew_prefix}/opt")
    fi
  fi

  while IFS= read -r -d '' candidate; do
    [[ -d "${candidate}" ]] || continue
    bundle_id="$(/usr/libexec/PlistBuddy \
      -c 'Print :CFBundleIdentifier' \
      "${candidate}/Contents/Info.plist" 2>/dev/null || true)"
    [[ "${bundle_id}" == "org.gnu.Emacs" ]] || continue

    version="$(/usr/libexec/PlistBuddy \
      -c 'Print :CFBundleShortVersionString' \
      "${candidate}/Contents/Info.plist" 2>/dev/null || true)"
    if ! supported_emacs_version "${version}"; then
      continue
    fi

    real_app="$(cd -- "${candidate}" 2>/dev/null && pwd -P)" || continue
    for existing in "${real_apps[@]}"; do
      if [[ "${existing}" == "${real_app}" ]]; then
        real_app=""
        break
      fi
    done
    [[ -n "${real_app}" ]] || continue
    real_apps+=("${real_app}")

    records+=("${version}"$'\t'"${candidate}")
  done < <(
    if command -v mdfind >/dev/null 2>&1; then
      while IFS= read -r candidate; do
        printf '%s\0' "${candidate}"
      done < <(mdfind 'kMDItemCFBundleIdentifier == "org.gnu.Emacs"')
    fi
    for candidate in "${search_roots[@]}"; do
      if [[ -d "${candidate}" ]]; then
        find -L "${candidate}" -maxdepth 4 -type d \
          -name '*.app' -prune -print0 2>/dev/null
      fi
    done
  )

  if [[ ${#records[@]} -eq 0 ]]; then
    echo "No Emacs ${minimum_emacs_version}+ app bundles found." >&2
    return 1
  fi

  while IFS=$'\t' read -r version candidate; do
    emacs_apps+=("${candidate}")
    emacs_labels+=("${version} · $(basename -- "${candidate}" .app)")
  done < <(printf '%s\n' "${records[@]}" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2)
}

stop_previous_e2e_instances() {
  local -a pids=()
  local pid command

  while read -r pid command; do
    if [[ "${command}" == *"/Contents/MacOS/Emacs"* &&
          "${command}" == *"--load ${fixture_file}"* ]]; then
      pids+=("${pid}")
    fi
  done < <(ps -axo pid=,command=)

  if [[ ${#pids[@]} -eq 0 ]]; then
    return
  fi

  echo "Stopping ${#pids[@]} previous Brutal Paper E2E Emacs instances..."
  kill -TERM "${pids[@]}" 2>/dev/null || true

  for _ in {1..50}; do
    local -a remaining=()
    for pid in "${pids[@]}"; do
      if kill -0 "${pid}" 2>/dev/null; then
        remaining+=("${pid}")
      fi
    done
    if [[ ${#remaining[@]} -eq 0 ]]; then
      return
    fi
    pids=("${remaining[@]}")
    sleep 0.1
  done

  echo "Force-stopping ${#pids[@]} unresponsive E2E instances..."
  kill -KILL "${pids[@]}" 2>/dev/null || true
}

install_yabai_float_rule() {
  yabai_bin="$(command -v yabai || true)"
  if [[ -z "${yabai_bin}" ]] || ! pgrep -x yabai >/dev/null; then
    return
  fi

  yabai_rule_label="brutal-paper-e2e-float-$$"
  "${yabai_bin}" -m rule --add \
    "label=${yabai_rule_label}" \
    'app=^Emacs$' \
    manage=off
  echo "Floating newly launched Emacs frames through yabai..."
}

remove_yabai_float_rule() {
  if [[ -n "${yabai_rule_label}" ]]; then
    "${yabai_bin}" -m rule --remove "${yabai_rule_label}" \
      >/dev/null 2>&1 || true
    yabai_rule_label=""
  fi
}

cleanup() {
  remove_yabai_float_rule
  if [[ -n "${ready_dir}" && -d "${ready_dir}" ]]; then
    rm -rf -- "${ready_dir}"
    ready_dir=""
  fi
}

stop_stalled_launch() {
  local emacs_app="$1"
  local pid command

  while read -r pid command; do
    if [[ "${command}" == "${emacs_app}/Contents/MacOS/"* &&
          "${command}" == *"--load ${fixture_file}"* ]]; then
      kill -TERM "${pid}" 2>/dev/null || true
    fi
  done < <(ps -axo pid=,command=)
}

wait_for_launches() {
  local -a remaining=()
  local launch index
  local failed=0

  for _ in {1..150}; do
    remaining=()
    for index in "${!launches[@]}"; do
      launch="${launches[index]}"
      if kill -0 "${launch}" 2>/dev/null; then
        remaining+=("${index}")
      fi
    done
    if [[ ${#remaining[@]} -eq 0 ]]; then
      break
    fi
    sleep 0.1
  done

  for index in "${remaining[@]}"; do
    launch="${launches[index]}"
    echo "Emacs ${emacs_labels[index]} did not finish launching; stopping its E2E process." >&2
    kill -TERM "${launch}" 2>/dev/null || true
    stop_stalled_launch "${emacs_apps[index]}"
    failed=1
  done

  for index in "${!launches[@]}"; do
    launch="${launches[index]}"
    if ! wait "${launch}"; then
      echo "Failed to ask Emacs ${emacs_labels[index]} to launch." >&2
      stop_stalled_launch "${emacs_apps[index]}"
      failed=1
    fi
  done

  (( failed == 0 )) || return 1

  for _ in {1..150}; do
    remaining=()
    for index in "${!ready_files[@]}"; do
      if [[ ! -f "${ready_files[index]}" ]]; then
        remaining+=("${index}")
      fi
    done
    if [[ ${#remaining[@]} -eq 0 ]]; then
      return 0
    fi
    sleep 0.1
  done

  for index in "${remaining[@]}"; do
    echo "Emacs ${emacs_labels[index]} did not finish the E2E fixture." >&2
    stop_stalled_launch "${emacs_apps[index]}"
  done
  return 1
}

main() {
  local index label emacs_app lisp_label lisp_ready

  if [[ ! "${theme_seed}" =~ ^[0-9]+$ ]]; then
    echo "BRUTAL_PAPER_E2E_SEED must be a nonnegative integer." >&2
    return 1
  fi

  emacs_labels=()
  emacs_apps=()
  launches=()
  ready_files=()
  ready_dir="$(mktemp -d)"
  trap cleanup EXIT

  discover_emacs_apps
  stop_previous_e2e_instances
  install_yabai_float_rule

  echo "Theme seed: ${theme_seed}"
  echo "Replay with BRUTAL_PAPER_E2E_SEED=${theme_seed} make e2e"

  for index in "${!emacs_apps[@]}"; do
    label="${emacs_labels[index]}"
    emacs_app="${emacs_apps[index]}"
    ready_files+=("${ready_dir}/${index}.ready")
    lisp_label="${label//\\/\\\\}"
    lisp_label="${lisp_label//\"/\\\"}"
    lisp_ready="${ready_files[index]//\\/\\\\}"
    lisp_ready="${lisp_ready//\"/\\\"}"
    echo "Launching Emacs ${label}..."
    /usr/bin/open -na "${emacs_app}" --args \
      -Q \
      --debug-init \
      -L "${project_dir}" \
      --eval "(setq brutal-paper-e2e-index ${index} brutal-paper-e2e-count ${#emacs_apps[@]} brutal-paper-e2e-label \"${lisp_label}\" brutal-paper-e2e-seed ${theme_seed} brutal-paper-e2e-ready-file \"${lisp_ready}\")" \
      --load "${fixture_file}" &
    launches+=("$!")
  done

  wait_for_launches

  if [[ -n "${yabai_rule_label}" ]]; then
    # NS can publish the accessible title after creating the window. Keep the
    # creation rule, then reapply a title-scoped rule while startup settles;
    # both operations are idempotent.
    for _ in {1..20}; do
      "${yabai_bin}" -m rule --apply \
        'app=^Emacs$' \
        'title=^Brutal Paper E2E' \
        manage=off >/dev/null 2>&1 || true
      sleep 0.1
    done
    remove_yabai_float_rule
  fi

  echo "Launched Brutal Paper E2E on Emacs ${emacs_labels[*]}."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod_dir_default="$(cd "$repo_root/.." && pwd)"
write_data_default="$(cd "$mod_dir_default/.." && pwd)"

factorio_bin="${FACTORIO_BIN:-/Users/adammiller/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
mod_dir="${FACTORIO_MOD_DIR:-$mod_dir_default}"
existing_save="${FACTORIO_EXISTING_SAVE:-$write_data_default/saves/_autosave1.zip}"
fresh_save="${FACTORIO_FRESH_SAVE:-/tmp/enemy-builder-regression-smoke.zip}"
fresh_until_tick="${FACTORIO_FRESH_UNTIL_TICK:-900}"
existing_until_tick="${FACTORIO_EXISTING_UNTIL_TICK:-210000}"

run_factorio() {
  "$factorio_bin" --mod-directory "$mod_dir" "$@"
}

run_existing_save() {
  local target_tick="$1"
  local output_file
  output_file="$(mktemp)"

  set +e
  run_factorio --load-game "$existing_save" --until-tick "$target_tick" >"$output_file" 2>&1
  local status=$?
  set -e

  cat "$output_file"

  if [[ $status -eq 0 ]]; then
    rm -f "$output_file"
    return 0
  fi

  local current_tick
  current_tick="$(sed -n 's/.*current map tick is \([0-9][0-9]*\).*/\1/p' "$output_file" | tail -n 1)"
  rm -f "$output_file"

  if [[ -n "$current_tick" ]]; then
    local retry_tick=$((current_tick + 1000))
    echo
    echo "-- existing save already at tick $current_tick; retrying to tick $retry_tick"
    run_factorio --load-game "$existing_save" --until-tick "$retry_tick"
    return 0
  fi

  return $status
}

if [[ ! -x "$factorio_bin" ]]; then
  echo "Factorio binary not found or not executable: $factorio_bin" >&2
  exit 1
fi

if [[ ! -d "$mod_dir" ]]; then
  echo "Mod directory not found: $mod_dir" >&2
  exit 1
fi

echo "== Enemy Builder headless regressions =="
echo "repo_root: $repo_root"
echo "factorio_bin: $factorio_bin"
echo "mod_dir: $mod_dir"
echo

echo "-- fresh create"
run_factorio --create "$fresh_save"

echo
echo "-- fresh load to tick $fresh_until_tick"
run_factorio --load-game "$fresh_save" --until-tick "$fresh_until_tick"

if [[ -f "$existing_save" ]]; then
  echo
  echo "-- existing save load to tick $existing_until_tick"
  run_existing_save "$existing_until_tick"
else
  echo
  echo "-- skipped existing save: $existing_save not found"
fi

echo
echo "All requested regressions passed."

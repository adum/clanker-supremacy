#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod_dir_default="$(cd "$repo_root/.." && pwd)"

factorio_bin="${FACTORIO_BIN:-/Users/adammiller/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
mod_dir="${FACTORIO_MOD_DIR:-$mod_dir_default}"
timeout_secs="${FACTORIO_TEST_TIMEOUT_SECS:-120}"

temp_root="$(mktemp -d /tmp/enemy-builder-tests.XXXXXX)"
write_data_dir="$temp_root/write-data"
config_path="$temp_root/config.ini"
server_settings_path="$temp_root/server-settings.json"
fresh_save_path="$temp_root/enemy-builder-test.zip"
server_input_pipe="$temp_root/server-input.pipe"

cleanup() {
  if [[ -n "${factorio_pid:-}" ]] && kill -0 "$factorio_pid" 2>/dev/null; then
    kill "$factorio_pid" 2>/dev/null || true
    wait "$factorio_pid" 2>/dev/null || true
  fi

  if [[ -n "${server_input_fd_opened:-}" ]]; then
    exec 3>&- || true
  fi

  rm -rf "$temp_root"
}
trap cleanup EXIT

mkdir -p "$write_data_dir"

cat >"$config_path" <<EOF
[path]
read-data=__PATH__system-read-data__
write-data=$write_data_dir
EOF

cat >"$server_settings_path" <<EOF
{
  "name": "Enemy Builder Test",
  "description": "Headless Enemy Builder integration test",
  "tags": ["test"],
  "max_players": 0,
  "visibility": {
    "public": false,
    "lan": false
  },
  "require_user_verification": false,
  "allow_commands": "true",
  "autosave_interval": 0,
  "autosave_slots": 1,
  "afk_autokick_interval": 0,
  "auto_pause": false,
  "auto_pause_when_players_connect": false,
  "only_admins_can_pause_the_game": false,
  "autosave_only_on_server": true,
  "non_blocking_saving": false
}
EOF

run_factorio() {
  "$factorio_bin" --config "$config_path" --mod-directory "$mod_dir" "$@"
}

run_factorio_with_config() {
  local selected_config_path="$1"
  shift
  "$factorio_bin" --config "$selected_config_path" --mod-directory "$mod_dir" "$@"
}

if [[ ! -x "$factorio_bin" ]]; then
  echo "Factorio binary not found or not executable: $factorio_bin" >&2
  exit 1
fi

if [[ ! -d "$mod_dir" ]]; then
  echo "Mod directory not found: $mod_dir" >&2
  exit 1
fi

echo "== Enemy Builder headless tests =="
echo "timeout_secs: $timeout_secs"
echo "write_data_dir: $write_data_dir"
echo

echo "-- create fresh save"
run_factorio --create "$fresh_save_path"

run_case() {
  local case_name="$1"
  local remote_setup_name="$2"
  local server_port="$3"
  local remote_setup_arg="${4:-}"
  local case_write_data_dir="$temp_root/write-data-${case_name}"
  local case_config_path="$temp_root/config-${case_name}.ini"
  local status_file_path="$case_write_data_dir/script-output/enemy-builder-tests/${case_name}.status"
  local output_path="$temp_root/${case_name}.log"

  mkdir -p "$case_write_data_dir"
  cat >"$case_config_path" <<EOF
[path]
read-data=__PATH__system-read-data__
write-data=$case_write_data_dir
EOF

  rm -f "$status_file_path" "$output_path" "$server_input_pipe"

  echo
  echo "-- start dedicated server for ${case_name}"
  mkfifo "$server_input_pipe"
  exec 3<>"$server_input_pipe"
  server_input_fd_opened=1

  set +e
  run_factorio_with_config "$case_config_path" --start-server "$fresh_save_path" --server-settings "$server_settings_path" --port "$server_port" <"$server_input_pipe" >"$output_path" 2>&1 &
  factorio_pid=$!
  set -e

  local server_ready=false
  for ((elapsed = 0; elapsed < 15; elapsed++)); do
    if grep -Fq "changing state from(CreatingGame) to(InGame)" "$output_path" 2>/dev/null; then
      server_ready=true
      break
    fi

    if ! kill -0 "$factorio_pid" 2>/dev/null; then
      set +e
      wait "$factorio_pid"
      local status=$?
      set -e
      cat "$output_path"
      echo
      echo "Dedicated server exited before it became ready for ${case_name}." >&2
      exit $status
    fi

    sleep 1
  done

  if [[ "$server_ready" != true ]]; then
    cat "$output_path"
    echo
    echo "Dedicated server never reached InGame state for ${case_name}." >&2
    exit 1
  fi

  echo
  echo "-- inject ${case_name} test case"
  local remote_command
  if [[ -n "$remote_setup_arg" ]]; then
    remote_command=$(printf '/silent-command remote.call("enemy-builder-test", "%s", "%s")\n' "$remote_setup_name" "$remote_setup_arg")
  else
    remote_command=$(printf '/silent-command remote.call("enemy-builder-test", "%s")\n' "$remote_setup_name")
  fi
  printf '%s' "$remote_command" >&3
  sleep 1
  printf '%s' "$remote_command" >&3

  local status_found=false
  for ((elapsed = 0; elapsed < timeout_secs; elapsed++)); do
    if [[ -f "$status_file_path" ]]; then
      status_found=true
      break
    fi

    if ! kill -0 "$factorio_pid" 2>/dev/null; then
      set +e
      wait "$factorio_pid"
      local status=$?
      set -e
      cat "$output_path"
      echo
      echo "Dedicated server exited before producing a status file for ${case_name}." >&2
      exit $status
    fi

    sleep 1
  done

  if [[ -n "${factorio_pid:-}" ]] && kill -0 "$factorio_pid" 2>/dev/null; then
    kill "$factorio_pid" 2>/dev/null || true
    wait "$factorio_pid" 2>/dev/null || true
  fi
  factorio_pid=""

  if [[ -n "${server_input_fd_opened:-}" ]]; then
    exec 3>&- || true
    unset server_input_fd_opened
  fi

  cat "$output_path"

  if [[ "$status_found" != true ]]; then
    echo
    echo "Headless test timed out before producing a status file for ${case_name}." >&2
    echo
    echo "-- factorio-current.log --" >&2
    cat "$case_write_data_dir/factorio-current.log" >&2
    exit 1
  fi

  if ! grep -Fq "PASS ${case_name}" "$status_file_path"; then
    echo
    echo "Headless test status did not report PASS for ${case_name}." >&2
    echo
    echo "-- status file --" >&2
    cat "$status_file_path" >&2
    exit 1
  fi
}

run_case "firearm_outpost_physical_feed" "setup_firearm_outpost_test_case" "34197"
run_case "pause_mode_manual_goal" "setup_pause_mode_manual_goal_test_case" "34214"
run_case "firearm_outpost_anchor_clearance" "setup_firearm_outpost_anchored_test_case" "34198"
run_case "tree_blocked_machine_placement" "setup_tree_blocked_assembler_test_case" "34199"
run_case "iron_plate_belt_export_physical_feed" "setup_iron_plate_belt_export_test_case" "34200"
run_case "solar_panel_factory_physical_feed" "setup_solar_panel_factory_test_case" "34206"
run_case "solar_panel_factory_missing_sources_reports_blocker" "setup_solar_panel_factory_missing_sources_reports_blocker_test_case" "34215"
run_case "scaling_collect_switches_site" "setup_scaling_collect_switches_site_test_case" "34205"
run_case "assembler_output_collection_limits" "setup_assembler_output_collection_limits_test_case" "34209"
run_case "wait_patrol_avoids_close_reposition" "setup_wait_patrol_avoids_close_reposition_test_case" "34210"
run_case "machine_refuel_respects_minimum_batch" "setup_machine_refuel_respects_minimum_batch_test_case" "34212"
run_case "steel_output_retries_blocked_anchors" "setup_steel_output_retries_blocked_anchors_test_case" "34213"
run_case "copper_smelting_large_patch_open_half" "setup_copper_smelting_large_patch_open_half_test_case" "34211"
run_case "scaling_early_expansion_over_coal_reserve" "setup_scaling_early_expansion_over_coal_reserve_test_case" "34207"
run_case "scaling_builds_before_coal_reserve" "setup_scaling_builds_before_coal_reserve_test_case" "34208"
run_case "steel_smelting_physical_feed_north" "setup_steel_smelting_test_case" "34201" "north"
run_case "steel_smelting_physical_feed_east" "setup_steel_smelting_test_case" "34202" "east"
run_case "steel_smelting_physical_feed_south" "setup_steel_smelting_test_case" "34203" "south"
run_case "steel_smelting_physical_feed_west" "setup_steel_smelting_test_case" "34204" "west"

echo
echo "All requested headless tests passed."

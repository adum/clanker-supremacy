#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod_dir_default="$(cd "$repo_root/.." && pwd)"

factorio_bin="${FACTORIO_BIN:-/Users/adammiller/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
mod_dir="${FACTORIO_MOD_DIR:-$mod_dir_default}"
timeout_secs="${FACTORIO_TEST_TIMEOUT_SECS:-120}"
save_passing_case="${FACTORIO_TEST_SAVE_CASE:-}"
save_output_dir="${FACTORIO_TEST_SAVE_OUTPUT_DIR:-}"
save_timeout_secs="${FACTORIO_TEST_SAVE_TIMEOUT_SECS:-30}"

temp_root="$(mktemp -d /tmp/enemy-builder-tests.XXXXXX)"
write_data_dir="$temp_root/write-data"
config_path="$temp_root/config.ini"
server_settings_path="$temp_root/server-settings.json"
fresh_save_path="$temp_root/enemy-builder-test.zip"
server_input_pipe="$temp_root/server-input.pipe"
save_case_matched=false

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

if [[ -n "$save_passing_case" && -z "$save_output_dir" ]]; then
  echo "FACTORIO_TEST_SAVE_OUTPUT_DIR is required when FACTORIO_TEST_SAVE_CASE is set." >&2
  exit 1
fi

echo "== Enemy Builder headless tests =="
echo "timeout_secs: $timeout_secs"
echo "write_data_dir: $write_data_dir"
if [[ -n "$save_passing_case" ]]; then
  mkdir -p "$save_output_dir"
  echo "save_passing_case: $save_passing_case"
  echo "save_output_dir: $save_output_dir"
fi
echo

echo "-- create fresh save"
run_factorio --create "$fresh_save_path"

run_case() {
  local case_name="$1"
  local _legacy_remote_setup_name="$2"
  local remote_setup_name="$case_name"
  local server_port="$3"
  local remote_setup_arg="${4:-}"
  local case_timeout_secs="${5:-$timeout_secs}"
  local case_write_data_dir="$temp_root/write-data-${case_name}"
  local case_config_path="$temp_root/config-${case_name}.ini"
  local status_file_path="$case_write_data_dir/script-output/${case_name}.status"
  local output_path="$temp_root/${case_name}.log"

  mkdir -p "$case_write_data_dir"
  mkdir -p "$(dirname "$status_file_path")"
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
  mkdir -p "$(dirname "$status_file_path")"
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
  for ((elapsed = 0; elapsed < case_timeout_secs; elapsed++)); do
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

  local status_passed=false
  if [[ "$status_found" == true ]] && grep -Fq "PASS ${case_name}" "$status_file_path"; then
    status_passed=true
  fi

  if [[ -n "$save_passing_case" && "$case_name" == "$save_passing_case" && "$status_passed" == true ]]; then
    save_case_matched=true
    local server_save_name="headless-test-${case_name}.zip"
    local server_save_dir="$case_write_data_dir/saves"
    local server_save_path="$server_save_dir/${server_save_name}"
    local destination_path="$save_output_dir/${server_save_name}"

    mkdir -p "$server_save_dir"
    echo "-- save ${case_name} result"
    printf '/server-save %s\n' "$server_save_name" >&3

    local save_found=false
    for ((elapsed = 0; elapsed < save_timeout_secs; elapsed++)); do
      if [[ -f "$server_save_path" ]]; then
        save_found=true
        break
      fi

      if ! kill -0 "$factorio_pid" 2>/dev/null; then
        set +e
        wait "$factorio_pid"
        local status=$?
        set -e
        cat "$output_path"
        echo
        echo "Dedicated server exited before producing the saved game for ${case_name}." >&2
        exit $status
      fi

      sleep 1
    done

    if [[ "$save_found" != true ]]; then
      cat "$output_path"
      echo
      echo "Timed out waiting for saved game ${server_save_name} for ${case_name}." >&2
      exit 1
    fi

    cp "$server_save_path" "$destination_path"
    echo "-- copied save to ${destination_path}"
  fi

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
run_case "iron_plate_belt_export_ignores_ground_items" "setup_iron_plate_belt_export_ground_items_test_case" "34217"
run_case "copper_plate_belt_export_ignores_ground_items" "setup_copper_plate_belt_export_ground_items_test_case" "34218"
run_case "output_belts_can_overlap_resources" "setup_output_belts_can_overlap_resources_test_case" "34216"
run_case "output_belt_prefers_less_ore_direction" "setup_output_belt_prefers_less_ore_direction_test_case" "34223"
run_case "output_belt_layout_places_inserter_then_straight_belts" "setup_output_belt_layout_places_inserter_then_straight_belts_test_case" "34226"
run_case "output_belt_sidestep_before_building" "setup_output_belt_sidestep_before_building_test_case" "34229"
run_case "steel_output_belt_layout_places_inserter_then_straight_belts" "setup_steel_output_belt_layout_places_inserter_then_straight_belts_test_case" "34227"
run_case "steel_output_belt_counts_as_export_site" "setup_steel_output_belt_counts_as_export_site_test_case" "34237"
run_case "output_belt_abort_preserves_transport_belts" "setup_output_belt_abort_preserves_transport_belts_test_case" "34228"
run_case "solar_panel_factory_physical_feed" "setup_solar_panel_factory_test_case" "34206" "" "600"
run_case "gun_turret_factory_physical_feed" "setup_gun_turret_factory_test_case" "34253" "" "600"
run_case "build_out_gun_turret_factory_finds_nearby_open_space" "setup_build_out_gun_turret_factory_finds_nearby_open_space_test_case" "34254" "" "240"
run_case "solar_panel_factory_east_orientation_physical_feed" "setup_solar_panel_factory_test_case_east" "34240" "" "600"
run_case "solar_panel_factory_south_orientation_physical_feed" "setup_solar_panel_factory_test_case_south" "34245" "" "600"
run_case "solar_panel_factory_west_orientation_physical_feed" "setup_solar_panel_factory_test_case_west" "34246" "" "600"
run_case "solar_panel_factory_opposed_sources_physical_feed" "setup_solar_panel_factory_opposed_sources_test_case" "34243" "" "600"
run_case "solar_panel_factory_cross_pressure_physical_feed" "setup_solar_panel_factory_cross_pressure_test_case" "34244" "" "600"
run_case "solar_panel_factory_cross_pressure_walled_underground_physical_feed" "setup_solar_panel_factory_cross_pressure_walled_underground_test_case" "34250" "" "600"
run_case "solar_panel_factory_jungle_route_physical_feed" "setup_solar_panel_factory_jungle_route_test_case" "34251" "" "600"
run_case "solar_panel_factory_missing_sources_reports_blocker" "setup_solar_panel_factory_missing_sources_reports_blocker_test_case" "34215"
run_case "solar_panel_factory_block_marks_scaling_milestone" "setup_solar_panel_factory_block_marks_scaling_milestone_test_case" "34238"
run_case "solar_panel_factory_iron_input_marks_scaling_milestone" "setup_solar_panel_factory_iron_input_marks_scaling_milestone_test_case" "34239"
run_case "solar_panel_factory_power_marks_scaling_milestone" "setup_solar_panel_factory_power_marks_scaling_milestone_test_case" "34247" "" "600"
run_case "scaling_collect_switches_site" "setup_scaling_collect_switches_site_test_case" "34205"
run_case "scaling_stays_in_starter_core_until_solar_block" "setup_scaling_stays_in_starter_core_until_solar_block_test_case" "34236"
run_case "assembler_output_collection_limits" "setup_assembler_output_collection_limits_test_case" "34209"
run_case "wait_patrol_avoids_close_reposition" "setup_wait_patrol_avoids_close_reposition_test_case" "34210"
run_case "wait_patrol_stops_when_inventory_cap_reached" "setup_wait_patrol_stops_when_inventory_cap_reached_test_case" "34224"
run_case "wait_patrol_recovers_coal_when_producers_are_out_of_fuel" "setup_wait_patrol_recovers_coal_when_producers_are_out_of_fuel_test_case" "34219"
run_case "machine_refuel_respects_minimum_batch" "setup_machine_refuel_respects_minimum_batch_test_case" "34212"
run_case "nearby_tree_harvest_tops_up_wood" "setup_nearby_tree_harvest_tops_up_wood_test_case" "34252"
run_case "cleanup_nearby_exhausted_miners" "setup_cleanup_nearby_exhausted_miners_test_case" "34232"
run_case "cleanup_exhausted_miner_removes_orphan_furnace" "setup_cleanup_exhausted_miner_removes_orphan_furnace_test_case" "34234"
run_case "cleanup_exhausted_miner_removes_orphan_steel_chain" "setup_cleanup_exhausted_miner_removes_orphan_steel_chain_test_case" "34235"
run_case "steel_output_retries_blocked_anchors" "setup_steel_output_retries_blocked_anchors_test_case" "34213"
run_case "steel_smelting_missing_inserter_does_not_place_free_inserter" "setup_steel_smelting_missing_inserter_does_not_place_free_inserter_test_case" "34230"
run_case "copper_smelting_large_patch_open_half" "setup_copper_smelting_large_patch_open_half_test_case" "34211"
run_case "iron_plate_belt_export_large_patch_sparse_near_edge" "setup_iron_plate_belt_export_large_patch_sparse_near_edge_test_case" "34231"
run_case "iron_plate_belt_export_large_patch_blocked_near_edge" "setup_iron_plate_belt_export_large_patch_blocked_near_edge_test_case" "34233"
run_case "scaling_early_expansion_over_coal_reserve" "setup_scaling_early_expansion_over_coal_reserve_test_case" "34207"
run_case "scaling_builds_before_coal_reserve" "setup_scaling_builds_before_coal_reserve_test_case" "34208"
run_case "scaling_repeats_material_patterns" "setup_scaling_repeats_material_patterns_test_case" "34221"
run_case "scaling_firearm_outpost_respects_cap" "setup_scaling_firearm_outpost_respects_cap_test_case" "34222"
run_case "scaling_material_expansion_before_firearm_outpost" "setup_scaling_material_expansion_before_firearm_outpost_test_case" "34220"
run_case "steel_export_requires_iron_export" "setup_steel_export_requires_iron_export_test_case" "34229"
run_case "steel_smelting_physical_feed_north" "setup_steel_smelting_test_case" "34201" "north"
run_case "steel_smelting_physical_feed_east" "setup_steel_smelting_test_case" "34202" "east"
run_case "steel_smelting_physical_feed_south" "setup_steel_smelting_test_case" "34203" "south"
run_case "steel_smelting_physical_feed_west" "setup_steel_smelting_test_case" "34204" "west"

if [[ -n "$save_passing_case" && "$save_case_matched" != true ]]; then
  echo "Requested save case was not run: ${save_passing_case}" >&2
  exit 1
fi

echo
echo "All requested headless tests passed."

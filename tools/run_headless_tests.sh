#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod_dir_default="$(cd "$repo_root/.." && pwd)"

factorio_bin="${FACTORIO_BIN:-/Users/adammiller/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
mod_dir="${FACTORIO_MOD_DIR:-$mod_dir_default}"
timeout_secs="${FACTORIO_TEST_TIMEOUT_SECS:-75}"

temp_root="$(mktemp -d /tmp/enemy-builder-tests.XXXXXX)"
write_data_dir="$temp_root/write-data"
config_path="$temp_root/config.ini"
server_settings_path="$temp_root/server-settings.json"
output_path="$temp_root/factorio-output.log"
fresh_save_path="$temp_root/firearm-outpost-test.zip"
status_file_path="$write_data_dir/script-output/enemy-builder-tests/firearm_outpost_physical_feed.status"
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

echo
echo "-- start dedicated server"
mkfifo "$server_input_pipe"
exec 3<>"$server_input_pipe"
server_input_fd_opened=1

set +e
run_factorio --start-server "$fresh_save_path" --server-settings "$server_settings_path" <"$server_input_pipe" >"$output_path" 2>&1 &
factorio_pid=$!
set -e

server_ready=false
for ((elapsed = 0; elapsed < 15; elapsed++)); do
  if grep -Fq "changing state from(CreatingGame) to(InGame)" "$output_path" 2>/dev/null; then
    server_ready=true
    break
  fi

  if ! kill -0 "$factorio_pid" 2>/dev/null; then
    set +e
    wait "$factorio_pid"
    status=$?
    set -e
    cat "$output_path"
    echo
    echo "Dedicated server exited before it became ready." >&2
    exit $status
  fi

  sleep 1
done

if [[ "$server_ready" != true ]]; then
  cat "$output_path"
  echo
  echo "Dedicated server never reached InGame state." >&2
  exit 1
fi

echo
echo "-- inject firearm outpost test case"
printf '/silent-command remote.call("enemy-builder-test", "setup_firearm_outpost_test_case")\n' >&3
sleep 1
printf '/silent-command remote.call("enemy-builder-test", "setup_firearm_outpost_test_case")\n' >&3

status_found=false
for ((elapsed = 0; elapsed < timeout_secs; elapsed++)); do
  if [[ -f "$status_file_path" ]]; then
    status_found=true
    break
  fi

  if ! kill -0 "$factorio_pid" 2>/dev/null; then
    set +e
    wait "$factorio_pid"
    status=$?
    set -e
    cat "$output_path"
    echo
    echo "Dedicated server exited before producing a status file." >&2
    exit $status
  fi

  sleep 1
done

if [[ -n "${factorio_pid:-}" ]] && kill -0 "$factorio_pid" 2>/dev/null; then
  kill "$factorio_pid" 2>/dev/null || true
  wait "$factorio_pid" 2>/dev/null || true
fi

cat "$output_path"

if [[ "$status_found" != true ]]; then
  echo
  echo "Headless test timed out before producing a status file." >&2
  echo
  echo "-- factorio-current.log --" >&2
  cat "$write_data_dir/factorio-current.log" >&2
  exit 1
fi

if ! grep -Fq "PASS firearm_outpost_physical_feed" "$status_file_path"; then
  echo
  echo "Headless test status did not report PASS." >&2
  echo
  echo "-- status file --" >&2
  cat "$status_file_path" >&2
  exit 1
fi

echo
echo "All requested headless tests passed."

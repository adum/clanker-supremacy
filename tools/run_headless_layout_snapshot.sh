#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod_dir_default="$(cd "$repo_root/.." && pwd)"

factorio_bin="${FACTORIO_BIN:-/Users/adammiller/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
mod_dir="${FACTORIO_MOD_DIR:-$mod_dir_default}"
timeout_secs="${FACTORIO_SNAPSHOT_TIMEOUT_SECS:-300}"
case_name="${ENEMY_BUILDER_SNAPSHOT_CASE:-full_run_layout_snapshot}"
remote_setup_name="${ENEMY_BUILDER_SNAPSHOT_SETUP:-setup_full_run_layout_snapshot_case}"
output_dir="${ENEMY_BUILDER_SNAPSHOT_OUTPUT_DIR:-$(mktemp -d /tmp/enemy-builder-layout-snapshot.XXXXXX)}"

temp_root="$(mktemp -d /tmp/enemy-builder-layout-run.XXXXXX)"
write_data_dir="$temp_root/write-data"
config_path="$temp_root/config.ini"
server_settings_path="$temp_root/server-settings.json"
fresh_save_path="$temp_root/enemy-builder-snapshot.zip"
server_input_pipe="$temp_root/server-input.pipe"
server_log_path="$temp_root/server.log"

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

mkdir -p "$write_data_dir" "$output_dir"

cat >"$config_path" <<EOF
[path]
read-data=__PATH__system-read-data__
write-data=$write_data_dir
EOF

cat >"$server_settings_path" <<EOF
{
  "name": "Enemy Builder Snapshot",
  "description": "Headless Enemy Builder layout snapshot run",
  "tags": ["snapshot"],
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

status_file_path="$write_data_dir/script-output/enemy-builder-snapshots/${case_name}.status"
artifact_source_dir="$write_data_dir/script-output/enemy-builder-snapshots/${case_name}"
artifact_dest_dir="$output_dir/${case_name}"

echo "== Enemy Builder headless layout snapshot =="
echo "case_name: $case_name"
echo "timeout_secs: $timeout_secs"
echo "output_dir: $output_dir"
echo

echo "-- create fresh save"
run_factorio --create "$fresh_save_path"

echo
echo "-- start dedicated server"
mkfifo "$server_input_pipe"
exec 3<>"$server_input_pipe"
server_input_fd_opened=1

set +e
run_factorio --start-server "$fresh_save_path" --server-settings "$server_settings_path" --port "34220" <"$server_input_pipe" >"$server_log_path" 2>&1 &
factorio_pid=$!
set -e

server_ready=false
for ((elapsed = 0; elapsed < 15; elapsed++)); do
  if grep -Fq "changing state from(CreatingGame) to(InGame)" "$server_log_path" 2>/dev/null; then
    server_ready=true
    break
  fi

  if ! kill -0 "$factorio_pid" 2>/dev/null; then
    set +e
    wait "$factorio_pid"
    status=$?
    set -e
    cat "$server_log_path"
    echo
    echo "Dedicated server exited before it became ready." >&2
    exit "$status"
  fi

  sleep 1
done

if [[ "$server_ready" != true ]]; then
  cat "$server_log_path"
  echo
  echo "Dedicated server never reached InGame state." >&2
  exit 1
fi

echo
echo "-- inject snapshot setup"
remote_command=$(printf '/silent-command remote.call("enemy-builder-test", "%s")\n' "$remote_setup_name")
printf '%s' "$remote_command" >&3
sleep 1
printf '%s' "$remote_command" >&3

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
    cat "$server_log_path"
    echo
    echo "Dedicated server exited before producing snapshot status." >&2
    exit "$status"
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

cat "$server_log_path"

if [[ "$status_found" != true ]]; then
  echo
  echo "Snapshot run timed out before producing a status file." >&2
  echo
  echo "-- factorio-current.log --" >&2
  cat "$write_data_dir/factorio-current.log" >&2
  exit 1
fi

if ! grep -Fq "PASS ${case_name}" "$status_file_path"; then
  echo
  echo "Snapshot run status did not report PASS." >&2
  cat "$status_file_path" >&2
  exit 1
fi

rm -rf "$artifact_dest_dir"
mkdir -p "$artifact_dest_dir"
cp -R "$artifact_source_dir"/. "$artifact_dest_dir"/
cp "$status_file_path" "$output_dir/"
cp "$server_log_path" "$output_dir/server.log"

echo
echo "Snapshot artifacts copied to:"
echo "  $artifact_dest_dir"
echo "Open:"
echo "  $artifact_dest_dir/index.html"

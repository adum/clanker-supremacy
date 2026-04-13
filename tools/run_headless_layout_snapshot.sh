#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod_dir_default="$(cd "$repo_root/.." && pwd)"

factorio_bin="${FACTORIO_BIN:-/Users/adammiller/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
mod_dir="${FACTORIO_MOD_DIR:-$mod_dir_default}"
timeout_secs="${FACTORIO_SNAPSHOT_TIMEOUT_SECS:-}"
case_name="${ENEMY_BUILDER_SNAPSHOT_CASE:-full_run_layout_snapshot}"
remote_setup_name="${ENEMY_BUILDER_SNAPSHOT_SETUP:-setup_full_run_layout_snapshot_case}"
output_dir="${ENEMY_BUILDER_SNAPSHOT_OUTPUT_DIR:-$(mktemp -d /tmp/enemy-builder-layout-snapshot.XXXXXX)}"
duration_ticks="${ENEMY_BUILDER_SNAPSHOT_DURATION_TICKS:-}"
duration_minutes="${ENEMY_BUILDER_SNAPSHOT_DURATION_MINUTES:-}"
snapshot_ticks_csv="${ENEMY_BUILDER_SNAPSHOT_TICKS:-}"
checkpoint_count="${ENEMY_BUILDER_SNAPSHOT_CHECKPOINT_COUNT:-5}"
game_speed="${ENEMY_BUILDER_SNAPSHOT_GAME_SPEED:-1}"
server_port="${ENEMY_BUILDER_SNAPSHOT_PORT:-$((35000 + (RANDOM % 2000)))}"

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

print_usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --duration-ticks N        Run for N ticks
  --duration-minutes N      Run for N game minutes (converted to ticks)
  --snapshot-ticks CSV      Explicit snapshot ticks, e.g. 600,1200,2400
  --checkpoint-count N      Generate N evenly spaced snapshots across the duration
  --game-speed N            Set Factorio game.speed for the run
  --timeout-secs N          Override wall-clock timeout
  --output-dir PATH         Copy final artifacts to PATH
  --case-name NAME          Override snapshot case name
  --help                    Show this help
EOF
}

generate_snapshot_ticks() {
  local duration="$1"
  local count="$2"
  local ticks=()
  local last_tick=0

  if (( count < 1 )); then
    count=1
  fi

  for ((index = 1; index <= count; index++)); do
    local tick=$(( duration * index / count ))
    if (( tick <= last_tick )); then
      tick=$(( last_tick + 1 ))
    fi
    ticks+=("$tick")
    last_tick="$tick"
  done

  local IFS=,
  printf '%s' "${ticks[*]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration-ticks)
      duration_ticks="$2"
      shift 2
      ;;
    --duration-minutes)
      duration_minutes="$2"
      shift 2
      ;;
    --snapshot-ticks)
      snapshot_ticks_csv="$2"
      shift 2
      ;;
    --checkpoint-count)
      checkpoint_count="$2"
      shift 2
      ;;
    --game-speed)
      game_speed="$2"
      shift 2
      ;;
    --timeout-secs)
      timeout_secs="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    --case-name)
      case_name="$2"
      shift 2
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$duration_minutes" ]]; then
  duration_ticks="$(awk "BEGIN { printf \"%d\", (($duration_minutes * 3600) + 0.5) }")"
fi

if [[ -z "$duration_ticks" ]]; then
  duration_ticks=4800
fi

if ! [[ "$duration_ticks" =~ ^[0-9]+$ ]] || (( duration_ticks <= 0 )); then
  echo "duration_ticks must be a positive integer, got: $duration_ticks" >&2
  exit 1
fi

if [[ -z "$snapshot_ticks_csv" ]]; then
  if ! [[ "$checkpoint_count" =~ ^[0-9]+$ ]] || (( checkpoint_count <= 0 )); then
    echo "checkpoint_count must be a positive integer, got: $checkpoint_count" >&2
    exit 1
  fi
  snapshot_ticks_csv="$(generate_snapshot_ticks "$duration_ticks" "$checkpoint_count")"
fi

if [[ -z "$timeout_secs" ]]; then
  timeout_secs=$(( (duration_ticks / 60) + 180 ))
fi

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs <= 0 )); then
  echo "timeout_secs must be a positive integer, got: $timeout_secs" >&2
  exit 1
fi

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
echo "duration_ticks: $duration_ticks"
echo "snapshot_ticks: $snapshot_ticks_csv"
echo "game_speed: $game_speed"
echo "server_port: $server_port"
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
run_factorio --start-server "$fresh_save_path" --server-settings "$server_settings_path" --port "$server_port" <"$server_input_pipe" >"$server_log_path" 2>&1 &
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
remote_command=$(printf '/silent-command remote.call("enemy-builder-test", "%s", %s, "%s", %s)\n' \
  "$remote_setup_name" "$duration_ticks" "$snapshot_ticks_csv" "$game_speed")
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

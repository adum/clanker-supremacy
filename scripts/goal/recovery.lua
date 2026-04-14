local common = require("scripts.goal.common")
local instances = require("scripts.goal.instances")

local recovery = {}

function recovery.record(builder_state, recovery_event)
  if not builder_state then
    return nil
  end

  local entry
  if type(recovery_event) == "table" then
    entry = {
      tick = game and game.tick or nil,
      kind = recovery_event.kind or "runtime-recovery",
      message = recovery_event.message or "",
      meta = common.deep_copy(recovery_event.meta or {})
    }
  else
    entry = {
      tick = game and game.tick or nil,
      kind = "runtime-recovery",
      message = recovery_event or "",
      meta = {}
    }
  end

  builder_state.last_recovery = entry
  return entry
end

function recovery.clear(builder_state)
  if builder_state then
    builder_state.last_recovery = nil
  end
end

function recovery.derive_runtime_blockers(snapshot)
  local blockers = {}
  local task_state = snapshot.task_state or {}

  if task_state.wait_reason then
    local wait_message = common.humanize_identifier(task_state.wait_reason)
    if task_state.wait_detail and task_state.wait_detail ~= "" then
      wait_message = wait_message .. " (" .. task_state.wait_detail .. ")"
    end

    blockers[#blockers + 1] = instances.make_blocker(
      "wait-reason",
      wait_message,
      {
        wait_reason = task_state.wait_reason,
        wait_detail = task_state.wait_detail,
        next_attempt_tick = task_state.next_attempt_tick
      }
    )
  end

  if snapshot.last_recovery and snapshot.last_recovery.message then
    blockers[#blockers + 1] = instances.make_blocker(
      snapshot.last_recovery.kind or "recovery",
      snapshot.last_recovery.message,
      snapshot.last_recovery.meta
    )
  end

  return blockers
end

return recovery

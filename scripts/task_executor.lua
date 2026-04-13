local action_build = require("scripts.actions.build")
local action_harvest = require("scripts.actions.harvest")
local action_move = require("scripts.actions.move")
local action_start = require("scripts.actions.start")

local task_executor = {}

function task_executor.start_task(builder_state, task, tick, ctx)
  action_start.start_task(builder_state, task, tick, ctx)
end

function task_executor.refresh_task(builder_state, task, tick, ctx)
  local retry_key = ctx.builder_runtime.get_task_retry_key(task)
  local retry_state = ctx.builder_runtime.get_retry_state(builder_state)
  retry_state.counts[retry_key] = (retry_state.counts[retry_key] or 0) + 1

  if retry_state.counts[retry_key] > ctx.builder_runtime.get_retry_limit() then
    ctx.builder_runtime.handle_task_retry_exhausted(
      builder_state,
      task,
      tick,
      "retry limit reached for " .. retry_key
    )
    return
  end

  builder_state.task_state = nil
  ctx.builder_runtime.record_recovery(builder_state, "retrying " .. (task and (task.id or task.type) or "task"))
  ctx.debug_log("task " .. task.id .. ": retrying from " .. ctx.format_position(builder_state.entity.position))
  task_executor.start_task(builder_state, task, tick, ctx)
end

function task_executor.advance_task_phase(builder_state, task, tick, ctx)
  local phase = builder_state.task_state.phase

  if phase == "waiting-for-resource" or phase == "waiting-for-source" then
    if tick >= builder_state.task_state.next_attempt_tick then
      task_executor.refresh_task(builder_state, task, tick, ctx)
    end
    return
  end

  if phase == "moving" then
    action_move.move_builder(builder_state, task, tick, ctx, task_executor.refresh_task)
    return
  end

  if phase == "moving-to-source" then
    action_move.move_to_gather_source(builder_state, task, tick, ctx, task_executor.refresh_task)
    return
  end

  if phase == "moving-to-resource" then
    action_move.move_to_resource(builder_state, task, tick, ctx, task_executor.refresh_task)
    return
  end

  if phase == "building" then
    if task.type == "place-machine-near-site" then
      action_build.place_machine_near_site(builder_state, task, tick, ctx, task_executor.refresh_task)
    elseif task.type == "place-layout-near-machine" or task.type == "place-output-belt-line" or task.type == "place-assembly-block" or task.type == "place-assembly-input-route" then
      action_build.place_layout_near_machine(builder_state, task, tick, ctx, task_executor.refresh_task)
    else
      action_build.place_miner(builder_state, task, tick, ctx, task_executor.refresh_task)
    end
    return
  end

  if phase == "post-place-pause" then
    action_build.advance_post_place_pause(builder_state, task, tick, ctx)
    return
  end

  if phase == "build-complete" then
    if task.type == "place-machine-near-site" then
      action_build.finish_place_machine_near_site_task(builder_state, task, tick, ctx, task_executor.refresh_task)
    elseif task.type == "place-layout-near-machine" or task.type == "place-output-belt-line" or task.type == "place-assembly-block" or task.type == "place-assembly-input-route" then
      action_build.finish_place_layout_near_machine_task(builder_state, task, tick, ctx, task_executor.refresh_task)
    else
      action_build.finish_place_miner_task(builder_state, task, tick, ctx, task_executor.refresh_task)
    end
    return
  end

  if phase == "arrived-at-resource" then
    ctx.complete_current_task(
      builder_state,
      task,
      "arrived at " .. task.resource_name .. " at " .. ctx.format_position(builder_state.task_state.target_position)
    )
    return
  end

  if phase == "harvesting" then
    action_harvest.harvest_world_items(builder_state, task, tick, ctx, task_executor.refresh_task)
  end
end

return task_executor

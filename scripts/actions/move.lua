local action_move = {}

local function move_builder_to_position(builder_state, task, tick, destination_position, next_phase, approach_position, ctx, refresh_task)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local movement_position = approach_position or destination_position

  if ctx.square_distance(entity.position, destination_position) <= (task.arrival_distance * task.arrival_distance) then
    ctx.set_idle(entity)
    task_state.phase = next_phase
    ctx.builder_runtime.clear_recovery(builder_state)
    ctx.debug_log("task " .. task.id .. ": reached target position " .. ctx.format_position(destination_position))
    return
  end

  local delta_x = movement_position.x - entity.position.x
  local delta_y = movement_position.y - entity.position.y
  local direction = ctx.direction_from_delta(delta_x, delta_y)

  if direction then
    entity.walking_state = {
      walking = true,
      direction = direction
    }
  end

  if ctx.square_distance(entity.position, task_state.last_position) > 0.0025 then
    task_state.last_position = ctx.clone_position(entity.position)
    task_state.last_progress_tick = tick
    return
  end

  if tick - task_state.last_progress_tick >= task.stuck_retry_ticks then
    ctx.debug_log("task " .. task.id .. ": movement stalled at " .. ctx.format_position(entity.position) .. "; refreshing task")
    refresh_task(builder_state, task, tick, ctx)
  end
end

function action_move.move_builder(builder_state, task, tick, ctx, refresh_task)
  move_builder_to_position(
    builder_state,
    task,
    tick,
    builder_state.task_state.build_position,
    "building",
    builder_state.task_state.approach_position,
    ctx,
    refresh_task
  )
end

function action_move.move_to_gather_source(builder_state, task, tick, ctx, refresh_task)
  local entity = builder_state.entity
  local task_state = builder_state.task_state

  if task_state.target_kind == "entity" then
    if not (task_state.target_entity and task_state.target_entity.valid) then
      ctx.debug_log("task " .. task.id .. ": source entity disappeared before harvest")
      refresh_task(builder_state, task, tick, ctx)
      return
    end

    task_state.target_position = ctx.clone_position(task_state.target_entity.position)
    task_state.approach_position = ctx.create_task_approach_position(task, task_state.target_position)
  elseif task_state.target_kind == "decorative" then
    if not ctx.decorative_target_exists(entity.surface, task_state.target_decorative_position, task_state.target_name) then
      ctx.debug_log("task " .. task.id .. ": decorative source disappeared before harvest")
      refresh_task(builder_state, task, tick, ctx)
      return
    end
  end

  local was_moving = task_state.phase == "moving-to-source"
  move_builder_to_position(
    builder_state,
    task,
    tick,
    task_state.target_position,
    "harvesting",
    task_state.approach_position,
    ctx,
    refresh_task
  )

  if was_moving and task_state.phase == "harvesting" and not task_state.harvest_complete_tick then
    task_state.harvest_complete_tick = tick + task_state.mining_duration_ticks
    ctx.debug_log(
      "task " .. task.id .. ": harvesting " .. task_state.source_id .. " at " ..
      ctx.format_position(task_state.target_position) .. " until tick " .. task_state.harvest_complete_tick
    )
  end
end

function action_move.move_to_resource(builder_state, task, tick, ctx, refresh_task)
  move_builder_to_position(
    builder_state,
    task,
    tick,
    builder_state.task_state.target_position,
    "arrived-at-resource",
    builder_state.task_state.approach_position,
    ctx,
    refresh_task
  )
end

return action_move

local action_move = {}

local function move_builder_to_position(
  builder_state,
  task,
  tick,
  destination_position,
  next_phase,
  approach_position,
  ctx,
  refresh_task,
  arrival_distance,
  require_approach_position
)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local movement_position = approach_position or destination_position
  local effective_arrival_distance = arrival_distance or task.arrival_distance
  local destination_reached =
    ctx.square_distance(entity.position, destination_position) <= (effective_arrival_distance * effective_arrival_distance)
  local approach_reached = true

  if require_approach_position and approach_position then
    local movement_settings = (ctx.builder_data and ctx.builder_data.movement) or {}
    local approach_tolerance = movement_settings.build_approach_tolerance or 0.3
    approach_reached =
      ctx.square_distance(entity.position, approach_position) <= (approach_tolerance * approach_tolerance)
  end

  if destination_reached and approach_reached then
    ctx.set_idle(entity)
    task_state.phase = next_phase
    task_state.move_destination_position = nil
    task_state.move_next_phase = nil
    task_state.move_arrival_distance = nil
    task_state.move_require_approach = nil
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
  local task_state = builder_state.task_state
  local destination_position = task_state.move_destination_position or task_state.build_position
  local next_phase = task_state.move_next_phase or "building"
  local require_approach_position = task_state.move_require_approach

  if require_approach_position == nil then
    require_approach_position =
      task_state.approach_position ~= nil and
      destination_position ~= nil and
      ctx.square_distance(task_state.approach_position, destination_position) > 0.01
  end

  move_builder_to_position(
    builder_state,
    task,
    tick,
    destination_position,
    next_phase,
    task_state.approach_position,
    ctx,
    refresh_task,
    task_state.move_arrival_distance or task.arrival_distance,
    require_approach_position
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

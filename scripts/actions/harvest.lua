local action_harvest = {}

local function clear_obstacle_state(task_state)
  task_state.source_id = nil
  task_state.target_item_name = nil
  task_state.target_kind = nil
  task_state.target_name = nil
  task_state.target_entity = nil
  task_state.target_decorative_position = nil
  task_state.target_position = nil
  task_state.approach_position = nil
  task_state.harvest_products = nil
  task_state.harvest_complete_tick = nil
  task_state.mining_duration_ticks = nil
  task_state.clear_obstacle_label = nil
  task_state.clear_obstacle_target_name = nil
  task_state.clear_obstacle_build_position = nil
  task_state.resume_phase_after_clear = nil
end

function action_harvest.harvest_world_items(builder_state, task, tick, ctx, refresh_task)
  local entity = builder_state.entity
  local task_state = builder_state.task_state

  if tick < task_state.harvest_complete_tick then
    return
  end

  if task_state.target_kind == "entity" then
    if not (task_state.target_entity and task_state.target_entity.valid) then
      ctx.debug_log("task " .. task.id .. ": source entity disappeared during harvest")
      refresh_task(builder_state, task, tick, ctx)
      return
    end

    task_state.target_entity.destroy()
  elseif task_state.target_kind == "decorative" then
    if not ctx.decorative_target_exists(entity.surface, task_state.target_decorative_position, task_state.target_name) then
      ctx.debug_log("task " .. task.id .. ": decorative source disappeared during harvest")
      refresh_task(builder_state, task, tick, ctx)
      return
    end

    entity.surface.destroy_decoratives{
      position = task_state.target_decorative_position,
      name = task_state.target_name,
      limit = 1
    }
  else
    ctx.debug_log("task " .. task.id .. ": unsupported harvest target kind " .. tostring(task_state.target_kind))
    refresh_task(builder_state, task, tick, ctx)
    return
  end

  local inserted_products = ctx.insert_products(
    entity,
    task_state.harvest_products,
    "harvested " .. task_state.source_id .. " at " .. ctx.format_position(task_state.target_position)
  )

  local inventory_summary = task.inventory_targets and
    ctx.inventory_targets_summary(entity, task.inventory_targets) or
    ctx.format_products(inserted_products)

  ctx.debug_log(
    "task " .. task.id .. ": harvested " .. task_state.source_id .. " at " ..
    ctx.format_position(task_state.target_position) .. "; inserted " .. ctx.format_products(inserted_products) ..
    "; inventory now " .. inventory_summary
  )

  if task_state.resume_phase_after_clear then
    local obstacle_label = task_state.clear_obstacle_label or task_state.target_name or "obstacle"
    local obstacle_position = task_state.target_position and ctx.format_position(task_state.target_position) or "unknown"
    local resume_phase = task_state.resume_phase_after_clear
    clear_obstacle_state(task_state)
    task_state.phase = resume_phase
    ctx.builder_runtime.clear_recovery(builder_state)
    ctx.debug_log(
      "task " .. task.id .. ": cleared " .. obstacle_label ..
      " obstacle at " .. obstacle_position .. "; resuming " .. resume_phase
    )
    return
  end

  if task.no_advance then
    builder_state.scaling_active_task = nil
  end

  builder_state.task_state = nil
end

return action_harvest

local action_harvest = {}

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

  ctx.debug_log(
    "task " .. task.id .. ": harvested " .. task_state.source_id .. " at " ..
    ctx.format_position(task_state.target_position) .. "; inserted " .. ctx.format_products(inserted_products) ..
    "; inventory now " .. ctx.inventory_targets_summary(entity, task.inventory_targets)
  )

  if task.no_advance then
    builder_state.scaling_active_task = nil
  end

  builder_state.task_state = nil
end

return action_harvest

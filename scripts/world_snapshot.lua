local world_snapshot = {}

local function clone_position(position)
  if not position then
    return nil
  end

  return {
    x = position.x,
    y = position.y
  }
end

local function clone_table(input, seen)
  if type(input) ~= "table" then
    return input
  end

  seen = seen or {}
  if seen[input] then
    return seen[input]
  end

  local copy = {}
  seen[input] = copy
  for key, value in pairs(input) do
    copy[clone_table(key, seen)] = clone_table(value, seen)
  end
  return copy
end

function world_snapshot.build(builder_data, builder_state, tick, adapter)
  if not builder_state then
    return {
      tick = tick,
      builder_missing = true,
      scaling_enabled = builder_data.scaling and builder_data.scaling.enabled or false
    }
  end

  local entity = builder_state.entity
  local display_task = adapter.get_display_task(builder_state)
  local active_task = adapter.get_active_task(builder_state)

  return {
    tick = tick,
    builder_missing = not (entity and entity.valid),
    entity = entity,
    position = entity and clone_position(entity.position) or nil,
    plan_name = builder_state.plan_name,
    task_index = builder_state.task_index,
    task_state = clone_table(builder_state.task_state),
    active_task = active_task,
    display_task = display_task,
    scaling_enabled = builder_data.scaling and builder_data.scaling.enabled or false,
    build_out_enabled = builder_data.build_out and builder_data.build_out.enabled or false,
    scale_production_complete = builder_state.scale_production_complete == true,
    scaling_active_task = builder_state.scaling_active_task,
    scaling_pattern_index = builder_state.scaling_pattern_index,
    completed_scaling_milestones = clone_table(builder_state.completed_scaling_milestones or {}),
    production_site_count = adapter.get_production_site_count(),
    resource_site_count = adapter.get_resource_site_count(),
    resource_site_counts = clone_table(adapter.get_resource_site_counts()),
    manual_goal_request = clone_table(builder_state.manual_goal_request),
    manual_pause = clone_table(builder_state.manual_pause),
    manual_active_task = builder_state.manual_goal_request and builder_state.manual_goal_request.tasks and
      builder_state.manual_goal_request.tasks[builder_state.manual_goal_request.current_task_index or 1] or nil,
    recent_maintenance_actions = clone_table(
      (builder_state.maintenance_state and builder_state.maintenance_state.recent_actions) or {}
    ),
    last_recovery = clone_table(builder_state.last_recovery),
    inventory_contents = adapter.get_inventory_contents(entity)
  }
end

return world_snapshot

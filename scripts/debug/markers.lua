local markers = {}

local function get_map_marker_settings(context)
  return context.builder_data.ui and context.builder_data.ui.map_marker or {}
end

local function map_marker_enabled(context)
  return get_map_marker_settings(context).enabled ~= false
end

function markers.ensure_storage()
  if storage.builder_map_markers == nil then
    storage.builder_map_markers = {}
  end

  return storage.builder_map_markers
end

local function destroy_chart_tag_if_valid(tag)
  if tag and tag.valid then
    tag.destroy()
  end
end

function markers.clear()
  local active_markers = markers.ensure_storage()

  for force_index, tag in pairs(active_markers) do
    destroy_chart_tag_if_valid(tag)
    active_markers[force_index] = nil
  end
end

local function clone_position(position)
  return {x = position.x, y = position.y}
end

local function square_distance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return (dx * dx) + (dy * dy)
end

local function get_builder_marker_forces(builder_force)
  local visible_forces = {}

  for _, player in pairs(game.players) do
    if player and player.valid and player.force and player.force.valid and player.force.index ~= builder_force.index then
      visible_forces[player.force.index] = player.force
    end
  end

  return visible_forces
end

function markers.update(builder_state, tick, force_update, context)
  if not map_marker_enabled(context) then
    markers.clear()
    return
  end

  local settings = get_map_marker_settings(context)
  local interval_ticks = settings.update_interval_ticks or 60
  if not force_update and (tick % interval_ticks) ~= 0 then
    return
  end

  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    markers.clear()
    return
  end

  local builder = builder_state.entity
  local active_markers = markers.ensure_storage()
  local active_forces = get_builder_marker_forces(builder.force)
  local refresh_distance = settings.refresh_distance or 1
  local refresh_distance_squared = refresh_distance * refresh_distance

  for force_index, force in pairs(active_forces) do
    local existing_tag = active_markers[force_index]
    local recreate_tag = true

    force.chart(
      builder.surface,
      {
        {builder.position.x - (settings.chart_radius or 16), builder.position.y - (settings.chart_radius or 16)},
        {builder.position.x + (settings.chart_radius or 16), builder.position.y + (settings.chart_radius or 16)}
      }
    )

    if existing_tag and existing_tag.valid then
      local tag_position = existing_tag.position
      if existing_tag.surface == builder.surface and tag_position and square_distance(tag_position, builder.position) <= refresh_distance_squared then
        recreate_tag = false
      else
        destroy_chart_tag_if_valid(existing_tag)
      end
    end

    if recreate_tag then
      active_markers[force_index] = force.add_chart_tag(
        builder.surface,
        {
          position = clone_position(builder.position),
          text = settings.text or "Builder"
        }
      )
    end
  end

  for force_index, tag in pairs(active_markers) do
    if not active_forces[force_index] then
      destroy_chart_tag_if_valid(tag)
      active_markers[force_index] = nil
    end
  end
end

return markers

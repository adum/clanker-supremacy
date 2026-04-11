local pass = {}

function pass.run(builder_state, tick, ctx)
  local collection_settings = ctx.builder_data.logistics and ctx.builder_data.logistics.nearby_container_collection
  if not collection_settings then
    return {}
  end

  if tick < (builder_state.next_container_scan_tick or 0) then
    return {}
  end

  builder_state.next_container_scan_tick = tick + collection_settings.interval_ticks

  local builder = builder_state.entity
  local filter = {
    position = builder.position,
    radius = collection_settings.radius
  }

  if collection_settings.entity_type then
    filter.type = collection_settings.entity_type
  elseif collection_settings.entity_types then
    filter.type = collection_settings.entity_types
  end

  if collection_settings.own_force_only then
    filter.force = builder.force
  end

  local containers = builder.surface.find_entities_filtered(filter)
  table.sort(containers, function(left, right)
    return ctx.square_distance(builder.position, left.position) < ctx.square_distance(builder.position, right.position)
  end)

  local containers_scanned = 0
  local actions = {}

  for _, container in ipairs(containers) do
    if collection_settings.max_containers_per_scan and containers_scanned >= collection_settings.max_containers_per_scan then
      break
    end

    if container.valid then
      containers_scanned = containers_scanned + 1

      local inventory = ctx.get_container_inventory(container)
      if inventory and not inventory.is_empty() then
        local moved_items = ctx.pull_inventory_contents_to_builder(
          inventory,
          builder,
          "collected from " .. container.name .. " at " .. ctx.format_position(container.position)
        )

        if #moved_items > 0 then
          actions[#actions + 1] = "collected from " .. container.name .. " at " .. ctx.format_position(container.position)
        end
      end
    end
  end

  return actions
end

return pass

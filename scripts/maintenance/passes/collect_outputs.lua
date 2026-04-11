local pass = {}

function pass.run(builder_state, tick, ctx)
  local collection_settings = ctx.builder_data.logistics and ctx.builder_data.logistics.nearby_machine_output_collection
  if not collection_settings then
    return {}
  end

  if tick < (builder_state.next_machine_output_collection_tick or 0) then
    return {}
  end

  builder_state.next_machine_output_collection_tick = tick + collection_settings.interval_ticks

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

  if collection_settings.entity_name then
    filter.name = collection_settings.entity_name
  elseif collection_settings.entity_names then
    filter.name = collection_settings.entity_names
  end

  if collection_settings.own_force_only then
    filter.force = builder.force
  end

  local entities = builder.surface.find_entities_filtered(filter)
  table.sort(entities, function(left, right)
    return ctx.square_distance(builder.position, left.position) < ctx.square_distance(builder.position, right.position)
  end)

  local entities_scanned = 0
  local actions = {}

  for _, entity in ipairs(entities) do
    if collection_settings.max_entities_per_scan and entities_scanned >= collection_settings.max_entities_per_scan then
      break
    end

    if entity.valid and entity ~= builder then
      entities_scanned = entities_scanned + 1

      local output_inventory = entity.get_output_inventory and entity.get_output_inventory()
      if output_inventory and not output_inventory.is_empty() then
        local moved_items = ctx.pull_inventory_contents_to_builder(
          output_inventory,
          builder,
          "collected from " .. entity.name .. " output at " .. ctx.format_position(entity.position)
        )

        if #moved_items > 0 then
          actions[#actions + 1] = "collected output from " .. entity.name .. " at " .. ctx.format_position(entity.position)
        end
      end
    end
  end

  return actions
end

return pass

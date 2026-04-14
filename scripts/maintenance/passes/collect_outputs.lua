local pass = {}

local function get_inventory_content_entry_name(content_key, item_stack)
  if type(item_stack) == "table" and item_stack.name then
    return item_stack.name
  end

  if type(content_key) == "string" then
    return content_key
  end

  if type(content_key) == "table" and content_key.name then
    return content_key.name
  end

  return nil
end

local function get_inventory_content_entry_count(item_stack)
  if type(item_stack) == "number" then
    return item_stack
  end

  if type(item_stack) == "table" then
    return item_stack.count or 0
  end

  return 0
end

local function get_total_item_count(inventory, allowed_item_names)
  local total = 0

  for content_key, item_stack in pairs(inventory.get_contents()) do
    local item_name = get_inventory_content_entry_name(content_key, item_stack)
    if item_name and (not allowed_item_names or allowed_item_names[item_name]) then
      total = total + get_inventory_content_entry_count(item_stack)
    end
  end

  return total
end

local function get_assembler_output_item_allowlist(entity, builder, collection_settings, ctx)
  if not (entity and entity.valid and entity.type == "assembling-machine") then
    return nil
  end

  local item_limits = collection_settings.assembler_item_limits or {}
  local allowed_item_names = {}

  for item_name, maximum_count in pairs(item_limits) do
    if ctx.get_item_count(builder, item_name) < maximum_count then
      allowed_item_names[item_name] = true
    end
  end

  return allowed_item_names
end

function pass.run(builder_state, tick, ctx)
  local test_state = storage.enemy_builder_test
  if test_state and test_state.disable_nearby_machine_output_collection == true then
    return {}
  end

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
        local allowed_item_names = get_assembler_output_item_allowlist(entity, builder, collection_settings, ctx)
        if allowed_item_names and next(allowed_item_names) == nil then
          goto continue
        end

        local minimum_total_items =
          (entity.type == "assembling-machine" and collection_settings.minimum_assembler_items_to_collect) or
          collection_settings.minimum_total_items_to_collect or 1
        if get_total_item_count(output_inventory, allowed_item_names) < minimum_total_items then
          goto continue
        end

        local moved_items = ctx.pull_inventory_contents_to_builder(
          output_inventory,
          builder,
          "collected from " .. entity.name .. " output at " .. ctx.format_position(entity.position),
          allowed_item_names
        )

        if #moved_items > 0 then
          actions[#actions + 1] = "collected output from " .. entity.name .. " at " .. ctx.format_position(entity.position)
        end
      end
    end

    ::continue::
  end

  return actions
end

return pass

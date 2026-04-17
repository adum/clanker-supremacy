local pass = {}

local function miner_has_mineable_resources(surface, miner)
  if not (surface and miner and miner.valid and miner.mining_area) then
    return false
  end

  return #surface.find_entities_filtered{
    area = miner.mining_area,
    type = "resource"
  } > 0
end

function pass.run(builder_state, tick, ctx)
  local cleanup_settings = ctx.builder_data.logistics and ctx.builder_data.logistics.nearby_exhausted_miner_cleanup
  if not cleanup_settings then
    return {}
  end

  if tick < (builder_state.next_exhausted_miner_cleanup_tick or 0) then
    return {}
  end

  builder_state.next_exhausted_miner_cleanup_tick = tick + cleanup_settings.interval_ticks

  local builder = builder_state.entity
  local filter = {
    position = builder.position,
    radius = cleanup_settings.radius,
    type = "mining-drill"
  }

  if cleanup_settings.own_force_only then
    filter.force = builder.force
  end

  local miners = builder.surface.find_entities_filtered(filter)
  table.sort(miners, function(left, right)
    return ctx.square_distance(builder.position, left.position) < ctx.square_distance(builder.position, right.position)
  end)

  local miners_scanned = 0
  local actions = {}

  for _, miner in ipairs(miners) do
    if cleanup_settings.max_entities_per_scan and miners_scanned >= cleanup_settings.max_entities_per_scan then
      break
    end

    if miner.valid and miner ~= builder then
      miners_scanned = miners_scanned + 1

      if not miner_has_mineable_resources(builder.surface, miner) then
        local miner_position = {
          x = miner.position.x,
          y = miner.position.y
        }
        local reason_suffix = "exhausted " .. miner.name .. " at " .. ctx.format_position(miner_position)
        local output_inventory = miner.get_output_inventory and miner.get_output_inventory() or nil
        local fuel_inventory = miner.get_fuel_inventory and miner.get_fuel_inventory() or nil

        if output_inventory and not output_inventory.is_empty() then
          ctx.pull_inventory_contents_to_builder(output_inventory, builder, "collected from " .. reason_suffix .. " output")
        end

        if fuel_inventory and not fuel_inventory.is_empty() then
          ctx.pull_inventory_contents_to_builder(fuel_inventory, builder, "collected fuel from " .. reason_suffix)
        end

        local inserted_count = ctx.insert_item(builder, miner.name, 1, "picked up " .. reason_suffix)
        if inserted_count >= 1 then
          miner.destroy()
          ctx.debug_log("picked up " .. reason_suffix)
          actions[#actions + 1] = "picked up exhausted miner at " .. ctx.format_position(miner_position)
          break
        end
      end
    end
  end

  return actions
end

return pass

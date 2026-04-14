local pass = {}

function pass.run(builder_state, tick, ctx)
  local refuel_settings = ctx.builder_data.logistics and ctx.builder_data.logistics.nearby_machine_refuel
  if not refuel_settings then
    return {}
  end

  if tick < (builder_state.next_machine_refuel_tick or 0) then
    return {}
  end

  builder_state.next_machine_refuel_tick = tick + refuel_settings.interval_ticks

  local builder = builder_state.entity
  local fuel_name = refuel_settings.fuel_name or "coal"
  local minimum_transfer_count = refuel_settings.minimum_item_transfer_count or 1
  local available_fuel = ctx.get_item_count(builder, fuel_name)
  if available_fuel < minimum_transfer_count then
    return {}
  end

  local filter = {
    position = builder.position,
    radius = refuel_settings.radius
  }

  if refuel_settings.own_force_only then
    filter.force = builder.force
  end

  local entities = builder.surface.find_entities_filtered(filter)
  table.sort(entities, function(left, right)
    return ctx.square_distance(builder.position, left.position) < ctx.square_distance(builder.position, right.position)
  end)

  local entities_scanned = 0
  local actions = {}

  for _, entity in ipairs(entities) do
    if refuel_settings.max_entities_per_scan and entities_scanned >= refuel_settings.max_entities_per_scan then
      break
    end

    if entity.valid and entity ~= builder then
      entities_scanned = entities_scanned + 1

      local fuel_inventory = entity.get_fuel_inventory and entity.get_fuel_inventory()
      if fuel_inventory then
        local current_fuel_count = fuel_inventory.get_item_count(fuel_name)
        local wanted_fuel_count = (refuel_settings.target_fuel_item_count or 20) - current_fuel_count
        if wanted_fuel_count >= minimum_transfer_count then
          local insert_count = math.min(wanted_fuel_count, available_fuel)
          if insert_count >= minimum_transfer_count then
            local inserted_count = fuel_inventory.insert{
              name = fuel_name,
              count = insert_count
            }

            if inserted_count > 0 and inserted_count < minimum_transfer_count then
              fuel_inventory.remove{
                name = fuel_name,
                count = inserted_count
              }
              inserted_count = 0
            end

            if inserted_count >= minimum_transfer_count then
              local reason = "refueled " .. entity.name .. " at " .. ctx.format_position(entity.position)
              local removed_count = ctx.remove_item(builder, fuel_name, inserted_count, reason)

              if removed_count < inserted_count then
                fuel_inventory.remove{
                  name = fuel_name,
                  count = inserted_count - removed_count
                }
                inserted_count = removed_count
              end

              if inserted_count > 0 then
                available_fuel = available_fuel - inserted_count
                ctx.debug_log(
                  reason .. " with " .. inserted_count .. " " .. fuel_name ..
                  "; machine now has " .. fuel_inventory.get_item_count(fuel_name)
                )
                actions[#actions + 1] = "refueled " .. entity.name .. " at " .. ctx.format_position(entity.position)
              end

              if available_fuel < minimum_transfer_count then
                break
              end
            end
          end
        end
      end
    end
  end

  return actions
end

return pass

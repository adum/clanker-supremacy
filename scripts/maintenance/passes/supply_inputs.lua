local pass = {}

local function is_belt_fed_assembly_block_assembler(entity)
  for _, site in ipairs(storage.production_sites or {}) do
    if site.site_type == "assembly-block" then
      for _, assembler in ipairs(site.assemblers or {}) do
        if assembler == entity then
          return true
        end
      end
    end
  end

  return false
end

function pass.run(builder_state, tick, ctx)
  local supply_settings = ctx.builder_data.logistics and ctx.builder_data.logistics.nearby_machine_input_supply
  if not supply_settings then
    return {}
  end

  if tick < (builder_state.next_machine_input_supply_tick or 0) then
    return {}
  end

  builder_state.next_machine_input_supply_tick = tick + supply_settings.interval_ticks

  local builder = builder_state.entity
  local filter = {
    position = builder.position,
    radius = supply_settings.radius
  }

  if supply_settings.entity_type then
    filter.type = supply_settings.entity_type
  elseif supply_settings.entity_types then
    filter.type = supply_settings.entity_types
  end

  if supply_settings.entity_name then
    filter.name = supply_settings.entity_name
  elseif supply_settings.entity_names then
    filter.name = supply_settings.entity_names
  end

  if supply_settings.own_force_only then
    filter.force = builder.force
  end

  local entities = builder.surface.find_entities_filtered(filter)
  table.sort(entities, function(left, right)
    return ctx.square_distance(builder.position, left.position) < ctx.square_distance(builder.position, right.position)
  end)

  local entities_scanned = 0
  local actions = {}

  for _, entity in ipairs(entities) do
    if supply_settings.max_entities_per_scan and entities_scanned >= supply_settings.max_entities_per_scan then
      break
    end

    if entity.valid and entity ~= builder then
      entities_scanned = entities_scanned + 1

      if is_belt_fed_assembly_block_assembler(entity) then
        goto continue
      end

      local recipe = entity.get_recipe and entity.get_recipe()
      local input_inventory = entity.get_inventory and entity.get_inventory(defines.inventory.assembling_machine_input)

      if recipe and input_inventory then
        for _, ingredient in ipairs(recipe.ingredients or {}) do
          local ingredient_type = ingredient.type or "item"
          local ingredient_name = ingredient.name

          if ingredient_type == "item" and ingredient_name then
            local current_count = input_inventory.get_item_count(ingredient_name)
            local desired_count = (supply_settings.target_ingredient_item_count or 20) - current_count

            if desired_count > 0 then
              local minimum_transfer_count = supply_settings.minimum_item_transfer_count or 1
              if desired_count < minimum_transfer_count then
                goto next_ingredient
              end

              local available_count = ctx.get_item_count(builder, ingredient_name)
              local transfer_count = math.min(desired_count, available_count)

              if transfer_count >= minimum_transfer_count then
                local inserted_count = input_inventory.insert{
                  name = ingredient_name,
                  count = transfer_count
                }

                if inserted_count > 0 then
                  local reason =
                    "supplied " .. ingredient_name .. " to " .. entity.name ..
                    " at " .. ctx.format_position(entity.position)
                  local removed_count = ctx.remove_item(builder, ingredient_name, inserted_count, reason)

                  if removed_count < inserted_count then
                    input_inventory.remove{
                      name = ingredient_name,
                      count = inserted_count - removed_count
                    }
                    inserted_count = removed_count
                  end

                  if inserted_count > 0 then
                    ctx.debug_log(
                      reason .. " with " .. inserted_count ..
                      "; machine now has " .. input_inventory.get_item_count(ingredient_name) ..
                      " " .. ingredient_name
                    )
                    actions[#actions + 1] = "supplied " .. ingredient_name .. " to " .. entity.name .. " at " .. ctx.format_position(entity.position)
                  end
                end
              end
            end
          end

          ::next_ingredient::
        end
      end
    end

    ::continue::
  end

  return actions
end

return pass

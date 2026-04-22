local pass = {}

local function get_tree_products(harvest_settings)
  return harvest_settings.products or {
    {name = harvest_settings.item_name or "wood", count = harvest_settings.items_per_tree or 4}
  }
end

function pass.run(builder_state, tick, ctx)
  local harvest_settings = ctx.builder_data.logistics and ctx.builder_data.logistics.nearby_tree_harvest
  if not harvest_settings then
    return {}
  end

  if tick < (builder_state.next_nearby_tree_harvest_tick or 0) then
    return {}
  end

  builder_state.next_nearby_tree_harvest_tick = tick + (harvest_settings.interval_ticks or 60)

  local builder = builder_state.entity
  local item_name = harvest_settings.item_name or "wood"
  local target_count = harvest_settings.target_item_count or 60
  if ctx.get_item_count(builder, item_name) >= target_count then
    return {}
  end

  local trees = builder.surface.find_entities_filtered{
    position = builder.position,
    radius = harvest_settings.radius or 24,
    type = "tree"
  }
  table.sort(trees, function(left, right)
    return ctx.square_distance(builder.position, left.position) < ctx.square_distance(builder.position, right.position)
  end)

  for _, tree in ipairs(trees) do
    if tree.valid then
      local tree_position = {
        x = tree.position.x,
        y = tree.position.y
      }
      tree.destroy()

      local inserted_products = ctx.insert_products(
        builder,
        get_tree_products(harvest_settings),
        "harvested nearby tree at " .. ctx.format_position(tree_position)
      )

      ctx.debug_log(
        "harvested nearby tree at " .. ctx.format_position(tree_position) ..
        "; inserted " .. ctx.format_products(inserted_products) ..
        "; " .. item_name .. "=" .. tostring(ctx.get_item_count(builder, item_name)) ..
        "/" .. tostring(target_count)
      )

      return {
        "harvested nearby tree at " .. ctx.format_position(tree_position)
      }
    end
  end

  return {}
end

return pass

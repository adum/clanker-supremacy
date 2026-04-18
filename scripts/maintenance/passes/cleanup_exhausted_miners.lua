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

local function point_in_area(position, area)
  if not (position and area and area.left_top and area.right_bottom) then
    return false
  end

  return position.x >= area.left_top.x and position.x <= area.right_bottom.x and
    position.y >= area.left_top.y and position.y <= area.right_bottom.y
end

local function find_direct_downstream_site(resource_sites, miner)
  if not (resource_sites and miner and miner.valid and miner.drop_position) then
    return nil
  end

  local fallback_site = nil

  for _, site in ipairs(resource_sites) do
    local downstream_machine = site and site.downstream_machine or nil
    if site and site.miner == miner and downstream_machine and downstream_machine.valid then
      fallback_site = fallback_site or site

      if point_in_area(miner.drop_position, downstream_machine.selection_box) then
        return site
      end
    end
  end

  return fallback_site
end

local function count_other_direct_feeders(resource_sites, downstream_machine, ignored_miner)
  if not (resource_sites and downstream_machine and downstream_machine.valid) then
    return 0
  end

  local feeder_count = 0

  for _, site in ipairs(resource_sites) do
    if site and site.miner and site.miner.valid and site.miner ~= ignored_miner and site.downstream_machine == downstream_machine then
      feeder_count = feeder_count + 1
    end
  end

  return feeder_count
end

local function append_unique_target(targets, seen_targets, entity, role)
  if not (entity and entity.valid) then
    return
  end

  local target_key = tostring(entity.unit_number or (entity.name .. ":" .. entity.position.x .. ":" .. entity.position.y))
  if seen_targets[target_key] then
    return
  end

  seen_targets[target_key] = true
  targets[#targets + 1] = {
    entity = entity,
    role = role
  }
end

local function collect_follow_on_steel_targets(resource_sites, production_sites, anchor_machine)
  local targets = {}
  local seen_targets = {}

  if not (anchor_machine and anchor_machine.valid) then
    return targets
  end

  for _, site in ipairs(resource_sites or {}) do
    if site and site.anchor_machine == anchor_machine then
      append_unique_target(targets, seen_targets, site.downstream_machine, "downstream steel furnace")
      append_unique_target(targets, seen_targets, site.feed_inserter, "steel feed inserter")
    end
  end

  for _, site in ipairs(production_sites or {}) do
    if site and site.site_type == "steel-smelting-chain" and site.anchor_machine == anchor_machine then
      append_unique_target(targets, seen_targets, site.downstream_machine, "downstream steel furnace")
      append_unique_target(targets, seen_targets, site.feed_inserter, "steel feed inserter")
    end
  end

  return targets
end

local function pull_entity_contents_to_builder(entity, builder, ctx, reason_suffix)
  if not (entity and entity.valid and builder and builder.valid) then
    return
  end

  local output_inventory = entity.get_output_inventory and entity.get_output_inventory() or nil
  local fuel_inventory = entity.get_fuel_inventory and entity.get_fuel_inventory() or nil

  if entity.type == "furnace" and entity.get_inventory then
    local source_inventory = entity.get_inventory(defines.inventory.furnace_source)
    if source_inventory and not source_inventory.is_empty() then
      ctx.pull_inventory_contents_to_builder(source_inventory, builder, "collected input from " .. reason_suffix)
    end
  end

  if output_inventory and not output_inventory.is_empty() then
    ctx.pull_inventory_contents_to_builder(output_inventory, builder, "collected from " .. reason_suffix .. " output")
  end

  if fuel_inventory and not fuel_inventory.is_empty() then
    ctx.pull_inventory_contents_to_builder(fuel_inventory, builder, "collected fuel from " .. reason_suffix)
  end
end

local function pick_up_entity(entity, builder, ctx, actions, label_prefix)
  if not (entity and entity.valid and builder and builder.valid) then
    return true
  end

  local entity_position = {
    x = entity.position.x,
    y = entity.position.y
  }
  local reason_suffix = label_prefix .. " " .. entity.name .. " at " .. ctx.format_position(entity_position)

  pull_entity_contents_to_builder(entity, builder, ctx, reason_suffix)

  local inserted_count = ctx.insert_item(builder, entity.name, 1, "picked up " .. reason_suffix)
  if inserted_count < 1 then
    return false
  end

  entity.destroy()
  ctx.debug_log("picked up " .. reason_suffix)
  actions[#actions + 1] = "picked up " .. label_prefix .. " at " .. ctx.format_position(entity_position)
  return true
end

local function build_cleanup_targets(ctx, miner)
  local resource_sites = ctx.cleanup_resource_sites and ctx.cleanup_resource_sites() or {}
  local direct_site = find_direct_downstream_site(resource_sites, miner)
  local direct_furnace = direct_site and direct_site.downstream_machine or nil

  local targets = {}
  local seen_targets = {}
  local downstream_cleanup_planned = false

  if direct_furnace and direct_furnace.valid and count_other_direct_feeders(resource_sites, direct_furnace, miner) == 0 then
    local production_sites = ctx.ensure_production_sites and ctx.ensure_production_sites() or {}
    for _, target in ipairs(collect_follow_on_steel_targets(resource_sites, production_sites, direct_furnace)) do
      append_unique_target(targets, seen_targets, target.entity, target.role)
    end

    append_unique_target(targets, seen_targets, direct_furnace, "orphaned furnace")
    downstream_cleanup_planned = true
  end

  append_unique_target(targets, seen_targets, miner, downstream_cleanup_planned and "exhausted upstream miner" or "exhausted miner")

  return targets
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
        local cleanup_targets = build_cleanup_targets(ctx, miner)
        local cleaned_any = false

        for _, target in ipairs(cleanup_targets) do
          if not pick_up_entity(target.entity, builder, ctx, actions, target.role) then
            break
          end
          cleaned_any = true
        end

        if cleaned_any then
          if ctx.cleanup_resource_sites then
            ctx.cleanup_resource_sites()
          end
          break
        end
      end
    end
  end

  return actions
end

return pass

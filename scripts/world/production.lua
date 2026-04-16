local storage_helpers = require("scripts.world.storage")

local production = {}

local function get_site_identity_key(site)
  if not site then
    return nil
  end

  local entity = site.output_machine or site.root_assembler or site.anchor_entity or site.downstream_machine
  if entity and entity.valid and entity.unit_number then
    return tostring(entity.unit_number)
  end

  local position = entity and entity.valid and entity.position or site.hub_position
  if position then
    return string.format("%.2f:%.2f:%s", position.x, position.y, site.site_type or "site")
  end

  return nil
end

function production.register_smelting_site(task, miner, downstream_machine, output_container, ctx)
  local production_sites = storage_helpers.ensure_production_sites()
  local task_id = (task and task.id) or (task and task.pattern_name) or "smelting-site"

  for _, site in ipairs(production_sites) do
    if site.miner == miner then
      site.task_id = task_id
      site.downstream_machine = downstream_machine
      site.output_container = output_container
      site.input_item_names = {
        [task.resource_name] = true
      }
      return site
    end
  end

  production_sites[#production_sites + 1] = {
    task_id = task_id,
    site_type = "smelting-chain",
    miner = miner,
    downstream_machine = downstream_machine,
    output_container = output_container,
    input_item_names = {
      [task.resource_name] = true
    },
    transfer_interval_ticks = (task.transfer and task.transfer.interval_ticks) or
      (ctx.builder_data.logistics and ctx.builder_data.logistics.production_transfer and ctx.builder_data.logistics.production_transfer.interval_ticks) or
      30,
    next_transfer_tick = 0
  }

  local message =
    "task " .. task_id .. ": registered smelting site with miner at " .. ctx.format_position(miner.position) ..
    ", " .. downstream_machine.name .. " at " .. ctx.format_position(downstream_machine.position)

  if output_container and output_container.valid then
    message = message .. " and output container at " .. ctx.format_position(output_container.position)
  end

  ctx.debug_log(message)
  return production_sites[#production_sites]
end

function production.register_steel_smelting_site(task, anchor_machine, feed_inserter, downstream_machine, miner, ctx)
  if not (task and anchor_machine and anchor_machine.valid and feed_inserter and feed_inserter.valid and downstream_machine and downstream_machine.valid) then
    return nil
  end

  local production_sites = storage_helpers.ensure_production_sites()
  local task_id = (task and task.id) or (task and task.pattern_name) or "steel-smelting-site"

  for _, site in ipairs(production_sites) do
    if site.site_type == "steel-smelting-chain" and site.anchor_machine == anchor_machine then
      site.task_id = task_id
      site.miner = miner
      site.anchor_machine = anchor_machine
      site.feed_inserter = feed_inserter
      site.downstream_machine = downstream_machine
      return site
    end
  end

  production_sites[#production_sites + 1] = {
    task_id = task_id,
    site_type = "steel-smelting-chain",
    miner = miner,
    anchor_machine = anchor_machine,
    feed_inserter = feed_inserter,
    downstream_machine = downstream_machine
  }

  ctx.debug_log(
    "task " .. task_id .. ": registered steel smelting site with anchor furnace at " ..
    ctx.format_position(anchor_machine.position) .. ", burner-inserter at " ..
    ctx.format_position(feed_inserter.position) .. ", steel furnace at " ..
    ctx.format_position(downstream_machine.position)
  )

  return production_sites[#production_sites]
end

function production.register_assembler_defense_site(task, assembler, placed_layout_entities, ctx)
  if not (task and assembler and assembler.valid) then
    return nil
  end

  local turrets = {}
  local inserters = {}
  local poles = {}
  local solar_panels = {}

  for _, placement in ipairs(placed_layout_entities or {}) do
    local entity = placement.entity
    if entity and entity.valid then
      if placement.site_role == "turret" then
        turrets[#turrets + 1] = entity
      elseif placement.site_role == "burner-inserter" then
        inserters[#inserters + 1] = entity
      elseif placement.site_role == "power-pole" then
        poles[#poles + 1] = entity
      elseif placement.site_role == "solar-panel" then
        solar_panels[#solar_panels + 1] = entity
      end
    end
  end

  if #turrets == 0 then
    return nil
  end

  local production_sites = storage_helpers.ensure_production_sites()
  for _, site in ipairs(production_sites) do
    if site.site_type == "assembler-defense" and site.assembler == assembler then
      site.task_id = task.id or task.completed_scaling_milestone_name or "assembler-defense"
      site.pattern_name = task.pattern_name
      site.turrets = turrets
      site.inserters = inserters
      site.power_poles = poles
      site.solar_panels = solar_panels
      return site
    end
  end

  production_sites[#production_sites + 1] = {
    task_id = task.id or task.completed_scaling_milestone_name or "assembler-defense",
    site_type = "assembler-defense",
    pattern_name = task.pattern_name,
    assembler = assembler,
    turrets = turrets,
    inserters = inserters,
    power_poles = poles,
    solar_panels = solar_panels
  }

  ctx.debug_log(
    "task " .. (task.id or "assembler-defense") ..
    ": registered assembler defense site at " .. ctx.format_position(assembler.position) ..
    " with " .. tostring(#turrets) .. " turrets"
  )

  return production_sites[#production_sites]
end

function production.get_pattern_site_counts()
  local counts = {}

  for _, site in ipairs(storage_helpers.ensure_production_sites()) do
    if site.site_type == "assembler-defense" and site.pattern_name and site.assembler and site.assembler.valid then
      for _, turret in ipairs(site.turrets or {}) do
        if turret and turret.valid then
          counts[site.pattern_name] = (counts[site.pattern_name] or 0) + 1
          break
        end
      end
    end
  end

  return counts
end

function production.register_output_belt_site(task, output_machine, output_inserter, belt_entities, hub_position, ctx)
  if not (task and output_machine and output_machine.valid and output_inserter and output_inserter.valid) then
    return nil
  end

  local valid_belts = {}
  for _, belt_entity in ipairs(belt_entities or {}) do
    if belt_entity and belt_entity.valid then
      valid_belts[#valid_belts + 1] = belt_entity
    end
  end

  if #valid_belts == 0 then
    return nil
  end

  local production_sites = storage_helpers.ensure_production_sites()
  local task_id = (task and task.id) or (task and task.pattern_name) or "smelting-output-belt"

  for _, site in ipairs(production_sites) do
    if site.site_type == "smelting-output-belt" and site.output_machine == output_machine then
      site.task_id = task_id
      site.output_item_name = task.output_item_name
      site.output_machine = output_machine
      site.output_inserter = output_inserter
      site.belt_entities = valid_belts
      site.hub_position = hub_position
      return site
    end
  end

  production_sites[#production_sites + 1] = {
    task_id = task_id,
    site_type = "smelting-output-belt",
    output_item_name = task.output_item_name,
    output_machine = output_machine,
    output_inserter = output_inserter,
    belt_entities = valid_belts,
    hub_position = hub_position
  }

  ctx.debug_log(
    "task " .. task_id .. ": registered smelting output belt at " ..
    ctx.format_position(output_machine.position) ..
    " with inserter at " .. ctx.format_position(output_inserter.position) ..
    " and " .. tostring(#valid_belts) .. " belts toward " ..
    ctx.format_position(hub_position)
  )

  return production_sites[#production_sites]
end

function production.register_assembly_block_site(task, anchor_entity, root_assembler, placed_layout_entities, ctx)
  if not (task and anchor_entity and anchor_entity.valid and root_assembler and root_assembler.valid) then
    return nil
  end

  local assemblers = {}
  local inserters = {}
  local poles = {}
  local belts = {}
  local route_local_belts_by_id = {}
  local route_input_inserters_by_id = {}

  for _, placement in ipairs(placed_layout_entities or {}) do
    local placed_entity = placement.entity
    if placed_entity and placed_entity.valid then
      if placed_entity.type == "assembling-machine" then
        assemblers[#assemblers + 1] = placed_entity
      elseif placed_entity.type == "inserter" then
        inserters[#inserters + 1] = placed_entity
        if placement.route_id and placement.site_role == "input-inserter" then
          route_input_inserters_by_id[placement.route_id] = route_input_inserters_by_id[placement.route_id] or {}
          route_input_inserters_by_id[placement.route_id][#route_input_inserters_by_id[placement.route_id] + 1] = placed_entity
        end
      elseif placed_entity.type == "electric-pole" then
        poles[#poles + 1] = placed_entity
      elseif placed_entity.type == "transport-belt" then
        belts[#belts + 1] = placed_entity
        if placement.route_id then
          route_local_belts_by_id[placement.route_id] = route_local_belts_by_id[placement.route_id] or {}
          route_local_belts_by_id[placement.route_id][#route_local_belts_by_id[placement.route_id] + 1] = placed_entity
        end
      end
    end
  end

  local production_sites = storage_helpers.ensure_production_sites()
  for _, site in ipairs(production_sites) do
    if site.site_type == "assembly-block" and site.anchor_entity == anchor_entity then
      site.task_id = task.id or task.pattern_name or "assembly-block"
      site.target_item_name = task.target_item_name
      site.anchor_entity = anchor_entity
      site.root_assembler = root_assembler
      site.assemblers = assemblers
      site.inserters = inserters
      site.power_poles = poles
      site.belt_entities = belts
      site.route_local_belts_by_id = route_local_belts_by_id
      site.route_input_inserters_by_id = route_input_inserters_by_id
      site.route_connections_by_id = site.route_connections_by_id or {}
      site.source_route_belts_by_id = site.source_route_belts_by_id or {}
      site.route_specs_by_id = {}
      for _, route_spec in ipairs(((task.assembly_target or {}).raw_input_routes) or {}) do
        site.route_specs_by_id[route_spec.id] = route_spec
      end
      return site
    end
  end

  production_sites[#production_sites + 1] = {
    task_id = task.id or task.pattern_name or "assembly-block",
    site_type = "assembly-block",
    target_item_name = task.target_item_name,
    anchor_entity = anchor_entity,
    root_assembler = root_assembler,
    assemblers = assemblers,
    inserters = inserters,
    power_poles = poles,
    belt_entities = belts,
    route_local_belts_by_id = route_local_belts_by_id,
    route_input_inserters_by_id = route_input_inserters_by_id,
    route_connections_by_id = {},
    source_route_belts_by_id = {},
    route_specs_by_id = {}
  }

  for _, route_spec in ipairs(((task.assembly_target or {}).raw_input_routes) or {}) do
    production_sites[#production_sites].route_specs_by_id[route_spec.id] = route_spec
  end

  ctx.debug_log(
    "task " .. (task.id or "assembly-block") ..
    ": registered assembly block at " .. ctx.format_position(root_assembler.position) ..
    " anchored to " .. anchor_entity.name .. " at " .. ctx.format_position(anchor_entity.position)
  )

  return production_sites[#production_sites]
end

function production.register_assembly_input_route(task, assembly_site, route_id, belt_entities, source_site, ctx)
  if not (task and assembly_site and assembly_site.root_assembler and assembly_site.root_assembler.valid and route_id) then
    return nil
  end

  local valid_belts = {}
  for _, belt_entity in ipairs(belt_entities or {}) do
    if belt_entity and belt_entity.valid then
      valid_belts[#valid_belts + 1] = belt_entity
    end
  end

  if #valid_belts == 0 then
    return nil
  end

  assembly_site.belt_entities = assembly_site.belt_entities or {}
  for _, belt_entity in ipairs(valid_belts) do
    assembly_site.belt_entities[#assembly_site.belt_entities + 1] = belt_entity
  end

  assembly_site.source_route_belts_by_id = assembly_site.source_route_belts_by_id or {}
  assembly_site.source_route_belts_by_id[route_id] = valid_belts

  assembly_site.route_connections_by_id = assembly_site.route_connections_by_id or {}
  assembly_site.route_connections_by_id[route_id] = {
    route_id = route_id,
    source_site_key = get_site_identity_key(source_site),
    source_site = source_site,
    belt_entities = valid_belts
  }

  ctx.debug_log(
    "task " .. (task.id or "assembly-input-route") ..
    ": connected assembly route " .. route_id ..
    " into block at " .. ctx.format_position(assembly_site.root_assembler.position) ..
    " with " .. tostring(#valid_belts) .. " belts"
  )

  return assembly_site.route_connections_by_id[route_id]
end

function production.process_production_sites(tick, ctx)
  local production_sites = storage_helpers.ensure_production_sites()
  local kept_sites = {}

  for _, site in ipairs(production_sites) do
    if site.site_type == "assembler-defense" then
      local valid_turrets = {}
      local valid_inserters = {}
      local valid_poles = {}
      local valid_solar_panels = {}

      for _, turret in ipairs(site.turrets or {}) do
        if turret and turret.valid then
          valid_turrets[#valid_turrets + 1] = turret
        end
      end

      for _, inserter in ipairs(site.inserters or {}) do
        if inserter and inserter.valid then
          valid_inserters[#valid_inserters + 1] = inserter
        end
      end

      for _, pole in ipairs(site.power_poles or {}) do
        if pole and pole.valid then
          valid_poles[#valid_poles + 1] = pole
        end
      end

      for _, solar_panel in ipairs(site.solar_panels or {}) do
        if solar_panel and solar_panel.valid then
          valid_solar_panels[#valid_solar_panels + 1] = solar_panel
        end
      end

      site.turrets = valid_turrets
      site.inserters = valid_inserters
      site.power_poles = valid_poles
      site.solar_panels = valid_solar_panels

      if site.assembler and site.assembler.valid and #site.turrets > 0 then
        kept_sites[#kept_sites + 1] = site
      end
    elseif site.site_type == "steel-smelting-chain" then
      if site.anchor_machine and site.anchor_machine.valid and
        site.feed_inserter and site.feed_inserter.valid and
        site.downstream_machine and site.downstream_machine.valid and
        site.miner and site.miner.valid
      then
        kept_sites[#kept_sites + 1] = site
      end
    elseif site.site_type == "smelting-output-belt" then
      local valid_belts = {}

      for _, belt_entity in ipairs(site.belt_entities or {}) do
        if belt_entity and belt_entity.valid then
          valid_belts[#valid_belts + 1] = belt_entity
        end
      end

      site.belt_entities = valid_belts

      if site.output_machine and site.output_machine.valid and
        site.output_inserter and site.output_inserter.valid and
        #site.belt_entities > 0
      then
        kept_sites[#kept_sites + 1] = site
      end
    elseif site.site_type == "assembly-block" then
      local valid_assemblers = {}
      local valid_inserters = {}
      local valid_poles = {}
      local valid_belts = {}

      for _, placed_entity in ipairs(site.assemblers or {}) do
        if placed_entity and placed_entity.valid then
          valid_assemblers[#valid_assemblers + 1] = placed_entity
        end
      end

      for _, placed_entity in ipairs(site.inserters or {}) do
        if placed_entity and placed_entity.valid then
          valid_inserters[#valid_inserters + 1] = placed_entity
        end
      end

      for _, placed_entity in ipairs(site.power_poles or {}) do
        if placed_entity and placed_entity.valid then
          valid_poles[#valid_poles + 1] = placed_entity
        end
      end

      for _, placed_entity in ipairs(site.belt_entities or {}) do
        if placed_entity and placed_entity.valid then
          valid_belts[#valid_belts + 1] = placed_entity
        end
      end

      site.assemblers = valid_assemblers
      site.inserters = valid_inserters
      site.power_poles = valid_poles
      site.belt_entities = valid_belts
      local valid_route_connections_by_id = {}
      local valid_source_route_belts_by_id = {}
      for route_id, connection in pairs(site.route_connections_by_id or {}) do
        local route_belts = {}
        for _, belt_entity in ipairs((connection and connection.belt_entities) or {}) do
          if belt_entity and belt_entity.valid then
            route_belts[#route_belts + 1] = belt_entity
          end
        end

        if #route_belts > 0 then
          connection.belt_entities = route_belts
          valid_route_connections_by_id[route_id] = connection
          valid_source_route_belts_by_id[route_id] = route_belts
        end
      end
      site.route_connections_by_id = valid_route_connections_by_id
      site.source_route_belts_by_id = valid_source_route_belts_by_id

      if site.anchor_entity and site.anchor_entity.valid and
        site.root_assembler and site.root_assembler.valid and
        #site.assemblers > 0
      then
        kept_sites[#kept_sites + 1] = site
      end
    elseif site.miner and site.miner.valid and site.downstream_machine and site.downstream_machine.valid and (not site.output_container or site.output_container.valid) then
      if tick >= (site.next_transfer_tick or 0) then
        site.next_transfer_tick = tick + site.transfer_interval_ticks

        ctx.transfer_inventory_contents(
          site.miner.get_output_inventory(),
          site.downstream_machine,
          "production site " .. site.task_id .. ": transferred miner output into " .. site.downstream_machine.name,
          site.input_item_names
        )

        if site.output_container and site.output_container.valid then
          ctx.transfer_inventory_contents(
            site.downstream_machine.get_output_inventory(),
            ctx.get_container_inventory(site.output_container),
            "production site " .. site.task_id .. ": transferred smelter output into " .. site.output_container.name
          )
        end
      end

      kept_sites[#kept_sites + 1] = site
    end
  end

  storage.production_sites = kept_sites
end

return production

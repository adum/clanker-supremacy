local storage_helpers = require("scripts.world.storage")

local production = {}

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

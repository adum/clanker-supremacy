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
      site.input_item_names = {
        ["iron-plate"] = true
      }
      site.transfer_interval_ticks = (ctx.builder_data.logistics and ctx.builder_data.logistics.production_transfer and ctx.builder_data.logistics.production_transfer.interval_ticks) or 30
      return site
    end
  end

  production_sites[#production_sites + 1] = {
    task_id = task_id,
    site_type = "steel-smelting-chain",
    miner = miner,
    anchor_machine = anchor_machine,
    feed_inserter = feed_inserter,
    downstream_machine = downstream_machine,
    input_item_names = {
      ["iron-plate"] = true
    },
    transfer_interval_ticks = (ctx.builder_data.logistics and ctx.builder_data.logistics.production_transfer and ctx.builder_data.logistics.production_transfer.interval_ticks) or 30,
    next_transfer_tick = 0
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
      site.ammo_item_name = (task.transfer and task.transfer.ammo_item_name) or "firearm-magazine"
      site.turret_ammo_target_count = (task.transfer and task.transfer.turret_ammo_target_count) or 20
      site.per_turret_transfer_limit = (task.transfer and task.transfer.per_turret_transfer_limit) or 1
      site.transfer_interval_ticks = (task.transfer and task.transfer.interval_ticks) or 30
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
    solar_panels = solar_panels,
    ammo_item_name = (task.transfer and task.transfer.ammo_item_name) or "firearm-magazine",
    turret_ammo_target_count = (task.transfer and task.transfer.turret_ammo_target_count) or 20,
    per_turret_transfer_limit = (task.transfer and task.transfer.per_turret_transfer_limit) or 1,
    transfer_interval_ticks = (task.transfer and task.transfer.interval_ticks) or 30,
    next_transfer_tick = 0
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

      for _, turret in ipairs(site.turrets or {}) do
        if turret and turret.valid then
          valid_turrets[#valid_turrets + 1] = turret
        end
      end

      site.turrets = valid_turrets

      if site.assembler and site.assembler.valid and #site.turrets > 0 then
        if tick >= (site.next_transfer_tick or 0) then
          site.next_transfer_tick = tick + (site.transfer_interval_ticks or 30)

          local output_inventory = site.assembler.get_output_inventory and site.assembler.get_output_inventory()
          if output_inventory then
            table.sort(site.turrets, function(left, right)
              local left_inventory = left.get_inventory and left.get_inventory(defines.inventory.turret_ammo)
              local right_inventory = right.get_inventory and right.get_inventory(defines.inventory.turret_ammo)
              local left_count = left_inventory and left_inventory.get_item_count(site.ammo_item_name or "firearm-magazine") or 0
              local right_count = right_inventory and right_inventory.get_item_count(site.ammo_item_name or "firearm-magazine") or 0

              if left_count ~= right_count then
                return left_count < right_count
              end

              return ctx.square_distance(site.assembler.position, left.position) < ctx.square_distance(site.assembler.position, right.position)
            end)

            for _, turret in ipairs(site.turrets) do
              local ammo_inventory = turret.get_inventory and turret.get_inventory(defines.inventory.turret_ammo)
              if ammo_inventory then
                local desired_count = (site.turret_ammo_target_count or 20) - ammo_inventory.get_item_count(site.ammo_item_name or "firearm-magazine")
                if desired_count > 0 then
                  ctx.transfer_inventory_item(
                    output_inventory,
                    ammo_inventory,
                    site.ammo_item_name or "firearm-magazine",
                    math.min(desired_count, site.per_turret_transfer_limit or desired_count),
                    "production site " .. site.task_id .. ": moved ammo into " .. turret.name .. " at " .. ctx.format_position(turret.position)
                  )
                end
              end
            end
          end
        end

        kept_sites[#kept_sites + 1] = site
      end
    elseif site.site_type == "steel-smelting-chain" then
      if site.anchor_machine and site.anchor_machine.valid and
        site.feed_inserter and site.feed_inserter.valid and
        site.downstream_machine and site.downstream_machine.valid and
        site.miner and site.miner.valid
      then
        if tick >= (site.next_transfer_tick or 0) then
          site.next_transfer_tick = tick + (site.transfer_interval_ticks or 30)

          ctx.transfer_inventory_contents(
            site.anchor_machine.get_output_inventory and site.anchor_machine.get_output_inventory() or nil,
            site.downstream_machine,
            "production site " .. site.task_id .. ": transferred iron plates into " .. site.downstream_machine.name,
            site.input_item_names
          )
        end

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

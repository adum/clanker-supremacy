local entity_refs = require("scripts.world.entity_refs")
local production = require("scripts.world.production")
local storage_helpers = require("scripts.world.storage")

local sites = {}

local function get_site_pattern(pattern_name, ctx)
  return ctx.builder_data.site_patterns and ctx.builder_data.site_patterns[pattern_name] or nil
end

function sites.cleanup_resource_sites()
  local kept_sites = {}

  for _, site in ipairs(storage_helpers.ensure_resource_sites()) do
    if site.miner and site.miner.valid and
      ((not site.downstream_machine) or site.downstream_machine.valid) and
      ((not site.output_container) or site.output_container.valid) and
      ((not site.identity_entity) or site.identity_entity.valid) and
      ((not site.anchor_machine) or site.anchor_machine.valid) and
      ((not site.feed_inserter) or site.feed_inserter.valid)
    then
      kept_sites[#kept_sites + 1] = site
    end
  end

  storage.resource_sites = kept_sites
  return kept_sites
end

function sites.get_resource_site_counts()
  local counts = {}

  for _, site in ipairs(sites.cleanup_resource_sites()) do
    if site.pattern_name then
      counts[site.pattern_name] = (counts[site.pattern_name] or 0) + 1
    end
  end

  return counts
end

function sites.register_resource_site(task, miner, downstream_machine, output_container, extras, ctx)
  if not (task and task.pattern_name and miner and miner.valid) then
    return nil
  end

  extras = extras or {}
  local identity_entity = extras.identity_entity or downstream_machine or output_container or miner
  local resource_sites = sites.cleanup_resource_sites()
  for _, site in ipairs(resource_sites) do
    local site_identity_entity = site.identity_entity or site.downstream_machine or site.output_container or site.miner
    if site_identity_entity == identity_entity then
      site.pattern_name = task.pattern_name
      site.resource_name = task.resource_name
      site.downstream_machine = downstream_machine
      site.output_container = output_container
      site.identity_entity = identity_entity
      site.anchor_machine = extras.anchor_machine
      site.feed_inserter = extras.feed_inserter
      site.parent_pattern_name = extras.parent_pattern_name
      return site
    end
  end

  local site = {
    pattern_name = task.pattern_name,
    resource_name = task.resource_name,
    miner = miner,
    downstream_machine = downstream_machine,
    output_container = output_container,
    identity_entity = identity_entity,
    anchor_machine = extras.anchor_machine,
    feed_inserter = extras.feed_inserter,
    parent_pattern_name = extras.parent_pattern_name
  }
  resource_sites[#resource_sites + 1] = site

  local message =
    "registered resource site " .. task.pattern_name ..
    " with miner at " .. ctx.format_position(miner.position)

  if downstream_machine and downstream_machine.valid then
    message = message .. ", " .. downstream_machine.name .. " at " .. ctx.format_position(downstream_machine.position)
  end

  if output_container and output_container.valid then
    message = message .. ", " .. output_container.name .. " at " .. ctx.format_position(output_container.position)
  end

  if extras.anchor_machine and extras.anchor_machine.valid then
    message = message .. ", anchor " .. extras.anchor_machine.name .. " at " .. ctx.format_position(extras.anchor_machine.position)
  end

  if extras.feed_inserter and extras.feed_inserter.valid then
    message = message .. ", " .. extras.feed_inserter.name .. " at " .. ctx.format_position(extras.feed_inserter.position)
  end

  ctx.debug_log(message)
  return site
end

function sites.get_site_collect_inventory(site, ctx)
  if site.output_container and site.output_container.valid then
    return ctx.get_container_inventory(site.output_container)
  end

  local pattern = get_site_pattern(site.pattern_name, ctx)
  if not pattern or not pattern.collect then
    return nil
  end

  if pattern.collect.source == "output-container" then
    if site.output_container and site.output_container.valid then
      return ctx.get_container_inventory(site.output_container)
    end
    return nil
  end

  if pattern.collect.source == "downstream-machine-output" then
    if site.downstream_machine and site.downstream_machine.valid then
      return site.downstream_machine.get_output_inventory()
    end
    return nil
  end

  if pattern.collect.source == "miner-output" then
    if site.miner and site.miner.valid then
      return site.miner.get_output_inventory()
    end
    return nil
  end

  return nil
end

function sites.get_site_collect_position(site, ctx)
  if site.output_container and site.output_container.valid then
    return ctx.clone_position(site.output_container.position)
  end

  local pattern = get_site_pattern(site.pattern_name, ctx)
  if not pattern or not pattern.collect then
    return site.miner and site.miner.valid and ctx.clone_position(site.miner.position) or nil
  end

  if pattern.collect.source == "output-container" and site.output_container and site.output_container.valid then
    return ctx.clone_position(site.output_container.position)
  end

  if pattern.collect.source == "downstream-machine-output" and site.downstream_machine and site.downstream_machine.valid then
    return ctx.clone_position(site.downstream_machine.position)
  end

  if site.miner and site.miner.valid then
    return ctx.clone_position(site.miner.position)
  end

  return nil
end

function sites.get_site_allowed_items(site, ctx)
  local pattern = get_site_pattern(site.pattern_name, ctx)
  if not (pattern and pattern.collect and pattern.collect.item_names) then
    return nil
  end

  local allowed_item_names = {}
  for _, item_name in ipairs(pattern.collect.item_names) do
    allowed_item_names[item_name] = true
  end

  return allowed_item_names
end

function sites.get_site_collect_count(site, item_name, ctx)
  local inventory = sites.get_site_collect_inventory(site, ctx)
  if not inventory then
    return 0
  end

  if item_name then
    return inventory.get_item_count(item_name)
  end

  local total_count = 0
  for _, item_stack in pairs(inventory.get_contents()) do
    if type(item_stack) == "number" then
      total_count = total_count + item_stack
    elseif type(item_stack) == "table" then
      total_count = total_count + (item_stack.count or 0)
    end
  end

  return total_count
end

function sites.reconcile_production_sites_from_resource_sites(ctx)
  local production_sites = storage_helpers.ensure_production_sites()

  for _, resource_site in ipairs(sites.cleanup_resource_sites()) do
    local pattern = get_site_pattern(resource_site.pattern_name, ctx)
    local build_task = pattern and pattern.build_task or nil

    if build_task and resource_site.miner and resource_site.miner.valid and resource_site.downstream_machine and resource_site.downstream_machine.valid then
      local has_production_site = false

      for _, production_site in ipairs(production_sites) do
        if production_site.downstream_machine == resource_site.downstream_machine or
          (resource_site.anchor_machine and production_site.anchor_machine == resource_site.anchor_machine)
        then
          if production_site.output_container and production_site.output_container.valid then
            resource_site.output_container = production_site.output_container
          end
          has_production_site = true
          break
        end
      end

      if not has_production_site then
        if resource_site.anchor_machine and resource_site.anchor_machine.valid and
          resource_site.feed_inserter and resource_site.feed_inserter.valid
        then
          production.register_steel_smelting_site(
            build_task or {id = "reconcile-" .. tostring(resource_site.pattern_name or "steel_smelting")},
            resource_site.anchor_machine,
            resource_site.feed_inserter,
            resource_site.downstream_machine,
            resource_site.miner,
            ctx
          )
        elseif build_task.downstream_machine then
          production.register_smelting_site(build_task, resource_site.miner, resource_site.downstream_machine, resource_site.output_container, ctx)
        end
      end
    end
  end
end

function sites.discover_resource_sites(builder_state, ctx, options)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return
  end

  builder_state.resource_site_discovery = builder_state.resource_site_discovery or {
    next_tick = 0
  }

  local discovery_interval_ticks = (options and options.interval_ticks) or (10 * 60)
  local current_tick = (game and game.tick) or 0
  if not (options and options.force == true) and current_tick < (builder_state.resource_site_discovery.next_tick or 0) then
    return
  end

  builder_state.resource_site_discovery.next_tick = current_tick + discovery_interval_ticks

  local known_sites = sites.cleanup_resource_sites()
  local known_miners = {}

  for _, site in ipairs(known_sites) do
    if site.miner and site.miner.valid then
      known_miners[site.miner.unit_number or (site.miner.position.x .. ":" .. site.miner.position.y)] = true
    end
  end

  local builder = builder_state.entity
  local surface = builder.surface
  local miners = surface.find_entities_filtered{
    force = builder.force,
    name = "burner-mining-drill"
  }

  local discovered_count = 0

  for _, miner in ipairs(miners) do
    if miner.valid then
      local miner_key = miner.unit_number or (miner.position.x .. ":" .. miner.position.y)
      if not known_miners[miner_key] then
        for pattern_name, pattern in pairs(ctx.builder_data.site_patterns or {}) do
          local build_task = pattern.build_task
          if build_task and build_task.miner_name == miner.name then
            local resources = surface.find_entities_filtered{
              area = miner.mining_area,
              type = "resource",
              name = build_task.resource_name
            }

            if #resources > 0 then
              local downstream_machine = nil
              local output_container = nil
              local site_valid = true

              if build_task.downstream_machine then
                downstream_machine = entity_refs.find_entity_covering_position(
                  surface,
                  builder.force,
                  build_task.downstream_machine.name,
                  miner.drop_position,
                  3,
                  ctx
                )
                site_valid = downstream_machine ~= nil
              end

              if site_valid and build_task.output_container then
                output_container = entity_refs.find_entity_at_position(
                  surface,
                  builder.force,
                  build_task.output_container.name,
                  miner.drop_position,
                  0.6
                )
                site_valid = output_container ~= nil
              end

              if site_valid then
                sites.register_resource_site(
                  {
                    pattern_name = pattern_name,
                    resource_name = build_task.resource_name
                  },
                  miner,
                  downstream_machine,
                  output_container,
                  nil,
                  ctx
                )
                if build_task.downstream_machine and downstream_machine then
                  production.register_smelting_site(build_task, miner, downstream_machine, output_container, ctx)
                end
                known_miners[miner_key] = true
                discovered_count = discovered_count + 1
                break
              end
            end
          end
        end
      end
    end
  end

  if discovered_count > 0 then
    ctx.debug_log("discovered " .. discovered_count .. " existing resource site(s)")
  end

  sites.reconcile_production_sites_from_resource_sites(ctx)
end

function sites.get_site_pattern(pattern_name, ctx)
  return get_site_pattern(pattern_name, ctx)
end

return sites

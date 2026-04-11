local world_model = {}

local function ensure_production_sites()
  if storage.production_sites == nil then
    storage.production_sites = {}
  end

  return storage.production_sites
end

local function ensure_resource_sites()
  if storage.resource_sites == nil then
    storage.resource_sites = {}
  end

  return storage.resource_sites
end

local function get_site_pattern(pattern_name, ctx)
  return ctx.builder_data.site_patterns and ctx.builder_data.site_patterns[pattern_name] or nil
end

local function entity_overlaps_resources(entity)
  if not (entity and entity.valid) then
    return false
  end

  return #entity.surface.find_entities_filtered{
    area = entity.selection_box,
    type = "resource",
    limit = 1
  } > 0
end

local function find_nearby_output_container_position(surface, anchor_entity, container_config)
  local area = anchor_entity.selection_box
  local candidate_positions = {}
  local seen_positions = {}

  local function add_candidate(position)
    local key = string.format("%.2f:%.2f", position.x, position.y)
    if not seen_positions[key] then
      seen_positions[key] = true
      candidate_positions[#candidate_positions + 1] = position
    end
  end

  for x = math.floor(area.left_top.x) + 0.5, math.ceil(area.right_bottom.x) - 0.5, 1 do
    add_candidate({x = x, y = area.left_top.y - 0.5})
  end

  for y = math.floor(area.left_top.y) + 0.5, math.ceil(area.right_bottom.y) - 0.5, 1 do
    add_candidate({x = area.right_bottom.x + 0.5, y = y})
  end

  for y = math.floor(area.left_top.y) + 0.5, math.ceil(area.right_bottom.y) - 0.5, 1 do
    add_candidate({x = area.left_top.x - 0.5, y = y})
  end

  for x = math.floor(area.left_top.x) + 0.5, math.ceil(area.right_bottom.x) - 0.5, 1 do
    add_candidate({x = x, y = area.right_bottom.y + 0.5})
  end

  for _, position in ipairs(candidate_positions) do
    if surface.can_place_entity{
      name = container_config.name,
      position = position,
      force = anchor_entity.force
    } then
      return position
    end
  end

  return nil
end

local function find_downstream_machine_placement(surface, force, task, drop_position, ctx)
  local downstream_machine = task.downstream_machine
  local stats = {
    positions_checked = 0,
    placeable_positions = 0,
    test_machines_created = 0,
    anchor_cover_hits = 0,
    output_container_hits = 0
  }

  for _, position in ipairs(ctx.build_search_positions(
    drop_position,
    downstream_machine.placement_search_radius or 2,
    downstream_machine.placement_step or 0.5
  )) do
    stats.positions_checked = stats.positions_checked + 1

    if surface.can_place_entity{
      name = downstream_machine.name,
      position = position,
      force = force
    } then
      stats.placeable_positions = stats.placeable_positions + 1
      local test_machine = surface.create_entity{
        name = downstream_machine.name,
        position = position,
        force = force,
        create_build_effect_smoke = false,
        raise_built = false
      }

      if test_machine then
        stats.test_machines_created = stats.test_machines_created + 1
        local covers_drop_position = not downstream_machine.cover_drop_position or ctx.point_in_area(drop_position, test_machine.selection_box)
        local output_container_position = nil

        if covers_drop_position then
          stats.anchor_cover_hits = stats.anchor_cover_hits + 1

          if task.output_container then
            output_container_position = find_nearby_output_container_position(surface, test_machine, task.output_container)
            if output_container_position then
              stats.output_container_hits = stats.output_container_hits + 1
            end
          end
        end

        test_machine.destroy()

        if covers_drop_position and (not task.output_container or output_container_position) then
          return ctx.clone_position(position), output_container_position and ctx.clone_position(output_container_position) or nil, stats
        end
      end
    end
  end

  return nil, nil, stats
end

local function count_registered_sites_near_position(requirement, position)
  if not (requirement and requirement.site_type and position) then
    return 0
  end

  local count = 0
  local radius = requirement.radius or 24
  local radius_squared = radius * radius
  local entity_field = requirement.entity_field or "assembler"

  for _, site in ipairs(ensure_production_sites()) do
    local entity = site[entity_field]
    if site.site_type == requirement.site_type and entity and entity.valid then
      local dx = position.x - entity.position.x
      local dy = position.y - entity.position.y
      if (dx * dx) + (dy * dy) <= radius_squared then
        count = count + 1
      end
    end
  end

  return count
end

local function anchor_has_registered_site(anchor_entity, requirement)
  if not (anchor_entity and anchor_entity.valid and requirement and requirement.site_type) then
    return false
  end

  local entity_field = requirement.entity_field or "assembler"

  for _, site in ipairs(ensure_production_sites()) do
    if site.site_type == requirement.site_type and site[entity_field] == anchor_entity then
      return true
    end
  end

  return false
end

local function find_entity_placement_near_anchor(surface, force, entity_name, anchor_position, search_radius, step, directions, placement_validator, ctx)
  local stats = {
    positions_checked = 0,
    placeable_positions = 0
  }

  for _, position in ipairs(ctx.build_search_positions(anchor_position, search_radius, step)) do
    if directions and #directions > 0 then
      for _, direction in ipairs(directions) do
        stats.positions_checked = stats.positions_checked + 1

        if surface.can_place_entity{
          name = entity_name,
          position = position,
          direction = direction,
          force = force
        } then
          stats.placeable_positions = stats.placeable_positions + 1
          if not placement_validator or placement_validator(position, direction) then
            return ctx.clone_position(position), direction, stats
          end
        end
      end
    else
      stats.positions_checked = stats.positions_checked + 1
      if surface.can_place_entity{
        name = entity_name,
        position = position,
        force = force
      } then
        stats.placeable_positions = stats.placeable_positions + 1
        if not placement_validator or placement_validator(position, nil) then
          return ctx.clone_position(position), nil, stats
        end
      end
    end
  end

  return nil, nil, stats
end

local function layout_fits_around_anchor_entity(builder, anchor_entity, layout_config, summary, ctx)
  if not layout_config then
    return true
  end

  if layout_config.forbid_resource_overlap and entity_overlaps_resources(anchor_entity) then
    if summary then
      summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
    end
    return false
  end

  for _, orientation in ipairs(layout_config.layout_orientations or {"north"}) do
    local probe_entities = {}
    local layout_valid = true

    for _, element in ipairs(layout_config.layout_elements or {}) do
      local rotated_offset = ctx.rotate_offset(element.offset, orientation)
      local desired_position = {
        x = anchor_entity.position.x + rotated_offset.x,
        y = anchor_entity.position.y + rotated_offset.y
      }
      local direction_name = ctx.rotate_direction_name(element.direction_name, orientation)
      local build_position, build_direction = find_entity_placement_near_anchor(
        builder.surface,
        builder.force,
        element.entity_name,
        desired_position,
        element.placement_search_radius or 0,
        element.placement_step or 0.5,
        direction_name and {ctx.direction_by_name[direction_name]} or nil,
        nil,
        ctx
      )

      if not build_position then
        layout_valid = false
        break
      end

      local probe_entity = builder.surface.create_entity{
        name = element.entity_name,
        position = build_position,
        direction = build_direction,
        force = builder.force,
        create_build_effect_smoke = false,
        raise_built = false
      }

      if not probe_entity then
        layout_valid = false
        break
      end

      probe_entities[#probe_entities + 1] = probe_entity

      if layout_config.forbid_resource_overlap and entity_overlaps_resources(probe_entity) then
        if summary then
          summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
        end
        layout_valid = false
        break
      end
    end

    for _, probe_entity in ipairs(probe_entities) do
      if probe_entity and probe_entity.valid then
        probe_entity.destroy()
      end
    end

    if layout_valid then
      return true
    end
  end

  return false
end

local function machine_site_candidate_is_valid(builder, task, position, direction, summary, ctx)
  local probe_entity = builder.surface.create_entity{
    name = task.entity_name,
    position = position,
    direction = direction,
    force = builder.force,
    create_build_effect_smoke = false,
    raise_built = false
  }

  if not probe_entity then
    return false
  end

  local valid = true

  if task.forbid_resource_overlap and entity_overlaps_resources(probe_entity) then
    summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
    valid = false
  end

  if valid and task.layout_reservation and not layout_fits_around_anchor_entity(builder, probe_entity, task.layout_reservation, summary, ctx) then
    summary.layout_reservation_rejections = (summary.layout_reservation_rejections or 0) + 1
    valid = false
  end

  probe_entity.destroy()
  return valid
end

local function site_matches_patterns(site, pattern_names)
  if not pattern_names or #pattern_names == 0 then
    return true
  end

  for _, pattern_name in ipairs(pattern_names) do
    if site.pattern_name == pattern_name then
      return true
    end
  end

  return false
end

local function get_anchor_site_position(site, anchor_position_source, ctx)
  if anchor_position_source == "downstream-machine" and site.downstream_machine and site.downstream_machine.valid then
    return ctx.clone_position(site.downstream_machine.position)
  end

  if anchor_position_source == "output-container" and site.output_container and site.output_container.valid then
    return ctx.clone_position(site.output_container.position)
  end

  if site.miner and site.miner.valid then
    return ctx.clone_position(site.miner.position)
  end

  return nil
end

local function get_anchor_site_entity(site, anchor_position_source)
  if anchor_position_source == "downstream-machine" and site.downstream_machine and site.downstream_machine.valid then
    return site.downstream_machine
  end

  if anchor_position_source == "output-container" and site.output_container and site.output_container.valid then
    return site.output_container
  end

  if site.miner and site.miner.valid then
    return site.miner
  end

  return nil
end

local function destroy_entities(entities)
  for _, entity in ipairs(entities or {}) do
    if entity and entity.valid then
      entity.destroy()
    end
  end
end

local function cleanup_resource_sites()
  local kept_sites = {}

  for _, site in ipairs(ensure_resource_sites()) do
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

local function get_resource_site_counts()
  local counts = {}

  for _, site in ipairs(cleanup_resource_sites()) do
    if site.pattern_name then
      counts[site.pattern_name] = (counts[site.pattern_name] or 0) + 1
    end
  end

  return counts
end

local function register_smelting_site(task, miner, downstream_machine, output_container, ctx)
  local production_sites = ensure_production_sites()
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

local function register_steel_smelting_site(task, anchor_machine, feed_inserter, downstream_machine, miner, ctx)
  if not (task and anchor_machine and anchor_machine.valid and feed_inserter and feed_inserter.valid and downstream_machine and downstream_machine.valid) then
    return nil
  end

  local production_sites = ensure_production_sites()
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

local function register_assembler_defense_site(task, assembler, placed_layout_entities, ctx)
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

  local production_sites = ensure_production_sites()
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

local function get_site_collect_inventory(site, ctx)
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

local function get_site_collect_position(site, ctx)
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

local function get_site_allowed_items(site, ctx)
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

local function get_site_collect_count(site, item_name, ctx)
  local inventory = get_site_collect_inventory(site, ctx)
  if not inventory then
    return 0
  end

  if item_name then
    return inventory.get_item_count(item_name)
  end

  local total_count = 0
  for _, item_stack in pairs(inventory.get_contents()) do
    total_count = total_count + (item_stack.count or 0)
  end

  return total_count
end

local function register_resource_site(task, miner, downstream_machine, output_container, extras, ctx)
  if not (task and task.pattern_name and miner and miner.valid) then
    return nil
  end

  extras = extras or {}
  local identity_entity = extras.identity_entity or downstream_machine or output_container or miner
  local sites = cleanup_resource_sites()
  for _, site in ipairs(sites) do
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
  sites[#sites + 1] = site

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

local function reconcile_production_sites_from_resource_sites(ctx)
  local production_sites = ensure_production_sites()

  for _, resource_site in ipairs(cleanup_resource_sites()) do
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
          register_steel_smelting_site(
            build_task or {id = "reconcile-" .. tostring(resource_site.pattern_name or "steel_smelting")},
            resource_site.anchor_machine,
            resource_site.feed_inserter,
            resource_site.downstream_machine,
            resource_site.miner,
            ctx
          )
        elseif build_task.downstream_machine then
          register_smelting_site(build_task, resource_site.miner, resource_site.downstream_machine, resource_site.output_container, ctx)
        end
      end
    end
  end
end

local function find_entity_covering_position(surface, force, entity_name, position, radius, ctx)
  local entities = surface.find_entities_filtered{
    position = position,
    radius = radius or 3,
    name = entity_name,
    force = force
  }

  for _, entity in ipairs(entities) do
    if entity.valid and ctx.point_in_area(position, entity.selection_box) then
      return entity
    end
  end

  return nil
end

local function find_entity_at_position(surface, force, entity_name, position, radius)
  return surface.find_entities_filtered{
    position = position,
    radius = radius or 0.1,
    name = entity_name,
    force = force
  }[1]
end

local function discover_resource_sites(builder_state, ctx)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return
  end

  local known_sites = cleanup_resource_sites()
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
                downstream_machine = find_entity_covering_position(
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
                output_container = find_entity_at_position(
                  surface,
                  builder.force,
                  build_task.output_container.name,
                  miner.drop_position,
                  0.6
                )
                site_valid = output_container ~= nil
              end

              if site_valid then
                register_resource_site(
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
                  register_smelting_site(build_task, miner, downstream_machine, output_container, ctx)
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

  reconcile_production_sites_from_resource_sites(ctx)
end

local function get_resource_position_key(resource)
  return string.format("%.2f:%.2f", resource.position.x, resource.position.y)
end

local function build_resource_patches(resources, origin, ctx)
  local resources_by_key = {}
  local visited = {}
  local patches = {}

  for _, resource in ipairs(resources) do
    resources_by_key[get_resource_position_key(resource)] = resource
  end

  for _, resource in ipairs(resources) do
    local resource_key = get_resource_position_key(resource)
    if not visited[resource_key] then
      local queue = {resource}
      local queue_index = 1
      local patch_resources = {}
      local sum_x = 0
      local sum_y = 0
      local nearest_distance = nil

      visited[resource_key] = true

      while queue_index <= #queue do
        local current_resource = queue[queue_index]
        queue_index = queue_index + 1

        patch_resources[#patch_resources + 1] = current_resource
        sum_x = sum_x + current_resource.position.x
        sum_y = sum_y + current_resource.position.y

        local current_distance = ctx.square_distance(origin, current_resource.position)
        if not nearest_distance or current_distance < nearest_distance then
          nearest_distance = current_distance
        end

        for dx = -1, 1 do
          for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
              local neighbor_key = string.format(
                "%.2f:%.2f",
                current_resource.position.x + dx,
                current_resource.position.y + dy
              )
              local neighbor_resource = resources_by_key[neighbor_key]
              if neighbor_resource and not visited[neighbor_key] then
                visited[neighbor_key] = true
                queue[#queue + 1] = neighbor_resource
              end
            end
          end
        end
      end

      patches[#patches + 1] = {
        anchor_position = {
          x = sum_x / #patch_resources,
          y = sum_y / #patch_resources
        },
        size = #patch_resources,
        nearest_distance = nearest_distance,
        representative_resource = patch_resources[1]
      }
    end
  end

  table.sort(patches, function(left, right)
    if left.nearest_distance ~= right.nearest_distance then
      return left.nearest_distance < right.nearest_distance
    end

    return left.size > right.size
  end)

  return patches
end

local function find_miner_placement(surface, force, task, resource_position, ctx)
  local stats = {
    positions_checked = 0,
    placeable_positions = 0,
    test_miners_created = 0,
    mining_area_hits = 0,
    valid_candidates = 0,
    best_resource_coverage = 0,
    selected_candidate_pool_size = 0,
    output_container_hits = 0,
    downstream_positions_checked = 0,
    downstream_placeable_positions = 0,
    test_downstream_created = 0,
    downstream_anchor_hits = 0
  }
  local valid_candidates = {}

  for _, position in ipairs(ctx.build_search_positions(resource_position, task.placement_search_radius, task.placement_step)) do
    for _, direction_name in ipairs(task.placement_directions) do
      local direction = ctx.direction_by_name[direction_name]
      stats.positions_checked = stats.positions_checked + 1

      if surface.can_place_entity{
        name = task.miner_name,
        position = position,
        direction = direction,
        force = force
      } then
        stats.placeable_positions = stats.placeable_positions + 1
        local test_miner = surface.create_entity{
          name = task.miner_name,
          position = position,
          direction = direction,
          force = force,
          create_build_effect_smoke = false,
          raise_built = false
        }

        if test_miner then
          stats.test_miners_created = stats.test_miners_created + 1
          local covered_resources = surface.find_entities_filtered{
            area = test_miner.mining_area,
            type = "resource",
            name = task.resource_name
          }
          local resource_coverage = #covered_resources
          local mines_resource = resource_coverage > 0
          local downstream_machine_position = nil
          local output_container_position = nil
          local has_output_container_spot = true

          if mines_resource then
            stats.mining_area_hits = stats.mining_area_hits + 1
            if resource_coverage > stats.best_resource_coverage then
              stats.best_resource_coverage = resource_coverage
            end

            if task.downstream_machine then
              local downstream_stats
              downstream_machine_position, output_container_position, downstream_stats =
                find_downstream_machine_placement(surface, force, task, test_miner.drop_position, ctx)
              stats.downstream_positions_checked = stats.downstream_positions_checked + downstream_stats.positions_checked
              stats.downstream_placeable_positions = stats.downstream_placeable_positions + downstream_stats.placeable_positions
              stats.test_downstream_created = stats.test_downstream_created + downstream_stats.test_machines_created
              stats.downstream_anchor_hits = stats.downstream_anchor_hits + downstream_stats.anchor_cover_hits
              stats.output_container_hits = stats.output_container_hits + downstream_stats.output_container_hits
              has_output_container_spot = downstream_machine_position ~= nil and (not task.output_container or output_container_position ~= nil)
            elseif task.output_container then
              output_container_position = ctx.clone_position(test_miner.drop_position)
              has_output_container_spot = surface.can_place_entity{
                name = task.output_container.name,
                position = output_container_position,
                force = force
              }

              if has_output_container_spot then
                stats.output_container_hits = stats.output_container_hits + 1
              end
            end
          end

          test_miner.destroy()

          if mines_resource and has_output_container_spot then
            stats.valid_candidates = stats.valid_candidates + 1
            valid_candidates[#valid_candidates + 1] = {
              build_position = {
                x = position.x,
                y = position.y
              },
              build_direction = direction,
              output_container_position = output_container_position and ctx.clone_position(output_container_position) or nil,
              downstream_machine_position = downstream_machine_position and ctx.clone_position(downstream_machine_position) or nil,
              resource_coverage = resource_coverage,
              search_weight = position.weight,
              direction_name = direction_name
            }
          end
        end
      end
    end
  end

  local site_selection = task.site_selection or {}
  local selected_candidate, pool_size = ctx.select_preferred_candidate(
    valid_candidates,
    site_selection.random_candidate_pool or 1,
    function(left, right)
      if site_selection.prefer_middle ~= false and left.resource_coverage ~= right.resource_coverage then
        return left.resource_coverage > right.resource_coverage
      end

      if left.search_weight ~= right.search_weight then
        return left.search_weight < right.search_weight
      end

      return left.direction_name < right.direction_name
    end,
    function(candidate, best_candidate)
      if site_selection.prefer_middle == false then
        return true
      end

      return candidate.resource_coverage >= best_candidate.resource_coverage
    end
  )

  if selected_candidate then
    stats.selected_candidate_pool_size = pool_size
    return selected_candidate.build_position,
      selected_candidate.build_direction,
      selected_candidate.output_container_position,
      selected_candidate.downstream_machine_position,
      stats
  end

  return nil, nil, nil, nil, stats
end

local function find_resource_site(surface, force, origin, task, ctx)
  local seen_resources = {}
  local summary = {
    radii_checked = 0,
    resources_considered = 0,
    patch_centers_considered = 0,
    positions_checked = 0,
    placeable_positions = 0,
    test_miners_created = 0,
    mining_area_hits = 0,
    valid_candidates = 0,
    best_resource_coverage = 0,
    selected_candidate_pool_size = 0,
    output_container_hits = 0,
    downstream_positions_checked = 0,
    downstream_placeable_positions = 0,
    test_downstream_created = 0,
    downstream_anchor_hits = 0
  }

  for _, radius in ipairs(task.search_radii) do
    summary.radii_checked = summary.radii_checked + 1

    local resources = surface.find_entities_filtered{
      position = origin,
      radius = radius,
      type = "resource",
      name = task.resource_name
    }

    table.sort(resources, function(left, right)
      return ctx.square_distance(origin, left.position) < ctx.square_distance(origin, right.position)
    end)

    local site_selection = task.site_selection or {}
    if site_selection.prefer_middle ~= false and #resources > 0 then
      local patches = build_resource_patches(resources, origin, ctx)

      for _, patch in ipairs(patches) do
        summary.patch_centers_considered = summary.patch_centers_considered + 1

        local build_position, build_direction, output_container_position, downstream_machine_position, placement_stats =
          find_miner_placement(surface, force, task, patch.anchor_position, ctx)

        summary.positions_checked = summary.positions_checked + placement_stats.positions_checked
        summary.placeable_positions = summary.placeable_positions + placement_stats.placeable_positions
        summary.test_miners_created = summary.test_miners_created + placement_stats.test_miners_created
        summary.mining_area_hits = summary.mining_area_hits + placement_stats.mining_area_hits
        summary.valid_candidates = summary.valid_candidates + placement_stats.valid_candidates
        if placement_stats.best_resource_coverage > summary.best_resource_coverage then
          summary.best_resource_coverage = placement_stats.best_resource_coverage
        end
        summary.output_container_hits = summary.output_container_hits + placement_stats.output_container_hits
        summary.downstream_positions_checked = summary.downstream_positions_checked + placement_stats.downstream_positions_checked
        summary.downstream_placeable_positions = summary.downstream_placeable_positions + placement_stats.downstream_placeable_positions
        summary.test_downstream_created = summary.test_downstream_created + placement_stats.test_downstream_created
        summary.downstream_anchor_hits = summary.downstream_anchor_hits + placement_stats.downstream_anchor_hits

        if build_position then
          summary.selected_candidate_pool_size = placement_stats.selected_candidate_pool_size
          return {
            resource = patch.representative_resource,
            anchor_position = ctx.clone_position(patch.anchor_position),
            build_position = build_position,
            build_direction = build_direction,
            output_container_position = output_container_position,
            downstream_machine_position = downstream_machine_position,
            resource_coverage = placement_stats.best_resource_coverage,
            selected_from_patch_center = true,
            summary = summary
          }
        end
      end
    end

    local considered_this_radius = 0
    local site_candidates = {}

    for _, resource in ipairs(resources) do
      local resource_key = get_resource_position_key(resource)
      if not seen_resources[resource_key] then
        seen_resources[resource_key] = true
        considered_this_radius = considered_this_radius + 1
        summary.resources_considered = summary.resources_considered + 1

        local build_position, build_direction, output_container_position, downstream_machine_position, placement_stats =
          find_miner_placement(surface, force, task, resource.position, ctx)
        summary.positions_checked = summary.positions_checked + placement_stats.positions_checked
        summary.placeable_positions = summary.placeable_positions + placement_stats.placeable_positions
        summary.test_miners_created = summary.test_miners_created + placement_stats.test_miners_created
        summary.mining_area_hits = summary.mining_area_hits + placement_stats.mining_area_hits
        summary.valid_candidates = summary.valid_candidates + placement_stats.valid_candidates
        if placement_stats.best_resource_coverage > summary.best_resource_coverage then
          summary.best_resource_coverage = placement_stats.best_resource_coverage
        end
        summary.output_container_hits = summary.output_container_hits + placement_stats.output_container_hits
        summary.downstream_positions_checked = summary.downstream_positions_checked + placement_stats.downstream_positions_checked
        summary.downstream_placeable_positions = summary.downstream_placeable_positions + placement_stats.downstream_placeable_positions
        summary.test_downstream_created = summary.test_downstream_created + placement_stats.test_downstream_created
        summary.downstream_anchor_hits = summary.downstream_anchor_hits + placement_stats.downstream_anchor_hits

        if build_position then
          site_candidates[#site_candidates + 1] = {
            resource = resource,
            build_position = build_position,
            build_direction = build_direction,
            output_container_position = output_container_position,
            downstream_machine_position = downstream_machine_position,
            resource_coverage = placement_stats.best_resource_coverage,
            resource_distance = ctx.square_distance(origin, build_position)
          }
        end

        if task.max_resource_candidates_per_radius and considered_this_radius >= task.max_resource_candidates_per_radius then
          break
        end
      end
    end

    local selected_candidate, pool_size = ctx.select_preferred_candidate(
      site_candidates,
      site_selection.random_candidate_pool or 1,
      function(left, right)
        if site_selection.prefer_middle ~= false and left.resource_coverage ~= right.resource_coverage then
          return left.resource_coverage > right.resource_coverage
        end

        if left.resource_distance ~= right.resource_distance then
          return left.resource_distance < right.resource_distance
        end

        return ctx.square_distance(origin, left.resource.position) < ctx.square_distance(origin, right.resource.position)
      end,
      function(candidate, best_candidate)
        if site_selection.prefer_middle == false then
          return true
        end

        return candidate.resource_coverage >= best_candidate.resource_coverage
      end
    )

    if selected_candidate then
      summary.selected_candidate_pool_size = pool_size
      selected_candidate.summary = summary
      return selected_candidate
    end
  end

  return nil, summary
end

local function find_nearest_resource(surface, origin, task, ctx)
  local seen_resources = {}

  for _, radius in ipairs(task.search_radii) do
    local resources = surface.find_entities_filtered{
      position = origin,
      radius = radius,
      type = "resource",
      name = task.resource_name
    }

    table.sort(resources, function(left, right)
      return ctx.square_distance(origin, left.position) < ctx.square_distance(origin, right.position)
    end)

    for _, resource in ipairs(resources) do
      local resource_key = get_resource_position_key(resource)
      if not seen_resources[resource_key] then
        seen_resources[resource_key] = true
        return resource
      end
    end
  end

  return nil
end

local function find_machine_site_near_resource_sites(builder_state, task, ctx)
  discover_resource_sites(builder_state, ctx)

  local builder = builder_state.entity
  local origin = task.manual_search_origin or builder.position
  local anchor_candidates = {}
  local anchor_preference = task.anchor_preference and task.anchor_preference.fewer_registered_sites or nil

  for _, site in ipairs(cleanup_resource_sites()) do
    if site_matches_patterns(site, task.anchor_pattern_names) then
      local anchor_position = get_anchor_site_position(site, task.anchor_position_source, ctx)
      if anchor_position then
        anchor_candidates[#anchor_candidates + 1] = {
          site = site,
          anchor_position = anchor_position,
          distance = ctx.square_distance(origin, anchor_position),
          nearby_registered_site_count = count_registered_sites_near_position(anchor_preference, anchor_position)
        }
      end
    end
  end

  table.sort(anchor_candidates, function(left, right)
    if left.nearby_registered_site_count ~= right.nearby_registered_site_count then
      return left.nearby_registered_site_count < right.nearby_registered_site_count
    end

    return left.distance < right.distance
  end)

  local summary = {
    anchor_sites_considered = 0,
    positions_checked = 0,
    placeable_positions = 0,
    resource_overlap_rejections = 0,
    layout_reservation_rejections = 0
  }

  local max_anchor_sites = task.max_anchor_sites or #anchor_candidates

  for _, anchor_candidate in ipairs(anchor_candidates) do
    if summary.anchor_sites_considered >= max_anchor_sites then
      break
    end

    summary.anchor_sites_considered = summary.anchor_sites_considered + 1
    local build_position, build_direction, placement_stats = find_entity_placement_near_anchor(
      builder.surface,
      builder.force,
      task.entity_name,
      anchor_candidate.anchor_position,
      task.placement_search_radius,
      task.placement_step,
      task.placement_directions,
      (task.forbid_resource_overlap or task.layout_reservation) and function(position, direction)
        return machine_site_candidate_is_valid(builder, task, position, direction, summary, ctx)
      end or nil,
      ctx
    )

    summary.positions_checked = summary.positions_checked + placement_stats.positions_checked
    summary.placeable_positions = summary.placeable_positions + placement_stats.placeable_positions

    if build_position then
      return {
        site = anchor_candidate.site,
        anchor_position = anchor_candidate.anchor_position,
        build_position = build_position,
        build_direction = build_direction,
        summary = summary
      }
    end
  end

  return nil, summary
end

local function find_layout_site_near_machine(builder_state, task, ctx)
  local builder = builder_state.entity
  local anchor_origin = task.manual_anchor_position or builder.position
  local summary = {
    anchor_entities_considered = 0,
    anchors_skipped_registered = 0,
    orientations_considered = 0,
    layout_elements_checked = 0,
    positions_checked = 0,
    placeable_positions = 0,
    resource_overlap_rejections = 0
  }

  local anchor_candidates = {}

  if task.anchor_pattern_names and #task.anchor_pattern_names > 0 then
    discover_resource_sites(builder_state, ctx)

    for _, site in ipairs(cleanup_resource_sites()) do
      if site_matches_patterns(site, task.anchor_pattern_names) then
        local anchor_entity = get_anchor_site_entity(site, task.anchor_position_source)
        if anchor_entity then
          local distance = ctx.square_distance(anchor_origin, anchor_entity.position)
          local anchor_search_radius = task.manual_anchor_search_radius or task.anchor_search_radius
          if (not anchor_search_radius) or distance <= (anchor_search_radius * anchor_search_radius) then
            anchor_candidates[#anchor_candidates + 1] = {
              site = site,
              anchor_entity = anchor_entity,
              distance = distance
            }
          end
        end
      end
    end
  else
    local anchor_entity_names = ctx.get_task_anchor_entity_names(task)
    if not anchor_entity_names then
      return nil, summary
    end

    local filter = {
      force = builder.force,
      name = anchor_entity_names
    }

    if task.anchor_search_radius then
      filter.position = anchor_origin
      filter.radius = task.manual_anchor_search_radius or task.anchor_search_radius
    end

    for _, anchor_entity in ipairs(builder.surface.find_entities_filtered(filter)) do
      anchor_candidates[#anchor_candidates + 1] = {
        site = nil,
        anchor_entity = anchor_entity,
        distance = ctx.square_distance(anchor_origin, anchor_entity.position)
      }
    end
  end

  table.sort(anchor_candidates, function(left, right)
    return left.distance < right.distance
  end)

  local max_anchor_entities = task.max_anchor_entities or #anchor_candidates

  for _, anchor_candidate in ipairs(anchor_candidates) do
    if summary.anchor_entities_considered >= max_anchor_entities then
      break
    end

    local anchor_entity = anchor_candidate.anchor_entity
    if anchor_entity.valid then
      if anchor_has_registered_site(anchor_entity, task.require_missing_registered_site) then
        summary.anchors_skipped_registered = summary.anchors_skipped_registered + 1
      else
        summary.anchor_entities_considered = summary.anchor_entities_considered + 1

        if task.forbid_resource_overlap and entity_overlaps_resources(anchor_entity) then
          summary.resource_overlap_rejections = summary.resource_overlap_rejections + 1
        else
          for _, orientation in ipairs(task.layout_orientations or {"north"}) do
            summary.orientations_considered = summary.orientations_considered + 1

            local placements = {}
            local probe_entities = {}
            local layout_valid = true

            for _, element in ipairs(task.layout_elements or {}) do
              summary.layout_elements_checked = summary.layout_elements_checked + 1

              local rotated_offset = ctx.rotate_offset(element.offset, orientation)
              local desired_position = {
                x = anchor_entity.position.x + rotated_offset.x,
                y = anchor_entity.position.y + rotated_offset.y
              }
              local direction_name = ctx.rotate_direction_name(element.direction_name, orientation)
              local build_position, build_direction, placement_stats = find_entity_placement_near_anchor(
                builder.surface,
                builder.force,
                element.entity_name,
                desired_position,
                element.placement_search_radius or 0,
                element.placement_step or 0.5,
                direction_name and {ctx.direction_by_name[direction_name]} or nil,
                nil,
                ctx
              )

              summary.positions_checked = summary.positions_checked + placement_stats.positions_checked
              summary.placeable_positions = summary.placeable_positions + placement_stats.placeable_positions

              if not build_position then
                layout_valid = false
                break
              end

              local probe_entity = builder.surface.create_entity{
                name = element.entity_name,
                position = build_position,
                direction = build_direction,
                force = builder.force,
                create_build_effect_smoke = false,
                raise_built = false
              }

              if not probe_entity then
                layout_valid = false
                break
              end

              if task.forbid_resource_overlap and entity_overlaps_resources(probe_entity) then
                summary.resource_overlap_rejections = summary.resource_overlap_rejections + 1
                probe_entities[#probe_entities + 1] = probe_entity
                layout_valid = false
                break
              end

              probe_entities[#probe_entities + 1] = probe_entity
              placements[#placements + 1] = {
                id = element.id or ("layout-" .. tostring(#placements + 1)),
                site_role = element.site_role,
                entity_name = element.entity_name,
                item_name = element.item_name or element.entity_name,
                build_position = ctx.clone_position(build_position),
                build_direction = build_direction,
                fuel = element.fuel
              }
            end

            destroy_entities(probe_entities)

            if layout_valid then
              return {
                site = anchor_candidate.site,
                anchor_entity = anchor_entity,
                anchor_position = ctx.clone_position(anchor_entity.position),
                build_position = ctx.clone_position(anchor_entity.position),
                orientation = orientation,
                placements = placements,
                summary = summary
              }, summary
            end
          end
        end
      end
    end
  end

  return nil, summary
end

function world_model.ensure_production_sites(_ctx)
  return ensure_production_sites()
end

function world_model.ensure_resource_sites(_ctx)
  return ensure_resource_sites()
end

function world_model.get_site_pattern(pattern_name, ctx)
  return get_site_pattern(pattern_name, ctx)
end

function world_model.find_machine_site_near_resource_sites(builder_state, task, ctx)
  return find_machine_site_near_resource_sites(builder_state, task, ctx)
end

function world_model.find_layout_site_near_machine(builder_state, task, ctx)
  return find_layout_site_near_machine(builder_state, task, ctx)
end

function world_model.register_smelting_site(task, miner, downstream_machine, output_container, ctx)
  return register_smelting_site(task, miner, downstream_machine, output_container, ctx)
end

function world_model.register_steel_smelting_site(task, anchor_machine, feed_inserter, downstream_machine, miner, ctx)
  return register_steel_smelting_site(task, anchor_machine, feed_inserter, downstream_machine, miner, ctx)
end

function world_model.register_assembler_defense_site(task, assembler, placed_layout_entities, ctx)
  return register_assembler_defense_site(task, assembler, placed_layout_entities, ctx)
end

function world_model.get_site_collect_inventory(site, ctx)
  return get_site_collect_inventory(site, ctx)
end

function world_model.get_site_collect_position(site, ctx)
  return get_site_collect_position(site, ctx)
end

function world_model.get_site_allowed_items(site, ctx)
  return get_site_allowed_items(site, ctx)
end

function world_model.get_site_collect_count(site, item_name, ctx)
  return get_site_collect_count(site, item_name, ctx)
end

function world_model.cleanup_resource_sites(_ctx)
  return cleanup_resource_sites()
end

function world_model.get_resource_site_counts(_ctx)
  return get_resource_site_counts()
end

function world_model.register_resource_site(task, miner, downstream_machine, output_container, extras, ctx)
  return register_resource_site(task, miner, downstream_machine, output_container, extras, ctx)
end

function world_model.discover_resource_sites(builder_state, ctx)
  return discover_resource_sites(builder_state, ctx)
end

function world_model.find_resource_site(surface, force, origin, task, ctx)
  return find_resource_site(surface, force, origin, task, ctx)
end

function world_model.find_nearest_resource(surface, origin, task, ctx)
  return find_nearest_resource(surface, origin, task, ctx)
end

return world_model

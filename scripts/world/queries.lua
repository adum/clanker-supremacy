local entity_refs = require("scripts.world.entity_refs")
local sites = require("scripts.world.sites")
local storage_helpers = require("scripts.world.storage")

local queries = {}
local find_or_create_belt_hub_position
local build_output_belt_layout_for_anchor
local build_simple_output_belt_layout_for_machine

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

local function build_entity_placement_area(entity_name, position)
  local prototype = prototypes and prototypes.entity and entity_name and prototypes.entity[entity_name] or nil
  local collision_box = prototype and (prototype.collision_box or prototype.selection_box) or nil

  if not collision_box then
    return {
      left_top = {x = position.x - 0.5, y = position.y - 0.5},
      right_bottom = {x = position.x + 0.5, y = position.y + 0.5}
    }
  end

  return {
    left_top = {
      x = position.x + collision_box.left_top.x,
      y = position.y + collision_box.left_top.y
    },
    right_bottom = {
      x = position.x + collision_box.right_bottom.x,
      y = position.y + collision_box.right_bottom.y
    }
  }
end

local function expand_bounding_box(area, padding)
  return {
    left_top = {
      x = area.left_top.x - padding,
      y = area.left_top.y - padding
    },
    right_bottom = {
      x = area.right_bottom.x + padding,
      y = area.right_bottom.y + padding
    }
  }
end

local function clear_ground_item_blockers(surface, entity_name, position, task, summary)
  if not (surface and entity_name and position and task and task.clear_ground_item_blockers) then
    return false
  end

  local search_area = expand_bounding_box(build_entity_placement_area(entity_name, position), 0.05)
  local blockers = surface.find_entities_filtered{
    area = {
      {search_area.left_top.x, search_area.left_top.y},
      {search_area.right_bottom.x, search_area.right_bottom.y}
    },
    type = "item-entity"
  }
  local cleared_count = 0

  for _, blocker in ipairs(blockers) do
    if blocker and blocker.valid then
      blocker.destroy()
      cleared_count = cleared_count + 1
    end
  end

  if cleared_count > 0 and summary then
    summary.ground_item_blockers_cleared = (summary.ground_item_blockers_cleared or 0) + cleared_count
  end

  return cleared_count > 0
end

local function can_place_entity_with_ground_item_clearance(surface, force, entity_name, position, direction, task, summary)
  local placement = {
    name = entity_name,
    position = position,
    force = force
  }

  if direction ~= nil then
    placement.direction = direction
  end

  if surface.can_place_entity(placement) then
    return true
  end

  if clear_ground_item_blockers(surface, entity_name, position, task, summary) then
    return surface.can_place_entity(placement)
  end

  return false
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

    if can_place_entity_with_ground_item_clearance(surface, force, downstream_machine.name, position, nil, task, stats) then
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

local function build_output_belt_layout_site_for_machine(surface, force, task, patch, output_machine, summary, ctx)
  if not (
      surface and
      force and
      task and
      task.output_inserter and
      task.belt_entity_name and
      output_machine and
      output_machine.valid
    )
  then
    return nil
  end

  if task.simple_output_belt_planning then
    return build_simple_output_belt_layout_for_machine(
      surface,
      force,
      task,
      output_machine,
      summary,
      ctx
    )
  end

  local effective_patch = patch or {
    anchor_position = ctx.clone_position(output_machine.position),
    resource_name = task.resource_name
  }
  local hub_position, patch_key = find_or_create_belt_hub_position(surface, force, effective_patch, task, summary, ctx)
  if not hub_position then
    return nil
  end

  local placements, terminal_position = build_output_belt_layout_for_anchor(
    surface,
    force,
    output_machine,
    hub_position,
    task,
    summary,
    ctx
  )
  if not (placements and #placements > 0) then
    return nil
  end

  return {
    placements = placements,
    hub_position = hub_position,
    hub_key = patch_key,
    belt_terminal_position = terminal_position
  }
end

local function find_output_belt_layout_for_machine_position(surface, force, task, patch, output_machine_position, stats, ctx)
  if not (task.output_inserter and task.belt_entity_name and task.downstream_machine and output_machine_position) then
    return nil, nil, nil, nil
  end

  local probe_machine = surface.create_entity{
    name = task.downstream_machine.name,
    position = output_machine_position,
    force = force,
    create_build_effect_smoke = false,
    raise_built = false
  }

  if not probe_machine then
    return nil, nil, nil, nil
  end

  local layout_site = build_output_belt_layout_site_for_machine(
    surface,
    force,
    task,
    patch,
    probe_machine,
    stats,
    ctx
  )

  probe_machine.destroy()

  if not layout_site then
    return nil, nil, nil, nil
  end

  return layout_site.placements,
    layout_site.hub_position,
    layout_site.hub_key,
    layout_site.belt_terminal_position
end

local function count_registered_sites_near_position(requirement, position, ctx)
  if not (requirement and requirement.site_type and position) then
    return 0
  end

  local count = 0
  local radius = requirement.radius or 24
  local radius_squared = radius * radius
  local entity_field = requirement.entity_field or "assembler"

  for _, site in ipairs(storage_helpers.ensure_production_sites()) do
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

  for _, site in ipairs(storage_helpers.ensure_production_sites()) do
    if site.site_type == requirement.site_type and site[entity_field] == anchor_entity then
      return true
    end
  end

  return false
end

local function get_layout_anchor_block_group(task)
  if task and task.require_missing_registered_site and task.require_missing_registered_site.site_type then
    return task.require_missing_registered_site.site_type
  end

  return task and (task.id or task.type) or "layout"
end

local function get_anchor_block_key(anchor_entity)
  if not (anchor_entity and anchor_entity.valid) then
    return nil
  end

  if anchor_entity.unit_number then
    return tostring(anchor_entity.unit_number)
  end

  return string.format("%.2f:%.2f:%s", anchor_entity.position.x, anchor_entity.position.y, anchor_entity.name)
end

local function anchor_is_blocked_for_layout(builder_state, task, anchor_entity)
  if not (builder_state and anchor_entity and anchor_entity.valid) then
    return false
  end

  local blocked_layout_anchors = builder_state.blocked_layout_anchors or {}
  local blocked_group = blocked_layout_anchors[get_layout_anchor_block_group(task)] or {}
  local block_key = get_anchor_block_key(anchor_entity)
  return block_key ~= nil and blocked_group[block_key] == true
end

local function clear_blocked_layout_anchors(builder_state, task)
  if not builder_state then
    return 0
  end

  local blocked_layout_anchors = builder_state.blocked_layout_anchors or {}
  local block_group = get_layout_anchor_block_group(task)
  local blocked_group = blocked_layout_anchors[block_group]
  if type(blocked_group) ~= "table" then
    return 0
  end

  local cleared_count = 0
  for _ in pairs(blocked_group) do
    cleared_count = cleared_count + 1
  end

  blocked_layout_anchors[block_group] = nil
  return cleared_count
end

local function should_retry_cleared_anchor_blocks(builder_state, task, summary, ctx)
  if not (builder_state and task and summary) then
    return false
  end

  if (summary.anchor_entities_considered or 0) > 0 or (summary.anchors_skipped_blocked or 0) <= 0 then
    return false
  end

  local cleared_count = clear_blocked_layout_anchors(builder_state, task)
  if cleared_count <= 0 then
    return false
  end

  if ctx and ctx.debug_log then
    ctx.debug_log(
      "task " .. tostring(task.id or task.pattern_name or task.type or "layout") ..
      ": exhausted blocked anchor pool for " .. tostring(get_layout_anchor_block_group(task)) ..
      "; cleared " .. tostring(cleared_count) .. " blocked anchor(s) and retrying search"
    )
  end

  return true
end

local function find_entity_placement_near_anchor(surface, force, entity_name, anchor_position, search_radius, step, directions, placement_validator, ctx, placement_task)
  local stats = {
    positions_checked = 0,
    placeable_positions = 0
  }

  for _, position in ipairs(ctx.build_search_positions(anchor_position, search_radius, step)) do
    if directions and #directions > 0 then
      for _, direction in ipairs(directions) do
        stats.positions_checked = stats.positions_checked + 1

        if can_place_entity_with_ground_item_clearance(surface, force, entity_name, position, direction, placement_task, stats) then
          stats.placeable_positions = stats.placeable_positions + 1
          if not placement_validator or placement_validator(position, direction) then
            return ctx.clone_position(position), direction, stats
          end
        end
      end
    else
      stats.positions_checked = stats.positions_checked + 1
      if can_place_entity_with_ground_item_clearance(surface, force, entity_name, position, nil, placement_task, stats) then
        stats.placeable_positions = stats.placeable_positions + 1
        if not placement_validator or placement_validator(position, nil) then
          return ctx.clone_position(position), nil, stats
        end
      end
    end
  end

  return nil, nil, stats
end

local function random_between_inclusive(ctx, minimum_value, maximum_value)
  if maximum_value <= minimum_value then
    return minimum_value
  end

  return minimum_value + (ctx.next_random_index((maximum_value - minimum_value) + 1) - 1)
end

local function build_randomized_heading_angles(search_config, ctx)
  local heading_count = math.max(search_config.heading_count or 8, 1)
  local heading_attempts = math.min(math.max(search_config.heading_attempts or heading_count, 1), heading_count)
  local angles = {}

  for index = 1, heading_count do
    angles[index] = ((index - 1) / heading_count) * (math.pi * 2)
  end

  for index = #angles, 2, -1 do
    local swap_index = ctx.next_random_index(index)
    angles[index], angles[swap_index] = angles[swap_index], angles[index]
  end

  local selected_angles = {}
  for index = 1, heading_attempts do
    selected_angles[index] = angles[index]
  end

  return selected_angles
end

local function candidate_entity_overlaps_resources(surface, force, entity_name, position, direction)
  local prototype = prototypes and prototypes.entity and entity_name and prototypes.entity[entity_name] or nil
  local entity_type = prototype and prototype.type or nil
  if entity_type == "transport-belt" or entity_type == "underground-belt" or entity_type == "splitter" then
    return false
  end

  return entity_refs.entity_name_overlaps_resources(surface, entity_name, position)
end

local function build_resource_clearance_search_origins(surface, force, task, anchor_position, summary, ctx)
  local search_config = task.resource_clearance_search
  if not search_config then
    return {
      {
        center = ctx.clone_position(anchor_position),
        search_radius = task.placement_search_radius,
        placement_step = task.placement_step
      }
    }
  end

  local search_origins = {}
  local ray_step = math.max(search_config.ray_step or 1, 0.5)
  local max_distance = math.max(search_config.max_distance or task.placement_search_radius or 16, ray_step)
  local extra_distance_min = math.max(search_config.extra_distance_min or 0, 0)
  local extra_distance_max = math.max(search_config.extra_distance_max or extra_distance_min, extra_distance_min)
  local local_search_radius = search_config.local_search_radius or task.placement_search_radius
  local local_search_step = search_config.local_search_step or task.placement_step

  summary.clearance_headings_considered = summary.clearance_headings_considered or 0
  summary.clearance_origins_found = summary.clearance_origins_found or 0

  for _, angle in ipairs(build_randomized_heading_angles(search_config, ctx)) do
    summary.clearance_headings_considered = summary.clearance_headings_considered + 1

    local saw_resource_overlap = false
    local clear_distance = nil
    local unit_x = math.cos(angle)
    local unit_y = math.sin(angle)

    for distance = ray_step, max_distance, ray_step do
      local probe_position = {
        x = anchor_position.x + (unit_x * distance),
        y = anchor_position.y + (unit_y * distance)
      }

      if candidate_entity_overlaps_resources(surface, force, task.entity_name, probe_position, nil) then
        saw_resource_overlap = true
      elseif saw_resource_overlap then
        clear_distance = distance
        break
      end
    end

    if clear_distance then
      local extra_distance = random_between_inclusive(ctx, extra_distance_min, extra_distance_max)
      local center_distance = clear_distance + extra_distance
      search_origins[#search_origins + 1] = {
        center = {
          x = anchor_position.x + (unit_x * center_distance),
          y = anchor_position.y + (unit_y * center_distance)
        },
        search_radius = local_search_radius,
        placement_step = local_search_step
      }
      summary.clearance_origins_found = summary.clearance_origins_found + 1
    elseif not saw_resource_overlap then
      local center_distance = random_between_inclusive(ctx, extra_distance_min, extra_distance_max)
      search_origins[#search_origins + 1] = {
        center = {
          x = anchor_position.x + (unit_x * center_distance),
          y = anchor_position.y + (unit_y * center_distance)
        },
        search_radius = local_search_radius,
        placement_step = local_search_step
      }
      summary.clearance_origins_found = summary.clearance_origins_found + 1
    end
  end

  return search_origins
end

local function build_layout_placements_around_anchor_entity(surface, force, anchor_entity, layout_config, summary, ctx)
  if not layout_config then
    return {}, "north"
  end

  if layout_config.forbid_resource_overlap and entity_refs.entity_overlaps_resources(anchor_entity) then
    if summary then
      summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
    end
    return nil, nil
  end

  for _, orientation in ipairs(layout_config.layout_orientations or {"north"}) do
    local placements = {}
    local probe_entities = {}
    local layout_valid = true

    for _, element in ipairs(layout_config.layout_elements or {}) do
      local rotated_offset = ctx.rotate_offset(element.offset, orientation)
      local desired_position = {
        x = anchor_entity.position.x + rotated_offset.x,
        y = anchor_entity.position.y + rotated_offset.y
      }
      local direction_name = ctx.rotate_direction_name(element.direction_name, orientation)
      local build_position, build_direction, placement_stats = find_entity_placement_near_anchor(
        surface,
        force,
        element.entity_name,
        desired_position,
        element.placement_search_radius or 0,
        element.placement_step or 0.5,
        direction_name and {ctx.direction_by_name[direction_name]} or nil,
        nil,
        ctx
      )

      if summary and placement_stats then
        summary.positions_checked = summary.positions_checked + (placement_stats.positions_checked or 0)
        summary.placeable_positions = summary.placeable_positions + (placement_stats.placeable_positions or 0)
      end

      if not build_position then
        layout_valid = false
        break
      end

      local probe_entity = surface.create_entity{
        name = element.entity_name,
        position = build_position,
        direction = build_direction,
        force = force,
        create_build_effect_smoke = false,
        raise_built = false
      }

      if not probe_entity then
        layout_valid = false
        break
      end

      probe_entities[#probe_entities + 1] = probe_entity

      if layout_config.forbid_resource_overlap and entity_refs.entity_overlaps_resources(probe_entity) then
        if summary then
          summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
        end
        layout_valid = false
        break
      end

      placements[#placements + 1] = {
        id = element.id or ("layout-" .. tostring(#placements + 1)),
        site_role = element.site_role,
        entity_name = element.entity_name,
        item_name = element.item_name or element.entity_name,
        build_position = ctx.clone_position(build_position),
        build_direction = build_direction,
        recipe_name = element.recipe_name,
        fuel = element.fuel
      }
    end

    if layout_valid and layout_config.layout_site_kind == "steel-smelting-chain" then
      layout_valid = steel_layout_geometry_is_valid(anchor_entity, probe_entities, ctx)
    end

    entity_refs.destroy_entities(probe_entities)

    if layout_valid then
      return placements, orientation
    end
  end

  return nil, nil
end

local function layout_fits_around_anchor_entity(builder, anchor_entity, layout_config, summary, ctx)
  local placements = build_layout_placements_around_anchor_entity(
    builder.surface,
    builder.force,
    anchor_entity,
    layout_config,
    summary,
    ctx
  )

  return placements ~= nil
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

  if task.forbid_resource_overlap and entity_refs.entity_overlaps_resources(probe_entity) then
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

local function entity_contains_point(entity, point, ctx)
  return entity and entity.valid and point and ctx.point_in_area(point, entity.selection_box)
end

local function steel_layout_geometry_is_valid(anchor_entity, probe_entities, ctx)
  local feed_inserter = nil
  local steel_furnace = nil

  for _, probe_entity in ipairs(probe_entities or {}) do
    if probe_entity and probe_entity.valid then
      if probe_entity.name == "burner-inserter" then
        feed_inserter = probe_entity
      elseif probe_entity.name == "stone-furnace" and probe_entity ~= anchor_entity then
        steel_furnace = probe_entity
      end
    end
  end

  if not (anchor_entity and anchor_entity.valid and feed_inserter and steel_furnace) then
    return false
  end

  if not entity_contains_point(anchor_entity, feed_inserter.pickup_position, ctx) then
    return false
  end

  if not entity_contains_point(steel_furnace, feed_inserter.drop_position, ctx) then
    return false
  end

  return true
end

local function get_resource_position_key(resource)
  return string.format("%.2f:%.2f", resource.position.x, resource.position.y)
end

local function resource_position_is_covered_by_existing_miner(surface, force, miner_name, resource_position, ctx)
  local nearby_miners = surface.find_entities_filtered{
    position = resource_position,
    radius = 4,
    force = force,
    name = miner_name
  }

  for _, miner in ipairs(nearby_miners) do
    if miner.valid and miner.mining_area and ctx.point_in_area(resource_position, miner.mining_area) then
      return true
    end
  end

  return false
end

local function build_patch_resource_keys(patch)
  local keys = {}

  for _, resource in ipairs((patch and patch.resources) or {}) do
    keys[get_resource_position_key(resource)] = true
  end

  return keys
end

local function resource_is_patch_edge(resource, patch_resource_keys)
  for dx = -1, 1 do
    for dy = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        local neighbor_key = string.format("%.2f:%.2f", resource.position.x + dx, resource.position.y + dy)
        if not patch_resource_keys[neighbor_key] then
          return true
        end
      end
    end
  end

  return false
end

local function collect_patch_edge_resources(patch, origin, surface, force, task, ctx)
  local patch_resource_keys = build_patch_resource_keys(patch)
  local edge_resources = {}

  for _, resource in ipairs((patch and patch.resources) or {}) do
    if resource_is_patch_edge(resource, patch_resource_keys) and
      not resource_position_is_covered_by_existing_miner(surface, force, task.miner_name, resource.position, ctx)
    then
      edge_resources[#edge_resources + 1] = resource
    end
  end

  table.sort(edge_resources, function(left, right)
    return ctx.square_distance(origin, left.position) < ctx.square_distance(origin, right.position)
  end)

  return edge_resources
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
      local min_x = nil
      local max_x = nil
      local min_y = nil
      local max_y = nil
      local nearest_distance = nil

      visited[resource_key] = true

      while queue_index <= #queue do
        local current_resource = queue[queue_index]
        queue_index = queue_index + 1

        patch_resources[#patch_resources + 1] = current_resource
        sum_x = sum_x + current_resource.position.x
        sum_y = sum_y + current_resource.position.y
        min_x = min_x and math.min(min_x, current_resource.position.x) or current_resource.position.x
        max_x = max_x and math.max(max_x, current_resource.position.x) or current_resource.position.x
        min_y = min_y and math.min(min_y, current_resource.position.y) or current_resource.position.y
        max_y = max_y and math.max(max_y, current_resource.position.y) or current_resource.position.y

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
        representative_resource = patch_resources[1],
        resource_name = patch_resources[1] and patch_resources[1].name or nil,
        resources = patch_resources,
        bounds = {
          left_top = {x = min_x, y = min_y},
          right_bottom = {x = max_x, y = max_y}
        }
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

local function sort_resources_by_distance(resources, origin, ctx)
  table.sort(resources, function(left, right)
    return ctx.square_distance(origin, left.position) < ctx.square_distance(origin, right.position)
  end)
  return resources
end

local function select_nearest_resources(resources, origin, limit, ctx)
  if not (resources and limit and limit > 0) or #resources <= limit then
    return sort_resources_by_distance(resources or {}, origin, ctx), false
  end

  local nearest = {}

  local function get_farthest_index()
    local farthest_index = 1
    local farthest_distance = nearest[1] and nearest[1].distance or -1

    for index = 2, #nearest do
      if nearest[index].distance > farthest_distance then
        farthest_index = index
        farthest_distance = nearest[index].distance
      end
    end

    return farthest_index, farthest_distance
  end

  for _, resource in ipairs(resources) do
    local distance = ctx.square_distance(origin, resource.position)
    if #nearest < limit then
      nearest[#nearest + 1] = {
        resource = resource,
        distance = distance
      }
    else
      local farthest_index, farthest_distance = get_farthest_index()
      if distance < farthest_distance then
        nearest[farthest_index] = {
          resource = resource,
          distance = distance
        }
      end
    end
  end

  table.sort(nearest, function(left, right)
    return left.distance < right.distance
  end)

  local selected_resources = {}
  for index, entry in ipairs(nearest) do
    selected_resources[index] = entry.resource
  end

  return selected_resources, true
end

local function get_patch_key(patch)
  if not patch then
    return nil
  end

  local resource_name = patch.resource_name or (patch.representative_resource and patch.representative_resource.name) or "resource"
  return string.format(
    "%s:%.1f:%.1f",
    resource_name,
    patch.anchor_position.x,
    patch.anchor_position.y
  )
end

local function get_patch_for_site(site, task, ctx)
  if not (site and site.miner and site.miner.valid) then
    return nil
  end

  local resource_name = task.resource_name or site.resource_name
  if not resource_name then
    return nil
  end

  local resources = site.miner.surface.find_entities_filtered{
    position = site.miner.position,
    radius = task.patch_search_radius or 64,
    type = "resource",
    name = resource_name
  }

  if #resources == 0 then
    return nil
  end

  local patches = build_resource_patches(resources, site.miner.position, ctx)
  local best_patch = nil
  local best_distance = nil

  for _, patch in ipairs(patches) do
    local distance = ctx.square_distance(site.miner.position, patch.anchor_position)
    if not best_patch or distance < best_distance then
      best_patch = patch
      best_distance = distance
    end
  end

  return best_patch
end

local function get_mining_area_patch_margin(mining_area, patch)
  local bounds = patch and patch.bounds or nil
  if not (mining_area and bounds and bounds.left_top and bounds.right_bottom) then
    return 0
  end

  local patch_left = bounds.left_top.x - 0.5
  local patch_top = bounds.left_top.y - 0.5
  local patch_right = bounds.right_bottom.x + 0.5
  local patch_bottom = bounds.right_bottom.y + 0.5

  return math.min(
    mining_area.left_top.x - patch_left,
    patch_right - mining_area.right_bottom.x,
    mining_area.left_top.y - patch_top,
    patch_bottom - mining_area.right_bottom.y
  )
end

local function get_total_resource_amount(resources)
  local total_amount = 0

  for _, resource in ipairs(resources or {}) do
    total_amount = total_amount + (resource.amount or 0)
  end

  return total_amount
end

local function find_first_miner_placement(surface, force, task, resource, patch, ctx)
  local site_selection = task.site_selection or {}
  local valid_candidate_limit = site_selection.max_valid_candidates or math.max(site_selection.random_candidate_pool or 1, 4)
  local stats = {
    positions_checked = 0,
    placeable_positions = 0,
    test_miners_created = 0,
    mining_area_hits = 0,
    valid_candidates = 0,
    best_resource_coverage = 0,
    best_resource_amount = 0,
    selected_resource_coverage = 0,
    selected_resource_amount = 0,
    best_patch_margin = 0,
    selected_patch_margin = 0,
    selected_candidate_pool_size = 0,
    output_container_hits = 0,
    downstream_positions_checked = 0,
    downstream_placeable_positions = 0,
    test_downstream_created = 0,
    downstream_anchor_hits = 0,
    terminal_positions_found = 0,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0,
    resource_overlap_rejections = 0,
    low_resource_amount_rejections = 0,
    ground_item_blockers_cleared = 0
  }
  local minimum_resource_amount = task.minimum_resource_amount or 0
  local valid_candidates = {}
  local stop_search = false

  for _, position in ipairs(ctx.build_search_positions(resource.position, task.placement_search_radius, task.placement_step)) do
    for _, direction_name in ipairs(task.placement_directions) do
      local direction = ctx.direction_by_name[direction_name]
      stats.positions_checked = stats.positions_checked + 1

      if can_place_entity_with_ground_item_clearance(surface, force, task.miner_name, position, direction, task, stats) then
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
          local mines_anchor_resource = test_miner.mining_area and ctx.point_in_area(resource.position, test_miner.mining_area)

          if mines_anchor_resource then
            local covered_resources = surface.find_entities_filtered{
              area = test_miner.mining_area,
              type = "resource",
              name = task.resource_name
            }
            local resource_coverage = #covered_resources
            local resource_amount = get_total_resource_amount(covered_resources)
            local patch_margin = get_mining_area_patch_margin(test_miner.mining_area, patch)

            if resource_coverage > 0 then
              stats.mining_area_hits = stats.mining_area_hits + 1
              if resource_coverage > stats.best_resource_coverage then
                stats.best_resource_coverage = resource_coverage
              end
              if resource_amount > stats.best_resource_amount then
                stats.best_resource_amount = resource_amount
              end
              if patch_margin > stats.best_patch_margin then
                stats.best_patch_margin = patch_margin
              end
              if resource_amount >= minimum_resource_amount then
                stats.valid_candidates = stats.valid_candidates + 1
                valid_candidates[#valid_candidates + 1] = {
                  build_position = {
                    x = position.x,
                    y = position.y
                  },
                  build_direction = direction,
                  resource_coverage = resource_coverage,
                  resource_amount = resource_amount,
                  patch_margin = patch_margin,
                  search_weight = position.weight,
                  direction_name = direction_name
                }
                if #valid_candidates >= valid_candidate_limit then
                  stop_search = true
                end
              else
                stats.low_resource_amount_rejections = stats.low_resource_amount_rejections + 1
              end
            end
          end

          test_miner.destroy()
        end
      end

      if stop_search then
        break
      end
    end

    if stop_search then
      break
    end
  end

  local selected_candidate, pool_size = ctx.select_preferred_candidate(
    valid_candidates,
    site_selection.random_candidate_pool or 1,
    function(left, right)
      if site_selection.prefer_patch_margin and left.patch_margin ~= right.patch_margin then
        return left.patch_margin > right.patch_margin
      end

      if site_selection.prefer_middle ~= false and left.resource_coverage ~= right.resource_coverage then
        return left.resource_coverage > right.resource_coverage
      end

      if left.search_weight ~= right.search_weight then
        return left.search_weight < right.search_weight
      end

      return left.direction_name < right.direction_name
    end,
    function(candidate, best_candidate)
      if site_selection.prefer_patch_margin and candidate.patch_margin ~= best_candidate.patch_margin then
        return false
      end

      if site_selection.prefer_middle ~= false and candidate.resource_coverage ~= best_candidate.resource_coverage then
        return false
      end

      return true
    end
  )

  if selected_candidate then
    stats.selected_resource_coverage = selected_candidate.resource_coverage or 0
    stats.selected_resource_amount = selected_candidate.resource_amount or 0
    stats.selected_patch_margin = selected_candidate.patch_margin or 0
    stats.selected_candidate_pool_size = pool_size
    return {
      build_position = selected_candidate.build_position,
      build_direction = selected_candidate.build_direction,
      resource_coverage = selected_candidate.resource_coverage,
      resource_amount = selected_candidate.resource_amount,
      patch_margin = selected_candidate.patch_margin
    }, stats
  end

  return nil, stats
end

local function get_direction_name_from_delta(dx, dy)
  if math.abs(dx) >= math.abs(dy) then
    if dx < 0 then
      return "west"
    end

    return "east"
  end

  if dy < 0 then
    return "north"
  end

  return "south"
end

local function get_direction_vector(direction_name)
  if direction_name == "north" then
    return {x = 0, y = -1}
  end

  if direction_name == "south" then
    return {x = 0, y = 1}
  end

  if direction_name == "west" then
    return {x = -1, y = 0}
  end

  return {x = 1, y = 0}
end

local function get_prioritized_output_directions(from_position, to_position)
  local primary = get_direction_name_from_delta(to_position.x - from_position.x, to_position.y - from_position.y)
  local directions = {primary}
  local seen = {[primary] = true}
  local all_directions = {"north", "east", "south", "west"}

  for _, direction_name in ipairs(all_directions) do
    if not seen[direction_name] then
      directions[#directions + 1] = direction_name
    end
  end

  return directions
end

local function get_opposite_direction_name(direction_name)
  if direction_name == "north" then
    return "south"
  end

  if direction_name == "south" then
    return "north"
  end

  if direction_name == "east" then
    return "west"
  end

  return "east"
end

local function get_machine_edge_belt_candidates(output_machine, direction_name)
  local area = output_machine.selection_box
  local candidates = {}

  if direction_name == "east" then
    for y = math.floor(area.left_top.y) + 0.5, math.ceil(area.right_bottom.y) - 0.5, 1 do
      candidates[#candidates + 1] = {
        inserter_position = {x = area.right_bottom.x + 0.5, y = y},
        first_belt_position = {x = area.right_bottom.x + 1.5, y = y}
      }
    end
    return candidates
  end

  if direction_name == "west" then
    for y = math.floor(area.left_top.y) + 0.5, math.ceil(area.right_bottom.y) - 0.5, 1 do
      candidates[#candidates + 1] = {
        inserter_position = {x = area.left_top.x - 0.5, y = y},
        first_belt_position = {x = area.left_top.x - 1.5, y = y}
      }
    end
    return candidates
  end

  if direction_name == "north" then
    for x = math.floor(area.left_top.x) + 0.5, math.ceil(area.right_bottom.x) - 0.5, 1 do
      candidates[#candidates + 1] = {
        inserter_position = {x = x, y = area.left_top.y - 0.5},
        first_belt_position = {x = x, y = area.left_top.y - 1.5}
      }
    end
    return candidates
  end

  for x = math.floor(area.left_top.x) + 0.5, math.ceil(area.right_bottom.x) - 0.5, 1 do
    candidates[#candidates + 1] = {
      inserter_position = {x = x, y = area.right_bottom.y + 0.5},
      first_belt_position = {x = x, y = area.right_bottom.y + 1.5}
    }
  end

  return candidates
end

local function update_summary_with_placement_stats(summary, placement_stats)
  if not (summary and placement_stats) then
    return
  end

  summary.positions_checked = summary.positions_checked + (placement_stats.positions_checked or 0)
  summary.placeable_positions = summary.placeable_positions + (placement_stats.placeable_positions or 0)
end

local function collect_blocking_occupant_names(surface, position, ctx)
  local occupant_names = {}
  for _, occupant in ipairs(surface.find_entities_filtered{
    area = {
      {position.x - 0.51, position.y - 0.51},
      {position.x + 0.51, position.y + 0.51}
    }
  }) do
    if occupant and occupant.valid then
      occupant_names[#occupant_names + 1] = occupant.name .. "@" .. ctx.format_position(occupant.position)
    end
  end

  return occupant_names
end

local function record_failed_belt_path_detail(summary, detail)
  if not (summary and detail) then
    return
  end

  if not summary.failed_belt_path_detail then
    summary.failed_belt_path_detail = detail
  end
end

local function snap_position_to_tile_center(position)
  return {
    x = math.floor(position.x) + 0.5,
    y = math.floor(position.y) + 0.5
  }
end

find_or_create_belt_hub_position = function(surface, force, patch, task, summary, ctx)
  local belt_hubs = storage_helpers.ensure_belt_hubs()
  local patch_key = get_patch_key(patch)
  local existing = patch_key and belt_hubs[patch_key] or nil
  if existing and existing.position then
    return ctx.clone_position(existing.position), patch_key
  end

  local hub_task = {
    entity_name = task.belt_entity_name,
    resource_clearance_search = task.belt_hub_search,
    placement_search_radius = (task.belt_hub_search and task.belt_hub_search.local_search_radius) or 4,
    placement_step = (task.belt_hub_search and task.belt_hub_search.local_search_step) or 1
  }

  for _, search_origin in ipairs(build_resource_clearance_search_origins(
    surface,
    force,
    hub_task,
    patch.anchor_position,
    summary,
    ctx
  )) do
    local snapped_center = snap_position_to_tile_center(search_origin.center)
    local hub_position, _, placement_stats = find_entity_placement_near_anchor(
      surface,
      force,
      task.belt_entity_name,
      snapped_center,
      search_origin.search_radius,
      search_origin.placement_step,
      {
        ctx.direction_by_name.north,
        ctx.direction_by_name.east,
        ctx.direction_by_name.south,
        ctx.direction_by_name.west
      },
      function(position, direction)
        if task.forbid_resource_overlap and candidate_entity_overlaps_resources(surface, force, task.belt_entity_name, position, direction) then
          summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
          return false
        end

        return true
      end,
      ctx,
      task
    )
    update_summary_with_placement_stats(summary, placement_stats)

    if hub_position then
      if patch_key then
        belt_hubs[patch_key] = {
          position = ctx.clone_position(hub_position),
          resource_name = patch.resource_name
        }
      end
      return ctx.clone_position(hub_position), patch_key
    end
  end

  return nil, patch_key
end

local function step_toward(start_value, end_value)
  if end_value > start_value then
    return start_value + 1
  end

  if end_value < start_value then
    return start_value - 1
  end

  return start_value
end

local function positions_share_tile_alignment(left_value, right_value)
  return math.abs((left_value - math.floor(left_value)) - (right_value - math.floor(right_value))) < 0.01
end

local function build_belt_path_positions(first_position, terminal_position, axis_order, ctx)
  if not positions_share_tile_alignment(first_position.x, terminal_position.x) or
    not positions_share_tile_alignment(first_position.y, terminal_position.y)
  then
    return nil
  end

  local positions = {ctx.clone_position(first_position)}
  local cursor = ctx.clone_position(first_position)
  local remaining_guard = 256

  for _, axis in ipairs(axis_order) do
    while math.abs(cursor[axis] - terminal_position[axis]) > 0.01 do
      remaining_guard = remaining_guard - 1
      if remaining_guard <= 0 then
        return nil
      end
      cursor[axis] = step_toward(cursor[axis], terminal_position[axis])
      positions[#positions + 1] = ctx.clone_position(cursor)
    end
  end

  return positions
end

local function build_belt_path_placements(surface, force, first_position, terminal_position, task, summary, ctx)
  local axis_orders = {
    {"x", "y"},
    {"y", "x"}
  }
  local scored_axis_orders = {}
  local turn_resource_avoidance_lookahead = math.max(task.belt_turn_resource_avoidance_lookahead or 4, 0)

  local function build_axis_order_resource_score(positions)
    local turn_index = nil
    local turn_overlap_count = 0
    local total_overlap_count = 0

    for index, position in ipairs(positions) do
      if entity_refs.entity_name_overlaps_resources(surface, task.belt_entity_name, position) then
        total_overlap_count = total_overlap_count + 1
      end

      if index > 1 and index < #positions and not turn_index then
        local previous_position = positions[index - 1]
        local next_position = positions[index + 1]
        local incoming_direction_name =
          get_direction_name_from_delta(position.x - previous_position.x, position.y - previous_position.y)
        local outgoing_direction_name =
          get_direction_name_from_delta(next_position.x - position.x, next_position.y - position.y)

        if incoming_direction_name ~= outgoing_direction_name then
          turn_index = index
        end
      end
    end

    if turn_index then
      local lookahead_end_index = math.min(#positions, turn_index + turn_resource_avoidance_lookahead)
      for index = turn_index, lookahead_end_index do
        if entity_refs.entity_name_overlaps_resources(surface, task.belt_entity_name, positions[index]) then
          turn_overlap_count = turn_overlap_count + 1
        end
      end
    end

    return turn_overlap_count, total_overlap_count
  end

  for axis_order_index, axis_order in ipairs(axis_orders) do
    local positions = build_belt_path_positions(first_position, terminal_position, axis_order, ctx)
    if not positions then
      goto continue
    end
    local turn_overlap_count, total_overlap_count = build_axis_order_resource_score(positions)
    scored_axis_orders[#scored_axis_orders + 1] = {
      axis_order = axis_order,
      axis_order_index = axis_order_index,
      positions = positions,
      turn_overlap_count = turn_overlap_count,
      total_overlap_count = total_overlap_count
    }

    ::continue::
  end

  table.sort(scored_axis_orders, function(left, right)
    if left.turn_overlap_count ~= right.turn_overlap_count then
      return left.turn_overlap_count < right.turn_overlap_count
    end

    if left.total_overlap_count ~= right.total_overlap_count then
      return left.total_overlap_count < right.total_overlap_count
    end

    return left.axis_order_index < right.axis_order_index
  end)

  for _, axis_order_entry in ipairs(scored_axis_orders) do
    local positions = axis_order_entry.positions
    local placements = {}
    local path_valid = true
    local seen_positions = {}

    for index, position in ipairs(positions) do
      local next_position = positions[index + 1]
      local previous_position = positions[index - 1]
      local direction_name = nil

      if next_position then
        direction_name = get_direction_name_from_delta(next_position.x - position.x, next_position.y - position.y)
      elseif previous_position then
        direction_name = get_direction_name_from_delta(position.x - previous_position.x, position.y - previous_position.y)
      end

      local direction = direction_name and ctx.direction_by_name[direction_name] or ctx.direction_by_name.east
      local position_key = string.format("%.2f:%.2f", position.x, position.y)
      if seen_positions[position_key] then
        record_failed_belt_path_detail(
          summary,
          "duplicate path position " .. ctx.format_position(position) ..
            " for route " .. ctx.format_position(first_position) .. " -> " .. ctx.format_position(terminal_position)
        )
        path_valid = false
        break
      end
      seen_positions[position_key] = true

      summary.positions_checked = summary.positions_checked + 1

      if not can_place_entity_with_ground_item_clearance(surface, force, task.belt_entity_name, position, direction, task, summary) then
        local occupant_names = collect_blocking_occupant_names(surface, position, ctx)
        record_failed_belt_path_detail(
          summary,
          "blocked at " .. ctx.format_position(position) ..
            " dir=" .. tostring(direction_name or "east") ..
            (#occupant_names > 0 and (" by " .. table.concat(occupant_names, ",")) or "")
        )
        path_valid = false
        break
      end

      summary.placeable_positions = summary.placeable_positions + 1

      if task.forbid_resource_overlap and candidate_entity_overlaps_resources(surface, force, task.belt_entity_name, position, direction) then
        summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
        record_failed_belt_path_detail(
          summary,
          "resource overlap at " .. ctx.format_position(position) ..
            " dir=" .. tostring(direction_name or "east")
        )
        path_valid = false
        break
      end

      placements[#placements + 1] = {
        id = "belt-" .. tostring(index),
        site_role = "output-belt",
        entity_name = task.belt_entity_name,
        item_name = task.belt_item_name or task.belt_entity_name,
        build_position = ctx.clone_position(position),
        build_direction = direction
      }
    end

    if path_valid and #placements > 0 then
      return placements
    end
  end

  return nil
end

local function validate_output_inserter_geometry(surface, force, output_machine, inserter_position, inserter_direction, first_belt_placement, task, ctx)
  if not can_place_entity_with_ground_item_clearance(
      surface,
      force,
      task.output_inserter.entity_name,
      inserter_position,
      inserter_direction,
      task
    )
  then
    return false
  end

  clear_ground_item_blockers(surface, first_belt_placement.entity_name, first_belt_placement.build_position, task)
  clear_ground_item_blockers(surface, task.output_inserter.entity_name, inserter_position, task)

  local probe_belt = surface.create_entity{
    name = first_belt_placement.entity_name,
    position = first_belt_placement.build_position,
    direction = first_belt_placement.build_direction,
    force = force,
    create_build_effect_smoke = false,
    raise_built = false
  }

  if not probe_belt then
    return false
  end

  local probe_inserter = surface.create_entity{
    name = task.output_inserter.entity_name,
    position = inserter_position,
    direction = inserter_direction,
    force = force,
    create_build_effect_smoke = false,
    raise_built = false
  }

  if not probe_inserter then
    probe_belt.destroy()
    return false
  end

  local valid =
    ctx.point_in_area(probe_inserter.pickup_position, output_machine.selection_box) and
    ctx.point_in_area(probe_inserter.drop_position, probe_belt.selection_box)

  probe_inserter.destroy()
  probe_belt.destroy()
  return valid
end

local function count_resources_along_straight_belt(surface, entity_name, start_position, direction_vector, step_count)
  local overlap_count = 0

  for step_index = 0, math.max(step_count or 0, 0) - 1 do
    local position = {
      x = start_position.x + (direction_vector.x * step_index),
      y = start_position.y + (direction_vector.y * step_index)
    }

    if entity_refs.entity_name_overlaps_resources(surface, entity_name, position) then
      overlap_count = overlap_count + 1
    end
  end

  return overlap_count
end

build_simple_output_belt_layout_for_machine = function(surface, force, task, output_machine, summary, ctx)
  local best_candidate = nil
  local direction_order = {"north", "east", "south", "west"}
  local belt_build_steps = math.max(task.simple_output_belt_build_steps or 15, 1)
  local belt_scan_steps = math.max(task.simple_output_belt_ore_scan_steps or 20, belt_build_steps)

  for direction_index, direction_name in ipairs(direction_order) do
    local inserter_direction = ctx.direction_by_name[get_opposite_direction_name(direction_name)]
    local belt_direction = ctx.direction_by_name[direction_name]
    local direction_vector = get_direction_vector(direction_name)

    for edge_index, edge_candidate in ipairs(get_machine_edge_belt_candidates(output_machine, direction_name)) do
      local first_belt_placement = {
        entity_name = task.belt_entity_name,
        build_position = ctx.clone_position(edge_candidate.first_belt_position),
        build_direction = belt_direction
      }

      if not validate_output_inserter_geometry(
          surface,
          force,
          output_machine,
          edge_candidate.inserter_position,
          inserter_direction,
          first_belt_placement,
          task,
          ctx
        )
      then
        summary.failed_inserter_geometry = (summary.failed_inserter_geometry or 0) + 1
        goto continue_edge_candidate
      end

      local belt_placements = {}

      for step_index = 0, belt_build_steps - 1 do
        local position = {
          x = edge_candidate.first_belt_position.x + (direction_vector.x * step_index),
          y = edge_candidate.first_belt_position.y + (direction_vector.y * step_index)
        }

        summary.positions_checked = summary.positions_checked + 1

        if not can_place_entity_with_ground_item_clearance(
            surface,
            force,
            task.belt_entity_name,
            position,
            belt_direction,
            task,
            summary
          )
        then
          if #belt_placements == 0 then
            local occupant_names = collect_blocking_occupant_names(surface, position, ctx)
            record_failed_belt_path_detail(
              summary,
              "blocked at " .. ctx.format_position(position) ..
                " dir=" .. tostring(direction_name) ..
                (#occupant_names > 0 and (" by " .. table.concat(occupant_names, ",")) or "")
            )
            summary.failed_belt_paths = (summary.failed_belt_paths or 0) + 1
          end
          break
        end

        summary.placeable_positions = summary.placeable_positions + 1
        belt_placements[#belt_placements + 1] = {
          id = "belt-" .. tostring(step_index + 1),
          site_role = "output-belt",
          entity_name = task.belt_entity_name,
          item_name = task.belt_item_name or task.belt_entity_name,
          build_position = ctx.clone_position(position),
          build_direction = belt_direction
        }
      end

      if #belt_placements == 0 then
        goto continue_edge_candidate
      end

      summary.valid_belt_paths = (summary.valid_belt_paths or 0) + 1

      local ore_overlap_count = count_resources_along_straight_belt(
        surface,
        task.belt_entity_name,
        edge_candidate.first_belt_position,
        direction_vector,
        belt_scan_steps
      )

      local candidate = {
        direction_index = direction_index,
        edge_index = edge_index,
        direction_name = direction_name,
        inserter_position = ctx.clone_position(edge_candidate.inserter_position),
        inserter_direction = inserter_direction,
        belt_placements = belt_placements,
        ore_overlap_count = ore_overlap_count,
        buildable_length = #belt_placements
      }

      if not best_candidate or
        candidate.ore_overlap_count < best_candidate.ore_overlap_count or
        (
          candidate.ore_overlap_count == best_candidate.ore_overlap_count and
          candidate.buildable_length > best_candidate.buildable_length
        ) or
        (
          candidate.ore_overlap_count == best_candidate.ore_overlap_count and
          candidate.buildable_length == best_candidate.buildable_length and
          candidate.direction_index < best_candidate.direction_index
        ) or
        (
          candidate.ore_overlap_count == best_candidate.ore_overlap_count and
          candidate.buildable_length == best_candidate.buildable_length and
          candidate.direction_index == best_candidate.direction_index and
          candidate.edge_index < best_candidate.edge_index
        )
      then
        best_candidate = candidate
      end

      ::continue_edge_candidate::
    end
  end

  if not best_candidate then
    if not summary.failed_belt_path_detail and (summary.failed_inserter_geometry or 0) == 0 then
      record_failed_belt_path_detail(summary, "no straight belt direction fit around output machine")
    end
    return nil
  end

  local placements = {
    {
      id = "output-inserter",
      site_role = "output-inserter",
      entity_name = task.output_inserter.entity_name,
      item_name = task.output_inserter.item_name or task.output_inserter.entity_name,
      build_position = best_candidate.inserter_position,
      build_direction = best_candidate.inserter_direction,
      fuel = task.output_inserter.fuel
    }
  }

  for _, placement in ipairs(best_candidate.belt_placements) do
    placements[#placements + 1] = placement
  end

  local terminal_position = best_candidate.belt_placements[#best_candidate.belt_placements].build_position
  return {
    placements = placements,
    hub_position = ctx.clone_position(terminal_position),
    hub_key = nil,
    belt_terminal_position = ctx.clone_position(terminal_position)
  }
end

build_output_belt_layout_for_anchor = function(surface, force, output_machine, hub_position, task, summary, ctx)
  for _, direction_name in ipairs(get_prioritized_output_directions(output_machine.position, hub_position)) do
    local inserter_direction = ctx.direction_by_name[get_opposite_direction_name(direction_name)]
    for _, edge_candidate in ipairs(get_machine_edge_belt_candidates(output_machine, direction_name)) do
      local terminal_position, _, placement_stats = find_entity_placement_near_anchor(
        surface,
        force,
        task.belt_entity_name,
        hub_position,
        task.belt_terminal_search_radius or 0,
        task.belt_terminal_search_step or 1,
        {
          ctx.direction_by_name.north,
          ctx.direction_by_name.east,
          ctx.direction_by_name.south,
          ctx.direction_by_name.west
        },
        function(position, direction)
          if not positions_share_tile_alignment(edge_candidate.first_belt_position.x, position.x) or
            not positions_share_tile_alignment(edge_candidate.first_belt_position.y, position.y)
          then
            return false
          end

          if task.forbid_resource_overlap and candidate_entity_overlaps_resources(surface, force, task.belt_entity_name, position, direction) then
            summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
            return false
          end

          return true
        end,
        ctx,
        task
      )
      update_summary_with_placement_stats(summary, placement_stats)

      if terminal_position then
        summary.terminal_positions_found = (summary.terminal_positions_found or 0) + 1
        local belt_placements = build_belt_path_placements(
          surface,
          force,
          edge_candidate.first_belt_position,
          terminal_position,
          task,
          summary,
          ctx
        )

        if belt_placements and #belt_placements > 0 then
          summary.valid_belt_paths = (summary.valid_belt_paths or 0) + 1
        else
          summary.failed_belt_paths = (summary.failed_belt_paths or 0) + 1
        end

        if belt_placements and #belt_placements > 0 and validate_output_inserter_geometry(
            surface,
            force,
            output_machine,
            edge_candidate.inserter_position,
            inserter_direction,
            belt_placements[1],
            task,
            ctx
          ) then
          local placements = {}
          for _, placement in ipairs(belt_placements) do
            placements[#placements + 1] = placement
          end

          placements[#placements + 1] = {
            id = "output-inserter",
            site_role = "output-inserter",
            entity_name = task.output_inserter.entity_name,
            item_name = task.output_inserter.item_name or task.output_inserter.entity_name,
            build_position = ctx.clone_position(edge_candidate.inserter_position),
            build_direction = inserter_direction,
            fuel = task.output_inserter.fuel
          }

          return placements, ctx.clone_position(terminal_position)
        elseif belt_placements and #belt_placements > 0 then
          summary.failed_inserter_geometry = (summary.failed_inserter_geometry or 0) + 1
        end
      end
    end
  end

  return nil, nil
end

local function find_miner_placement(surface, force, task, resource_position, patch, ctx)
  local site_selection = task.site_selection or {}
  local valid_candidate_limit = site_selection.max_valid_candidates or math.max(site_selection.random_candidate_pool or 1, 4)
  local stats = {
    positions_checked = 0,
    placeable_positions = 0,
    test_miners_created = 0,
    mining_area_hits = 0,
    valid_candidates = 0,
    best_resource_coverage = 0,
    best_resource_amount = 0,
    selected_resource_coverage = 0,
    selected_resource_amount = 0,
    best_patch_margin = 0,
    selected_patch_margin = 0,
    selected_candidate_pool_size = 0,
    output_container_hits = 0,
    downstream_positions_checked = 0,
    downstream_placeable_positions = 0,
    test_downstream_created = 0,
    downstream_anchor_hits = 0,
    terminal_positions_found = 0,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0,
    resource_overlap_rejections = 0,
    low_resource_amount_rejections = 0,
    ground_item_blockers_cleared = 0,
    valid_candidate_limit = valid_candidate_limit,
    valid_candidate_limit_reached = false
  }
  local valid_candidates = {}
  local stop_search = false
  local minimum_resource_amount = task.minimum_resource_amount or 0

  for _, position in ipairs(ctx.build_search_positions(resource_position, task.placement_search_radius, task.placement_step)) do
    for _, direction_name in ipairs(task.placement_directions) do
      local direction = ctx.direction_by_name[direction_name]
      stats.positions_checked = stats.positions_checked + 1

      if can_place_entity_with_ground_item_clearance(surface, force, task.miner_name, position, direction, task, stats) then
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
          local resource_amount = get_total_resource_amount(covered_resources)
          local patch_margin = get_mining_area_patch_margin(test_miner.mining_area, patch)
          local mines_resource = resource_coverage > 0 and resource_amount >= minimum_resource_amount
          local downstream_machine_position = nil
          local output_container_position = nil
          local has_output_container_spot = true
          local belt_layout_placements = nil
          local belt_hub_position = nil
          local belt_hub_key = nil
          local belt_terminal_position = nil
          local has_output_belt_layout = true

          if resource_coverage > 0 then
            stats.mining_area_hits = stats.mining_area_hits + 1
            if resource_coverage > stats.best_resource_coverage then
              stats.best_resource_coverage = resource_coverage
            end
            if resource_amount > stats.best_resource_amount then
              stats.best_resource_amount = resource_amount
            end
            if patch_margin > stats.best_patch_margin then
              stats.best_patch_margin = patch_margin
            end
          end

          if resource_coverage > 0 and resource_amount < minimum_resource_amount then
            stats.low_resource_amount_rejections = stats.low_resource_amount_rejections + 1
          end

          if mines_resource then
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
              has_output_container_spot = can_place_entity_with_ground_item_clearance(
                surface,
                force,
                task.output_container.name,
                output_container_position,
                nil,
                task,
                stats
              )

              if has_output_container_spot then
                stats.output_container_hits = stats.output_container_hits + 1
              end
            end

            if has_output_container_spot and downstream_machine_position and task.output_inserter and task.belt_entity_name and
              not task.simple_output_belt_planning
            then
              belt_layout_placements, belt_hub_position, belt_hub_key, belt_terminal_position =
                find_output_belt_layout_for_machine_position(
                  surface,
                  force,
                  task,
                  patch,
                  downstream_machine_position,
                  stats,
                  ctx
                )
              has_output_belt_layout = belt_layout_placements ~= nil and #belt_layout_placements > 0
            end
          end

          test_miner.destroy()

          if mines_resource and has_output_container_spot and has_output_belt_layout then
            stats.valid_candidates = stats.valid_candidates + 1
            valid_candidates[#valid_candidates + 1] = {
              build_position = {
                x = position.x,
                y = position.y
              },
              build_direction = direction,
              output_container_position = output_container_position and ctx.clone_position(output_container_position) or nil,
              downstream_machine_position = downstream_machine_position and ctx.clone_position(downstream_machine_position) or nil,
              belt_layout_placements = belt_layout_placements,
              belt_hub_position = belt_hub_position and ctx.clone_position(belt_hub_position) or nil,
              belt_hub_key = belt_hub_key,
              belt_terminal_position = belt_terminal_position and ctx.clone_position(belt_terminal_position) or nil,
              resource_coverage = resource_coverage,
              resource_amount = resource_amount,
              patch_margin = patch_margin,
              search_weight = position.weight,
              direction_name = direction_name
            }

            if #valid_candidates >= valid_candidate_limit then
              stats.valid_candidate_limit_reached = true
              stop_search = true
              break
            end
          end
        end
      end
    end

    if stop_search then
      break
    end
  end

  local selected_candidate, pool_size = ctx.select_preferred_candidate(
    valid_candidates,
    site_selection.random_candidate_pool or 1,
    function(left, right)
      if site_selection.prefer_patch_margin and left.patch_margin ~= right.patch_margin then
        return left.patch_margin > right.patch_margin
      end

      if site_selection.prefer_middle ~= false and left.resource_coverage ~= right.resource_coverage then
        return left.resource_coverage > right.resource_coverage
      end

      if left.search_weight ~= right.search_weight then
        return left.search_weight < right.search_weight
      end

      return left.direction_name < right.direction_name
    end,
    function(candidate, best_candidate)
      if site_selection.prefer_patch_margin and candidate.patch_margin ~= best_candidate.patch_margin then
        return false
      end

      if site_selection.prefer_middle ~= false and candidate.resource_coverage ~= best_candidate.resource_coverage then
        return false
      end

      return true
    end
  )

  if selected_candidate then
    stats.selected_candidate_pool_size = pool_size
    stats.selected_resource_coverage = selected_candidate.resource_coverage or 0
    stats.selected_resource_amount = selected_candidate.resource_amount or 0
    stats.selected_patch_margin = selected_candidate.patch_margin
    return selected_candidate.build_position,
      selected_candidate.build_direction,
      selected_candidate.output_container_position,
      selected_candidate.downstream_machine_position,
      selected_candidate.belt_layout_placements,
      selected_candidate.belt_hub_position,
      selected_candidate.belt_hub_key,
      selected_candidate.belt_terminal_position,
      stats
  end

  return nil, nil, nil, nil, nil, nil, nil, nil, stats
end

local function merge_resource_site_search_summary(summary, placement_stats)
  summary.positions_checked = summary.positions_checked + (placement_stats.positions_checked or 0)
  summary.placeable_positions = summary.placeable_positions + (placement_stats.placeable_positions or 0)
  summary.test_miners_created = summary.test_miners_created + (placement_stats.test_miners_created or 0)
  summary.mining_area_hits = summary.mining_area_hits + (placement_stats.mining_area_hits or 0)
  summary.valid_candidates = summary.valid_candidates + (placement_stats.valid_candidates or 0)
  if (placement_stats.best_resource_coverage or 0) > summary.best_resource_coverage then
    summary.best_resource_coverage = placement_stats.best_resource_coverage
  end
  if (placement_stats.best_resource_amount or 0) > summary.best_resource_amount then
    summary.best_resource_amount = placement_stats.best_resource_amount
  end
  summary.output_container_hits = summary.output_container_hits + (placement_stats.output_container_hits or 0)
  summary.downstream_positions_checked = summary.downstream_positions_checked +
    (placement_stats.downstream_positions_checked or 0)
  summary.downstream_placeable_positions = summary.downstream_placeable_positions +
    (placement_stats.downstream_placeable_positions or 0)
  summary.test_downstream_created = summary.test_downstream_created + (placement_stats.test_downstream_created or 0)
  summary.downstream_anchor_hits = summary.downstream_anchor_hits + (placement_stats.downstream_anchor_hits or 0)
  summary.terminal_positions_found = summary.terminal_positions_found + (placement_stats.terminal_positions_found or 0)
  summary.valid_belt_paths = summary.valid_belt_paths + (placement_stats.valid_belt_paths or 0)
  summary.failed_belt_paths = summary.failed_belt_paths + (placement_stats.failed_belt_paths or 0)
  summary.failed_inserter_geometry = summary.failed_inserter_geometry +
    (placement_stats.failed_inserter_geometry or 0)
  summary.resource_overlap_rejections = summary.resource_overlap_rejections +
    (placement_stats.resource_overlap_rejections or 0)
  summary.low_resource_amount_rejections = summary.low_resource_amount_rejections +
    (placement_stats.low_resource_amount_rejections or 0)
  summary.ground_item_blockers_cleared = (summary.ground_item_blockers_cleared or 0) +
    (placement_stats.ground_item_blockers_cleared or 0)
end

local function build_resource_site_candidate(
  resource,
  build_position,
  build_direction,
  output_container_position,
  downstream_machine_position,
  belt_layout_placements,
  belt_hub_position,
  belt_hub_key,
  belt_terminal_position,
  placement_stats,
  origin,
  ctx
)
  if not build_position then
    return nil
  end

  return {
    resource = resource,
    build_position = build_position,
    build_direction = build_direction,
    output_container_position = output_container_position,
    downstream_machine_position = downstream_machine_position,
    belt_layout_placements = belt_layout_placements,
    belt_hub_position = belt_hub_position,
    belt_hub_key = belt_hub_key,
    belt_terminal_position = belt_terminal_position,
    resource_coverage = placement_stats.selected_resource_coverage or placement_stats.best_resource_coverage,
    resource_amount = placement_stats.selected_resource_amount or placement_stats.best_resource_amount,
    patch_margin = placement_stats.selected_patch_margin or placement_stats.best_patch_margin or 0,
    resource_distance = ctx.square_distance(origin, build_position)
  }
end

local function select_preferred_resource_site_candidate(site_candidates, site_selection, origin, ctx)
  return ctx.select_preferred_candidate(
    site_candidates,
    site_selection.random_candidate_pool or 1,
    function(left, right)
      if site_selection.prefer_patch_margin and left.patch_margin ~= right.patch_margin then
        return left.patch_margin > right.patch_margin
      end

      if site_selection.prefer_middle ~= false and left.resource_coverage ~= right.resource_coverage then
        return left.resource_coverage > right.resource_coverage
      end

      if left.resource_distance ~= right.resource_distance then
        return left.resource_distance < right.resource_distance
      end

      return ctx.square_distance(origin, left.resource.position) < ctx.square_distance(origin, right.resource.position)
    end,
    function(candidate, best_candidate)
      if site_selection.prefer_patch_margin and candidate.patch_margin ~= best_candidate.patch_margin then
        return false
      end

      if site_selection.prefer_middle ~= false and candidate.resource_coverage ~= best_candidate.resource_coverage then
        return false
      end

      return true
    end
  )
end

local function find_edge_resource_site(surface, force, origin, task, ctx)
  local seen_resources = {}
  local site_selection = task.site_selection or {}
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
    best_resource_amount = 0,
    selected_candidate_pool_size = 0,
    output_container_hits = 0,
    downstream_positions_checked = 0,
    downstream_placeable_positions = 0,
    test_downstream_created = 0,
    downstream_anchor_hits = 0,
    terminal_positions_found = 0,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0,
    resource_overlap_rejections = 0,
    low_resource_amount_rejections = 0,
    ground_item_blockers_cleared = 0,
    resource_entities_found = 0,
    resource_entities_selected = 0,
    resource_entities_truncated = false
  }

  for _, radius in ipairs(task.search_radii) do
    summary.radii_checked = summary.radii_checked + 1

    local found_resources = surface.find_entities_filtered{
      position = origin,
      radius = radius,
      type = "resource",
      name = task.resource_name
    }
    local max_resource_scan_entities = task.max_resource_scan_entities_per_radius or
      math.max((task.max_resource_candidates_per_radius or 48) * 4, 64)
    local resources, resources_truncated = select_nearest_resources(
      found_resources,
      origin,
      max_resource_scan_entities,
      ctx
    )
    local patches = build_resource_patches(resources, origin, ctx)
    local considered_this_radius = 0
    local site_candidates = {}

    summary.resource_entities_found = summary.resource_entities_found + #found_resources
    summary.resource_entities_selected = summary.resource_entities_selected + #resources
    summary.resource_entities_truncated = summary.resource_entities_truncated or resources_truncated

    for _, patch in ipairs(patches) do
      for _, resource in ipairs(collect_patch_edge_resources(patch, origin, surface, force, task, ctx)) do
        local resource_key = get_resource_position_key(resource)
        if not seen_resources[resource_key] then
          seen_resources[resource_key] = true
          considered_this_radius = considered_this_radius + 1
          summary.resources_considered = summary.resources_considered + 1

          local site, placement_stats = find_first_miner_placement(surface, force, task, resource, patch, ctx)
          summary.positions_checked = summary.positions_checked + placement_stats.positions_checked
          summary.placeable_positions = summary.placeable_positions + placement_stats.placeable_positions
          summary.test_miners_created = summary.test_miners_created + placement_stats.test_miners_created
          summary.mining_area_hits = summary.mining_area_hits + placement_stats.mining_area_hits
          summary.valid_candidates = summary.valid_candidates + placement_stats.valid_candidates
          if placement_stats.best_resource_coverage > summary.best_resource_coverage then
            summary.best_resource_coverage = placement_stats.best_resource_coverage
          end
          if placement_stats.best_resource_amount > summary.best_resource_amount then
            summary.best_resource_amount = placement_stats.best_resource_amount
          end
          summary.low_resource_amount_rejections = summary.low_resource_amount_rejections +
            (placement_stats.low_resource_amount_rejections or 0)
          summary.selected_candidate_pool_size = placement_stats.selected_candidate_pool_size or
            summary.selected_candidate_pool_size

          if site then
            site_candidates[#site_candidates + 1] = {
              resource = resource,
              anchor_position = ctx.clone_position(resource.position),
              build_position = site.build_position,
              build_direction = site.build_direction,
              resource_coverage = site.resource_coverage,
              resource_amount = site.resource_amount,
              patch_margin = site.patch_margin or placement_stats.selected_patch_margin or placement_stats.best_patch_margin or 0,
              resource_distance = ctx.square_distance(origin, site.build_position)
            }
          end

          if task.max_resource_candidates_per_radius and considered_this_radius >= task.max_resource_candidates_per_radius then
            break
          end
        end
      end

      if task.max_resource_candidates_per_radius and considered_this_radius >= task.max_resource_candidates_per_radius then
        break
      end
    end

    local selected_candidate, pool_size = select_preferred_resource_site_candidate(
      site_candidates,
      site_selection,
      origin,
      ctx
    )

    if selected_candidate then
      summary.selected_candidate_pool_size = pool_size
      return {
        resource = selected_candidate.resource,
        anchor_position = selected_candidate.anchor_position,
        build_position = selected_candidate.build_position,
        build_direction = selected_candidate.build_direction,
        resource_coverage = selected_candidate.resource_coverage,
        resource_amount = selected_candidate.resource_amount,
        selected_from_patch_center = false,
        summary = summary
      }, summary
    end
  end

  return nil, summary
end

function queries.find_resource_site(surface, force, origin, task, ctx)
  if task.site_search_mode == "resource-edge-only" then
    return find_edge_resource_site(surface, force, origin, task, ctx)
  end

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
    best_resource_amount = 0,
    selected_candidate_pool_size = 0,
    output_container_hits = 0,
    downstream_positions_checked = 0,
    downstream_placeable_positions = 0,
    test_downstream_created = 0,
    downstream_anchor_hits = 0,
    terminal_positions_found = 0,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0,
    resource_overlap_rejections = 0,
    low_resource_amount_rejections = 0,
    resource_entities_found = 0,
    resource_entities_selected = 0,
    resource_entities_truncated = false
  }

  for _, radius in ipairs(task.search_radii) do
    summary.radii_checked = summary.radii_checked + 1

    local site_selection = task.site_selection or {}
    local found_resources = surface.find_entities_filtered{
      position = origin,
      radius = radius,
      type = "resource",
      name = task.resource_name
    }

    local max_resource_scan_entities = task.max_resource_scan_entities_per_radius or
      math.max((task.max_resource_candidates_per_radius or 48) * 4, 64)
    local resources, resources_truncated = select_nearest_resources(
      found_resources,
      origin,
      max_resource_scan_entities,
      ctx
    )
    summary.resource_entities_found = summary.resource_entities_found + #found_resources
    summary.resource_entities_selected = summary.resource_entities_selected + #resources
    summary.resource_entities_truncated = summary.resource_entities_truncated or resources_truncated

    local patches = build_resource_patches(found_resources, origin, ctx)

    if site_selection.prefer_middle ~= false and #resources > 0 then
      for _, patch in ipairs(patches) do
        summary.patch_centers_considered = summary.patch_centers_considered + 1

        local build_position,
          build_direction,
          output_container_position,
          downstream_machine_position,
          belt_layout_placements,
          belt_hub_position,
          belt_hub_key,
          belt_terminal_position,
          placement_stats =
          find_miner_placement(surface, force, task, patch.anchor_position, patch, ctx)

        merge_resource_site_search_summary(summary, placement_stats)

        if build_position then
          summary.selected_candidate_pool_size = placement_stats.selected_candidate_pool_size
          return {
            resource = patch.representative_resource,
            anchor_position = ctx.clone_position(patch.anchor_position),
            build_position = build_position,
            build_direction = build_direction,
            output_container_position = output_container_position,
            downstream_machine_position = downstream_machine_position,
            belt_layout_placements = belt_layout_placements,
            belt_hub_position = belt_hub_position,
            belt_hub_key = belt_hub_key,
            belt_terminal_position = belt_terminal_position,
            resource_coverage = placement_stats.selected_resource_coverage or placement_stats.best_resource_coverage,
            resource_amount = placement_stats.selected_resource_amount or placement_stats.best_resource_amount,
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

        local build_position,
          build_direction,
          output_container_position,
          downstream_machine_position,
          belt_layout_placements,
          belt_hub_position,
          belt_hub_key,
          belt_terminal_position,
          placement_stats =
          find_miner_placement(
            surface,
            force,
            task,
            resource.position,
            {
              anchor_position = ctx.clone_position(resource.position),
              resource_name = task.resource_name,
              representative_resource = resource
            },
            ctx
          )
        merge_resource_site_search_summary(summary, placement_stats)

        local site_candidate = build_resource_site_candidate(
          resource,
          build_position,
          build_direction,
          output_container_position,
          downstream_machine_position,
          belt_layout_placements,
          belt_hub_position,
          belt_hub_key,
          belt_terminal_position,
          placement_stats,
          origin,
          ctx
        )
        if site_candidate then
          site_candidates[#site_candidates + 1] = site_candidate
        end

        if task.max_resource_candidates_per_radius and considered_this_radius >= task.max_resource_candidates_per_radius then
          break
        end
      end
    end

    local selected_candidate, pool_size = select_preferred_resource_site_candidate(
      site_candidates,
      site_selection,
      origin,
      ctx
    )

    if selected_candidate then
      summary.selected_candidate_pool_size = pool_size
      selected_candidate.summary = summary
      return selected_candidate
    end

    if task.downstream_machine and resources_truncated and #found_resources > #resources then
      local edge_resource_candidates = {}

      for _, patch in ipairs(patches) do
        for _, resource in ipairs(collect_patch_edge_resources(patch, origin, surface, force, task, ctx)) do
          local resource_key = get_resource_position_key(resource)
          if not seen_resources[resource_key] then
            edge_resource_candidates[#edge_resource_candidates + 1] = {
              resource = resource,
              patch = patch,
              distance = ctx.square_distance(origin, resource.position)
            }
          end
        end
      end

      table.sort(edge_resource_candidates, function(left, right)
        if left.distance ~= right.distance then
          return left.distance > right.distance
        end

        return (left.patch.size or 0) > (right.patch.size or 0)
      end)

      local fallback_site_candidates = {}
      local fallback_considered = 0

      for _, edge_candidate in ipairs(edge_resource_candidates) do
        local resource = edge_candidate.resource
        local resource_key = get_resource_position_key(resource)
        if not seen_resources[resource_key] then
          seen_resources[resource_key] = true
          fallback_considered = fallback_considered + 1
          summary.resources_considered = summary.resources_considered + 1

          local build_position,
            build_direction,
            output_container_position,
            downstream_machine_position,
            belt_layout_placements,
            belt_hub_position,
            belt_hub_key,
            belt_terminal_position,
            placement_stats =
            find_miner_placement(surface, force, task, resource.position, edge_candidate.patch, ctx)

          merge_resource_site_search_summary(summary, placement_stats)

          local site_candidate = build_resource_site_candidate(
            resource,
            build_position,
            build_direction,
            output_container_position,
            downstream_machine_position,
            belt_layout_placements,
            belt_hub_position,
            belt_hub_key,
            belt_terminal_position,
            placement_stats,
            origin,
            ctx
          )
          if site_candidate then
            fallback_site_candidates[#fallback_site_candidates + 1] = site_candidate
          end

          if task.max_resource_candidates_per_radius and fallback_considered >= task.max_resource_candidates_per_radius then
            break
          end
        end
      end

      selected_candidate, pool_size = select_preferred_resource_site_candidate(
        fallback_site_candidates,
        site_selection,
        origin,
        ctx
      )

      if selected_candidate then
        summary.selected_candidate_pool_size = pool_size
        selected_candidate.summary = summary
        return selected_candidate
      end
    end
  end

  return nil, summary
end

function queries.find_downstream_machine_site(surface, force, task, miner, ctx)
  if not (surface and force and task and task.downstream_machine and miner and miner.valid) then
    return nil, {
      positions_checked = 0,
      placeable_positions = 0,
      test_machines_created = 0,
      anchor_cover_hits = 0,
      output_container_hits = 0
    }
  end

  local downstream_machine_position, output_container_position, summary =
    find_downstream_machine_placement(surface, force, task, miner.drop_position, ctx)

  if not downstream_machine_position then
    return nil, summary
  end

  return {
    downstream_machine_position = downstream_machine_position,
    output_container_position = output_container_position
  }, summary
end

function queries.find_output_belt_layout_for_miner_site(surface, force, task, miner, output_machine, ctx)
  local summary = {
    positions_checked = 0,
    placeable_positions = 0,
    terminal_positions_found = 0,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0,
    resource_overlap_rejections = 0
  }

  if not (
      surface and
      force and
      task and
      task.output_inserter and
      task.belt_entity_name and
      miner and
      miner.valid and
      output_machine and
      output_machine.valid
    )
  then
    return nil, summary
  end

  local patch = get_patch_for_site(
    {
      miner = miner,
      resource_name = task.resource_name
    },
    task,
    ctx
  ) or {
    anchor_position = ctx.clone_position(miner.position),
    resource_name = task.resource_name
  }
  local layout_site = build_output_belt_layout_site_for_machine(
    surface,
    force,
    task,
    patch,
    output_machine,
    summary,
    ctx
  )

  if not layout_site then
    return nil, summary
  end

  return layout_site, summary
end

function queries.find_output_belt_path_between_positions(surface, force, first_position, terminal_position, task, ctx)
  local summary = {
    positions_checked = 0,
    placeable_positions = 0,
    resource_overlap_rejections = 0,
    terminal_positions_found = 1,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0
  }

  local placements = build_belt_path_placements(surface, force, first_position, terminal_position, task, summary, ctx)
  if placements and #placements > 0 then
    summary.valid_belt_paths = 1
  else
    summary.failed_belt_paths = 1
  end

  return placements, summary
end

function queries.find_nearest_resource(surface, origin, task, ctx)
  local seen_resources = {}

  for _, radius in ipairs(task.search_radii) do
    local found_resources = surface.find_entities_filtered{
      position = origin,
      radius = radius,
      type = "resource",
      name = task.resource_name
    }

    local resources = select_nearest_resources(found_resources, origin, 1, ctx)

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

function queries.find_machine_site_near_resource_sites(builder_state, task, ctx)
  sites.discover_resource_sites(builder_state, ctx)

  local builder = builder_state.entity
  local origin = task.manual_search_origin or builder.position
  local anchor_candidates = {}
  local anchor_preference = task.anchor_preference and task.anchor_preference.fewer_registered_sites or nil

  for _, site in ipairs(sites.cleanup_resource_sites()) do
    if site_matches_patterns(site, task.anchor_pattern_names) then
      local anchor_position = get_anchor_site_position(site, task.anchor_position_source, ctx)
      if anchor_position then
        anchor_candidates[#anchor_candidates + 1] = {
          site = site,
          anchor_position = anchor_position,
          distance = ctx.square_distance(origin, anchor_position),
          nearby_registered_site_count = count_registered_sites_near_position(anchor_preference, anchor_position, ctx)
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
    minimum_distance_rejections = 0,
    clearance_headings_considered = 0,
    clearance_origins_found = 0,
    resource_overlap_rejections = 0,
    layout_reservation_rejections = 0
  }

  local max_anchor_sites = task.max_anchor_sites or #anchor_candidates

  for _, anchor_candidate in ipairs(anchor_candidates) do
    if summary.anchor_sites_considered >= max_anchor_sites then
      break
    end

    summary.anchor_sites_considered = summary.anchor_sites_considered + 1
    for _, search_origin in ipairs(build_resource_clearance_search_origins(
      builder.surface,
      builder.force,
      task,
      anchor_candidate.anchor_position,
      summary,
      ctx
    )) do
      local build_position, build_direction, placement_stats = find_entity_placement_near_anchor(
        builder.surface,
        builder.force,
        task.entity_name,
        search_origin.center,
        search_origin.search_radius,
        search_origin.placement_step,
        task.placement_directions,
        function(position, direction)
          if task.minimum_anchor_distance then
            local minimum_distance_squared = task.minimum_anchor_distance * task.minimum_anchor_distance
            if ctx.square_distance(position, anchor_candidate.anchor_position) < minimum_distance_squared then
              summary.minimum_distance_rejections = (summary.minimum_distance_rejections or 0) + 1
              return false
            end
          end

          if task.forbid_resource_overlap or task.layout_reservation then
            return machine_site_candidate_is_valid(builder, task, position, direction, summary, ctx)
          end

          return true
        end,
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
  end

  return nil, summary
end

function queries.find_reserved_layout_placements(surface, force, task, anchor_entity, ctx)
  if not (task and task.layout_reservation and anchor_entity and anchor_entity.valid) then
    return nil
  end

  local placements, orientation = build_layout_placements_around_anchor_entity(
    surface,
    force,
    anchor_entity,
    task.layout_reservation,
    nil,
    ctx
  )

  if not placements then
    return nil
  end

  return {
    anchor_entity = anchor_entity,
    anchor_position = ctx.clone_position(anchor_entity.position),
    orientation = orientation,
    placements = placements
  }
end

function queries.find_layout_site_near_machine(builder_state, task, ctx)
  local builder = builder_state.entity
  local anchor_origin = task.manual_anchor_position or builder.position
  local summary = {
    anchor_entities_considered = 0,
    anchors_skipped_registered = 0,
    anchors_skipped_blocked = 0,
    orientations_considered = 0,
    layout_elements_checked = 0,
    positions_checked = 0,
    placeable_positions = 0,
    resource_overlap_rejections = 0,
    terminal_positions_found = 0,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0,
    failed_anchor_entity = nil
  }

  local anchor_candidates = {}

  if task.anchor_pattern_names and #task.anchor_pattern_names > 0 then
    sites.discover_resource_sites(builder_state, ctx)

    for _, site in ipairs(sites.cleanup_resource_sites()) do
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

  for attempt = 1, 2 do
    for _, anchor_candidate in ipairs(anchor_candidates) do
      if summary.anchor_entities_considered >= max_anchor_entities then
        break
      end

      local anchor_entity = anchor_candidate.anchor_entity
      if anchor_entity.valid then
        if anchor_is_blocked_for_layout(builder_state, task, anchor_entity) then
          summary.anchors_skipped_blocked = summary.anchors_skipped_blocked + 1
        elseif anchor_has_registered_site(anchor_entity, task.require_missing_registered_site) then
          summary.anchors_skipped_registered = summary.anchors_skipped_registered + 1
        else
          summary.anchor_entities_considered = summary.anchor_entities_considered + 1
          summary.failed_anchor_entity = anchor_entity

          if task.forbid_resource_overlap and entity_refs.entity_overlaps_resources(anchor_entity) then
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

                if task.forbid_resource_overlap and entity_refs.entity_overlaps_resources(probe_entity) then
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

              if layout_valid and task.layout_site_kind == "steel-smelting-chain" then
                layout_valid = steel_layout_geometry_is_valid(anchor_entity, probe_entities, ctx)
              end

              entity_refs.destroy_entities(probe_entities)

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

    if not (attempt == 1 and should_retry_cleared_anchor_blocks(builder_state, task, summary, ctx)) then
      break
    end
  end

  return nil, summary
end

function queries.find_output_belt_line_site(builder_state, task, ctx)
  sites.discover_resource_sites(builder_state, ctx)

  local builder = builder_state.entity
  local anchor_origin = task.manual_anchor_position or builder.position
  local summary = {
    anchor_entities_considered = 0,
    anchors_skipped_registered = 0,
    anchors_skipped_blocked = 0,
    orientations_considered = 0,
    layout_elements_checked = 0,
    positions_checked = 0,
    placeable_positions = 0,
    resource_overlap_rejections = 0,
    ground_item_blockers_cleared = 0,
    failed_anchor_entity = nil
  }

  local anchor_candidates = {}

  for _, site in ipairs(sites.cleanup_resource_sites()) do
    if site_matches_patterns(site, task.anchor_pattern_names) then
      local anchor_entity = get_anchor_site_entity(site, task.anchor_position_source)
      if anchor_entity then
        anchor_candidates[#anchor_candidates + 1] = {
          site = site,
          anchor_entity = anchor_entity,
          distance = ctx.square_distance(anchor_origin, anchor_entity.position)
        }
      end
    end
  end

  table.sort(anchor_candidates, function(left, right)
    return left.distance < right.distance
  end)

  local max_anchor_entities = task.max_anchor_entities or #anchor_candidates

  for attempt = 1, 2 do
    for _, anchor_candidate in ipairs(anchor_candidates) do
      if summary.anchor_entities_considered >= max_anchor_entities then
        break
      end

      local anchor_entity = anchor_candidate.anchor_entity
      if anchor_entity and anchor_entity.valid then
        if anchor_is_blocked_for_layout(builder_state, task, anchor_entity) then
          summary.anchors_skipped_blocked = summary.anchors_skipped_blocked + 1
        elseif anchor_has_registered_site(anchor_entity, task.require_missing_registered_site) then
          summary.anchors_skipped_registered = summary.anchors_skipped_registered + 1
        else
          summary.anchor_entities_considered = summary.anchor_entities_considered + 1
          summary.failed_anchor_entity = anchor_entity

          local patch = get_patch_for_site(anchor_candidate.site, task, ctx)
          if patch then
            local layout_site = build_output_belt_layout_site_for_machine(
              builder.surface,
              builder.force,
              task,
              patch,
              anchor_entity,
              summary,
              ctx
            )

            if layout_site then
              return {
                site = anchor_candidate.site,
                anchor_entity = anchor_entity,
                anchor_position = ctx.clone_position(anchor_entity.position),
                build_position = ctx.clone_position(anchor_entity.position),
                hub_position = layout_site.hub_position,
                hub_key = layout_site.hub_key,
                belt_terminal_position = layout_site.belt_terminal_position,
                placements = layout_site.placements,
                summary = summary
              }, summary
            end
          end
        end
      end
    end

    if not (attempt == 1 and should_retry_cleared_anchor_blocks(builder_state, task, summary, ctx)) then
      break
    end
  end

  return nil, summary
end

local function get_position_key(position)
  return string.format("%.2f:%.2f", position.x, position.y)
end

local function get_direction_vector_from_direction(direction, ctx)
  if direction == ctx.direction_by_name.north then
    return {x = 0, y = -1}
  end

  if direction == ctx.direction_by_name.south then
    return {x = 0, y = 1}
  end

  if direction == ctx.direction_by_name.west then
    return {x = -1, y = 0}
  end

  return {x = 1, y = 0}
end

local function get_site_output_item_name(site)
  if site.output_item_name then
    return site.output_item_name
  end

  if site.output_machine and site.output_machine.valid and site.output_machine.get_recipe then
    local recipe = site.output_machine.get_recipe()
    return recipe and recipe.name or nil
  end

  return nil
end

local function get_assembly_route_item_names(assembly_target)
  local item_names = {}
  local seen = {}

  for _, route_spec in ipairs((assembly_target and assembly_target.raw_input_routes) or {}) do
    local item_name = route_spec.item_name
    if item_name and not seen[item_name] then
      seen[item_name] = true
      item_names[#item_names + 1] = item_name
    end
  end

  return item_names
end

local function find_nearest_power_anchor_pole(surface, force, position, radius, pole_name, ctx)
  local poles = surface.find_entities_filtered{
    position = position,
    radius = radius,
    force = force,
    name = pole_name
  }

  table.sort(poles, function(left, right)
    return ctx.square_distance(position, left.position) < ctx.square_distance(position, right.position)
  end)

  return poles[1]
end

local function build_source_cluster_anchor_candidates(builder_state, task, summary, ctx)
  local builder = builder_state.entity
  local assembly_target = task.assembly_target or {}
  local cluster_config = assembly_target.source_cluster or task.source_cluster or {}
  local site_type = cluster_config.site_type or "smelting-output-belt"
  local max_sites_per_item = math.max(cluster_config.max_sites_per_item or 4, 1)
  local route_item_names = get_assembly_route_item_names(assembly_target)
  local sites_by_item = {}
  local candidates = {}

  if #route_item_names == 0 then
    return candidates
  end

  for _, item_name in ipairs(route_item_names) do
    sites_by_item[item_name] = {}
  end

  for _, site in ipairs(storage_helpers.ensure_production_sites()) do
    local output_item_name = get_site_output_item_name(site)
    if site.site_type == site_type and output_item_name and sites_by_item[output_item_name] then
      local anchor_entity = site.output_machine
      local hub_position = site.hub_position
      if anchor_entity and anchor_entity.valid and hub_position then
        sites_by_item[output_item_name][#sites_by_item[output_item_name] + 1] = {
          site = site,
          distance = ctx.square_distance(builder.position, hub_position)
        }
      end
    end
  end

  local missing_source_items = {}
  for _, item_name in ipairs(route_item_names) do
    local item_sites = sites_by_item[item_name]
    table.sort(item_sites, function(left, right)
      return left.distance < right.distance
    end)

    while #item_sites > max_sites_per_item do
      table.remove(item_sites)
    end

    if #item_sites == 0 then
      missing_source_items[#missing_source_items + 1] = item_name
    end
  end

  if #missing_source_items > 0 then
    for _, item_name in ipairs(missing_source_items) do
      summary.missing_source_items[#summary.missing_source_items + 1] = item_name
    end
    return {}
  end

  local primary_item_name = route_item_names[1]
  for _, primary_candidate in ipairs(sites_by_item[primary_item_name]) do
    local source_sites_by_item = {
      [primary_item_name] = {primary_candidate.site}
    }
    local cluster_positions = {
      primary_candidate.site.hub_position
    }
    local preferred_direction_x = 0
    local preferred_direction_y = 0
    local cluster_score = 0
    local cluster_valid = true

    if primary_candidate.site.output_machine and primary_candidate.site.output_machine.valid then
      preferred_direction_x = preferred_direction_x +
        (primary_candidate.site.hub_position.x - primary_candidate.site.output_machine.position.x)
      preferred_direction_y = preferred_direction_y +
        (primary_candidate.site.hub_position.y - primary_candidate.site.output_machine.position.y)
    end

    for item_index = 2, #route_item_names do
      local item_name = route_item_names[item_index]
      local nearest_site = nil
      local nearest_distance = nil

      for _, candidate in ipairs(sites_by_item[item_name]) do
        local candidate_distance = ctx.square_distance(primary_candidate.site.hub_position, candidate.site.hub_position)
        if not nearest_site or candidate_distance < nearest_distance then
          nearest_site = candidate.site
          nearest_distance = candidate_distance
        end
      end

      if not nearest_site then
        cluster_valid = false
        break
      end

      source_sites_by_item[item_name] = {nearest_site}
      cluster_positions[#cluster_positions + 1] = nearest_site.hub_position
      if nearest_site.output_machine and nearest_site.output_machine.valid then
        preferred_direction_x = preferred_direction_x +
          (nearest_site.hub_position.x - nearest_site.output_machine.position.x)
        preferred_direction_y = preferred_direction_y +
          (nearest_site.hub_position.y - nearest_site.output_machine.position.y)
      end
      cluster_score = cluster_score + (nearest_distance or 0)
    end

    if cluster_valid then
      local sum_x = 0
      local sum_y = 0
      for _, cluster_position in ipairs(cluster_positions) do
        sum_x = sum_x + cluster_position.x
        sum_y = sum_y + cluster_position.y
      end

      local cluster_center = {
        x = sum_x / #cluster_positions,
        y = sum_y / #cluster_positions
      }
      local power_anchor_pole = find_nearest_power_anchor_pole(
        builder.surface,
        builder.force,
        cluster_center,
        task.power_anchor_search_radius or 16,
        assembly_target.power_anchor_entity_name or task.power_anchor_entity_name,
        ctx
      )

      if power_anchor_pole and power_anchor_pole.valid then
        local preferred_direction_vector = nil
        if preferred_direction_x ~= 0 or preferred_direction_y ~= 0 then
          preferred_direction_vector = {
            x = preferred_direction_x,
            y = preferred_direction_y
          }
        else
          preferred_direction_vector = {
            x = power_anchor_pole.position.x - cluster_center.x,
            y = power_anchor_pole.position.y - cluster_center.y
          }
        end

        candidates[#candidates + 1] = {
          anchor_entity = primary_candidate.site.output_machine,
          power_anchor_pole = power_anchor_pole,
          search_center = snap_position_to_tile_center(power_anchor_pole.position),
          minimum_distance_reference = snap_position_to_tile_center(cluster_center),
          source_sites_by_item = source_sites_by_item,
          preferred_direction_vector = preferred_direction_vector,
          score = cluster_score + ctx.square_distance(builder.position, cluster_center)
        }
      else
        summary.anchors_missing_power = summary.anchors_missing_power + 1
      end
    end
  end

  table.sort(candidates, function(left, right)
    return left.score < right.score
  end)

  return candidates
end

local function build_source_cluster_search_origins(cluster_center, cluster_config, task, preferred_direction_vector, ctx)
  local maximum_build_distance = math.max(
    cluster_config.maximum_build_distance or cluster_config.local_search_radius or task.placement_search_radius or 0,
    0
  )
  local minimum_build_distance = math.max(cluster_config.minimum_build_distance or 0, 0)

  if maximum_build_distance <= 0 then
    return {{
      center = ctx.clone_position(cluster_center),
      search_radius = task.placement_search_radius or 0,
      placement_step = cluster_config.local_search_step or task.placement_step or 1
    }}
  end

  local heading_config = {
    heading_count = cluster_config.heading_count or 16,
    heading_attempts = cluster_config.heading_attempts or (cluster_config.heading_count or 16)
  }
  local origin_search_radius = cluster_config.origin_search_radius or task.placement_search_radius or 0
  local origin_search_step = cluster_config.local_search_step or task.placement_step or 1
  local search_origins = {}

  local heading_angles = build_randomized_heading_angles(heading_config, ctx)
  if preferred_direction_vector and (preferred_direction_vector.x ~= 0 or preferred_direction_vector.y ~= 0) then
    local vector_length = math.sqrt(
      (preferred_direction_vector.x * preferred_direction_vector.x) +
      (preferred_direction_vector.y * preferred_direction_vector.y)
    )
    if vector_length > 0 then
      local preferred_unit_x = preferred_direction_vector.x / vector_length
      local preferred_unit_y = preferred_direction_vector.y / vector_length
      table.sort(heading_angles, function(left, right)
        local left_score = (math.cos(left) * preferred_unit_x) + (math.sin(left) * preferred_unit_y)
        local right_score = (math.cos(right) * preferred_unit_x) + (math.sin(right) * preferred_unit_y)
        return left_score > right_score
      end)
    end
  end

  for _, angle in ipairs(heading_angles) do
    local center_distance = random_between_inclusive(
      ctx,
      math.ceil(minimum_build_distance),
      math.ceil(maximum_build_distance)
    )
    search_origins[#search_origins + 1] = {
      center = snap_position_to_tile_center{
        x = cluster_center.x + (math.cos(angle) * center_distance),
        y = cluster_center.y + (math.sin(angle) * center_distance)
      },
      search_radius = origin_search_radius,
      placement_step = origin_search_step
    }
  end

  return search_origins
end

local function get_output_belt_terminal_entity(site, ctx)
  local best_belt = nil
  local best_distance = nil
  local hub_position = site and site.hub_position or nil

  for _, belt_entity in ipairs((site and site.belt_entities) or {}) do
    if belt_entity and belt_entity.valid then
      local distance
      if hub_position then
        distance = ctx.square_distance(belt_entity.position, hub_position)
      elseif site.output_machine and site.output_machine.valid then
        distance = -ctx.square_distance(belt_entity.position, site.output_machine.position)
      else
        distance = 0
      end

      if not best_belt or distance < best_distance then
        best_belt = belt_entity
        best_distance = distance
      end
    end
  end

  return best_belt
end

local function get_output_belt_connection_positions(site, ctx)
  local terminal_belt = get_output_belt_terminal_entity(site, ctx)
  if not (terminal_belt and terminal_belt.valid) then
    return {}
  end

  local direction_vector = get_direction_vector_from_direction(terminal_belt.direction, ctx)
  return {{
    position = {
      x = terminal_belt.position.x + direction_vector.x,
      y = terminal_belt.position.y + direction_vector.y
    },
    terminal_belt = terminal_belt
  }}
end

local function build_source_route_entry_options(surface, force, terminal_belt, route_target_position, task, summary, ctx)
  local options = {}
  if not (terminal_belt and terminal_belt.valid and route_target_position) then
    return options
  end

  local extractor_spec = task.assembly_target and task.assembly_target.source_route_extractor or nil
  if not extractor_spec then
    local start_direction_vector = get_direction_vector_from_direction(terminal_belt.direction, ctx)
    if start_direction_vector then
      options[#options + 1] = {
        path_start_position = {
          x = terminal_belt.position.x + (start_direction_vector.x * 2),
          y = terminal_belt.position.y + (start_direction_vector.y * 2)
        },
        prefix_placements = {{
          entity_name = task.belt_entity_name,
          item_name = task.belt_item_name or task.belt_entity_name,
          build_position = {
            x = terminal_belt.position.x + start_direction_vector.x,
            y = terminal_belt.position.y + start_direction_vector.y
          },
          build_direction = terminal_belt.direction,
          site_role = "assembly-source-belt"
        }}
      }
    end
    return options
  end

  local candidate_steps = {
    {x = 1, y = 0},
    {x = -1, y = 0},
    {x = 0, y = 1},
    {x = 0, y = -1}
  }
  local target_vector = {
    x = route_target_position.x - terminal_belt.position.x,
    y = route_target_position.y - terminal_belt.position.y
  }
  table.sort(candidate_steps, function(left, right)
    local left_score = (left.x * target_vector.x) + (left.y * target_vector.y)
    local right_score = (right.x * target_vector.x) + (right.y * target_vector.y)
    return left_score > right_score
  end)

  for _, step in ipairs(candidate_steps) do
    local inserter_position = {
      x = terminal_belt.position.x + step.x,
      y = terminal_belt.position.y + step.y
    }
    local drop_belt_position = {
      x = terminal_belt.position.x + (step.x * 2),
      y = terminal_belt.position.y + (step.y * 2)
    }
    local pickup_direction_name = get_direction_name_from_delta(-step.x, -step.y)
    local pickup_direction = pickup_direction_name and ctx.direction_by_name[pickup_direction_name] or nil

    if pickup_direction and surface.can_place_entity{
      name = extractor_spec.entity_name,
      position = inserter_position,
      direction = pickup_direction,
      force = force
    } and surface.can_place_entity{
      name = task.belt_entity_name,
      position = drop_belt_position,
      direction = ctx.direction_by_name.east,
      force = force
    } then
      local resource_overlap = false
      if task.forbid_resource_overlap then
        resource_overlap =
          candidate_entity_overlaps_resources(surface, force, extractor_spec.entity_name, inserter_position, pickup_direction) or
          candidate_entity_overlaps_resources(surface, force, task.belt_entity_name, drop_belt_position, ctx.direction_by_name.east)
      end

      if resource_overlap then
        summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
      else
        local probe_belt = surface.create_entity{
          name = task.belt_entity_name,
          position = drop_belt_position,
          direction = ctx.direction_by_name.east,
          force = force,
          create_build_effect_smoke = false,
          raise_built = false
        }
        local probe_inserter = probe_belt and surface.create_entity{
          name = extractor_spec.entity_name,
          position = inserter_position,
          direction = pickup_direction,
          force = force,
          create_build_effect_smoke = false,
          raise_built = false
        } or nil

        local geometry_ok =
          probe_belt and probe_belt.valid and
          probe_inserter and probe_inserter.valid and
          entity_contains_point(terminal_belt, probe_inserter.pickup_position, ctx) and
          entity_contains_point(probe_belt, probe_inserter.drop_position, ctx)

        if probe_inserter and probe_inserter.valid then
          probe_inserter.destroy()
        end
        if probe_belt and probe_belt.valid then
          probe_belt.destroy()
        end

        if geometry_ok then
          options[#options + 1] = {
            path_start_position = ctx.clone_position(drop_belt_position),
            suffix_placements = {{
              entity_name = extractor_spec.entity_name,
              item_name = extractor_spec.item_name or extractor_spec.entity_name,
              build_position = ctx.clone_position(inserter_position),
              build_direction = pickup_direction,
              site_role = "assembly-source-inserter",
              fuel = extractor_spec.fuel
            }}
          }
        else
          summary.failed_source_extractors = (summary.failed_source_extractors or 0) + 1
        end
      end
    else
      summary.failed_source_extractors = (summary.failed_source_extractors or 0) + 1
    end
  end

  return options
end

local function build_belt_path_placements_between_positions(surface, force, first_position, terminal_position, task, summary, reusable_belt_entities_by_key, ctx)
  local function is_walkable_position(position)
    local position_key = get_position_key(position)
    local reusable_belt = reusable_belt_entities_by_key and reusable_belt_entities_by_key[position_key] or nil
    if reusable_belt and reusable_belt.valid then
      return true
    end

    summary.positions_checked = summary.positions_checked + 1

    if not surface.can_place_entity{
      name = task.belt_entity_name,
      position = position,
      direction = ctx.direction_by_name.east,
      force = force
    } then
      return false
    end

    summary.placeable_positions = summary.placeable_positions + 1

    if task.forbid_resource_overlap and candidate_entity_overlaps_resources(
      surface,
      force,
      task.belt_entity_name,
      position,
      ctx.direction_by_name.east
    ) then
      summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
      return false
    end

    return true
  end

  local function try_build_placements_from_positions(positions, axis_label)
    local placements = {}
    local seen_positions = {}

    for index, position in ipairs(positions) do
      local next_position = positions[index + 1]
      local previous_position = positions[index - 1]
      local direction_name = nil

      if next_position then
        direction_name = get_direction_name_from_delta(next_position.x - position.x, next_position.y - position.y)
      elseif previous_position then
        direction_name = get_direction_name_from_delta(position.x - previous_position.x, position.y - previous_position.y)
      end

      local direction = direction_name and ctx.direction_by_name[direction_name] or ctx.direction_by_name.east
      local position_key = get_position_key(position)
      if seen_positions[position_key] then
        if (summary.failed_source_routes or 0) < 5 then
          ctx.debug_log(
            "assembly route duplicate position at " .. ctx.format_position(position) ..
            " for path " .. ctx.format_position(first_position) .. " -> " .. ctx.format_position(terminal_position) ..
            " via " .. axis_label
          )
        end
        return nil
      end
      seen_positions[position_key] = true

      local reusable_belt = reusable_belt_entities_by_key and reusable_belt_entities_by_key[position_key] or nil
      if reusable_belt and reusable_belt.valid then
        if position_key ~= get_position_key(terminal_position) and reusable_belt.direction == direction then
          goto continue_position
        end
        return nil
      end

      summary.positions_checked = summary.positions_checked + 1

      if not surface.can_place_entity{
        name = task.belt_entity_name,
        position = position,
        direction = direction,
        force = force
      } then
        if (summary.failed_source_routes or 0) < 5 then
          local occupant_names = {}
          for _, occupant in ipairs(surface.find_entities_filtered{
            area = {
              {position.x - 0.51, position.y - 0.51},
              {position.x + 0.51, position.y + 0.51}
            }
          }) do
            if occupant and occupant.valid then
              occupant_names[#occupant_names + 1] = occupant.name .. "@" .. ctx.format_position(occupant.position)
            end
          end
          ctx.debug_log(
            "assembly route blocked at " .. ctx.format_position(position) ..
            " dir=" .. tostring(direction_name) ..
            " for path " .. ctx.format_position(first_position) .. " -> " .. ctx.format_position(terminal_position) ..
            " via " .. axis_label ..
            "; occupants=" .. table.concat(occupant_names, ",")
          )
        end
        return nil
      end

      summary.placeable_positions = summary.placeable_positions + 1

      if task.forbid_resource_overlap and candidate_entity_overlaps_resources(surface, force, task.belt_entity_name, position, direction) then
        summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
        if (summary.failed_source_routes or 0) < 5 then
          ctx.debug_log(
            "assembly route resource overlap at " .. ctx.format_position(position) ..
            " for path " .. ctx.format_position(first_position) .. " -> " .. ctx.format_position(terminal_position) ..
            " via " .. axis_label
          )
        end
        return nil
      end

      placements[#placements + 1] = {
        id = "assembly-belt-route-" .. tostring(index),
        site_role = "assembly-input-belt",
        entity_name = task.belt_entity_name,
        item_name = task.belt_item_name or task.belt_entity_name,
        build_position = ctx.clone_position(position),
        build_direction = direction
      }

      ::continue_position::
    end

    return placements
  end

  local axis_orders = {
    {"x", "y"},
    {"y", "x"}
  }

  for _, axis_order in ipairs(axis_orders) do
    local positions = build_belt_path_positions(first_position, terminal_position, axis_order, ctx)
    if not positions then
      goto continue
    end

    local placements = try_build_placements_from_positions(positions, table.concat(axis_order, ","))
    if placements then
      return placements
    end

    ::continue::
  end

  local search_margin = task.belt_route_search_margin or 10
  local min_x = math.min(first_position.x, terminal_position.x) - search_margin
  local max_x = math.max(first_position.x, terminal_position.x) + search_margin
  local min_y = math.min(first_position.y, terminal_position.y) - search_margin
  local max_y = math.max(first_position.y, terminal_position.y) + search_margin
  local function in_bounds(position)
    return position.x >= min_x and position.x <= max_x and position.y >= min_y and position.y <= max_y
  end

  local start_key = get_position_key(first_position)
  local goal_key = get_position_key(terminal_position)
  local queue = {ctx.clone_position(first_position)}
  local head = 1
  local parents = {}
  local visited = {[start_key] = true}
  local found_goal = false
  local steps = {
    {x = 1, y = 0},
    {x = -1, y = 0},
    {x = 0, y = 1},
    {x = 0, y = -1}
  }

  while head <= #queue do
    local current = queue[head]
    head = head + 1

    if get_position_key(current) == goal_key then
      found_goal = true
      break
    end

    for _, step in ipairs(steps) do
      local next_position = {
        x = current.x + step.x,
        y = current.y + step.y
      }
      local next_key = get_position_key(next_position)

      if not visited[next_key] and in_bounds(next_position) then
        visited[next_key] = true

        if next_key == goal_key then
          parents[next_key] = get_position_key(current)
          queue[#queue + 1] = next_position
        else
          if is_walkable_position(next_position) then
            parents[next_key] = get_position_key(current)
            queue[#queue + 1] = next_position
          end
        end
      end
    end
  end

  if found_goal or visited[goal_key] then
    local positions = {ctx.clone_position(terminal_position)}
    local current_key = goal_key
    while current_key ~= start_key do
      local parent_key = parents[current_key]
      if not parent_key then
        positions = nil
        break
      end
      local x_string, y_string = string.match(parent_key, "^([^:]+):([^:]+)$")
      positions[#positions + 1] = {
        x = tonumber(x_string),
        y = tonumber(y_string)
      }
      current_key = parent_key
    end

    if positions then
      local ordered_positions = {}
      for index = #positions, 1, -1 do
        ordered_positions[#ordered_positions + 1] = positions[index]
      end
      local placements = try_build_placements_from_positions(ordered_positions, "grid")
      if placements then
        return placements
      end
    end
  end

  if (summary.failed_source_routes or 0) < 5 then
    ctx.debug_log(
      "assembly route no path from " .. ctx.format_position(first_position) ..
      " to " .. ctx.format_position(terminal_position) ..
      " within search margin " .. tostring(task.belt_route_search_margin or 10)
    )
  end

  return nil
end

local function create_ordered_belt_placements_from_positions(positions, task, id_prefix, site_role, explicit_direction_name, ctx)
  local placements = {}

  for index, position in ipairs(positions or {}) do
    local next_position = positions[index + 1]
    local previous_position = positions[index - 1]
    local direction_name = nil

    if next_position then
      direction_name = get_direction_name_from_delta(next_position.x - position.x, next_position.y - position.y)
    elseif previous_position then
      direction_name = get_direction_name_from_delta(position.x - previous_position.x, position.y - previous_position.y)
    end

    local final_direction_name = explicit_direction_name or direction_name

    placements[#placements + 1] = {
      id = id_prefix .. "-" .. tostring(index),
      site_role = site_role or "assembly-input-belt",
      entity_name = task.belt_entity_name,
      item_name = task.belt_item_name or task.belt_entity_name,
      build_position = ctx.clone_position(position),
      build_direction = final_direction_name and ctx.direction_by_name[final_direction_name] or ctx.direction_by_name.east
    }
  end

  return placements
end

local function transform_offset_positions(origin_position, offsets, orientation, ctx)
  local positions = {}

  for _, offset in ipairs(offsets or {}) do
    local rotated_offset = ctx.rotate_offset(offset, orientation)
    positions[#positions + 1] = {
      x = origin_position.x + rotated_offset.x,
      y = origin_position.y + rotated_offset.y
    }
  end

  return positions
end

local function build_power_bridge_positions(surface, force, source_position, target_position, pole_name, ctx)
  local max_link_distance = 5.5
  local max_link_distance_squared = max_link_distance * max_link_distance
  if ctx.square_distance(source_position, target_position) <= max_link_distance_squared then
    return {}
  end

  local source = snap_position_to_tile_center(source_position)
  local target = snap_position_to_tile_center(target_position)
  local search_margin = 12
  local min_x = math.min(source.x, target.x) - search_margin
  local max_x = math.max(source.x, target.x) + search_margin
  local min_y = math.min(source.y, target.y) - search_margin
  local max_y = math.max(source.y, target.y) + search_margin
  local steps = {
    {x = 5, y = 0},
    {x = -5, y = 0},
    {x = 0, y = 5},
    {x = 0, y = -5},
    {x = 5, y = 5},
    {x = 5, y = -5},
    {x = -5, y = 5},
    {x = -5, y = -5}
  }

  local function in_bounds(position)
    return position.x >= min_x and position.x <= max_x and position.y >= min_y and position.y <= max_y
  end

  local function position_key(position)
    return string.format("%.2f:%.2f", position.x, position.y)
  end

  local function parse_position_key(key)
    local x_string, y_string = string.match(key, "^([^:]+):([^:]+)$")
    return {
      x = tonumber(x_string),
      y = tonumber(y_string)
    }
  end

  local queue = {source}
  local head = 1
  local parents = {}
  local visited = {
    [position_key(source)] = true
  }
  local goal_key = nil

  while head <= #queue do
    local current = queue[head]
    head = head + 1

    for _, step in ipairs(steps) do
      local next_position = snap_position_to_tile_center{
        x = current.x + step.x,
        y = current.y + step.y
      }
      local next_key = position_key(next_position)

      if not visited[next_key] and in_bounds(next_position) then
        visited[next_key] = true

        if ctx.square_distance(next_position, target) <= max_link_distance_squared then
          parents[next_key] = position_key(current)
          goal_key = next_key
          head = #queue + 1
          break
        end

        if surface.can_place_entity{
          name = pole_name,
          position = next_position,
          force = force
        } then
          parents[next_key] = position_key(current)
          queue[#queue + 1] = next_position
        end
      end
    end
  end

  if not goal_key then
    return nil
  end

  local positions = {}
  local current_key = goal_key
  while current_key do
    local parent_key = parents[current_key]
    if not parent_key then
      break
    end

    local current_position = parse_position_key(current_key)
    if ctx.square_distance(current_position, target) > max_link_distance_squared then
      positions[#positions + 1] = current_position
    end

    if parent_key == position_key(source) then
      break
    end
    current_key = parent_key
  end

  local ordered_positions = {}
  for index = #positions, 1, -1 do
    ordered_positions[#ordered_positions + 1] = positions[index]
  end

  return ordered_positions
end

local function any_entity_contains_point(entities, point, ctx)
  for _, entity in ipairs(entities or {}) do
    if entity_contains_point(entity, point, ctx) then
      return true
    end
  end

  return false
end

local function try_set_probe_recipe(entity, recipe_name)
  if not (entity and entity.valid and recipe_name and entity.set_recipe) then
    return false, "entity-or-recipe-missing"
  end

  local ok, result = pcall(function()
    return entity.set_recipe(recipe_name)
  end)
  if ok then
    if result ~= false then
      return true, nil
    end
    return false, "set_recipe returned false"
  end

  local first_error = tostring(result)
  ok, result = pcall(function()
    return entity.set_recipe(recipe_name, "normal")
  end)
  if ok and result ~= false then
    return true, nil
  end

  local second_error = ok and "set_recipe returned false with quality" or tostring(result)
  return false, first_error .. " / " .. second_error
end

local function try_probe_layout_entity(surface, force, placement, task, summary, ctx)
  summary.positions_checked = summary.positions_checked + 1

  if not surface.can_place_entity{
    name = placement.entity_name,
    position = placement.build_position,
    direction = placement.build_direction,
    force = force
  } then
    return nil
  end

  summary.placeable_positions = summary.placeable_positions + 1

  local probe_entity = surface.create_entity{
    name = placement.entity_name,
    position = placement.build_position,
    direction = placement.build_direction,
    force = force,
    create_build_effect_smoke = false,
    raise_built = false
  }

  if not probe_entity then
    return nil
  end

  if task.forbid_resource_overlap and entity_refs.entity_overlaps_resources(probe_entity) then
    summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
    probe_entity.destroy()
    return nil
  end

  if placement.recipe_name then
    local recipe_set, recipe_error = try_set_probe_recipe(probe_entity, placement.recipe_name)
    if not recipe_set then
      summary.recipe_unavailable_rejections = (summary.recipe_unavailable_rejections or 0) + 1
      if summary.recipe_unavailable_rejections <= 5 then
        ctx.debug_log(
          "assembly probe recipe failure for " .. placement.entity_name ..
          " recipe=" .. placement.recipe_name ..
          " enabled=" .. tostring(
            force and force.recipes and force.recipes[placement.recipe_name] and force.recipes[placement.recipe_name].enabled
          ) ..
          " categories=" .. table.concat((probe_entity.prototype and probe_entity.prototype.crafting_categories) or {}, ",") ..
          " reason=" .. tostring(recipe_error)
        )
      end
      probe_entity.destroy()
      return nil
    end
  end

  return probe_entity
end

local function build_assembly_block_candidate(surface, force, build_position, orientation, anchor_entity, power_anchor_pole, source_sites_by_item, task, summary, ctx)
  local assembly_target = task.assembly_target
  local placements = {}
  local probe_entities = {}
  local probe_entities_by_id = {}
  local route_belt_entities = {}
  local local_pole_by_id = {}

  local function destroy_probes()
    entity_refs.destroy_entities(probe_entities)
  end

  local function add_probe(placement)
    local probe_entity = try_probe_layout_entity(surface, force, placement, task, summary, ctx)
    if not probe_entity then
      if (summary.failed_source_routes or 0) < 5 then
        ctx.debug_log(
          "assembly probe blocked for " .. placement.id ..
          " (" .. placement.entity_name .. ") at " .. ctx.format_position(placement.build_position) ..
          " orientation=" .. tostring(orientation)
        )
      end
      return false
    end

    probe_entities[#probe_entities + 1] = probe_entity
    probe_entities_by_id[placement.id] = probe_entity
    placements[#placements + 1] = placement
    return true
  end

  for _, pole_spec in ipairs(assembly_target.local_poles or {}) do
    local rotated_offset = ctx.rotate_offset(pole_spec.offset, orientation)
    local placement = {
      id = pole_spec.id,
      site_role = pole_spec.site_role,
      entity_name = pole_spec.entity_name,
      item_name = pole_spec.item_name or pole_spec.entity_name,
      build_position = {
        x = build_position.x + rotated_offset.x,
        y = build_position.y + rotated_offset.y
      }
    }

    if not add_probe(placement) then
      destroy_probes()
      return nil
    end

    if pole_spec.is_power_entry then
      local_pole_by_id.power_entry = probe_entities_by_id[pole_spec.id]
    end
  end

  for _, node_spec in ipairs(assembly_target.assembler_nodes or {}) do
    local rotated_offset = ctx.rotate_offset(node_spec.offset, orientation)
    local placement = {
      id = node_spec.id,
      site_role = node_spec.site_role,
      entity_name = node_spec.entity_name,
      item_name = node_spec.item_name or node_spec.entity_name,
      recipe_name = node_spec.recipe_name,
      build_position = {
        x = build_position.x + rotated_offset.x,
        y = build_position.y + rotated_offset.y
      }
    }

    if not add_probe(placement) then
      destroy_probes()
      return nil
    end
  end

  for _, route_spec in ipairs(assembly_target.raw_input_routes or {}) do
    local local_belt_positions = transform_offset_positions(build_position, route_spec.local_belt_offsets, orientation, ctx)
    local belt_placements = create_ordered_belt_placements_from_positions(
      local_belt_positions,
      task,
      route_spec.id .. "-local-belt",
      "assembly-input-belt",
      route_spec.local_belt_direction_name and ctx.rotate_direction_name(route_spec.local_belt_direction_name, orientation) or nil,
      ctx
    )
    route_belt_entities[route_spec.id] = {}
    for _, placement in ipairs(belt_placements) do
      placement.route_id = route_spec.id
    end

    for _, placement in ipairs(belt_placements) do
      if not add_probe(placement) then
        destroy_probes()
        return nil
      end

      route_belt_entities[route_spec.id][#route_belt_entities[route_spec.id] + 1] = probe_entities_by_id[placement.id]
    end

    for _, inserter_spec in ipairs(route_spec.input_inserters or {}) do
      local rotated_offset = ctx.rotate_offset(inserter_spec.offset, orientation)
      local direction_name = ctx.rotate_direction_name(inserter_spec.direction_name, orientation)
      local placement = {
        id = inserter_spec.id,
        site_role = inserter_spec.site_role,
        entity_name = inserter_spec.entity_name,
        item_name = inserter_spec.item_name or inserter_spec.entity_name,
        build_position = {
          x = build_position.x + rotated_offset.x,
          y = build_position.y + rotated_offset.y
        },
        build_direction = direction_name and ctx.direction_by_name[direction_name] or nil,
        fuel = inserter_spec.fuel,
        target_node_id = inserter_spec.target_node_id,
        route_id = route_spec.id
      }

      if not add_probe(placement) then
        destroy_probes()
        return nil
      end
    end
  end

  for _, inserter_spec in ipairs(assembly_target.internal_inserters or {}) do
    local rotated_offset = ctx.rotate_offset(inserter_spec.offset, orientation)
    local direction_name = ctx.rotate_direction_name(inserter_spec.direction_name, orientation)
    local placement = {
      id = inserter_spec.id,
      site_role = inserter_spec.site_role,
      entity_name = inserter_spec.entity_name,
      item_name = inserter_spec.item_name or inserter_spec.entity_name,
      build_position = {
        x = build_position.x + rotated_offset.x,
        y = build_position.y + rotated_offset.y
      },
      build_direction = direction_name and ctx.direction_by_name[direction_name] or nil,
      fuel = inserter_spec.fuel,
      source_node_id = inserter_spec.source_node_id,
      target_node_id = inserter_spec.target_node_id
    }

    if not add_probe(placement) then
      destroy_probes()
      return nil
    end
  end

  for _, inserter_spec in ipairs(assembly_target.internal_inserters or {}) do
    local probe_inserter = probe_entities_by_id[inserter_spec.id]
    local source_node = probe_entities_by_id[inserter_spec.source_node_id]
    local target_node = probe_entities_by_id[inserter_spec.target_node_id]
    if not (probe_inserter and source_node and target_node) or
      not entity_contains_point(source_node, probe_inserter.pickup_position, ctx) or
      not entity_contains_point(target_node, probe_inserter.drop_position, ctx)
    then
      summary.failed_inserter_geometry = (summary.failed_inserter_geometry or 0) + 1
      if summary.failed_inserter_geometry <= 5 then
        ctx.debug_log(
          "assembly internal geometry failure: inserter=" .. inserter_spec.id ..
          " pos=" .. ctx.format_position(probe_inserter and probe_inserter.position or {x = 0, y = 0}) ..
          " pickup=" .. ctx.format_position(probe_inserter and probe_inserter.pickup_position or {x = 0, y = 0}) ..
          " drop=" .. ctx.format_position(probe_inserter and probe_inserter.drop_position or {x = 0, y = 0}) ..
          " source=" .. ctx.format_position(source_node and source_node.position or {x = 0, y = 0}) ..
          " target=" .. ctx.format_position(target_node and target_node.position or {x = 0, y = 0}) ..
          " orientation=" .. tostring(orientation)
        )
      end
      destroy_probes()
      return nil
    end
  end

  for _, route_spec in ipairs(assembly_target.raw_input_routes or {}) do
    for _, inserter_spec in ipairs(route_spec.input_inserters or {}) do
      local probe_inserter = probe_entities_by_id[inserter_spec.id]
      local target_node = probe_entities_by_id[inserter_spec.target_node_id]
      local source_belts = route_belt_entities[route_spec.id]
      if not (probe_inserter and target_node) or
        not any_entity_contains_point(source_belts, probe_inserter.pickup_position, ctx) or
        not entity_contains_point(target_node, probe_inserter.drop_position, ctx)
      then
        summary.failed_inserter_geometry = (summary.failed_inserter_geometry or 0) + 1
        if summary.failed_inserter_geometry <= 5 then
          ctx.debug_log(
            "assembly input geometry failure: inserter=" .. inserter_spec.id ..
            " pos=" .. ctx.format_position(probe_inserter and probe_inserter.position or {x = 0, y = 0}) ..
            " pickup=" .. ctx.format_position(probe_inserter and probe_inserter.pickup_position or {x = 0, y = 0}) ..
            " drop=" .. ctx.format_position(probe_inserter and probe_inserter.drop_position or {x = 0, y = 0}) ..
            " target=" .. ctx.format_position(target_node and target_node.position or {x = 0, y = 0}) ..
            " orientation=" .. tostring(orientation) ..
            " route=" .. route_spec.id
          )
        end
        destroy_probes()
        return nil
      end
    end
  end

  local entry_pole = local_pole_by_id.power_entry
  if not (entry_pole and entry_pole.valid) then
    destroy_probes()
    return nil
  end

  local bridge_positions = build_power_bridge_positions(
    surface,
    force,
    power_anchor_pole.position,
    entry_pole.position,
    assembly_target.power_anchor_entity_name,
    ctx
  )

  if bridge_positions == nil then
    summary.failed_power_bridge = (summary.failed_power_bridge or 0) + 1
    destroy_probes()
    return nil
  end

  for bridge_index, bridge_position in ipairs(bridge_positions) do
    local placement = {
      id = "power-bridge-" .. tostring(bridge_index),
      site_role = "power-pole",
      entity_name = assembly_target.power_anchor_entity_name,
      item_name = assembly_target.power_anchor_entity_name,
      build_position = bridge_position
    }

    if not add_probe(placement) then
      summary.failed_power_bridge = (summary.failed_power_bridge or 0) + 1
      destroy_probes()
      return nil
    end
  end

  local source_network_id = power_anchor_pole.electric_network_id or 0
  for _, node_spec in ipairs(assembly_target.assembler_nodes or {}) do
    local probe_assembler = probe_entities_by_id[node_spec.id]
    if not (probe_assembler and probe_assembler.valid and probe_assembler.electric_network_id and probe_assembler.electric_network_id ~= 0) then
      summary.failed_power_network = (summary.failed_power_network or 0) + 1
      destroy_probes()
      return nil
    end

    if source_network_id ~= 0 and probe_assembler.electric_network_id ~= source_network_id then
      summary.failed_power_network = (summary.failed_power_network or 0) + 1
      destroy_probes()
      return nil
    end
  end

  destroy_probes()
  return {
    anchor_entity = anchor_entity,
    power_anchor_pole = power_anchor_pole,
    build_position = ctx.clone_position(build_position),
    placements = placements
  }
end

local function get_production_site_identity_key(site)
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

local function get_assembly_route_target_position(local_connection_entity, ctx)
  if not (local_connection_entity and local_connection_entity.valid) then
    return nil
  end

  local direction_vector = get_direction_vector_from_direction(local_connection_entity.direction, ctx)
  return {
    x = local_connection_entity.position.x - direction_vector.x,
    y = local_connection_entity.position.y - direction_vector.y
  }
end

function queries.find_assembly_input_route_site(builder_state, task, ctx)
  local builder = builder_state.entity
  local anchor_origin = task.manual_anchor_position or builder.position
  local summary = {
    anchor_entities_considered = 0,
    anchors_skipped_blocked = 0,
    anchors_skipped_registered = 0,
    positions_checked = 0,
    placeable_positions = 0,
    resource_overlap_rejections = 0,
    failed_belt_paths = 0,
    failed_source_extractors = 0,
    source_sites_considered = 0,
    failed_anchor_entity = nil
  }

  local production_sites = storage_helpers.ensure_production_sites()
  local assembly_sites = {}

  for _, site in ipairs(production_sites) do
    if site.site_type == "assembly-block" and site.root_assembler and site.root_assembler.valid then
      assembly_sites[#assembly_sites + 1] = {
        site = site,
        anchor_entity = site.root_assembler,
        distance = ctx.square_distance(anchor_origin, site.root_assembler.position)
      }
    end
  end

  table.sort(assembly_sites, function(left, right)
    return left.distance < right.distance
  end)

  local max_anchor_entities = task.max_anchor_entities or #assembly_sites
  for attempt = 1, 2 do
    for _, assembly_candidate in ipairs(assembly_sites) do
      if summary.anchor_entities_considered >= max_anchor_entities then
        break
      end

      local assembly_site = assembly_candidate.site
      local anchor_entity = assembly_candidate.anchor_entity
      local route_spec = assembly_site.route_specs_by_id and assembly_site.route_specs_by_id[task.route_id] or nil

      if route_spec then
        if anchor_is_blocked_for_layout(builder_state, task, anchor_entity) then
          summary.anchors_skipped_blocked = summary.anchors_skipped_blocked + 1
        elseif assembly_site.route_connections_by_id and assembly_site.route_connections_by_id[task.route_id] then
          summary.anchors_skipped_registered = summary.anchors_skipped_registered + 1
        else
          local local_route_belts = assembly_site.route_local_belts_by_id and assembly_site.route_local_belts_by_id[task.route_id] or nil
          local local_connection_entity = local_route_belts and local_route_belts[1] or nil
          local route_target_position = get_assembly_route_target_position(local_connection_entity, ctx)

          if local_connection_entity and route_target_position then
            summary.anchor_entities_considered = summary.anchor_entities_considered + 1
            summary.failed_anchor_entity = anchor_entity

            local used_source_site_keys = {}
            for _, connection in pairs(assembly_site.route_connections_by_id or {}) do
              if connection.source_site_key then
                used_source_site_keys[connection.source_site_key] = true
              end
            end

            local source_candidates = {}
            for _, source_site in ipairs(production_sites) do
              if source_site.site_type == "smelting-output-belt" and get_site_output_item_name(source_site) == route_spec.item_name then
                local source_site_key = get_production_site_identity_key(source_site)
                if not used_source_site_keys[source_site_key] then
                  for _, route_start in ipairs(get_output_belt_connection_positions(source_site, ctx)) do
                    source_candidates[#source_candidates + 1] = {
                      site = source_site,
                      source_site_key = source_site_key,
                      route_start_position = route_start.position,
                      source_terminal_belt = route_start.terminal_belt,
                      distance = ctx.square_distance(route_start.position, route_target_position)
                    }
                  end
                end
              end
            end

            table.sort(source_candidates, function(left, right)
              return left.distance < right.distance
            end)

            summary.source_sites_considered = summary.source_sites_considered + #source_candidates

            for _, candidate in ipairs(source_candidates) do
              local source_entry_options = build_source_route_entry_options(
                builder.surface,
                builder.force,
                candidate.source_terminal_belt,
                route_target_position,
                task,
                summary,
                ctx
              )

              for _, source_entry in ipairs(source_entry_options) do
                local route_placements = build_belt_path_placements_between_positions(
                  builder.surface,
                  builder.force,
                  source_entry.path_start_position,
                  route_target_position,
                  task,
                  summary,
                  nil,
                  ctx
                )

                if route_placements and #route_placements > 0 then
                  for _, prefix_placement in ipairs(source_entry.prefix_placements or {}) do
                    table.insert(route_placements, 1, prefix_placement)
                  end
                  for _, suffix_placement in ipairs(source_entry.suffix_placements or {}) do
                    route_placements[#route_placements + 1] = suffix_placement
                  end

                  local last_route_placement = route_placements[#route_placements]
                  if last_route_placement.site_role == "assembly-source-inserter" and #route_placements > 1 then
                    last_route_placement = route_placements[#route_placements - 1]
                  end
                  local direction_name = get_direction_name_from_delta(
                    local_connection_entity.position.x - last_route_placement.build_position.x,
                    local_connection_entity.position.y - last_route_placement.build_position.y
                  )
                  if direction_name then
                    last_route_placement.build_direction = ctx.direction_by_name[direction_name]
                  end

                  for placement_index, route_placement in ipairs(route_placements) do
                    route_placement.id = task.route_id .. "-source-belt-" .. tostring(placement_index)
                    route_placement.route_id = task.route_id
                    route_placement.site_role = route_placement.site_role or "assembly-source-belt"
                  end

                  return {
                    assembly_site = assembly_site,
                    anchor_entity = anchor_entity,
                    build_position = ctx.clone_position(route_placements[1].build_position),
                    placements = route_placements,
                    route_id = task.route_id,
                    route_spec = route_spec,
                    source_site = candidate.site,
                    summary = summary
                  }, summary
                end
              end
            end

            summary.failed_belt_paths = (summary.failed_belt_paths or 0) + 1
            if (summary.failed_belt_paths or 0) <= 5 then
              ctx.debug_log(
                "assembly source route failed for " .. tostring(task.route_id) ..
                " item=" .. tostring(route_spec.item_name) ..
                " target=" .. ctx.format_position(route_target_position) ..
                " candidates=" .. tostring(#source_candidates)
              )
            end
          end
        end
      end
    end

    if not (attempt == 1 and should_retry_cleared_anchor_blocks(builder_state, task, summary, ctx)) then
      break
    end
  end

  return nil, summary
end

function queries.find_assembly_block_site(builder_state, task, ctx)
  local builder = builder_state.entity
  local assembly_target = task.assembly_target
  local anchor_origin = task.manual_anchor_position or builder.position
  local summary = {
    anchor_entities_considered = 0,
    anchors_skipped_registered = 0,
    anchors_skipped_blocked = 0,
    anchors_missing_power = 0,
    missing_source_items = {},
    clearance_headings_considered = 0,
    clearance_origins_found = 0,
    orientations_considered = 0,
    positions_checked = 0,
    placeable_positions = 0,
    resource_overlap_rejections = 0,
    failed_inserter_geometry = 0,
    failed_power_bridge = 0,
    failed_power_network = 0,
    failed_source_routes = 0,
    source_sites_considered = 0,
    recipe_unavailable_rejections = 0,
    failed_anchor_entity = nil
  }

  if not (assembly_target and assembly_target.assembler_nodes and #assembly_target.assembler_nodes > 0) then
    return nil, summary
  end

  local anchor_candidates = {}
  if assembly_target.anchor_mode == "source-cluster" then
    anchor_candidates = build_source_cluster_anchor_candidates(builder_state, task, summary, ctx)
  else
    for _, anchor_entity in ipairs(builder.surface.find_entities_filtered{
      force = builder.force,
      name = task.anchor_entity_names or assembly_target.anchor_entity_names
    }) do
      anchor_candidates[#anchor_candidates + 1] = {
        anchor_entity = anchor_entity,
        distance = ctx.square_distance(anchor_origin, anchor_entity.position)
      }
    end

    table.sort(anchor_candidates, function(left, right)
      return left.distance < right.distance
    end)
  end

  local max_anchor_entities = task.max_anchor_entities or #anchor_candidates
  for attempt = 1, 2 do
    for _, anchor_candidate in ipairs(anchor_candidates) do
      if summary.anchor_entities_considered >= max_anchor_entities then
        break
      end

      local anchor_entity = anchor_candidate.anchor_entity
      if anchor_entity and anchor_entity.valid then
        if anchor_is_blocked_for_layout(builder_state, task, anchor_entity) then
          summary.anchors_skipped_blocked = summary.anchors_skipped_blocked + 1
        elseif anchor_has_registered_site(anchor_entity, task.require_missing_registered_site) then
          summary.anchors_skipped_registered = summary.anchors_skipped_registered + 1
        else
          local power_anchor_pole = anchor_candidate.power_anchor_pole
          if not power_anchor_pole then
            local power_anchor_entities = builder.surface.find_entities_filtered{
              position = anchor_entity.position,
              radius = task.power_anchor_search_radius or 16,
              force = builder.force,
              name = assembly_target.power_anchor_entity_name or task.power_anchor_entity_name
            }

            table.sort(power_anchor_entities, function(left, right)
              return ctx.square_distance(anchor_entity.position, left.position) < ctx.square_distance(anchor_entity.position, right.position)
            end)

            power_anchor_pole = power_anchor_entities[1]
          end

          if not (power_anchor_pole and power_anchor_pole.valid) then
            summary.anchors_missing_power = summary.anchors_missing_power + 1
            goto continue
          end

          summary.anchor_entities_considered = summary.anchor_entities_considered + 1
          summary.failed_anchor_entity = anchor_entity

          local search_origins
          if task.manual_target_position then
            search_origins = {{
              center = ctx.clone_position(task.manual_target_position),
              search_radius = task.manual_target_search_radius or task.placement_search_radius or 0,
              placement_step = task.manual_target_search_step or task.placement_step or 1
            }}
          elseif anchor_candidate.search_center then
            local source_cluster = assembly_target.source_cluster or task.source_cluster or {}
            search_origins = build_source_cluster_search_origins(
              anchor_candidate.search_center,
              source_cluster,
              task,
              anchor_candidate.preferred_direction_vector,
              ctx
            )
          else
            search_origins = build_resource_clearance_search_origins(
              builder.surface,
              builder.force,
              task,
              anchor_entity.position,
              summary,
              ctx
            )
          end

          local source_cluster = assembly_target.source_cluster or task.source_cluster or {}
          local minimum_build_distance = source_cluster.minimum_build_distance or 0
          local minimum_build_distance_squared = minimum_build_distance * minimum_build_distance

          for _, search_origin in ipairs(search_origins) do
            for _, orientation in ipairs(task.layout_orientations or {"north", "east", "south", "west"}) do
              summary.orientations_considered = summary.orientations_considered + 1

              for _, build_position in ipairs(ctx.build_search_positions(
                search_origin.center,
                search_origin.search_radius,
                search_origin.placement_step
              )) do
                local minimum_build_distance_reference =
                  anchor_candidate.minimum_distance_reference or
                  anchor_candidate.search_center or
                  search_origin.center
                if minimum_build_distance_squared > 0 and
                  ctx.square_distance(build_position, minimum_build_distance_reference) < minimum_build_distance_squared
                then
                  goto continue_build_position
                end

                local candidate = build_assembly_block_candidate(
                  builder.surface,
                  builder.force,
                  build_position,
                  orientation,
                  anchor_entity,
                  power_anchor_pole,
                  anchor_candidate.source_sites_by_item,
                  task,
                  summary,
                  ctx
                )

                if candidate then
                  candidate.summary = summary
                  return candidate, summary
                end

                ::continue_build_position::
              end
            end
          end
        end
      end

      ::continue::
    end

    if not (attempt == 1 and should_retry_cleared_anchor_blocks(builder_state, task, summary, ctx)) then
      break
    end
  end

  return nil, summary
end

return queries

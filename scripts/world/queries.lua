local entity_refs = require("scripts.world.entity_refs")
local sites = require("scripts.world.sites")
local storage_helpers = require("scripts.world.storage")

local queries = {}
local find_or_create_belt_hub_position
local build_output_belt_layout_for_anchor

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

  local effective_patch = patch or {
    anchor_position = ctx.clone_position(output_machine_position),
    resource_name = task.resource_name
  }
  local hub_position, patch_key = find_or_create_belt_hub_position(surface, force, effective_patch, task, stats, ctx)
  local placements = nil
  local terminal_position = nil

  if hub_position then
    placements, terminal_position = build_output_belt_layout_for_anchor(
      surface,
      force,
      probe_machine,
      hub_position,
      task,
      stats,
      ctx
    )
  end

  probe_machine.destroy()
  return placements, hub_position, patch_key, terminal_position
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
  local probe_entity = surface.create_entity{
    name = entity_name,
    position = position,
    direction = direction,
    force = force,
    create_build_effect_smoke = false,
    raise_built = false
  }

  if not probe_entity then
    return true
  end

  local overlaps_resources = entity_refs.entity_overlaps_resources(probe_entity)
  probe_entity.destroy()
  return overlaps_resources
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
    end
  end

  return search_origins
end

local function layout_fits_around_anchor_entity(builder, anchor_entity, layout_config, summary, ctx)
  if not layout_config then
    return true
  end

  if layout_config.forbid_resource_overlap and entity_refs.entity_overlaps_resources(anchor_entity) then
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

      if layout_config.forbid_resource_overlap and entity_refs.entity_overlaps_resources(probe_entity) then
        if summary then
          summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
        end
        layout_valid = false
        break
      end
    end

    entity_refs.destroy_entities(probe_entities)

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
      ctx
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

  for _, axis_order in ipairs(axis_orders) do
    local positions = build_belt_path_positions(first_position, terminal_position, axis_order, ctx)
    if not positions then
      goto continue
    end
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
        path_valid = false
        break
      end
      seen_positions[position_key] = true

      summary.positions_checked = summary.positions_checked + 1

      if not surface.can_place_entity{
        name = task.belt_entity_name,
        position = position,
        direction = direction,
        force = force
      } then
        path_valid = false
        break
      end

      summary.placeable_positions = summary.placeable_positions + 1

      if task.forbid_resource_overlap and candidate_entity_overlaps_resources(surface, force, task.belt_entity_name, position, direction) then
        summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
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

    ::continue::
  end

  return nil
end

local function validate_output_inserter_geometry(surface, force, output_machine, inserter_position, inserter_direction, first_belt_placement, task, ctx)
  if not surface.can_place_entity{
    name = task.output_inserter.entity_name,
    position = inserter_position,
    direction = inserter_direction,
    force = force
  } then
    return false
  end

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
        ctx
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
          local placements = {
            {
              id = "output-inserter",
              site_role = "output-inserter",
              entity_name = task.output_inserter.entity_name,
              item_name = task.output_inserter.item_name or task.output_inserter.entity_name,
              build_position = ctx.clone_position(edge_candidate.inserter_position),
              build_direction = inserter_direction,
              fuel = task.output_inserter.fuel
            }
          }

          for _, placement in ipairs(belt_placements) do
            placements[#placements + 1] = placement
          end

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
    downstream_anchor_hits = 0,
    terminal_positions_found = 0,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0,
    resource_overlap_rejections = 0
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
          local belt_layout_placements = nil
          local belt_hub_position = nil
          local belt_hub_key = nil
          local belt_terminal_position = nil
          local has_output_belt_layout = true

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

            if has_output_container_spot and downstream_machine_position and task.output_inserter and task.belt_entity_name then
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
      selected_candidate.belt_layout_placements,
      selected_candidate.belt_hub_position,
      selected_candidate.belt_hub_key,
      selected_candidate.belt_terminal_position,
      stats
  end

  return nil, nil, nil, nil, nil, nil, nil, nil, stats
end

function queries.find_resource_site(surface, force, origin, task, ctx)
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
    downstream_anchor_hits = 0,
    terminal_positions_found = 0,
    valid_belt_paths = 0,
    failed_belt_paths = 0,
    failed_inserter_geometry = 0,
    resource_overlap_rejections = 0
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
        summary.terminal_positions_found = summary.terminal_positions_found + (placement_stats.terminal_positions_found or 0)
        summary.valid_belt_paths = summary.valid_belt_paths + (placement_stats.valid_belt_paths or 0)
        summary.failed_belt_paths = summary.failed_belt_paths + (placement_stats.failed_belt_paths or 0)
        summary.failed_inserter_geometry = summary.failed_inserter_geometry + (placement_stats.failed_inserter_geometry or 0)
        summary.resource_overlap_rejections = summary.resource_overlap_rejections + (placement_stats.resource_overlap_rejections or 0)

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
        summary.terminal_positions_found = summary.terminal_positions_found + (placement_stats.terminal_positions_found or 0)
        summary.valid_belt_paths = summary.valid_belt_paths + (placement_stats.valid_belt_paths or 0)
        summary.failed_belt_paths = summary.failed_belt_paths + (placement_stats.failed_belt_paths or 0)
        summary.failed_inserter_geometry = summary.failed_inserter_geometry + (placement_stats.failed_inserter_geometry or 0)
        summary.resource_overlap_rejections = summary.resource_overlap_rejections + (placement_stats.resource_overlap_rejections or 0)

        if build_position then
          site_candidates[#site_candidates + 1] = {
            resource = resource,
            build_position = build_position,
            build_direction = build_direction,
            output_container_position = output_container_position,
            downstream_machine_position = downstream_machine_position,
            belt_layout_placements = belt_layout_placements,
            belt_hub_position = belt_hub_position,
            belt_hub_key = belt_hub_key,
            belt_terminal_position = belt_terminal_position,
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

function queries.find_nearest_resource(surface, origin, task, ctx)
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
          local hub_position, patch_key = find_or_create_belt_hub_position(
            builder.surface,
            builder.force,
            patch,
            task,
            summary,
            ctx
          )

          if hub_position then
            local placements, terminal_position = build_output_belt_layout_for_anchor(
              builder.surface,
              builder.force,
              anchor_entity,
              hub_position,
              task,
              summary,
              ctx
            )

            if placements and #placements > 0 then
              return {
                site = anchor_candidate.site,
                anchor_entity = anchor_entity,
                anchor_position = ctx.clone_position(anchor_entity.position),
                build_position = ctx.clone_position(anchor_entity.position),
                hub_position = hub_position,
                hub_key = patch_key,
                belt_terminal_position = terminal_position,
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

return queries

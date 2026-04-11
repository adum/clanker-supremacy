local entity_refs = require("scripts.world.entity_refs")
local sites = require("scripts.world.sites")
local storage_helpers = require("scripts.world.storage")

local queries = {}

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

function queries.find_layout_site_near_machine(builder_state, task, ctx)
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
      if anchor_has_registered_site(anchor_entity, task.require_missing_registered_site) then
        summary.anchors_skipped_registered = summary.anchors_skipped_registered + 1
      else
        summary.anchor_entities_considered = summary.anchor_entities_considered + 1

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

return queries

local action_start = {}

local function start_place_miner_task(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local search_origin = task.manual_search_origin or entity.position
  ctx.debug_log("task " .. task.id .. ": scanning for " .. task.resource_name .. " from " .. ctx.format_position(search_origin))
  local site, search_summary = ctx.find_resource_site(entity.surface, entity.force, search_origin, task)

  if not site then
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = "no-build-site",
      next_attempt_tick = tick + task.search_retry_ticks
    }
    ctx.debug_log(
      "task " .. task.id .. ": no buildable " .. task.miner_name .. " site found for " .. task.resource_name ..
      "; checked " .. search_summary.resources_considered .. " resource tiles and " ..
      search_summary.patch_centers_considered .. " patch centers, " ..
      search_summary.positions_checked .. " candidate positions, " ..
      search_summary.placeable_positions .. " placeable spots, " ..
      search_summary.test_miners_created .. " probe drills, " ..
      search_summary.mining_area_hits .. " mining-area hits, " ..
      search_summary.valid_candidates .. " valid sites, best coverage " .. search_summary.best_resource_coverage .. ", " ..
      search_summary.downstream_anchor_hits .. " downstream-machine hits, " ..
      search_summary.output_container_hits .. " output-container hits; retry at tick " ..
      builder_state.task_state.next_attempt_tick
    )
    return
  end

  local resource = site.resource
  local build_position = site.build_position
  local build_direction = site.build_direction
  local downstream_machine_position = site.downstream_machine_position
  local output_container_position = site.output_container_position

  builder_state.task_state = {
    phase = "moving",
    resource_position = ctx.clone_position(resource.position),
    build_position = build_position,
    approach_position = ctx.create_task_approach_position(task, build_position),
    build_direction = build_direction,
    downstream_machine_position = downstream_machine_position,
    output_container_position = output_container_position,
    last_position = ctx.clone_position(entity.position),
    last_progress_tick = tick
  }
  ctx.builder_runtime.clear_task_retry_state(builder_state, task)
  ctx.debug_log(
    "task " .. task.id .. ": found build site for " .. task.resource_name .. " at " ..
    ctx.format_position((site.selected_from_patch_center and site.anchor_position) or resource.position) ..
    (site.selected_from_patch_center and " via patch center" or "") ..
    " after checking " .. site.summary.resources_considered ..
    " resource tiles and " .. tostring(site.summary.patch_centers_considered or 0) .. " patch centers; chose coverage " ..
    tostring(site.resource_coverage or site.summary.best_resource_coverage or 0) ..
    " from " .. tostring(site.summary.selected_candidate_pool_size or 1) ..
    " preferred candidates; moving toward " .. ctx.format_position(build_position) ..
    (downstream_machine_position and " with " .. task.downstream_machine.name .. " at " .. ctx.format_position(downstream_machine_position) or "") ..
    (output_container_position and " with output container at " .. ctx.format_position(output_container_position) or "")
  )
end

local function start_gather_world_items_task(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local search_origin = task.manual_search_origin or entity.position
  local inventory_target, current_count = ctx.get_missing_inventory_target(entity, task.inventory_targets)

  if not inventory_target then
    ctx.complete_current_task(
      builder_state,
      task,
      "inventory goals met (" .. ctx.inventory_targets_summary(entity, task.inventory_targets) .. ")"
    )
    return
  end

  ctx.debug_log(
    "task " .. task.id .. ": need " .. inventory_target.name .. " " ..
    current_count .. "/" .. inventory_target.count
  )

  local gather_site = ctx.find_gather_site(entity.surface, search_origin, task, inventory_target.name)
  if not gather_site then
    builder_state.task_state = {
      phase = "waiting-for-source",
      wait_reason = "no-source",
      target_item_name = inventory_target.name,
      next_attempt_tick = tick + task.search_retry_ticks
    }
    ctx.debug_log(
      "task " .. task.id .. ": no gather source found for " .. inventory_target.name ..
      "; retry at tick " .. builder_state.task_state.next_attempt_tick
    )
    return
  end

  builder_state.task_state = {
    phase = "moving-to-source",
    source_id = gather_site.source.id,
    target_item_name = inventory_target.name,
    target_kind = gather_site.target_kind,
    target_name = gather_site.target_name,
    target_entity = gather_site.entity,
    target_decorative_position = gather_site.decorative_position,
    target_position = ctx.clone_position(gather_site.target_position),
    approach_position = ctx.create_task_approach_position(task, gather_site.target_position),
    harvest_products = gather_site.source.yields,
    mining_duration_ticks = gather_site.source.mining_duration_ticks or task.mining_duration_ticks,
    last_position = ctx.clone_position(entity.position),
    last_progress_tick = tick
  }
  ctx.builder_runtime.clear_task_retry_state(builder_state, task)

  ctx.debug_log(
    "task " .. task.id .. ": moving to " .. gather_site.source.id .. " at " ..
    ctx.format_position(gather_site.target_position) ..
    (gather_site.target_name and " (" .. gather_site.target_name .. ")" or "") ..
    " to gather " .. ctx.format_products(gather_site.source.yields)
  )
end

local function start_move_to_resource_task(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local search_origin = task.manual_search_origin or entity.position
  ctx.debug_log("task " .. task.id .. ": scanning for " .. task.resource_name .. " from " .. ctx.format_position(search_origin))

  local resource = ctx.find_nearest_resource(entity.surface, search_origin, task)
  if not resource then
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = "no-resource",
      next_attempt_tick = tick + task.search_retry_ticks
    }
    ctx.debug_log(
      "task " .. task.id .. ": no " .. task.resource_name ..
      " resource found; retry at tick " .. builder_state.task_state.next_attempt_tick
    )
    return
  end

  builder_state.task_state = {
    phase = "moving-to-resource",
    resource_position = ctx.clone_position(resource.position),
    target_position = ctx.clone_position(resource.position),
    approach_position = ctx.create_task_approach_position(task, resource.position),
    last_position = ctx.clone_position(entity.position),
    last_progress_tick = tick
  }
  ctx.builder_runtime.clear_task_retry_state(builder_state, task)
  ctx.debug_log(
    "task " .. task.id .. ": moving to " .. task.resource_name ..
    " at " .. ctx.format_position(resource.position)
  )
end

local function start_place_machine_near_site_task(builder_state, task, tick, ctx)
  local entity = builder_state.entity

  if task.manual_target_position then
    builder_state.task_state = {
      phase = "moving",
      build_position = ctx.clone_position(task.manual_target_position),
      approach_position = ctx.create_task_approach_position(task, task.manual_target_position),
      build_direction = task.manual_direction,
      anchor_position = ctx.clone_position(task.manual_target_position),
      anchor_pattern_name = task.manual_component_name or task.scaling_pattern_name or task.pattern_name,
      last_position = ctx.clone_position(entity.position),
      last_progress_tick = tick
    }
    ctx.builder_runtime.clear_task_retry_state(builder_state, task)

    ctx.debug_log(
      "task " .. task.id .. ": using manual build position for " .. task.entity_name ..
      " at " .. ctx.format_position(task.manual_target_position)
    )
    return
  end

  ctx.debug_log(
    "task " .. task.id .. ": scanning for " .. task.entity_name ..
    " placement near " .. table.concat(task.anchor_pattern_names or {}, ", ") ..
    " from " .. ctx.format_position(entity.position)
  )

  local site, summary = ctx.find_machine_site_near_resource_sites(builder_state, task)
  if not site then
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = "no-machine-site",
      next_attempt_tick = tick + task.search_retry_ticks
    }
    ctx.debug_log(
      "task " .. task.id .. ": no buildable " .. task.entity_name ..
      " site found near anchor sites; checked " .. summary.anchor_sites_considered ..
      " anchors, " .. summary.positions_checked .. " candidate positions, " ..
      summary.placeable_positions .. " placeable spots, " ..
      (summary.resource_overlap_rejections or 0) .. " resource-overlap rejections, " ..
      (summary.layout_reservation_rejections or 0) .. " layout-fit rejections; retry at tick " ..
      builder_state.task_state.next_attempt_tick
    )
    return
  end

  builder_state.task_state = {
    phase = "moving",
    build_position = ctx.clone_position(site.build_position),
    approach_position = ctx.create_task_approach_position(task, site.build_position),
    build_direction = site.build_direction,
    anchor_position = ctx.clone_position(site.anchor_position),
    anchor_pattern_name = site.site.pattern_name,
    last_position = ctx.clone_position(entity.position),
    last_progress_tick = tick
  }
  ctx.builder_runtime.clear_task_retry_state(builder_state, task)

  ctx.debug_log(
    "task " .. task.id .. ": found build site for " .. task.entity_name ..
    " near " .. (site.site.pattern_name or "resource site") ..
    " at " .. ctx.format_position(site.anchor_position) ..
    "; moving toward " .. ctx.format_position(site.build_position)
  )
end

local function start_place_layout_near_machine_task(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local anchor_description = task.anchor_pattern_names and #task.anchor_pattern_names > 0 and
    table.concat(task.anchor_pattern_names, ", ") or
    table.concat(ctx.get_task_anchor_entity_names(task) or {}, ", ")
  ctx.debug_log(
    "task " .. task.id .. ": scanning for layout anchor " ..
    anchor_description ..
    " from " .. ctx.format_position(entity.position)
  )

  local site, summary = ctx.find_layout_site_near_machine(builder_state, task)
  if not site then
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = "no-layout-site",
      next_attempt_tick = tick + task.search_retry_ticks
    }
    ctx.debug_log(
      "task " .. task.id .. ": no layout site found; checked " ..
      summary.anchor_entities_considered .. " anchors, " ..
      (summary.anchors_skipped_registered or 0) .. " anchors already registered, " ..
      summary.orientations_considered .. " orientations, " ..
      summary.layout_elements_checked .. " layout elements, " ..
      summary.positions_checked .. " candidate positions, " ..
      summary.placeable_positions .. " placeable spots, " ..
      (summary.resource_overlap_rejections or 0) .. " resource-overlap rejections; retry at tick " ..
      builder_state.task_state.next_attempt_tick
    )
    return
  end

  builder_state.task_state = {
    phase = "moving",
    build_position = ctx.clone_position(site.build_position),
    approach_position = ctx.create_task_approach_position(task, site.build_position),
    anchor_position = ctx.clone_position(site.anchor_position),
    anchor_entity = site.anchor_entity,
    anchor_site = site.site,
    layout_orientation = site.orientation,
    layout_placements = site.placements,
    layout_index = 1,
    placed_layout_entities = {},
    last_position = ctx.clone_position(entity.position),
    last_progress_tick = tick
  }
  ctx.builder_runtime.clear_task_retry_state(builder_state, task)

  ctx.debug_log(
    "task " .. task.id .. ": found layout near " .. site.anchor_entity.name ..
    " at " .. ctx.format_position(site.anchor_position) ..
    " using orientation " .. tostring(site.orientation) ..
    "; moving toward " .. ctx.format_position(site.build_position)
  )
end

function action_start.start_task(builder_state, task, tick, ctx)
  if task.type == "place-miner-on-resource" then
    start_place_miner_task(builder_state, task, tick, ctx)
    return
  end

  if task.type == "gather-world-items" then
    start_gather_world_items_task(builder_state, task, tick, ctx)
    return
  end

  if task.type == "move-to-resource" then
    start_move_to_resource_task(builder_state, task, tick, ctx)
    return
  end

  if task.type == "place-machine-near-site" then
    start_place_machine_near_site_task(builder_state, task, tick, ctx)
    return
  end

  if task.type == "place-layout-near-machine" then
    start_place_layout_near_machine_task(builder_state, task, tick, ctx)
    return
  end

  ctx.complete_current_task(builder_state, task, "unsupported task type " .. task.type)
end

return action_start

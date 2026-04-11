local task_executor = {}

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

function task_executor.start_task(builder_state, task, tick, ctx)
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

function task_executor.refresh_task(builder_state, task, tick, ctx)
  local retry_key = ctx.builder_runtime.get_task_retry_key(task)
  local retry_state = ctx.builder_runtime.get_retry_state(builder_state)
  retry_state.counts[retry_key] = (retry_state.counts[retry_key] or 0) + 1

  if retry_state.counts[retry_key] > ctx.builder_runtime.get_retry_limit() then
    ctx.builder_runtime.handle_task_retry_exhausted(
      builder_state,
      task,
      tick,
      "retry limit reached for " .. retry_key
    )
    return
  end

  builder_state.task_state = nil
  ctx.builder_runtime.record_recovery(builder_state, "retrying " .. (task and (task.id or task.type) or "task"))
  ctx.debug_log("task " .. task.id .. ": retrying from " .. ctx.format_position(builder_state.entity.position))
  task_executor.start_task(builder_state, task, tick, ctx)
end

local function move_builder_to_position(builder_state, task, tick, destination_position, next_phase, approach_position, ctx)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local movement_position = approach_position or destination_position

  if ctx.square_distance(entity.position, destination_position) <= (task.arrival_distance * task.arrival_distance) then
    ctx.set_idle(entity)
    task_state.phase = next_phase
    ctx.builder_runtime.clear_recovery(builder_state)
    ctx.debug_log("task " .. task.id .. ": reached target position " .. ctx.format_position(destination_position))
    return
  end

  local delta_x = movement_position.x - entity.position.x
  local delta_y = movement_position.y - entity.position.y
  local direction = ctx.direction_from_delta(delta_x, delta_y)

  if direction then
    entity.walking_state = {
      walking = true,
      direction = direction
    }
  end

  if ctx.square_distance(entity.position, task_state.last_position) > 0.0025 then
    task_state.last_position = ctx.clone_position(entity.position)
    task_state.last_progress_tick = tick
    return
  end

  if tick - task_state.last_progress_tick >= task.stuck_retry_ticks then
    ctx.debug_log("task " .. task.id .. ": movement stalled at " .. ctx.format_position(entity.position) .. "; refreshing task")
    task_executor.refresh_task(builder_state, task, tick, ctx)
  end
end

local function move_builder(builder_state, task, tick, ctx)
  move_builder_to_position(
    builder_state,
    task,
    tick,
    builder_state.task_state.build_position,
    "building",
    builder_state.task_state.approach_position,
    ctx
  )
end

local function move_to_gather_source(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local task_state = builder_state.task_state

  if task_state.target_kind == "entity" then
    if not (task_state.target_entity and task_state.target_entity.valid) then
      ctx.debug_log("task " .. task.id .. ": source entity disappeared before harvest")
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    task_state.target_position = ctx.clone_position(task_state.target_entity.position)
    task_state.approach_position = ctx.create_task_approach_position(task, task_state.target_position)
  elseif task_state.target_kind == "decorative" then
    if not ctx.decorative_target_exists(entity.surface, task_state.target_decorative_position, task_state.target_name) then
      ctx.debug_log("task " .. task.id .. ": decorative source disappeared before harvest")
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end
  end

  local was_moving = task_state.phase == "moving-to-source"
  move_builder_to_position(
    builder_state,
    task,
    tick,
    task_state.target_position,
    "harvesting",
    task_state.approach_position,
    ctx
  )

  if was_moving and task_state.phase == "harvesting" and not task_state.harvest_complete_tick then
    task_state.harvest_complete_tick = tick + task_state.mining_duration_ticks
    ctx.debug_log(
      "task " .. task.id .. ": harvesting " .. task_state.source_id .. " at " ..
      ctx.format_position(task_state.target_position) .. " until tick " .. task_state.harvest_complete_tick
    )
  end
end

local function move_to_resource(builder_state, task, tick, ctx)
  move_builder_to_position(
    builder_state,
    task,
    tick,
    builder_state.task_state.target_position,
    "arrived-at-resource",
    builder_state.task_state.approach_position,
    ctx
  )
end

local function begin_post_place_pause(builder_state, task, tick, next_phase, placed_entity, ctx)
  local task_state = builder_state.task_state
  local pause_ticks = ctx.get_post_place_pause_ticks(task)

  ctx.set_idle(builder_state.entity)

  if pause_ticks > 0 then
    task_state.phase = "post-place-pause"
    task_state.pause_until_tick = tick + pause_ticks
    task_state.next_phase = next_phase
    task_state.pause_reason = "after placing " .. placed_entity.name
    ctx.debug_log(
      "task " .. task.id .. ": pausing until tick " .. task_state.pause_until_tick ..
      " after placing " .. placed_entity.name .. " at " .. ctx.format_position(placed_entity.position)
    )
    return
  end

  task_state.phase = next_phase
  task_state.pause_until_tick = nil
  task_state.next_phase = nil
  task_state.pause_reason = nil
end

local function get_next_build_phase(task_state, task)
  if not (task_state.placed_miner and task_state.placed_miner.valid) then
    return "place-miner"
  end

  if task.downstream_machine and not (task_state.placed_downstream_machine and task_state.placed_downstream_machine.valid) then
    return "place-downstream-machine"
  end

  if task.output_container and not (task_state.placed_output_container and task_state.placed_output_container.valid) then
    return "place-output-container"
  end

  return "build-complete"
end

local function finish_place_miner_task(builder_state, task, tick, ctx)
  local task_state = builder_state.task_state
  local miner = task_state.placed_miner
  local downstream_machine = task_state.placed_downstream_machine
  local container = task_state.placed_output_container

  if not (miner and miner.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.miner_name .. "; refreshing task")
    task_executor.refresh_task(builder_state, task, tick, ctx)
    return
  end

  if task.downstream_machine and not (downstream_machine and downstream_machine.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.downstream_machine.name .. "; refreshing task")
    task_executor.refresh_task(builder_state, task, tick, ctx)
    return
  end

  if task.output_container and not (container and container.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.output_container.name .. "; refreshing task")
    task_executor.refresh_task(builder_state, task, tick, ctx)
    return
  end

  if downstream_machine then
    ctx.register_smelting_site(task, miner, downstream_machine, container)
  end

  ctx.register_resource_site(task, miner, downstream_machine, container)

  ctx.complete_current_task(
    builder_state,
    task,
    "placed " .. task.miner_name .. " at " .. ctx.format_position(miner.position) ..
    (downstream_machine and " with " .. downstream_machine.name .. " at " .. ctx.format_position(downstream_machine.position) or "") ..
    (container and " and " .. container.name .. " at " .. ctx.format_position(container.position) or "")
  )
end

local function seed_entity_from_builder_inventory(builder, target_entity, seed_items, reason, ctx)
  local inserted_items = {}

  for _, seed_item in ipairs(seed_items or {}) do
    local removed_count = ctx.remove_item(builder, seed_item.name, seed_item.count, reason)
    if removed_count > 0 then
      local inserted_count = target_entity.insert{
        name = seed_item.name,
        count = removed_count
      }

      if inserted_count < removed_count then
        ctx.insert_item(
          builder,
          seed_item.name,
          removed_count - inserted_count,
          "refunded after partial insert into " .. target_entity.name .. " at " .. ctx.format_position(target_entity.position)
        )
      end

      if inserted_count > 0 then
        inserted_items[#inserted_items + 1] = {
          name = seed_item.name,
          count = inserted_count
        }
      end
    end
  end

  if #inserted_items > 0 then
    ctx.debug_log(reason .. ": inserted " .. ctx.format_products(inserted_items))
  end

  return inserted_items
end

local function finish_place_layout_near_machine_task(builder_state, task, tick, ctx)
  local task_state = builder_state.task_state
  local anchor_entity = task_state.anchor_entity

  if not (anchor_entity and anchor_entity.valid) then
    ctx.debug_log("task " .. task.id .. ": anchor entity disappeared before layout completion; refreshing task")
    task_executor.refresh_task(builder_state, task, tick, ctx)
    return
  end

  local valid_entities = {}
  for _, placement in ipairs(task_state.placed_layout_entities or {}) do
    if placement.entity and placement.entity.valid then
      valid_entities[#valid_entities + 1] = placement
    end
  end

  if #valid_entities < #(task.layout_elements or {}) then
    ctx.debug_log("task " .. task.id .. ": layout completed with missing entities; refreshing task")
    task_executor.refresh_task(builder_state, task, tick, ctx)
    return
  end

  if task.layout_site_kind == "steel-smelting-chain" then
    local anchor_site = task_state.anchor_site
    local feed_inserter = nil
    local steel_furnace = nil

    for _, placement in ipairs(valid_entities) do
      if placement.site_role == "steel-feed-inserter" then
        feed_inserter = placement.entity
      elseif placement.site_role == "steel-furnace" then
        steel_furnace = placement.entity
      end
    end

    if not (anchor_site and anchor_site.miner and anchor_site.miner.valid) then
      ctx.debug_log("task " .. task.id .. ": anchor site disappeared before steel layout completion; refreshing task")
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    if not (feed_inserter and feed_inserter.valid and steel_furnace and steel_furnace.valid) then
      ctx.debug_log("task " .. task.id .. ": steel layout completed without valid inserter/furnace; refreshing task")
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    ctx.register_steel_smelting_site(task, anchor_entity, feed_inserter, steel_furnace, anchor_site.miner)
    ctx.register_resource_site(
      task,
      anchor_site.miner,
      steel_furnace,
      nil,
      {
        identity_entity = steel_furnace,
        anchor_machine = anchor_entity,
        feed_inserter = feed_inserter,
        parent_pattern_name = anchor_site.pattern_name
      }
    )

    ctx.complete_current_task(
      builder_state,
      task,
      "extended " .. (anchor_site.pattern_name or "smelting line") ..
      " at " .. ctx.format_position(anchor_entity.position) ..
      " with burner-inserter at " .. ctx.format_position(feed_inserter.position) ..
      " and steel furnace at " .. ctx.format_position(steel_furnace.position)
    )
    return
  end

  local seeded_items = seed_entity_from_builder_inventory(
    builder_state.entity,
    anchor_entity,
    task.seed_anchor_items,
    "seeded " .. anchor_entity.name .. " at " .. ctx.format_position(anchor_entity.position),
    ctx
  )

  ctx.register_assembler_defense_site(task, anchor_entity, valid_entities)

  if task.completed_scaling_milestone_name then
    ctx.builder_runtime.ensure_builder_state_fields(builder_state)
    builder_state.completed_scaling_milestones[task.completed_scaling_milestone_name] = true
  end

  ctx.complete_current_task(
    builder_state,
    task,
    "fortified " .. anchor_entity.name .. " at " .. ctx.format_position(anchor_entity.position) ..
    " with " .. tostring(#valid_entities) .. " support entities" ..
    (#seeded_items > 0 and "; seeded " .. ctx.format_products(seeded_items) or "")
  )
end

local function finish_place_machine_near_site_task(builder_state, task, tick, ctx)
  local task_state = builder_state.task_state
  local placed_entity = task_state.placed_entity

  if not (placed_entity and placed_entity.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.entity_name .. "; refreshing task")
    task_executor.refresh_task(builder_state, task, tick, ctx)
    return
  end

  if task.completed_scaling_milestone_name then
    ctx.builder_runtime.ensure_builder_state_fields(builder_state)
    builder_state.completed_scaling_milestones[task.completed_scaling_milestone_name] = true
  end

  ctx.complete_current_task(
    builder_state,
    task,
    "placed " .. task.entity_name .. " at " .. ctx.format_position(placed_entity.position) ..
    (task.recipe_name and " with recipe " .. task.recipe_name or "")
  )
end

local function place_miner(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local surface = entity.surface

  local function record_consumed_build_item(item_name, count)
    if not task.consume_items_on_place then
      return
    end

    task_state.consumed_build_items = task_state.consumed_build_items or {}
    task_state.consumed_build_items[item_name] = (task_state.consumed_build_items[item_name] or 0) + (count or 1)
  end

  local function refund_consumed_build_items(reason)
    if not task_state.consumed_build_items then
      return
    end

    for item_name, count in pairs(task_state.consumed_build_items) do
      ctx.insert_item(entity, item_name, count, reason)
    end

    task_state.consumed_build_items = nil
  end

  local function consume_build_item(item_name, placed_entity)
    if not task.consume_items_on_place then
      return true
    end

    local reason = "placed " .. item_name .. " at " .. ctx.format_position(placed_entity.position)
    local removed_count = ctx.remove_item(entity, item_name, 1, reason)
    if removed_count < 1 then
      ctx.debug_log("task " .. task.id .. ": missing " .. item_name .. " in builder inventory for placement")
      return false
    end

    record_consumed_build_item(item_name, removed_count)
    return true
  end

  local function abort_build(reason)
    refund_consumed_build_items("refunded after aborted build for " .. task.id)
    ctx.destroy_entity_if_valid(task_state.placed_output_container)
    ctx.destroy_entity_if_valid(task_state.placed_downstream_machine)
    ctx.destroy_entity_if_valid(task_state.placed_miner)
    task_executor.refresh_task(builder_state, task, tick, ctx)
    ctx.debug_log("task " .. task.id .. ": " .. reason)
  end

  local build_phase = get_next_build_phase(task_state, task)

  if build_phase == "place-miner" then
    if not surface.can_place_entity{
      name = task.miner_name,
      position = task_state.build_position,
      direction = task_state.build_direction,
      force = entity.force
    } then
      ctx.debug_log("task " .. task.id .. ": build position became invalid at " .. ctx.format_position(task_state.build_position))
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    local miner = surface.create_entity{
      name = task.miner_name,
      position = task_state.build_position,
      direction = task_state.build_direction,
      force = entity.force,
      create_build_effect_smoke = false
    }

    if not miner then
      ctx.debug_log("task " .. task.id .. ": create_entity returned nil for " .. task.miner_name .. " at " .. ctx.format_position(task_state.build_position))
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    if not (miner.mining_target and miner.mining_target.valid and miner.mining_target.name == task.resource_name) then
      local covered_resources = surface.find_entities_filtered{
        area = miner.mining_area,
        type = "resource",
        name = task.resource_name
      }

      if #covered_resources == 0 then
        local mining_target_name = miner.mining_target and miner.mining_target.valid and miner.mining_target.name or "nil"
        miner.destroy()
        ctx.debug_log("task " .. task.id .. ": miner at " .. ctx.format_position(task_state.build_position) .. " covered no " .. task.resource_name .. " in mining_area; immediate mining_target=" .. mining_target_name)
        task_executor.refresh_task(builder_state, task, tick, ctx)
        return
      end
    end

    task_state.placed_miner = miner
    if not consume_build_item(task.miner_name, miner) then
      miner.destroy()
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end
    ctx.insert_entity_fuel(miner, task.fuel)
    ctx.debug_log("task " .. task.id .. ": placed " .. task.miner_name .. " at " .. ctx.format_position(miner.position))
    begin_post_place_pause(
      builder_state,
      task,
      tick,
      get_next_build_phase(task_state, task) == "build-complete" and "build-complete" or "building",
      miner,
      ctx
    )
    return
  end

  if build_phase == "place-downstream-machine" then
    local miner = task_state.placed_miner
    if not (miner and miner.valid) then
      abort_build("miner disappeared before placing " .. task.downstream_machine.name)
      return
    end

    if not task_state.downstream_machine_position then
      abort_build("missing downstream machine position")
      return
    end

    if not surface.can_place_entity{
      name = task.downstream_machine.name,
      position = task_state.downstream_machine_position,
      force = entity.force
    } then
      abort_build("downstream machine position became invalid at " .. ctx.format_position(task_state.downstream_machine_position))
      return
    end

    local downstream_machine = surface.create_entity{
      name = task.downstream_machine.name,
      position = task_state.downstream_machine_position,
      force = entity.force,
      create_build_effect_smoke = false
    }

    if not downstream_machine then
      abort_build("failed to place downstream machine at " .. ctx.format_position(task_state.downstream_machine_position))
      return
    end

    if task.downstream_machine.cover_drop_position and not ctx.point_in_area(miner.drop_position, downstream_machine.selection_box) then
      downstream_machine.destroy()
      abort_build(task.downstream_machine.name .. " no longer covers miner drop position at " .. ctx.format_position(miner.drop_position))
      return
    end

    task_state.placed_downstream_machine = downstream_machine
    if not consume_build_item(task.downstream_machine.name, downstream_machine) then
      downstream_machine.destroy()
      abort_build("missing " .. task.downstream_machine.name .. " in builder inventory")
      return
    end
    ctx.insert_entity_fuel(downstream_machine, task.downstream_machine.fuel)
    ctx.debug_log("task " .. task.id .. ": placed " .. task.downstream_machine.name .. " at " .. ctx.format_position(downstream_machine.position))
    begin_post_place_pause(
      builder_state,
      task,
      tick,
      get_next_build_phase(task_state, task) == "build-complete" and "build-complete" or "building",
      downstream_machine,
      ctx
    )
    return
  end

  if build_phase == "place-output-container" then
    if not task_state.output_container_position then
      abort_build("missing output container position")
      return
    end

    if not surface.can_place_entity{
      name = task.output_container.name,
      position = task_state.output_container_position,
      force = entity.force
    } then
      abort_build("output container position became invalid at " .. ctx.format_position(task_state.output_container_position))
      return
    end

    local container = surface.create_entity{
      name = task.output_container.name,
      position = task_state.output_container_position,
      force = entity.force,
      create_build_effect_smoke = false
    }

    if not container then
      abort_build("failed to place output container at " .. ctx.format_position(task_state.output_container_position))
      return
    end

    task_state.placed_output_container = container
    if not consume_build_item(task.output_container.name, container) then
      container.destroy()
      abort_build("missing " .. task.output_container.name .. " in builder inventory")
      return
    end
    ctx.debug_log("task " .. task.id .. ": placed " .. task.output_container.name .. " at " .. ctx.format_position(container.position))
    begin_post_place_pause(
      builder_state,
      task,
      tick,
      get_next_build_phase(task_state, task) == "build-complete" and "build-complete" or "building",
      container,
      ctx
    )
    return
  end

  finish_place_miner_task(builder_state, task, tick, ctx)
end

local function place_machine_near_site(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local surface = entity.surface
  local consumed_item_name = ctx.get_task_consumed_item_name(task)

  local function refund_consumed_build_item(reason)
    if task_state.consumed_machine_item then
      ctx.insert_item(entity, consumed_item_name, task_state.consumed_machine_item, reason)
      task_state.consumed_machine_item = nil
    end
  end

  local function abort_build(reason)
    refund_consumed_build_item("refunded after aborted build for " .. task.id)
    ctx.destroy_entity_if_valid(task_state.placed_entity)
    task_executor.refresh_task(builder_state, task, tick, ctx)
    ctx.debug_log("task " .. task.id .. ": " .. reason)
  end

  local function schedule_retry(wait_reason, reason)
    refund_consumed_build_item("refunded after delayed retry for " .. task.id)
    ctx.destroy_entity_if_valid(task_state.placed_entity)
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = wait_reason,
      next_attempt_tick = tick + task.search_retry_ticks
    }
    ctx.debug_log("task " .. task.id .. ": " .. reason .. "; retry at tick " .. builder_state.task_state.next_attempt_tick)
  end

  if not task_state.placed_entity then
    if not surface.can_place_entity{
      name = task.entity_name,
      position = task_state.build_position,
      direction = task_state.build_direction,
      force = entity.force
    } then
      ctx.debug_log("task " .. task.id .. ": build position became invalid at " .. ctx.format_position(task_state.build_position))
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    local placed_entity = surface.create_entity{
      name = task.entity_name,
      position = task_state.build_position,
      direction = task_state.build_direction,
      force = entity.force,
      create_build_effect_smoke = false
    }

    if not placed_entity then
      ctx.debug_log("task " .. task.id .. ": failed to create " .. task.entity_name .. " at " .. ctx.format_position(task_state.build_position))
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    if task.recipe_name and task.recipe_is_fixed then
      local current_recipe = placed_entity.get_recipe and placed_entity.get_recipe()
      local recipe_name = current_recipe and current_recipe.name or nil
      if recipe_name ~= task.recipe_name then
        task_state.placed_entity = placed_entity
        schedule_retry(
          "recipe-unavailable",
          "placed fixed-recipe machine " .. task.entity_name ..
            " but it reported recipe " .. tostring(recipe_name) ..
            " instead of " .. task.recipe_name
        )
        return
      end
    elseif task.recipe_name then
      local recipe_set = false
      local recipe_enabled = entity.force.recipes and entity.force.recipes[task.recipe_name] and entity.force.recipes[task.recipe_name].enabled
      if placed_entity.set_recipe then
        local ok, result = pcall(placed_entity.set_recipe, placed_entity, task.recipe_name, "normal")
        recipe_set = ok and result ~= false
        if not ok then
          ctx.debug_log(
            "task " .. task.id .. ": set_recipe raised " .. tostring(result) ..
            " while configuring " .. task.entity_name
          )
        end
      end

      if not recipe_set then
        task_state.placed_entity = placed_entity
        schedule_retry(
          "recipe-unavailable",
          "failed to set recipe " .. task.recipe_name .. " on " .. task.entity_name ..
            " (force recipe enabled=" .. tostring(recipe_enabled) .. ")"
        )
        return
      end
    end

    task_state.placed_entity = placed_entity

    if task.consume_items_on_place then
      local reason = "placed " .. consumed_item_name .. " at " .. ctx.format_position(placed_entity.position)
      local removed_count = ctx.remove_item(entity, consumed_item_name, 1, reason)
      if removed_count < 1 then
        placed_entity.destroy()
        task_state.placed_entity = nil
        ctx.debug_log("task " .. task.id .. ": missing " .. consumed_item_name .. " in builder inventory for placement")
        task_executor.refresh_task(builder_state, task, tick, ctx)
        return
      end

      task_state.consumed_machine_item = removed_count
    end

    ctx.debug_log(
      "task " .. task.id .. ": placed " .. task.entity_name ..
      " at " .. ctx.format_position(placed_entity.position) ..
      (task.recipe_name and " with recipe " .. task.recipe_name or "")
    )
    begin_post_place_pause(builder_state, task, tick, "build-complete", placed_entity, ctx)
    return
  end

  finish_place_machine_near_site_task(builder_state, task, tick, ctx)
end

local function place_layout_near_machine(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local surface = entity.surface

  local function record_consumed_build_item(item_name, count)
    if not task.consume_items_on_place then
      return
    end

    task_state.consumed_build_items = task_state.consumed_build_items or {}
    task_state.consumed_build_items[item_name] = (task_state.consumed_build_items[item_name] or 0) + (count or 1)
  end

  local function refund_consumed_build_items(reason)
    if not task_state.consumed_build_items then
      return
    end

    for item_name, count in pairs(task_state.consumed_build_items) do
      ctx.insert_item(entity, item_name, count, reason)
    end

    task_state.consumed_build_items = nil
  end

  local function destroy_placed_layout_entities()
    for _, placement in ipairs(task_state.placed_layout_entities or {}) do
      ctx.destroy_entity_if_valid(placement.entity)
    end

    task_state.placed_layout_entities = {}
  end

  local function abort_build(reason)
    refund_consumed_build_items("refunded after aborted build for " .. task.id)
    destroy_placed_layout_entities()
    task_executor.refresh_task(builder_state, task, tick, ctx)
    ctx.debug_log("task " .. task.id .. ": " .. reason)
  end

  local placement = task_state.layout_placements and task_state.layout_placements[task_state.layout_index]
  if not placement then
    task_state.phase = "build-complete"
    return
  end

  if not surface.can_place_entity{
    name = placement.entity_name,
    position = placement.build_position,
    direction = placement.build_direction,
    force = entity.force
  } then
    abort_build("layout position became invalid for " .. placement.entity_name .. " at " .. ctx.format_position(placement.build_position))
    return
  end

  local placed_entity = surface.create_entity{
    name = placement.entity_name,
    position = placement.build_position,
    direction = placement.build_direction,
    force = entity.force,
    create_build_effect_smoke = false
  }

  if not placed_entity then
    abort_build("failed to place " .. placement.entity_name .. " at " .. ctx.format_position(placement.build_position))
    return
  end

  if task.consume_items_on_place then
    local removed_count = ctx.remove_item(
      entity,
      placement.item_name,
      1,
      "placed " .. placement.item_name .. " at " .. ctx.format_position(placed_entity.position)
    )
    if removed_count < 1 then
      placed_entity.destroy()
      abort_build("missing " .. placement.item_name .. " in builder inventory")
      return
    end

    record_consumed_build_item(placement.item_name, removed_count)
  end

  ctx.insert_entity_fuel(placed_entity, placement.fuel)

  task_state.placed_layout_entities[#task_state.placed_layout_entities + 1] = {
    id = placement.id,
    site_role = placement.site_role,
    entity = placed_entity
  }

  ctx.debug_log(
    "task " .. task.id .. ": placed " .. placement.entity_name ..
    " at " .. ctx.format_position(placed_entity.position) ..
    (placement.site_role and " as " .. placement.site_role or "")
  )

  task_state.layout_index = task_state.layout_index + 1
  begin_post_place_pause(
    builder_state,
    task,
    tick,
    task_state.layout_index > #(task_state.layout_placements or {}) and "build-complete" or "building",
    placed_entity,
    ctx
  )
end

local function harvest_world_items(builder_state, task, tick, ctx)
  local entity = builder_state.entity
  local task_state = builder_state.task_state

  if tick < task_state.harvest_complete_tick then
    return
  end

  if task_state.target_kind == "entity" then
    if not (task_state.target_entity and task_state.target_entity.valid) then
      ctx.debug_log("task " .. task.id .. ": source entity disappeared during harvest")
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    task_state.target_entity.destroy()
  elseif task_state.target_kind == "decorative" then
    if not ctx.decorative_target_exists(entity.surface, task_state.target_decorative_position, task_state.target_name) then
      ctx.debug_log("task " .. task.id .. ": decorative source disappeared during harvest")
      task_executor.refresh_task(builder_state, task, tick, ctx)
      return
    end

    entity.surface.destroy_decoratives{
      position = task_state.target_decorative_position,
      name = task_state.target_name,
      limit = 1
    }
  else
    ctx.debug_log("task " .. task.id .. ": unsupported harvest target kind " .. tostring(task_state.target_kind))
    task_executor.refresh_task(builder_state, task, tick, ctx)
    return
  end

  local inserted_products = ctx.insert_products(
    entity,
    task_state.harvest_products,
    "harvested " .. task_state.source_id .. " at " .. ctx.format_position(task_state.target_position)
  )

  ctx.debug_log(
    "task " .. task.id .. ": harvested " .. task_state.source_id .. " at " ..
    ctx.format_position(task_state.target_position) .. "; inserted " .. ctx.format_products(inserted_products) ..
    "; inventory now " .. ctx.inventory_targets_summary(entity, task.inventory_targets)
  )

  if task.no_advance then
    builder_state.scaling_active_task = nil
  end

  builder_state.task_state = nil
end

function task_executor.advance_task_phase(builder_state, task, tick, ctx)
  local phase = builder_state.task_state.phase

  if phase == "waiting-for-resource" then
    if tick >= builder_state.task_state.next_attempt_tick then
      task_executor.refresh_task(builder_state, task, tick, ctx)
    end
    return
  end

  if phase == "waiting-for-source" then
    if tick >= builder_state.task_state.next_attempt_tick then
      task_executor.refresh_task(builder_state, task, tick, ctx)
    end
    return
  end

  if phase == "moving" then
    move_builder(builder_state, task, tick, ctx)
    return
  end

  if phase == "moving-to-source" then
    move_to_gather_source(builder_state, task, tick, ctx)
    return
  end

  if phase == "moving-to-resource" then
    move_to_resource(builder_state, task, tick, ctx)
    return
  end

  if phase == "building" then
    if task.type == "place-machine-near-site" then
      place_machine_near_site(builder_state, task, tick, ctx)
    elseif task.type == "place-layout-near-machine" then
      place_layout_near_machine(builder_state, task, tick, ctx)
    else
      place_miner(builder_state, task, tick, ctx)
    end
    return
  end

  if phase == "post-place-pause" then
    if tick >= (builder_state.task_state.pause_until_tick or 0) then
      builder_state.task_state.phase = builder_state.task_state.next_phase or "building"
      builder_state.task_state.pause_until_tick = nil
      builder_state.task_state.next_phase = nil
      builder_state.task_state.pause_reason = nil
      ctx.debug_log("task " .. task.id .. ": post-build pause complete; resuming " .. builder_state.task_state.phase)
    end
    return
  end

  if phase == "build-complete" then
    if task.type == "place-machine-near-site" then
      finish_place_machine_near_site_task(builder_state, task, tick, ctx)
    elseif task.type == "place-layout-near-machine" then
      finish_place_layout_near_machine_task(builder_state, task, tick, ctx)
    else
      finish_place_miner_task(builder_state, task, tick, ctx)
    end
    return
  end

  if phase == "arrived-at-resource" then
    ctx.complete_current_task(
      builder_state,
      task,
      "arrived at " .. task.resource_name .. " at " .. ctx.format_position(builder_state.task_state.target_position)
    )
    return
  end

  if phase == "harvesting" then
    harvest_world_items(builder_state, task, tick, ctx)
  end
end

return task_executor

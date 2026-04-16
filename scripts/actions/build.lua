local action_build = {}

local function entity_contains_point(entity, point, ctx)
  return entity and entity.valid and point and ctx.point_in_area(point, entity.selection_box)
end

local function try_set_entity_recipe(entity, recipe_name)
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

  if task.output_inserter and task.belt_entity_name then
    if not task_state.layout_placements then
      return "place-output-belt-layout"
    end

    if #task_state.layout_placements > 0 and #(task_state.placed_layout_entities or {}) < #task_state.layout_placements then
      return "place-output-belt-layout"
    end
  end

  return "build-complete"
end

local function describe_output_belt_layout_failure(summary)
  summary = summary or {}

  local positions_checked = summary.positions_checked or 0
  local placeable_positions = summary.placeable_positions or 0
  local terminal_positions_found = summary.terminal_positions_found or 0
  local valid_belt_paths = summary.valid_belt_paths or 0
  local failed_belt_paths = summary.failed_belt_paths or 0
  local failed_inserter_geometry = summary.failed_inserter_geometry or 0
  local resource_overlap_rejections = summary.resource_overlap_rejections or 0

  if summary.failed_belt_path_detail then
    return "belt routing failed (" .. summary.failed_belt_path_detail .. ")"
  end

  if failed_inserter_geometry > 0 then
    return "output inserter geometry did not line up (" .. tostring(failed_inserter_geometry) .. " attempts)"
  end

  if terminal_positions_found > 0 and failed_belt_paths > 0 and valid_belt_paths == 0 then
    return "belt routing failed for all " .. tostring(terminal_positions_found) .. " terminal positions"
  end

  if placeable_positions > 0 and terminal_positions_found == 0 then
    return "no terminal belt position fit near the hub"
  end

  if positions_checked > 0 then
    local message = "no belt hub location fit near the patch"
    if resource_overlap_rejections > 0 then
      message = message .. " (" .. tostring(resource_overlap_rejections) .. " resource-overlap rejections)"
    end
    return message
  end

  return nil
end

local function collect_output_belt_layout_entities(placed_layout_entities)
  local output_inserter = nil
  local belt_entities = {}

  for _, placement in ipairs(placed_layout_entities or {}) do
    if placement.entity and placement.entity.valid then
      if placement.site_role == "output-inserter" then
        output_inserter = placement.entity
      elseif placement.site_role == "output-belt" then
        belt_entities[#belt_entities + 1] = placement.entity
      end
    end
  end

  return output_inserter, belt_entities
end

local function finalize_output_belt_site(builder_state, task, tick, ctx, refresh_task, task_state, output_machine, completion_prefix)
  local output_inserter, belt_entities = collect_output_belt_layout_entities(task_state.placed_layout_entities)
  if not (output_machine and output_machine.valid and output_inserter and output_inserter.valid and #belt_entities > 0) then
    ctx.debug_log("task " .. task.id .. ": output belt layout completed without valid machine/inserter/belts; refreshing task")
    refresh_task(builder_state, task, tick, ctx)
    return false
  end

  local hub_position = task_state.belt_hub_position or task_state.belt_terminal_position or belt_entities[#belt_entities].position

  ctx.register_output_belt_site(
    task,
    output_machine,
    output_inserter,
    belt_entities,
    hub_position
  )

  ctx.complete_current_task(
    builder_state,
    task,
    completion_prefix ..
      " with burner-inserter at " .. ctx.format_position(output_inserter.position) ..
      " and " .. tostring(#belt_entities) .. " belts toward " ..
      ctx.format_position(hub_position)
  )

  return true
end

local function summarize_layout_entities(placements)
  local counts_by_name = {}
  local summarized = {}

  for _, placement in ipairs(placements or {}) do
    local placed_entity = placement.entity
    local entity_name = nil

    if placed_entity and placed_entity.valid then
      entity_name = placed_entity.name
    else
      entity_name = placement.entity_name
    end

    if entity_name then
      counts_by_name[entity_name] = (counts_by_name[entity_name] or 0) + 1
    end
  end

  for entity_name, count in pairs(counts_by_name) do
    summarized[#summarized + 1] = {
      name = entity_name,
      count = count
    }
  end

  table.sort(summarized, function(left, right)
    return left.name < right.name
  end)

  return summarized
end

local function cleanup_placed_layout_entities(builder_entity, task_state, refund_reason, ctx)
  local preserved_layout_entities = summarize_layout_entities(task_state.placed_layout_entities)
  task_state.consumed_build_items = nil
  task_state.placed_layout_entities = {}
  return {}, preserved_layout_entities
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

local function clear_ground_item_blockers(surface, entity_name, position, task, ctx)
  if not (surface and entity_name and position and task and task.clear_ground_item_blockers) then
    return false
  end

  local area = build_entity_placement_area(entity_name, position)
  local blockers = surface.find_entities_filtered{
    area = {
      {area.left_top.x - 0.05, area.left_top.y - 0.05},
      {area.right_bottom.x + 0.05, area.right_bottom.y + 0.05}
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

  if cleared_count > 0 then
    ctx.debug_log(
      "task " .. task.id .. ": cleared " .. tostring(cleared_count) ..
      " ground-item blocker(s) for " .. entity_name .. " at " .. ctx.format_position(position)
    )
  end

  return cleared_count > 0
end

local function can_place_entity_with_ground_item_clearance(surface, force, entity_name, position, direction, task, ctx)
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

  if clear_ground_item_blockers(surface, entity_name, position, task, ctx) then
    return surface.can_place_entity(placement)
  end

  return false
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

local function begin_clear_obstacle(builder_state, task, tick, blocked_entity_name, blocked_position, obstacle, ctx)
  local task_state = builder_state.task_state
  local builder = builder_state.entity
  local obstacle_label = obstacle.display_name or obstacle.target_name or "obstacle"

  task_state.phase = "moving-to-source"
  task_state.source_id = (obstacle.source_id or obstacle_label) .. "-obstacle"
  task_state.target_item_name = nil
  task_state.target_kind = obstacle.target_kind
  task_state.target_name = obstacle.target_name
  task_state.target_entity = obstacle.entity
  task_state.target_decorative_position = obstacle.decorative_position and ctx.clone_position(obstacle.decorative_position) or nil
  task_state.target_position = ctx.clone_position(obstacle.target_position)
  task_state.approach_position = ctx.create_task_approach_position(task, obstacle.target_position)
  task_state.harvest_products = obstacle.yields or {}
  task_state.harvest_complete_tick = nil
  task_state.mining_duration_ticks = obstacle.mining_duration_ticks or 45
  task_state.resume_phase_after_clear = "building"
  task_state.clear_obstacle_label = obstacle_label
  task_state.clear_obstacle_target_name = obstacle.target_name
  task_state.clear_obstacle_build_position = ctx.clone_position(blocked_position)
  task_state.last_position = ctx.clone_position(builder.position)
  task_state.last_progress_tick = tick

  ctx.builder_runtime.record_recovery(
    builder_state,
    {
      kind = "clear-obstacle",
      message = "Clearing " .. obstacle_label .. " blocking " .. blocked_entity_name,
      meta = {
        obstacle_name = obstacle.target_name,
        obstacle_label = obstacle_label,
        blocked_entity_name = blocked_entity_name,
        blocked_position = ctx.clone_position(blocked_position)
      }
    }
  )
  ctx.debug_log(
    "task " .. task.id .. ": clearing " .. obstacle_label ..
    " (" .. tostring(obstacle.target_name) .. ") at " .. ctx.format_position(obstacle.target_position) ..
    " blocking " .. blocked_entity_name .. " at " .. ctx.format_position(blocked_position)
  )
end

local function try_clear_blocking_obstacle(builder_state, task, tick, blocked_entity_name, blocked_position, ctx)
  local obstacle = ctx.find_clearable_build_obstacle(
    builder_state.entity.surface,
    blocked_entity_name,
    blocked_position
  )

  if not obstacle then
    return false
  end

  begin_clear_obstacle(builder_state, task, tick, blocked_entity_name, blocked_position, obstacle, ctx)
  return true
end

function action_build.finish_place_miner_task(builder_state, task, tick, ctx, refresh_task)
  local task_state = builder_state.task_state
  local miner = task_state.placed_miner
  local downstream_machine = task_state.placed_downstream_machine
  local container = task_state.placed_output_container

  if not (miner and miner.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.miner_name .. "; refreshing task")
    refresh_task(builder_state, task, tick, ctx)
    return
  end

  if task.downstream_machine and not (downstream_machine and downstream_machine.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.downstream_machine.name .. "; refreshing task")
    refresh_task(builder_state, task, tick, ctx)
    return
  end

  if task.output_container and not (container and container.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.output_container.name .. "; refreshing task")
    refresh_task(builder_state, task, tick, ctx)
    return
  end

  local has_output_belt_layout = task.output_inserter and task.belt_entity_name

  if downstream_machine then
    ctx.register_smelting_site(task, miner, downstream_machine, container)
  end

  ctx.register_resource_site(task, miner, downstream_machine, container)

  if has_output_belt_layout then
    if not finalize_output_belt_site(
        builder_state,
        task,
        tick,
        ctx,
        refresh_task,
        task_state,
        downstream_machine,
        "placed " .. task.miner_name .. " at " .. ctx.format_position(miner.position) ..
          " with " .. downstream_machine.name .. " at " .. ctx.format_position(downstream_machine.position)
      )
    then
      return
    end

    return
  end

  ctx.complete_current_task(
    builder_state,
    task,
    "placed " .. task.miner_name .. " at " .. ctx.format_position(miner.position) ..
    (downstream_machine and " with " .. downstream_machine.name .. " at " .. ctx.format_position(downstream_machine.position) or "") ..
    (container and " and " .. container.name .. " at " .. ctx.format_position(container.position) or "")
  )
end

function action_build.finish_place_layout_near_machine_task(builder_state, task, tick, ctx, refresh_task)
  local task_state = builder_state.task_state
  local anchor_entity = task_state.anchor_entity

  if not (anchor_entity and anchor_entity.valid) then
    ctx.debug_log("task " .. task.id .. ": anchor entity disappeared before layout completion; refreshing task")
    refresh_task(builder_state, task, tick, ctx)
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
    refresh_task(builder_state, task, tick, ctx)
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
      refresh_task(builder_state, task, tick, ctx)
      return
    end

    if not (feed_inserter and feed_inserter.valid and steel_furnace and steel_furnace.valid) then
      ctx.debug_log("task " .. task.id .. ": steel layout completed without valid inserter/furnace; refreshing task")
      refresh_task(builder_state, task, tick, ctx)
      return
    end

    if not entity_contains_point(anchor_entity, feed_inserter.pickup_position, ctx) then
      ctx.debug_log(
        "task " .. task.id .. ": steel feed inserter pickup " ..
        ctx.format_position(feed_inserter.pickup_position) ..
        " no longer points into anchor furnace at " .. ctx.format_position(anchor_entity.position) ..
        "; refreshing task"
      )
      refresh_task(builder_state, task, tick, ctx)
      return
    end

    if not entity_contains_point(steel_furnace, feed_inserter.drop_position, ctx) then
      ctx.debug_log(
        "task " .. task.id .. ": steel feed inserter drop " ..
        ctx.format_position(feed_inserter.drop_position) ..
        " no longer points into steel furnace at " .. ctx.format_position(steel_furnace.position) ..
        "; refreshing task"
      )
      refresh_task(builder_state, task, tick, ctx)
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

  if task.type == "place-output-belt-line" then
    local output_machine = task_state.anchor_entity
    finalize_output_belt_site(
      builder_state,
      task,
      tick,
      ctx,
      refresh_task,
      task_state,
      output_machine,
      "extended " .. (task_state.anchor_site and task_state.anchor_site.pattern_name or "smelting line") ..
        " at " .. ctx.format_position(output_machine and output_machine.position or task_state.anchor_position)
    )
    return
  end

  if task.type == "place-assembly-block" then
    local anchor_entity = task_state.anchor_entity
    local root_assembler = nil

    for _, placement in ipairs(valid_entities) do
      if placement.site_role == "assembly-root" then
        root_assembler = placement.entity
        break
      end
    end

    if not (anchor_entity and anchor_entity.valid and root_assembler and root_assembler.valid) then
      ctx.debug_log("task " .. task.id .. ": assembly block completed without a valid anchor/root assembler; refreshing task")
      refresh_task(builder_state, task, tick, ctx)
      return
    end

    ctx.register_assembly_block_site(task, anchor_entity, root_assembler, valid_entities)

    ctx.complete_current_task(
      builder_state,
      task,
      "built " .. (task.target_item_name or "assembly block") ..
      " at " .. ctx.format_position(root_assembler.position) ..
      " near " .. anchor_entity.name .. " at " .. ctx.format_position(anchor_entity.position)
    )
    return
  end

  if task.type == "place-assembly-input-route" then
    local assembly_site = task_state.assembly_site
    local anchor_entity = task_state.anchor_entity
    local belt_entities = {}

    for _, placement in ipairs(valid_entities) do
      if placement.entity and placement.entity.valid and placement.entity.type == "transport-belt" then
        belt_entities[#belt_entities + 1] = placement.entity
      end
    end

    if not (assembly_site and anchor_entity and anchor_entity.valid and #belt_entities > 0) then
      ctx.debug_log("task " .. task.id .. ": assembly input route completed without a valid block/belts; refreshing task")
      refresh_task(builder_state, task, tick, ctx)
      return
    end

    ctx.register_assembly_input_route(task, assembly_site, task_state.route_id or task.route_id, belt_entities, task_state.source_site)

    ctx.complete_current_task(
      builder_state,
      task,
      "connected " .. tostring(task_state.route_id or task.route_id or "assembly route") ..
      " into block at " .. ctx.format_position(anchor_entity.position) ..
      " with " .. tostring(#belt_entities) .. " belts"
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

function action_build.finish_place_machine_near_site_task(builder_state, task, tick, ctx, refresh_task)
  local task_state = builder_state.task_state
  local placed_entity = task_state.placed_entity

  if not (placed_entity and placed_entity.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.entity_name .. "; refreshing task")
    refresh_task(builder_state, task, tick, ctx)
    return
  end

  local valid_layout_entities = {}
  for _, placement in ipairs(task_state.placed_layout_entities or {}) do
    if placement.entity and placement.entity.valid then
      valid_layout_entities[#valid_layout_entities + 1] = placement
    end
  end

  local seeded_items = {}
  if task.seed_anchor_items and #task.seed_anchor_items > 0 then
    seeded_items = seed_entity_from_builder_inventory(
      builder_state.entity,
      placed_entity,
      task.seed_anchor_items,
      "seeded " .. placed_entity.name .. " at " .. ctx.format_position(placed_entity.position),
      ctx
    )
  end

  local full_reserved_layout_built = false
  if task.build_reserved_layout then
    local expected_layout_count = #(task_state.layout_placements or {})
    full_reserved_layout_built =
      not task_state.reserved_layout_failed and
      expected_layout_count > 0 and
      #valid_layout_entities >= expected_layout_count

    if full_reserved_layout_built and task.register_reserved_layout_as_assembler_defense then
      ctx.register_assembler_defense_site(task, placed_entity, valid_layout_entities)
    end
  end

  if task.completed_scaling_milestone_name then
    ctx.builder_runtime.ensure_builder_state_fields(builder_state)
    builder_state.completed_scaling_milestones[task.completed_scaling_milestone_name] = true
  end

  local completion_message =
    "placed " .. task.entity_name .. " at " .. ctx.format_position(placed_entity.position) ..
    (task.recipe_name and " with recipe " .. task.recipe_name or "")

  if task.build_reserved_layout and #valid_layout_entities > 0 then
    completion_message = completion_message ..
      (full_reserved_layout_built and " with " or "; left ") ..
      tostring(#valid_layout_entities) .. " support entities"
  end

  if task_state.reserved_layout_failed then
    completion_message = completion_message .. "; abandoned remaining defense after " .. task_state.reserved_layout_failed
  end

  if #seeded_items > 0 then
    completion_message = completion_message .. "; seeded " .. ctx.format_products(seeded_items)
  end

  ctx.complete_current_task(
    builder_state,
    task,
    completion_message
  )
end

function action_build.place_miner(builder_state, task, tick, ctx, refresh_task)
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
    local _, preserved_layout_entities = cleanup_placed_layout_entities(
      entity,
      task_state,
      "refunded after aborted build for " .. task.id,
      ctx
    )
    if #preserved_layout_entities > 0 then
      ctx.debug_log(
        "task " .. task.id .. ": preserving placed layout " ..
        ctx.format_products(preserved_layout_entities) ..
        " despite " .. reason
      )
    end
    refresh_task(builder_state, task, tick, ctx)
    ctx.debug_log("task " .. task.id .. ": " .. reason)
  end

  local function abandon_partial_build(reason)
    ctx.complete_current_task(builder_state, task, reason)
  end

  local build_phase = get_next_build_phase(task_state, task)

  if build_phase == "place-miner" then
    if not can_place_entity_with_ground_item_clearance(
        surface,
        entity.force,
        task.miner_name,
        task_state.build_position,
        task_state.build_direction,
        task,
        ctx
      )
    then
      if try_clear_blocking_obstacle(builder_state, task, tick, task.miner_name, task_state.build_position, ctx) then
        return
      end
      ctx.debug_log("task " .. task.id .. ": build position became invalid at " .. ctx.format_position(task_state.build_position))
      refresh_task(builder_state, task, tick, ctx)
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
      refresh_task(builder_state, task, tick, ctx)
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
        ctx.debug_log("task " .. task.id .. ": miner at " .. ctx.format_position(task_state.build_position) .. " covered no " .. task.resource_name .. " in mining_area; immediate mining_target=" .. mining_target_name)
        refresh_task(builder_state, task, tick, ctx)
        return
      end
    end

    task_state.placed_miner = miner
    if not consume_build_item(task.miner_name, miner) then
      refresh_task(builder_state, task, tick, ctx)
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
      if task.defer_downstream_planning and ctx.find_downstream_machine_site then
        local site = ctx.find_downstream_machine_site(surface, entity.force, task, miner)
        if not site then
          if task.abandon_partial_site_on_failure then
            abandon_partial_build(
              "abandoned partial site after failing to place " ..
                task.downstream_machine.name ..
                " for miner at " ..
                ctx.format_position(miner.position)
            )
          else
            abort_build("missing downstream machine position")
          end
          return
        end

        task_state.downstream_machine_position = site.downstream_machine_position
        task_state.output_container_position = site.output_container_position
        ctx.debug_log(
          "task " .. task.id .. ": resolved " .. task.downstream_machine.name ..
            " at " .. ctx.format_position(task_state.downstream_machine_position)
        )
      else
        abort_build("missing downstream machine position")
        return
      end
    end

    if not can_place_entity_with_ground_item_clearance(
        surface,
        entity.force,
        task.downstream_machine.name,
        task_state.downstream_machine_position,
        nil,
        task,
        ctx
      )
    then
      if try_clear_blocking_obstacle(
        builder_state,
        task,
        tick,
        task.downstream_machine.name,
        task_state.downstream_machine_position,
        ctx
      ) then
        return
      end
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
      abort_build(task.downstream_machine.name .. " no longer covers miner drop position at " .. ctx.format_position(miner.drop_position))
      return
    end

    task_state.placed_downstream_machine = downstream_machine
    if not consume_build_item(task.downstream_machine.name, downstream_machine) then
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

    if not can_place_entity_with_ground_item_clearance(
        surface,
        entity.force,
        task.output_container.name,
        task_state.output_container_position,
        nil,
        task,
        ctx
      )
    then
      if try_clear_blocking_obstacle(
        builder_state,
        task,
        tick,
        task.output_container.name,
        task_state.output_container_position,
        ctx
      ) then
        return
      end
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

  if build_phase == "place-output-belt-layout" then
    if not task_state.layout_placements and task.defer_output_belt_planning and ctx.find_output_belt_layout_for_miner_site then
      local miner = task_state.placed_miner
      local downstream_machine = task_state.placed_downstream_machine
      local layout_site = nil
      local layout_summary = nil
      if miner and downstream_machine and miner.valid and downstream_machine.valid then
        layout_site, layout_summary = ctx.find_output_belt_layout_for_miner_site(
          surface,
          entity.force,
          task,
          miner,
          downstream_machine
        )
      end

      if not layout_site then
        local failure_detail = describe_output_belt_layout_failure(layout_summary)
        if task.abandon_partial_site_on_failure then
          abandon_partial_build(
            "abandoned partial site after failing output belt layout near " ..
              ctx.format_position(
                (downstream_machine and downstream_machine.valid and downstream_machine.position) or
                  (miner and miner.valid and miner.position) or
                  task_state.build_position
              ) ..
              (failure_detail and ("; " .. failure_detail) or "")
          )
        else
          abort_build("missing output belt layout" .. (failure_detail and ("; " .. failure_detail) or ""))
        end
        return
      end

      task_state.layout_placements = layout_site.placements
      task_state.layout_index = 1
      task_state.belt_hub_position = layout_site.hub_position
      task_state.belt_hub_key = layout_site.hub_key
      task_state.belt_terminal_position = layout_site.belt_terminal_position
      ctx.debug_log(
        "task " .. task.id .. ": resolved output belt layout toward " ..
          ctx.format_position(task_state.belt_hub_position or task_state.belt_terminal_position)
      )
    end

    local placement = task_state.layout_placements and task_state.layout_placements[task_state.layout_index]
    if not placement then
      task_state.phase = "build-complete"
      return
    end

    if not can_place_entity_with_ground_item_clearance(
        surface,
        entity.force,
        placement.entity_name,
        placement.build_position,
        placement.build_direction,
        task,
        ctx
      )
    then
      if try_clear_blocking_obstacle(builder_state, task, tick, placement.entity_name, placement.build_position, ctx) then
        return
      end
      abort_build("output belt layout position became invalid for " .. placement.entity_name .. " at " .. ctx.format_position(placement.build_position))
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

    if not consume_build_item(placement.item_name, placed_entity) then
      abort_build("missing " .. placement.item_name .. " in builder inventory")
      return
    end

    ctx.insert_entity_fuel(placed_entity, placement.fuel)

    task_state.placed_layout_entities = task_state.placed_layout_entities or {}
    task_state.placed_layout_entities[#task_state.placed_layout_entities + 1] = {
      id = placement.id,
      site_role = placement.site_role,
      route_id = placement.route_id,
      entity = placed_entity
    }

    ctx.debug_log(
      "task " .. task.id .. ": placed " .. placement.entity_name ..
      " at " .. ctx.format_position(placed_entity.position) ..
      (placement.site_role and " as " .. placement.site_role or "")
    )

    task_state.layout_index = (task_state.layout_index or 1) + 1
    begin_post_place_pause(
      builder_state,
      task,
      tick,
      task_state.layout_index > #(task_state.layout_placements or {}) and "build-complete" or "building",
      placed_entity,
      ctx
    )
    return
  end

  action_build.finish_place_miner_task(builder_state, task, tick, ctx, refresh_task)
end

function action_build.place_machine_near_site(builder_state, task, tick, ctx, refresh_task)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local surface = entity.surface
  local consumed_item_name = ctx.get_task_consumed_item_name(task)

  local function record_consumed_build_item(item_name, count)
    if not task.consume_items_on_place then
      return
    end

    task_state.consumed_build_items = task_state.consumed_build_items or {}
    task_state.consumed_build_items[item_name] = (task_state.consumed_build_items[item_name] or 0) + (count or 1)
  end

  local function abort_build(reason)
    local _, preserved_layout_entities = cleanup_placed_layout_entities(
      entity,
      task_state,
      "refunded after aborted reserved layout for " .. task.id,
      ctx
    )
    if #preserved_layout_entities > 0 then
      ctx.debug_log(
        "task " .. task.id .. ": preserving placed reserved layout " ..
        ctx.format_products(preserved_layout_entities) ..
        " despite " .. reason
      )
    end
    refresh_task(builder_state, task, tick, ctx)
    ctx.debug_log("task " .. task.id .. ": " .. reason)
  end

  local function complete_partial_site(reason)
    task_state.reserved_layout_failed = reason
    task_state.layout_resolution_complete = true
    ctx.debug_log("task " .. task.id .. ": " .. reason .. "; leaving partial site in place")
    action_build.finish_place_machine_near_site_task(builder_state, task, tick, ctx, refresh_task)
  end

  local function schedule_retry(wait_reason, reason)
    local _, preserved_layout_entities = cleanup_placed_layout_entities(
      entity,
      task_state,
      "refunded after delayed retry for " .. task.id,
      ctx
    )
    if #preserved_layout_entities > 0 then
      ctx.debug_log(
        "task " .. task.id .. ": preserving placed reserved layout " ..
        ctx.format_products(preserved_layout_entities) ..
        " before retry despite " .. reason
      )
    end
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
      if try_clear_blocking_obstacle(builder_state, task, tick, task.entity_name, task_state.build_position, ctx) then
        return
      end
      ctx.debug_log("task " .. task.id .. ": build position became invalid at " .. ctx.format_position(task_state.build_position))
      refresh_task(builder_state, task, tick, ctx)
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
      refresh_task(builder_state, task, tick, ctx)
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
      local recipe_enabled = entity.force.recipes and entity.force.recipes[task.recipe_name] and entity.force.recipes[task.recipe_name].enabled
      local recipe_set, recipe_error = try_set_entity_recipe(placed_entity, task.recipe_name)

      if not recipe_set then
        task_state.placed_entity = placed_entity
        schedule_retry(
          "recipe-unavailable",
          "failed to set recipe " .. task.recipe_name .. " on " .. task.entity_name ..
            " (force recipe enabled=" .. tostring(recipe_enabled) .. ", reason=" .. tostring(recipe_error) .. ")"
        )
        return
      end
    end

    task_state.placed_entity = placed_entity

    if task.consume_items_on_place then
      local reason = "placed " .. consumed_item_name .. " at " .. ctx.format_position(placed_entity.position)
      local removed_count = ctx.remove_item(entity, consumed_item_name, 1, reason)
      if removed_count < 1 then
        ctx.debug_log("task " .. task.id .. ": missing " .. consumed_item_name .. " in builder inventory for placement")
        refresh_task(builder_state, task, tick, ctx)
        return
      end

      task_state.consumed_machine_item = removed_count
    end

    ctx.debug_log(
      "task " .. task.id .. ": placed " .. task.entity_name ..
      " at " .. ctx.format_position(placed_entity.position) ..
      (task.recipe_name and " with recipe " .. task.recipe_name or "")
    )
    begin_post_place_pause(
      builder_state,
      task,
      tick,
      task.build_reserved_layout and "building" or "build-complete",
      placed_entity,
      ctx
    )
    return
  end

  if task.build_reserved_layout then
    task_state.placed_layout_entities = task_state.placed_layout_entities or {}
    task_state.layout_index = task_state.layout_index or 1

    if not task_state.layout_resolution_complete then
      local layout_site = ctx.find_reserved_layout_placements and
        ctx.find_reserved_layout_placements(surface, entity.force, task, task_state.placed_entity) or nil

      task_state.layout_resolution_complete = true

      if not layout_site then
        if task.abandon_partial_site_on_failure then
          complete_partial_site(
            "could not resolve reserved defense layout around " ..
              task.entity_name .. " at " .. ctx.format_position(task_state.placed_entity.position)
          )
          return
        end

        abort_build("missing reserved defense layout")
        return
      end

      task_state.layout_orientation = layout_site.orientation
      task_state.layout_placements = layout_site.placements or {}
      ctx.debug_log(
        "task " .. task.id .. ": resolved reserved defense layout using orientation " ..
          tostring(task_state.layout_orientation) ..
          " with " .. tostring(#task_state.layout_placements) .. " support placements"
      )

      if #task_state.layout_placements == 0 then
        action_build.finish_place_machine_near_site_task(builder_state, task, tick, ctx, refresh_task)
        return
      end
    end

    local placement = task_state.layout_placements and task_state.layout_placements[task_state.layout_index]
    if placement then
      if not surface.can_place_entity{
        name = placement.entity_name,
        position = placement.build_position,
        direction = placement.build_direction,
        force = entity.force
      } then
        if try_clear_blocking_obstacle(builder_state, task, tick, placement.entity_name, placement.build_position, ctx) then
          return
        end

        if task.abandon_partial_site_on_failure then
          complete_partial_site(
            "reserved defense position became invalid for " ..
              placement.entity_name .. " at " .. ctx.format_position(placement.build_position)
          )
          return
        end

        abort_build("reserved defense position became invalid for " .. placement.entity_name .. " at " .. ctx.format_position(placement.build_position))
        return
      end

      local placed_support_entity = surface.create_entity{
        name = placement.entity_name,
        position = placement.build_position,
        direction = placement.build_direction,
        force = entity.force,
        create_build_effect_smoke = false
      }

      if not placed_support_entity then
        if task.abandon_partial_site_on_failure then
          complete_partial_site("failed to place " .. placement.entity_name .. " at " .. ctx.format_position(placement.build_position))
          return
        end

        abort_build("failed to place " .. placement.entity_name .. " at " .. ctx.format_position(placement.build_position))
        return
      end

      if placement.recipe_name then
        local recipe_set, recipe_error = try_set_entity_recipe(placed_support_entity, placement.recipe_name)
        if not recipe_set then
          if task.abandon_partial_site_on_failure then
            complete_partial_site(
              "failed to set recipe " .. placement.recipe_name ..
                " on " .. placement.entity_name .. ": " .. tostring(recipe_error)
            )
            return
          end

          abort_build("failed to set recipe " .. placement.recipe_name .. " on " .. placement.entity_name .. ": " .. tostring(recipe_error))
          return
        end
      end

      if task.consume_items_on_place then
        local removed_count = ctx.remove_item(
          entity,
          placement.item_name,
          1,
          "placed " .. placement.item_name .. " at " .. ctx.format_position(placed_support_entity.position)
        )
        if removed_count < 1 then
          if task.abandon_partial_site_on_failure then
            complete_partial_site("missing " .. placement.item_name .. " in builder inventory")
            return
          end

          abort_build("missing " .. placement.item_name .. " in builder inventory")
          return
        end

        record_consumed_build_item(placement.item_name, removed_count)
      end

      ctx.insert_entity_fuel(placed_support_entity, placement.fuel)

      task_state.placed_layout_entities[#task_state.placed_layout_entities + 1] = {
        id = placement.id,
        site_role = placement.site_role,
        route_id = placement.route_id,
        entity = placed_support_entity
      }

      ctx.debug_log(
        "task " .. task.id .. ": placed reserved " .. placement.entity_name ..
          " at " .. ctx.format_position(placed_support_entity.position) ..
          (placement.site_role and " as " .. placement.site_role or "")
      )

      task_state.layout_index = task_state.layout_index + 1
      begin_post_place_pause(
        builder_state,
        task,
        tick,
        task_state.layout_index > #(task_state.layout_placements or {}) and "build-complete" or "building",
        placed_support_entity,
        ctx
      )
      return
    end
  end

  action_build.finish_place_machine_near_site_task(builder_state, task, tick, ctx, refresh_task)
end

function action_build.place_layout_near_machine(builder_state, task, tick, ctx, refresh_task)
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

  local function abort_build(reason)
    local _, preserved_layout_entities = cleanup_placed_layout_entities(
      entity,
      task_state,
      "refunded after aborted build for " .. task.id,
      ctx
    )
    if #preserved_layout_entities > 0 then
      ctx.debug_log(
        "task " .. task.id .. ": preserving placed layout " ..
        ctx.format_products(preserved_layout_entities) ..
        " despite " .. reason
      )
    end
    refresh_task(builder_state, task, tick, ctx)
    ctx.debug_log("task " .. task.id .. ": " .. reason)
  end

  local placement = task_state.layout_placements and task_state.layout_placements[task_state.layout_index]
  if not placement then
    task_state.phase = "build-complete"
    return
  end

  if not can_place_entity_with_ground_item_clearance(
      surface,
      entity.force,
      placement.entity_name,
      placement.build_position,
      placement.build_direction,
      task,
      ctx
    )
  then
    if try_clear_blocking_obstacle(builder_state, task, tick, placement.entity_name, placement.build_position, ctx) then
      return
    end
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

  if placement.recipe_name then
    local recipe_set, recipe_error = try_set_entity_recipe(placed_entity, placement.recipe_name)
    if not recipe_set then
      abort_build("failed to set recipe " .. placement.recipe_name .. " on " .. placement.entity_name .. ": " .. tostring(recipe_error))
      return
    end
  end

  if task.consume_items_on_place then
    local removed_count = ctx.remove_item(
      entity,
      placement.item_name,
      1,
      "placed " .. placement.item_name .. " at " .. ctx.format_position(placed_entity.position)
    )
    if removed_count < 1 then
      abort_build("missing " .. placement.item_name .. " in builder inventory")
      return
    end

    record_consumed_build_item(placement.item_name, removed_count)
  end

  ctx.insert_entity_fuel(placed_entity, placement.fuel)

  task_state.placed_layout_entities[#task_state.placed_layout_entities + 1] = {
    id = placement.id,
    site_role = placement.site_role,
    route_id = placement.route_id,
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

function action_build.advance_post_place_pause(builder_state, task, tick, ctx)
  if tick >= (builder_state.task_state.pause_until_tick or 0) then
    builder_state.task_state.phase = builder_state.task_state.next_phase or "building"
    builder_state.task_state.pause_until_tick = nil
    builder_state.task_state.next_phase = nil
    builder_state.task_state.pause_reason = nil
    ctx.debug_log("task " .. task.id .. ": post-build pause complete; resuming " .. builder_state.task_state.phase)
  end
end

return action_build

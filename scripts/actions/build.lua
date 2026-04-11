local action_build = {}

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

function action_build.finish_place_machine_near_site_task(builder_state, task, tick, ctx, refresh_task)
  local task_state = builder_state.task_state
  local placed_entity = task_state.placed_entity

  if not (placed_entity and placed_entity.valid) then
    ctx.debug_log("task " .. task.id .. ": build finished without a valid " .. task.entity_name .. "; refreshing task")
    refresh_task(builder_state, task, tick, ctx)
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
    refresh_task(builder_state, task, tick, ctx)
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
        miner.destroy()
        ctx.debug_log("task " .. task.id .. ": miner at " .. ctx.format_position(task_state.build_position) .. " covered no " .. task.resource_name .. " in mining_area; immediate mining_target=" .. mining_target_name)
        refresh_task(builder_state, task, tick, ctx)
        return
      end
    end

    task_state.placed_miner = miner
    if not consume_build_item(task.miner_name, miner) then
      miner.destroy()
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

  action_build.finish_place_miner_task(builder_state, task, tick, ctx, refresh_task)
end

function action_build.place_machine_near_site(builder_state, task, tick, ctx, refresh_task)
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
    refresh_task(builder_state, task, tick, ctx)
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
    begin_post_place_pause(builder_state, task, tick, "build-complete", placed_entity, ctx)
    return
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
    refresh_task(builder_state, task, tick, ctx)
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

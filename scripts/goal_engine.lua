local common = require("scripts.goal.common")
local instances = require("scripts.goal.instances")
local predicates = require("scripts.goal.predicates")
local trace = require("scripts.goal.trace")
local goal_tree = require("scripts.goal_tree")

local goal_engine = {}

local function create_scaling_build_task(builder_data, get_site_pattern, pattern_name)
  local pattern = get_site_pattern(pattern_name)
  if not pattern then
    return nil
  end

  local task = common.deep_copy(pattern.build_task)
  task.id = "scale-build-" .. pattern_name
  task.no_advance = true
  task.consume_items_on_place = true
  task.scaling_pattern_name = pattern_name
  return task
end

local function create_scaling_gather_task(builder_data, item_name, target_count)
  local scaling = builder_data.scaling
  local source_set = scaling and scaling.gather_source_set and builder_data.world_item_sources and builder_data.world_item_sources[scaling.gather_source_set]
  if not source_set then
    return nil
  end

  return {
    id = "scale-gather-" .. item_name,
    type = "gather-world-items",
    no_advance = true,
    search_retry_ticks = source_set.search_retry_ticks,
    arrival_distance = source_set.arrival_distance,
    stuck_retry_ticks = source_set.stuck_retry_ticks,
    mining_duration_ticks = source_set.mining_duration_ticks,
    inventory_targets = {
      {name = item_name, count = target_count}
    },
    sources = source_set.sources
  }
end

local function create_scaling_milestone_task(milestone)
  if not (milestone and milestone.task) then
    return nil
  end

  local task = common.deep_copy(milestone.task)
  task.id = task.id or ("scale-milestone-" .. milestone.name)
  task.no_advance = true
  task.consume_items_on_place = true
  task.completed_scaling_milestone_name = milestone.name
  return task
end

local function create_scaling_repeatable_milestone_task(milestone)
  local task = create_scaling_milestone_task(milestone)
  if not task then
    return nil
  end

  task.completed_scaling_milestone_name = nil
  task.repeatable_scaling_milestone_name = milestone.name
  return task
end

function goal_engine.normalize_scaling_active_task(builder_data, builder_state, adapters)
  local task = builder_state and builder_state.scaling_active_task or nil
  if not task then
    return
  end

  if task.completed_scaling_milestone_name then
    local milestone = predicates.get_milestone(builder_data, task.completed_scaling_milestone_name)
    if milestone then
      builder_state.scaling_active_task = create_scaling_milestone_task(milestone)
      return
    end
  end

  if task.repeatable_scaling_milestone_name then
    local milestone = predicates.get_milestone(builder_data, task.repeatable_scaling_milestone_name)
    if milestone then
      builder_state.scaling_active_task = create_scaling_repeatable_milestone_task(milestone)
      return
    end
  end

  if task.scaling_pattern_name then
    local normalized_task = create_scaling_build_task(builder_data, adapters.get_site_pattern, task.scaling_pattern_name)
    if normalized_task then
      builder_state.scaling_active_task = normalized_task
    end
  end
end

function goal_engine.get_pending_scaling_milestone(builder_data, builder_state, tick, adapters)
  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if
      not adapters.is_goal_retry_blocked(builder_state, "milestone:" .. milestone.name, tick) and
      not builder_state.completed_scaling_milestones[milestone.name]
    then
      return milestone
    end
  end

  return nil
end

function goal_engine.resolve_required_items(builder_data, entity, required_items, adapters)
  return predicates.resolve_required_items(entity, required_items, adapters.get_item_count, function(item_name)
    return predicates.get_recipe(builder_data, item_name)
  end)
end

local function set_scaling_display_task(builder_state, task)
  local state = instances.ensure_state(builder_state)
  if not state then
    return
  end

  state.scaling_display_task = task and common.deep_copy(task) or nil
end

local function start_scaling_wait(builder_data, builder_state, tick, wait_reason, message, display_task, adapters)
  local idle_retry_ticks = (builder_data.scaling and builder_data.scaling.idle_retry_ticks) or (2 * 60)
  builder_state.task_state = {
    phase = "scaling-waiting",
    wait_reason = wait_reason,
    next_attempt_tick = tick + idle_retry_ticks
  }

  set_scaling_display_task(builder_state, display_task)
  adapters.record_recovery(builder_state, {
    kind = "scaling-wait",
    message = message or ("scaling wait: " .. tostring(wait_reason)),
    meta = {
      wait_reason = wait_reason,
      next_attempt_tick = builder_state.task_state.next_attempt_tick
    }
  })

  if message then
    adapters.debug_log(message .. "; retry at tick " .. builder_state.task_state.next_attempt_tick)
  end
end

local function find_collectable_site(builder_state, item_name, allow_empty, adapters)
  adapters.discover_resource_sites(builder_state)

  local builder = builder_state.entity
  local best_site = nil
  local best_distance = nil
  local best_count = nil

  for _, site in ipairs(adapters.cleanup_resource_sites()) do
    local allowed_item_names = adapters.get_site_allowed_items(site)
    if not item_name or (allowed_item_names and allowed_item_names[item_name]) then
      local collect_position = adapters.get_site_collect_position(site)
      local collect_count = adapters.get_site_collect_count(site, item_name)

      if collect_position and (collect_count > 0 or allow_empty) then
        local distance = adapters.square_distance(builder.position, collect_position)
        if not best_site or
          collect_count > (best_count or -1) or
          (collect_count == best_count and (not best_distance or distance < best_distance))
        then
          best_site = site
          best_count = collect_count
          best_distance = distance
        end
      end
    end
  end

  return best_site
end

local function start_scaling_collection(builder_state, site, item_name, tick, allow_wait_for_items, display_task, adapters)
  local collect_position = adapters.get_site_collect_position(site)
  if not collect_position then
    start_scaling_wait(
      adapters.builder_data,
      builder_state,
      tick,
      "missing-site-position",
      "scaling: site " .. (site.pattern_name or "?") .. " lost its collection position",
      display_task,
      adapters
    )
    return
  end

  set_scaling_display_task(builder_state, display_task)
  builder_state.task_state = {
    phase = "scaling-moving-to-site",
    scaling_site = site,
    target_item_name = item_name,
    allowed_item_names = adapters.get_site_allowed_items(site),
    allow_wait_for_items = allow_wait_for_items == true,
    target_position = collect_position,
    approach_position = adapters.create_task_approach_position(nil, collect_position, 1.1),
    last_position = common.clone_position(builder_state.entity.position),
    last_progress_tick = tick
  }

  adapters.debug_log(
    "scaling: moving to " .. (site.pattern_name or "site") .. " at " ..
    adapters.format_position(collect_position) .. " to collect " .. (item_name or "items")
  )
end

local function start_scaling_craft(builder_data, builder_state, action, tick, display_task, adapters)
  local produced_count = action.count
  local craft_runs = action.craft_runs or produced_count
  local reason = "started crafting " .. action.item_name .. " x" .. produced_count
  local removed_ingredients = adapters.consume_recipe_ingredients(builder_state.entity, action.recipe, craft_runs, reason)
  if not removed_ingredients then
    start_scaling_wait(
      builder_data,
      builder_state,
      tick,
      "missing-craft-ingredients",
      "scaling: missing ingredients to craft " .. action.item_name,
      display_task,
      adapters
    )
    return
  end

  set_scaling_display_task(builder_state, display_task)
  builder_state.task_state = {
    phase = "scaling-crafting",
    craft_item_name = action.item_name,
    craft_count = produced_count,
    craft_runs = craft_runs,
    craft_complete_tick = tick + (action.recipe.craft_ticks * craft_runs)
  }

  adapters.debug_log(
    "scaling: crafting " .. action.item_name .. " x" .. produced_count ..
    " over " .. craft_runs .. " run(s) until tick " .. builder_state.task_state.craft_complete_tick
  )
end

local function finish_scaling_craft(builder_state, adapters)
  local task_state = builder_state.task_state
  local inserted_count = adapters.insert_item(
    builder_state.entity,
    task_state.craft_item_name,
    task_state.craft_count,
    "completed crafting " .. task_state.craft_item_name
  )

  adapters.debug_log(
    "scaling: completed crafting " .. task_state.craft_item_name ..
    " x" .. inserted_count
  )

  builder_state.task_state = nil
end

local function start_scaling_subtask(builder_state, task, tick, adapters)
  builder_state.scaling_active_task = task
  set_scaling_display_task(builder_state, task)
  adapters.start_task(builder_state, task, tick)
  if not builder_state.task_state then
    builder_state.scaling_active_task = nil
  end
end

local function plan_scaling_required_items(builder_data, builder_state, required_items, tick, display_task, adapters)
  local action = predicates.resolve_required_items(
    builder_state.entity,
    required_items,
    adapters.get_item_count,
    function(item_name)
      return predicates.get_recipe(builder_data, item_name)
    end
  )

  if not action then
    return false
  end

  if action.kind == "craft" then
    start_scaling_craft(builder_data, builder_state, action, tick, display_task, adapters)
    return true
  end

  if action.kind == "collect-ingredient" then
    local site = find_collectable_site(builder_state, action.item_name, false, adapters)
    if site then
      start_scaling_collection(builder_state, site, action.item_name, tick, false, display_task, adapters)
      return true
    end

    local producer = builder_data.scaling and builder_data.scaling.collect_ingredient_producers and
      builder_data.scaling.collect_ingredient_producers[action.item_name]
    if producer and producer.pattern_name then
      local site_counts = adapters.get_resource_site_counts()
      local current_site_count = site_counts[producer.pattern_name] or 0
      local minimum_site_count = producer.minimum_site_count or 1

      if current_site_count < minimum_site_count then
        local producer_pattern = adapters.get_site_pattern(producer.pattern_name)
        if producer_pattern and producer_pattern.required_items and
          plan_scaling_required_items(builder_data, builder_state, producer_pattern.required_items, tick, display_task, adapters)
        then
          return true
        end

        local build_task = create_scaling_build_task(builder_data, adapters.get_site_pattern, producer.pattern_name)
        if build_task then
          start_scaling_subtask(builder_state, build_task, tick, adapters)
          return true
        end
      end
    end

    if action.item_name == "wood" or action.item_name == "stone" then
      local gather_task = create_scaling_gather_task(
        builder_data,
        action.item_name,
        adapters.get_item_count(builder_state.entity, action.item_name) + action.count
      )

      if not gather_task then
        start_scaling_wait(
          builder_data,
          builder_state,
          tick,
          "missing-gather-task",
          "scaling: no gather task configured for " .. action.item_name,
          display_task,
          adapters
        )
        return true
      end

      start_scaling_subtask(builder_state, gather_task, tick, adapters)
      return true
    end

    start_scaling_wait(
      builder_data,
      builder_state,
      tick,
      "waiting-for-" .. action.item_name,
      "scaling: waiting for " .. action.item_name .. " from existing sites",
      display_task,
      adapters
    )
    return true
  end

  return false
end

local function repeatable_scaling_task_has_site(builder_state, task, adapters)
  if not task then
    return false
  end

  if task.type == "place-layout-near-machine" then
    local site = adapters.find_layout_site_near_machine(builder_state, task)
    return site ~= nil
  end

  if task.type == "place-machine-near-site" then
    local site = adapters.find_machine_site_near_resource_sites(builder_state, task)
    return site ~= nil
  end

  return true
end

local function plan_repeatable_scaling_milestones(builder_data, builder_state, tick, adapters)
  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if milestone.repeat_when_eligible and builder_state.completed_scaling_milestones[milestone.name] then
      if not adapters.is_goal_retry_blocked(builder_state, "repeatable-milestone:" .. milestone.name, tick) then
        local task = create_scaling_repeatable_milestone_task(milestone)
        if task and repeatable_scaling_task_has_site(builder_state, task, adapters) then
          if plan_scaling_required_items(builder_data, builder_state, milestone.required_items, tick, task, adapters) then
            return true
          end

          start_scaling_subtask(builder_state, task, tick, adapters)
          return true
        end
      end
    end
  end

  return false
end

local function plan_scaling(builder_data, builder_state, tick, adapters)
  for _, reserve_item in ipairs((builder_data.scaling and builder_data.scaling.reserve_items) or {}) do
    if adapters.get_item_count(builder_state.entity, reserve_item.name) < reserve_item.count then
      local reserve_task = {
        id = "scale-reserve-" .. reserve_item.name,
        type = "scale-reserve",
        reserve_item_name = reserve_item.name
      }
      local site = find_collectable_site(builder_state, reserve_item.name, false, adapters)
      if site then
        start_scaling_collection(builder_state, site, reserve_item.name, tick, false, reserve_task, adapters)
      else
        start_scaling_wait(
          builder_data,
          builder_state,
          tick,
          "waiting-for-" .. reserve_item.name,
          "scaling: waiting for " .. reserve_item.name .. " from existing sites",
          reserve_task,
          adapters
        )
      end
      return
    end
  end

  local milestone = goal_engine.get_pending_scaling_milestone(builder_data, builder_state, tick, adapters)
  if milestone and predicates.should_pursue_milestone(builder_data, builder_state, milestone, adapters.get_item_count, function(item_name)
    return predicates.get_recipe(builder_data, item_name)
  end) then
    local task = create_scaling_milestone_task(milestone)
    if predicates.resolve_required_items(builder_state.entity, milestone.required_items, adapters.get_item_count, function(item_name)
      return predicates.get_recipe(builder_data, item_name)
    end) ~= nil then
      if plan_scaling_required_items(builder_data, builder_state, milestone.required_items, tick, task, adapters) then
        return
      end
    end

    if not task then
      start_scaling_wait(
        builder_data,
        builder_state,
        tick,
        "missing-milestone-task",
        "scaling: missing task for milestone " .. tostring(milestone.name),
        {id = "milestone-" .. milestone.name, completed_scaling_milestone_name = milestone.name},
        adapters
      )
      return
    end

    start_scaling_subtask(builder_state, task, tick, adapters)
    return
  end

  if plan_repeatable_scaling_milestones(builder_data, builder_state, tick, adapters) then
    return
  end

  local pattern_name = adapters.get_scaling_pattern_name(builder_state)
  if not pattern_name then
    set_scaling_display_task(builder_state, nil)
    adapters.set_idle(builder_state.entity)
    return
  end

  local pattern = adapters.get_site_pattern(pattern_name)
  if not pattern then
    start_scaling_wait(
      builder_data,
      builder_state,
      tick,
      "unknown-pattern",
      "scaling: unknown pattern " .. tostring(pattern_name),
      {id = "pattern-" .. pattern_name, scaling_pattern_name = pattern_name},
      adapters
    )
    return
  end

  local build_task = create_scaling_build_task(builder_data, adapters.get_site_pattern, pattern_name)
  if plan_scaling_required_items(builder_data, builder_state, pattern.required_items, tick, build_task, adapters) then
    return
  end

  if not build_task then
    start_scaling_wait(
      builder_data,
      builder_state,
      tick,
      "missing-build-task",
      "scaling: missing build task for pattern " .. pattern_name,
      {id = "pattern-" .. pattern_name, scaling_pattern_name = pattern_name},
      adapters
    )
    return
  end

  start_scaling_subtask(builder_state, build_task, tick, adapters)
end

local function advance_scaling(builder_data, builder_state, tick, adapters)
  adapters.discover_resource_sites(builder_state)

  if builder_state.scaling_active_task and builder_state.task_state then
    set_scaling_display_task(builder_state, builder_state.scaling_active_task)
    adapters.advance_task_phase(builder_state, builder_state.scaling_active_task, tick)
    return
  end

  builder_state.scaling_active_task = nil

  if not builder_state.task_state then
    plan_scaling(builder_data, builder_state, tick, adapters)
    return
  end

  local phase = builder_state.task_state.phase

  if phase == "scaling-waiting" then
    if tick >= (builder_state.task_state.next_attempt_tick or 0) then
      builder_state.task_state = nil
    end
    return
  end

  if phase == "scaling-moving-to-site" then
    local entity = builder_state.entity
    local task_state = builder_state.task_state
    local destination_position = task_state.target_position
    local movement_position = task_state.approach_position or destination_position

    if adapters.square_distance(entity.position, destination_position) <= (1.1 * 1.1) then
      adapters.set_idle(entity)
      task_state.phase = "scaling-collecting-site"
      adapters.debug_log("scaling: reached collection site at " .. adapters.format_position(destination_position))
      return
    end

    local direction = adapters.direction_from_delta(
      movement_position.x - entity.position.x,
      movement_position.y - entity.position.y
    )

    if direction then
      entity.walking_state = {
        walking = true,
        direction = direction
      }
    end

    if adapters.square_distance(entity.position, task_state.last_position) > 0.0025 then
      task_state.last_position = common.clone_position(entity.position)
      task_state.last_progress_tick = tick
      return
    end

    if tick - task_state.last_progress_tick >= (3 * 60) then
      start_scaling_wait(
        builder_data,
        builder_state,
        tick,
        "collection-movement-stalled",
        "scaling: movement stalled while approaching collection site",
        instances.ensure_state(builder_state).scaling_display_task,
        adapters
      )
    end
    return
  end

  if phase == "scaling-collecting-site" then
    local task_state = builder_state.task_state
    local site = task_state.scaling_site
    local inventory = site and adapters.get_site_collect_inventory(site) or nil

    if not inventory then
      start_scaling_wait(
        builder_data,
        builder_state,
        tick,
        "site-inventory-missing",
        "scaling: site inventory disappeared before collection",
        instances.ensure_state(builder_state).scaling_display_task,
        adapters
      )
      return
    end

    local reason = "collected from " .. (site.pattern_name or "site") .. " at " .. adapters.format_position(task_state.target_position)
    local moved_items = adapters.pull_inventory_contents_to_builder(
      inventory,
      builder_state.entity,
      reason,
      task_state.allowed_item_names
    )

    if #moved_items == 0 then
      if task_state.allow_wait_for_items then
        local idle_retry_ticks = (builder_data.scaling and builder_data.scaling.idle_retry_ticks) or (2 * 60)
        builder_state.task_state.phase = "scaling-waiting-at-site"
        builder_state.task_state.wait_reason = "site-empty"
        builder_state.task_state.next_attempt_tick = tick + idle_retry_ticks
        adapters.debug_log(
          "scaling: " .. (site.pattern_name or "site") ..
          " has no collectable " .. (task_state.target_item_name or "items") ..
          " yet; waiting on-site until tick " .. builder_state.task_state.next_attempt_tick
        )
      else
        start_scaling_wait(
          builder_data,
          builder_state,
          tick,
          "site-empty",
          "scaling: " .. (site.pattern_name or "site") .. " had no collectable items",
          instances.ensure_state(builder_state).scaling_display_task,
          adapters
        )
      end
      return
    end

    adapters.debug_log("scaling: " .. reason .. "; moved " .. adapters.format_products(moved_items))
    builder_state.task_state = nil
    return
  end

  if phase == "scaling-crafting" then
    if tick >= (builder_state.task_state.craft_complete_tick or 0) then
      finish_scaling_craft(builder_state, adapters)
    end
    return
  end

  if phase == "scaling-waiting-at-site" then
    if tick >= (builder_state.task_state.next_attempt_tick or 0) then
      builder_state.task_state.phase = "scaling-collecting-site"
    end
    return
  end

  builder_state.task_state = nil
end

function goal_engine.get_active_task(builder_data, builder_state)
  if not builder_state then
    return nil
  end

  if builder_state.manual_goal_request and builder_state.manual_goal_request.tasks then
    return builder_state.manual_goal_request.tasks[builder_state.manual_goal_request.current_task_index or 1]
  end

  if builder_state.scaling_active_task then
    return builder_state.scaling_active_task
  end

  local plan = builder_data.plans[builder_state.plan_name]
  if not plan then
    return nil
  end

  return plan.tasks[builder_state.task_index]
end

function goal_engine.get_display_task(builder_data, builder_state)
  if not builder_state then
    return nil
  end

  local active_task = goal_engine.get_active_task(builder_data, builder_state)
  if active_task then
    return active_task
  end

  local state = instances.ensure_state(builder_state)
  return state and state.scaling_display_task or nil
end

function goal_engine.advance(builder_data, builder_state, tick, adapters)
  instances.ensure_state(builder_state)

  local task = goal_engine.get_active_task(builder_data, builder_state)
  if task then
    if not builder_state.task_state then
      adapters.start_task(builder_state, task, tick)
    else
      adapters.advance_task_phase(builder_state, task, tick)
    end
    return
  end

  if builder_data.scaling and builder_data.scaling.enabled then
    advance_scaling(builder_data, builder_state, tick, adapters)
  else
    set_scaling_display_task(builder_state, nil)
    adapters.set_idle(builder_state.entity)
  end
end

function goal_engine.sync_model(builder_data, builder_state, tick, adapters)
  instances.ensure_state(builder_state)

  local snapshot = adapters.build_runtime_snapshot(builder_state, tick)
  local root = goal_tree.build_runtime_tree(
    builder_data,
    snapshot,
    {
      get_item_count = adapters.get_item_count,
      get_recipe = function(item_name)
        return predicates.get_recipe(builder_data, item_name)
      end
    }
  )

  trace.sync_from_root(builder_state, root, tick, adapters.debug_log)

  builder_state.goal_tree_root = root
  builder_state.goal_path_lines = goal_tree.get_active_path_lines(root)
  builder_state.goal_blockers = goal_tree.get_blockers(root)
  builder_state.goal_blocker_lines = goal_tree.get_blocker_lines(root)
  return snapshot
end

function goal_engine.get_recent_trace_lines(builder_state, limit)
  return trace.get_recent_lines(builder_state, limit)
end

return goal_engine

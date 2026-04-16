local common = require("scripts.goal.common")
local instances = require("scripts.goal.instances")
local model = require("scripts.goal.model")
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
      predicates.is_milestone_unlocked(builder_state, milestone, adapters.get_resource_site_counts) and
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

local function sync_goal_model(builder_data, builder_state, options)
  return model.sync(builder_data, builder_state, options)
end

local function start_scaling_wait(builder_data, builder_state, tick, wait_reason, message, display_task, adapters)
  local idle_retry_ticks = (builder_data.scaling and builder_data.scaling.idle_retry_ticks) or (2 * 60)
  builder_state.task_state = {
    phase = "scaling-waiting",
    wait_reason = wait_reason,
    next_attempt_tick = tick + idle_retry_ticks
  }

  set_scaling_display_task(builder_state, display_task)
  model.set_scaling_focus(builder_data, builder_state, {
    id = "scaling-wait-" .. tostring(wait_reason),
    title = display_task and common.humanize_identifier(display_task.scaling_pattern_name or display_task.id or wait_reason) or "Scaling Wait",
    display_task = display_task,
    execution_kind = "scaling-phase",
    focus_kind = "wait",
    focus_name = wait_reason
  })
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

local function get_collectable_site_key(site)
  if not site then
    return nil
  end

  local identity_entity = site.identity_entity or site.downstream_machine or site.output_container or site.miner
  if identity_entity and identity_entity.valid and identity_entity.unit_number then
    return tostring(identity_entity.unit_number)
  end

  local collect_position = site.output_container and site.output_container.valid and site.output_container.position or
    site.downstream_machine and site.downstream_machine.valid and site.downstream_machine.position or
    site.miner and site.miner.valid and site.miner.position or
    nil

  if collect_position then
    return string.format(
      "%s:%.2f:%.2f",
      tostring(site.pattern_name or "site"),
      collect_position.x,
      collect_position.y
    )
  end

  return tostring(site.pattern_name or "site")
end

local function should_use_scaling_site_crawl(item_name)
  return item_name == "iron-plate"
end

local function get_scaling_collection_goal_count(item_name, adapters)
  local limits = adapters.builder_data and adapters.builder_data.logistics and adapters.builder_data.logistics.inventory_take_limits
  return limits and limits[item_name] or nil
end

local function get_active_scaling_collection_goal_count(task_state, adapters)
  if not task_state then
    return nil
  end

  if task_state.collection_goal_count then
    return task_state.collection_goal_count
  end

  return get_scaling_collection_goal_count(task_state.target_item_name, adapters)
end

local function finish_scaling_collection_if_goal_reached(builder_state, task_state, adapters)
  if not (builder_state and task_state and task_state.target_item_name) then
    return false
  end

  local goal_count = get_active_scaling_collection_goal_count(task_state, adapters)
  if not goal_count then
    return false
  end

  if adapters.get_item_count(builder_state.entity, task_state.target_item_name) < goal_count then
    return false
  end

  adapters.set_idle(builder_state.entity)
  adapters.debug_log(
    "scaling: reached " .. task_state.target_item_name ..
    " target " .. tostring(goal_count) ..
    (task_state.collection_mode == "wait-patrol" and " while patrolling; ending collection" or "; ending collection")
  )

  if builder_state.scaling_fuel_recovery and builder_state.scaling_fuel_recovery.item_name == task_state.target_item_name then
    reset_scaling_fuel_recovery_observation(builder_state)
  end

  builder_state.task_state = nil
  return true
end

local function find_random_collection_crawl_site(builder_state, item_name, origin_position, visited_site_keys, adapters)
  adapters.discover_resource_sites(builder_state)

  local candidates = {}
  for _, site in ipairs(adapters.cleanup_resource_sites()) do
    local site_key = get_collectable_site_key(site)
    local allowed_item_names = adapters.get_site_allowed_items(site)
    if
      site_key and
      (not (visited_site_keys and visited_site_keys[site_key])) and
      (not item_name or (allowed_item_names and allowed_item_names[item_name]))
    then
      local collect_position = adapters.get_site_collect_position(site)
      local collect_count = adapters.get_site_collect_count(site, item_name)
      if collect_position and collect_count > 0 then
        candidates[#candidates + 1] = {
          site = site,
          collect_position = collect_position,
          distance = adapters.square_distance(origin_position, collect_position)
        }
      end
    end
  end

  if #candidates == 0 then
    return nil, 0, 0
  end

  table.sort(candidates, function(left, right)
    return left.distance < right.distance
  end)

  local selection_pool_size = math.min(#candidates, 4)
  local selection_index = adapters.next_random_index and adapters.next_random_index(selection_pool_size) or 1
  local selected = candidates[selection_index]
  return selected and selected.site or nil, selection_pool_size, #candidates
end

local function get_wait_patrol_patterns(builder_data, item_name)
  local wait_patrol = builder_data.scaling and builder_data.scaling.wait_patrol
  if not wait_patrol then
    return nil
  end

  if item_name and wait_patrol.item_site_patterns and wait_patrol.item_site_patterns[item_name] then
    return wait_patrol.item_site_patterns[item_name]
  end

  return wait_patrol.fallback_site_patterns
end

local function get_scaling_collection_arrival_distance(builder_data, collection_mode)
  if collection_mode == "wait-patrol" then
    local wait_patrol = builder_data.scaling and builder_data.scaling.wait_patrol or nil
    local patrol_arrival_distance = wait_patrol and wait_patrol.arrival_distance or nil
    if patrol_arrival_distance and patrol_arrival_distance > 0 then
      return patrol_arrival_distance
    end
  end

  return 1.1
end

local function get_scaling_fuel_recovery_threshold(builder_data)
  local wait_patrol = builder_data.scaling and builder_data.scaling.wait_patrol or nil
  local threshold = wait_patrol and wait_patrol.fuel_recovery_unfueled_machine_threshold or nil
  if threshold and threshold > 0 then
    return math.max(1, math.floor(threshold))
  end

  return 3
end

local function site_matches_pattern_names(site, pattern_names)
  if not (site and pattern_names and site.pattern_name) then
    return false
  end

  for _, pattern_name in ipairs(pattern_names) do
    if site.pattern_name == pattern_name then
      return true
    end
  end

  return false
end

local function find_wait_patrol_site(builder_data, builder_state, item_name, adapters, exclude_site)
  local pattern_names = get_wait_patrol_patterns(builder_data, item_name)
  if not (pattern_names and #pattern_names > 0) then
    return nil
  end

  adapters.discover_resource_sites(builder_state)

  local pattern_priority = {}
  for index, pattern_name in ipairs(pattern_names) do
    pattern_priority[pattern_name] = index
  end

  local candidates = {}
  for _, site in ipairs(adapters.cleanup_resource_sites()) do
    local collect_position = adapters.get_site_collect_position(site)
    if collect_position and site_matches_pattern_names(site, pattern_names) and site ~= exclude_site then
      candidates[#candidates + 1] = {
        site = site,
        collect_position = collect_position
      }
    end
  end

  if #candidates == 0 and exclude_site then
    for _, site in ipairs(adapters.cleanup_resource_sites()) do
      local collect_position = adapters.get_site_collect_position(site)
      if collect_position and site_matches_pattern_names(site, pattern_names) then
        candidates[#candidates + 1] = {
          site = site,
          collect_position = collect_position
        }
      end
    end
  end

  if #candidates == 0 then
    return nil
  end

  table.sort(candidates, function(left, right)
    local left_priority = pattern_priority[left.site.pattern_name] or math.huge
    local right_priority = pattern_priority[right.site.pattern_name] or math.huge
    if left_priority ~= right_priority then
      return left_priority < right_priority
    end

    if left.collect_position.x ~= right.collect_position.x then
      return left.collect_position.x < right.collect_position.x
    end

    return left.collect_position.y < right.collect_position.y
  end)

  builder_state.scaling_wait_patrol_cursor = ((builder_state.scaling_wait_patrol_cursor or 0) % #candidates) + 1
  return candidates[builder_state.scaling_wait_patrol_cursor].site
end

local start_scaling_collection
local function reset_scaling_fuel_recovery_observation(builder_state)
  builder_state.scaling_fuel_recovery = nil
end

local function get_entity_total_fuel_count(entity)
  local fuel_inventory = entity and entity.valid and entity.get_fuel_inventory and entity.get_fuel_inventory() or nil
  if not fuel_inventory then
    return nil
  end

  local total_count = 0
  for _, item_stack in pairs(fuel_inventory.get_contents()) do
    if type(item_stack) == "number" then
      total_count = total_count + item_stack
    elseif type(item_stack) == "table" then
      total_count = total_count + (item_stack.count or 0)
    end
  end

  return total_count
end

local function collect_fuel_burner_entities_for_site(site)
  local burner_entities = {}
  local seen_entities = {}

  local function add_entity(entity)
    local fuel_count = get_entity_total_fuel_count(entity)
    if fuel_count == nil then
      return
    end

    local entity_key = entity.unit_number or (entity.name .. ":" .. entity.position.x .. ":" .. entity.position.y)
    if seen_entities[entity_key] then
      return
    end

    seen_entities[entity_key] = true
    burner_entities[#burner_entities + 1] = entity
  end

  add_entity(site and site.miner or nil)
  add_entity(site and site.downstream_machine or nil)
  add_entity(site and site.anchor_machine or nil)
  add_entity(site and site.feed_inserter or nil)
  add_entity(site and site.output_machine or nil)

  return burner_entities
end

local function get_fuel_observation_entity_key(entity)
  if not (entity and entity.valid) then
    return nil
  end

  return tostring(entity.unit_number or (entity.name .. ":" .. entity.position.x .. ":" .. entity.position.y))
end

local function note_unfueled_burner_entities(builder_state, item_name, site)
  if not (builder_state and item_name and site) then
    return 0, 0, 0
  end

  if not (builder_state.scaling_fuel_recovery and builder_state.scaling_fuel_recovery.item_name == item_name) then
    builder_state.scaling_fuel_recovery = {
      item_name = item_name,
      seen_site_keys = {},
      seen_entity_keys = {},
      unfueled_entity_count = 0,
      observed_site_count = 0
    }
  end

  local observation = builder_state.scaling_fuel_recovery
  local unfueled_entity_count = 0
  local new_entity_count = 0

  for _, burner_entity in ipairs(collect_fuel_burner_entities_for_site(site)) do
    if (get_entity_total_fuel_count(burner_entity) or 0) <= 0 then
      unfueled_entity_count = unfueled_entity_count + 1
      local entity_key = get_fuel_observation_entity_key(burner_entity)
      if entity_key and not observation.seen_entity_keys[entity_key] then
        observation.seen_entity_keys[entity_key] = true
        observation.unfueled_entity_count = (observation.unfueled_entity_count or 0) + 1
        new_entity_count = new_entity_count + 1
      end
    end
  end

  local site_key = get_collectable_site_key(site)
  if site_key and unfueled_entity_count > 0 and not observation.seen_site_keys[site_key] then
    observation.seen_site_keys[site_key] = true
    observation.observed_site_count = (observation.observed_site_count or 0) + 1
  end

  return unfueled_entity_count, observation.unfueled_entity_count or 0, new_entity_count
end

local function try_start_scaling_fuel_recovery(builder_data, builder_state, item_name, site, tick, display_task, adapters)
  if not item_name or item_name == "coal" or not site then
    return nil
  end

  if adapters.get_site_collect_count(site, item_name) > 0 then
    return nil
  end

  local site_unfueled_count, observed_unfueled_count, new_entity_count =
    note_unfueled_burner_entities(builder_state, item_name, site)
  if site_unfueled_count <= 0 then
    return nil
  end

  local threshold = get_scaling_fuel_recovery_threshold(builder_data)
  if new_entity_count > 0 and observed_unfueled_count < threshold then
    adapters.debug_log(
      "scaling: observed " .. tostring(site_unfueled_count) .. " unfueled burner machines at " ..
      ((site.pattern_name or "site")) .. " while waiting for " .. item_name ..
      " (" .. tostring(observed_unfueled_count) .. "/" .. tostring(threshold) .. ")"
    )
  end

  if observed_unfueled_count < threshold then
    return nil
  end

  local fuel_name = (((builder_data.logistics or {}).nearby_machine_refuel or {}).fuel_name) or "coal"
  local recovery_site = find_collectable_site(builder_state, fuel_name, false, adapters)
  if not recovery_site then
    return nil
  end

  local observation = builder_state.scaling_fuel_recovery or {}
  adapters.debug_log(
    "scaling: observed " .. tostring(observed_unfueled_count) .. " unfueled burner machines across " ..
    tostring(observation.observed_site_count or 0) .. " " .. common.humanize_identifier(item_name) ..
    " sites; collecting " .. fuel_name .. " to restart production"
  )
  reset_scaling_fuel_recovery_observation(builder_state)
  start_scaling_collection(builder_state, recovery_site, fuel_name, tick, false, display_task, adapters)
  return "fuel-recovery"
end

start_scaling_collection = function(builder_state, site, item_name, tick, allow_wait_for_items, display_task, adapters, options)
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

  if builder_state.scaling_fuel_recovery and builder_state.scaling_fuel_recovery.item_name ~= item_name then
    reset_scaling_fuel_recovery_observation(builder_state)
  end

  set_scaling_display_task(builder_state, display_task)
  model.set_scaling_focus(adapters.builder_data, builder_state, {
    id = "scaling-collect-" .. tostring(item_name or "items"),
    title = "Collect " .. common.humanize_identifier(item_name or "items"),
    display_task = display_task,
    execution_kind = "scaling-phase",
    focus_kind = "collect",
    focus_name = item_name
  })
  local collection_mode = options and options.collection_mode or "collect"
  local crawl_visited_site_keys = options and options.crawl_visited_site_keys or nil
  local collection_goal_count = options and options.collection_goal_count or nil
  local arrival_distance = get_scaling_collection_arrival_distance(adapters.builder_data, collection_mode)
  local phase = "scaling-moving-to-site"
  if collection_mode == "site-crawl" then
    crawl_visited_site_keys = crawl_visited_site_keys or {}
    collection_goal_count = collection_goal_count or get_scaling_collection_goal_count(item_name, adapters)
  end
  if adapters.square_distance(builder_state.entity.position, collect_position) <= (arrival_distance * arrival_distance) then
    phase = "scaling-collecting-site"
    adapters.set_idle(builder_state.entity)
  end
  builder_state.task_state = {
    phase = phase,
    scaling_site = site,
    target_item_name = item_name,
    allowed_item_names = adapters.get_site_allowed_items(site),
    allow_wait_for_items = allow_wait_for_items == true,
    collection_mode = collection_mode,
    crawl_visited_site_keys = crawl_visited_site_keys,
    collection_goal_count = collection_goal_count,
    arrival_distance = arrival_distance,
    target_position = collect_position,
    approach_position = adapters.create_task_approach_position(nil, collect_position, arrival_distance),
    last_position = common.clone_position(builder_state.entity.position),
    last_progress_tick = tick
  }

  if options and options.collection_mode == "wait-patrol" then
    adapters.debug_log(
      "scaling: patrolling " .. (site.pattern_name or "site") .. " at " ..
      adapters.format_position(collect_position) .. " while waiting for " .. (item_name or "items")
    )
  else
    adapters.debug_log(
      "scaling: moving to " .. (site.pattern_name or "site") .. " at " ..
      adapters.format_position(collect_position) .. " to collect " .. (item_name or "items") ..
      (collection_mode == "site-crawl" and collection_goal_count and (" while crawling sites up to " .. tostring(collection_goal_count)) or "")
    )
  end
end

local function start_scaling_wait_patrol(
  builder_data,
  builder_state,
  item_name,
  tick,
  display_task,
  adapters,
  exclude_site,
  collection_goal_count
)
  local site = find_wait_patrol_site(builder_data, builder_state, item_name, adapters, exclude_site)
  if not site then
    return nil
  end

  start_scaling_collection(
    builder_state,
    site,
    item_name,
    tick,
    false,
    display_task,
    adapters,
    {
      collection_mode = "wait-patrol",
      collection_goal_count = collection_goal_count
    }
  )
  return "wait-patrol"
end

local function continue_scaling_site_crawl(builder_state, tick, task_state, display_task, adapters)
  if not (task_state and task_state.collection_mode == "site-crawl" and task_state.target_item_name) then
    return false
  end

  local visited_site_keys = task_state.crawl_visited_site_keys or {}
  task_state.crawl_visited_site_keys = visited_site_keys

  local current_site_key = get_collectable_site_key(task_state.scaling_site)
  if current_site_key then
    visited_site_keys[current_site_key] = true
  end

  local goal_count = task_state.collection_goal_count or get_scaling_collection_goal_count(task_state.target_item_name, adapters)
  if goal_count and adapters.get_item_count(builder_state.entity, task_state.target_item_name) >= goal_count then
    adapters.debug_log(
      "scaling: site crawl reached " .. task_state.target_item_name ..
      " cap " .. tostring(goal_count)
    )
    builder_state.task_state = nil
    return true
  end

  local next_site, pool_size, candidate_count = find_random_collection_crawl_site(
    builder_state,
    task_state.target_item_name,
    task_state.target_position or builder_state.entity.position,
    visited_site_keys,
    adapters
  )

  if next_site then
    adapters.debug_log(
      "scaling: site crawl moving on to " .. (next_site.pattern_name or "site") ..
      " from a pool of " .. tostring(pool_size) ..
      " nearby candidates (" .. tostring(candidate_count) .. " total remaining)"
    )
    start_scaling_collection(
      builder_state,
      next_site,
      task_state.target_item_name,
      tick,
      false,
      display_task,
      adapters,
      {
        collection_mode = "site-crawl",
        crawl_visited_site_keys = visited_site_keys,
        collection_goal_count = goal_count
      }
    )
    return true
  end

  adapters.debug_log("scaling: site crawl exhausted " .. task_state.target_item_name .. " sites")
  builder_state.task_state = nil
  return true
end

local function normalize_scaling_collection_task_state(task_state, adapters)
  if not (task_state and should_use_scaling_site_crawl(task_state.target_item_name)) then
    return
  end

  if task_state.collection_mode == nil then
    task_state.collection_mode = "site-crawl"
  end

  if task_state.collection_mode == "site-crawl" then
    task_state.crawl_visited_site_keys = task_state.crawl_visited_site_keys or {}
    task_state.collection_goal_count = task_state.collection_goal_count or
      get_scaling_collection_goal_count(task_state.target_item_name, adapters)
  end
end

local function handle_empty_scaling_collection_site(builder_data, builder_state, tick, task_state, display_task, adapters)
  normalize_scaling_collection_task_state(task_state, adapters)

  if continue_scaling_site_crawl(builder_state, tick, task_state, display_task, adapters) then
    return true
  end

  local item_name = task_state and task_state.target_item_name or nil
  local current_site = task_state and task_state.scaling_site or nil
  local collection_goal_count = task_state and task_state.collection_goal_count or nil
  local fuel_recovery_result =
    try_start_scaling_fuel_recovery(builder_data, builder_state, item_name, current_site, tick, display_task, adapters)
  if fuel_recovery_result then
    return true
  end

  local alternate_site = find_collectable_site(builder_state, item_name, false, adapters)

  if alternate_site and alternate_site ~= current_site then
    adapters.debug_log(
      "scaling: " .. ((current_site and current_site.pattern_name) or "site") ..
      " yielded no collectable items on arrival; switching to " .. (alternate_site.pattern_name or "site")
    )
    start_scaling_collection(
      builder_state,
      alternate_site,
      item_name,
      tick,
      false,
      display_task,
      adapters,
      {collection_goal_count = collection_goal_count}
    )
    return true
  end

  local wait_patrol_result =
    start_scaling_wait_patrol(
      builder_data,
      builder_state,
      item_name,
      tick,
      display_task,
      adapters,
      current_site,
      collection_goal_count
    )
  if wait_patrol_result then
    if wait_patrol_result == "wait-patrol" then
      adapters.debug_log(
        "scaling: " .. ((current_site and current_site.pattern_name) or "site") ..
        " yielded no collectable items on arrival; patrolling other sites for " .. (item_name or "items")
      )
    end
    return true
  end

  return false
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
  model.set_scaling_focus(builder_data, builder_state, {
    id = "scaling-craft-" .. tostring(action.item_name),
    title = "Craft " .. common.humanize_identifier(action.item_name),
    display_task = display_task,
    execution_kind = "scaling-phase",
    focus_kind = "craft",
    focus_name = action.item_name
  })
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
  model.clear_scaling_focus(adapters.builder_data, builder_state)
end

local function start_scaling_subtask(builder_state, task, tick, adapters)
  builder_state.scaling_active_task = task
  set_scaling_display_task(builder_state, task)
  model.set_scaling_focus(adapters.builder_data, builder_state, {
    id = "scaling-task-" .. tostring(task.id or task.type or "task"),
    title = common.humanize_identifier(task.scaling_pattern_name or task.id or task.type or "task"),
    task = task,
    display_task = task,
    execution_kind = "task",
    focus_kind = "task",
    focus_name = task.scaling_pattern_name or task.id or task.type
  })
  adapters.start_task(builder_state, task, tick)
  if not builder_state.task_state then
    builder_state.scaling_active_task = nil
    model.clear_scaling_focus(adapters.builder_data, builder_state)
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
    local collection_goal_count = adapters.get_item_count(builder_state.entity, action.item_name) + action.count
    local site = find_collectable_site(builder_state, action.item_name, false, adapters)
    if site then
      local collection_options = {
        collection_goal_count = collection_goal_count
      }
      if should_use_scaling_site_crawl(action.item_name) then
        collection_options.collection_mode = "site-crawl"
        collection_options.collection_goal_count = get_scaling_collection_goal_count(action.item_name, adapters)
      end
      start_scaling_collection(builder_state, site, action.item_name, tick, false, display_task, adapters, collection_options)
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

    if start_scaling_wait_patrol(
      builder_data,
      builder_state,
      action.item_name,
      tick,
      display_task,
      adapters,
      nil,
      collection_goal_count
    ) then
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

local function plan_scaling_reserves(builder_data, builder_state, tick, adapters)
  for _, reserve_item in ipairs((builder_data.scaling and builder_data.scaling.reserve_items) or {}) do
    if predicates.unlock_requirements_met(builder_state, reserve_item.unlock, adapters.get_resource_site_counts) then
      if adapters.get_item_count(builder_state.entity, reserve_item.name) < reserve_item.count then
        local reserve_task = {
          id = "scale-reserve-" .. reserve_item.name,
          type = "scale-reserve",
          reserve_item_name = reserve_item.name
        }
        local site = find_collectable_site(builder_state, reserve_item.name, false, adapters)
        if site then
          start_scaling_collection(
            builder_state,
            site,
            reserve_item.name,
            tick,
            false,
            reserve_task,
            adapters,
            {collection_goal_count = reserve_item.count}
          )
        elseif start_scaling_wait_patrol(
          builder_data,
          builder_state,
          reserve_item.name,
          tick,
          reserve_task,
          adapters,
          nil,
          reserve_item.count
        ) then
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
        return true
      end
    end
  end

  return false
end

local function plan_repeatable_scaling_milestones(builder_data, builder_state, tick, adapters)
  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if milestone.repeat_when_eligible and builder_state.completed_scaling_milestones[milestone.name] then
      if not adapters.is_goal_retry_blocked(builder_state, "repeatable-milestone:" .. milestone.name, tick) then
        local task = create_scaling_repeatable_milestone_task(milestone)
        if task then
          if plan_scaling_required_items(builder_data, builder_state, milestone.required_items, tick, task, adapters) then
            return true
          end

          -- Keep planning cheap. Task start owns the expensive site search and retry behavior.
          start_scaling_subtask(builder_state, task, tick, adapters)
          return true
        end
      end
    end
  end

  return false
end

local function plan_scaling(builder_data, builder_state, tick, adapters)
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
    if not plan_scaling_reserves(builder_data, builder_state, tick, adapters) then
      set_scaling_display_task(builder_state, nil)
      adapters.set_idle(builder_state.entity)
    end
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

  -- Avoid running heavyweight placement searches during planning. The task start
  -- path performs the real search once and handles backoff if no site exists.
  start_scaling_subtask(builder_state, build_task, tick, adapters)
end

local function advance_scaling(builder_data, builder_state, tick, adapters)
  if builder_state.scaling_active_task and builder_state.task_state then
    normalize_scaling_collection_task_state(builder_state.task_state, adapters)
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
    normalize_scaling_collection_task_state(task_state, adapters)
    if finish_scaling_collection_if_goal_reached(builder_state, task_state, adapters) then
      return
    end
    local destination_position = task_state.target_position
    local movement_position = task_state.approach_position or destination_position
    local arrival_distance = task_state.arrival_distance or 1.1

    if adapters.square_distance(entity.position, destination_position) <= (arrival_distance * arrival_distance) then
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
    normalize_scaling_collection_task_state(task_state, adapters)
    if finish_scaling_collection_if_goal_reached(builder_state, task_state, adapters) then
      return
    end
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
        if handle_empty_scaling_collection_site(
          builder_data,
          builder_state,
          tick,
          task_state,
          instances.ensure_state(builder_state).scaling_display_task,
          adapters
        ) then
          return
        end

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
    if builder_state.scaling_fuel_recovery and builder_state.scaling_fuel_recovery.item_name == task_state.target_item_name then
      reset_scaling_fuel_recovery_observation(builder_state)
    end
    if continue_scaling_site_crawl(
        builder_state,
        tick,
        task_state,
        instances.ensure_state(builder_state).scaling_display_task,
        adapters
      )
    then
      return
    end

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
    normalize_scaling_collection_task_state(builder_state.task_state, adapters)
    if finish_scaling_collection_if_goal_reached(builder_state, builder_state.task_state, adapters) then
      return
    end
    if tick >= (builder_state.task_state.next_attempt_tick or 0) then
      builder_state.task_state.phase = "scaling-collecting-site"
    end
    return
  end

  builder_state.task_state = nil
end

function goal_engine.get_active_task(builder_data, builder_state)
  sync_goal_model(builder_data, builder_state)
  return model.get_active_task(builder_data, builder_state)
end

function goal_engine.get_display_task(builder_data, builder_state)
  sync_goal_model(builder_data, builder_state)
  return model.get_display_task(builder_data, builder_state)
end

function goal_engine.advance(builder_data, builder_state, tick, adapters)
  instances.ensure_state(builder_state)
  sync_goal_model(builder_data, builder_state)

  local execution = model.get_active_execution(builder_data, builder_state)
  if execution and execution.execution_kind == "task" and execution.task then
    if not builder_state.task_state then
      adapters.start_task(builder_state, execution.task, tick)
    else
      adapters.advance_task_phase(builder_state, execution.task, tick)
    end
    sync_goal_model(builder_data, builder_state)
    return
  end

  local model_state = sync_goal_model(builder_data, builder_state)
  local root = model_state and model_state.root or nil
  local active_branch = root and root.active_child_id or nil

  if active_branch == "scaling" and builder_data.scaling and builder_data.scaling.enabled then
    advance_scaling(builder_data, builder_state, tick, adapters)
    sync_goal_model(builder_data, builder_state)
  else
    set_scaling_display_task(builder_state, nil)
    adapters.set_idle(builder_state.entity)
  end
end

function goal_engine.sync_model(builder_data, builder_state, tick, adapters)
  instances.ensure_state(builder_state)
  sync_goal_model(builder_data, builder_state)

  local snapshot = adapters.build_runtime_snapshot(builder_state, tick)
  local model_state = sync_goal_model(
    builder_data,
    builder_state,
    {
      snapshot = snapshot,
      adapter = {
        get_item_count = adapters.get_item_count,
        get_recipe = function(item_name)
          return predicates.get_recipe(builder_data, item_name)
        end
      }
    }
  )
  local root = model_state and model_state.root or nil
  if not root then
    return snapshot
  end

  trace.sync_from_root(builder_state, root, tick, adapters.debug_log)

  builder_state.goal_tree_root = root
  builder_state.goal_model_root = root
  builder_state.goal_path_lines = goal_tree.get_active_path_lines(root)
  builder_state.goal_blockers = goal_tree.get_blockers(root)
  builder_state.goal_blocker_lines = goal_tree.get_blocker_lines(root)
  return snapshot
end

function goal_engine.get_recent_trace_lines(builder_state, limit)
  return trace.get_recent_lines(builder_state, limit)
end

return goal_engine

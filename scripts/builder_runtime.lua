local builder_data = require("shared.builder_data")

local builder_runtime = {}
local debug_prefix = "[enemy-builder] "
local overlay_element_names = {
  status_root = "enemy_builder_status_overlay_root",
  goal_label = "enemy_builder_goal_overlay_label",
  status_label = "enemy_builder_status_overlay_label",
  inventory_root = "enemy_builder_inventory_overlay_root",
  inventory_title = "enemy_builder_inventory_overlay_title",
  inventory_label = "enemy_builder_inventory_overlay_label"
}
local get_builder_state
local get_active_task
local get_item_count
local get_pending_scaling_milestone
local get_site_pattern
local pull_inventory_contents_to_builder
local resolve_required_items
local cleanup_resource_sites
local discover_resource_sites
local set_idle
local normalize_scaling_active_task
local start_scaling_collection
local start_scaling_craft
local start_scaling_subtask

local direction_by_name = {
  north = defines.direction.north,
  northeast = defines.direction.northeast,
  east = defines.direction.east,
  southeast = defines.direction.southeast,
  south = defines.direction.south,
  southwest = defines.direction.southwest,
  west = defines.direction.west,
  northwest = defines.direction.northwest
}

local diagonal_ratio = 0.41421356237

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for key, nested_value in pairs(value) do
    copy[deep_copy(key)] = deep_copy(nested_value)
  end

  return copy
end

local function clone_position(position)
  return {x = position.x, y = position.y}
end

local function tile_position_to_world_center(position)
  return {
    x = position.x + 0.5,
    y = position.y + 0.5
  }
end

local function square_distance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return (dx * dx) + (dy * dy)
end

local function ensure_random_seed()
  if storage.random_seed == nil then
    storage.random_seed = (game and game.tick or 0) + 1
  end

  return storage.random_seed
end

local function next_random_index(max_value)
  if not max_value or max_value < 1 then
    return 1
  end

  local seed = ensure_random_seed()
  seed = (seed * 48271) % 2147483647
  storage.random_seed = seed
  return (seed % max_value) + 1
end

local function format_position(position)
  if not position then
    return "(nil)"
  end

  return string.format("(%.2f, %.2f)", position.x, position.y)
end

local function format_direction(direction)
  if direction == nil then
    return "nil"
  end

  return tostring(direction)
end

local function format_products(products)
  local parts = {}

  for _, product in ipairs(products) do
    parts[#parts + 1] = product.name .. "=" .. product.count
  end

  return table.concat(parts, ", ")
end

local function format_item_stack_name(item_stack)
  if item_stack.quality then
    return item_stack.name .. " (" .. item_stack.quality .. ")"
  end

  return item_stack.name
end

local function humanize_identifier(identifier)
  if not identifier then
    return "unknown"
  end

  local words = {}
  local normalized = string.gsub(identifier, "[-_]+", " ")

  for word in string.gmatch(normalized, "%S+") do
    words[#words + 1] = string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2)
  end

  return table.concat(words, " ")
end

local function count_table_entries(values)
  local count = 0
  for _ in pairs(values or {}) do
    count = count + 1
  end

  return count
end

local function get_sorted_item_stacks(contents)
  local item_stacks = {}

  for _, item_stack in pairs(contents) do
    item_stacks[#item_stacks + 1] = item_stack
  end

  table.sort(item_stacks, function(left, right)
    return format_item_stack_name(left) < format_item_stack_name(right)
  end)

  return item_stacks
end

local function ensure_debug_settings()
  if storage.debug_enabled == nil then
    storage.debug_enabled = true
  end
end

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

local function ensure_builder_map_markers()
  if storage.builder_map_markers == nil then
    storage.builder_map_markers = {}
  end

  return storage.builder_map_markers
end

local function debug_enabled()
  return storage.debug_enabled == true
end

local function debug_log(message)
  if debug_enabled() then
    log(debug_prefix .. message)
  end
end

local function inventory_log(message)
  log(debug_prefix .. "inventory: " .. message)
end

local function get_command_player(command)
  if not (command and command.player_index) then
    return nil
  end

  return game.get_player(command.player_index)
end

local function reply_to_command(command, message)
  local player = get_command_player(command)
  if player and player.valid then
    player.print(debug_prefix .. message)
    return
  end

  log(debug_prefix .. message)
end

local function get_overlay_settings()
  return builder_data.ui and builder_data.ui.overlay or {}
end

local function overlay_enabled()
  return get_overlay_settings().enabled ~= false
end

local function get_map_marker_settings()
  return builder_data.ui and builder_data.ui.map_marker or {}
end

local function map_marker_enabled()
  return get_map_marker_settings().enabled ~= false
end

local function describe_builder_state(builder_state)
  if not builder_state then
    return {
      "builder: missing"
    }
  end

  local entity = builder_state.entity
  local lines = {
    "debug=" .. tostring(debug_enabled()),
    "builder-position=" .. format_position(entity.position),
    "surface=" .. entity.surface.name
  }

  local walking_state = entity.walking_state
  if walking_state then
    lines[#lines + 1] = "walking=" .. tostring(walking_state.walking) .. " direction=" .. format_direction(walking_state.direction)
  end

  local task = get_active_task(builder_state)
  if task then
    lines[#lines + 1] = "task=" .. task.id .. " phase=" .. (builder_state.task_state and builder_state.task_state.phase or "uninitialized")
  elseif builder_data.scaling and builder_data.scaling.enabled then
    local scaling_phase = builder_state.task_state and builder_state.task_state.phase or "planning"
    local cycle_pattern_names = builder_data.scaling.cycle_pattern_names or {}
    local pattern_index = builder_state.scaling_pattern_index or 1
    local pattern_name = cycle_pattern_names[pattern_index] or "none"
    lines[#lines + 1] = "task=scaling phase=" .. scaling_phase
    lines[#lines + 1] = "scaling-pattern=" .. pattern_name
  else
    lines[#lines + 1] = "task=complete"
  end

  local task_state = builder_state.task_state
  if task_state then
    if task_state.wait_reason then
      lines[#lines + 1] = "wait-reason=" .. task_state.wait_reason
    end

    if task_state.resource_position then
      lines[#lines + 1] = "resource-position=" .. format_position(task_state.resource_position)
    end

    if task_state.build_position then
      lines[#lines + 1] = "build-position=" .. format_position(task_state.build_position)
      lines[#lines + 1] = "build-direction=" .. format_direction(task_state.build_direction)
    end

    if task_state.downstream_machine_position then
      lines[#lines + 1] = "downstream-machine-position=" .. format_position(task_state.downstream_machine_position)
    end

    if task_state.output_container_position then
      lines[#lines + 1] = "output-container-position=" .. format_position(task_state.output_container_position)
    end

    if task_state.target_position then
      lines[#lines + 1] = "target-position=" .. format_position(task_state.target_position)
    end

    if task_state.target_item_name then
      lines[#lines + 1] = "target-item=" .. task_state.target_item_name
    end

    if task_state.source_id then
      lines[#lines + 1] = "source-id=" .. task_state.source_id
    end

    if task_state.target_kind then
      lines[#lines + 1] = "target-kind=" .. task_state.target_kind
    end

    if task_state.target_name then
      lines[#lines + 1] = "target-name=" .. task_state.target_name
    end

    if task_state.harvest_complete_tick then
      lines[#lines + 1] = "harvest-complete-tick=" .. task_state.harvest_complete_tick
    end

    if task_state.next_attempt_tick then
      lines[#lines + 1] = "next-attempt-tick=" .. task_state.next_attempt_tick
    end

    if task_state.pause_until_tick then
      lines[#lines + 1] = "pause-until-tick=" .. task_state.pause_until_tick
    end

    if task_state.next_phase then
      lines[#lines + 1] = "next-phase=" .. task_state.next_phase
    end

    if task_state.pause_reason then
      lines[#lines + 1] = "pause-reason=" .. task_state.pause_reason
    end
  end

  if builder_state.next_container_scan_tick then
    lines[#lines + 1] = "next-container-scan-tick=" .. builder_state.next_container_scan_tick
  end

  if builder_state.next_machine_refuel_tick then
    lines[#lines + 1] = "next-machine-refuel-tick=" .. builder_state.next_machine_refuel_tick
  end

  if builder_state.next_machine_output_collection_tick then
    lines[#lines + 1] = "next-machine-output-collection-tick=" .. builder_state.next_machine_output_collection_tick
  end

  if builder_state.completed_scaling_milestones then
    lines[#lines + 1] = "completed-scaling-milestones=" .. count_table_entries(builder_state.completed_scaling_milestones)
  end

  lines[#lines + 1] = "production-sites=" .. #ensure_production_sites()
  lines[#lines + 1] = "resource-sites=" .. #ensure_resource_sites()

  return lines
end

local function ensure_builder_state_fields(builder_state)
  if not builder_state then
    return nil
  end

  if builder_state.scaling_pattern_index == nil then
    builder_state.scaling_pattern_index = 1
  end

  if builder_state.completed_scaling_milestones == nil then
    builder_state.completed_scaling_milestones = {}
  end

  return builder_state
end

local function enable_force_recipe_if_available(force, recipe_name)
  if not (force and recipe_name and force.recipes and force.recipes[recipe_name]) then
    return
  end

  force.recipes[recipe_name].enabled = true
end

local function get_task_consumed_item_name(task)
  if task and task.consume_item_name then
    return task.consume_item_name
  end

  return task and task.entity_name or nil
end

local function enable_configured_force_recipes(force)
  if not force then
    return
  end

  force.reset_technologies()
  force.reset_recipes()

  if builder_data.force and builder_data.force.unlock_all_technologies then
    force.research_all_technologies()
  end

  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if milestone.task and milestone.task.recipe_name then
      enable_force_recipe_if_available(force, milestone.task.recipe_name)
    end
  end

  force.reset_technology_effects()
end

local function ensure_builder_force()
  local force = game.forces[builder_data.force_name]
  if force then
    enable_configured_force_recipes(force)
    return force
  end

  force = game.create_force(builder_data.force_name)
  enable_configured_force_recipes(force)
  return force
end

local function get_first_valid_player()
  for _, player in pairs(game.players) do
    if player and player.valid and player.character and player.character.valid then
      return player
    end
  end

  return nil
end

get_builder_state = function()
  local state = storage.builder_state
  if not state then
    return nil
  end

  if not (state.entity and state.entity.valid) then
    storage.builder_state = nil
    return nil
  end

  ensure_builder_state_fields(state)
  normalize_scaling_active_task(state)
  return state
end

local function debug_status_command(command)
  ensure_debug_settings()

  local lines = describe_builder_state(get_builder_state())
  for _, line in ipairs(lines) do
    reply_to_command(command, line)
  end
end

local function debug_toggle_command(command)
  ensure_debug_settings()

  local parameter = command.parameter and string.lower(command.parameter) or nil
  if parameter == "on" then
    storage.debug_enabled = true
    reply_to_command(command, "debug logging enabled")
    return
  end

  if parameter == "off" then
    storage.debug_enabled = false
    reply_to_command(command, "debug logging disabled")
    return
  end

  reply_to_command(command, "debug logging is " .. (debug_enabled() and "on" or "off") .. "; use /enemy-builder-debug on or /enemy-builder-debug off")
end

local function debug_retask_command(command)
  local builder_state = get_builder_state()
  if not builder_state then
    reply_to_command(command, "no builder entity is active")
    return
  end

  builder_state.task_state = nil
  builder_state.scaling_active_task = nil
  set_idle(builder_state.entity)
  debug_log("manual retask requested at " .. format_position(builder_state.entity.position))
  reply_to_command(command, "builder task state cleared; it will re-evaluate on the next tick")
end

get_active_task = function(builder_state)
  local plan = builder_data.plans[builder_state.plan_name]
  if not plan then
    return nil
  end

  return plan.tasks[builder_state.task_index]
end

local function get_display_task(builder_state)
  if not builder_state then
    return nil
  end

  if builder_state.scaling_active_task then
    return builder_state.scaling_active_task
  end

  return get_active_task(builder_state)
end

local function get_milestone_by_name(milestone_name)
  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if milestone.name == milestone_name then
      return milestone
    end
  end

  return nil
end

local function get_milestone_display_name(milestone_name)
  local milestone = get_milestone_by_name(milestone_name)
  if milestone and milestone.display_name then
    return milestone.display_name
  end

  return humanize_identifier(milestone_name)
end

local function get_pattern_display_name(pattern_name)
  local pattern = get_site_pattern(pattern_name)
  if pattern and pattern.display_name then
    return pattern.display_name
  end

  return humanize_identifier(pattern_name)
end

local function milestone_thresholds_met(entity, milestone)
  for _, threshold in ipairs((milestone and milestone.inventory_thresholds) or {}) do
    if get_item_count(entity, threshold.name) < threshold.count then
      return false
    end
  end

  return true
end

local function should_pursue_milestone(builder_state, milestone)
  if not (builder_state and milestone) then
    return false
  end

  local active_task = builder_state.scaling_active_task
  if active_task and active_task.completed_scaling_milestone_name == milestone.name then
    return true
  end

  if resolve_required_items(builder_state.entity, milestone.required_items) == nil then
    return true
  end

  if milestone_thresholds_met(builder_state.entity, milestone) then
    return true
  end

  return builder_data.scaling and builder_data.scaling.pursue_milestones_proactively == true
end

set_idle = function(entity)
  if entity and entity.valid then
    entity.walking_state = {walking = false}
  end
end

local function configure_builder_entity(entity)
  entity.destructible = false
  entity.minable = false
  entity.operable = false
  entity.color = builder_data.avatar.tint
  entity.health = 1000000
end

local function get_post_place_pause_ticks(task)
  if task.post_place_pause_ticks ~= nil then
    return task.post_place_pause_ticks
  end

  if builder_data.build and builder_data.build.post_place_pause_ticks then
    return builder_data.build.post_place_pause_ticks
  end

  return 0
end

local function destroy_entity_if_valid(entity)
  if entity and entity.valid then
    entity.destroy()
  end
end

get_item_count = function(entity, item_name)
  return entity.get_item_count(item_name)
end

local function get_builder_main_inventory(entity)
  if not (entity and entity.valid) then
    return nil
  end

  return entity.get_inventory(defines.inventory.character_main)
end

local function get_missing_inventory_target(entity, inventory_targets)
  for _, inventory_target in ipairs(inventory_targets) do
    local current_count = get_item_count(entity, inventory_target.name)
    if current_count < inventory_target.count then
      return inventory_target, current_count
    end
  end

  return nil, nil
end

local function inventory_targets_summary(entity, inventory_targets)
  local parts = {}

  for _, inventory_target in ipairs(inventory_targets) do
    parts[#parts + 1] = inventory_target.name .. "=" .. get_item_count(entity, inventory_target.name) .. "/" .. inventory_target.count
  end

  return table.concat(parts, ", ")
end

local function source_yields_item(source, item_name)
  for _, product in ipairs(source.yields) do
    if product.name == item_name then
      return true
    end
  end

  return false
end

local function get_valid_source_names(source, source_field, prototype_group)
  local cached_field = "_" .. source_field .. "_cache"
  if source[cached_field] then
    return source[cached_field]
  end

  local names = source[source_field]
  if not names then
    return nil
  end

  local prototype_dictionary = prototypes and prototypes[prototype_group]
  if not prototype_dictionary then
    source[cached_field] = names
    return names
  end

  local valid_names = {}
  local invalid_names = {}

  for _, name in ipairs(names) do
    if prototype_dictionary[name] then
      valid_names[#valid_names + 1] = name
    else
      invalid_names[#invalid_names + 1] = name
    end
  end

  source[cached_field] = valid_names

  if #invalid_names > 0 then
    debug_log(
      "source " .. (source.id or "?") .. ": ignoring unsupported " .. prototype_group ..
      " names " .. table.concat(invalid_names, ", ")
    )
  end

  return valid_names
end

local function find_matching_entities(surface, origin, radius, source)
  local filter = {
    position = origin,
    radius = radius
  }

  if source.entity_type then
    filter.type = source.entity_type
  end

  if source.entity_name then
    if prototypes and prototypes.entity and not prototypes.entity[source.entity_name] then
      debug_log("source " .. (source.id or "?") .. ": ignoring unsupported entity name " .. source.entity_name)
      return {}
    end
    filter.name = source.entity_name
  elseif source.entity_names then
    local valid_names = get_valid_source_names(source, "entity_names", "entity")
    if #valid_names == 0 then
      return {}
    end
    filter.name = valid_names
  end

  return surface.find_entities_filtered(filter)
end

local function find_matching_decoratives(surface, origin, radius, source)
  local decorative_names = get_valid_source_names(source, "decorative_names", "decorative")
  if not decorative_names or #decorative_names == 0 then
    return {}
  end

  return surface.find_decoratives_filtered{
    area = {
      {origin.x - radius, origin.y - radius},
      {origin.x + radius, origin.y + radius}
    },
    name = decorative_names
  }
end

local function find_matching_targets(surface, origin, radius, source)
  if source.decorative_names then
    local decoratives = find_matching_decoratives(surface, origin, radius, source)
    local targets = {}

    for _, decorative in ipairs(decoratives) do
      targets[#targets + 1] = {
        target_kind = "decorative",
        target_name = decorative.decorative.name,
        target_position = tile_position_to_world_center(decorative.position),
        decorative_position = clone_position(decorative.position)
      }
    end

    return targets
  end

  local entities = find_matching_entities(surface, origin, radius, source)
  local targets = {}

  for _, entity in ipairs(entities) do
    if entity.valid then
      targets[#targets + 1] = {
        target_kind = "entity",
        target_name = entity.name,
        target_position = clone_position(entity.position),
        entity = entity
      }
    end
  end

  return targets
end

local function decorative_target_exists(surface, decorative_position, decorative_name)
  return #surface.find_decoratives_filtered{
    position = decorative_position,
    name = decorative_name,
    limit = 1
  } > 0
end

local function find_gather_site(surface, origin, task, item_name)
  for _, source in ipairs(task.sources) do
    if source_yields_item(source, item_name) then
      local search_radii = source.search_radii or task.search_radii

      for _, radius in ipairs(search_radii) do
        local candidates = find_matching_targets(surface, origin, radius, source)
        table.sort(candidates, function(left, right)
          return square_distance(origin, left.target_position) < square_distance(origin, right.target_position)
        end)

        for _, candidate in ipairs(candidates) do
          return {
            source = source,
            target_kind = candidate.target_kind,
            target_name = candidate.target_name,
            target_position = candidate.target_position,
            decorative_position = candidate.decorative_position,
            entity = candidate.entity
          }
        end
      end
    end
  end

  return nil
end

local function log_inventory_delta(entity, item_name, delta, reason, item_label)
  if delta == 0 then
    return
  end

  local sign = delta > 0 and "+" or ""
  inventory_log(
    sign .. delta .. " " .. (item_label or item_name) .. " via " .. reason ..
    "; total=" .. get_item_count(entity, item_name)
  )
end

local function insert_stack(entity, item_stack, reason)
  local inserted_count = entity.insert(item_stack)
  log_inventory_delta(entity, item_stack.name, inserted_count, reason, format_item_stack_name(item_stack))
  return inserted_count
end

local function insert_item(entity, item_name, count, reason)
  return insert_stack(entity, {name = item_name, count = count}, reason)
end

local function remove_item(entity, item_name, count, reason, item_label)
  local removed_count = entity.remove_item{
    name = item_name,
    count = count
  }
  log_inventory_delta(entity, item_name, -removed_count, reason, item_label or item_name)
  return removed_count
end

local function remove_products(entity, products, reason)
  local removed_products = {}

  for _, product in ipairs(products) do
    local removed_count = remove_item(entity, product.name, product.count, reason)
    if removed_count < product.count then
      return nil, removed_products
    end

    removed_products[#removed_products + 1] = {
      name = product.name,
      count = removed_count
    }
  end

  return removed_products, removed_products
end

local function insert_products(entity, products, reason)
  local inserted_products = {}

  for _, product in ipairs(products) do
    local inserted_count = insert_item(entity, product.name, product.count, reason)

    inserted_products[#inserted_products + 1] = {
      name = product.name,
      count = inserted_count
    }
  end

  return inserted_products
end

local function get_container_inventory(container)
  return container.get_inventory(defines.inventory.chest)
end

local function point_in_area(position, area)
  return position.x >= area.left_top.x and position.x <= area.right_bottom.x and
    position.y >= area.left_top.y and position.y <= area.right_bottom.y
end

local function build_search_positions(anchor_position, radius, step)
  local positions = {}

  for dx = -radius, radius, step do
    for dy = -radius, radius, step do
      positions[#positions + 1] = {
        x = anchor_position.x + dx,
        y = anchor_position.y + dy,
        weight = (dx * dx) + (dy * dy)
      }
    end
  end

  table.sort(positions, function(left, right)
    return left.weight < right.weight
  end)

  return positions
end

local function select_preferred_candidate(candidates, preferred_pool_size, sort_candidates, is_preferred_candidate)
  if #candidates == 0 then
    return nil, 0
  end

  table.sort(candidates, sort_candidates)

  local max_pool_size = math.min(math.max(preferred_pool_size or 1, 1), #candidates)
  local selection_pool = {}

  if is_preferred_candidate then
    local best_candidate = candidates[1]
    for _, candidate in ipairs(candidates) do
      if is_preferred_candidate(candidate, best_candidate) then
        selection_pool[#selection_pool + 1] = candidate
        if #selection_pool >= max_pool_size then
          break
        end
      elseif #selection_pool > 0 then
        break
      end
    end
  end

  if #selection_pool == 0 then
    for index = 1, max_pool_size do
      selection_pool[#selection_pool + 1] = candidates[index]
    end
  end

  local selected_candidate = selection_pool[next_random_index(#selection_pool)]
  return selected_candidate, #selection_pool
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

local function transfer_inventory_contents(source_inventory, destination, debug_reason, allowed_item_names)
  if not (source_inventory and destination) or source_inventory.is_empty() then
    return {}
  end

  local moved_items = {}

  for _, item_stack in ipairs(get_sorted_item_stacks(source_inventory.get_contents())) do
    if item_stack.count and item_stack.count > 0 and (not allowed_item_names or allowed_item_names[item_stack.name]) then
      local inserted_count = destination.insert(item_stack)
      if inserted_count > 0 then
        source_inventory.remove{
          name = item_stack.name,
          quality = item_stack.quality,
          count = inserted_count
        }
        moved_items[#moved_items + 1] = {
          name = format_item_stack_name(item_stack),
          count = inserted_count
        }
      end
    end
  end

  if debug_reason and #moved_items > 0 then
    debug_log(debug_reason .. ": moved " .. format_products(moved_items))
  end

  return moved_items
end

local function insert_entity_fuel(entity, fuel)
  if not fuel then
    return
  end

  local fuel_inventory = entity.get_fuel_inventory and entity.get_fuel_inventory()
  if fuel_inventory then
    fuel_inventory.insert{
      name = fuel.name,
      count = fuel.count
    }
  end
end

local function find_downstream_machine_placement(surface, force, task, drop_position)
  local downstream_machine = task.downstream_machine
  local stats = {
    positions_checked = 0,
    placeable_positions = 0,
    test_machines_created = 0,
    anchor_cover_hits = 0,
    output_container_hits = 0
  }

  for _, position in ipairs(build_search_positions(
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
        local covers_drop_position = not downstream_machine.cover_drop_position or point_in_area(drop_position, test_machine.selection_box)
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
          return clone_position(position), output_container_position and clone_position(output_container_position) or nil, stats
        end
      end
    end
  end

  return nil, nil, stats
end

local function find_entity_placement_near_anchor(surface, force, entity_name, anchor_position, search_radius, step, directions)
  local stats = {
    positions_checked = 0,
    placeable_positions = 0
  }

  for _, position in ipairs(build_search_positions(anchor_position, search_radius, step)) do
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
          return clone_position(position), direction, stats
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
        return clone_position(position), nil, stats
      end
    end
  end

  return nil, nil, stats
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

local function get_anchor_site_position(site, anchor_position_source)
  if anchor_position_source == "downstream-machine" and site.downstream_machine and site.downstream_machine.valid then
    return clone_position(site.downstream_machine.position)
  end

  if anchor_position_source == "output-container" and site.output_container and site.output_container.valid then
    return clone_position(site.output_container.position)
  end

  if site.miner and site.miner.valid then
    return clone_position(site.miner.position)
  end

  return nil
end

local function find_machine_site_near_resource_sites(builder_state, task)
  discover_resource_sites(builder_state)

  local builder = builder_state.entity
  local anchor_candidates = {}

  for _, site in ipairs(cleanup_resource_sites()) do
    if site_matches_patterns(site, task.anchor_pattern_names) then
      local anchor_position = get_anchor_site_position(site, task.anchor_position_source)
      if anchor_position then
        anchor_candidates[#anchor_candidates + 1] = {
          site = site,
          anchor_position = anchor_position,
          distance = square_distance(builder.position, anchor_position)
        }
      end
    end
  end

  table.sort(anchor_candidates, function(left, right)
    return left.distance < right.distance
  end)

  local summary = {
    anchor_sites_considered = 0,
    positions_checked = 0,
    placeable_positions = 0
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
      task.placement_directions
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

local function collect_nearby_container_items(builder_state, tick)
  local collection_settings = builder_data.logistics and builder_data.logistics.nearby_container_collection
  if not collection_settings then
    return
  end

  if tick < (builder_state.next_container_scan_tick or 0) then
    return
  end

  builder_state.next_container_scan_tick = tick + collection_settings.interval_ticks

  local builder = builder_state.entity
  local filter = {
    position = builder.position,
    radius = collection_settings.radius
  }

  if collection_settings.entity_type then
    filter.type = collection_settings.entity_type
  elseif collection_settings.entity_types then
    filter.type = collection_settings.entity_types
  end

  if collection_settings.own_force_only then
    filter.force = builder.force
  end

  local containers = builder.surface.find_entities_filtered(filter)
  table.sort(containers, function(left, right)
    return square_distance(builder.position, left.position) < square_distance(builder.position, right.position)
  end)

  local containers_scanned = 0

  for _, container in ipairs(containers) do
    if collection_settings.max_containers_per_scan and containers_scanned >= collection_settings.max_containers_per_scan then
      break
    end

    if container.valid then
      containers_scanned = containers_scanned + 1

      local inventory = get_container_inventory(container)
      if inventory and not inventory.is_empty() then
        local reason = "collected from " .. container.name .. " at " .. format_position(container.position)
        for _, item_stack in ipairs(get_sorted_item_stacks(inventory.get_contents())) do
          if item_stack.count and item_stack.count > 0 then
            local inserted_count = insert_stack(builder, item_stack, reason)
            if inserted_count > 0 then
              inventory.remove{
                name = item_stack.name,
                quality = item_stack.quality,
                count = inserted_count
              }
            end
          end
        end
      end
    end
  end
end

local function collect_nearby_machine_output_items(builder_state, tick)
  local collection_settings = builder_data.logistics and builder_data.logistics.nearby_machine_output_collection
  if not collection_settings then
    return
  end

  if tick < (builder_state.next_machine_output_collection_tick or 0) then
    return
  end

  builder_state.next_machine_output_collection_tick = tick + collection_settings.interval_ticks

  local builder = builder_state.entity
  local filter = {
    position = builder.position,
    radius = collection_settings.radius
  }

  if collection_settings.entity_type then
    filter.type = collection_settings.entity_type
  elseif collection_settings.entity_types then
    filter.type = collection_settings.entity_types
  end

  if collection_settings.entity_name then
    filter.name = collection_settings.entity_name
  elseif collection_settings.entity_names then
    filter.name = collection_settings.entity_names
  end

  if collection_settings.own_force_only then
    filter.force = builder.force
  end

  local entities = builder.surface.find_entities_filtered(filter)
  table.sort(entities, function(left, right)
    return square_distance(builder.position, left.position) < square_distance(builder.position, right.position)
  end)

  local entities_scanned = 0

  for _, entity in ipairs(entities) do
    if collection_settings.max_entities_per_scan and entities_scanned >= collection_settings.max_entities_per_scan then
      break
    end

    if entity.valid and entity ~= builder then
      entities_scanned = entities_scanned + 1

      local output_inventory = entity.get_output_inventory and entity.get_output_inventory()
      if output_inventory and not output_inventory.is_empty() then
        pull_inventory_contents_to_builder(
          output_inventory,
          builder,
          "collected from " .. entity.name .. " output at " .. format_position(entity.position)
        )
      end
    end
  end
end

local function refuel_nearby_machines(builder_state, tick)
  local refuel_settings = builder_data.logistics and builder_data.logistics.nearby_machine_refuel
  if not refuel_settings then
    return
  end

  if tick < (builder_state.next_machine_refuel_tick or 0) then
    return
  end

  builder_state.next_machine_refuel_tick = tick + refuel_settings.interval_ticks

  local builder = builder_state.entity
  local fuel_name = refuel_settings.fuel_name or "coal"
  local available_fuel = get_item_count(builder, fuel_name)
  if available_fuel <= 0 then
    return
  end

  local filter = {
    position = builder.position,
    radius = refuel_settings.radius
  }

  if refuel_settings.own_force_only then
    filter.force = builder.force
  end

  local entities = builder.surface.find_entities_filtered(filter)
  table.sort(entities, function(left, right)
    return square_distance(builder.position, left.position) < square_distance(builder.position, right.position)
  end)

  local entities_scanned = 0

  for _, entity in ipairs(entities) do
    if refuel_settings.max_entities_per_scan and entities_scanned >= refuel_settings.max_entities_per_scan then
      break
    end

    if entity.valid and entity ~= builder then
      entities_scanned = entities_scanned + 1

      local fuel_inventory = entity.get_fuel_inventory and entity.get_fuel_inventory()
      if fuel_inventory then
        local current_fuel_count = fuel_inventory.get_item_count(fuel_name)
        local wanted_fuel_count = (refuel_settings.target_fuel_item_count or 20) - current_fuel_count
        if wanted_fuel_count > 0 then
          local insert_count = math.min(wanted_fuel_count, available_fuel)
          if insert_count > 0 then
            local inserted_count = fuel_inventory.insert{
              name = fuel_name,
              count = insert_count
            }

            if inserted_count > 0 then
              local reason = "refueled " .. entity.name .. " at " .. format_position(entity.position)
              local removed_count = remove_item(builder, fuel_name, inserted_count, reason)

              if removed_count < inserted_count then
                fuel_inventory.remove{
                  name = fuel_name,
                  count = inserted_count - removed_count
                }
                inserted_count = removed_count
              end

              if inserted_count > 0 then
                available_fuel = available_fuel - inserted_count
                debug_log(
                  reason .. " with " .. inserted_count .. " " .. fuel_name ..
                  "; machine now has " .. fuel_inventory.get_item_count(fuel_name)
                )
              end

              if available_fuel <= 0 then
                break
              end
            end
          end
        end
      end
    end
  end
end

local function register_smelting_site(task, miner, downstream_machine, output_container)
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
      (builder_data.logistics and builder_data.logistics.production_transfer and builder_data.logistics.production_transfer.interval_ticks) or
      30,
    next_transfer_tick = 0
  }
  local message =
    "task " .. task_id .. ": registered smelting site with miner at " .. format_position(miner.position) ..
    ", " .. downstream_machine.name .. " at " .. format_position(downstream_machine.position)

  if output_container and output_container.valid then
    message = message .. " and output container at " .. format_position(output_container.position)
  end

  debug_log(message)
end

local function process_production_sites(tick)
  local production_sites = ensure_production_sites()
  local kept_sites = {}

  for _, site in ipairs(production_sites) do
    if site.miner and site.miner.valid and site.downstream_machine and site.downstream_machine.valid and (not site.output_container or site.output_container.valid) then
      if tick >= (site.next_transfer_tick or 0) then
        site.next_transfer_tick = tick + site.transfer_interval_ticks

        transfer_inventory_contents(
          site.miner.get_output_inventory(),
          site.downstream_machine,
          "production site " .. site.task_id .. ": transferred miner output into " .. site.downstream_machine.name,
          site.input_item_names
        )

        if site.output_container and site.output_container.valid then
          transfer_inventory_contents(
            site.downstream_machine.get_output_inventory(),
            get_container_inventory(site.output_container),
            "production site " .. site.task_id .. ": transferred smelter output into " .. site.output_container.name
          )
        end
      end

      kept_sites[#kept_sites + 1] = site
    end
  end

  storage.production_sites = kept_sites
end

pull_inventory_contents_to_builder = function(source_inventory, builder, reason, allowed_item_names)
  if not source_inventory or source_inventory.is_empty() then
    return {}
  end

  local moved_items = {}

  for _, item_stack in ipairs(get_sorted_item_stacks(source_inventory.get_contents())) do
    if item_stack.count and item_stack.count > 0 and (not allowed_item_names or allowed_item_names[item_stack.name]) then
      local inserted_count = insert_stack(builder, item_stack, reason)
      if inserted_count > 0 then
        source_inventory.remove{
          name = item_stack.name,
          quality = item_stack.quality,
          count = inserted_count
        }
        moved_items[#moved_items + 1] = {
          name = format_item_stack_name(item_stack),
          count = inserted_count
        }
      end
    end
  end

  return moved_items
end

get_site_pattern = function(pattern_name)
  return builder_data.site_patterns and builder_data.site_patterns[pattern_name] or nil
end

local function get_player_screen_size(player)
  local resolution = player.display_resolution
  local scale = player.display_scale or 1

  if not resolution then
    return {width = 1280, height = 720}
  end

  return {
    width = math.floor(resolution.width / scale),
    height = math.floor(resolution.height / scale)
  }
end

local function ensure_overlay_label(parent, name, caption, font_color, maximal_width)
  local label = parent[name]
  if label and label.valid then
    return label
  end

  label = parent.add{
    type = "label",
    name = name,
    caption = caption or ""
  }
  label.style.single_line = false
  label.style.font_color = font_color

  if maximal_width then
    label.style.maximal_width = maximal_width
  end

  return label
end

local function ensure_status_overlay(player)
  local root = player.gui.screen[overlay_element_names.status_root]
  if root and root.valid then
    ensure_overlay_label(root, overlay_element_names.goal_label, "", {0.75, 0.9, 1, 0.82})
    ensure_overlay_label(root, overlay_element_names.status_label, "", {1, 1, 1, 0.82})
    return root
  end

  root = player.gui.screen.add{
    type = "flow",
    name = overlay_element_names.status_root,
    direction = "vertical"
  }
  ensure_overlay_label(root, overlay_element_names.goal_label, "", {0.75, 0.9, 1, 0.82})
  ensure_overlay_label(root, overlay_element_names.status_label, "", {1, 1, 1, 0.82})
  return root
end

local function ensure_inventory_overlay(player)
  local settings = get_overlay_settings()
  local root = player.gui.screen[overlay_element_names.inventory_root]
  if root and root.valid then
    ensure_overlay_label(root, overlay_element_names.inventory_title, "", {0.75, 0.9, 1, 0.82}, settings.inventory_width)
    ensure_overlay_label(root, overlay_element_names.inventory_label, "", {0.92, 0.92, 0.92, 0.72}, settings.inventory_width)
    return root
  end

  root = player.gui.screen.add{
    type = "flow",
    name = overlay_element_names.inventory_root,
    direction = "vertical"
  }
  ensure_overlay_label(root, overlay_element_names.inventory_title, "", {0.75, 0.9, 1, 0.82}, settings.inventory_width)
  ensure_overlay_label(root, overlay_element_names.inventory_label, "", {0.92, 0.92, 0.92, 0.72}, settings.inventory_width)
  return root
end

local function destroy_builder_overlay(player)
  if not (player and player.valid) then
    return
  end

  local status_root = player.gui.screen[overlay_element_names.status_root]
  if status_root and status_root.valid then
    status_root.destroy()
  end

  local inventory_root = player.gui.screen[overlay_element_names.inventory_root]
  if inventory_root and inventory_root.valid then
    inventory_root.destroy()
  end
end

local function destroy_chart_tag_if_valid(tag)
  if tag and tag.valid then
    tag.destroy()
  end
end

local function clear_builder_map_markers()
  local markers = ensure_builder_map_markers()

  for force_index, tag in pairs(markers) do
    destroy_chart_tag_if_valid(tag)
    markers[force_index] = nil
  end
end

local function get_activity_summary(builder_state)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return "Enemy Builder: inactive"
  end

  local task_state = builder_state.task_state
  local task = get_display_task(builder_state)

  if task_state and task_state.phase == "scaling-crafting" then
    return
      "Enemy Builder: crafting " .. (task_state.craft_item_name or "item") ..
      " x" .. tostring(task_state.craft_count or 0)
  end

  if task_state and task_state.phase == "scaling-collecting-site" then
    local site = task_state.scaling_site and task_state.scaling_site.pattern_name or "site"
    return "Enemy Builder: collecting " .. (task_state.target_item_name or "items") .. " from " .. site
  end

  if task_state and task_state.phase == "scaling-moving-to-site" then
    local site = task_state.scaling_site and task_state.scaling_site.pattern_name or "site"
    return
      "Enemy Builder: moving to collect " .. (task_state.target_item_name or "items") ..
      " from " .. site .. " at " .. format_position(task_state.target_position)
  end

  local task_label = task and task.id or ((builder_data.scaling and builder_data.scaling.enabled) and "scaling" or "idle")
  local phase = task_state and task_state.phase or (task and "planning" or "idle")
  local summary = "Enemy Builder: " .. task_label .. " [" .. phase .. "]"

  if task_state then
    if task_state.pause_reason then
      summary = summary .. " " .. task_state.pause_reason
    elseif task_state.wait_reason then
      summary = summary .. " waiting for " .. task_state.wait_reason
    elseif task_state.target_item_name then
      summary = summary .. " " .. task_state.target_item_name
    elseif task_state.source_id then
      summary = summary .. " " .. task_state.source_id
    elseif task_state.target_name then
      summary = summary .. " " .. task_state.target_name
    end

    if task_state.target_position then
      summary = summary .. " -> " .. format_position(task_state.target_position)
    elseif task_state.build_position then
      summary = summary .. " -> " .. format_position(task_state.build_position)
    elseif task_state.resource_position then
      summary = summary .. " -> " .. format_position(task_state.resource_position)
    end
  end

  return summary
end

local function get_goal_summary(builder_state)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return "Goal: inactive"
  end

  local pending_milestone = get_pending_scaling_milestone(builder_state)
  if pending_milestone and should_pursue_milestone(builder_state, pending_milestone) then
    return "Goal: " .. get_milestone_display_name(pending_milestone.name)
  end

  local task = get_display_task(builder_state)
  if task and task.scaling_pattern_name then
    return "Goal: Expand " .. get_pattern_display_name(task.scaling_pattern_name)
  end

  if task and task.pattern_name then
    local plan = builder_data.plans and builder_data.plans[builder_state.plan_name] or nil
    if plan and plan.display_name then
      return "Goal: " .. plan.display_name
    end

    return "Goal: Build " .. get_pattern_display_name(task.pattern_name)
  end

  if task and task.type == "gather-world-items" then
    local plan = builder_data.plans and builder_data.plans[builder_state.plan_name] or nil
    if plan and plan.display_name then
      return "Goal: " .. plan.display_name
    end

    return "Goal: Gather materials"
  end

  if task and task.type == "move-to-resource" then
    local plan = builder_data.plans and builder_data.plans[builder_state.plan_name] or nil
    if plan and plan.display_name then
      return "Goal: " .. plan.display_name
    end

    return "Goal: Move to " .. humanize_identifier(task.resource_name)
  end

  if builder_data.scaling and builder_data.scaling.enabled then
    local cycle_pattern_names = builder_data.scaling.cycle_pattern_names or {}
    local pattern_name = cycle_pattern_names[builder_state.scaling_pattern_index or 1]
    if pattern_name then
      return "Goal: Expand " .. get_pattern_display_name(pattern_name)
    end

    return "Goal: Scale production"
  end

  local plan = builder_data.plans and builder_data.plans[builder_state.plan_name] or nil
  if plan and plan.display_name then
    return "Goal: " .. plan.display_name
  end

  return "Goal: idle"
end

local function get_builder_inventory_lines(builder_state)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return {"builder unavailable"}
  end

  local inventory = get_builder_main_inventory(builder_state.entity)
  if not inventory then
    return {"inventory unavailable"}
  end

  local item_stacks = get_sorted_item_stacks(inventory.get_contents())
  if #item_stacks == 0 then
    return {"(empty)"}
  end

  local settings = get_overlay_settings()
  local max_lines = settings.max_inventory_lines or #item_stacks
  local lines = {}

  for index, item_stack in ipairs(item_stacks) do
    if index > max_lines then
      lines[#lines + 1] = "... +" .. (#item_stacks - max_lines) .. " more"
      break
    end

    lines[#lines + 1] = format_item_stack_name(item_stack) .. ": " .. item_stack.count
  end

  return lines
end

local function update_builder_overlay_for_player(player, builder_state)
  if not (player and player.valid and player.connected) then
    return
  end

  if not overlay_enabled() then
    destroy_builder_overlay(player)
    return
  end

  local settings = get_overlay_settings()
  local screen_size = get_player_screen_size(player)
  local status_root = ensure_status_overlay(player)
  local inventory_root = ensure_inventory_overlay(player)
  local goal_label = status_root[overlay_element_names.goal_label]
  local status_label = status_root[overlay_element_names.status_label]
  local inventory_title = inventory_root[overlay_element_names.inventory_title]
  local inventory_label = inventory_root[overlay_element_names.inventory_label]

  status_root.location = {
    x = settings.left_margin or 20,
    y = settings.top_margin or 12
  }
  inventory_root.location = {
    x = math.max(0, screen_size.width - (settings.inventory_width or 260) - (settings.right_margin or 20)),
    y = (settings.top_margin or 12) + (settings.inventory_top_offset or 40)
  }

  goal_label.caption = get_goal_summary(builder_state)
  status_label.caption = get_activity_summary(builder_state)
  inventory_title.caption = "Enemy Builder Inventory"
  inventory_label.caption = table.concat(get_builder_inventory_lines(builder_state), "\n")
end

local function update_builder_overlays(builder_state, tick, force_update)
  if not overlay_enabled() then
    for _, player in pairs(game.connected_players) do
      destroy_builder_overlay(player)
    end
    return
  end

  local settings = get_overlay_settings()
  local interval_ticks = settings.update_interval_ticks or 15
  if not force_update and (tick % interval_ticks) ~= 0 then
    return
  end

  for _, player in pairs(game.connected_players) do
    update_builder_overlay_for_player(player, builder_state)
  end
end

local function get_builder_marker_forces(builder_force)
  local forces = {}

  for _, player in pairs(game.players) do
    if player and player.valid and player.force and player.force.valid and player.force.index ~= builder_force.index then
      forces[player.force.index] = player.force
    end
  end

  return forces
end

local function update_builder_map_markers(builder_state, tick, force_update)
  if not map_marker_enabled() then
    clear_builder_map_markers()
    return
  end

  local settings = get_map_marker_settings()
  local interval_ticks = settings.update_interval_ticks or 60
  if not force_update and (tick % interval_ticks) ~= 0 then
    return
  end

  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    clear_builder_map_markers()
    return
  end

  local builder = builder_state.entity
  local markers = ensure_builder_map_markers()
  local active_forces = get_builder_marker_forces(builder.force)
  local refresh_distance = settings.refresh_distance or 1
  local refresh_distance_squared = refresh_distance * refresh_distance

  for force_index, force in pairs(active_forces) do
    local existing_tag = markers[force_index]
    local recreate_tag = true

    force.chart(
      builder.surface,
      {
        {builder.position.x - (settings.chart_radius or 16), builder.position.y - (settings.chart_radius or 16)},
        {builder.position.x + (settings.chart_radius or 16), builder.position.y + (settings.chart_radius or 16)}
      }
    )

    if existing_tag and existing_tag.valid then
      local tag_position = existing_tag.position
      if existing_tag.surface == builder.surface and tag_position and square_distance(tag_position, builder.position) <= refresh_distance_squared then
        recreate_tag = false
      else
        destroy_chart_tag_if_valid(existing_tag)
      end
    end

    if recreate_tag then
      markers[force_index] = force.add_chart_tag(
        builder.surface,
        {
          position = clone_position(builder.position),
          text = settings.text or "Builder"
        }
      )
    end
  end

  for force_index, tag in pairs(markers) do
    if not active_forces[force_index] then
      destroy_chart_tag_if_valid(tag)
      markers[force_index] = nil
    end
  end
end

local function get_site_collect_inventory(site)
  if site.output_container and site.output_container.valid then
    return get_container_inventory(site.output_container)
  end

  local pattern = get_site_pattern(site.pattern_name)
  if not pattern or not pattern.collect then
    return nil
  end

  if pattern.collect.source == "output-container" then
    if site.output_container and site.output_container.valid then
      return get_container_inventory(site.output_container)
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

local function get_site_collect_position(site)
  if site.output_container and site.output_container.valid then
    return clone_position(site.output_container.position)
  end

  local pattern = get_site_pattern(site.pattern_name)
  if not pattern or not pattern.collect then
    return site.miner and site.miner.valid and clone_position(site.miner.position) or nil
  end

  if pattern.collect.source == "output-container" and site.output_container and site.output_container.valid then
    return clone_position(site.output_container.position)
  end

  if pattern.collect.source == "downstream-machine-output" and site.downstream_machine and site.downstream_machine.valid then
    return clone_position(site.downstream_machine.position)
  end

  if site.miner and site.miner.valid then
    return clone_position(site.miner.position)
  end

  return nil
end

local function get_site_allowed_items(site)
  local pattern = get_site_pattern(site.pattern_name)
  if not (pattern and pattern.collect and pattern.collect.item_names) then
    return nil
  end

  local allowed_item_names = {}
  for _, item_name in ipairs(pattern.collect.item_names) do
    allowed_item_names[item_name] = true
  end

  return allowed_item_names
end

local function get_site_collect_count(site, item_name)
  local inventory = get_site_collect_inventory(site)
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

cleanup_resource_sites = function()
  local kept_sites = {}

  for _, site in ipairs(ensure_resource_sites()) do
    if site.miner and site.miner.valid and ((not site.downstream_machine) or site.downstream_machine.valid) and ((not site.output_container) or site.output_container.valid) then
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

local function register_resource_site(task, miner, downstream_machine, output_container)
  if not (task and task.pattern_name and miner and miner.valid) then
    return nil
  end

  local sites = cleanup_resource_sites()
  for _, site in ipairs(sites) do
    if site.miner == miner then
      site.pattern_name = task.pattern_name
      site.resource_name = task.resource_name
      site.downstream_machine = downstream_machine
      site.output_container = output_container
      return site
    end
  end

  local site = {
    pattern_name = task.pattern_name,
    resource_name = task.resource_name,
    miner = miner,
    downstream_machine = downstream_machine,
    output_container = output_container
  }
  sites[#sites + 1] = site

  local message =
    "registered resource site " .. task.pattern_name ..
    " with miner at " .. format_position(miner.position)

  if downstream_machine and downstream_machine.valid then
    message = message .. ", " .. downstream_machine.name .. " at " .. format_position(downstream_machine.position)
  end

  if output_container and output_container.valid then
    message = message .. ", " .. output_container.name .. " at " .. format_position(output_container.position)
  end

  debug_log(message)
  return site
end

local function reconcile_production_sites_from_resource_sites()
  local production_sites = ensure_production_sites()

  for _, resource_site in ipairs(cleanup_resource_sites()) do
    local pattern = get_site_pattern(resource_site.pattern_name)
    local build_task = pattern and pattern.build_task or nil

    if build_task and build_task.downstream_machine and resource_site.miner and resource_site.miner.valid and resource_site.downstream_machine and resource_site.downstream_machine.valid then
      local has_production_site = false

      for _, production_site in ipairs(production_sites) do
        if production_site.miner == resource_site.miner then
          if production_site.output_container and production_site.output_container.valid then
            resource_site.output_container = production_site.output_container
          end
          has_production_site = true
          break
        end
      end

      if not has_production_site then
        if build_task then
          register_smelting_site(build_task, resource_site.miner, resource_site.downstream_machine, resource_site.output_container)
        end
      end
    end
  end
end

local function find_entity_covering_position(surface, force, entity_name, position, radius)
  local entities = surface.find_entities_filtered{
    position = position,
    radius = radius or 3,
    name = entity_name,
    force = force
  }

  for _, entity in ipairs(entities) do
    if entity.valid and point_in_area(position, entity.selection_box) then
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

discover_resource_sites = function(builder_state)
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
        for pattern_name, pattern in pairs(builder_data.site_patterns or {}) do
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
                  3
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
                  output_container
                )
                if build_task.downstream_machine and downstream_machine then
                  register_smelting_site(build_task, miner, downstream_machine, output_container)
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
    debug_log("discovered " .. discovered_count .. " existing resource site(s)")
  end

  reconcile_production_sites_from_resource_sites()
end

local function direction_from_delta(dx, dy)
  local abs_dx = math.abs(dx)
  local abs_dy = math.abs(dy)

  if abs_dx < 0.001 and abs_dy < 0.001 then
    return nil
  end

  if abs_dx <= abs_dy * diagonal_ratio then
    if dy < 0 then
      return defines.direction.north
    end

    return defines.direction.south
  end

  if abs_dy <= abs_dx * diagonal_ratio then
    if dx < 0 then
      return defines.direction.west
    end

    return defines.direction.east
  end

  if dx > 0 and dy < 0 then
    return defines.direction.northeast
  end

  if dx > 0 and dy > 0 then
    return defines.direction.southeast
  end

  if dx < 0 and dy > 0 then
    return defines.direction.southwest
  end

  return defines.direction.northwest
end

local function find_spawn_position(player)
  local origin = player.character.position
  local target = {
    x = origin.x + builder_data.avatar.spawn_offset.x,
    y = origin.y + builder_data.avatar.spawn_offset.y
  }

  local surface = player.surface
  local prototype_name = builder_data.avatar.prototype_name

  return surface.find_non_colliding_position(
    prototype_name,
    target,
    builder_data.avatar.spawn_search_radius,
    builder_data.avatar.spawn_precision
  ) or surface.find_non_colliding_position(
    prototype_name,
    origin,
    builder_data.avatar.spawn_search_radius,
    builder_data.avatar.spawn_precision
  )
end

local function spawn_builder_for_player(player)
  if get_builder_state() then
    debug_log("spawn skipped because the builder already exists")
    return get_builder_state()
  end

  if not (player and player.valid and player.character and player.character.valid) then
    debug_log("spawn skipped because no valid player character is available")
    return nil
  end

  local spawn_position = find_spawn_position(player)
  if not spawn_position then
    debug_log("spawn failed because no non-colliding position was found near " .. format_position(player.character.position))
    return nil
  end

  local force = ensure_builder_force()
  local entity = player.surface.create_entity{
    name = builder_data.avatar.prototype_name,
    position = spawn_position,
    force = force,
    create_build_effect_smoke = false
  }

  if not entity then
    return nil
  end

  configure_builder_entity(entity)
  debug_log("spawned builder at " .. format_position(entity.position) .. " near player " .. player.name .. " at " .. format_position(player.character.position))

  storage.builder_state = {
    entity = entity,
    plan_name = builder_data.default_plan,
    task_index = 1,
    task_state = nil,
    scaling_pattern_index = 1,
    scaling_active_task = nil,
    completed_scaling_milestones = {}
  }

  return ensure_builder_state_fields(storage.builder_state)
end

local function complete_current_task(builder_state, task, completion_message)
  if task and task.no_advance then
    if task.scaling_pattern_name and builder_data.scaling and builder_data.scaling.cycle_pattern_names then
      local cycle_pattern_names = builder_data.scaling.cycle_pattern_names
      local next_pattern_index = builder_state.scaling_pattern_index or 1

      for index, pattern_name in ipairs(cycle_pattern_names) do
        if pattern_name == task.scaling_pattern_name then
          next_pattern_index = (index % #cycle_pattern_names) + 1
          break
        end
      end

      builder_state.scaling_pattern_index = next_pattern_index
    end

    builder_state.scaling_active_task = nil
    builder_state.task_state = nil
    set_idle(builder_state.entity)

    if completion_message then
      debug_log("task " .. task.id .. ": " .. completion_message)
    end
    return
  end

  builder_state.task_index = builder_state.task_index + 1
  builder_state.task_state = nil
  set_idle(builder_state.entity)

  if completion_message then
    debug_log("task " .. task.id .. ": " .. completion_message)
  end
end

local function find_miner_placement(surface, force, task, resource_position)
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

  for _, position in ipairs(build_search_positions(resource_position, task.placement_search_radius, task.placement_step)) do
    for _, direction_name in ipairs(task.placement_directions) do
      local direction = direction_by_name[direction_name]
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
              downstream_machine_position, output_container_position, downstream_stats = find_downstream_machine_placement(surface, force, task, test_miner.drop_position)
              stats.downstream_positions_checked = stats.downstream_positions_checked + downstream_stats.positions_checked
              stats.downstream_placeable_positions = stats.downstream_placeable_positions + downstream_stats.placeable_positions
              stats.test_downstream_created = stats.test_downstream_created + downstream_stats.test_machines_created
              stats.downstream_anchor_hits = stats.downstream_anchor_hits + downstream_stats.anchor_cover_hits
              stats.output_container_hits = stats.output_container_hits + downstream_stats.output_container_hits
              has_output_container_spot = downstream_machine_position ~= nil and (not task.output_container or output_container_position ~= nil)
            elseif task.output_container then
              output_container_position = clone_position(test_miner.drop_position)
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
              output_container_position = output_container_position and clone_position(output_container_position) or nil,
              downstream_machine_position = downstream_machine_position and clone_position(downstream_machine_position) or nil,
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
  local selected_candidate, pool_size = select_preferred_candidate(
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

local function get_resource_position_key(resource)
  return string.format("%.2f:%.2f", resource.position.x, resource.position.y)
end

local function build_resource_patches(resources, origin)
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

        local current_distance = square_distance(origin, current_resource.position)
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

local function find_resource_site(surface, force, origin, task)
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
      return square_distance(origin, left.position) < square_distance(origin, right.position)
    end)

    local site_selection = task.site_selection or {}
    if site_selection.prefer_middle ~= false and #resources > 0 then
      local patches = build_resource_patches(resources, origin)

      for _, patch in ipairs(patches) do
        summary.patch_centers_considered = summary.patch_centers_considered + 1

        local build_position, build_direction, output_container_position, downstream_machine_position, placement_stats =
          find_miner_placement(surface, force, task, patch.anchor_position)

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
            anchor_position = clone_position(patch.anchor_position),
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

        local build_position, build_direction, output_container_position, downstream_machine_position, placement_stats = find_miner_placement(surface, force, task, resource.position)
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
            resource_distance = square_distance(origin, build_position)
          }
        end

        if task.max_resource_candidates_per_radius and considered_this_radius >= task.max_resource_candidates_per_radius then
          break
        end
      end
    end

    local selected_candidate, pool_size = select_preferred_candidate(
      site_candidates,
      site_selection.random_candidate_pool or 1,
      function(left, right)
        if site_selection.prefer_middle ~= false and left.resource_coverage ~= right.resource_coverage then
          return left.resource_coverage > right.resource_coverage
        end

        if left.resource_distance ~= right.resource_distance then
          return left.resource_distance < right.resource_distance
        end

        return square_distance(origin, left.resource.position) < square_distance(origin, right.resource.position)
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

local function find_nearest_resource(surface, origin, task)
  local seen_resources = {}

  for _, radius in ipairs(task.search_radii) do
    local resources = surface.find_entities_filtered{
      position = origin,
      radius = radius,
      type = "resource",
      name = task.resource_name
    }

    table.sort(resources, function(left, right)
      return square_distance(origin, left.position) < square_distance(origin, right.position)
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

local function start_place_miner_task(builder_state, task, tick)
  local entity = builder_state.entity
  debug_log("task " .. task.id .. ": scanning for " .. task.resource_name .. " from " .. format_position(entity.position))
  local site, search_summary = find_resource_site(entity.surface, entity.force, entity.position, task)

  if not site then
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = "no-build-site",
      next_attempt_tick = tick + task.search_retry_ticks
    }
  debug_log(
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
    resource_position = clone_position(resource.position),
    build_position = build_position,
    build_direction = build_direction,
    downstream_machine_position = downstream_machine_position,
    output_container_position = output_container_position,
    last_position = clone_position(entity.position),
    last_progress_tick = tick
  }
  debug_log(
    "task " .. task.id .. ": found build site for " .. task.resource_name .. " at " ..
    format_position((site.selected_from_patch_center and site.anchor_position) or resource.position) ..
    (site.selected_from_patch_center and " via patch center" or "") ..
    " after checking " .. site.summary.resources_considered ..
    " resource tiles and " .. tostring(site.summary.patch_centers_considered or 0) .. " patch centers; chose coverage " ..
    tostring(site.resource_coverage or site.summary.best_resource_coverage or 0) ..
    " from " .. tostring(site.summary.selected_candidate_pool_size or 1) ..
    " preferred candidates; moving toward " .. format_position(build_position) ..
    (downstream_machine_position and " with " .. task.downstream_machine.name .. " at " .. format_position(downstream_machine_position) or "") ..
    (output_container_position and " with output container at " .. format_position(output_container_position) or "")
  )
end

local function start_gather_world_items_task(builder_state, task, tick)
  local entity = builder_state.entity
  local inventory_target, current_count = get_missing_inventory_target(entity, task.inventory_targets)

  if not inventory_target then
    complete_current_task(
      builder_state,
      task,
      "inventory goals met (" .. inventory_targets_summary(entity, task.inventory_targets) .. ")"
    )
    return
  end

  debug_log(
    "task " .. task.id .. ": need " .. inventory_target.name .. " " ..
    current_count .. "/" .. inventory_target.count
  )

  local gather_site = find_gather_site(entity.surface, entity.position, task, inventory_target.name)
  if not gather_site then
    builder_state.task_state = {
      phase = "waiting-for-source",
      wait_reason = "no-source",
      target_item_name = inventory_target.name,
      next_attempt_tick = tick + task.search_retry_ticks
    }
    debug_log(
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
    target_position = clone_position(gather_site.target_position),
    harvest_products = gather_site.source.yields,
    mining_duration_ticks = gather_site.source.mining_duration_ticks or task.mining_duration_ticks,
    last_position = clone_position(entity.position),
    last_progress_tick = tick
  }

  debug_log(
    "task " .. task.id .. ": moving to " .. gather_site.source.id .. " at " ..
    format_position(gather_site.target_position) ..
    (gather_site.target_name and " (" .. gather_site.target_name .. ")" or "") ..
    " to gather " .. format_products(gather_site.source.yields)
  )
end

local function start_move_to_resource_task(builder_state, task, tick)
  local entity = builder_state.entity
  debug_log("task " .. task.id .. ": scanning for " .. task.resource_name .. " from " .. format_position(entity.position))

  local resource = find_nearest_resource(entity.surface, entity.position, task)
  if not resource then
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = "no-resource",
      next_attempt_tick = tick + task.search_retry_ticks
    }
    debug_log(
      "task " .. task.id .. ": no " .. task.resource_name ..
      " resource found; retry at tick " .. builder_state.task_state.next_attempt_tick
    )
    return
  end

  builder_state.task_state = {
    phase = "moving-to-resource",
    resource_position = clone_position(resource.position),
    target_position = clone_position(resource.position),
    last_position = clone_position(entity.position),
    last_progress_tick = tick
  }
  debug_log(
    "task " .. task.id .. ": moving to " .. task.resource_name ..
    " at " .. format_position(resource.position)
  )
end

local function start_place_machine_near_site_task(builder_state, task, tick)
  local entity = builder_state.entity
  debug_log(
    "task " .. task.id .. ": scanning for " .. task.entity_name ..
    " placement near " .. table.concat(task.anchor_pattern_names or {}, ", ") ..
    " from " .. format_position(entity.position)
  )

  local site, summary = find_machine_site_near_resource_sites(builder_state, task)
  if not site then
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = "no-machine-site",
      next_attempt_tick = tick + task.search_retry_ticks
    }
    debug_log(
      "task " .. task.id .. ": no buildable " .. task.entity_name ..
      " site found near anchor sites; checked " .. summary.anchor_sites_considered ..
      " anchors, " .. summary.positions_checked .. " candidate positions, " ..
      summary.placeable_positions .. " placeable spots; retry at tick " ..
      builder_state.task_state.next_attempt_tick
    )
    return
  end

  builder_state.task_state = {
    phase = "moving",
    build_position = clone_position(site.build_position),
    build_direction = site.build_direction,
    anchor_position = clone_position(site.anchor_position),
    anchor_pattern_name = site.site.pattern_name,
    last_position = clone_position(entity.position),
    last_progress_tick = tick
  }

  debug_log(
    "task " .. task.id .. ": found build site for " .. task.entity_name ..
    " near " .. (site.site.pattern_name or "resource site") ..
    " at " .. format_position(site.anchor_position) ..
    "; moving toward " .. format_position(site.build_position)
  )
end

local function start_task(builder_state, task, tick)
  if task.type == "place-miner-on-resource" then
    start_place_miner_task(builder_state, task, tick)
    return
  end

  if task.type == "gather-world-items" then
    start_gather_world_items_task(builder_state, task, tick)
    return
  end

  if task.type == "move-to-resource" then
    start_move_to_resource_task(builder_state, task, tick)
    return
  end

  if task.type == "place-machine-near-site" then
    start_place_machine_near_site_task(builder_state, task, tick)
    return
  end

  complete_current_task(builder_state, task, "unsupported task type " .. task.type)
end

local function refresh_task(builder_state, task, tick)
  builder_state.task_state = nil
  debug_log("task " .. task.id .. ": retrying from " .. format_position(builder_state.entity.position))
  start_task(builder_state, task, tick)
end

local function move_builder_to_position(builder_state, task, tick, destination_position, next_phase)
  local entity = builder_state.entity
  local task_state = builder_state.task_state

  if square_distance(entity.position, destination_position) <= (task.arrival_distance * task.arrival_distance) then
    set_idle(entity)
    task_state.phase = next_phase
    debug_log("task " .. task.id .. ": reached target position " .. format_position(destination_position))
    return
  end

  local delta_x = destination_position.x - entity.position.x
  local delta_y = destination_position.y - entity.position.y
  local direction = direction_from_delta(delta_x, delta_y)

  if direction then
    entity.walking_state = {
      walking = true,
      direction = direction
    }
  end

  if square_distance(entity.position, task_state.last_position) > 0.0025 then
    task_state.last_position = clone_position(entity.position)
    task_state.last_progress_tick = tick
    return
  end

  if tick - task_state.last_progress_tick >= task.stuck_retry_ticks then
    debug_log("task " .. task.id .. ": movement stalled at " .. format_position(entity.position) .. "; refreshing task")
    refresh_task(builder_state, task, tick)
  end
end

local function move_builder(builder_state, task, tick)
  move_builder_to_position(builder_state, task, tick, builder_state.task_state.build_position, "building")
end

local function move_to_gather_source(builder_state, task, tick)
  local entity = builder_state.entity
  local task_state = builder_state.task_state

  if task_state.target_kind == "entity" then
    if not (task_state.target_entity and task_state.target_entity.valid) then
      debug_log("task " .. task.id .. ": source entity disappeared before harvest")
      refresh_task(builder_state, task, tick)
      return
    end

    task_state.target_position = clone_position(task_state.target_entity.position)
  elseif task_state.target_kind == "decorative" then
    if not decorative_target_exists(entity.surface, task_state.target_decorative_position, task_state.target_name) then
      debug_log("task " .. task.id .. ": decorative source disappeared before harvest")
      refresh_task(builder_state, task, tick)
      return
    end
  end

  local was_moving = task_state.phase == "moving-to-source"
  move_builder_to_position(builder_state, task, tick, task_state.target_position, "harvesting")

  if was_moving and task_state.phase == "harvesting" and not task_state.harvest_complete_tick then
    task_state.harvest_complete_tick = tick + task_state.mining_duration_ticks
    debug_log(
      "task " .. task.id .. ": harvesting " .. task_state.source_id .. " at " ..
      format_position(task_state.target_position) .. " until tick " .. task_state.harvest_complete_tick
    )
  end
end

local function move_to_resource(builder_state, task, tick)
  move_builder_to_position(builder_state, task, tick, builder_state.task_state.target_position, "arrived-at-resource")
end

local function begin_post_place_pause(builder_state, task, tick, next_phase, placed_entity)
  local task_state = builder_state.task_state
  local pause_ticks = get_post_place_pause_ticks(task)

  set_idle(builder_state.entity)

  if pause_ticks > 0 then
    task_state.phase = "post-place-pause"
    task_state.pause_until_tick = tick + pause_ticks
    task_state.next_phase = next_phase
    task_state.pause_reason = "after placing " .. placed_entity.name
    debug_log(
      "task " .. task.id .. ": pausing until tick " .. task_state.pause_until_tick ..
      " after placing " .. placed_entity.name .. " at " .. format_position(placed_entity.position)
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

local function finish_place_miner_task(builder_state, task, tick)
  local task_state = builder_state.task_state
  local miner = task_state.placed_miner
  local downstream_machine = task_state.placed_downstream_machine
  local container = task_state.placed_output_container

  if not (miner and miner.valid) then
    debug_log("task " .. task.id .. ": build finished without a valid " .. task.miner_name .. "; refreshing task")
    refresh_task(builder_state, task, tick)
    return
  end

  if task.downstream_machine and not (downstream_machine and downstream_machine.valid) then
    debug_log("task " .. task.id .. ": build finished without a valid " .. task.downstream_machine.name .. "; refreshing task")
    refresh_task(builder_state, task, tick)
    return
  end

  if task.output_container and not (container and container.valid) then
    debug_log("task " .. task.id .. ": build finished without a valid " .. task.output_container.name .. "; refreshing task")
    refresh_task(builder_state, task, tick)
    return
  end

  if downstream_machine then
    register_smelting_site(task, miner, downstream_machine, container)
  end

  register_resource_site(task, miner, downstream_machine, container)

  complete_current_task(
    builder_state,
    task,
    "placed " .. task.miner_name .. " at " .. format_position(miner.position) ..
    (downstream_machine and " with " .. downstream_machine.name .. " at " .. format_position(downstream_machine.position) or "") ..
    (container and " and " .. container.name .. " at " .. format_position(container.position) or "")
  )
end

local function finish_place_machine_near_site_task(builder_state, task, tick)
  local task_state = builder_state.task_state
  local placed_entity = task_state.placed_entity

  if not (placed_entity and placed_entity.valid) then
    debug_log("task " .. task.id .. ": build finished without a valid " .. task.entity_name .. "; refreshing task")
    refresh_task(builder_state, task, tick)
    return
  end

  if task.completed_scaling_milestone_name then
    ensure_builder_state_fields(builder_state)
    builder_state.completed_scaling_milestones[task.completed_scaling_milestone_name] = true
  end

  complete_current_task(
    builder_state,
    task,
    "placed " .. task.entity_name .. " at " .. format_position(placed_entity.position) ..
    (task.recipe_name and " with recipe " .. task.recipe_name or "")
  )
end

local function place_miner(builder_state, task, tick)
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
      insert_item(entity, item_name, count, reason)
    end

    task_state.consumed_build_items = nil
  end

  local function consume_build_item(item_name, placed_entity)
    if not task.consume_items_on_place then
      return true
    end

    local reason = "placed " .. item_name .. " at " .. format_position(placed_entity.position)
    local removed_count = remove_item(entity, item_name, 1, reason)
    if removed_count < 1 then
      debug_log("task " .. task.id .. ": missing " .. item_name .. " in builder inventory for placement")
      return false
    end

    record_consumed_build_item(item_name, removed_count)
    return true
  end

  local function abort_build(reason)
    refund_consumed_build_items("refunded after aborted build for " .. task.id)
    destroy_entity_if_valid(task_state.placed_output_container)
    destroy_entity_if_valid(task_state.placed_downstream_machine)
    destroy_entity_if_valid(task_state.placed_miner)
    refresh_task(builder_state, task, tick)
    debug_log("task " .. task.id .. ": " .. reason)
  end
  local build_phase = get_next_build_phase(task_state, task)

  if build_phase == "place-miner" then
    if not surface.can_place_entity{
      name = task.miner_name,
      position = task_state.build_position,
      direction = task_state.build_direction,
      force = entity.force
    } then
      debug_log("task " .. task.id .. ": build position became invalid at " .. format_position(task_state.build_position))
      refresh_task(builder_state, task, tick)
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
      debug_log("task " .. task.id .. ": create_entity returned nil for " .. task.miner_name .. " at " .. format_position(task_state.build_position))
      refresh_task(builder_state, task, tick)
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
        debug_log("task " .. task.id .. ": miner at " .. format_position(task_state.build_position) .. " covered no " .. task.resource_name .. " in mining_area; immediate mining_target=" .. mining_target_name)
        refresh_task(builder_state, task, tick)
        return
      end
    end

    task_state.placed_miner = miner
    if not consume_build_item(task.miner_name, miner) then
      miner.destroy()
      refresh_task(builder_state, task, tick)
      return
    end
    insert_entity_fuel(miner, task.fuel)
    debug_log("task " .. task.id .. ": placed " .. task.miner_name .. " at " .. format_position(miner.position))
    begin_post_place_pause(
      builder_state,
      task,
      tick,
      get_next_build_phase(task_state, task) == "build-complete" and "build-complete" or "building",
      miner
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
      abort_build("downstream machine position became invalid at " .. format_position(task_state.downstream_machine_position))
      return
    end

    local downstream_machine = surface.create_entity{
      name = task.downstream_machine.name,
      position = task_state.downstream_machine_position,
      force = entity.force,
      create_build_effect_smoke = false
    }

    if not downstream_machine then
      abort_build("failed to place downstream machine at " .. format_position(task_state.downstream_machine_position))
      return
    end

    if task.downstream_machine.cover_drop_position and not point_in_area(miner.drop_position, downstream_machine.selection_box) then
      downstream_machine.destroy()
      abort_build(task.downstream_machine.name .. " no longer covers miner drop position at " .. format_position(miner.drop_position))
      return
    end

    task_state.placed_downstream_machine = downstream_machine
    if not consume_build_item(task.downstream_machine.name, downstream_machine) then
      downstream_machine.destroy()
      abort_build("missing " .. task.downstream_machine.name .. " in builder inventory")
      return
    end
    insert_entity_fuel(downstream_machine, task.downstream_machine.fuel)
    debug_log("task " .. task.id .. ": placed " .. task.downstream_machine.name .. " at " .. format_position(downstream_machine.position))
    begin_post_place_pause(
      builder_state,
      task,
      tick,
      get_next_build_phase(task_state, task) == "build-complete" and "build-complete" or "building",
      downstream_machine
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
      abort_build("output container position became invalid at " .. format_position(task_state.output_container_position))
      return
    end

    local container = surface.create_entity{
      name = task.output_container.name,
      position = task_state.output_container_position,
      force = entity.force,
      create_build_effect_smoke = false
    }

    if not container then
      abort_build("failed to place output container at " .. format_position(task_state.output_container_position))
      return
    end

    task_state.placed_output_container = container
    if not consume_build_item(task.output_container.name, container) then
      container.destroy()
      abort_build("missing " .. task.output_container.name .. " in builder inventory")
      return
    end
    debug_log("task " .. task.id .. ": placed " .. task.output_container.name .. " at " .. format_position(container.position))
    begin_post_place_pause(
      builder_state,
      task,
      tick,
      get_next_build_phase(task_state, task) == "build-complete" and "build-complete" or "building",
      container
    )
    return
  end

  finish_place_miner_task(builder_state, task, tick)
end

local function place_machine_near_site(builder_state, task, tick)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local surface = entity.surface
  local consumed_item_name = get_task_consumed_item_name(task)

  local function refund_consumed_build_item(reason)
    if task_state.consumed_machine_item then
      insert_item(entity, consumed_item_name, task_state.consumed_machine_item, reason)
      task_state.consumed_machine_item = nil
    end
  end

  local function abort_build(reason)
    refund_consumed_build_item("refunded after aborted build for " .. task.id)
    destroy_entity_if_valid(task_state.placed_entity)
    refresh_task(builder_state, task, tick)
    debug_log("task " .. task.id .. ": " .. reason)
  end

  local function schedule_retry(wait_reason, reason)
    refund_consumed_build_item("refunded after delayed retry for " .. task.id)
    destroy_entity_if_valid(task_state.placed_entity)
    builder_state.task_state = {
      phase = "waiting-for-resource",
      wait_reason = wait_reason,
      next_attempt_tick = tick + task.search_retry_ticks
    }
    debug_log("task " .. task.id .. ": " .. reason .. "; retry at tick " .. builder_state.task_state.next_attempt_tick)
  end

  if not task_state.placed_entity then
    if not surface.can_place_entity{
      name = task.entity_name,
      position = task_state.build_position,
      direction = task_state.build_direction,
      force = entity.force
    } then
      debug_log("task " .. task.id .. ": build position became invalid at " .. format_position(task_state.build_position))
      refresh_task(builder_state, task, tick)
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
      debug_log("task " .. task.id .. ": failed to create " .. task.entity_name .. " at " .. format_position(task_state.build_position))
      refresh_task(builder_state, task, tick)
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
          debug_log(
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
      local reason = "placed " .. consumed_item_name .. " at " .. format_position(placed_entity.position)
      local removed_count = remove_item(entity, consumed_item_name, 1, reason)
      if removed_count < 1 then
        placed_entity.destroy()
        task_state.placed_entity = nil
        debug_log("task " .. task.id .. ": missing " .. consumed_item_name .. " in builder inventory for placement")
        refresh_task(builder_state, task, tick)
        return
      end

      task_state.consumed_machine_item = removed_count
    end

    debug_log(
      "task " .. task.id .. ": placed " .. task.entity_name ..
      " at " .. format_position(placed_entity.position) ..
      (task.recipe_name and " with recipe " .. task.recipe_name or "")
    )
    begin_post_place_pause(builder_state, task, tick, "build-complete", placed_entity)
    return
  end

  finish_place_machine_near_site_task(builder_state, task, tick)
end

local function harvest_world_items(builder_state, task, tick)
  local entity = builder_state.entity
  local task_state = builder_state.task_state

  if tick < task_state.harvest_complete_tick then
    return
  end

  if task_state.target_kind == "entity" then
    if not (task_state.target_entity and task_state.target_entity.valid) then
      debug_log("task " .. task.id .. ": source entity disappeared during harvest")
      refresh_task(builder_state, task, tick)
      return
    end

    task_state.target_entity.destroy()
  elseif task_state.target_kind == "decorative" then
    if not decorative_target_exists(entity.surface, task_state.target_decorative_position, task_state.target_name) then
      debug_log("task " .. task.id .. ": decorative source disappeared during harvest")
      refresh_task(builder_state, task, tick)
      return
    end

    entity.surface.destroy_decoratives{
      position = task_state.target_decorative_position,
      name = task_state.target_name,
      limit = 1
    }
  else
    debug_log("task " .. task.id .. ": unsupported harvest target kind " .. tostring(task_state.target_kind))
    refresh_task(builder_state, task, tick)
    return
  end

  local inserted_products = insert_products(
    entity,
    task_state.harvest_products,
    "harvested " .. task_state.source_id .. " at " .. format_position(task_state.target_position)
  )

  debug_log(
    "task " .. task.id .. ": harvested " .. task_state.source_id .. " at " ..
    format_position(task_state.target_position) .. "; inserted " .. format_products(inserted_products) ..
    "; inventory now " .. inventory_targets_summary(entity, task.inventory_targets)
  )

  if task.no_advance then
    builder_state.scaling_active_task = nil
  end

  builder_state.task_state = nil
end

local function get_scaling_pattern_name(builder_state)
  local scaling = builder_data.scaling
  if not (scaling and scaling.cycle_pattern_names and #scaling.cycle_pattern_names > 0) then
    return nil
  end

  local site_counts = get_resource_site_counts()
  local pattern_unlocks = scaling.pattern_unlocks or {}
  local pattern_index = builder_state.scaling_pattern_index or 1
  if pattern_index < 1 or pattern_index > #scaling.cycle_pattern_names then
    pattern_index = 1
    builder_state.scaling_pattern_index = pattern_index
  end

  for offset = 0, (#scaling.cycle_pattern_names - 1) do
    local candidate_index = ((pattern_index - 1 + offset) % #scaling.cycle_pattern_names) + 1
    local pattern_name = scaling.cycle_pattern_names[candidate_index]
    local unlock = pattern_unlocks[pattern_name]
    local unlocked = true

    if unlock and unlock.minimum_site_counts then
      for dependency_pattern_name, dependency_count in pairs(unlock.minimum_site_counts) do
        if (site_counts[dependency_pattern_name] or 0) < dependency_count then
          unlocked = false
          break
        end
      end
    end

    if unlocked then
      builder_state.scaling_pattern_index = candidate_index
      return pattern_name
    end
  end

  return nil
end

local function get_recipe(item_name)
  return builder_data.crafting and builder_data.crafting.recipes and builder_data.crafting.recipes[item_name] or nil
end

local function create_scaling_build_task(pattern_name)
  local pattern = get_site_pattern(pattern_name)
  if not pattern then
    return nil
  end

  local task = deep_copy(pattern.build_task)
  task.id = "scale-build-" .. pattern_name
  task.no_advance = true
  task.consume_items_on_place = true
  task.scaling_pattern_name = pattern_name
  return task
end

local function create_scaling_gather_task(item_name, target_count)
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

  local task = deep_copy(milestone.task)
  task.id = task.id or ("scale-milestone-" .. milestone.name)
  task.no_advance = true
  task.consume_items_on_place = true
  task.completed_scaling_milestone_name = milestone.name
  return task
end

normalize_scaling_active_task = function(builder_state)
  local task = builder_state and builder_state.scaling_active_task or nil
  if not task then
    return
  end

  if task.completed_scaling_milestone_name then
    for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
      if milestone.name == task.completed_scaling_milestone_name then
        builder_state.scaling_active_task = create_scaling_milestone_task(milestone)
        return
      end
    end
  end

  if task.scaling_pattern_name then
    local normalized_task = create_scaling_build_task(task.scaling_pattern_name)
    if normalized_task then
      builder_state.scaling_active_task = normalized_task
    end
  end
end

get_pending_scaling_milestone = function(builder_state)
  ensure_builder_state_fields(builder_state)

  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if not builder_state.completed_scaling_milestones[milestone.name] then
      return milestone
    end
  end

  return nil
end

local function resolve_craft_action(entity, item_name, target_count)
  local current_count = get_item_count(entity, item_name)
  if current_count >= target_count then
    return nil
  end

  local missing_count = target_count - current_count
  local recipe = get_recipe(item_name)
  if not recipe then
    return {
      kind = "collect-ingredient",
      item_name = item_name,
      count = missing_count
    }
  end

  local result_count = recipe.result_count or 1
  local craft_runs = math.ceil(missing_count / result_count)

  for _, ingredient in ipairs(recipe.ingredients) do
    local ingredient_action = resolve_craft_action(entity, ingredient.name, ingredient.count * craft_runs)
    if ingredient_action then
      return ingredient_action
    end
  end

  return {
    kind = "craft",
    item_name = item_name,
    count = craft_runs * result_count,
    craft_runs = craft_runs,
    recipe = recipe,
    result_count = result_count
  }
end

resolve_required_items = function(entity, required_items)
  for _, requirement in ipairs(required_items or {}) do
    local action = resolve_craft_action(entity, requirement.name, requirement.count)
    if action then
      return action
    end
  end

  return nil
end

local function resolve_pattern_requirements(entity, pattern)
  return resolve_required_items(entity, pattern.required_items)
end

local function consume_recipe_ingredients(entity, recipe, craft_count, reason)
  local removed_ingredients = {}

  for _, ingredient in ipairs(recipe.ingredients) do
    local ingredient_count = ingredient.count * craft_count
    local removed_count = remove_item(entity, ingredient.name, ingredient_count, reason)
    if removed_count < ingredient_count then
      for _, removed_ingredient in ipairs(removed_ingredients) do
        insert_item(entity, removed_ingredient.name, removed_ingredient.count, "refunded after failed craft start for " .. reason)
      end
      return nil
    end

    removed_ingredients[#removed_ingredients + 1] = {
      name = ingredient.name,
      count = removed_count
    }
  end

  return removed_ingredients
end

local function start_scaling_wait(builder_state, tick, wait_reason, message)
  local idle_retry_ticks = (builder_data.scaling and builder_data.scaling.idle_retry_ticks) or (2 * 60)
  builder_state.task_state = {
    phase = "scaling-waiting",
    wait_reason = wait_reason,
    next_attempt_tick = tick + idle_retry_ticks
  }

  if message then
    debug_log(message .. "; retry at tick " .. builder_state.task_state.next_attempt_tick)
  end
end

local function find_collectable_site(builder_state, item_name, allow_empty)
  discover_resource_sites(builder_state)

  local builder = builder_state.entity
  local best_site = nil
  local best_distance = nil
  local best_count = nil

  for _, site in ipairs(cleanup_resource_sites()) do
    local allowed_item_names = get_site_allowed_items(site)
    if not item_name or (allowed_item_names and allowed_item_names[item_name]) then
      local collect_position = get_site_collect_position(site)
      local collect_count = get_site_collect_count(site, item_name)

      if collect_position and (collect_count > 0 or allow_empty) then
        local distance = square_distance(builder.position, collect_position)
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

local function plan_scaling_collect_item(builder_state, item_name, count, tick, wait_reason_prefix)
  local site = find_collectable_site(builder_state, item_name, false)
  if site then
    start_scaling_collection(builder_state, site, item_name, tick, false)
  else
    start_scaling_wait(
      builder_state,
      tick,
      (wait_reason_prefix or "waiting-for") .. "-" .. item_name,
      "scaling: waiting for " .. item_name .. " from existing sites"
    )
  end
end

local function plan_scaling_required_items(builder_state, required_items, tick)
  local action = resolve_required_items(builder_state.entity, required_items)
  if not action then
    return false
  end

  if action.kind == "craft" then
    start_scaling_craft(builder_state, action, tick)
    return true
  end

  if action.kind == "collect-ingredient" then
    local site = find_collectable_site(builder_state, action.item_name, false)
    if site then
      start_scaling_collection(builder_state, site, action.item_name, tick, false)
      return true
    end

    if action.item_name == "wood" or action.item_name == "stone" then
      local gather_task = create_scaling_gather_task(
        action.item_name,
        get_item_count(builder_state.entity, action.item_name) + action.count
      )

      if not gather_task then
        start_scaling_wait(builder_state, tick, "missing-gather-task", "scaling: no gather task configured for " .. action.item_name)
        return true
      end

      start_scaling_subtask(builder_state, gather_task, tick)
      return true
    end

    start_scaling_wait(builder_state, tick, "waiting-for-" .. action.item_name, "scaling: waiting for " .. action.item_name .. " from existing sites")
    return true
  end

  return false
end

local function plan_scaling_milestone(builder_state, milestone, tick)
  if not milestone then
    return false
  end

  if not should_pursue_milestone(builder_state, milestone) then
    return false
  end

  local has_required_items = resolve_required_items(builder_state.entity, milestone.required_items) == nil

  if not has_required_items then
    if plan_scaling_required_items(builder_state, milestone.required_items, tick) then
      return true
    end
  end

  local task = create_scaling_milestone_task(milestone)
  if not task then
    start_scaling_wait(builder_state, tick, "missing-milestone-task", "scaling: missing task for milestone " .. tostring(milestone.name))
    return true
  end

  start_scaling_subtask(builder_state, task, tick)
  return true
end

start_scaling_collection = function(builder_state, site, item_name, tick, allow_wait_for_items)
  local collect_position = get_site_collect_position(site)
  if not collect_position then
    start_scaling_wait(builder_state, tick, "missing-site-position", "scaling: site " .. (site.pattern_name or "?") .. " lost its collection position")
    return
  end

  builder_state.task_state = {
    phase = "scaling-moving-to-site",
    scaling_site = site,
    target_item_name = item_name,
    allowed_item_names = get_site_allowed_items(site),
    allow_wait_for_items = allow_wait_for_items == true,
    target_position = collect_position,
    last_position = clone_position(builder_state.entity.position),
    last_progress_tick = tick
  }

  debug_log(
    "scaling: moving to " .. (site.pattern_name or "site") .. " at " ..
    format_position(collect_position) .. " to collect " .. (item_name or "items")
  )
end

local function collect_from_scaling_site(builder_state, tick)
  local task_state = builder_state.task_state
  local site = task_state.scaling_site
  local inventory = site and get_site_collect_inventory(site) or nil

  if not inventory then
    start_scaling_wait(builder_state, tick, "site-inventory-missing", "scaling: site inventory disappeared before collection")
    return
  end

  local reason = "collected from " .. (site.pattern_name or "site") .. " at " .. format_position(task_state.target_position)
  local moved_items = pull_inventory_contents_to_builder(inventory, builder_state.entity, reason, task_state.allowed_item_names)

  if #moved_items == 0 then
    if task_state.allow_wait_for_items then
      local idle_retry_ticks = (builder_data.scaling and builder_data.scaling.idle_retry_ticks) or (2 * 60)
      builder_state.task_state.phase = "scaling-waiting-at-site"
      builder_state.task_state.wait_reason = "site-empty"
      builder_state.task_state.next_attempt_tick = tick + idle_retry_ticks
      debug_log(
        "scaling: " .. (site.pattern_name or "site") ..
        " has no collectable " .. (task_state.target_item_name or "items") ..
        " yet; waiting on-site until tick " .. builder_state.task_state.next_attempt_tick
      )
    else
      start_scaling_wait(builder_state, tick, "site-empty", "scaling: " .. (site.pattern_name or "site") .. " had no collectable items")
    end
    return
  end

  debug_log("scaling: " .. reason .. "; moved " .. format_products(moved_items))
  builder_state.task_state = nil
end

start_scaling_craft = function(builder_state, action, tick)
  local produced_count = action.count
  local craft_runs = action.craft_runs or produced_count
  local reason = "started crafting " .. action.item_name .. " x" .. produced_count
  local removed_ingredients = consume_recipe_ingredients(builder_state.entity, action.recipe, craft_runs, reason)
  if not removed_ingredients then
    start_scaling_wait(builder_state, tick, "missing-craft-ingredients", "scaling: missing ingredients to craft " .. action.item_name)
    return
  end

  builder_state.task_state = {
    phase = "scaling-crafting",
    craft_item_name = action.item_name,
    craft_count = produced_count,
    craft_runs = craft_runs,
    craft_complete_tick = tick + (action.recipe.craft_ticks * craft_runs)
  }

  debug_log(
    "scaling: crafting " .. action.item_name .. " x" .. produced_count ..
    " over " .. craft_runs .. " run(s)" ..
    " until tick " .. builder_state.task_state.craft_complete_tick
  )
end

local function finish_scaling_craft(builder_state)
  local task_state = builder_state.task_state
  local inserted_count = insert_item(
    builder_state.entity,
    task_state.craft_item_name,
    task_state.craft_count,
    "completed crafting " .. task_state.craft_item_name
  )

  debug_log(
    "scaling: completed crafting " .. task_state.craft_item_name ..
    " x" .. inserted_count
  )

  builder_state.task_state = nil
end

start_scaling_subtask = function(builder_state, task, tick)
  builder_state.scaling_active_task = task
  start_task(builder_state, task, tick)
  if not builder_state.task_state then
    builder_state.scaling_active_task = nil
  end
end

local function plan_scaling(builder_state, tick)
  for _, reserve_item in ipairs((builder_data.scaling and builder_data.scaling.reserve_items) or {}) do
    if get_item_count(builder_state.entity, reserve_item.name) < reserve_item.count then
      plan_scaling_collect_item(builder_state, reserve_item.name, reserve_item.count, tick)
      return
    end
  end

  local milestone = get_pending_scaling_milestone(builder_state)
  if milestone then
    if plan_scaling_milestone(builder_state, milestone, tick) then
      return
    end
  end

  local pattern_name = get_scaling_pattern_name(builder_state)
  if not pattern_name then
    set_idle(builder_state.entity)
    return
  end

  local pattern = get_site_pattern(pattern_name)
  if not pattern then
    start_scaling_wait(builder_state, tick, "unknown-pattern", "scaling: unknown pattern " .. tostring(pattern_name))
    return
  end

  if plan_scaling_required_items(builder_state, pattern.required_items, tick) then
    return
  end

  local build_task = create_scaling_build_task(pattern_name)
  if not build_task then
    start_scaling_wait(builder_state, tick, "missing-build-task", "scaling: missing build task for pattern " .. pattern_name)
    return
  end

  start_scaling_subtask(builder_state, build_task, tick)
end

local function advance_task_phase(builder_state, task, tick)
  local phase = builder_state.task_state.phase

  if phase == "waiting-for-resource" then
    if tick >= builder_state.task_state.next_attempt_tick then
      refresh_task(builder_state, task, tick)
    end
    return
  end

  if phase == "waiting-for-source" then
    if tick >= builder_state.task_state.next_attempt_tick then
      refresh_task(builder_state, task, tick)
    end
    return
  end

  if phase == "moving" then
    move_builder(builder_state, task, tick)
    return
  end

  if phase == "moving-to-source" then
    move_to_gather_source(builder_state, task, tick)
    return
  end

  if phase == "moving-to-resource" then
    move_to_resource(builder_state, task, tick)
    return
  end

  if phase == "building" then
    if task.type == "place-machine-near-site" then
      place_machine_near_site(builder_state, task, tick)
    else
      place_miner(builder_state, task, tick)
    end
    return
  end

  if phase == "post-place-pause" then
    if tick >= (builder_state.task_state.pause_until_tick or 0) then
      builder_state.task_state.phase = builder_state.task_state.next_phase or "building"
      builder_state.task_state.pause_until_tick = nil
      builder_state.task_state.next_phase = nil
      builder_state.task_state.pause_reason = nil
      debug_log("task " .. task.id .. ": post-build pause complete; resuming " .. builder_state.task_state.phase)
    end
    return
  end

  if phase == "build-complete" then
    if task.type == "place-machine-near-site" then
      finish_place_machine_near_site_task(builder_state, task, tick)
    else
      finish_place_miner_task(builder_state, task, tick)
    end
    return
  end

  if phase == "arrived-at-resource" then
    complete_current_task(
      builder_state,
      task,
      "arrived at " .. task.resource_name .. " at " .. format_position(builder_state.task_state.target_position)
    )
    return
  end

  if phase == "harvesting" then
    harvest_world_items(builder_state, task, tick)
  end
end

local function advance_scaling(builder_state, tick)
  discover_resource_sites(builder_state)

  if builder_state.scaling_active_task and builder_state.task_state then
    advance_task_phase(builder_state, builder_state.scaling_active_task, tick)
    return
  end

  builder_state.scaling_active_task = nil

  if not builder_state.task_state then
    plan_scaling(builder_state, tick)
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

    if square_distance(entity.position, destination_position) <= (1.1 * 1.1) then
      set_idle(entity)
      task_state.phase = "scaling-collecting-site"
      debug_log("scaling: reached collection site at " .. format_position(destination_position))
      return
    end

    local direction = direction_from_delta(
      destination_position.x - entity.position.x,
      destination_position.y - entity.position.y
    )

    if direction then
      entity.walking_state = {
        walking = true,
        direction = direction
      }
    end

    if square_distance(entity.position, task_state.last_position) > 0.0025 then
      task_state.last_position = clone_position(entity.position)
      task_state.last_progress_tick = tick
      return
    end

    if tick - task_state.last_progress_tick >= (3 * 60) then
      start_scaling_wait(builder_state, tick, "collection-movement-stalled", "scaling: movement stalled while approaching collection site")
    end
    return
  end

  if phase == "scaling-collecting-site" then
    collect_from_scaling_site(builder_state, tick)
    return
  end

  if phase == "scaling-crafting" then
    if tick >= (builder_state.task_state.craft_complete_tick or 0) then
      finish_scaling_craft(builder_state)
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

local function advance_builder(builder_state, tick)
  configure_builder_entity(builder_state.entity)
  process_production_sites(tick)
  collect_nearby_container_items(builder_state, tick)
  collect_nearby_machine_output_items(builder_state, tick)
  refuel_nearby_machines(builder_state, tick)

  local task = get_active_task(builder_state)
  if not task then
    if builder_data.scaling and builder_data.scaling.enabled then
      advance_scaling(builder_state, tick)
    else
      set_idle(builder_state.entity)
    end
    return
  end

  if not builder_state.task_state then
    start_task(builder_state, task, tick)
    return
  end

  advance_task_phase(builder_state, task, tick)
end

local function on_init()
  ensure_debug_settings()
  ensure_production_sites()
  ensure_resource_sites()
  ensure_builder_map_markers()
  ensure_builder_force()

  local player = get_first_valid_player()
  if player then
    local builder_state = spawn_builder_for_player(player)
    if builder_state then
      discover_resource_sites(builder_state)
    end
  else
    debug_log("on_init: no player character available yet")
  end

  update_builder_overlays(get_builder_state(), game.tick, true)
  update_builder_map_markers(get_builder_state(), game.tick, true)
end

local function on_configuration_changed()
  ensure_debug_settings()
  ensure_production_sites()
  ensure_resource_sites()
  ensure_builder_map_markers()
  ensure_builder_force()

  if not get_builder_state() then
    local player = get_first_valid_player()
    if player then
      local builder_state = spawn_builder_for_player(player)
      if builder_state then
        discover_resource_sites(builder_state)
      end
    else
      debug_log("on_configuration_changed: no player character available yet")
    end
  else
    discover_resource_sites(get_builder_state())
  end

  update_builder_overlays(get_builder_state(), game.tick, true)
  update_builder_map_markers(get_builder_state(), game.tick, true)
end

local function on_player_created(event)
  local player = game.get_player(event.player_index)
  if player then
    debug_log("on_player_created: player " .. player.name)
    spawn_builder_for_player(player)
    update_builder_overlay_for_player(player, get_builder_state())
    update_builder_map_markers(get_builder_state(), game.tick, true)
  end
end

local function on_tick(event)
  local builder_state = get_builder_state()
  if not builder_state then
    local player = get_first_valid_player()
    if player then
      builder_state = spawn_builder_for_player(player)
    end
  end

  if builder_state then
    advance_builder(builder_state, event.tick)
  end

  update_builder_overlays(builder_state, event.tick, false)
  update_builder_map_markers(builder_state, event.tick, false)
end

function builder_runtime.register_events()
  if commands.commands["enemy-builder-status"] then
    commands.remove_command("enemy-builder-status")
  end
  commands.add_command("enemy-builder-status", "Show the current Enemy Builder state.", debug_status_command)

  if commands.commands["enemy-builder-debug"] then
    commands.remove_command("enemy-builder-debug")
  end
  commands.add_command("enemy-builder-debug", "Toggle Enemy Builder debug logging. Use on or off.", debug_toggle_command)

  if commands.commands["enemy-builder-retask"] then
    commands.remove_command("enemy-builder-retask")
  end
  commands.add_command("enemy-builder-retask", "Clear the current Enemy Builder task state and retry.", debug_retask_command)

  script.on_init(on_init)
  script.on_configuration_changed(on_configuration_changed)
  script.on_event(defines.events.on_player_created, on_player_created)
  script.on_event(defines.events.on_tick, on_tick)
end

return builder_runtime

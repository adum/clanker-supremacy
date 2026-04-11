local builder_data = require("shared.builder_data")
local goal_engine = require("scripts.goal_engine")
local goal_tree = require("scripts.goal_tree")
local maintenance_runner = require("scripts.maintenance_runner")
local task_executor = require("scripts.task_executor")
local world_model = require("scripts.world_model")
local world_snapshot = require("scripts.world_snapshot")

local builder_runtime = {}
local debug_prefix = "[enemy-builder] "
local overlay_element_names = {
  status_root = "enemy_builder_status_overlay_root",
  goal_label = "enemy_builder_goal_overlay_label",
  status_label = "enemy_builder_status_overlay_label",
  path_label = "enemy_builder_path_overlay_label",
  blockers_label = "enemy_builder_blockers_overlay_label",
  maintenance_label = "enemy_builder_maintenance_overlay_label",
  inventory_root = "enemy_builder_inventory_overlay_root",
  inventory_title = "enemy_builder_inventory_overlay_title",
  inventory_label = "enemy_builder_inventory_overlay_label"
}
local get_builder_state
local get_active_task
local get_item_count
local get_recipe
local get_builder_main_inventory
local ensure_production_sites
local ensure_resource_sites
local get_pending_scaling_milestone
local get_site_pattern
local get_resource_site_counts
local get_site_collect_inventory
local get_site_collect_position
local get_site_allowed_items
local get_site_collect_count
local pull_inventory_contents_to_builder
local find_layout_site_near_machine
local find_machine_site_near_resource_sites
local find_resource_site
local find_nearest_resource
local register_assembler_defense_site
local register_resource_site
local register_smelting_site
local register_steel_smelting_site
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

local cardinal_direction_rotation_order = {"north", "east", "south", "west"}
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

local function rotate_offset(offset, orientation)
  if not offset then
    return {x = 0, y = 0}
  end

  local x = offset.x or 0
  local y = offset.y or 0

  if orientation == "east" then
    return {x = -y, y = x}
  end

  if orientation == "south" then
    return {x = -x, y = -y}
  end

  if orientation == "west" then
    return {x = y, y = -x}
  end

  return {x = x, y = y}
end

local function rotate_direction_name(direction_name, orientation)
  if not direction_name then
    return nil
  end

  local base_index = nil
  for index, candidate_name in ipairs(cardinal_direction_rotation_order) do
    if candidate_name == direction_name then
      base_index = index
      break
    end
  end

  if not base_index then
    return direction_name
  end

  local rotation_steps = 0
  if orientation == "east" then
    rotation_steps = 1
  elseif orientation == "south" then
    rotation_steps = 2
  elseif orientation == "west" then
    rotation_steps = 3
  end

  local rotated_index = ((base_index - 1 + rotation_steps) % #cardinal_direction_rotation_order) + 1
  return cardinal_direction_rotation_order[rotated_index]
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

  if builder_state.next_machine_input_supply_tick then
    lines[#lines + 1] = "next-machine-input-supply-tick=" .. builder_state.next_machine_input_supply_tick
  end

  if builder_state.next_machine_output_collection_tick then
    lines[#lines + 1] = "next-machine-output-collection-tick=" .. builder_state.next_machine_output_collection_tick
  end

  if builder_state.completed_scaling_milestones then
    lines[#lines + 1] = "completed-scaling-milestones=" .. count_table_entries(builder_state.completed_scaling_milestones)
  end

  lines[#lines + 1] = "production-sites=" .. #ensure_production_sites()
  lines[#lines + 1] = "resource-sites=" .. #ensure_resource_sites()

  if builder_state.goal_tree_root then
    lines[#lines + 1] = "goal=" .. goal_tree.get_root_goal_line(builder_state.goal_tree_root)
    for _, path_line in ipairs(builder_state.goal_path_lines or {}) do
      lines[#lines + 1] = "goal-path=" .. path_line
    end
    for _, blocker_line in ipairs(builder_state.goal_blocker_lines or {}) do
      lines[#lines + 1] = "goal-blocker=" .. blocker_line
    end
  end

  for _, maintenance_line in ipairs(maintenance_runner.get_recent_action_lines(builder_state, 4)) do
    lines[#lines + 1] = "maintenance=" .. maintenance_line
  end

  for _, trace_line in ipairs(goal_engine.get_recent_trace_lines(builder_state, 4)) do
    lines[#lines + 1] = "goal-trace=" .. trace_line
  end

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

  if builder_state.manual_goal_request == nil then
    builder_state.manual_goal_request = nil
  end

  if builder_state.maintenance_state == nil then
    builder_state.maintenance_state = {
      recent_actions = {}
    }
  end

  if builder_state.goal_tree_root == nil then
    builder_state.goal_tree_root = nil
  end

  if builder_state.goal_path_lines == nil then
    builder_state.goal_path_lines = {}
  end

  if builder_state.goal_blocker_lines == nil then
    builder_state.goal_blocker_lines = {}
  end

  if builder_state.goal_engine == nil then
    builder_state.goal_engine = nil
  end

  if builder_state.last_recovery == nil then
    builder_state.last_recovery = nil
  end

  if builder_state.task_retry_state == nil then
    builder_state.task_retry_state = {
      counts = {},
      cooldowns = {}
    }
  end

  return builder_state
end

builder_runtime.ensure_builder_state_fields = ensure_builder_state_fields

local function normalize_builder_task_state(builder_state)
  local task_state = builder_state and builder_state.task_state or nil
  if not task_state then
    return
  end

  if task_state.phase == "scaling-crafting" and task_state.craft_item_name == "steel-plate" and not get_recipe("steel-plate") then
    builder_state.task_state = nil
    debug_log("cleared legacy steel-plate crafting state so steel can be sourced from furnaces instead")
  end
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
  goal_engine.normalize_scaling_active_task(
    builder_data,
    state,
    {
      get_site_pattern = get_site_pattern
    }
  )
  normalize_builder_task_state(state)
  return state
end

function builder_runtime.debug_status_command(command)
  ensure_debug_settings()

  local builder_state = get_builder_state()
  if builder_state then
    builder_runtime.update_goal_model(builder_state, game.tick)
  end

  local lines = describe_builder_state(builder_state)
  for _, line in ipairs(lines) do
    reply_to_command(command, line)
  end
end

function builder_runtime.debug_toggle_command(command)
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

function builder_runtime.debug_retask_command(command)
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

function builder_runtime.ensure_builder_for_command(command)
  local builder_state = get_builder_state()
  if builder_state then
    return builder_state
  end

  local player = get_command_player(command) or get_first_valid_player()
  if player then
    return spawn_builder_for_player(player)
  end

  return nil
end

function builder_runtime.parse_manual_component_request(command, builder_state)
  local parameter = command.parameter or ""
  local tokens = {}
  for token in string.gmatch(parameter, "%S+") do
    tokens[#tokens + 1] = token
  end

  local component_name = tokens[1]
  if not component_name then
    return nil, nil, "usage: /" .. command.name .. " <component> [here|x y]"
  end

  local position = nil
  if tokens[2] == "here" then
    local player = get_command_player(command)
    if player and player.valid then
      position = clone_position(player.position)
    elseif builder_state and builder_state.entity and builder_state.entity.valid then
      position = clone_position(builder_state.entity.position)
    end
  elseif tokens[2] then
    local x = tonumber(tokens[2])
    local y = tonumber(tokens[3])
    if not (x and y) then
      return nil, nil, "expected coordinates as <x y> or the keyword 'here'"
    end
    position = {x = x, y = y}
  end

  return component_name, position
end

function builder_runtime.goals_command(command)
  local builder_state = builder_runtime.ensure_builder_for_command(command)
  if not builder_state then
    reply_to_command(command, "no builder entity is active")
    return
  end

  builder_runtime.update_goal_model(builder_state, game.tick)
  for _, line in ipairs(goal_tree.format_tree_lines(builder_state.goal_tree_root, false)) do
    reply_to_command(command, line)
  end
end

function builder_runtime.manual_plan_command(command)
  local builder_state = builder_runtime.ensure_builder_for_command(command)
  local component_name, position, error_message = builder_runtime.parse_manual_component_request(command, builder_state)
  if error_message then
    reply_to_command(command, error_message)
    reply_to_command(command, "components: " .. table.concat(goal_tree.list_component_names(builder_data), ", "))
    return
  end

  if not builder_state then
    reply_to_command(command, "no builder entity is active")
    return
  end

  local lines, preview_error = goal_tree.describe_plan_preview(
    builder_data,
    builder_runtime.build_runtime_snapshot(builder_state, game.tick),
    {
      get_item_count = get_item_count,
      get_recipe = get_recipe
    },
    component_name,
    position
  )

  if preview_error then
    reply_to_command(command, preview_error)
    reply_to_command(command, "components: " .. table.concat(goal_tree.list_component_names(builder_data), ", "))
    return
  end

  for _, line in ipairs(lines or {}) do
    reply_to_command(command, line)
  end
end

function builder_runtime.manual_build_command(command)
  local builder_state = builder_runtime.ensure_builder_for_command(command)
  local component_name, position, error_message = builder_runtime.parse_manual_component_request(command, builder_state)
  if error_message then
    reply_to_command(command, error_message)
    reply_to_command(command, "components: " .. table.concat(goal_tree.list_component_names(builder_data), ", "))
    return
  end

  if not builder_state then
    reply_to_command(command, "no builder entity is active")
    return
  end

  local request, request_error = goal_tree.instantiate_manual_request(builder_data, component_name, position)
  if request_error then
    reply_to_command(command, request_error)
    reply_to_command(command, "components: " .. table.concat(goal_tree.list_component_names(builder_data), ", "))
    return
  end

  builder_state.manual_goal_request = request
  builder_state.task_state = nil
  if builder_state.goal_engine then
    builder_state.goal_engine.scaling_display_task = nil
  end
  set_idle(builder_state.entity)
  builder_runtime.record_recovery(builder_state, "manual goal injected for " .. request.display_name)
  debug_log("manual goal injected: " .. request.display_name .. (position and " at " .. format_position(position) or ""))
  reply_to_command(command, "manual goal queued: " .. request.display_name)
end

function builder_runtime.cancel_manual_command(command)
  local builder_state = get_builder_state()
  if not builder_state or not builder_state.manual_goal_request then
    reply_to_command(command, "no manual goal is active")
    return
  end

  local display_name = builder_state.manual_goal_request.display_name or builder_state.manual_goal_request.component_name or "manual goal"
  builder_state.manual_goal_request = nil
  builder_state.task_state = nil
  if builder_state.goal_engine then
    builder_state.goal_engine.scaling_display_task = nil
  end
  set_idle(builder_state.entity)
  debug_log("manual goal cancelled: " .. display_name)
  reply_to_command(command, "cancelled " .. display_name)
end

get_active_task = function(builder_state)
  return goal_engine.get_active_task(builder_data, builder_state)
end

function builder_runtime.get_display_task(builder_state)
  return goal_engine.get_display_task(builder_data, builder_state)
end

function builder_runtime.record_recovery(builder_state, message)
  if not builder_state then
    return
  end

  builder_state.last_recovery = {
    tick = game and game.tick or nil,
    message = message
  }
end

function builder_runtime.clear_recovery(builder_state)
  if builder_state then
    builder_state.last_recovery = nil
  end
end

function builder_runtime.get_inventory_contents(entity)
  local inventory = get_builder_main_inventory(entity)
  return inventory and inventory.get_contents() or {}
end

function builder_runtime.build_runtime_snapshot(builder_state, tick)
  return world_snapshot.build(
    builder_data,
    builder_state,
    tick,
    {
      get_active_task = get_active_task,
      get_display_task = builder_runtime.get_display_task,
      get_production_site_count = function()
        return #ensure_production_sites()
      end,
      get_resource_site_count = function()
        return #cleanup_resource_sites()
      end,
      get_resource_site_counts = get_resource_site_counts,
      get_item_count = get_item_count,
      get_inventory_contents = builder_runtime.get_inventory_contents
    }
  )
end

function builder_runtime.update_goal_model(builder_state, tick)
  if not builder_state then
    return nil
  end

  return goal_engine.sync_model(
    builder_data,
    builder_state,
    tick,
    {
      build_runtime_snapshot = builder_runtime.build_runtime_snapshot,
      debug_log = debug_log,
      get_item_count = get_item_count,
      get_recipe = get_recipe
    }
  )
end

function builder_runtime.get_task_retry_key(task)
  if not task then
    return "task:unknown"
  end

  if task.repeatable_scaling_milestone_name then
    return "repeatable-milestone:" .. task.repeatable_scaling_milestone_name
  end

  if task.completed_scaling_milestone_name then
    return "milestone:" .. task.completed_scaling_milestone_name
  end

  if task.scaling_pattern_name then
    return "pattern:" .. task.scaling_pattern_name
  end

  return "task:" .. tostring(task.id or task.type or "unknown")
end

function builder_runtime.get_retry_state(builder_state)
  ensure_builder_state_fields(builder_state)
  return builder_state.task_retry_state
end

function builder_runtime.get_retry_cooldown_ticks()
  return (builder_data.recovery and builder_data.recovery.blocked_goal_cooldown_ticks) or (15 * 60)
end

function builder_runtime.get_retry_limit()
  return (builder_data.recovery and builder_data.recovery.max_task_retries) or 6
end

function builder_runtime.prune_retry_cooldowns(builder_state, tick)
  local retry_state = builder_runtime.get_retry_state(builder_state)
  for key, until_tick in pairs(retry_state.cooldowns) do
    if tick >= until_tick then
      retry_state.cooldowns[key] = nil
    end
  end
end

function builder_runtime.is_goal_retry_blocked(builder_state, key, tick)
  if not builder_state or not key then
    return false
  end

  builder_runtime.prune_retry_cooldowns(builder_state, tick)
  local retry_state = builder_runtime.get_retry_state(builder_state)
  return retry_state.cooldowns[key] ~= nil
end

function builder_runtime.clear_task_retry_state(builder_state, task)
  if not (builder_state and task) then
    return
  end

  local retry_state = builder_runtime.get_retry_state(builder_state)
  retry_state.counts[builder_runtime.get_task_retry_key(task)] = nil
end

function builder_runtime.enter_task_retry_cooldown(builder_state, task, tick, reason)
  if not (builder_state and task) then
    return
  end

  local retry_key = builder_runtime.get_task_retry_key(task)
  local retry_state = builder_runtime.get_retry_state(builder_state)
  retry_state.counts[retry_key] = nil
  retry_state.cooldowns[retry_key] = tick + builder_runtime.get_retry_cooldown_ticks()

  builder_runtime.record_recovery(
    builder_state,
    (reason or ("blocked " .. retry_key)) ..
      "; cooling down until tick " .. retry_state.cooldowns[retry_key]
  )
end

function builder_runtime.handle_task_retry_exhausted(builder_state, task, tick, reason)
  local task_name = task and (task.id or task.type) or "task"
  local message = (reason or ("retry limit reached for " .. task_name))

  if task and task.manual_goal_id and builder_state.manual_goal_request and builder_state.manual_goal_request.id == task.manual_goal_id then
    builder_state.manual_goal_request = nil
    builder_state.task_state = nil
    if builder_state.goal_engine then
      builder_state.goal_engine.scaling_display_task = nil
    end
    set_idle(builder_state.entity)
    builder_runtime.enter_task_retry_cooldown(builder_state, task, tick, message)
    debug_log("task " .. task_name .. ": aborting manual goal after repeated failures: " .. message)
    return
  end

  if task and task.no_advance then
    builder_state.scaling_active_task = nil
    builder_state.task_state = nil
    if builder_state.goal_engine then
      builder_state.goal_engine.scaling_display_task = nil
    end
    set_idle(builder_state.entity)
    builder_runtime.enter_task_retry_cooldown(builder_state, task, tick, message)
    debug_log("task " .. task_name .. ": abandoning scaling subtask after repeated failures: " .. message)
    return
  end

  builder_runtime.clear_task_retry_state(builder_state, task)
  builder_state.task_state = {
    phase = "waiting-for-resource",
    wait_reason = "retry-exhausted",
    next_attempt_tick = tick + builder_runtime.get_retry_cooldown_ticks()
  }
  set_idle(builder_state.entity)
  builder_runtime.record_recovery(builder_state, message)
  debug_log("task " .. task_name .. ": delaying retry after repeated failures: " .. message)
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

  if milestone.pursue_proactively == true then
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

local function get_approach_randomness(task, arrival_distance)
  local movement_settings = builder_data.movement or {}
  local max_offset = task and task.approach_randomness

  if max_offset == nil then
    max_offset = movement_settings.approach_randomness or 0
  end

  if arrival_distance and arrival_distance > 0 then
    max_offset = math.min(max_offset, arrival_distance * 0.75)
  end

  if max_offset < 0.01 then
    return 0
  end

  return max_offset
end

local function create_randomized_approach_position(target_position, max_offset)
  if not target_position then
    return nil
  end

  if not max_offset or max_offset <= 0 then
    return clone_position(target_position)
  end

  local angle = (next_random_index(360) - 1) * (math.pi / 180)
  local radius = ((next_random_index(1000) - 1) / 999) * max_offset

  return {
    x = target_position.x + (math.cos(angle) * radius),
    y = target_position.y + (math.sin(angle) * radius)
  }
end

local function create_task_approach_position(task, target_position, arrival_distance)
  return create_randomized_approach_position(
    target_position,
    get_approach_randomness(task, arrival_distance or (task and task.arrival_distance) or nil)
  )
end

local function destroy_entity_if_valid(entity)
  if entity and entity.valid then
    entity.destroy()
  end
end

get_item_count = function(entity, item_name)
  return entity.get_item_count(item_name)
end

get_builder_main_inventory = function(entity)
  if not (entity and entity.valid) then
    return nil
  end

  return entity.get_inventory(defines.inventory.character_main)
end

local function get_inventory_take_limit(item_name)
  local limits = builder_data.logistics and builder_data.logistics.inventory_take_limits
  if not limits then
    return nil
  end

  return limits[item_name]
end

local function get_inventory_take_allowance(entity, item_name)
  local limit = get_inventory_take_limit(item_name)
  if not limit then
    return nil
  end

  return math.max(0, limit - get_item_count(entity, item_name))
end

local function get_capped_collection_stack(entity, item_stack)
  local allowance = get_inventory_take_allowance(entity, item_stack.name)
  if allowance == nil then
    return item_stack
  end

  if allowance <= 0 then
    return nil
  end

  if item_stack.count <= allowance then
    return item_stack
  end

  return {
    name = item_stack.name,
    quality = item_stack.quality,
    count = allowance
  }
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

local function transfer_inventory_item(source_inventory, destination_inventory, item_name, requested_count, debug_reason)
  if not (source_inventory and destination_inventory and item_name and requested_count and requested_count > 0) then
    return 0
  end

  local available_count = source_inventory.get_item_count(item_name)
  if available_count <= 0 then
    return 0
  end

  local inserted_count = destination_inventory.insert{
    name = item_name,
    count = math.min(requested_count, available_count)
  }

  if inserted_count <= 0 then
    return 0
  end

  source_inventory.remove{
    name = item_name,
    count = inserted_count
  }

  if debug_reason then
    debug_log(debug_reason .. ": moved " .. item_name .. "=" .. inserted_count)
  end

  return inserted_count
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

local function entity_overlaps_resources(entity)
  if not (entity and entity.valid) then
    return false
  end

  return #entity.surface.find_entities_filtered{
    area = entity.selection_box,
    type = "resource",
    limit = 1
  } > 0
end

local function count_registered_sites_near_position(requirement, position)
  if not (requirement and requirement.site_type and position) then
    return 0
  end

  local count = 0
  local radius = requirement.radius or 24
  local radius_squared = radius * radius
  local entity_field = requirement.entity_field or "assembler"

  for _, site in ipairs(ensure_production_sites()) do
    local entity = site[entity_field]
    if site.site_type == requirement.site_type and entity and entity.valid then
      if square_distance(position, entity.position) <= radius_squared then
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

  for _, site in ipairs(ensure_production_sites()) do
    if site.site_type == requirement.site_type and site[entity_field] == anchor_entity then
      return true
    end
  end

  return false
end

local function find_entity_placement_near_anchor(surface, force, entity_name, anchor_position, search_radius, step, directions, placement_validator)
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
          if not placement_validator or placement_validator(position, direction) then
            return clone_position(position), direction, stats
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
          return clone_position(position), nil, stats
        end
      end
    end
  end

  return nil, nil, stats
end

local function layout_fits_around_anchor_entity(builder, anchor_entity, layout_config, summary)
  if not layout_config then
    return true
  end

  if layout_config.forbid_resource_overlap and entity_overlaps_resources(anchor_entity) then
    if summary then
      summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
    end
    return false
  end

  for _, orientation in ipairs(layout_config.layout_orientations or {"north"}) do
    local probe_entities = {}
    local layout_valid = true

    for _, element in ipairs(layout_config.layout_elements or {}) do
      local rotated_offset = rotate_offset(element.offset, orientation)
      local desired_position = {
        x = anchor_entity.position.x + rotated_offset.x,
        y = anchor_entity.position.y + rotated_offset.y
      }
      local direction_name = rotate_direction_name(element.direction_name, orientation)
      local build_position, build_direction = find_entity_placement_near_anchor(
        builder.surface,
        builder.force,
        element.entity_name,
        desired_position,
        element.placement_search_radius or 0,
        element.placement_step or 0.5,
        direction_name and {direction_by_name[direction_name]} or nil
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

      if layout_config.forbid_resource_overlap and entity_overlaps_resources(probe_entity) then
        if summary then
          summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
        end
        layout_valid = false
        break
      end
    end

    for _, probe_entity in ipairs(probe_entities) do
      if probe_entity and probe_entity.valid then
        probe_entity.destroy()
      end
    end

    if layout_valid then
      return true
    end
  end

  return false
end

local function machine_site_candidate_is_valid(builder, task, position, direction, summary)
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

  if task.forbid_resource_overlap and entity_overlaps_resources(probe_entity) then
    summary.resource_overlap_rejections = (summary.resource_overlap_rejections or 0) + 1
    valid = false
  end

  if valid and task.layout_reservation and not layout_fits_around_anchor_entity(builder, probe_entity, task.layout_reservation, summary) then
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

local function find_machine_site_near_resource_sites(builder_state, task)
  discover_resource_sites(builder_state)

  local builder = builder_state.entity
  local origin = task.manual_search_origin or builder.position
  local anchor_candidates = {}
  local anchor_preference = task.anchor_preference and task.anchor_preference.fewer_registered_sites or nil

  for _, site in ipairs(cleanup_resource_sites()) do
    if site_matches_patterns(site, task.anchor_pattern_names) then
      local anchor_position = get_anchor_site_position(site, task.anchor_position_source)
      if anchor_position then
        anchor_candidates[#anchor_candidates + 1] = {
          site = site,
          anchor_position = anchor_position,
          distance = square_distance(origin, anchor_position),
          nearby_registered_site_count = count_registered_sites_near_position(anchor_preference, anchor_position)
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
        return machine_site_candidate_is_valid(builder, task, position, direction, summary)
      end or nil
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

local function get_task_anchor_entity_names(task)
  if not task then
    return nil
  end

  if task.anchor_entity_names and #task.anchor_entity_names > 0 then
    return task.anchor_entity_names
  end

  if task.anchor_entity_name then
    return {task.anchor_entity_name}
  end

  return nil
end

local function destroy_entities(entities)
  for _, entity in ipairs(entities or {}) do
    if entity and entity.valid then
      entity.destroy()
    end
  end
end

local function find_layout_site_near_machine(builder_state, task)
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
    discover_resource_sites(builder_state)

    for _, site in ipairs(cleanup_resource_sites()) do
      if site_matches_patterns(site, task.anchor_pattern_names) then
        local anchor_entity = get_anchor_site_entity(site, task.anchor_position_source)
        if anchor_entity then
          local distance = square_distance(anchor_origin, anchor_entity.position)
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
    local anchor_entity_names = get_task_anchor_entity_names(task)
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
        distance = square_distance(anchor_origin, anchor_entity.position)
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

        if task.forbid_resource_overlap and entity_overlaps_resources(anchor_entity) then
          summary.resource_overlap_rejections = summary.resource_overlap_rejections + 1
        else
          for _, orientation in ipairs(task.layout_orientations or {"north"}) do
            summary.orientations_considered = summary.orientations_considered + 1

            local placements = {}
            local probe_entities = {}
            local layout_valid = true

            for _, element in ipairs(task.layout_elements or {}) do
              summary.layout_elements_checked = summary.layout_elements_checked + 1

              local rotated_offset = rotate_offset(element.offset, orientation)
              local desired_position = {
                x = anchor_entity.position.x + rotated_offset.x,
                y = anchor_entity.position.y + rotated_offset.y
              }
              local direction_name = rotate_direction_name(element.direction_name, orientation)
              local build_position, build_direction, placement_stats = find_entity_placement_near_anchor(
                builder.surface,
                builder.force,
                element.entity_name,
                desired_position,
                element.placement_search_radius or 0,
                element.placement_step or 0.5,
                direction_name and {direction_by_name[direction_name]} or nil
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

              if task.forbid_resource_overlap and entity_overlaps_resources(probe_entity) then
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
                build_position = clone_position(build_position),
                build_direction = build_direction,
                fuel = element.fuel
              }
            end

            destroy_entities(probe_entities)

            if layout_valid then
              return {
                site = anchor_candidate.site,
                anchor_entity = anchor_entity,
                anchor_position = clone_position(anchor_entity.position),
                build_position = clone_position(anchor_entity.position),
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

local function collect_nearby_container_items(builder_state, tick)
  local collection_settings = builder_data.logistics and builder_data.logistics.nearby_container_collection
  if not collection_settings then
    return {}
  end

  if tick < (builder_state.next_container_scan_tick or 0) then
    return {}
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
  local actions = {}

  for _, container in ipairs(containers) do
    if collection_settings.max_containers_per_scan and containers_scanned >= collection_settings.max_containers_per_scan then
      break
    end

    if container.valid then
      containers_scanned = containers_scanned + 1

      local inventory = get_container_inventory(container)
      if inventory and not inventory.is_empty() then
        local moved_items = pull_inventory_contents_to_builder(
          inventory,
          builder,
          "collected from " .. container.name .. " at " .. format_position(container.position)
        )

        if #moved_items > 0 then
          actions[#actions + 1] = "collected from " .. container.name .. " at " .. format_position(container.position)
        end
      end
    end
  end

  return actions
end

local function collect_nearby_machine_output_items(builder_state, tick)
  local collection_settings = builder_data.logistics and builder_data.logistics.nearby_machine_output_collection
  if not collection_settings then
    return {}
  end

  if tick < (builder_state.next_machine_output_collection_tick or 0) then
    return {}
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
  local actions = {}

  for _, entity in ipairs(entities) do
    if collection_settings.max_entities_per_scan and entities_scanned >= collection_settings.max_entities_per_scan then
      break
    end

    if entity.valid and entity ~= builder then
      entities_scanned = entities_scanned + 1

      local output_inventory = entity.get_output_inventory and entity.get_output_inventory()
      if output_inventory and not output_inventory.is_empty() then
        local moved_items = pull_inventory_contents_to_builder(
          output_inventory,
          builder,
          "collected from " .. entity.name .. " output at " .. format_position(entity.position)
        )

        if #moved_items > 0 then
          actions[#actions + 1] = "collected output from " .. entity.name .. " at " .. format_position(entity.position)
        end
      end
    end
  end

  return actions
end

local function refuel_nearby_machines(builder_state, tick)
  local refuel_settings = builder_data.logistics and builder_data.logistics.nearby_machine_refuel
  if not refuel_settings then
    return {}
  end

  if tick < (builder_state.next_machine_refuel_tick or 0) then
    return {}
  end

  builder_state.next_machine_refuel_tick = tick + refuel_settings.interval_ticks

  local builder = builder_state.entity
  local fuel_name = refuel_settings.fuel_name or "coal"
  local available_fuel = get_item_count(builder, fuel_name)
  if available_fuel <= 0 then
    return {}
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
  local actions = {}

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
                actions[#actions + 1] = "refueled " .. entity.name .. " at " .. format_position(entity.position)
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

  return actions
end

local function supply_nearby_machine_inputs(builder_state, tick)
  local supply_settings = builder_data.logistics and builder_data.logistics.nearby_machine_input_supply
  if not supply_settings then
    return {}
  end

  if tick < (builder_state.next_machine_input_supply_tick or 0) then
    return {}
  end

  builder_state.next_machine_input_supply_tick = tick + supply_settings.interval_ticks

  local builder = builder_state.entity
  local filter = {
    position = builder.position,
    radius = supply_settings.radius
  }

  if supply_settings.entity_type then
    filter.type = supply_settings.entity_type
  elseif supply_settings.entity_types then
    filter.type = supply_settings.entity_types
  end

  if supply_settings.entity_name then
    filter.name = supply_settings.entity_name
  elseif supply_settings.entity_names then
    filter.name = supply_settings.entity_names
  end

  if supply_settings.own_force_only then
    filter.force = builder.force
  end

  local entities = builder.surface.find_entities_filtered(filter)
  table.sort(entities, function(left, right)
    return square_distance(builder.position, left.position) < square_distance(builder.position, right.position)
  end)

  local entities_scanned = 0
  local actions = {}

  for _, entity in ipairs(entities) do
    if supply_settings.max_entities_per_scan and entities_scanned >= supply_settings.max_entities_per_scan then
      break
    end

    if entity.valid and entity ~= builder then
      entities_scanned = entities_scanned + 1

      local recipe = entity.get_recipe and entity.get_recipe()
      local input_inventory = entity.get_inventory and entity.get_inventory(defines.inventory.assembling_machine_input)

      if recipe and input_inventory then
        for _, ingredient in ipairs(recipe.ingredients or {}) do
          local ingredient_type = ingredient.type or "item"
          local ingredient_name = ingredient.name

          if ingredient_type == "item" and ingredient_name then
            local current_count = input_inventory.get_item_count(ingredient_name)
            local desired_count = (supply_settings.target_ingredient_item_count or 20) - current_count

            if desired_count > 0 then
              local available_count = get_item_count(builder, ingredient_name)
              local transfer_count = math.min(desired_count, available_count)

              if transfer_count > 0 then
                local inserted_count = input_inventory.insert{
                  name = ingredient_name,
                  count = transfer_count
                }

                if inserted_count > 0 then
                  local reason =
                    "supplied " .. ingredient_name .. " to " .. entity.name ..
                    " at " .. format_position(entity.position)
                  local removed_count = remove_item(builder, ingredient_name, inserted_count, reason)

                  if removed_count < inserted_count then
                    input_inventory.remove{
                      name = ingredient_name,
                      count = inserted_count - removed_count
                    }
                    inserted_count = removed_count
                  end

                  if inserted_count > 0 then
                    debug_log(
                      reason .. " with " .. inserted_count ..
                      "; machine now has " .. input_inventory.get_item_count(ingredient_name) ..
                      " " .. ingredient_name
                    )
                    actions[#actions + 1] = "supplied " .. ingredient_name .. " to " .. entity.name .. " at " .. format_position(entity.position)
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  return actions
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

local function register_steel_smelting_site(task, anchor_machine, feed_inserter, downstream_machine, miner)
  if not (task and anchor_machine and anchor_machine.valid and feed_inserter and feed_inserter.valid and downstream_machine and downstream_machine.valid) then
    return nil
  end

  local production_sites = ensure_production_sites()
  local task_id = (task and task.id) or (task and task.pattern_name) or "steel-smelting-site"

  for _, site in ipairs(production_sites) do
    if site.site_type == "steel-smelting-chain" and site.anchor_machine == anchor_machine then
      site.task_id = task_id
      site.miner = miner
      site.anchor_machine = anchor_machine
      site.feed_inserter = feed_inserter
      site.downstream_machine = downstream_machine
      site.input_item_names = {
        ["iron-plate"] = true
      }
      site.transfer_interval_ticks = (builder_data.logistics and builder_data.logistics.production_transfer and builder_data.logistics.production_transfer.interval_ticks) or 30
      return site
    end
  end

  production_sites[#production_sites + 1] = {
    task_id = task_id,
    site_type = "steel-smelting-chain",
    miner = miner,
    anchor_machine = anchor_machine,
    feed_inserter = feed_inserter,
    downstream_machine = downstream_machine,
    input_item_names = {
      ["iron-plate"] = true
    },
    transfer_interval_ticks = (builder_data.logistics and builder_data.logistics.production_transfer and builder_data.logistics.production_transfer.interval_ticks) or 30,
    next_transfer_tick = 0
  }

  debug_log(
    "task " .. task_id .. ": registered steel smelting site with anchor furnace at " ..
    format_position(anchor_machine.position) .. ", burner-inserter at " ..
    format_position(feed_inserter.position) .. ", steel furnace at " ..
    format_position(downstream_machine.position)
  )

  return production_sites[#production_sites]
end

local function register_assembler_defense_site(task, assembler, placed_layout_entities)
  if not (task and assembler and assembler.valid) then
    return nil
  end

  local turrets = {}
  local inserters = {}
  local poles = {}
  local solar_panels = {}

  for _, placement in ipairs(placed_layout_entities or {}) do
    local entity = placement.entity
    if entity and entity.valid then
      if placement.site_role == "turret" then
        turrets[#turrets + 1] = entity
      elseif placement.site_role == "burner-inserter" then
        inserters[#inserters + 1] = entity
      elseif placement.site_role == "power-pole" then
        poles[#poles + 1] = entity
      elseif placement.site_role == "solar-panel" then
        solar_panels[#solar_panels + 1] = entity
      end
    end
  end

  if #turrets == 0 then
    return nil
  end

  local production_sites = ensure_production_sites()
  for _, site in ipairs(production_sites) do
    if site.site_type == "assembler-defense" and site.assembler == assembler then
      site.task_id = task.id or task.completed_scaling_milestone_name or "assembler-defense"
      site.turrets = turrets
      site.inserters = inserters
      site.power_poles = poles
      site.solar_panels = solar_panels
      site.ammo_item_name = (task.transfer and task.transfer.ammo_item_name) or "firearm-magazine"
      site.turret_ammo_target_count = (task.transfer and task.transfer.turret_ammo_target_count) or 20
      site.per_turret_transfer_limit = (task.transfer and task.transfer.per_turret_transfer_limit) or 1
      site.transfer_interval_ticks = (task.transfer and task.transfer.interval_ticks) or 30
      return site
    end
  end

  production_sites[#production_sites + 1] = {
    task_id = task.id or task.completed_scaling_milestone_name or "assembler-defense",
    site_type = "assembler-defense",
    assembler = assembler,
    turrets = turrets,
    inserters = inserters,
    power_poles = poles,
    solar_panels = solar_panels,
    ammo_item_name = (task.transfer and task.transfer.ammo_item_name) or "firearm-magazine",
    turret_ammo_target_count = (task.transfer and task.transfer.turret_ammo_target_count) or 20,
    per_turret_transfer_limit = (task.transfer and task.transfer.per_turret_transfer_limit) or 1,
    transfer_interval_ticks = (task.transfer and task.transfer.interval_ticks) or 30,
    next_transfer_tick = 0
  }

  debug_log(
    "task " .. (task.id or "assembler-defense") ..
    ": registered assembler defense site at " .. format_position(assembler.position) ..
    " with " .. tostring(#turrets) .. " turrets"
  )

  return production_sites[#production_sites]
end

local function process_production_sites(tick)
  local production_sites = ensure_production_sites()
  local kept_sites = {}

  for _, site in ipairs(production_sites) do
    if site.site_type == "assembler-defense" then
      local valid_turrets = {}

      for _, turret in ipairs(site.turrets or {}) do
        if turret and turret.valid then
          valid_turrets[#valid_turrets + 1] = turret
        end
      end

      site.turrets = valid_turrets

      if site.assembler and site.assembler.valid and #site.turrets > 0 then
        if tick >= (site.next_transfer_tick or 0) then
          site.next_transfer_tick = tick + (site.transfer_interval_ticks or 30)

          local output_inventory = site.assembler.get_output_inventory and site.assembler.get_output_inventory()
          if output_inventory then
            table.sort(site.turrets, function(left, right)
              local left_inventory = left.get_inventory and left.get_inventory(defines.inventory.turret_ammo)
              local right_inventory = right.get_inventory and right.get_inventory(defines.inventory.turret_ammo)
              local left_count = left_inventory and left_inventory.get_item_count(site.ammo_item_name or "firearm-magazine") or 0
              local right_count = right_inventory and right_inventory.get_item_count(site.ammo_item_name or "firearm-magazine") or 0

              if left_count ~= right_count then
                return left_count < right_count
              end

              return square_distance(site.assembler.position, left.position) < square_distance(site.assembler.position, right.position)
            end)

            for _, turret in ipairs(site.turrets) do
              local ammo_inventory = turret.get_inventory and turret.get_inventory(defines.inventory.turret_ammo)
              if ammo_inventory then
                local desired_count = (site.turret_ammo_target_count or 20) - ammo_inventory.get_item_count(site.ammo_item_name or "firearm-magazine")
                if desired_count > 0 then
                  transfer_inventory_item(
                    output_inventory,
                    ammo_inventory,
                    site.ammo_item_name or "firearm-magazine",
                    math.min(desired_count, site.per_turret_transfer_limit or desired_count),
                    "production site " .. site.task_id .. ": moved ammo into " .. turret.name .. " at " .. format_position(turret.position)
                  )
                end
              end
            end
          end
        end

        kept_sites[#kept_sites + 1] = site
      end
    elseif site.site_type == "steel-smelting-chain" then
      if site.anchor_machine and site.anchor_machine.valid and
        site.feed_inserter and site.feed_inserter.valid and
        site.downstream_machine and site.downstream_machine.valid and
        site.miner and site.miner.valid
      then
        if tick >= (site.next_transfer_tick or 0) then
          site.next_transfer_tick = tick + (site.transfer_interval_ticks or 30)

          transfer_inventory_contents(
            site.anchor_machine.get_output_inventory and site.anchor_machine.get_output_inventory() or nil,
            site.downstream_machine,
            "production site " .. site.task_id .. ": transferred iron plates into " .. site.downstream_machine.name,
            site.input_item_names
          )
        end

        kept_sites[#kept_sites + 1] = site
      end
    elseif site.miner and site.miner.valid and site.downstream_machine and site.downstream_machine.valid and (not site.output_container or site.output_container.valid) then
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
      local capped_stack = get_capped_collection_stack(builder, item_stack)
      local inserted_count = capped_stack and insert_stack(builder, capped_stack, reason) or 0
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

function builder_runtime.ensure_status_overlay(player)
  local root = player.gui.screen[overlay_element_names.status_root]
  if root and root.valid then
    ensure_overlay_label(root, overlay_element_names.goal_label, "", {0.75, 0.9, 1, 0.82})
    ensure_overlay_label(root, overlay_element_names.status_label, "", {1, 1, 1, 0.82})
    ensure_overlay_label(root, overlay_element_names.path_label, "", {0.86, 0.94, 1, 0.72})
    ensure_overlay_label(root, overlay_element_names.blockers_label, "", {1, 0.78, 0.78, 0.78})
    ensure_overlay_label(root, overlay_element_names.maintenance_label, "", {0.86, 0.92, 0.86, 0.72})
    return root
  end

  root = player.gui.screen.add{
    type = "flow",
    name = overlay_element_names.status_root,
    direction = "vertical"
  }
  ensure_overlay_label(root, overlay_element_names.goal_label, "", {0.75, 0.9, 1, 0.82})
  ensure_overlay_label(root, overlay_element_names.status_label, "", {1, 1, 1, 0.82})
  ensure_overlay_label(root, overlay_element_names.path_label, "", {0.86, 0.94, 1, 0.72})
  ensure_overlay_label(root, overlay_element_names.blockers_label, "", {1, 0.78, 0.78, 0.78})
  ensure_overlay_label(root, overlay_element_names.maintenance_label, "", {0.86, 0.92, 0.86, 0.72})
  return root
end

function builder_runtime.ensure_inventory_overlay(player)
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

function builder_runtime.get_activity_summary(builder_state)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return "Enemy Builder: inactive"
  end

  return "Activity: " .. goal_tree.get_activity_line(builder_runtime.build_runtime_snapshot(builder_state, game.tick))
end

function builder_runtime.get_goal_summary(builder_state)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return "Goal: inactive"
  end

  local snapshot = builder_runtime.build_runtime_snapshot(builder_state, game.tick)
  local root = builder_state.goal_tree_root or goal_tree.build_runtime_tree(
    builder_data,
    snapshot,
    {
      get_item_count = get_item_count,
      get_recipe = get_recipe
    }
  )

  return "Goal: " .. goal_tree.get_root_goal_line(root)
end

function builder_runtime.get_builder_inventory_lines(builder_state)
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

function builder_runtime.update_builder_overlay_for_player(player, builder_state)
  if not (player and player.valid and player.connected) then
    return
  end

  if not overlay_enabled() then
    destroy_builder_overlay(player)
    return
  end

  local settings = get_overlay_settings()
  local screen_size = get_player_screen_size(player)
  local status_root = builder_runtime.ensure_status_overlay(player)
  local inventory_root = builder_runtime.ensure_inventory_overlay(player)
  local goal_label = status_root[overlay_element_names.goal_label]
  local status_label = status_root[overlay_element_names.status_label]
  local path_label = status_root[overlay_element_names.path_label]
  local blockers_label = status_root[overlay_element_names.blockers_label]
  local maintenance_label = status_root[overlay_element_names.maintenance_label]
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

  goal_label.caption = builder_runtime.get_goal_summary(builder_state)
  status_label.caption = builder_runtime.get_activity_summary(builder_state)
  local path_lines = builder_state and builder_state.goal_path_lines or {}
  local blocker_lines = builder_state and builder_state.goal_blocker_lines or {}
  local maintenance_lines = maintenance_runner.get_recent_action_lines(builder_state or {}, 4)
  path_label.caption = "Path:\n" .. (#path_lines > 0 and table.concat(path_lines, "\n") or "(none)")
  blockers_label.caption = "Blockers:\n" .. (#blocker_lines > 0 and table.concat(blocker_lines, "\n") or "(none)")
  maintenance_label.caption = "Maintenance:\n" .. (#maintenance_lines > 0 and table.concat(maintenance_lines, "\n") or "(none)")
  inventory_title.caption = "Enemy Builder Inventory"
  inventory_label.caption = table.concat(builder_runtime.get_builder_inventory_lines(builder_state), "\n")
end

function builder_runtime.update_builder_overlays(builder_state, tick, force_update)
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

  if builder_state then
    builder_runtime.update_goal_model(builder_state, tick)
  end

  for _, player in pairs(game.connected_players) do
    builder_runtime.update_builder_overlay_for_player(player, builder_state)
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
    if site.miner and site.miner.valid and
      ((not site.downstream_machine) or site.downstream_machine.valid) and
      ((not site.output_container) or site.output_container.valid) and
      ((not site.identity_entity) or site.identity_entity.valid) and
      ((not site.anchor_machine) or site.anchor_machine.valid) and
      ((not site.feed_inserter) or site.feed_inserter.valid)
    then
      kept_sites[#kept_sites + 1] = site
    end
  end

  storage.resource_sites = kept_sites
  return kept_sites
end

get_resource_site_counts = function()
  local counts = {}

  for _, site in ipairs(cleanup_resource_sites()) do
    if site.pattern_name then
      counts[site.pattern_name] = (counts[site.pattern_name] or 0) + 1
    end
  end

  return counts
end

local function register_resource_site(task, miner, downstream_machine, output_container, extras)
  if not (task and task.pattern_name and miner and miner.valid) then
    return nil
  end

  extras = extras or {}
  local identity_entity = extras.identity_entity or downstream_machine or output_container or miner
  local sites = cleanup_resource_sites()
  for _, site in ipairs(sites) do
    local site_identity_entity = site.identity_entity or site.downstream_machine or site.output_container or site.miner
    if site_identity_entity == identity_entity then
      site.pattern_name = task.pattern_name
      site.resource_name = task.resource_name
      site.downstream_machine = downstream_machine
      site.output_container = output_container
      site.identity_entity = identity_entity
      site.anchor_machine = extras.anchor_machine
      site.feed_inserter = extras.feed_inserter
      site.parent_pattern_name = extras.parent_pattern_name
      return site
    end
  end

  local site = {
    pattern_name = task.pattern_name,
    resource_name = task.resource_name,
    miner = miner,
    downstream_machine = downstream_machine,
    output_container = output_container,
    identity_entity = identity_entity,
    anchor_machine = extras.anchor_machine,
    feed_inserter = extras.feed_inserter,
    parent_pattern_name = extras.parent_pattern_name
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

  if extras.anchor_machine and extras.anchor_machine.valid then
    message = message .. ", anchor " .. extras.anchor_machine.name .. " at " .. format_position(extras.anchor_machine.position)
  end

  if extras.feed_inserter and extras.feed_inserter.valid then
    message = message .. ", " .. extras.feed_inserter.name .. " at " .. format_position(extras.feed_inserter.position)
  end

  debug_log(message)
  return site
end

local function reconcile_production_sites_from_resource_sites()
  local production_sites = ensure_production_sites()

  for _, resource_site in ipairs(cleanup_resource_sites()) do
    local pattern = get_site_pattern(resource_site.pattern_name)
    local build_task = pattern and pattern.build_task or nil

    if build_task and resource_site.miner and resource_site.miner.valid and resource_site.downstream_machine and resource_site.downstream_machine.valid then
      local has_production_site = false

      for _, production_site in ipairs(production_sites) do
        if production_site.downstream_machine == resource_site.downstream_machine or
          (resource_site.anchor_machine and production_site.anchor_machine == resource_site.anchor_machine)
        then
          if production_site.output_container and production_site.output_container.valid then
            resource_site.output_container = production_site.output_container
          end
          has_production_site = true
          break
        end
      end

      if not has_production_site then
        if resource_site.anchor_machine and resource_site.anchor_machine.valid and
          resource_site.feed_inserter and resource_site.feed_inserter.valid
        then
          register_steel_smelting_site(
            build_task or {id = "reconcile-" .. tostring(resource_site.pattern_name or "steel_smelting")},
            resource_site.anchor_machine,
            resource_site.feed_inserter,
            resource_site.downstream_machine,
            resource_site.miner
          )
        elseif build_task.downstream_machine then
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
  if task and task.manual_goal_id and builder_state.manual_goal_request and builder_state.manual_goal_request.id == task.manual_goal_id then
    local request = builder_state.manual_goal_request
    local completed_task_state = builder_state.task_state
    local next_task_index = (request.current_task_index or 1) + 1

    if completed_task_state and completed_task_state.placed_entity and completed_task_state.placed_entity.valid and request.tasks[next_task_index] then
      local next_task = request.tasks[next_task_index]
      next_task.manual_anchor_position = clone_position(completed_task_state.placed_entity.position)
      next_task.manual_anchor_search_radius = next_task.manual_anchor_search_radius or 16
    end

    builder_state.task_state = nil
    if builder_state.goal_engine then
      builder_state.goal_engine.scaling_display_task = nil
    end
    set_idle(builder_state.entity)
    builder_runtime.clear_task_retry_state(builder_state, task)
    builder_runtime.clear_recovery(builder_state)

    if completion_message then
      debug_log("task " .. task.id .. ": " .. completion_message)
    end

    if request.tasks[next_task_index] then
      request.current_task_index = next_task_index
    else
      debug_log("manual goal " .. (request.display_name or request.component_name or "request") .. ": complete")
      builder_state.manual_goal_request = nil
    end
    return
  end

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
    if builder_state.goal_engine then
      builder_state.goal_engine.scaling_display_task = nil
    end
    set_idle(builder_state.entity)
    builder_runtime.clear_task_retry_state(builder_state, task)
    builder_runtime.clear_recovery(builder_state)

    if completion_message then
      debug_log("task " .. task.id .. ": " .. completion_message)
    end
    return
  end

  builder_state.task_index = builder_state.task_index + 1
  builder_state.task_state = nil
  if builder_state.goal_engine then
    builder_state.goal_engine.scaling_display_task = nil
  end
  set_idle(builder_state.entity)
  builder_runtime.clear_task_retry_state(builder_state, task)
  builder_runtime.clear_recovery(builder_state)

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

local world_model_context = {
  builder_data = builder_data,
  build_search_positions = build_search_positions,
  clone_position = clone_position,
  debug_log = debug_log,
  direction_by_name = direction_by_name,
  format_position = format_position,
  get_container_inventory = get_container_inventory,
  get_task_anchor_entity_names = get_task_anchor_entity_names,
  point_in_area = point_in_area,
  rotate_direction_name = rotate_direction_name,
  rotate_offset = rotate_offset,
  select_preferred_candidate = select_preferred_candidate,
  square_distance = square_distance
}

ensure_production_sites = function()
  return world_model.ensure_production_sites(world_model_context)
end

ensure_resource_sites = function()
  return world_model.ensure_resource_sites(world_model_context)
end

get_site_pattern = function(pattern_name)
  return world_model.get_site_pattern(pattern_name, world_model_context)
end

get_resource_site_counts = function()
  return world_model.get_resource_site_counts(world_model_context)
end

cleanup_resource_sites = function()
  return world_model.cleanup_resource_sites(world_model_context)
end

discover_resource_sites = function(builder_state)
  return world_model.discover_resource_sites(builder_state, world_model_context)
end

find_machine_site_near_resource_sites = function(builder_state, task)
  return world_model.find_machine_site_near_resource_sites(builder_state, task, world_model_context)
end

find_layout_site_near_machine = function(builder_state, task)
  return world_model.find_layout_site_near_machine(builder_state, task, world_model_context)
end

register_assembler_defense_site = function(task, assembler, placed_layout_entities)
  return world_model.register_assembler_defense_site(task, assembler, placed_layout_entities, world_model_context)
end

register_resource_site = function(task, miner, downstream_machine, output_container, extras)
  return world_model.register_resource_site(
    task,
    miner,
    downstream_machine,
    output_container,
    extras,
    world_model_context
  )
end

register_smelting_site = function(task, miner, downstream_machine, output_container)
  return world_model.register_smelting_site(task, miner, downstream_machine, output_container, world_model_context)
end

register_steel_smelting_site = function(task, anchor_machine, feed_inserter, downstream_machine, miner)
  return world_model.register_steel_smelting_site(
    task,
    anchor_machine,
    feed_inserter,
    downstream_machine,
    miner,
    world_model_context
  )
end

get_site_collect_inventory = function(site)
  return world_model.get_site_collect_inventory(site, world_model_context)
end

get_site_collect_position = function(site)
  return world_model.get_site_collect_position(site, world_model_context)
end

get_site_allowed_items = function(site)
  return world_model.get_site_allowed_items(site, world_model_context)
end

get_site_collect_count = function(site, item_name)
  return world_model.get_site_collect_count(site, item_name, world_model_context)
end

find_resource_site = function(surface, force, origin, task)
  return world_model.find_resource_site(surface, force, origin, task, world_model_context)
end

find_nearest_resource = function(surface, origin, task)
  return world_model.find_nearest_resource(surface, origin, task, world_model_context)
end

local task_executor_context = {
  builder_runtime = builder_runtime,
  clone_position = clone_position,
  complete_current_task = complete_current_task,
  create_task_approach_position = create_task_approach_position,
  debug_log = debug_log,
  decorative_target_exists = decorative_target_exists,
  destroy_entity_if_valid = destroy_entity_if_valid,
  direction_from_delta = direction_from_delta,
  find_gather_site = find_gather_site,
  find_layout_site_near_machine = find_layout_site_near_machine,
  find_machine_site_near_resource_sites = find_machine_site_near_resource_sites,
  find_nearest_resource = find_nearest_resource,
  find_resource_site = find_resource_site,
  format_position = format_position,
  format_products = format_products,
  get_missing_inventory_target = get_missing_inventory_target,
  get_post_place_pause_ticks = get_post_place_pause_ticks,
  get_task_anchor_entity_names = get_task_anchor_entity_names,
  get_task_consumed_item_name = get_task_consumed_item_name,
  insert_entity_fuel = insert_entity_fuel,
  insert_item = insert_item,
  insert_products = insert_products,
  inventory_targets_summary = inventory_targets_summary,
  point_in_area = point_in_area,
  register_assembler_defense_site = register_assembler_defense_site,
  register_resource_site = register_resource_site,
  register_smelting_site = register_smelting_site,
  register_steel_smelting_site = register_steel_smelting_site,
  remove_item = remove_item,
  set_idle = set_idle,
  square_distance = square_distance
}

local function start_task(builder_state, task, tick)
  task_executor.start_task(builder_state, task, tick, task_executor_context)
end

local function get_scaling_pattern_name(builder_state)
  local scaling = builder_data.scaling
  if not (scaling and scaling.cycle_pattern_names and #scaling.cycle_pattern_names > 0) then
    return nil
  end

  builder_runtime.prune_retry_cooldowns(builder_state, game and game.tick or 0)
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
    local unlocked = not builder_runtime.is_goal_retry_blocked(builder_state, "pattern:" .. pattern_name, game and game.tick or 0)

    if unlock and unlock.minimum_site_counts then
      for dependency_pattern_name, dependency_count in pairs(unlock.minimum_site_counts) do
        if (site_counts[dependency_pattern_name] or 0) < dependency_count then
          unlocked = false
          break
        end
      end
    end

    if unlocked and unlock and unlock.required_completed_milestones then
      ensure_builder_state_fields(builder_state)

      for _, milestone_name in ipairs(unlock.required_completed_milestones) do
        if not builder_state.completed_scaling_milestones[milestone_name] then
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

get_recipe = function(item_name)
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

local function create_scaling_repeatable_milestone_task(milestone)
  local task = create_scaling_milestone_task(milestone)
  if not task then
    return nil
  end

  task.completed_scaling_milestone_name = nil
  task.repeatable_scaling_milestone_name = milestone.name
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

  if task.repeatable_scaling_milestone_name then
    for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
      if milestone.name == task.repeatable_scaling_milestone_name then
        builder_state.scaling_active_task = create_scaling_repeatable_milestone_task(milestone)
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
    if
      not builder_runtime.is_goal_retry_blocked(builder_state, "milestone:" .. milestone.name, game and game.tick or 0) and
      not builder_state.completed_scaling_milestones[milestone.name]
    then
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

  builder_runtime.record_recovery(builder_state, message or ("scaling wait: " .. tostring(wait_reason)))

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

    local producer = builder_data.scaling and builder_data.scaling.collect_ingredient_producers and
      builder_data.scaling.collect_ingredient_producers[action.item_name]
    if producer and producer.pattern_name then
      local site_counts = get_resource_site_counts()
      local current_site_count = site_counts[producer.pattern_name] or 0
      local minimum_site_count = producer.minimum_site_count or 1

      if current_site_count < minimum_site_count then
        local producer_pattern = get_site_pattern(producer.pattern_name)
        if producer_pattern and producer_pattern.required_items and
          plan_scaling_required_items(builder_state, producer_pattern.required_items, tick)
        then
          return true
        end

        local build_task = create_scaling_build_task(producer.pattern_name)
        if build_task then
          start_scaling_subtask(builder_state, build_task, tick)
          return true
        end
      end
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

local function repeatable_scaling_task_has_site(builder_state, task)
  if not task then
    return false
  end

  if task.type == "place-layout-near-machine" then
    local site = find_layout_site_near_machine(builder_state, task)
    return site ~= nil
  end

  if task.type == "place-machine-near-site" then
    local site = find_machine_site_near_resource_sites(builder_state, task)
    return site ~= nil
  end

  return true
end

local function plan_repeatable_scaling_milestones(builder_state, tick)
  ensure_builder_state_fields(builder_state)

  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if milestone.repeat_when_eligible and builder_state.completed_scaling_milestones[milestone.name] then
      if not builder_runtime.is_goal_retry_blocked(builder_state, "repeatable-milestone:" .. milestone.name, tick) then
        local task = create_scaling_repeatable_milestone_task(milestone)
        if task and repeatable_scaling_task_has_site(builder_state, task) then
          if plan_scaling_required_items(builder_state, milestone.required_items, tick) then
            return true
          end

          start_scaling_subtask(builder_state, task, tick)
          return true
        end
      end
    end
  end

  return false
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
    approach_position = create_task_approach_position(nil, collect_position, 1.1),
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

  if plan_repeatable_scaling_milestones(builder_state, tick) then
    return
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
  task_executor.advance_task_phase(builder_state, task, tick, task_executor_context)
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
    local movement_position = task_state.approach_position or destination_position

    if square_distance(entity.position, destination_position) <= (1.1 * 1.1) then
      set_idle(entity)
      task_state.phase = "scaling-collecting-site"
      debug_log("scaling: reached collection site at " .. format_position(destination_position))
      return
    end

    local direction = direction_from_delta(
      movement_position.x - entity.position.x,
      movement_position.y - entity.position.y
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

local goal_engine_adapters = {
  advance_task_phase = advance_task_phase,
  build_runtime_snapshot = builder_runtime.build_runtime_snapshot,
  builder_data = builder_data,
  cleanup_resource_sites = cleanup_resource_sites,
  consume_recipe_ingredients = consume_recipe_ingredients,
  create_task_approach_position = create_task_approach_position,
  debug_log = debug_log,
  direction_from_delta = direction_from_delta,
  discover_resource_sites = discover_resource_sites,
  find_layout_site_near_machine = find_layout_site_near_machine,
  find_machine_site_near_resource_sites = find_machine_site_near_resource_sites,
  format_position = format_position,
  format_products = format_products,
  get_item_count = get_item_count,
  get_recipe = get_recipe,
  get_resource_site_counts = get_resource_site_counts,
  get_scaling_pattern_name = get_scaling_pattern_name,
  get_site_allowed_items = get_site_allowed_items,
  get_site_collect_count = get_site_collect_count,
  get_site_collect_inventory = get_site_collect_inventory,
  get_site_collect_position = get_site_collect_position,
  get_site_pattern = get_site_pattern,
  insert_item = insert_item,
  is_goal_retry_blocked = builder_runtime.is_goal_retry_blocked,
  pull_inventory_contents_to_builder = pull_inventory_contents_to_builder,
  record_recovery = builder_runtime.record_recovery,
  set_idle = set_idle,
  square_distance = square_distance,
  start_task = start_task
}

local function advance_builder(builder_state, tick)
  configure_builder_entity(builder_state.entity)
  process_production_sites(tick)
  maintenance_runner.run(
    builder_state,
    tick,
    {
      {name = "collect-containers", run = collect_nearby_container_items},
      {name = "collect-machine-output", run = collect_nearby_machine_output_items},
      {name = "refuel-machines", run = refuel_nearby_machines},
      {name = "supply-machine-inputs", run = supply_nearby_machine_inputs}
    }
  )
  goal_engine.advance(builder_data, builder_state, tick, goal_engine_adapters)
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

  if get_builder_state() then
    builder_runtime.update_goal_model(get_builder_state(), game.tick)
  end
  builder_runtime.update_builder_overlays(get_builder_state(), game.tick, true)
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

  if get_builder_state() then
    builder_runtime.update_goal_model(get_builder_state(), game.tick)
  end
  builder_runtime.update_builder_overlays(get_builder_state(), game.tick, true)
  update_builder_map_markers(get_builder_state(), game.tick, true)
end

local function on_player_created(event)
  local player = game.get_player(event.player_index)
  if player then
    debug_log("on_player_created: player " .. player.name)
    spawn_builder_for_player(player)
    if get_builder_state() then
      builder_runtime.update_goal_model(get_builder_state(), game.tick)
    end
    builder_runtime.update_builder_overlay_for_player(player, get_builder_state())
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
    builder_runtime.update_goal_model(builder_state, event.tick)
  end

  builder_runtime.update_builder_overlays(builder_state, event.tick, false)
  update_builder_map_markers(builder_state, event.tick, false)
end

function builder_runtime.register_events()
  if commands.commands["enemy-builder-status"] then
    commands.remove_command("enemy-builder-status")
  end
  commands.add_command("enemy-builder-status", "Show the current Enemy Builder state.", builder_runtime.debug_status_command)

  if commands.commands["enemy-builder-goals"] then
    commands.remove_command("enemy-builder-goals")
  end
  commands.add_command("enemy-builder-goals", "Show the current Enemy Builder goal tree.", builder_runtime.goals_command)

  if commands.commands["enemy-builder-debug"] then
    commands.remove_command("enemy-builder-debug")
  end
  commands.add_command("enemy-builder-debug", "Toggle Enemy Builder debug logging. Use on or off.", builder_runtime.debug_toggle_command)

  if commands.commands["enemy-builder-retask"] then
    commands.remove_command("enemy-builder-retask")
  end
  commands.add_command("enemy-builder-retask", "Clear the current Enemy Builder task state and retry.", builder_runtime.debug_retask_command)

  if commands.commands["enemy-builder-plan"] then
    commands.remove_command("enemy-builder-plan")
  end
  commands.add_command("enemy-builder-plan", "Preview a manual Enemy Builder component plan.", builder_runtime.manual_plan_command)

  if commands.commands["enemy-builder-build"] then
    commands.remove_command("enemy-builder-build")
  end
  commands.add_command("enemy-builder-build", "Queue a manual Enemy Builder component build.", builder_runtime.manual_build_command)

  if commands.commands["enemy-builder-cancel-manual"] then
    commands.remove_command("enemy-builder-cancel-manual")
  end
  commands.add_command("enemy-builder-cancel-manual", "Cancel the active manual Enemy Builder goal.", builder_runtime.cancel_manual_command)

  script.on_init(on_init)
  script.on_configuration_changed(on_configuration_changed)
  script.on_event(defines.events.on_player_created, on_player_created)
  script.on_event(defines.events.on_tick, on_tick)
end

return builder_runtime

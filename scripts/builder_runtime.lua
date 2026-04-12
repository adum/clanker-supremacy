local builder_data = require("shared.builder_data")
local goal_recovery = require("scripts.goal.recovery")
local goal_engine = require("scripts.goal_engine")
local goal_tree = require("scripts.goal_tree")
local debug_commands = require("scripts.debug.commands")
local debug_markers = require("scripts.debug.markers")
local debug_overlay = require("scripts.debug.overlay")
local default_maintenance_passes = require("scripts.maintenance.default_passes")
local maintenance_runner = require("scripts.maintenance_runner")
local task_executor = require("scripts.task_executor")
local world_model = require("scripts.world_model")
local world_snapshot = require("scripts.world_snapshot")

local builder_runtime = {}
local debug_prefix = "[enemy-builder] "
local debug_command_context
local debug_marker_context
local debug_overlay_context
local maintenance_pass_context
local maintenance_passes
local get_builder_state
local get_active_task
local get_item_count
local get_recipe
local get_builder_main_inventory
local ensure_production_sites
local ensure_resource_sites
local get_site_pattern
local get_resource_site_counts
local get_site_collect_inventory
local get_site_collect_position
local get_site_allowed_items
local get_site_collect_count
local pull_inventory_contents_to_builder
local find_layout_site_near_machine
local find_output_belt_line_site
local find_machine_site_near_resource_sites
local find_resource_site
local find_nearest_resource
local register_assembler_defense_site
local register_output_belt_site
local register_resource_site
local register_smelting_site
local register_steel_smelting_site
local cleanup_resource_sites
local discover_resource_sites
local set_idle
local configure_builder_entity

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

local function ensure_builder_map_markers()
  return debug_markers.ensure_storage()
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

local function get_test_state()
  return storage.enemy_builder_test
end

local function autospawn_suppressed_for_test()
  local test_state = get_test_state()
  return test_state and test_state.suppress_player_autospawn == true
end

local function forbid_direct_turret_ammo_transfer()
  local test_state = get_test_state()
  return test_state and test_state.forbid_direct_turret_ammo_transfer == true
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

  if builder_state.goal_blockers == nil then
    builder_state.goal_blockers = {}
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

  if builder_state.blocked_layout_anchors == nil then
    builder_state.blocked_layout_anchors = {}
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

  force.reset_technology_effects()

  for _, recipe_name in ipairs((builder_data.force and builder_data.force.enabled_recipes) or {}) do
    enable_force_recipe_if_available(force, recipe_name)
  end

  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if milestone.task and milestone.task.recipe_name then
      enable_force_recipe_if_available(force, milestone.task.recipe_name)
    end
  end
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

get_active_task = function(builder_state)
  return goal_engine.get_active_task(builder_data, builder_state)
end

function builder_runtime.get_display_task(builder_state)
  return goal_engine.get_display_task(builder_data, builder_state)
end

function builder_runtime.record_recovery(builder_state, message)
  return goal_recovery.record(builder_state, message)
end

function builder_runtime.clear_recovery(builder_state)
  goal_recovery.clear(builder_state)
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

local function get_layout_anchor_block_group(task)
  if task and task.require_missing_registered_site and task.require_missing_registered_site.site_type then
    return task.require_missing_registered_site.site_type
  end

  return task and (task.id or task.type) or "layout"
end

local function get_layout_anchor_block_key(anchor_entity)
  if not (anchor_entity and anchor_entity.valid) then
    return nil
  end

  if anchor_entity.unit_number then
    return tostring(anchor_entity.unit_number)
  end

  return string.format("%.2f:%.2f:%s", anchor_entity.position.x, anchor_entity.position.y, anchor_entity.name)
end

local function mark_layout_anchor_blocked(builder_state, task, anchor_entity)
  ensure_builder_state_fields(builder_state)

  local block_group = get_layout_anchor_block_group(task)
  local block_key = get_layout_anchor_block_key(anchor_entity)
  if not block_key then
    return false
  end

  if builder_state.blocked_layout_anchors[block_group] == nil then
    builder_state.blocked_layout_anchors[block_group] = {}
  end

  builder_state.blocked_layout_anchors[block_group][block_key] = true
  return true
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

  if task and task.type == "place-layout-near-machine" and task.completed_scaling_milestone_name == "firearm-magazine-defense" then
    local failed_anchor_entity = builder_state and builder_state.task_state and builder_state.task_state.failed_layout_anchor_entity or nil
    if failed_anchor_entity and failed_anchor_entity.valid then
      local blocked = mark_layout_anchor_blocked(builder_state, task, failed_anchor_entity)
      builder_state.completed_scaling_milestones["firearm-magazine-assembler"] = nil
      builder_state.scaling_active_task = nil
      builder_state.task_state = nil
      if builder_state.goal_engine then
        builder_state.goal_engine.scaling_display_task = nil
      end
      set_idle(builder_state.entity)
      builder_runtime.record_recovery(
        builder_state,
        "abandoned firearm magazine defense at " .. format_position(failed_anchor_entity.position) ..
          "; assembler site blocked for defense and assembler milestone reopened"
      )
      debug_log(
        "task " .. task_name .. ": " .. message ..
        "; " .. (blocked and "blocked" or "could not block") ..
        " assembler at " .. format_position(failed_anchor_entity.position) ..
        " and reopened firearm-magazine-assembler milestone"
      )
      return
    end
  end

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

set_idle = function(entity)
  if entity and entity.valid then
    entity.walking_state = {walking = false}
  end
end

configure_builder_entity = function(entity)
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

local function get_basic_world_item_source(source_id)
  local basic_materials = builder_data.world_item_sources and builder_data.world_item_sources.basic_materials or nil
  local sources = basic_materials and basic_materials.sources or nil
  if not sources then
    return nil
  end

  for _, source in ipairs(sources) do
    if source.id == source_id then
      return source
    end
  end

  return nil
end

local function build_entity_placement_area(entity_name, position)
  local prototype = prototypes and prototypes.entity and prototypes.entity[entity_name] or nil
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

local function expand_area(area, padding)
  return {
    left_top = {
      x = area.left_top.x - padding,
      y = area.left_top.y - padding
    },
    right_bottom = {
      x = area.right_bottom.x + padding,
      y = area.right_bottom.y + padding
    }
  }
end

local function find_clearable_build_obstacle(surface, entity_name, position)
  if not (surface and entity_name and position) then
    return nil
  end

  local search_area = expand_area(build_entity_placement_area(entity_name, position), 0.05)
  local candidates = {}
  local tree_source = get_basic_world_item_source("trees")
  local rock_source = get_basic_world_item_source("rocks")
  local default_mining_duration =
    builder_data.world_item_sources and
    builder_data.world_item_sources.basic_materials and
    builder_data.world_item_sources.basic_materials.mining_duration_ticks or 45

  for _, obstacle_entity in ipairs(surface.find_entities_filtered{area = search_area, type = "tree"}) do
    if obstacle_entity.valid then
      candidates[#candidates + 1] = {
        source_id = tree_source and tree_source.id or "trees",
        display_name = "tree",
        target_kind = "entity",
        target_name = obstacle_entity.name,
        target_position = clone_position(obstacle_entity.position),
        entity = obstacle_entity,
        yields = deep_copy(tree_source and tree_source.yields or {}),
        mining_duration_ticks = (tree_source and tree_source.mining_duration_ticks) or default_mining_duration
      }
    end
  end

  local decorative_names = rock_source and get_valid_source_names(rock_source, "decorative_names", "decorative") or nil
  if decorative_names and #decorative_names > 0 then
    for _, decorative in ipairs(surface.find_decoratives_filtered{
      area = {
        {search_area.left_top.x, search_area.left_top.y},
        {search_area.right_bottom.x, search_area.right_bottom.y}
      },
      name = decorative_names
    }) do
      candidates[#candidates + 1] = {
        source_id = rock_source and rock_source.id or "rocks",
        display_name = "rock",
        target_kind = "decorative",
        target_name = decorative.decorative.name,
        target_position = tile_position_to_world_center(decorative.position),
        decorative_position = clone_position(decorative.position),
        yields = deep_copy(rock_source and rock_source.yields or {}),
        mining_duration_ticks = (rock_source and rock_source.mining_duration_ticks) or default_mining_duration
      }
    end
  end

  if #candidates == 0 then
    return nil
  end

  table.sort(candidates, function(left, right)
    return square_distance(position, left.target_position) < square_distance(position, right.target_position)
  end)

  return candidates[1]
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

local function transfer_inventory_contents(source_inventory, destination, debug_reason, allowed_item_names)
  if not (source_inventory and destination) or source_inventory.is_empty() then
    return {}
  end

  local moved_items = {}

  for _, item_stack in ipairs(get_sorted_item_stacks(source_inventory.get_contents())) do
    if item_stack.count and item_stack.count > 0 and (not allowed_item_names or allowed_item_names[item_stack.name]) then
      if forbid_direct_turret_ammo_transfer() and item_stack.name == "firearm-magazine" and debug_reason and string.find(string.lower(debug_reason), "turret", 1, true) then
        error("enemy-builder test: scripted firearm-magazine transfer into turret path is forbidden: " .. debug_reason)
      end

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

  if forbid_direct_turret_ammo_transfer() and item_name == "firearm-magazine" and debug_reason and string.find(string.lower(debug_reason), "turret", 1, true) then
    error("enemy-builder test: scripted firearm-magazine transfer into turret path is forbidden: " .. debug_reason)
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

function builder_runtime.update_builder_overlay_for_player(player, builder_state)
  debug_overlay.update_for_player(player, builder_state, game and game.tick or 0, debug_overlay_context)
end

function builder_runtime.update_builder_overlays(builder_state, tick, force_update)
  debug_overlay.update_all(builder_state, tick, force_update, debug_overlay_context)
end

local function update_builder_map_markers(builder_state, tick, force_update)
  debug_markers.update(builder_state, tick, force_update, debug_marker_context)
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

local function find_spawn_position_on_surface(surface, target, fallback)
  if not (surface and target) then
    return nil
  end

  local prototype_name = builder_data.avatar.prototype_name
  return surface.find_non_colliding_position(
    prototype_name,
    target,
    builder_data.avatar.spawn_search_radius,
    builder_data.avatar.spawn_precision
  ) or (fallback and surface.find_non_colliding_position(
    prototype_name,
    fallback,
    builder_data.avatar.spawn_search_radius,
    builder_data.avatar.spawn_precision
  )) or clone_position(target)
end

local function initialize_builder_state(entity)
  configure_builder_entity(entity)

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

local function destroy_active_builder()
  local builder_state = storage.builder_state
  if builder_state and builder_state.entity and builder_state.entity.valid then
    builder_state.entity.destroy()
  end

  storage.builder_state = nil
end

local function spawn_builder_at_position(surface, requested_position, debug_context, fallback_position)
  if get_builder_state() then
    debug_log("spawn skipped because the builder already exists")
    return get_builder_state()
  end

  if not (surface and requested_position) then
    debug_log("spawn skipped because no valid surface or position was provided")
    return nil
  end

  local spawn_position = find_spawn_position_on_surface(surface, requested_position, fallback_position)
  if not spawn_position then
    debug_log("spawn failed because no non-colliding position was found near " .. format_position(requested_position))
    return nil
  end

  local force = ensure_builder_force()
  local entity = surface.create_entity{
    name = builder_data.avatar.prototype_name,
    position = spawn_position,
    force = force,
    create_build_effect_smoke = false
  }

  if not entity then
    debug_log("spawn failed because the builder entity could not be created at " .. format_position(spawn_position))
    return nil
  end

  local builder_state = initialize_builder_state(entity)
  debug_log("spawned builder at " .. format_position(entity.position) .. (debug_context and (" " .. debug_context) or ""))
  return builder_state
end

local function spawn_builder_for_player(player)
  if not (player and player.valid and player.character and player.character.valid) then
    debug_log("spawn skipped because no valid player character is available")
    return nil
  end

  local spawn_position = find_spawn_position(player)
  return spawn_builder_at_position(
    player.surface,
    spawn_position,
    "near player " .. player.name .. " at " .. format_position(player.character.position),
    player.character.position
  )
end

local function normalize_test_inventory(inventory)
  local stacks = {}

  if type(inventory) ~= "table" then
    return stacks
  end

  if inventory[1] ~= nil then
    for _, stack in ipairs(inventory) do
      if stack and stack.name and stack.count and stack.count > 0 then
        stacks[#stacks + 1] = {
          name = stack.name,
          count = stack.count
        }
      end
    end
  else
    for item_name, count in pairs(inventory) do
      if count and count > 0 then
        stacks[#stacks + 1] = {
          name = item_name,
          count = count
        }
      end
    end
  end

  table.sort(stacks, function(left, right)
    return left.name < right.name
  end)

  return stacks
end

local function get_test_surface(spec)
  if spec and spec.surface_name and game.surfaces[spec.surface_name] then
    return game.surfaces[spec.surface_name]
  end

  if spec and spec.surface_index and game.surfaces[spec.surface_index] then
    return game.surfaces[spec.surface_index]
  end

  return game.surfaces["nauvis"] or game.surfaces[1]
end

local function sanitize_test_file_name(name)
  return string.gsub(name or "manual-test", "[^%w%-_]+", "_")
end

local function make_test_area(center, half_width, half_height)
  return {
    left_top = {
      x = center.x - half_width,
      y = center.y - half_height
    },
    right_bottom = {
      x = center.x + half_width,
      y = center.y + half_height
    }
  }
end

local function build_test_area_tiles(area, tile_name)
  local tiles = {}

  for x = math.floor(area.left_top.x), math.ceil(area.right_bottom.x) do
    for y = math.floor(area.left_top.y), math.ceil(area.right_bottom.y) do
      tiles[#tiles + 1] = {
        name = tile_name or "grass-1",
        position = {x = x, y = y}
      }
    end
  end

  return tiles
end

local function clear_test_area(surface, area)
  surface.request_to_generate_chunks({
    x = (area.left_top.x + area.right_bottom.x) * 0.5,
    y = (area.left_top.y + area.right_bottom.y) * 0.5
  }, 3)
  surface.force_generate_chunk_requests()
  surface.set_tiles(build_test_area_tiles(area, "grass-1"), true)

  for _, entity in ipairs(surface.find_entities_filtered{area = area}) do
    if entity.valid and entity.name ~= "character" and entity.type ~= "player-port" then
      entity.destroy()
    end
  end

  surface.destroy_decoratives{area = area}
end

local function create_test_resource_patch(surface, resource_name, center, radius, amount)
  local resources_created = 0

  for dx = -radius, radius do
    for dy = -radius, radius do
      if (dx * dx) + (dy * dy) <= (radius * radius) then
        local entity = surface.create_entity{
          name = resource_name,
          position = {
            x = center.x + dx + 0.5,
            y = center.y + dy + 0.5
          },
          amount = amount
        }

        if entity and entity.valid then
          resources_created = resources_created + 1
        end
      end
    end
  end

  return resources_created
end

local function get_orientation_miner_offset(layout_orientation)
  if layout_orientation == "east" then
    return {x = 0, y = -2}
  end

  if layout_orientation == "south" then
    return {x = 2, y = 0}
  end

  if layout_orientation == "west" then
    return {x = 0, y = 2}
  end

  return {x = -2, y = 0}
end

local function place_test_iron_smelting_anchor(surface, layout_orientation, anchor_position)
  local miner_offset = get_orientation_miner_offset(layout_orientation)
  local miner_position = {
    x = anchor_position.x + miner_offset.x,
    y = anchor_position.y + miner_offset.y
  }

  create_test_resource_patch(surface, "iron-ore", miner_position, 1, 5000)

  local force = ensure_builder_force()
  local anchor_furnace = surface.create_entity{
    name = "stone-furnace",
    position = anchor_position,
    force = force,
    create_build_effect_smoke = false
  }

  if not (anchor_furnace and anchor_furnace.valid) then
    error("enemy-builder test: failed to create anchor furnace for steel layout " .. layout_orientation)
  end

  local miner_directions = {
    {"north", direction_by_name.north},
    {"east", direction_by_name.east},
    {"south", direction_by_name.south},
    {"west", direction_by_name.west}
  }

  local miner = nil
  for _, direction_entry in ipairs(miner_directions) do
    local candidate = surface.create_entity{
      name = "burner-mining-drill",
      position = miner_position,
      direction = direction_entry[2],
      force = force,
      create_build_effect_smoke = false
    }

    if candidate and candidate.valid then
      local covered_resources = surface.find_entities_filtered{
        area = candidate.mining_area,
        type = "resource",
        name = "iron-ore"
      }
      local feeds_anchor_furnace = false
      local ok, drop_target = pcall(function()
        return candidate.drop_target
      end)

      if ok and drop_target and drop_target.valid then
        feeds_anchor_furnace = drop_target == anchor_furnace
      else
        feeds_anchor_furnace = point_in_area(candidate.drop_position, anchor_furnace.selection_box)
      end

      if feeds_anchor_furnace and #covered_resources > 0 then
        miner = candidate
        break
      end

      candidate.destroy()
    end
  end

  if not (miner and miner.valid) then
    anchor_furnace.destroy()
    error("enemy-builder test: failed to create anchor miner for steel layout " .. layout_orientation)
  end

  insert_entity_fuel(miner, {name = "coal", count = 8})
  insert_entity_fuel(anchor_furnace, {name = "coal", count = 8})

  local iron_task = builder_data.site_patterns and builder_data.site_patterns.iron_smelting and
    builder_data.site_patterns.iron_smelting.build_task or nil
  if not iron_task then
    miner.destroy()
    anchor_furnace.destroy()
    error("enemy-builder test: missing iron_smelting build task")
  end

  register_smelting_site(iron_task, miner, anchor_furnace, nil)
  register_resource_site(iron_task, miner, anchor_furnace, nil)

  return {
    miner = miner,
    anchor_furnace = anchor_furnace,
    miner_position = miner_position
  }
end

local function place_test_runtime_iron_smelting_site(surface, origin_position)
  local force = ensure_builder_force()
  local iron_task = builder_data.site_patterns and builder_data.site_patterns.iron_smelting and
    builder_data.site_patterns.iron_smelting.build_task or nil
  if not iron_task then
    error("enemy-builder test: missing iron_smelting build task")
  end

  local site = find_resource_site(surface, force, origin_position, iron_task)
  if not site then
    error("enemy-builder test: failed to find runtime iron smelting site near " .. format_position(origin_position))
  end

  local miner = surface.create_entity{
    name = iron_task.miner_name,
    position = site.build_position,
    direction = site.build_direction,
    force = force,
    create_build_effect_smoke = false
  }

  if not (miner and miner.valid) then
    error("enemy-builder test: failed to create runtime iron miner")
  end

  local furnace = surface.create_entity{
    name = iron_task.downstream_machine.name,
    position = site.downstream_machine_position,
    force = force,
    create_build_effect_smoke = false
  }

  if not (furnace and furnace.valid) then
    miner.destroy()
    error("enemy-builder test: failed to create runtime iron furnace")
  end

  insert_entity_fuel(miner, iron_task.fuel)
  insert_entity_fuel(furnace, iron_task.downstream_machine.fuel)

  register_smelting_site(iron_task, miner, furnace, nil)
  register_resource_site(iron_task, miner, furnace, nil)

  return {
    miner = miner,
    anchor_furnace = furnace,
    miner_position = miner.position
  }
end

local function setup_manual_test(spec)
  spec = spec or {}

  ensure_debug_settings()
  ensure_production_sites()
  ensure_resource_sites()
  ensure_builder_map_markers()
  ensure_builder_force()

  storage.enemy_builder_test = {
    case_name = spec.case_name or "manual-test",
    suppress_player_autospawn = spec.suppress_player_autospawn ~= false,
    forbid_direct_turret_ammo_transfer = spec.forbid_direct_turret_ammo_transfer == true,
    disable_nearby_machine_output_collection = spec.disable_nearby_machine_output_collection == true
  }

  if spec.assertion then
    storage.enemy_builder_test.assertion = deep_copy(spec.assertion)
    storage.enemy_builder_test.assertion.case_name =
      storage.enemy_builder_test.assertion.case_name or storage.enemy_builder_test.case_name
    storage.enemy_builder_test.assertion.surface_name =
      storage.enemy_builder_test.assertion.surface_name or spec.surface_name
    storage.enemy_builder_test.assertion.surface_index =
      storage.enemy_builder_test.assertion.surface_index or spec.surface_index
    storage.enemy_builder_test.assertion.deadline_tick =
      game.tick + (storage.enemy_builder_test.assertion.deadline_offset_ticks or 0)
    storage.enemy_builder_test.assertion.result_file =
      storage.enemy_builder_test.assertion.result_file or
      ("enemy-builder-tests/" .. sanitize_test_file_name(storage.enemy_builder_test.assertion.case_name) .. ".status")
  end

  debug_markers.clear()
  destroy_active_builder()
  storage.production_sites = {}
  storage.resource_sites = {}

  local surface = get_test_surface(spec)
  if not surface then
    error("enemy-builder test: no valid surface available for setup")
  end

  local builder_position = clone_position(spec.builder_position or {x = 0, y = 0})
  local builder_state = spawn_builder_at_position(
    surface,
    builder_position,
    "for test " .. storage.enemy_builder_test.case_name
  )

  if not builder_state then
    error("enemy-builder test: failed to spawn builder for test setup")
  end

  builder_state.task_state = nil
  builder_state.scaling_active_task = nil
  local bootstrap_tasks = (((builder_data.plans or {}).bootstrap or {}).tasks) or {}
  builder_state.task_index = #bootstrap_tasks + 1
  builder_state.task_retry_state = {
    counts = {},
    cooldowns = {}
  }
  builder_state.completed_scaling_milestones = deep_copy(spec.completed_scaling_milestones or {})

  for _, stack in ipairs(normalize_test_inventory(spec.inventory)) do
    local inserted_count = insert_item(builder_state.entity, stack.name, stack.count, "test setup inventory")
    if inserted_count < stack.count then
      error(
        "enemy-builder test: failed to seed " .. stack.name ..
        " x" .. stack.count .. "; inserted " .. inserted_count
      )
    end
  end

  local request, request_error = goal_tree.instantiate_manual_request(
    builder_data,
    spec.component_name or "firearm_magazine_site",
    spec.target_position and clone_position(spec.target_position) or nil
  )

  if request_error then
    error("enemy-builder test: " .. request_error)
  end

  if spec.mutate_request then
    spec.mutate_request(request)
  end

  builder_state.manual_goal_request = request
  if builder_state.goal_engine then
    builder_state.goal_engine.scaling_display_task = nil
  end
  set_idle(builder_state.entity)
  builder_runtime.clear_recovery(builder_state)
  builder_runtime.update_goal_model(builder_state, game.tick)
  builder_runtime.update_builder_overlays(builder_state, game.tick, true)
  update_builder_map_markers(builder_state, game.tick, true)
  debug_log(
    "test setup " .. storage.enemy_builder_test.case_name ..
    ": queued manual goal " .. request.display_name ..
    (spec.target_position and (" at " .. format_position(spec.target_position)) or "")
  )

  return {
    builder_position = clone_position(builder_state.entity.position),
    target_position = spec.target_position and clone_position(spec.target_position) or nil,
    manual_goal_id = request.id
  }
end

local function setup_firearm_outpost_test_case()
  local surface = game.surfaces["nauvis"] or game.surfaces[1]
  if not surface then
    error("enemy-builder test: nauvis surface is unavailable")
  end

  local target_position = {x = 32, y = 0}
  local builder_position = {x = 0, y = 0}
  local area = make_test_area(target_position, 40, 24)

  surface.always_day = true
  clear_test_area(surface, area)

  return setup_manual_test{
    case_name = "firearm_outpost_physical_feed",
    component_name = "firearm_magazine_site",
    builder_position = builder_position,
    target_position = target_position,
    surface_name = surface.name,
    suppress_player_autospawn = true,
    forbid_direct_turret_ammo_transfer = true,
    inventory = {
      {name = "coal", count = 20},
      {name = "copper-plate", count = 250},
      {name = "iron-plate", count = 400},
      {name = "steel-plate", count = 30},
      {name = "wood", count = 20}
    },
    assertion = {
      case_name = "firearm_outpost_physical_feed",
      surface_name = surface.name,
      area = area,
      deadline_offset_ticks = 3600,
      primary_entity_name = builder_data.prototypes.firearm_magazine_assembler_name,
      required_recipe_name = "firearm-magazine",
      turret_ammo_item_name = "firearm-magazine",
      minimum_turret_ammo_count = 1,
      expected_counts = {
        [builder_data.prototypes.firearm_magazine_assembler_name] = 1,
        ["gun-turret"] = 2,
        ["burner-inserter"] = 2,
        ["small-electric-pole"] = 4,
        ["solar-panel"] = 4
      }
    }
  }
end

local function setup_firearm_outpost_anchored_test_case()
  local surface = game.surfaces["nauvis"] or game.surfaces[1]
  if not surface then
    error("enemy-builder test: nauvis surface is unavailable")
  end

  local anchor_position = {x = 32, y = 0}
  local builder_position = {x = 0, y = 0}
  local area = make_test_area(anchor_position, 56, 40)

  surface.always_day = true
  clear_test_area(surface, area)
  local anchor_site = place_test_iron_smelting_anchor(surface, "north", anchor_position)

  return setup_manual_test{
    case_name = "firearm_outpost_anchor_clearance",
    component_name = "firearm_magazine_site",
    builder_position = builder_position,
    surface_name = surface.name,
    suppress_player_autospawn = true,
    forbid_direct_turret_ammo_transfer = true,
    inventory = {
      {name = "coal", count = 20},
      {name = "copper-plate", count = 250},
      {name = "iron-plate", count = 400},
      {name = "steel-plate", count = 30},
      {name = "wood", count = 20}
    },
    assertion = {
      case_name = "firearm_outpost_anchor_clearance",
      surface_name = surface.name,
      area = area,
      deadline_offset_ticks = 5400,
      primary_entity_name = builder_data.prototypes.firearm_magazine_assembler_name,
      required_recipe_name = "firearm-magazine",
      turret_ammo_item_name = "firearm-magazine",
      minimum_turret_ammo_count = 1,
      minimum_primary_distance_from_position = {
        position = anchor_site.miner_position,
        distance = 10
      },
      expected_counts = {
        [builder_data.prototypes.firearm_magazine_assembler_name] = 1,
        ["gun-turret"] = 2,
        ["burner-inserter"] = 2,
        ["small-electric-pole"] = 4,
        ["solar-panel"] = 4
      }
    }
  }
end

local function setup_tree_blocked_assembler_test_case()
  local surface = game.surfaces["nauvis"] or game.surfaces[1]
  if not surface then
    error("enemy-builder test: nauvis surface is unavailable")
  end

  local target_position = {x = 32, y = 0}
  local builder_position = {x = 0, y = 0}
  local area = make_test_area(target_position, 12, 12)

  surface.always_day = true
  clear_test_area(surface, area)

  local tree = surface.create_entity{
    name = "tree-08",
    position = {x = target_position.x + 0.5, y = target_position.y + 0.5}
  }

  if not (tree and tree.valid) then
    error("enemy-builder test: failed to place blocking tree at manual build target")
  end

  return setup_manual_test{
    case_name = "tree_blocked_machine_placement",
    component_name = "firearm-magazine-assembler",
    builder_position = builder_position,
    target_position = target_position,
    surface_name = surface.name,
    suppress_player_autospawn = true,
    inventory = {
      {name = "assembling-machine-1", count = 1},
      {name = "iron-plate", count = 40}
    },
    assertion = {
      case_name = "tree_blocked_machine_placement",
      surface_name = surface.name,
      area = area,
      deadline_offset_ticks = 1800,
      skip_output_assertion = true,
      primary_entity_name = builder_data.prototypes.firearm_magazine_assembler_name,
      required_recipe_name = "firearm-magazine",
      expected_counts = {
        [builder_data.prototypes.firearm_magazine_assembler_name] = 1
      },
      maximum_counts = {
        ["tree-08"] = 0
      }
    }
  }
end

local function setup_steel_smelting_test_case(layout_orientation)
  local surface = game.surfaces["nauvis"] or game.surfaces[1]
  if not surface then
    error("enemy-builder test: nauvis surface is unavailable")
  end

  local allowed_orientations = {
    north = true,
    east = true,
    south = true,
    west = true
  }
  layout_orientation = layout_orientation or "north"
  if not allowed_orientations[layout_orientation] then
    error("enemy-builder test: unsupported steel layout orientation '" .. tostring(layout_orientation) .. "'")
  end

  local target_position = {x = 32, y = 0}
  local builder_position = {x = 0, y = 0}
  local area = make_test_area(target_position, 40, 24)

  surface.always_day = true
  clear_test_area(surface, area)
  place_test_iron_smelting_anchor(surface, layout_orientation, target_position)

  return setup_manual_test{
    case_name = "steel_smelting_physical_feed_" .. layout_orientation,
    component_name = "steel_smelting",
    builder_position = builder_position,
    target_position = target_position,
    surface_name = surface.name,
    suppress_player_autospawn = true,
    mutate_request = function(request)
      local steel_task = request.tasks and request.tasks[1]
      if steel_task then
        steel_task.layout_orientations = {layout_orientation}
        steel_task.manual_anchor_position = clone_position(target_position)
        steel_task.manual_anchor_search_radius = 3
      end
    end,
    inventory = {
      {name = "burner-inserter", count = 1},
      {name = "coal", count = 80},
      {name = "stone-furnace", count = 1}
    },
    assertion = {
      case_name = "steel_smelting_physical_feed_" .. layout_orientation,
      surface_name = surface.name,
      area = area,
      deadline_offset_ticks = 5400,
      steel_layout_orientation = layout_orientation,
      require_valid_steel_chain_geometry = true,
      output_entity_names = {"stone-furnace"},
      output_item_name = "steel-plate",
      minimum_output_item_count = 1,
      expected_counts = {
        ["burner-inserter"] = 1,
        ["burner-mining-drill"] = 1,
        ["stone-furnace"] = 2
      }
    }
  }
end

local function setup_iron_plate_belt_export_test_case()
  local surface = game.surfaces["nauvis"] or game.surfaces[1]
  if not surface then
    error("enemy-builder test: nauvis surface is unavailable")
  end

  local anchor_position = {x = 32, y = 0}
  local builder_position = {x = 0, y = 0}
  local area = make_test_area(anchor_position, 80, 56)

  surface.always_day = true
  clear_test_area(surface, area)
  local anchor_site = place_test_iron_smelting_anchor(surface, "north", anchor_position)

  return setup_manual_test{
    case_name = "iron_plate_belt_export_physical_feed",
    component_name = "iron_plate_belt_export",
    builder_position = builder_position,
    surface_name = surface.name,
    suppress_player_autospawn = true,
    disable_nearby_machine_output_collection = true,
    mutate_request = function(request)
      local export_task = request.tasks and request.tasks[1]
      if export_task then
        export_task.manual_anchor_position = clone_position(anchor_site.anchor_furnace.position)
        export_task.max_anchor_entities = 4
      end
    end,
    inventory = {
      {name = "burner-inserter", count = 1},
      {name = "transport-belt", count = 48},
      {name = "coal", count = 40}
    },
    assertion = {
      case_name = "iron_plate_belt_export_physical_feed",
      surface_name = surface.name,
      area = area,
      deadline_offset_ticks = 5400,
      seed_source_item_after_layout = {
        item_name = "iron-ore",
        count = 8
      },
      expected_counts = {
        ["burner-inserter"] = 1,
        ["transport-belt"] = 1,
        ["burner-mining-drill"] = 1,
        ["stone-furnace"] = 1
      },
      belt_item_name = "iron-plate",
      minimum_belt_item_count = 1
    }
  }
end

local function finish_manual_test()
  if storage.enemy_builder_test then
    storage.enemy_builder_test.finished = true
  end

  debug_markers.clear()
  destroy_active_builder()
  storage.production_sites = {}
  storage.resource_sites = {}
  builder_runtime.update_builder_overlays(nil, game.tick, true)
  update_builder_map_markers(nil, game.tick, true)
end

local function clear_test_state()
  finish_manual_test()
  storage.enemy_builder_test = nil
end

local function count_test_entities(surface, force, area, entity_name)
  return #surface.find_entities_filtered{
    area = area,
    force = force,
    name = entity_name
  }
end

local function get_primary_test_assembler(surface, force, area, entity_name)
  return surface.find_entities_filtered{
    area = area,
    force = force,
    name = entity_name,
    limit = 1
  }[1]
end

local function get_test_turret_ammo_count(surface, force, area, item_name)
  local ammo_count = 0

  for _, turret in ipairs(surface.find_entities_filtered{
    area = area,
    force = force,
    name = "gun-turret"
  }) do
    local ammo_inventory = turret.get_inventory(defines.inventory.turret_ammo)
    if ammo_inventory then
      ammo_count = ammo_count + ammo_inventory.get_item_count(item_name)
    end
  end

  return ammo_count
end

local function get_test_output_item_count(surface, force, area, entity_names, item_name)
  local total_count = 0

  for _, entity in ipairs(surface.find_entities_filtered{
    area = area,
    force = force,
    name = entity_names
  }) do
    local output_inventory = entity.get_output_inventory and entity.get_output_inventory()
    if output_inventory then
      total_count = total_count + output_inventory.get_item_count(item_name)
    end
  end

  return total_count
end

local function get_test_belt_item_count(surface, force, area, item_name)
  local total_count = 0

  for _, belt in ipairs(surface.find_entities_filtered{
    area = area,
    force = force,
    name = "transport-belt"
  }) do
    local max_line_index = belt.get_max_transport_line_index and belt.get_max_transport_line_index() or 0
    for line_index = 1, max_line_index do
      local line = belt.get_transport_line and belt.get_transport_line(line_index) or nil
      if line then
        for key, value in pairs(line.get_contents()) do
          if key == item_name and type(value) == "number" then
            total_count = total_count + value
          elseif type(value) == "table" and value.name == item_name then
            total_count = total_count + (value.count or 0)
          end
        end
      end
    end
  end

  return total_count
end

local function find_test_resource_site_in_area(pattern_name, area)
  for _, site in ipairs(storage.resource_sites or {}) do
    if site.pattern_name == pattern_name and
      site.miner and site.miner.valid and
      point_in_area(site.miner.position, area)
    then
      return site
    end
  end

  return nil
end

local function entity_contains_point(entity, point)
  return entity and entity.valid and point and point_in_area(point, entity.selection_box)
end

local function steel_chain_geometry_passed(assertion)
  local site = find_test_resource_site_in_area("steel_smelting", assertion.area)
  if not site then
    return false
  end

  local anchor_furnace = site.anchor_machine
  local feed_inserter = site.feed_inserter
  local steel_furnace = site.downstream_machine

  if not (anchor_furnace and anchor_furnace.valid and feed_inserter and feed_inserter.valid and steel_furnace and steel_furnace.valid) then
    return false
  end

  if not entity_contains_point(anchor_furnace, feed_inserter.pickup_position) then
    return false
  end

  if not entity_contains_point(steel_furnace, feed_inserter.drop_position) then
    return false
  end

  return true
end

local function get_test_entity_debug_details(surface, force, area)
  local details = {}

  for _, inserter in ipairs(surface.find_entities_filtered{
    area = area,
    force = force,
    name = "burner-inserter"
  }) do
    local held_name = nil
    local held_count = 0
    if inserter.held_stack and inserter.held_stack.valid_for_read then
      held_name = inserter.held_stack.name
      held_count = inserter.held_stack.count
    end

    details[#details + 1] = string.format(
      "inserter(pos=%s dir=%s pickup=%s drop=%s held=%s:%d energy=%.3f)",
      format_position(inserter.position),
      tostring(inserter.direction),
      format_position(inserter.pickup_position),
      format_position(inserter.drop_position),
      tostring(held_name or "nil"),
      held_count,
      inserter.energy or 0
    )
  end

  for _, turret in ipairs(surface.find_entities_filtered{
    area = area,
    force = force,
    name = "gun-turret"
  }) do
    local ammo_inventory = turret.get_inventory(defines.inventory.turret_ammo)
    local ammo_count = ammo_inventory and ammo_inventory.get_contents()["firearm-magazine"] or 0
    details[#details + 1] = string.format(
      "turret(pos=%s dir=%s ammo=%d)",
      format_position(turret.position),
      tostring(turret.direction),
      ammo_count or 0
    )
  end

  for _, furnace in ipairs(surface.find_entities_filtered{
    area = area,
    force = force,
    name = "stone-furnace"
  }) do
    local source_inventory = furnace.get_inventory(defines.inventory.furnace_source)
    local result_inventory = furnace.get_inventory(defines.inventory.furnace_result)
    details[#details + 1] = string.format(
      "furnace(pos=%s dir=%s source_iron=%d result_iron=%d result_steel=%d energy=%.3f)",
      format_position(furnace.position),
      tostring(furnace.direction),
      source_inventory and source_inventory.get_item_count("iron-ore") or 0,
      result_inventory and result_inventory.get_item_count("iron-plate") or 0,
      result_inventory and result_inventory.get_item_count("steel-plate") or 0,
      furnace.energy or 0
    )
  end

  local steel_site = find_test_resource_site_in_area("steel_smelting", area)
  if steel_site and steel_site.anchor_machine and steel_site.anchor_machine.valid and
    steel_site.feed_inserter and steel_site.feed_inserter.valid and
    steel_site.downstream_machine and steel_site.downstream_machine.valid
  then
    details[#details + 1] = string.format(
      "steel-site(anchor=%s inserter=%s pickup=%s drop=%s steel=%s)",
      format_position(steel_site.anchor_machine.position),
      format_position(steel_site.feed_inserter.position),
      format_position(steel_site.feed_inserter.pickup_position),
      format_position(steel_site.feed_inserter.drop_position),
      format_position(steel_site.downstream_machine.position)
    )
  end

  for _, miner in ipairs(surface.find_entities_filtered{
    area = area,
    force = force,
    name = "burner-mining-drill"
  }) do
    local output_inventory = miner.get_output_inventory and miner.get_output_inventory()
    details[#details + 1] = string.format(
      "miner(pos=%s dir=%s drop=%s output_iron=%d energy=%.3f)",
      format_position(miner.position),
      tostring(miner.direction),
      format_position(miner.drop_position),
      output_inventory and output_inventory.get_item_count("iron-ore") or 0,
      miner.energy or 0
    )
  end

  return details
end

local function format_test_failure_summary(surface, force, assertion)
  local area = assertion.area
  local parts = {}

  for entity_name, expected_count in pairs(assertion.expected_counts or {}) do
    parts[#parts + 1] =
      entity_name .. "=" .. count_test_entities(surface, force, area, entity_name) .. "/" .. expected_count
  end

  for entity_name, maximum_count in pairs(assertion.maximum_counts or {}) do
    parts[#parts + 1] =
      entity_name .. "<=" .. maximum_count .. " actual=" .. count_test_entities(surface, force, area, entity_name)
  end

  if assertion.output_item_name and assertion.output_entity_names then
    parts[#parts + 1] =
      "output-" .. assertion.output_item_name .. "=" ..
      get_test_output_item_count(surface, force, area, assertion.output_entity_names, assertion.output_item_name)
  elseif assertion.belt_item_name then
    parts[#parts + 1] =
      "belt-" .. assertion.belt_item_name .. "=" ..
      get_test_belt_item_count(surface, force, area, assertion.belt_item_name)
    parts[#parts + 1] =
      "belt-observed-" .. assertion.belt_item_name .. "=" ..
      tostring(assertion.observed_belt_item_count or 0)
  elseif assertion.skip_output_assertion then
    parts[#parts + 1] = "output-check=skipped"
  else
    local ammo_item_name = assertion.turret_ammo_item_name or "firearm-magazine"
    parts[#parts + 1] = "turret-ammo=" .. get_test_turret_ammo_count(surface, force, area, ammo_item_name)

    local assembler_name = assertion.primary_entity_name or builder_data.prototypes.firearm_magazine_assembler_name
    local assembler = get_primary_test_assembler(surface, force, area, assembler_name)
    if assembler and assembler.valid then
      local recipe = assembler.get_recipe and assembler.get_recipe()
      parts[#parts + 1] = "assembler-recipe=" .. (recipe and recipe.name or "nil")
      local output_inventory = assembler.get_output_inventory and assembler.get_output_inventory()
      parts[#parts + 1] = "assembler-output=" .. ((output_inventory and output_inventory.get_item_count(ammo_item_name)) or 0)
    else
      parts[#parts + 1] = "assembler=missing"
    end
  end

  if assertion.minimum_primary_distance_from_position then
    local assembler_name = assertion.primary_entity_name or builder_data.prototypes.firearm_magazine_assembler_name
    local assembler = get_primary_test_assembler(surface, force, area, assembler_name)
    local minimum_distance = assertion.minimum_primary_distance_from_position.distance or 0
    local actual_distance = -1

    if assembler and assembler.valid then
      actual_distance = math.sqrt(square_distance(
        assembler.position,
        assertion.minimum_primary_distance_from_position.position
      ))
    end

    parts[#parts + 1] = string.format("primary-distance=%.2f/%.2f", actual_distance, minimum_distance)
  end

  if assertion.require_valid_steel_chain_geometry then
    parts[#parts + 1] = "steel-chain-geometry=" .. tostring(steel_chain_geometry_passed(assertion))
  end

  for _, detail in ipairs(get_test_entity_debug_details(surface, force, area)) do
    parts[#parts + 1] = detail
  end

  return table.concat(parts, ", ")
end

local function test_assertion_passed(surface, force, assertion)
  local area = assertion.area

  for entity_name, expected_count in pairs(assertion.expected_counts or {}) do
    if count_test_entities(surface, force, area, entity_name) < expected_count then
      return false
    end
  end

  for entity_name, maximum_count in pairs(assertion.maximum_counts or {}) do
    if count_test_entities(surface, force, area, entity_name) > maximum_count then
      return false
    end
  end

  if assertion.require_valid_steel_chain_geometry and not steel_chain_geometry_passed(assertion) then
    return false
  end

  if assertion.primary_entity_name or assertion.required_recipe_name then
    local assembler_name = assertion.primary_entity_name or builder_data.prototypes.firearm_magazine_assembler_name
    local assembler = get_primary_test_assembler(surface, force, area, assembler_name)
    if not (assembler and assembler.valid) then
      return false
    end

    if assertion.required_recipe_name then
      local recipe = assembler.get_recipe and assembler.get_recipe()
      if not (recipe and recipe.name == assertion.required_recipe_name) then
        return false
      end
    end
  end

  if assertion.minimum_primary_distance_from_position then
    local assembler_name = assertion.primary_entity_name or builder_data.prototypes.firearm_magazine_assembler_name
    local assembler = get_primary_test_assembler(surface, force, area, assembler_name)
    if not (assembler and assembler.valid) then
      return false
    end

    local minimum_distance = assertion.minimum_primary_distance_from_position.distance or 0
    if square_distance(assembler.position, assertion.minimum_primary_distance_from_position.position) < (minimum_distance * minimum_distance) then
      return false
    end
  end

  if assertion.output_item_name and assertion.output_entity_names then
    return get_test_output_item_count(
      surface,
      force,
      area,
      assertion.output_entity_names,
      assertion.output_item_name
    ) >= (assertion.minimum_output_item_count or 1)
  end

  if assertion.belt_item_name then
    if (assertion.observed_belt_item_count or 0) >= (assertion.minimum_belt_item_count or 1) then
      return true
    end

    return get_test_belt_item_count(
      surface,
      force,
      area,
      assertion.belt_item_name
    ) >= (assertion.minimum_belt_item_count or 1)
  end

  if assertion.skip_output_assertion then
    return true
  end

  return get_test_turret_ammo_count(
    surface,
    force,
    area,
    assertion.turret_ammo_item_name or "firearm-magazine"
  ) >= (assertion.minimum_turret_ammo_count or 1)
end

local function run_active_test_assertion(tick)
  local test_state = get_test_state()
  local assertion = test_state and test_state.assertion or nil
  if not assertion or assertion.completed then
    return
  end

  local surface = get_test_surface(assertion)
  local force = game.forces[builder_data.force_name]
  if not (surface and force) then
    error("enemy-builder test: missing surface or builder force while running assertion")
  end

  local target_entity = nil
  if assertion.seed_output_item_after_layout or assertion.seed_source_item_after_layout then
    for _, site in ipairs(storage.production_sites or {}) do
      local output_machine = site.output_machine
      if site.site_type == "smelting-output-belt" and output_machine and output_machine.valid and point_in_area(output_machine.position, assertion.area) then
        target_entity = output_machine
        break
      end
    end
  end

  local source_seed = assertion.seed_source_item_after_layout
  if source_seed and not assertion.source_seed_inserted and target_entity then
    local source_inventory = target_entity.get_inventory and target_entity.get_inventory(defines.inventory.furnace_source) or nil
    if source_inventory then
      local inserted_count = source_inventory.insert{
        name = source_seed.item_name,
        count = source_seed.count
      }
      if inserted_count > 0 then
        assertion.source_seed_inserted = true
        log(
          debug_prefix .. "test: seeded source " .. source_seed.item_name ..
          " x" .. inserted_count .. " into " .. target_entity.name ..
          " at " .. format_position(target_entity.position)
        )
      end
    end
  end

  local output_seed = assertion.seed_output_item_after_layout
  if output_seed and not assertion.output_seed_inserted and target_entity then
    local output_inventory = target_entity.get_output_inventory and target_entity.get_output_inventory() or nil
    if output_inventory then
      local inserted_count = output_inventory.insert{
        name = output_seed.item_name,
        count = output_seed.count
      }
      if inserted_count > 0 then
        assertion.output_seed_inserted = true
        log(
          debug_prefix .. "test: seeded output " .. output_seed.item_name ..
          " x" .. inserted_count .. " into " .. target_entity.name ..
          " at " .. format_position(target_entity.position)
        )
      end
    end
  end

  if assertion.belt_item_name then
    local belt_item_count = get_test_belt_item_count(
      surface,
      force,
      assertion.area,
      assertion.belt_item_name
    )
    if belt_item_count > (assertion.observed_belt_item_count or 0) then
      assertion.observed_belt_item_count = belt_item_count
    end
  end

  if test_assertion_passed(surface, force, assertion) then
    if assertion.result_file then
      helpers.write_file(
        assertion.result_file,
        "PASS " .. (assertion.case_name or test_state.case_name or "manual-test") .. " tick=" .. tick .. "\n",
        false
      )
    end
    log(
      debug_prefix .. "test: PASS " ..
      (assertion.case_name or test_state.case_name or "manual-test") ..
      " at tick " .. tick
    )
    assertion.completed = true
    finish_manual_test()
    return
  end

  if tick >= (assertion.deadline_tick or tick) then
    local failure_message =
      "FAIL " .. (assertion.case_name or test_state.case_name or "manual-test") ..
      " tick=" .. tick .. " " .. format_test_failure_summary(surface, force, assertion)
    if assertion.result_file then
      helpers.write_file(assertion.result_file, failure_message .. "\n", false)
    end
    error(
      "enemy-builder test: " .. failure_message
    )
  end
end

local test_remote_interface = {
  setup_manual_test = setup_manual_test,
  setup_firearm_outpost_test_case = setup_firearm_outpost_test_case,
  setup_firearm_outpost_anchored_test_case = setup_firearm_outpost_anchored_test_case,
  setup_tree_blocked_assembler_test_case = setup_tree_blocked_assembler_test_case,
  setup_iron_plate_belt_export_test_case = setup_iron_plate_belt_export_test_case,
  setup_steel_smelting_test_case = setup_steel_smelting_test_case,
  finish_manual_test = finish_manual_test,
  clear_test_state = clear_test_state
}

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

local world_model_context = {
  builder_data = builder_data,
  build_search_positions = build_search_positions,
  clone_position = clone_position,
  debug_log = debug_log,
  direction_by_name = direction_by_name,
  format_position = format_position,
  get_container_inventory = get_container_inventory,
  get_task_anchor_entity_names = get_task_anchor_entity_names,
  next_random_index = next_random_index,
  point_in_area = point_in_area,
  rotate_direction_name = rotate_direction_name,
  rotate_offset = rotate_offset,
  select_preferred_candidate = select_preferred_candidate,
  square_distance = square_distance,
  transfer_inventory_contents = transfer_inventory_contents,
  transfer_inventory_item = transfer_inventory_item
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

find_output_belt_line_site = function(builder_state, task)
  return world_model.find_output_belt_line_site(builder_state, task, world_model_context)
end

register_assembler_defense_site = function(task, assembler, placed_layout_entities)
  return world_model.register_assembler_defense_site(task, assembler, placed_layout_entities, world_model_context)
end

register_output_belt_site = function(task, output_machine, output_inserter, belt_entities, hub_position)
  return world_model.register_output_belt_site(
    task,
    output_machine,
    output_inserter,
    belt_entities,
    hub_position,
    world_model_context
  )
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

local function process_production_sites(tick)
  return world_model.process_production_sites(tick, world_model_context)
end

local task_executor_context = {
  builder_runtime = builder_runtime,
  clone_position = clone_position,
  complete_current_task = complete_current_task,
  create_task_approach_position = create_task_approach_position,
  debug_log = debug_log,
  decorative_target_exists = decorative_target_exists,
  find_clearable_build_obstacle = find_clearable_build_obstacle,
  destroy_entity_if_valid = destroy_entity_if_valid,
  direction_from_delta = direction_from_delta,
  find_gather_site = find_gather_site,
  find_layout_site_near_machine = find_layout_site_near_machine,
  find_output_belt_line_site = find_output_belt_line_site,
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
  register_output_belt_site = register_output_belt_site,
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

local function advance_task_phase(builder_state, task, tick)
  task_executor.advance_task_phase(builder_state, task, tick, task_executor_context)
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

debug_overlay_context = {
  builder_data = builder_data,
  build_runtime_snapshot = builder_runtime.build_runtime_snapshot,
  format_item_stack_name = format_item_stack_name,
  get_builder_main_inventory = get_builder_main_inventory,
  get_item_count = get_item_count,
  get_recipe = get_recipe,
  get_sorted_item_stacks = get_sorted_item_stacks,
  update_goal_model = builder_runtime.update_goal_model
}

debug_marker_context = {
  builder_data = builder_data
}

debug_command_context = {
  builder_data = builder_data,
  build_runtime_snapshot = builder_runtime.build_runtime_snapshot,
  clone_position = clone_position,
  count_table_entries = count_table_entries,
  debug_enabled = debug_enabled,
  debug_log = debug_log,
  ensure_builder_for_command = builder_runtime.ensure_builder_for_command,
  ensure_debug_settings = ensure_debug_settings,
  ensure_production_sites = ensure_production_sites,
  ensure_resource_sites = ensure_resource_sites,
  format_direction = format_direction,
  format_position = format_position,
  get_active_task = get_active_task,
  get_builder_state = get_builder_state,
  get_command_player = get_command_player,
  get_item_count = get_item_count,
  get_recipe = get_recipe,
  record_recovery = builder_runtime.record_recovery,
  reply_to_command = reply_to_command,
  set_idle = set_idle,
  update_goal_model = builder_runtime.update_goal_model
}

maintenance_pass_context = {
  builder_data = builder_data,
  debug_log = debug_log,
  format_position = format_position,
  get_container_inventory = get_container_inventory,
  get_item_count = get_item_count,
  pull_inventory_contents_to_builder = pull_inventory_contents_to_builder,
  remove_item = remove_item,
  square_distance = square_distance
}

maintenance_passes = default_maintenance_passes.build(maintenance_pass_context)

local function advance_builder(builder_state, tick)
  configure_builder_entity(builder_state.entity)
  process_production_sites(tick)
  maintenance_runner.run(builder_state, tick, maintenance_passes)
  goal_engine.advance(builder_data, builder_state, tick, goal_engine_adapters)
end

local function on_init()
  ensure_debug_settings()
  ensure_production_sites()
  ensure_resource_sites()
  ensure_builder_map_markers()
  ensure_builder_force()

  if not autospawn_suppressed_for_test() then
    local player = get_first_valid_player()
    if player then
      local builder_state = spawn_builder_for_player(player)
      if builder_state then
        discover_resource_sites(builder_state)
      end
    else
      debug_log("on_init: no player character available yet")
    end
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
    if not autospawn_suppressed_for_test() then
      local player = get_first_valid_player()
      if player then
        local builder_state = spawn_builder_for_player(player)
        if builder_state then
          discover_resource_sites(builder_state)
        end
      else
        debug_log("on_configuration_changed: no player character available yet")
      end
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
    if not autospawn_suppressed_for_test() then
      spawn_builder_for_player(player)
    end
    if get_builder_state() then
      builder_runtime.update_goal_model(get_builder_state(), game.tick)
    end
    builder_runtime.update_builder_overlay_for_player(player, get_builder_state())
    update_builder_map_markers(get_builder_state(), game.tick, true)
  end
end

local function on_tick(event)
  local builder_state = get_builder_state()
  if not builder_state and not autospawn_suppressed_for_test() then
    local player = get_first_valid_player()
    if player then
      builder_state = spawn_builder_for_player(player)
    end
  end

  if builder_state then
    advance_builder(builder_state, event.tick)
    builder_runtime.update_goal_model(builder_state, event.tick)
  end

  run_active_test_assertion(event.tick)
  builder_state = get_builder_state()

  builder_runtime.update_builder_overlays(builder_state, event.tick, false)
  update_builder_map_markers(builder_state, event.tick, false)
end

function builder_runtime.register_events()
  debug_commands.register(debug_command_context)
  if remote.interfaces["enemy-builder-test"] then
    remote.remove_interface("enemy-builder-test")
  end
  remote.add_interface("enemy-builder-test", test_remote_interface)
  script.on_init(on_init)
  script.on_configuration_changed(on_configuration_changed)
  script.on_event(defines.events.on_player_created, on_player_created)
  script.on_event(defines.events.on_tick, on_tick)
end

return builder_runtime

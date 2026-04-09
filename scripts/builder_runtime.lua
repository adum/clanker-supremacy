local builder_data = require("shared.builder_data")

local builder_runtime = {}
local debug_prefix = "[enemy-builder] "
local get_builder_state
local get_active_task
local set_idle

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

local function clone_position(position)
  return {x = position.x, y = position.y}
end

local function square_distance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return (dx * dx) + (dy * dy)
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

local function ensure_debug_settings()
  if storage.debug_enabled == nil then
    storage.debug_enabled = true
  end
end

local function debug_enabled()
  return storage.debug_enabled == true
end

local function debug_log(message)
  if debug_enabled() then
    log(debug_prefix .. message)
  end
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

    if task_state.next_attempt_tick then
      lines[#lines + 1] = "next-attempt-tick=" .. task_state.next_attempt_tick
    end
  end

  return lines
end

local function ensure_builder_force()
  local force = game.forces[builder_data.force_name]
  if force then
    return force
  end

  return game.create_force(builder_data.force_name)
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
    task_state = nil
  }

  return storage.builder_state
end

local function find_miner_placement(surface, force, task, resource_position)
  local positions = {}
  local radius = task.placement_search_radius
  local step = task.placement_step
  local stats = {
    positions_checked = 0,
    placeable_positions = 0,
    test_miners_created = 0,
    mining_area_hits = 0
  }

  for dx = -radius, radius, step do
    for dy = -radius, radius, step do
      positions[#positions + 1] = {
        x = resource_position.x + dx,
        y = resource_position.y + dy,
        weight = (dx * dx) + (dy * dy)
      }
    end
  end

  table.sort(positions, function(left, right)
    return left.weight < right.weight
  end)

  for _, position in ipairs(positions) do
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
          local mines_resource = #covered_resources > 0

          if mines_resource then
            stats.mining_area_hits = stats.mining_area_hits + 1
          end

          test_miner.destroy()

          if mines_resource then
            return {x = position.x, y = position.y}, direction, stats
          end
        end
      end
    end
  end

  return nil, nil, stats
end

local function get_resource_position_key(resource)
  return string.format("%.2f:%.2f", resource.position.x, resource.position.y)
end

local function find_resource_site(surface, force, origin, task)
  local seen_resources = {}
  local summary = {
    radii_checked = 0,
    resources_considered = 0,
    positions_checked = 0,
    placeable_positions = 0,
    test_miners_created = 0,
    mining_area_hits = 0
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

    local considered_this_radius = 0

    for _, resource in ipairs(resources) do
      local resource_key = get_resource_position_key(resource)
      if not seen_resources[resource_key] then
        seen_resources[resource_key] = true
        considered_this_radius = considered_this_radius + 1
        summary.resources_considered = summary.resources_considered + 1

        local build_position, build_direction, placement_stats = find_miner_placement(surface, force, task, resource.position)
        summary.positions_checked = summary.positions_checked + placement_stats.positions_checked
        summary.placeable_positions = summary.placeable_positions + placement_stats.placeable_positions
        summary.test_miners_created = summary.test_miners_created + placement_stats.test_miners_created
        summary.mining_area_hits = summary.mining_area_hits + placement_stats.mining_area_hits

        if build_position then
          return {
            resource = resource,
            build_position = build_position,
            build_direction = build_direction,
            summary = summary
          }
        end

        if task.max_resource_candidates_per_radius and considered_this_radius >= task.max_resource_candidates_per_radius then
          break
        end
      end
    end
  end

  return nil, summary
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
      "; checked " .. search_summary.resources_considered .. " resource tiles, " ..
      search_summary.positions_checked .. " candidate positions, " ..
      search_summary.placeable_positions .. " placeable spots, " ..
      search_summary.test_miners_created .. " probe drills, " ..
      search_summary.mining_area_hits .. " mining-area hits; retry at tick " ..
      builder_state.task_state.next_attempt_tick
    )
    return
  end

  local resource = site.resource
  local build_position = site.build_position
  local build_direction = site.build_direction

  builder_state.task_state = {
    phase = "moving",
    resource_position = clone_position(resource.position),
    build_position = build_position,
    build_direction = build_direction,
    last_position = clone_position(entity.position),
    last_progress_tick = tick
  }
  debug_log(
    "task " .. task.id .. ": found build site for " .. task.resource_name .. " at " ..
    format_position(resource.position) .. " after checking " .. site.summary.resources_considered ..
    " resource tiles; moving toward " .. format_position(build_position)
  )
end

local function refresh_task(builder_state, task, tick)
  builder_state.task_state = nil
  debug_log("task " .. task.id .. ": retrying from " .. format_position(builder_state.entity.position))
  start_place_miner_task(builder_state, task, tick)
end

local function move_builder(builder_state, task, tick)
  local entity = builder_state.entity
  local task_state = builder_state.task_state

  if square_distance(entity.position, task_state.build_position) <= (task.arrival_distance * task.arrival_distance) then
    set_idle(entity)
    task_state.phase = "building"
    debug_log("task " .. task.id .. ": reached build position " .. format_position(task_state.build_position))
    return
  end

  local delta_x = task_state.build_position.x - entity.position.x
  local delta_y = task_state.build_position.y - entity.position.y
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

local function place_miner(builder_state, task, tick)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local surface = entity.surface

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

  if task.fuel then
    local fuel_inventory = miner.get_inventory(defines.inventory.fuel)
    if fuel_inventory then
      fuel_inventory.insert{
        name = task.fuel.name,
        count = task.fuel.count
      }
    end
  end

  builder_state.task_index = builder_state.task_index + 1
  builder_state.task_state = nil
  set_idle(entity)
  debug_log("task " .. task.id .. ": placed " .. task.miner_name .. " at " .. format_position(miner.position))
end

local function advance_builder(builder_state, tick)
  configure_builder_entity(builder_state.entity)

  local task = get_active_task(builder_state)
  if not task then
    set_idle(builder_state.entity)
    return
  end

  if not builder_state.task_state then
    if task.type == "place-miner-on-resource" then
      start_place_miner_task(builder_state, task, tick)
    end
    return
  end

  local phase = builder_state.task_state.phase

  if phase == "waiting-for-resource" then
    if tick >= builder_state.task_state.next_attempt_tick then
      refresh_task(builder_state, task, tick)
    end
    return
  end

  if phase == "moving" then
    move_builder(builder_state, task, tick)
    return
  end

  if phase == "building" then
    place_miner(builder_state, task, tick)
  end
end

local function on_init()
  ensure_debug_settings()
  ensure_builder_force()

  local player = get_first_valid_player()
  if player then
    spawn_builder_for_player(player)
  else
    debug_log("on_init: no player character available yet")
  end
end

local function on_configuration_changed()
  ensure_debug_settings()
  ensure_builder_force()

  if not get_builder_state() then
    local player = get_first_valid_player()
    if player then
      spawn_builder_for_player(player)
    else
      debug_log("on_configuration_changed: no player character available yet")
    end
  end
end

local function on_player_created(event)
  local player = game.get_player(event.player_index)
  if player then
    debug_log("on_player_created: player " .. player.name)
    spawn_builder_for_player(player)
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

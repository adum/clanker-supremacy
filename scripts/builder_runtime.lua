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

  lines[#lines + 1] = "production-sites=" .. #ensure_production_sites()

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

local function get_item_count(entity, item_name)
  return entity.get_item_count(item_name)
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

local function register_smelting_site(task, miner, downstream_machine, output_container)
  local production_sites = ensure_production_sites()
  production_sites[#production_sites + 1] = {
    task_id = task.id,
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
    "task " .. task.id .. ": registered smelting site with miner at " .. format_position(miner.position) ..
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

local function complete_current_task(builder_state, task, completion_message)
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
    output_container_hits = 0,
    downstream_positions_checked = 0,
    downstream_placeable_positions = 0,
    test_downstream_created = 0,
    downstream_anchor_hits = 0
  }

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
          local mines_resource = #covered_resources > 0
          local downstream_machine_position = nil
          local output_container_position = nil
          local has_output_container_spot = true

          if mines_resource then
            stats.mining_area_hits = stats.mining_area_hits + 1

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
            return {
              x = position.x,
              y = position.y
            }, direction, output_container_position, downstream_machine_position, stats
          end
        end
      end
    end
  end

  return nil, nil, nil, nil, stats
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
    mining_area_hits = 0,
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

    local considered_this_radius = 0

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
        summary.output_container_hits = summary.output_container_hits + placement_stats.output_container_hits
        summary.downstream_positions_checked = summary.downstream_positions_checked + placement_stats.downstream_positions_checked
        summary.downstream_placeable_positions = summary.downstream_placeable_positions + placement_stats.downstream_placeable_positions
        summary.test_downstream_created = summary.test_downstream_created + placement_stats.test_downstream_created
        summary.downstream_anchor_hits = summary.downstream_anchor_hits + placement_stats.downstream_anchor_hits

        if build_position then
          return {
            resource = resource,
            build_position = build_position,
            build_direction = build_direction,
            output_container_position = output_container_position,
            downstream_machine_position = downstream_machine_position,
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
      "; checked " .. search_summary.resources_considered .. " resource tiles, " ..
      search_summary.positions_checked .. " candidate positions, " ..
      search_summary.placeable_positions .. " placeable spots, " ..
      search_summary.test_miners_created .. " probe drills, " ..
      search_summary.mining_area_hits .. " mining-area hits, " ..
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
    format_position(resource.position) .. " after checking " .. site.summary.resources_considered ..
    " resource tiles; moving toward " .. format_position(build_position) ..
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

  complete_current_task(
    builder_state,
    task,
    "placed " .. task.miner_name .. " at " .. format_position(miner.position) ..
    (downstream_machine and " with " .. downstream_machine.name .. " at " .. format_position(downstream_machine.position) or "") ..
    (container and " and " .. container.name .. " at " .. format_position(container.position) or "")
  )
end

local function place_miner(builder_state, task, tick)
  local entity = builder_state.entity
  local task_state = builder_state.task_state
  local surface = entity.surface

  local function abort_build(reason)
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

  builder_state.task_state = nil
end

local function advance_builder(builder_state, tick)
  configure_builder_entity(builder_state.entity)
  process_production_sites(tick)
  collect_nearby_container_items(builder_state, tick)

  local task = get_active_task(builder_state)
  if not task then
    set_idle(builder_state.entity)
    return
  end

  if not builder_state.task_state then
    start_task(builder_state, task, tick)
    return
  end

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
    place_miner(builder_state, task, tick)
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
    finish_place_miner_task(builder_state, task, tick)
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

local function on_init()
  ensure_debug_settings()
  ensure_production_sites()
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
  ensure_production_sites()
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

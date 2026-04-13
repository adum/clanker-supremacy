local layout_snapshot = {}

local function parse_positive_integer(value)
  local number = tonumber(value)
  if not number or number <= 0 then
    return nil
  end

  return math.floor(number)
end

local function parse_positive_number(value)
  local number = tonumber(value)
  if not number or number <= 0 then
    return nil
  end

  return number
end

local function parse_snapshot_ticks_csv(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end

  local snapshot_ticks = {}
  for part in string.gmatch(value, "[^,%s]+") do
    local tick = parse_positive_integer(part)
    if tick then
      snapshot_ticks[#snapshot_ticks + 1] = tick
    end
  end

  if #snapshot_ticks == 0 then
    return nil
  end

  table.sort(snapshot_ticks)

  local normalized = {}
  local previous_tick = nil
  for _, tick in ipairs(snapshot_ticks) do
    if tick ~= previous_tick then
      normalized[#normalized + 1] = tick
      previous_tick = tick
    end
  end

  return normalized
end

local function clone_area(area, clone_position)
  if not area then
    return nil
  end

  return {
    left_top = clone_position(area.left_top),
    right_bottom = clone_position(area.right_bottom)
  }
end

local function is_dense_array(value)
  if type(value) ~= "table" then
    return false
  end

  local max_index = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key <= 0 or key % 1 ~= 0 then
      return false
    end
    if key > max_index then
      max_index = key
    end
  end

  for index = 1, max_index do
    if value[index] == nil then
      return false
    end
  end

  return true
end

local function json_escape_string(value)
  return (tostring(value)
    :gsub("\\", "\\\\")
    :gsub("\"", "\\\"")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t"))
end

local function encode_json(value)
  local value_type = type(value)

  if value == nil then
    return "null"
  end

  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end

  if value_type == "string" then
    return "\"" .. json_escape_string(value) .. "\""
  end

  if value_type ~= "table" then
    return "\"" .. json_escape_string(tostring(value)) .. "\""
  end

  if is_dense_array(value) then
    local parts = {}
    for index = 1, #value do
      parts[#parts + 1] = encode_json(value[index])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = "\"" .. json_escape_string(tostring(key)) .. "\":" .. encode_json(value[key])
  end

  return "{" .. table.concat(parts, ",") .. "}"
end

local function svg_escape(value)
  return tostring(value)
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub("\"", "&quot;")
end

local function normalize_inventory_contents(contents, get_sorted_item_stacks)
  local normalized = {}

  for _, item_stack in ipairs(get_sorted_item_stacks(contents or {})) do
    normalized[#normalized + 1] = {
      name = item_stack.name,
      quality = item_stack.quality,
      count = item_stack.count
    }
  end

  return normalized
end

local function inventory_snapshot_from_object(inventory, get_sorted_item_stacks)
  if not inventory then
    return {}
  end

  return normalize_inventory_contents(inventory.get_contents(), get_sorted_item_stacks)
end

local function entity_has_items(entity, inventory_getter, count_table_entries)
  if not inventory_getter then
    return false
  end

  local inventory = inventory_getter(entity)
  if not inventory then
    return false
  end

  return count_table_entries(inventory.get_contents()) > 0
end

local function get_snapshot_entity_area(entity, clone_position)
  if entity and entity.valid and entity.selection_box then
    return clone_area(entity.selection_box, clone_position)
  end

  if entity and entity.valid and entity.position then
    return {
      left_top = {x = entity.position.x - 0.45, y = entity.position.y - 0.45},
      right_bottom = {x = entity.position.x + 0.45, y = entity.position.y + 0.45}
    }
  end

  return nil
end

local function serialize_goal_node(node, deep_copy)
  if not node then
    return nil
  end

  local serialized = {
    id = node.id,
    title = node.title,
    kind = node.kind,
    status = node.status,
    active = node.active == true
  }

  if node.blockers and #node.blockers > 0 then
    serialized.blockers = {}
    for _, blocker in ipairs(node.blockers) do
      serialized.blockers[#serialized.blockers + 1] = {
        kind = blocker.kind,
        message = blocker.message,
        meta = deep_copy(blocker.meta or {})
      }
    end
  end

  if node.meta then
    serialized.meta = {
      item_name = node.meta.item_name,
      target_count = node.meta.target_count,
      current_count = node.meta.current_count,
      execution_kind = node.meta.execution_kind,
      pattern_name = node.meta.pattern_name,
      milestone_name = node.meta.milestone_name
    }
  end

  if node.children and #node.children > 0 then
    serialized.children = {}
    for _, child in ipairs(node.children) do
      serialized.children[#serialized.children + 1] = serialize_goal_node(child, deep_copy)
    end
  end

  return serialized
end

local function collect_snapshot_resources(surface, area, clone_position)
  local resources = {}

  for _, resource in ipairs(surface.find_entities_filtered{area = area, type = "resource"}) do
    resources[#resources + 1] = {
      name = resource.name,
      position = clone_position(resource.position),
      amount = resource.amount
    }
  end

  table.sort(resources, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    if left.position.y ~= right.position.y then
      return left.position.y < right.position.y
    end
    return left.position.x < right.position.x
  end)

  return resources
end

local function collect_snapshot_decoratives(surface, area, clone_position)
  local decoratives = {}

  for _, decorative in ipairs(surface.find_decoratives_filtered{
    area = {
      {area.left_top.x, area.left_top.y},
      {area.right_bottom.x, area.right_bottom.y}
    }
  }) do
    decoratives[#decoratives + 1] = {
      name = decorative.decorative.name,
      position = clone_position(decorative.position)
    }
  end

  table.sort(decoratives, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    if left.position.y ~= right.position.y then
      return left.position.y < right.position.y
    end
    return left.position.x < right.position.x
  end)

  return decoratives
end

local function collect_snapshot_entities(surface, force, area, ctx)
  local entities = {}

  for _, entity in ipairs(surface.find_entities_filtered{area = area, force = force}) do
    local serialized = {
      name = entity.name,
      type = entity.type,
      position = ctx.clone_position(entity.position),
      direction = entity.direction,
      area = get_snapshot_entity_area(entity, ctx.clone_position)
    }

    if entity.type == "inserter" then
      serialized.drop_position = ctx.clone_position(entity.drop_position)
      serialized.pickup_position = ctx.clone_position(entity.pickup_position)
    elseif entity.type == "mining-drill" then
      serialized.drop_position = ctx.clone_position(entity.drop_position)
      serialized.mining_area = clone_area(entity.mining_area, ctx.clone_position)
    end

    if entity.type == "assembling-machine" and entity.get_recipe then
      local recipe = entity.get_recipe()
      serialized.recipe_name = recipe and recipe.name or nil
    end

    if entity.type == "mining-drill" and entity.mining_target and entity.mining_target.valid then
      serialized.mining_target = {
        name = entity.mining_target.name,
        position = ctx.clone_position(entity.mining_target.position)
      }
    end

    if entity.type == "gun-turret" then
      serialized.ammo_items = inventory_snapshot_from_object(
        entity.get_inventory(defines.inventory.turret_ammo),
        ctx.get_sorted_item_stacks
      )
    end

    if entity_has_items(entity, function(target) return target.get_output_inventory and target.get_output_inventory() or nil end, ctx.count_table_entries) then
      serialized.output_items = inventory_snapshot_from_object(entity.get_output_inventory(), ctx.get_sorted_item_stacks)
    end

    if entity_has_items(entity, function(target) return target.get_fuel_inventory and target.get_fuel_inventory() or nil end, ctx.count_table_entries) then
      serialized.fuel_items = inventory_snapshot_from_object(entity.get_fuel_inventory(), ctx.get_sorted_item_stacks)
    end

    if entity.type == "container" or entity.type == "logistic-container" then
      serialized.container_items = inventory_snapshot_from_object(ctx.get_container_inventory(entity), ctx.get_sorted_item_stacks)
    end

    if entity.type == "furnace" then
      local source_inventory = entity.get_inventory(defines.inventory.furnace_source)
      if source_inventory and ctx.count_table_entries(source_inventory.get_contents()) > 0 then
        serialized.source_items = inventory_snapshot_from_object(source_inventory, ctx.get_sorted_item_stacks)
      end
    end

    entities[#entities + 1] = serialized
  end

  table.sort(entities, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    if left.position.y ~= right.position.y then
      return left.position.y < right.position.y
    end
    return left.position.x < right.position.x
  end)

  return entities
end

local function collect_snapshot_site_summaries(area, storage, point_in_area, clone_position)
  local resource_sites = {}
  for _, site in ipairs(storage.resource_sites or {}) do
    local anchor = (site.output_machine and site.output_machine.valid and site.output_machine) or
      (site.miner and site.miner.valid and site.miner) or
      (site.downstream_machine and site.downstream_machine.valid and site.downstream_machine)
    if anchor and point_in_area(anchor.position, area) then
      resource_sites[#resource_sites + 1] = {
        pattern_name = site.pattern_name,
        site_type = site.site_type,
        miner_position = site.miner and site.miner.valid and clone_position(site.miner.position) or nil,
        output_machine_position = site.output_machine and site.output_machine.valid and clone_position(site.output_machine.position) or nil,
        output_container_position = site.output_container and site.output_container.valid and clone_position(site.output_container.position) or nil,
        downstream_machine_position = site.downstream_machine and site.downstream_machine.valid and clone_position(site.downstream_machine.position) or nil,
        belt_hub_position = site.belt_hub_position and clone_position(site.belt_hub_position) or nil
      }
    end
  end

  local production_sites = {}
  for _, site in ipairs(storage.production_sites or {}) do
    local anchor = (site.assembler and site.assembler.valid and site.assembler) or
      (site.output_machine and site.output_machine.valid and site.output_machine) or
      (site.anchor_machine and site.anchor_machine.valid and site.anchor_machine)
    if anchor and point_in_area(anchor.position, area) then
      production_sites[#production_sites + 1] = {
        site_type = site.site_type,
        pattern_name = site.pattern_name,
        assembler_position = site.assembler and site.assembler.valid and clone_position(site.assembler.position) or nil,
        anchor_machine_position = site.anchor_machine and site.anchor_machine.valid and clone_position(site.anchor_machine.position) or nil,
        output_machine_position = site.output_machine and site.output_machine.valid and clone_position(site.output_machine.position) or nil,
        downstream_machine_position = site.downstream_machine and site.downstream_machine.valid and clone_position(site.downstream_machine.position) or nil,
        belt_hub_position = site.belt_hub_position and clone_position(site.belt_hub_position) or nil
      }
    end
  end

  table.sort(resource_sites, function(left, right)
    return (left.pattern_name or "") < (right.pattern_name or "")
  end)
  table.sort(production_sites, function(left, right)
    return (left.site_type or "") < (right.site_type or "")
  end)

  return resource_sites, production_sites
end

local function snapshot_color_for_resource(resource_name)
  if resource_name == "iron-ore" then
    return "#4d85d1"
  end
  if resource_name == "copper-ore" then
    return "#d97a39"
  end
  if resource_name == "coal" then
    return "#555555"
  end
  if resource_name == "stone" then
    return "#b8ab8a"
  end
  return "#999999"
end

local function snapshot_color_for_entity(entity_name, entity_type, builder_data)
  if entity_name == builder_data.avatar.prototype_name then
    return "#ff4d4d"
  end
  if entity_name == "transport-belt" then
    return "#d4b036"
  end
  if entity_name == "burner-inserter" then
    return "#ff9966"
  end
  if entity_name == "burner-mining-drill" then
    return "#7dc56a"
  end
  if entity_name == "stone-furnace" then
    return "#d1a87a"
  end
  if entity_name == "wooden-chest" then
    return "#8d6039"
  end
  if entity_name == "gun-turret" then
    return "#cc5555"
  end
  if entity_name == "small-electric-pole" then
    return "#d6c28a"
  end
  if entity_name == "solar-panel" then
    return "#4ca3dd"
  end
  if entity_type == "assembling-machine" then
    return "#9b6ad3"
  end
  return "#cccccc"
end

local function build_layout_snapshot_svg(snapshot, builder_data)
  local area = snapshot.area
  local scale = 8
  local padding = 24
  local width = math.floor(((area.right_bottom.x - area.left_top.x) * scale) + (padding * 2))
  local height = math.floor(((area.right_bottom.y - area.left_top.y) * scale) + (padding * 2) + 120)
  local world_height = area.right_bottom.y - area.left_top.y

  local function to_svg_point(position)
    return {
      x = padding + ((position.x - area.left_top.x) * scale),
      y = padding + ((world_height - (position.y - area.left_top.y)) * scale)
    }
  end

  local svg = {
    string.format(
      '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">',
      width,
      height,
      width,
      height
    ),
    '<rect x="0" y="0" width="100%" height="100%" fill="#171310"/>',
    string.format(
      '<rect x="%d" y="%d" width="%d" height="%d" fill="#231e18" stroke="#40352a" stroke-width="1"/>',
      padding,
      padding,
      math.floor((area.right_bottom.x - area.left_top.x) * scale),
      math.floor((area.right_bottom.y - area.left_top.y) * scale)
    )
  }

  for _, resource in ipairs(snapshot.resources or {}) do
    local point = to_svg_point(resource.position)
    svg[#svg + 1] = string.format(
      '<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s" fill-opacity="0.55"/>',
      point.x - (0.5 * scale),
      point.y - (0.5 * scale),
      scale,
      scale,
      snapshot_color_for_resource(resource.name)
    )
  end

  for _, decorative in ipairs(snapshot.decoratives or {}) do
    local point = to_svg_point(decorative.position)
    svg[#svg + 1] = string.format(
      '<circle cx="%.2f" cy="%.2f" r="2.2" fill="#7f776d" fill-opacity="0.85"/>',
      point.x,
      point.y
    )
  end

  for _, entity in ipairs(snapshot.entities or {}) do
    if entity.mining_area then
      local left_top = to_svg_point(entity.mining_area.left_top)
      local right_bottom = to_svg_point(entity.mining_area.right_bottom)
      svg[#svg + 1] = string.format(
        '<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="none" stroke="#6fe38f" stroke-width="1" stroke-dasharray="4 2" opacity="0.7"/>',
        left_top.x,
        right_bottom.y,
        math.max(right_bottom.x - left_top.x, 1),
        math.max(left_top.y - right_bottom.y, 1)
      )
    end
  end

  for _, entity in ipairs(snapshot.entities or {}) do
    if entity.pickup_position and entity.drop_position then
      local pickup = to_svg_point(entity.pickup_position)
      local drop = to_svg_point(entity.drop_position)
      svg[#svg + 1] = string.format(
        '<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="#ffd166" stroke-width="1.5" opacity="0.9"/>',
        pickup.x,
        pickup.y,
        drop.x,
        drop.y
      )
    end
  end

  for _, entity in ipairs(snapshot.entities or {}) do
    local draw_area = entity.area
    if draw_area then
      local left_top = to_svg_point(draw_area.left_top)
      local right_bottom = to_svg_point(draw_area.right_bottom)
      svg[#svg + 1] = string.format(
        '<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s" fill-opacity="0.88" stroke="#111111" stroke-width="1"/>',
        left_top.x,
        right_bottom.y,
        math.max(right_bottom.x - left_top.x, 3),
        math.max(left_top.y - right_bottom.y, 3),
        snapshot_color_for_entity(entity.name, entity.type, builder_data)
      )
    end
  end

  local text_y = height - 90
  svg[#svg + 1] = string.format(
    '<text x="%d" y="%d" fill="#f4efe6" font-size="16" font-family="monospace">Tick %d | %s</text>',
    padding,
    text_y,
    snapshot.tick,
    svg_escape(snapshot.goal_summary or "Goal: inactive")
  )
  svg[#svg + 1] = string.format(
    '<text x="%d" y="%d" fill="#d8d0c2" font-size="14" font-family="monospace">%s</text>',
    padding,
    text_y + 22,
    svg_escape(snapshot.activity_summary or "Activity: inactive")
  )

  local line_y = text_y + 44
  for _, line in ipairs(snapshot.goal_path_lines or {}) do
    svg[#svg + 1] = string.format(
      '<text x="%d" y="%d" fill="#cbb89c" font-size="12" font-family="monospace">%s</text>',
      padding,
      line_y,
      svg_escape(line)
    )
    line_y = line_y + 16
    if line_y > height - 12 then
      break
    end
  end

  svg[#svg + 1] = "</svg>"
  return table.concat(svg, "\n")
end

local function build_snapshot_index_html(snapshot_run)
  local html = {
    "<!doctype html>",
    "<html><head><meta charset=\"utf-8\"/>",
    "<title>" .. svg_escape(snapshot_run.case_name) .. "</title>",
    "<style>",
    "body{font-family:ui-monospace,Menlo,monospace;background:#16120f;color:#f1e9db;margin:24px;}",
    "a{color:#8ecbff;} .snapshot{margin:32px 0;padding:16px;background:#221c17;border:1px solid #3a2f25;}",
    "img{max-width:100%;height:auto;display:block;border:1px solid #3a2f25;background:#171310;}",
    ".meta{color:#cabda8;margin:8px 0 16px;}",
    "</style></head><body>",
    "<h1>" .. svg_escape(snapshot_run.case_name) .. "</h1>",
    "<p>" .. svg_escape(snapshot_run.description or "") .. "</p>"
  }

  for _, entry in ipairs(snapshot_run.manifest.entries or {}) do
    html[#html + 1] = "<div class=\"snapshot\">"
    html[#html + 1] = "<h2>Tick " .. tostring(entry.tick) .. "</h2>"
    html[#html + 1] = "<div class=\"meta\">" .. svg_escape((entry.goal_summary or "") .. " | " .. (entry.activity_summary or "")) .. "</div>"
    html[#html + 1] = '<p><a href="' .. svg_escape(entry.json_file) .. '">JSON</a> | <a href="' .. svg_escape(entry.svg_file) .. '">SVG</a></p>'
    html[#html + 1] = '<img src="' .. svg_escape(entry.svg_file) .. '" alt="Tick ' .. tostring(entry.tick) .. ' layout snapshot"/>'
    html[#html + 1] = "</div>"
  end

  html[#html + 1] = "</body></html>"
  return table.concat(html, "\n")
end

local function write_snapshot_manifest_files(snapshot_run)
  helpers.write_file(
    snapshot_run.output_dir .. "/manifest.json",
    encode_json(snapshot_run.manifest) .. "\n",
    false
  )
  helpers.write_file(
    snapshot_run.output_dir .. "/index.html",
    build_snapshot_index_html(snapshot_run),
    false
  )
end

local function create_test_tree_cluster(surface, center, radius_x, radius_y, spacing, tree_name)
  local created = 0
  local step = spacing or 2
  local prototype_name = tree_name or "tree-08"

  for dx = -radius_x, radius_x, step do
    for dy = -radius_y, radius_y, step do
      local normalized_distance =
        ((dx * dx) / math.max(radius_x * radius_x, 1)) +
        ((dy * dy) / math.max(radius_y * radius_y, 1))
      if normalized_distance <= 1 and ((math.floor(dx / step) + math.floor(dy / step)) % 2 == 0) then
        local entity = surface.create_entity{
          name = prototype_name,
          position = {
            x = center.x + dx + 0.5,
            y = center.y + dy + 0.5
          }
        }

        if entity and entity.valid then
          created = created + 1
        end
      end
    end
  end

  return created
end

local function create_test_rock_cluster(surface, center, radius_x, radius_y, spacing)
  local decoratives = {}
  local decorative_names = {"small-sand-rock", "medium-rock", "small-rock"}
  local step = spacing or 2
  local decorative_index = 1

  for dx = -radius_x, radius_x, step do
    for dy = -radius_y, radius_y, step do
      local normalized_distance =
        ((dx * dx) / math.max(radius_x * radius_x, 1)) +
        ((dy * dy) / math.max(radius_y * radius_y, 1))
      if normalized_distance <= 1 and ((math.floor(dx / step) + math.floor(dy / step)) % 2 == 0) then
        decoratives[#decoratives + 1] = {
          name = decorative_names[decorative_index],
          position = {
            x = math.floor(center.x + dx),
            y = math.floor(center.y + dy)
          },
          amount = 1
        }
        decorative_index = (decorative_index % #decorative_names) + 1
      end
    end
  end

  if #decoratives > 0 then
    surface.create_decoratives{
      check_collision = false,
      decoratives = decoratives
    }
  end

  return #decoratives
end

local function export_snapshot_run_tick(snapshot_run, tick, ctx)
  local surface = ctx.get_test_surface{surface_name = snapshot_run.surface_name}
  local force = game.forces[ctx.builder_data.force_name]
  local builder_state = ctx.get_builder_state and ctx.get_builder_state() or nil
  local runtime_snapshot = builder_state and ctx.build_runtime_snapshot(builder_state, tick) or {
    tick = tick,
    builder_missing = true
  }

  if builder_state then
    ctx.update_goal_model(builder_state, tick)
  end

  local snapshot = {
    case_name = snapshot_run.case_name,
    tick = tick,
    description = snapshot_run.description,
    area = clone_area(snapshot_run.area, ctx.clone_position),
    goal_summary = builder_state and ctx.debug_overlay.get_goal_summary(builder_state, tick, ctx.debug_overlay_context) or "Goal: inactive",
    activity_summary = builder_state and ctx.debug_overlay.get_activity_summary(builder_state, tick, ctx.debug_overlay_context) or "Activity: inactive",
    goal_path_lines = builder_state and ctx.deep_copy(builder_state.goal_path_lines or {}) or {},
    goal_blocker_lines = builder_state and ctx.deep_copy(builder_state.goal_blocker_lines or {}) or {},
    recent_maintenance_actions = builder_state and ctx.deep_copy((builder_state.maintenance_state and builder_state.maintenance_state.recent_actions) or {}) or {},
    builder_position = builder_state and builder_state.entity and builder_state.entity.valid and ctx.clone_position(builder_state.entity.position) or nil,
    builder_inventory = {},
    runtime_snapshot = {
      tick = runtime_snapshot.tick,
      position = runtime_snapshot.position,
      task_index = runtime_snapshot.task_index,
      task_state = ctx.deep_copy(runtime_snapshot.task_state),
      resource_site_count = runtime_snapshot.resource_site_count,
      production_site_count = runtime_snapshot.production_site_count,
      resource_site_counts = ctx.deep_copy(runtime_snapshot.resource_site_counts),
      completed_scaling_milestones = ctx.deep_copy(runtime_snapshot.completed_scaling_milestones),
      recent_maintenance_actions = ctx.deep_copy(runtime_snapshot.recent_maintenance_actions),
      last_recovery = ctx.deep_copy(runtime_snapshot.last_recovery)
    },
    goal_model = builder_state and serialize_goal_node(builder_state.goal_model_root, ctx.deep_copy) or nil,
    resources = surface and collect_snapshot_resources(surface, snapshot_run.area, ctx.clone_position) or {},
    decoratives = surface and collect_snapshot_decoratives(surface, snapshot_run.area, ctx.clone_position) or {},
    entities = surface and force and collect_snapshot_entities(surface, force, snapshot_run.area, ctx) or {}
  }

  local resource_sites, production_sites = collect_snapshot_site_summaries(
    snapshot_run.area,
    ctx.storage,
    ctx.point_in_area,
    ctx.clone_position
  )
  snapshot.resource_sites = resource_sites
  snapshot.production_sites = production_sites

  if builder_state and builder_state.entity and builder_state.entity.valid then
    local main_inventory = builder_state.entity.get_main_inventory and builder_state.entity.get_main_inventory() or nil
    if main_inventory then
      snapshot.builder_inventory = normalize_inventory_contents(main_inventory.get_contents(), ctx.get_sorted_item_stacks)
    end
  end

  local file_stem = string.format("tick-%06d", tick)
  local json_file = file_stem .. ".json"
  local svg_file = file_stem .. ".svg"

  helpers.write_file(snapshot_run.output_dir .. "/" .. json_file, encode_json(snapshot) .. "\n", false)
  helpers.write_file(snapshot_run.output_dir .. "/" .. svg_file, build_layout_snapshot_svg(snapshot, ctx.builder_data), false)

  snapshot_run.manifest.entries[#snapshot_run.manifest.entries + 1] = {
    tick = tick,
    json_file = json_file,
    svg_file = svg_file,
    goal_summary = snapshot.goal_summary,
    activity_summary = snapshot.activity_summary
  }
  snapshot_run.last_export_tick = tick
  write_snapshot_manifest_files(snapshot_run)

  ctx.debug_log(
    "snapshot run " .. snapshot_run.case_name ..
    ": exported " .. file_stem .. " to " .. snapshot_run.output_dir
  )
end

function layout_snapshot.run_active_snapshot_run(tick, ctx)
  local test_state = ctx.storage.enemy_builder_test
  local snapshot_run = test_state and test_state.snapshot_run or nil
  if not snapshot_run or snapshot_run.completed then
    return
  end

  if not snapshot_run.started_log_emitted then
    ctx.debug_log(
      "snapshot run " .. snapshot_run.case_name ..
      ": monitoring " .. tostring(#snapshot_run.tick_schedule) ..
      " checkpoints starting from tick " .. tostring(snapshot_run.manifest.start_tick or 0)
    )
    snapshot_run.started_log_emitted = true
  end

  while snapshot_run.next_snapshot_index <= #snapshot_run.tick_schedule do
    local scheduled_offset = snapshot_run.tick_schedule[snapshot_run.next_snapshot_index]
    local scheduled_tick = (snapshot_run.manifest.start_tick or 0) + scheduled_offset
    if tick < scheduled_tick then
      break
    end

    ctx.debug_log(
      "snapshot run " .. snapshot_run.case_name ..
      ": checkpoint due at tick " .. tostring(scheduled_tick) ..
      ", exporting at tick " .. tostring(tick)
    )
    export_snapshot_run_tick(snapshot_run, tick, ctx)
    snapshot_run.next_snapshot_index = snapshot_run.next_snapshot_index + 1
  end

  if tick >= snapshot_run.deadline_tick then
    if snapshot_run.last_export_tick ~= tick then
      export_snapshot_run_tick(snapshot_run, tick, ctx)
    end

    helpers.write_file(
      snapshot_run.status_file,
      "PASS " .. snapshot_run.case_name ..
      " tick=" .. tick ..
      " output_dir=" .. snapshot_run.output_dir .. "\n",
      false
    )
    snapshot_run.completed = true
    ctx.debug_log("snapshot run " .. snapshot_run.case_name .. ": completed at tick " .. tick)
  end
end

local function setup_snapshot_run(spec, ctx)
  spec = spec or {}

  ctx.ensure_debug_settings()
  ctx.ensure_production_sites()
  ctx.ensure_resource_sites()
  ctx.ensure_builder_map_markers()
  ctx.ensure_builder_force()

  local case_name = spec.case_name or "layout-snapshot"
  local snapshot_ticks = ctx.deep_copy(spec.snapshot_ticks or {3600, 7200, 14400, 28800, 43200})
  table.sort(snapshot_ticks)
  local deadline_offset_ticks = spec.deadline_offset_ticks or snapshot_ticks[#snapshot_ticks] or 43200
  local snapshot_output_name = ctx.sanitize_test_file_name(case_name)
  local game_speed = spec.game_speed or 1

  game.speed = game_speed

  ctx.storage.enemy_builder_test = {
    case_name = case_name,
    suppress_player_autospawn = spec.suppress_player_autospawn ~= false,
    snapshot_run = {
      case_name = case_name,
      description = spec.description or "Deterministic autonomous layout snapshot run",
      area = ctx.deep_copy(spec.area),
      surface_name = spec.surface_name,
      game_speed = game_speed,
      deadline_tick = game.tick + deadline_offset_ticks,
      tick_schedule = snapshot_ticks,
      next_snapshot_index = 1,
      output_dir = "enemy-builder-snapshots/" .. snapshot_output_name,
      status_file = "enemy-builder-snapshots/" .. snapshot_output_name .. ".status",
      manifest = {
        case_name = case_name,
        description = spec.description or "Deterministic autonomous layout snapshot run",
        surface_name = spec.surface_name,
        game_speed = game_speed,
        area = ctx.deep_copy(spec.area),
        start_tick = game.tick,
        entries = {}
      }
    }
  }

  ctx.debug_markers.clear()
  ctx.destroy_active_builder()
  ctx.storage.production_sites = {}
  ctx.storage.resource_sites = {}

  local surface = ctx.get_test_surface(spec)
  if not surface then
    error("enemy-builder snapshot: no valid surface available for setup")
  end

  local builder_position = ctx.clone_position(spec.builder_position or {x = 0, y = 0})
  local builder_state = ctx.spawn_builder_at_position(
    surface,
    builder_position,
    "for snapshot " .. case_name
  )

  if not builder_state then
    error("enemy-builder snapshot: failed to spawn builder")
  end

  builder_state.task_index = spec.task_index or 1
  builder_state.task_state = nil
  builder_state.scaling_active_task = nil
  builder_state.manual_goal_request = nil
  builder_state.task_retry_state = {
    counts = {},
    cooldowns = {}
  }
  builder_state.completed_scaling_milestones = ctx.deep_copy(spec.completed_scaling_milestones or {})

  for _, stack in ipairs(ctx.normalize_test_inventory(spec.inventory)) do
    local inserted_count = ctx.insert_item(builder_state.entity, stack.name, stack.count, "snapshot setup inventory")
    if inserted_count < stack.count then
      error(
        "enemy-builder snapshot: failed to seed " .. stack.name ..
        " x" .. stack.count .. "; inserted " .. inserted_count
      )
    end
  end

  if spec.mutate_builder_state then
    spec.mutate_builder_state(builder_state, surface)
  end

  ctx.set_idle(builder_state.entity)
  ctx.clear_recovery(builder_state)
  ctx.update_goal_model(builder_state, game.tick)
  ctx.update_builder_overlays(builder_state, game.tick, true)
  ctx.update_builder_map_markers(builder_state, game.tick, true)

  ctx.debug_log(
    "snapshot setup " .. case_name ..
    ": started autonomous run at " .. ctx.format_position(builder_state.entity.position) ..
    " with deadline tick " .. tostring(ctx.storage.enemy_builder_test.snapshot_run.deadline_tick)
  )

  return {
    builder_position = ctx.clone_position(builder_state.entity.position),
    deadline_tick = ctx.storage.enemy_builder_test.snapshot_run.deadline_tick,
    output_dir = ctx.storage.enemy_builder_test.snapshot_run.output_dir,
    game_speed = game_speed
  }
end

function layout_snapshot.setup_full_run_layout_snapshot_case(ctx, options)
  options = options or {}

  local surface = game.surfaces["nauvis"] or game.surfaces[1]
  if not surface then
    error("enemy-builder snapshot: nauvis surface is unavailable")
  end

  local center = {x = 0, y = 0}
  local builder_position = {x = 0, y = 0}
  local area = ctx.make_test_area(center, 128, 96)

  surface.always_day = true
  ctx.clear_test_area(surface, area)

  ctx.create_test_resource_patch(surface, "coal", {x = -44, y = -10}, 6, 9000)
  ctx.create_test_resource_patch(surface, "iron-ore", {x = 26, y = 2}, 8, 10000)
  ctx.create_test_resource_patch(surface, "copper-ore", {x = 58, y = 34}, 7, 10000)
  ctx.create_test_resource_patch(surface, "stone", {x = -6, y = 48}, 5, 9000)
  ctx.create_test_resource_patch(surface, "iron-ore", {x = 78, y = -34}, 6, 9000)
  ctx.create_test_resource_patch(surface, "coal", {x = -82, y = 28}, 4, 8000)

  create_test_tree_cluster(surface, {x = 4, y = 22}, 18, 10, 2, "tree-08")
  create_test_tree_cluster(surface, {x = -30, y = 34}, 12, 8, 2, "tree-09")
  create_test_rock_cluster(surface, {x = 10, y = 26}, 10, 8, 2)
  create_test_rock_cluster(surface, {x = -18, y = 42}, 8, 6, 2)

  local default_snapshot_ticks = {600, 1200, 2400, 3600, 4800}
  local snapshot_ticks = parse_snapshot_ticks_csv(options.snapshot_ticks_csv) or ctx.deep_copy(default_snapshot_ticks)
  local default_deadline_offset_ticks = snapshot_ticks[#snapshot_ticks] or 4800
  local requested_duration_ticks = parse_positive_integer(options.duration_ticks)
  local deadline_offset_ticks = math.max(requested_duration_ticks or default_deadline_offset_ticks, default_deadline_offset_ticks)
  local game_speed = parse_positive_number(options.game_speed) or 1

  return setup_snapshot_run({
    case_name = "full_run_layout_snapshot",
    description = "Autonomous deterministic builder run with curated nearby resource patches",
    builder_position = builder_position,
    surface_name = surface.name,
    area = area,
    suppress_player_autospawn = true,
    snapshot_ticks = snapshot_ticks,
    deadline_offset_ticks = deadline_offset_ticks,
    game_speed = game_speed,
    inventory = {
      {name = "burner-mining-drill", count = 1},
      {name = "wooden-chest", count = 1},
      {name = "stone-furnace", count = 2},
      {name = "coal", count = 96},
      {name = "wood", count = 20},
      {name = "iron-plate", count = 32},
      {name = "copper-plate", count = 16}
    }
  }, ctx)
end

return layout_snapshot

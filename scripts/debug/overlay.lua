local goal_tree = require("scripts.goal_tree")
local maintenance_runner = require("scripts.maintenance_runner")

local overlay = {}

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

local function get_overlay_settings(context)
  return context.builder_data.ui and context.builder_data.ui.overlay or {}
end

local function overlay_enabled(context)
  return get_overlay_settings(context).enabled ~= false
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

local function ensure_inventory_overlay(player, context)
  local settings = get_overlay_settings(context)
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

function overlay.destroy_for_player(player)
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

function overlay.get_activity_summary(builder_state, tick, context)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return "Enemy Builder: inactive"
  end

  return "Activity: " .. goal_tree.get_activity_line(context.build_runtime_snapshot(builder_state, tick))
end

function overlay.get_goal_summary(builder_state, tick, context)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return "Goal: inactive"
  end

  local root = builder_state.goal_model_root
  if not root then
    context.update_goal_model(builder_state, tick)
    root = builder_state.goal_model_root
  end
  if not root then
    return "Goal: inactive"
  end

  return "Goal: " .. goal_tree.get_root_goal_line(root)
end

function overlay.get_inventory_lines(builder_state, context)
  if not (builder_state and builder_state.entity and builder_state.entity.valid) then
    return {"builder unavailable"}
  end

  local inventory = context.get_builder_main_inventory(builder_state.entity)
  if not inventory then
    return {"inventory unavailable"}
  end

  local item_stacks = context.get_sorted_item_stacks(inventory.get_contents())
  if #item_stacks == 0 then
    return {"(empty)"}
  end

  local settings = get_overlay_settings(context)
  local max_lines = settings.max_inventory_lines or #item_stacks
  local lines = {}

  for index, item_stack in ipairs(item_stacks) do
    if index > max_lines then
      lines[#lines + 1] = "... +" .. (#item_stacks - max_lines) .. " more"
      break
    end

    lines[#lines + 1] = context.format_item_stack_name(item_stack) .. ": " .. item_stack.count
  end

  return lines
end

function overlay.update_for_player(player, builder_state, tick, context)
  if not (player and player.valid and player.connected) then
    return
  end

  if not overlay_enabled(context) then
    overlay.destroy_for_player(player)
    return
  end

  local settings = get_overlay_settings(context)
  local screen_size = get_player_screen_size(player)
  local status_root = ensure_status_overlay(player)
  local inventory_root = ensure_inventory_overlay(player, context)
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

  goal_label.caption = overlay.get_goal_summary(builder_state, tick, context)
  status_label.caption = overlay.get_activity_summary(builder_state, tick, context)
  local path_lines = builder_state and builder_state.goal_path_lines or {}
  local blocker_lines = builder_state and builder_state.goal_blocker_lines or {}
  local maintenance_lines = maintenance_runner.get_recent_action_lines(builder_state or {}, 4)
  path_label.caption = "Path:\n" .. (#path_lines > 0 and table.concat(path_lines, "\n") or "(none)")
  blockers_label.caption = "Blockers:\n" .. (#blocker_lines > 0 and table.concat(blocker_lines, "\n") or "(none)")
  maintenance_label.caption = "Maintenance:\n" .. (#maintenance_lines > 0 and table.concat(maintenance_lines, "\n") or "(none)")
  inventory_title.caption = "Enemy Builder Inventory"
  inventory_label.caption = table.concat(overlay.get_inventory_lines(builder_state, context), "\n")
end

function overlay.update_all(builder_state, tick, force_update, context)
  if not overlay_enabled(context) then
    for _, player in pairs(game.connected_players) do
      overlay.destroy_for_player(player)
    end
    return
  end

  local settings = get_overlay_settings(context)
  local interval_ticks = settings.update_interval_ticks or 15
  if not force_update and (tick % interval_ticks) ~= 0 then
    return
  end

  if builder_state then
    context.update_goal_model(builder_state, tick)
  end

  for _, player in pairs(game.connected_players) do
    overlay.update_for_player(player, builder_state, tick, context)
  end
end

return overlay

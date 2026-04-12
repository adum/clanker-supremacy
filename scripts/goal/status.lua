local common = require("scripts.goal.common")
local instances = require("scripts.goal.instances")

local status = {}

function status.get_task_phase_status(snapshot)
  local task_state = snapshot.task_state or {}
  local phase = task_state.phase

  if phase == "waiting-for-resource" or phase == "waiting-for-source" or phase == "scaling-waiting" or phase == "scaling-waiting-at-site" then
    return "blocked"
  end

  if phase == "moving" or phase == "moving-to-source" or phase == "moving-to-resource" or
    phase == "building" or phase == "post-place-pause" or phase == "build-complete" or
    phase == "harvesting" or phase == "scaling-moving-to-site" or
    phase == "scaling-collecting-site" or phase == "scaling-crafting"
  then
    return "running"
  end

  return "ready"
end

function status.derive_action_summary(snapshot)
  local task = snapshot.display_task
  local task_state = snapshot.task_state or {}

  if not task then
    return "Planning next goal"
  end

  if task_state.phase == "scaling-crafting" and task_state.craft_item_name then
    return "Craft " .. common.humanize_identifier(task_state.craft_item_name)
  end

  if task_state.phase == "scaling-moving-to-site" and task_state.target_item_name then
    if task_state.collection_mode == "wait-patrol" then
      return "Patrol sites for " .. common.humanize_identifier(task_state.target_item_name)
    end
    return "Move to collect " .. common.humanize_identifier(task_state.target_item_name)
  end

  if task_state.phase == "scaling-collecting-site" and task_state.target_item_name then
    if task_state.collection_mode == "wait-patrol" then
      return "Patrol collection for " .. common.humanize_identifier(task_state.target_item_name)
    end
    return "Collect " .. common.humanize_identifier(task_state.target_item_name)
  end

  if task_state.phase == "moving-to-resource" and task.resource_name then
    return "Move to " .. common.humanize_identifier(task.resource_name)
  end

  if task_state.phase == "moving-to-source" and task_state.target_item_name then
    return "Move to gather " .. common.humanize_identifier(task_state.target_item_name)
  end

  if task_state.phase == "moving-to-source" and task_state.clear_obstacle_label then
    return "Move to clear " .. common.humanize_identifier(task_state.clear_obstacle_label) .. " obstacle"
  end

  if task_state.phase == "harvesting" and task_state.target_item_name then
    return "Gather " .. common.humanize_identifier(task_state.target_item_name)
  end

  if task_state.phase == "harvesting" and task_state.clear_obstacle_label then
    return "Clear " .. common.humanize_identifier(task_state.clear_obstacle_label) .. " obstacle"
  end

  if task_state.phase == "building" or task_state.phase == "post-place-pause" or task_state.phase == "build-complete" then
    if task.type == "place-miner-on-resource" then
      return "Place " .. common.humanize_identifier(task.pattern_name or task.resource_name or task.id)
    end

    if task.type == "place-machine-near-site" or task.type == "place-layout-near-machine" then
      return "Build " .. common.humanize_identifier(task.scaling_pattern_name or task.id)
    end
  end

  return common.humanize_identifier(task.id or task.type or "task")
end

local function collect_active_path(node, lines)
  if not node then
    return
  end

  if node.active or node.id == "root" then
    lines[#lines + 1] = node.title
  end

  for _, child in ipairs(node.children or {}) do
    if child.active then
      collect_active_path(child, lines)
      return
    end
  end
end

local function collect_blockers(node, blockers)
  for _, blocker in ipairs(node.blockers or {}) do
    blockers[#blockers + 1] = blocker
  end

  for _, child in ipairs(node.children or {}) do
    if child.active then
      collect_blockers(child, blockers)
    end
  end
end

local function format_tree_node_lines(node, depth, lines, active_only)
  if not node then
    return
  end

  if not active_only or node.active or depth == 0 then
    local indent = string.rep("  ", depth)
    local prefix = node.active and "*" or "-"
    lines[#lines + 1] = indent .. prefix .. " [" .. node.status .. "] " .. node.title
    for _, blocker in ipairs(node.blockers or {}) do
      lines[#lines + 1] = indent .. "  " .. "! " .. instances.blocker_message(blocker)
    end
  end

  for _, child in ipairs(node.children or {}) do
    if not active_only or child.active then
      format_tree_node_lines(child, depth + 1, lines, active_only)
    end
  end
end

function status.format_tree_lines(root, active_only)
  local lines = {}
  format_tree_node_lines(root, 0, lines, active_only == true)
  return lines
end

function status.get_active_path_lines(root)
  local lines = {}
  collect_active_path(root, lines)
  return lines
end

function status.get_blockers(root)
  local blockers = {}
  collect_blockers(root, blockers)
  return blockers
end

function status.get_blocker_lines(root)
  local lines = {}
  for _, blocker in ipairs(status.get_blockers(root)) do
    lines[#lines + 1] = instances.blocker_message(blocker)
  end
  return lines
end

function status.get_root_goal_line(root)
  if not root or not root.children or #root.children == 0 then
    return "No Goal"
  end

  for _, child in ipairs(root.children) do
    if child.active or child.status == "running" or child.status == "blocked" then
      return child.title
    end
  end

  for _, child in ipairs(root.children) do
    if child.status ~= "completed" then
      return child.title
    end
  end

  return root.children[1].title
end

function status.get_activity_line(snapshot)
  return status.derive_action_summary(snapshot)
end

return status

local common = require("scripts.goal.common")
local instances = require("scripts.goal.instances")
local predicates = require("scripts.goal.predicates")
local recovery = require("scripts.goal.recovery")
local status = require("scripts.goal.status")

local goal_tree = {}

local function get_item_count(snapshot, adapter, item_name)
  if not snapshot.entity then
    return 0
  end

  return adapter.get_item_count(snapshot.entity, item_name)
end

local function build_item_requirement_node(builder_data, snapshot, adapter, item_name, target_count, active_context, seen_items)
  local requirement_id = item_name .. ":" .. tostring(target_count)
  local node = instances.new_node(
    "require-item-" .. requirement_id,
    "Have " .. common.humanize_identifier(item_name) .. " x" .. tostring(target_count),
    "pending"
  )

  local current_count = get_item_count(snapshot, adapter, item_name)
  node.meta.item_name = item_name
  node.meta.target_count = target_count
  node.meta.current_count = current_count
  node.title = node.title .. " (" .. tostring(current_count) .. "/" .. tostring(target_count) .. ")"

  if current_count >= target_count then
    node.status = "completed"
    return node
  end

  if active_context.item_name == item_name and (active_context.kind == "craft" or active_context.kind == "collect" or active_context.kind == "gather") then
    node.status = active_context.status or "running"
    node.active = true
  else
    node.status = "ready"
  end

  seen_items = seen_items or {}
  if seen_items[item_name] then
    instances.add_blocker(
      node,
      instances.make_blocker(
        "cycle-detected",
        "cycle detected while expanding " .. common.humanize_identifier(item_name),
        {item_name = item_name}
      )
    )
    node.status = "blocked"
    return node
  end

  local next_seen_items = common.deep_copy(seen_items)
  next_seen_items[item_name] = true

  local recipe = adapter.get_recipe(item_name)
  if recipe then
    local result_count = recipe.result_count or 1
    local craft_runs = math.ceil((target_count - current_count) / result_count)
    local craft_node = instances.add_child(
      node,
      instances.new_node(
        "craft-" .. item_name,
        "Craft " .. common.humanize_identifier(item_name) .. " (" .. tostring(craft_runs) .. " run(s))",
        active_context.kind == "craft" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
      )
    )

    for _, ingredient in ipairs(recipe.ingredients or {}) do
      instances.add_child(
        craft_node,
        build_item_requirement_node(
          builder_data,
          snapshot,
          adapter,
          ingredient.name,
          ingredient.count * craft_runs,
          active_context,
          next_seen_items
        )
      )
    end

    return node
  end

  local producer = builder_data.scaling and builder_data.scaling.collect_ingredient_producers and
    builder_data.scaling.collect_ingredient_producers[item_name]
  if producer and producer.pattern_name then
    local current_site_count = (snapshot.resource_site_counts and snapshot.resource_site_counts[producer.pattern_name]) or 0
    local minimum_site_count = producer.minimum_site_count or 1
    local producer_pattern = predicates.get_pattern(builder_data, producer.pattern_name)
    local producer_node = instances.add_child(
      node,
      instances.new_node(
        "producer-" .. item_name,
        "Produce via " .. (producer_pattern and producer_pattern.display_name or common.humanize_identifier(producer.pattern_name)),
        current_site_count >= minimum_site_count and "ready" or "blocked"
      )
    )

    producer_node.title = producer_node.title .. " (" .. tostring(current_site_count) .. "/" .. tostring(minimum_site_count) .. " site(s))"
    if current_site_count < minimum_site_count then
      instances.add_blocker(
        producer_node,
        instances.make_blocker(
          "need-additional-sites",
          "need additional " .. (producer_pattern and producer_pattern.display_name or common.humanize_identifier(producer.pattern_name)) .. " sites",
          {
            pattern_name = producer.pattern_name,
            current_count = current_site_count,
            target_count = minimum_site_count
          }
        )
      )

      for _, requirement in ipairs((producer_pattern and producer_pattern.required_items) or {}) do
        instances.add_child(
          producer_node,
          build_item_requirement_node(
            builder_data,
            snapshot,
            adapter,
            requirement.name,
            requirement.count,
            active_context,
            next_seen_items
          )
        )
      end
    end

    return node
  end

  if item_name == "wood" or item_name == "stone" then
    instances.add_child(
      node,
      instances.new_node(
        "gather-" .. item_name,
        "Gather " .. common.humanize_identifier(item_name) .. " from world",
        active_context.kind == "gather" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
      )
    )
    return node
  end

  instances.add_child(
    node,
    instances.new_node(
      "collect-" .. item_name,
      "Collect " .. common.humanize_identifier(item_name) .. " from existing sites",
      active_context.kind == "collect" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
    )
  )

  return node
end

local function build_requirements_node(builder_data, snapshot, adapter, title, required_items, active_context)
  local node = instances.new_node("requirements-" .. title:gsub("%s+", "-"):lower(), title, "ready")
  local child_statuses = {}

  for _, requirement in ipairs(required_items or {}) do
    local child = build_item_requirement_node(
      builder_data,
      snapshot,
      adapter,
      requirement.name,
      requirement.count,
      active_context,
      {}
    )
    child_statuses[child.status] = true
    instances.add_child(node, child)
  end

  if next(node.children) == nil then
    node.status = "completed"
    return node
  end

  if child_statuses.blocked then
    node.status = "blocked"
  elseif child_statuses.running then
    node.status = "running"
    node.active = true
  elseif child_statuses.ready then
    node.status = "ready"
  else
    node.status = "completed"
  end

  return node
end

local function get_active_context(snapshot)
  local task = snapshot.display_task
  local task_state = snapshot.task_state or {}
  local context = {
    kind = nil,
    item_name = nil,
    status = status.get_task_phase_status(snapshot)
  }

  if task_state.phase == "scaling-crafting" and task_state.craft_item_name then
    context.kind = "craft"
    context.item_name = task_state.craft_item_name
    return context
  end

  if (task_state.phase == "scaling-moving-to-site" or task_state.phase == "scaling-collecting-site" or task_state.phase == "scaling-waiting-at-site") and task_state.target_item_name then
    context.kind = "collect"
    context.item_name = task_state.target_item_name
    return context
  end

  if (task_state.phase == "moving-to-source" or task_state.phase == "harvesting") and task_state.target_item_name then
    context.kind = "gather"
    context.item_name = task_state.target_item_name
    return context
  end

  if task and task.scaling_pattern_name then
    context.kind = "pattern"
    context.pattern_name = task.scaling_pattern_name
    return context
  end

  if task and task.completed_scaling_milestone_name then
    context.kind = "milestone"
    context.milestone_name = task.completed_scaling_milestone_name
    return context
  end

  if task and task.repeatable_scaling_milestone_name then
    context.kind = "milestone"
    context.milestone_name = task.repeatable_scaling_milestone_name
    return context
  end

  if snapshot.manual_goal_request then
    context.kind = "manual"
    context.manual_goal_id = snapshot.manual_goal_request.id
    return context
  end

  return context
end

local function build_bootstrap_goal(builder_data, snapshot)
  local bootstrap_plan = builder_data.plans and builder_data.plans.bootstrap
  if not bootstrap_plan then
    return nil
  end

  local node = instances.new_node("bootstrap", bootstrap_plan.display_name or "Bootstrap Base", "pending")
  local tasks = bootstrap_plan.tasks or {}
  local current_index = snapshot.task_index or 1
  local current_task = snapshot.active_task
  local active_status = status.get_task_phase_status(snapshot)
  local runtime_blockers = recovery.derive_runtime_blockers(snapshot)
  local has_running_child = false

  for index, task in ipairs(tasks) do
    local child_status = "pending"
    if index < current_index then
      child_status = "completed"
    elseif index == current_index and current_task and task.id == current_task.id then
      child_status = active_status
      has_running_child = true
    end

    local child = instances.new_node(
      "bootstrap-task-" .. tostring(index),
      task.id and common.humanize_identifier(task.id) or common.humanize_identifier(task.pattern_name or task.resource_name or task.type),
      child_status
    )

    if index == current_index and current_task and task.id == current_task.id then
      child.active = true
      for _, blocker in ipairs(runtime_blockers) do
        instances.add_blocker(child, blocker)
      end
      instances.add_child(
        child,
        instances.new_node("bootstrap-action-" .. tostring(index), status.derive_action_summary(snapshot), child_status)
      )
    end

    instances.add_child(node, child)
  end

  if current_index > #tasks then
    node.status = "completed"
  elseif has_running_child then
    node.status = active_status
    node.active = true
  else
    node.status = "ready"
  end

  return node
end

local function milestone_is_completed(snapshot, milestone)
  return snapshot.completed_scaling_milestones and snapshot.completed_scaling_milestones[milestone.name] == true
end

local function milestone_thresholds_met(snapshot, adapter, milestone)
  if not snapshot.entity then
    return false
  end

  return predicates.milestone_thresholds_met(snapshot.entity, adapter.get_item_count, milestone)
end

local function build_milestone_node(builder_data, snapshot, adapter, milestone)
  local is_completed = milestone_is_completed(snapshot, milestone)
  local active_task = snapshot.display_task
  local active = active_task and
    (active_task.completed_scaling_milestone_name == milestone.name or active_task.repeatable_scaling_milestone_name == milestone.name)

  local node_status = "pending"
  if active then
    node_status = status.get_task_phase_status(snapshot)
  elseif is_completed and not milestone.repeat_when_eligible then
    node_status = "completed"
  elseif milestone_thresholds_met(snapshot, adapter, milestone) then
    node_status = "ready"
  end

  local node = instances.new_node("milestone-" .. milestone.name, milestone.display_name or common.humanize_identifier(milestone.name), node_status)
  if active then
    node.active = true
    for _, blocker in ipairs(recovery.derive_runtime_blockers(snapshot)) do
      instances.add_blocker(node, blocker)
    end
  end

  if milestone.inventory_thresholds and #milestone.inventory_thresholds > 0 then
    local threshold_node = instances.new_node("milestone-thresholds-" .. milestone.name, "Thresholds", "ready")
    local threshold_statuses = {}
    for _, threshold in ipairs(milestone.inventory_thresholds) do
      local count = snapshot.entity and adapter.get_item_count(snapshot.entity, threshold.name) or 0
      local threshold_child = instances.new_node(
        "milestone-threshold-" .. threshold.name,
        "Have " .. common.humanize_identifier(threshold.name) .. " x" .. tostring(threshold.count) .. " (" .. tostring(count) .. "/" .. tostring(threshold.count) .. ")",
        count >= threshold.count and "completed" or "pending"
      )
      threshold_statuses[threshold_child.status] = true
      instances.add_child(threshold_node, threshold_child)
    end

    threshold_node.status = threshold_statuses.pending and "pending" or "completed"
    instances.add_child(node, threshold_node)
  end

  if milestone.required_items and #milestone.required_items > 0 then
    instances.add_child(node, build_requirements_node(builder_data, snapshot, adapter, "Requirements", milestone.required_items, get_active_context(snapshot)))
  end

  return node
end

local function build_pattern_node(builder_data, snapshot, adapter, pattern_name)
  local pattern = predicates.get_pattern(builder_data, pattern_name)
  local active_task = snapshot.display_task
  local active = active_task and active_task.scaling_pattern_name == pattern_name
  local blockers = predicates.get_unlock_blockers(builder_data, snapshot, pattern_name)
  local node_status = "ready"

  if #blockers > 0 then
    node_status = "blocked"
  end
  if active then
    node_status = status.get_task_phase_status(snapshot)
  end

  local site_count = (snapshot.resource_site_counts and snapshot.resource_site_counts[pattern_name]) or 0
  local node = instances.new_node(
    "pattern-" .. pattern_name,
    (pattern and pattern.display_name or common.humanize_identifier(pattern_name)) .. " (" .. tostring(site_count) .. " site(s))",
    node_status
  )

  for _, blocker in ipairs(blockers) do
    instances.add_blocker(node, blocker)
  end

  if active then
    node.active = true
    for _, blocker in ipairs(recovery.derive_runtime_blockers(snapshot)) do
      instances.add_blocker(node, blocker)
    end
  end

  if pattern and pattern.required_items and #pattern.required_items > 0 then
    instances.add_child(node, build_requirements_node(builder_data, snapshot, adapter, "Requirements", pattern.required_items, get_active_context(snapshot)))
  end

  return node
end

local function build_scaling_goal(builder_data, snapshot, adapter)
  if not builder_data.scaling or not builder_data.scaling.enabled then
    return nil
  end

  local node = instances.new_node("scale-production", "Scale Production", "ready")
  local active_task = snapshot.display_task

  local milestones_root = instances.add_child(node, instances.new_node("scaling-milestones", "Milestones", "ready"))
  local milestones_statuses = {}
  for _, milestone in ipairs(builder_data.scaling.production_milestones or {}) do
    local child = build_milestone_node(builder_data, snapshot, adapter, milestone)
    milestones_statuses[child.status] = true
    instances.add_child(milestones_root, child)
  end
  milestones_root.status = milestones_statuses.running and "running" or milestones_statuses.ready and "ready" or milestones_statuses.completed and "completed" or "pending"

  local patterns_root = instances.add_child(node, instances.new_node("scaling-patterns", "Expansion Patterns", "ready"))
  local pattern_statuses = {}
  for _, pattern_name in ipairs((builder_data.scaling and builder_data.scaling.cycle_pattern_names) or {}) do
    local child = build_pattern_node(builder_data, snapshot, adapter, pattern_name)
    pattern_statuses[child.status] = true
    instances.add_child(patterns_root, child)
  end
  patterns_root.status = pattern_statuses.running and "running" or pattern_statuses.ready and "ready" or pattern_statuses.blocked and "blocked" or "pending"

  if active_task then
    node.status = status.get_task_phase_status(snapshot)
    node.active = true
    for _, blocker in ipairs(recovery.derive_runtime_blockers(snapshot)) do
      instances.add_blocker(node, blocker)
    end
  elseif snapshot.task_state and snapshot.task_state.phase then
    node.status = status.get_task_phase_status(snapshot)
    node.active = true
  elseif milestones_statuses.ready or pattern_statuses.ready then
    node.status = "ready"
  else
    node.status = "pending"
  end

  return node
end

local function build_manual_goal(builder_data, snapshot, adapter)
  local request = snapshot.manual_goal_request
  if not request then
    return nil
  end

  local node = instances.new_node("manual-goal-" .. tostring(request.id or "request"), "Manual Goal: " .. (request.display_name or common.humanize_identifier(request.component_name or "request")), "ready")
  node.active = true

  if request.requested_position then
    node.meta.requested_position = request.requested_position
    node.title = node.title .. " at " .. common.format_position(request.requested_position)
  end

  local component = predicates.get_component_spec(builder_data, request.component_name or "")
  if component and component.required_items and #component.required_items > 0 then
    instances.add_child(node, build_requirements_node(builder_data, snapshot, adapter, "Requirements", component.required_items, get_active_context(snapshot)))
  end

  local current_index = request.current_task_index or 1
  local current_task = request.tasks and request.tasks[current_index] or nil
  local active_status = status.get_task_phase_status(snapshot)
  local runtime_blockers = recovery.derive_runtime_blockers(snapshot)

  for index, task in ipairs(request.tasks or {}) do
    local child_status = "pending"
    if index < current_index then
      child_status = "completed"
    elseif current_task and task.id == current_task.id then
      child_status = active_status
    end

    local child = instances.new_node(
      "manual-task-" .. tostring(index),
      common.humanize_identifier(task.manual_component_name or task.scaling_pattern_name or task.pattern_name or task.id or task.type),
      child_status
    )

    if current_task and task.id == current_task.id then
      child.active = true
      for _, blocker in ipairs(runtime_blockers) do
        instances.add_blocker(child, blocker)
      end
      instances.add_child(child, instances.new_node("manual-action-" .. tostring(index), status.derive_action_summary(snapshot), child_status))
    end

    instances.add_child(node, child)
  end

  node.status = current_task and active_status or "completed"
  for _, blocker in ipairs(runtime_blockers) do
    instances.add_blocker(node, blocker)
  end

  return node
end

function goal_tree.build_runtime_tree(builder_data, snapshot, adapter)
  local root = instances.new_node("root", "Operate Builder", "ready")
  root.active = true

  if snapshot.builder_missing then
    root.status = "blocked"
    instances.add_blocker(root, instances.make_blocker("builder-missing", "builder entity is missing"))
    return root
  end

  local manual_goal = build_manual_goal(builder_data, snapshot, adapter)
  if manual_goal then
    instances.add_child(root, manual_goal)
  end

  local bootstrap_goal = build_bootstrap_goal(builder_data, snapshot, adapter)
  if bootstrap_goal then
    instances.add_child(root, bootstrap_goal)
  end

  local scaling_goal = build_scaling_goal(builder_data, snapshot, adapter)
  if scaling_goal then
    instances.add_child(root, scaling_goal)
  end

  if manual_goal then
    root.status = manual_goal.status
    manual_goal.active = true
  elseif bootstrap_goal and bootstrap_goal.status ~= "completed" then
    root.status = bootstrap_goal.status
    bootstrap_goal.active = true
  elseif scaling_goal then
    root.status = scaling_goal.status
    scaling_goal.active = true
  else
    root.status = "completed"
  end

  return root
end

function goal_tree.format_tree_lines(root, active_only)
  return status.format_tree_lines(root, active_only)
end

function goal_tree.get_active_path_lines(root)
  return status.get_active_path_lines(root)
end

function goal_tree.get_blockers(root)
  return status.get_blockers(root)
end

function goal_tree.get_blocker_lines(root)
  return status.get_blocker_lines(root)
end

function goal_tree.get_root_goal_line(root)
  return status.get_root_goal_line(root)
end

function goal_tree.get_activity_line(snapshot)
  return status.get_activity_line(snapshot)
end

function goal_tree.instantiate_manual_request(builder_data, component_name, position)
  local component = predicates.get_component_spec(builder_data, component_name)
  if not component then
    return nil, "unknown component '" .. tostring(component_name) .. "'"
  end

  local snapped_position = position and common.snap_to_tile_center(position) or nil
  local request = {
    id = (game and game.tick or 0) .. "-" .. component.id,
    component_name = component.id,
    display_name = component.display_name,
    requested_position = common.clone_position(snapped_position or position),
    current_task_index = 1,
    tasks = {}
  }

  for index, task in ipairs(component.tasks or {}) do
    local instance = common.deep_copy(task)
    instance.id = "manual-" .. component.id .. "-" .. tostring(index) .. "-" .. (instance.id or instance.type or "task")
    instance.manual_goal_id = request.id
    instance.manual_component_name = component.id
    instance.manual_search_origin = common.clone_position(snapped_position or position)
    if snapped_position then
      if instance.type == "place-machine-near-site" then
        instance.manual_target_position = common.clone_position(snapped_position)
      end

      if instance.type == "place-assembly-block" then
        instance.manual_target_position = common.clone_position(snapped_position)
        instance.manual_target_search_radius = instance.placement_search_radius or 6
      end

      if instance.type == "place-layout-near-machine" then
        instance.manual_anchor_position = common.clone_position(snapped_position)
        instance.manual_anchor_search_radius = 16
      end
    end
    request.tasks[#request.tasks + 1] = instance
  end

  return request
end

function goal_tree.describe_plan_preview(builder_data, snapshot, adapter, component_name, position)
  local component = predicates.get_component_spec(builder_data, component_name)
  if not component then
    return nil, "unknown component '" .. tostring(component_name) .. "'"
  end

  local plan_snapshot = {
    entity = snapshot.entity,
    task_state = nil,
    display_task = nil,
    resource_site_counts = snapshot.resource_site_counts,
    completed_scaling_milestones = snapshot.completed_scaling_milestones,
    manual_goal_request = {
      id = "preview",
      component_name = component.id,
      display_name = component.display_name,
      requested_position = common.clone_position(position),
      current_task_index = 1,
      tasks = common.deep_copy(component.tasks)
    }
  }

  local root = build_manual_goal(builder_data, plan_snapshot, adapter)
  local lines = {
    "Plan: " .. component.display_name .. (position and " at " .. common.format_position(position) or ""),
    "Status: " .. root.status
  }

  local tree_lines = goal_tree.format_tree_lines(root, false)
  for _, line in ipairs(tree_lines) do
    lines[#lines + 1] = line
  end

  local blockers = goal_tree.get_blocker_lines(root)
  if #blockers > 0 then
    lines[#lines + 1] = "Blockers:"
    for _, blocker in ipairs(blockers) do
      lines[#lines + 1] = "- " .. blocker
    end
  end

  return lines
end

function goal_tree.list_component_names(builder_data)
  return predicates.list_component_names(builder_data)
end

return goal_tree

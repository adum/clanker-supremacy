local goal_tree = {}

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
  if not position then
    return nil
  end

  return {
    x = position.x,
    y = position.y
  }
end

local function humanize_identifier(identifier)
  if not identifier or identifier == "" then
    return "Unknown"
  end

  local words = {}
  for word in string.gmatch(identifier:gsub("[_-]+", " "), "%S+") do
    words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
  end

  return table.concat(words, " ")
end

local function format_position(position)
  if not position then
    return "(?, ?)"
  end

  return string.format("(%.2f, %.2f)", position.x, position.y)
end

local function new_node(id, title, status)
  return {
    id = id,
    title = title,
    status = status or "pending",
    blockers = {},
    children = {},
    active = false,
    meta = {}
  }
end

local function add_child(parent, child)
  if child then
    parent.children[#parent.children + 1] = child
  end
  return child
end

local function add_blocker(node, blocker)
  if blocker and blocker ~= "" then
    node.blockers[#node.blockers + 1] = blocker
  end
end

local function merge_required_items(requirements_a, requirements_b)
  local by_name = {}

  local function add_requirements(requirements)
    for _, requirement in ipairs(requirements or {}) do
      by_name[requirement.name] = (by_name[requirement.name] or 0) + (requirement.count or 0)
    end
  end

  add_requirements(requirements_a)
  add_requirements(requirements_b)

  local merged = {}
  for name, count in pairs(by_name) do
    merged[#merged + 1] = {
      name = name,
      count = count
    }
  end

  table.sort(merged, function(left, right)
    return left.name < right.name
  end)

  return merged
end

local function get_pattern(builder_data, pattern_name)
  return builder_data.site_patterns and builder_data.site_patterns[pattern_name] or nil
end

local function get_milestone(builder_data, milestone_name)
  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    if milestone.name == milestone_name then
      return milestone
    end
  end

  return nil
end

local function list_component_names(builder_data)
  local names = {}

  for pattern_name in pairs(builder_data.site_patterns or {}) do
    names[#names + 1] = pattern_name
  end

  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    names[#names + 1] = milestone.name
  end

  names[#names + 1] = "firearm_magazine_site"
  table.sort(names)
  return names
end

local function get_component_spec(builder_data, component_name)
  local pattern = get_pattern(builder_data, component_name)
  if pattern and pattern.build_task then
    return {
      id = component_name,
      display_name = pattern.display_name or humanize_identifier(component_name),
      required_items = deep_copy(pattern.required_items or {}),
      tasks = {
        deep_copy(pattern.build_task)
      }
    }
  end

  local milestone = get_milestone(builder_data, component_name)
  if milestone and milestone.task then
    return {
      id = component_name,
      display_name = milestone.display_name or humanize_identifier(component_name),
      required_items = deep_copy(milestone.required_items or {}),
      tasks = {
        deep_copy(milestone.task)
      }
    }
  end

  if component_name == "firearm_magazine_site" then
    local assembler_milestone = get_milestone(builder_data, "firearm-magazine-assembler")
    local defense_milestone = get_milestone(builder_data, "firearm-magazine-defense")
    if assembler_milestone and defense_milestone then
      return {
        id = component_name,
        display_name = "Firearm Magazine Site",
        required_items = merge_required_items(assembler_milestone.required_items, defense_milestone.required_items),
        tasks = {
          deep_copy(assembler_milestone.task),
          deep_copy(defense_milestone.task)
        }
      }
    end
  end

  return nil
end

local function get_unlock_blockers(builder_data, snapshot, pattern_name)
  local blockers = {}
  local unlock = builder_data.scaling and builder_data.scaling.pattern_unlocks and builder_data.scaling.pattern_unlocks[pattern_name]
  if not unlock then
    return blockers
  end

  for dependency_name, minimum_count in pairs(unlock.minimum_site_counts or {}) do
    local current_count = (snapshot.resource_site_counts and snapshot.resource_site_counts[dependency_name]) or 0
    if current_count < minimum_count then
      blockers[#blockers + 1] = "need " .. humanize_identifier(dependency_name) .. " sites " .. current_count .. "/" .. minimum_count
    end
  end

  for _, milestone_name in ipairs(unlock.required_completed_milestones or {}) do
    if not snapshot.completed_scaling_milestones[milestone_name] then
      blockers[#blockers + 1] = "waiting for milestone " .. (get_milestone(builder_data, milestone_name) and get_milestone(builder_data, milestone_name).display_name or humanize_identifier(milestone_name))
    end
  end

  return blockers
end

local function get_task_phase_status(snapshot)
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

local function derive_runtime_blockers(snapshot)
  local blockers = {}
  local task_state = snapshot.task_state or {}

  if task_state.wait_reason then
    blockers[#blockers + 1] = humanize_identifier(task_state.wait_reason)
  end

  if snapshot.last_recovery and snapshot.last_recovery.message then
    blockers[#blockers + 1] = snapshot.last_recovery.message
  end

  return blockers
end

local function derive_action_summary(snapshot)
  local task = snapshot.display_task
  local task_state = snapshot.task_state or {}

  if not task then
    return "Planning next goal"
  end

  if task_state.phase == "scaling-crafting" and task_state.craft_item_name then
    return "Craft " .. humanize_identifier(task_state.craft_item_name)
  end

  if task_state.phase == "scaling-moving-to-site" and task_state.target_item_name then
    return "Move to collect " .. humanize_identifier(task_state.target_item_name)
  end

  if task_state.phase == "scaling-collecting-site" and task_state.target_item_name then
    return "Collect " .. humanize_identifier(task_state.target_item_name)
  end

  if task_state.phase == "moving-to-resource" and task.resource_name then
    return "Move to " .. humanize_identifier(task.resource_name)
  end

  if task_state.phase == "moving-to-source" and task_state.target_item_name then
    return "Move to gather " .. humanize_identifier(task_state.target_item_name)
  end

  if task_state.phase == "harvesting" and task_state.target_item_name then
    return "Gather " .. humanize_identifier(task_state.target_item_name)
  end

  if task_state.phase == "building" or task_state.phase == "post-place-pause" or task_state.phase == "build-complete" then
    if task.type == "place-miner-on-resource" then
      return "Place " .. humanize_identifier(task.pattern_name or task.resource_name or task.id)
    end

    if task.type == "place-machine-near-site" or task.type == "place-layout-near-machine" then
      return "Build " .. humanize_identifier(task.scaling_pattern_name or task.id)
    end
  end

  return humanize_identifier(task.id or task.type or "task")
end

local function get_item_count(snapshot, adapter, item_name)
  if not snapshot.entity then
    return 0
  end

  return adapter.get_item_count(snapshot.entity, item_name)
end

local function build_item_requirement_node(builder_data, snapshot, adapter, item_name, target_count, active_context, seen_items)
  local requirement_id = item_name .. ":" .. tostring(target_count)
  local node = new_node(
    "require-item-" .. requirement_id,
    "Have " .. humanize_identifier(item_name) .. " x" .. tostring(target_count),
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
    add_blocker(node, "cycle detected while expanding " .. humanize_identifier(item_name))
    node.status = "blocked"
    return node
  end

  local next_seen_items = deep_copy(seen_items)
  next_seen_items[item_name] = true

  local recipe = adapter.get_recipe(item_name)
  if recipe then
    local result_count = recipe.result_count or 1
    local craft_runs = math.ceil((target_count - current_count) / result_count)
    local craft_node = add_child(
      node,
      new_node(
        "craft-" .. item_name,
        "Craft " .. humanize_identifier(item_name) .. " (" .. tostring(craft_runs) .. " run(s))",
        active_context.kind == "craft" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
      )
    )

    for _, ingredient in ipairs(recipe.ingredients or {}) do
      add_child(
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
    local producer_pattern = get_pattern(builder_data, producer.pattern_name)
    local producer_node = add_child(
      node,
      new_node(
        "producer-" .. item_name,
        "Produce via " .. (producer_pattern and producer_pattern.display_name or humanize_identifier(producer.pattern_name)),
        current_site_count >= minimum_site_count and "ready" or "blocked"
      )
    )

    producer_node.title = producer_node.title .. " (" .. tostring(current_site_count) .. "/" .. tostring(minimum_site_count) .. " site(s))"
    if current_site_count < minimum_site_count then
      add_blocker(producer_node, "need additional " .. (producer_pattern and producer_pattern.display_name or humanize_identifier(producer.pattern_name)) .. " sites")
      for _, requirement in ipairs((producer_pattern and producer_pattern.required_items) or {}) do
        add_child(
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
    add_child(
      node,
      new_node(
        "gather-" .. item_name,
        "Gather " .. humanize_identifier(item_name) .. " from world",
        active_context.kind == "gather" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
      )
    )
    return node
  end

  add_child(
    node,
    new_node(
      "collect-" .. item_name,
      "Collect " .. humanize_identifier(item_name) .. " from existing sites",
      active_context.kind == "collect" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
    )
  )

  return node
end

local function build_requirements_node(builder_data, snapshot, adapter, title, required_items, active_context)
  local node = new_node("requirements-" .. title:gsub("%s+", "-"):lower(), title, "ready")
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
    add_child(node, child)
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
    status = get_task_phase_status(snapshot)
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

local function build_task_node(builder_data, snapshot, adapter, task, title, status)
  local node = new_node(task.id or task.type or title, title, status or get_task_phase_status(snapshot))

  for _, blocker in ipairs(derive_runtime_blockers(snapshot)) do
    add_blocker(node, blocker)
  end

  local required_items = nil
  if task.pattern_name then
    local pattern = get_pattern(builder_data, task.pattern_name)
    required_items = pattern and pattern.required_items or nil
  elseif task.scaling_pattern_name then
    local pattern = get_pattern(builder_data, task.scaling_pattern_name)
    required_items = pattern and pattern.required_items or nil
  end

  if required_items and #required_items > 0 then
    add_child(node, build_requirements_node(builder_data, snapshot, adapter, "Requirements", required_items, get_active_context(snapshot)))
  end

  local action_child = new_node(
    (task.id or task.type or "task") .. "-action",
    derive_action_summary(snapshot),
    get_task_phase_status(snapshot)
  )
  add_child(node, action_child)

  return node
end

local function build_bootstrap_goal(builder_data, snapshot, adapter)
  local bootstrap_plan = builder_data.plans and builder_data.plans.bootstrap
  if not bootstrap_plan then
    return nil
  end

  local node = new_node("bootstrap", bootstrap_plan.display_name or "Bootstrap Base", "pending")
  local tasks = bootstrap_plan.tasks or {}
  local current_index = snapshot.task_index or 1
  local current_task = snapshot.active_task
  local active_status = get_task_phase_status(snapshot)
  local has_running_child = false

  for index, task in ipairs(tasks) do
    local child_status = "pending"
    if index < current_index then
      child_status = "completed"
    elseif index == current_index and current_task and task.id == current_task.id then
      child_status = active_status
      has_running_child = true
    end

    local child = new_node(
      "bootstrap-task-" .. tostring(index),
      task.id and humanize_identifier(task.id) or humanize_identifier(task.pattern_name or task.resource_name or task.type),
      child_status
    )

    if index == current_index and current_task and task.id == current_task.id then
      child.active = true
      for _, blocker in ipairs(derive_runtime_blockers(snapshot)) do
        add_blocker(child, blocker)
      end
      add_child(
        child,
        new_node("bootstrap-action-" .. tostring(index), derive_action_summary(snapshot), child_status)
      )
    end

    add_child(node, child)
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

  for _, threshold in ipairs(milestone.inventory_thresholds or {}) do
    if adapter.get_item_count(snapshot.entity, threshold.name) < threshold.count then
      return false
    end
  end

  return true
end

local function build_milestone_node(builder_data, snapshot, adapter, milestone)
  local is_completed = milestone_is_completed(snapshot, milestone)
  local active_task = snapshot.display_task
  local active = active_task and
    (active_task.completed_scaling_milestone_name == milestone.name or active_task.repeatable_scaling_milestone_name == milestone.name)

  local status = "pending"
  if active then
    status = get_task_phase_status(snapshot)
  elseif is_completed and not milestone.repeat_when_eligible then
    status = "completed"
  elseif milestone_thresholds_met(snapshot, adapter, milestone) then
    status = "ready"
  end

  local node = new_node("milestone-" .. milestone.name, milestone.display_name or humanize_identifier(milestone.name), status)
  if active then
    node.active = true
    for _, blocker in ipairs(derive_runtime_blockers(snapshot)) do
      add_blocker(node, blocker)
    end
  end

  if milestone.inventory_thresholds and #milestone.inventory_thresholds > 0 then
    local threshold_node = new_node("milestone-thresholds-" .. milestone.name, "Thresholds", "ready")
    local threshold_statuses = {}
    for _, threshold in ipairs(milestone.inventory_thresholds) do
      local count = snapshot.entity and adapter.get_item_count(snapshot.entity, threshold.name) or 0
      local threshold_child = new_node(
        "milestone-threshold-" .. threshold.name,
        "Have " .. humanize_identifier(threshold.name) .. " x" .. tostring(threshold.count) .. " (" .. tostring(count) .. "/" .. tostring(threshold.count) .. ")",
        count >= threshold.count and "completed" or "pending"
      )
      threshold_statuses[threshold_child.status] = true
      add_child(threshold_node, threshold_child)
    end

    if threshold_statuses.pending then
      threshold_node.status = "pending"
    else
      threshold_node.status = "completed"
    end
    add_child(node, threshold_node)
  end

  if milestone.required_items and #milestone.required_items > 0 then
    add_child(node, build_requirements_node(builder_data, snapshot, adapter, "Requirements", milestone.required_items, get_active_context(snapshot)))
  end

  return node
end

local function build_pattern_node(builder_data, snapshot, adapter, pattern_name)
  local pattern = get_pattern(builder_data, pattern_name)
  local active_task = snapshot.display_task
  local active = active_task and active_task.scaling_pattern_name == pattern_name
  local blockers = get_unlock_blockers(builder_data, snapshot, pattern_name)
  local status = "ready"

  if #blockers > 0 then
    status = "blocked"
  end
  if active then
    status = get_task_phase_status(snapshot)
  end

  local site_count = (snapshot.resource_site_counts and snapshot.resource_site_counts[pattern_name]) or 0
  local node = new_node(
    "pattern-" .. pattern_name,
    (pattern and pattern.display_name or humanize_identifier(pattern_name)) .. " (" .. tostring(site_count) .. " site(s))",
    status
  )

  for _, blocker in ipairs(blockers) do
    add_blocker(node, blocker)
  end

  if active then
    node.active = true
    for _, blocker in ipairs(derive_runtime_blockers(snapshot)) do
      add_blocker(node, blocker)
    end
  end

  if pattern and pattern.required_items and #pattern.required_items > 0 then
    add_child(node, build_requirements_node(builder_data, snapshot, adapter, "Requirements", pattern.required_items, get_active_context(snapshot)))
  end

  return node
end

local function build_scaling_goal(builder_data, snapshot, adapter)
  if not builder_data.scaling or not builder_data.scaling.enabled then
    return nil
  end

  local node = new_node("scale-production", "Scale Production", "ready")
  local active_task = snapshot.display_task

  local milestones_root = add_child(node, new_node("scaling-milestones", "Milestones", "ready"))
  local milestones_statuses = {}
  for _, milestone in ipairs(builder_data.scaling.production_milestones or {}) do
    local child = build_milestone_node(builder_data, snapshot, adapter, milestone)
    milestones_statuses[child.status] = true
    add_child(milestones_root, child)
  end
  milestones_root.status = milestones_statuses.running and "running" or milestones_statuses.ready and "ready" or milestones_statuses.completed and "completed" or "pending"

  local patterns_root = add_child(node, new_node("scaling-patterns", "Expansion Patterns", "ready"))
  local pattern_statuses = {}
  for _, pattern_name in ipairs((builder_data.scaling and builder_data.scaling.cycle_pattern_names) or {}) do
    local child = build_pattern_node(builder_data, snapshot, adapter, pattern_name)
    pattern_statuses[child.status] = true
    add_child(patterns_root, child)
  end
  patterns_root.status = pattern_statuses.running and "running" or pattern_statuses.ready and "ready" or pattern_statuses.blocked and "blocked" or "pending"

  if active_task then
    node.status = get_task_phase_status(snapshot)
    node.active = true
    for _, blocker in ipairs(derive_runtime_blockers(snapshot)) do
      add_blocker(node, blocker)
    end
  elseif snapshot.task_state and snapshot.task_state.phase then
    node.status = get_task_phase_status(snapshot)
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

  local node = new_node("manual-goal-" .. tostring(request.id or "request"), "Manual Goal: " .. (request.display_name or humanize_identifier(request.component_name or "request")), "ready")
  node.active = true

  if request.requested_position then
    node.meta.requested_position = request.requested_position
    node.title = node.title .. " at " .. format_position(request.requested_position)
  end

  local component = get_component_spec(builder_data, request.component_name or "")
  if component and component.required_items and #component.required_items > 0 then
    add_child(node, build_requirements_node(builder_data, snapshot, adapter, "Requirements", component.required_items, get_active_context(snapshot)))
  end

  local current_index = request.current_task_index or 1
  local current_task = request.tasks and request.tasks[current_index] or nil
  local active_status = get_task_phase_status(snapshot)
  for index, task in ipairs(request.tasks or {}) do
    local child_status = "pending"
    if index < current_index then
      child_status = "completed"
    elseif current_task and task.id == current_task.id then
      child_status = active_status
    end

    local child = new_node(
      "manual-task-" .. tostring(index),
      humanize_identifier(task.manual_component_name or task.scaling_pattern_name or task.pattern_name or task.id or task.type),
      child_status
    )

    if current_task and task.id == current_task.id then
      child.active = true
      for _, blocker in ipairs(derive_runtime_blockers(snapshot)) do
        add_blocker(child, blocker)
      end
      add_child(child, new_node("manual-action-" .. tostring(index), derive_action_summary(snapshot), child_status))
    end

    add_child(node, child)
  end

  node.status = current_task and active_status or "completed"
  for _, blocker in ipairs(derive_runtime_blockers(snapshot)) do
    add_blocker(node, blocker)
  end

  return node
end

function goal_tree.build_runtime_tree(builder_data, snapshot, adapter)
  local root = new_node("root", "Operate Builder", "ready")
  root.active = true

  if snapshot.builder_missing then
    root.status = "blocked"
    add_blocker(root, "builder entity is missing")
    return root
  end

  local manual_goal = build_manual_goal(builder_data, snapshot, adapter)
  if manual_goal then
    add_child(root, manual_goal)
  end

  local bootstrap_goal = build_bootstrap_goal(builder_data, snapshot, adapter)
  if bootstrap_goal then
    add_child(root, bootstrap_goal)
  end

  local scaling_goal = build_scaling_goal(builder_data, snapshot, adapter)
  if scaling_goal then
    add_child(root, scaling_goal)
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

local function collect_blockers(node, lines)
  for _, blocker in ipairs(node.blockers or {}) do
    lines[#lines + 1] = blocker
  end

  for _, child in ipairs(node.children or {}) do
    if child.active then
      collect_blockers(child, lines)
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
      lines[#lines + 1] = indent .. "  " .. "! " .. blocker
    end
  end

  for _, child in ipairs(node.children or {}) do
    if not active_only or child.active then
      format_tree_node_lines(child, depth + 1, lines, active_only)
    end
  end
end

function goal_tree.format_tree_lines(root, active_only)
  local lines = {}
  format_tree_node_lines(root, 0, lines, active_only == true)
  return lines
end

function goal_tree.get_active_path_lines(root)
  local lines = {}
  collect_active_path(root, lines)
  return lines
end

function goal_tree.get_blocker_lines(root)
  local lines = {}
  collect_blockers(root, lines)
  return lines
end

function goal_tree.get_root_goal_line(root)
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

function goal_tree.get_activity_line(snapshot)
  return derive_action_summary(snapshot)
end

function goal_tree.instantiate_manual_request(builder_data, component_name, position)
  local component = get_component_spec(builder_data, component_name)
  if not component then
    return nil, "unknown component '" .. tostring(component_name) .. "'"
  end

  local request = {
    id = (game and game.tick or 0) .. "-" .. component.id,
    component_name = component.id,
    display_name = component.display_name,
    requested_position = clone_position(position),
    current_task_index = 1,
    tasks = {}
  }

  for index, task in ipairs(component.tasks or {}) do
    local instance = deep_copy(task)
    instance.id = "manual-" .. component.id .. "-" .. tostring(index) .. "-" .. (instance.id or instance.type or "task")
    instance.manual_goal_id = request.id
    instance.manual_component_name = component.id
    instance.manual_search_origin = clone_position(position)
    if position then
      if instance.type == "place-machine-near-site" then
        instance.manual_target_position = clone_position(position)
      end

      if instance.type == "place-layout-near-machine" then
        instance.manual_anchor_position = clone_position(position)
        instance.manual_anchor_search_radius = 16
      end
    end
    request.tasks[#request.tasks + 1] = instance
  end

  return request
end

function goal_tree.describe_plan_preview(builder_data, snapshot, adapter, component_name, position)
  local component = get_component_spec(builder_data, component_name)
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
      requested_position = clone_position(position),
      current_task_index = 1,
      tasks = deep_copy(component.tasks)
    }
  }

  local root = build_manual_goal(builder_data, plan_snapshot, adapter)
  local lines = {
    "Plan: " .. component.display_name .. (position and " at " .. format_position(position) or ""),
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
  return list_component_names(builder_data)
end

return goal_tree

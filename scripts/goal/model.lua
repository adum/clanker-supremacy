local common = require("scripts.goal.common")
local instances = require("scripts.goal.instances")
local predicates = require("scripts.goal.predicates")
local recovery = require("scripts.goal.recovery")
local specs = require("scripts.goal.specs")
local status = require("scripts.goal.status")

local model = {}
local MODEL_VERSION = 4

local function new_instance(spec_id, title, kind)
  return {
    id = spec_id,
    spec_id = spec_id,
    title = title,
    kind = kind or "action",
    status = "pending",
    blockers = {},
    children = {},
    active = false,
    active_child_id = nil,
    meta = {}
  }
end

local function find_active_execution(node)
  if not node then
    return nil
  end

  if node.active and node.meta and node.meta.execution_kind then
    return node
  end

  for _, child in ipairs(node.children or {}) do
    if child.active then
      local found = find_active_execution(child)
      if found then
        return found
      end
    end
  end

  return nil
end

local function reset_instance(instance, keep_children)
  instance.status = "pending"
  instance.blockers = {}
  instance.active = false
  instance.active_child_id = nil
  instance.meta = {}
  if not keep_children then
    instance.children = {}
  end
end

local function set_active_child(node, child_id)
  node.active_child_id = child_id
  for _, child in ipairs(node.children or {}) do
    child.active = child.id == child_id
  end
end

local function add_runtime_blockers(node, snapshot)
  for _, blocker in ipairs(recovery.derive_runtime_blockers(snapshot)) do
    instances.add_blocker(node, blocker)
  end
end

local function get_item_count(snapshot, adapter, item_name)
  if not snapshot.entity then
    return 0
  end

  return adapter.get_item_count(snapshot.entity, item_name)
end

local function any_child_status(node, expected_status)
  for _, child in ipairs(node.children or {}) do
    if child.status == expected_status then
      return true
    end
  end

  return false
end

local function finalize_group_status(node)
  if next(node.children or {}) == nil then
    node.status = "pending"
    return
  end

  if any_child_status(node, "blocked") then
    node.status = "blocked"
  elseif any_child_status(node, "running") then
    node.status = "running"
  elseif any_child_status(node, "ready") then
    node.status = "ready"
  elseif any_child_status(node, "pending") then
    node.status = "pending"
  elseif any_child_status(node, "completed") then
    node.status = "completed"
  else
    node.status = "pending"
  end
end

local function build_action_node(node_id, snapshot)
  local action_node = new_instance(node_id, status.derive_action_summary(snapshot), "action")
  action_node.status = status.get_task_phase_status(snapshot)
  action_node.active = true
  return action_node
end

local function get_active_context(snapshot)
  local task = snapshot.display_task
  local task_state = snapshot.task_state or {}
  local context = {
    kind = nil,
    item_name = nil,
    status = status.get_task_phase_status(snapshot),
    owner_kind = nil,
    pattern_name = nil,
    milestone_name = nil
  }

  if task and task.scaling_pattern_name then
    context.owner_kind = "pattern"
    context.pattern_name = task.scaling_pattern_name
  elseif task and task.completed_scaling_milestone_name then
    context.owner_kind = "milestone"
    context.milestone_name = task.completed_scaling_milestone_name
  elseif task and task.repeatable_scaling_milestone_name then
    context.owner_kind = "milestone"
    context.milestone_name = task.repeatable_scaling_milestone_name
  end

  if task_state.phase == "scaling-crafting" and task_state.craft_item_name then
    context.kind = "craft"
    context.item_name = task_state.craft_item_name
    return context
  end

  if
    (task_state.phase == "scaling-moving-to-site" or task_state.phase == "scaling-collecting-site" or task_state.phase == "scaling-waiting-at-site") and
    task_state.target_item_name
  then
    context.kind = "collect"
    context.item_name = task_state.target_item_name
    return context
  end

  if (task_state.phase == "moving-to-source" or task_state.phase == "harvesting") and task_state.target_item_name then
    context.kind = "gather"
    context.item_name = task_state.target_item_name
    return context
  end

  if context.owner_kind then
    context.kind = context.owner_kind
    return context
  end

  if snapshot.manual_goal_request then
    context.kind = "manual"
    return context
  end

  return context
end

local function build_item_requirement_node(builder_data, snapshot, adapter, item_name, target_count, active_context, seen_items)
  local requirement_id = item_name .. ":" .. tostring(target_count)
  local current_count = get_item_count(snapshot, adapter, item_name)
  local node = new_instance(
    "require-item-" .. requirement_id,
    "Have " .. common.humanize_identifier(item_name) .. " x" .. tostring(target_count) ..
      " (" .. tostring(current_count) .. "/" .. tostring(target_count) .. ")",
    "sequence"
  )

  node.meta.item_name = item_name
  node.meta.target_count = target_count
  node.meta.current_count = current_count

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
    local craft_node = new_instance(
      "craft-" .. item_name .. "-" .. tostring(craft_runs),
      "Craft " .. common.humanize_identifier(item_name) .. " (" .. tostring(craft_runs) .. " run(s))",
      "sequence"
    )
    craft_node.status =
      active_context.kind == "craft" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
    craft_node.active = active_context.kind == "craft" and active_context.item_name == item_name

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

    if craft_node.active then
      for _, child in ipairs(craft_node.children) do
        if child.active then
          craft_node.active_child_id = child.id
          break
        end
      end
      node.active_child_id = craft_node.id
    end

    finalize_group_status(craft_node)
    instances.add_child(node, craft_node)
    return node
  end

  local producer = builder_data.scaling and builder_data.scaling.collect_ingredient_producers and
    builder_data.scaling.collect_ingredient_producers[item_name]
  if producer and producer.pattern_name then
    local current_site_count = (snapshot.resource_site_counts and snapshot.resource_site_counts[producer.pattern_name]) or 0
    local minimum_site_count = producer.minimum_site_count or 1
    local producer_pattern = predicates.get_pattern(builder_data, producer.pattern_name)
    local producer_node = new_instance(
      "producer-" .. item_name,
      "Produce via " .. (producer_pattern and producer_pattern.display_name or common.humanize_identifier(producer.pattern_name)) ..
        " (" .. tostring(current_site_count) .. "/" .. tostring(minimum_site_count) .. " site(s))",
      "sequence"
    )
    producer_node.status = current_site_count >= minimum_site_count and "ready" or "blocked"

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

      finalize_group_status(producer_node)
    end

    instances.add_child(node, producer_node)
    return node
  end

  if item_name == "wood" or item_name == "stone" then
    local gather_node = new_instance(
      "gather-" .. item_name,
      "Gather " .. common.humanize_identifier(item_name) .. " from world",
      "action"
    )
    gather_node.status = active_context.kind == "gather" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
    gather_node.active = active_context.kind == "gather" and active_context.item_name == item_name
    instances.add_child(node, gather_node)
    if gather_node.active then
      node.active_child_id = gather_node.id
    end
    return node
  end

  local collect_node = new_instance(
    "collect-" .. item_name,
    "Collect " .. common.humanize_identifier(item_name) .. " from existing sites",
    "action"
  )
  collect_node.status = active_context.kind == "collect" and active_context.item_name == item_name and (active_context.status or "running") or "ready"
  collect_node.active = active_context.kind == "collect" and active_context.item_name == item_name
  instances.add_child(node, collect_node)
  if collect_node.active then
    node.active_child_id = collect_node.id
  end
  return node
end

local function build_requirements_node(builder_data, snapshot, adapter, title, required_items, active_context, node_id)
  local node = new_instance(node_id or ("requirements-" .. title:gsub("%s+", "-"):lower()), title, "sequence")
  local active_child_id = nil

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
    if child.active then
      active_child_id = active_child_id or child.id
    end
    instances.add_child(node, child)
  end

  if next(node.children) == nil then
    node.status = "completed"
    return node
  end

  if active_child_id then
    node.active = true
    set_active_child(node, active_child_id)
  end

  finalize_group_status(node)
  return node
end

local function ensure_bootstrap_children(bootstrap_instance, builder_data)
  local task_specs = specs.build(builder_data).bootstrap.children or {}
  if #bootstrap_instance.children == #task_specs then
    return
  end

  bootstrap_instance.children = {}
  for _, child_spec in ipairs(task_specs) do
    bootstrap_instance.children[#bootstrap_instance.children + 1] = new_instance(child_spec.id, child_spec.title, child_spec.kind)
  end
end

local function ensure_model(builder_data, builder_state)
  local state = instances.ensure_state(builder_state)
  if not state then
    return nil
  end

  local spec_tree = specs.build(builder_data)
  if state.model and state.model.version == MODEL_VERSION then
    ensure_bootstrap_children(state.model.bootstrap, builder_data)
    return state.model
  end

  local root = new_instance(spec_tree.root.id, spec_tree.root.title, spec_tree.root.kind)
  local manual = new_instance(spec_tree.manual.id, spec_tree.manual.title, spec_tree.manual.kind)
  local paused = new_instance(spec_tree.paused.id, spec_tree.paused.title, spec_tree.paused.kind)
  local bootstrap = new_instance(spec_tree.bootstrap.id, spec_tree.bootstrap.title, spec_tree.bootstrap.kind)
  local scaling = new_instance(spec_tree.scaling.id, spec_tree.scaling.title, spec_tree.scaling.kind)
  local build_out = new_instance(spec_tree.build_out.id, spec_tree.build_out.title, spec_tree.build_out.kind)

  root.children = {manual, paused, bootstrap, scaling, build_out}
  ensure_bootstrap_children(bootstrap, builder_data)

  state.model = {
    version = MODEL_VERSION,
    specs = spec_tree,
    root = root,
    manual = manual,
    paused = paused,
    bootstrap = bootstrap,
    scaling = scaling,
    build_out = build_out,
    scaling_focus = nil,
    build_out_focus = nil
  }

  return state.model
end

local function sync_paused(model_state, builder_state, snapshot)
  local paused = model_state.paused
  reset_instance(paused, false)

  local pause_state = snapshot and snapshot.manual_pause or builder_state.manual_pause
  if not pause_state then
    paused.status = "pending"
    paused.title = "Paused"
    return
  end

  paused.title = "Paused"
  if pause_state.reason and pause_state.reason ~= "" then
    paused.title = paused.title .. ": " .. common.humanize_identifier(pause_state.reason)
  end

  paused.status = "blocked"
  paused.active = true
  paused.meta.pause_state = common.deep_copy(pause_state)
  instances.add_blocker(
    paused,
    instances.make_blocker(
      "manual-pause",
      "builder is paused until manually unpaused or given a manual goal",
      {
        reason = pause_state.reason,
        since_tick = pause_state.since_tick
      }
    )
  )
end

local function sync_manual(model_state, builder_data, builder_state, snapshot, adapter)
  local manual = model_state.manual
  reset_instance(manual, false)

  local request = builder_state.manual_goal_request
  if not request then
    manual.status = "pending"
    return
  end

  manual.title = "Manual Goal: " .. (request.display_name or request.component_name or "request")
  if request.requested_position then
    manual.title = manual.title .. " at " .. common.format_position(request.requested_position)
    manual.meta.requested_position = common.clone_position(request.requested_position)
  end

  local current_index = request.current_task_index or 1
  local current_task = request.tasks and request.tasks[current_index] or nil
  local active_status = snapshot and status.get_task_phase_status{
    task_state = builder_state.task_state,
    display_task = current_task
  } or "ready"

  if snapshot and adapter then
    local component = predicates.get_component_spec(builder_data, request.component_name or "")
    if component and component.required_items and #component.required_items > 0 then
      instances.add_child(
        manual,
        build_requirements_node(
          builder_data,
          snapshot,
          adapter,
          "Requirements",
          component.required_items,
          get_active_context(snapshot),
          "manual-requirements"
        )
      )
    end
  end

  for index, task in ipairs(request.tasks or {}) do
    local child = new_instance(
      "manual-task-" .. tostring(index),
      common.humanize_identifier(task.manual_component_name or task.scaling_pattern_name or task.pattern_name or task.id or task.type),
      "action"
    )

    if index < current_index then
      child.status = "completed"
    elseif current_task and task.id == current_task.id then
      child.status = active_status
      child.active = true
      child.meta.task = task
      child.meta.display_task = task
      child.meta.execution_kind = "task"
      if snapshot then
        add_runtime_blockers(child, snapshot)
        if not (snapshot.task_state and tostring(snapshot.task_state.phase or ""):match("^scaling")) then
          instances.add_child(child, build_action_node("manual-action-" .. tostring(index), snapshot))
          child.active_child_id = "manual-action-" .. tostring(index)
        end
      end
      manual.active_child_id = child.id
      manual.status = active_status
    else
      child.status = "pending"
    end

    instances.add_child(manual, child)
  end

  if current_task == nil then
    manual.status = "completed"
  else
    manual.status = active_status
    manual.active = true
    if snapshot then
      add_runtime_blockers(manual, snapshot)
    end
  end
end

local function sync_bootstrap(model_state, builder_data, builder_state, snapshot)
  local bootstrap = model_state.bootstrap
  reset_instance(bootstrap, true)
  ensure_bootstrap_children(bootstrap, builder_data)

  local bootstrap_plan = builder_data.plans and builder_data.plans.bootstrap or nil
  local tasks = (bootstrap_plan and bootstrap_plan.tasks) or {}
  local current_index = builder_state.task_index or 1
  local current_task = tasks[current_index]
  local active_status = snapshot and status.get_task_phase_status{
    task_state = builder_state.task_state,
    display_task = current_task
  } or "ready"

  for index, child in ipairs(bootstrap.children) do
    reset_instance(child, false)
    if index < current_index then
      child.status = "completed"
    elseif index == current_index and current_task then
      child.status = active_status
      child.active = true
      child.meta.task = current_task
      child.meta.display_task = current_task
      child.meta.execution_kind = "task"
      if snapshot then
        add_runtime_blockers(child, snapshot)
        instances.add_child(child, build_action_node("bootstrap-action-" .. tostring(index), snapshot))
        child.active_child_id = "bootstrap-action-" .. tostring(index)
      end
      bootstrap.active_child_id = child.id
    else
      child.status = "pending"
    end
  end

  if current_index > #tasks then
    bootstrap.status = "completed"
  elseif current_task then
    bootstrap.status = active_status
    bootstrap.active = true
    if snapshot then
      add_runtime_blockers(bootstrap, snapshot)
    end
  else
    bootstrap.status = "pending"
  end
end

local function phase_name_starts_with(builder_state, prefix)
  local phase = builder_state and builder_state.task_state and builder_state.task_state.phase or nil
  return type(phase) == "string" and phase:sub(1, #prefix) == prefix
end

local function all_milestones_completed(snapshot_or_state, milestones)
  local completed = snapshot_or_state and snapshot_or_state.completed_scaling_milestones or {}
  for _, milestone in ipairs(milestones or {}) do
    if not completed[milestone.name] then
      return false
    end
  end

  return true
end

local function scaling_is_complete(builder_state)
  return builder_state and builder_state.scale_production_complete == true
end

local function task_is_scaling_task(builder_data, task)
  if not task then
    return false
  end

  return task.scaling_pattern_name ~= nil or
    predicates.task_targets_milestone(task, (builder_data.scaling and builder_data.scaling.production_milestones) or {})
end

local function task_is_build_out_task(builder_data, task)
  return predicates.task_targets_milestone(
    task,
    (builder_data.build_out and builder_data.build_out.production_milestones) or {}
  )
end

local function sync_scaling_focus_state(model_state, builder_data, builder_state)
  local scaling = model_state.scaling
  reset_instance(scaling, false)

  if not (builder_data.scaling and builder_data.scaling.enabled) then
    scaling.status = "pending"
    model_state.scaling_focus = nil
    return nil
  end

  if scaling_is_complete(builder_state) and not task_is_scaling_task(builder_data, builder_state.scaling_active_task) then
    scaling.status = "completed"
    model_state.scaling_focus = nil
    return nil
  end

  local focus = model_state.scaling_focus
  local scaling_phase_active = builder_state.task_state and tostring(builder_state.task_state.phase or ""):match("^scaling") ~= nil

  if focus then
    if focus.execution_kind == "task" then
      if builder_state.scaling_active_task ~= focus.task then
        focus = nil
        model_state.scaling_focus = nil
      end
    elseif not scaling_phase_active then
      focus = nil
      model_state.scaling_focus = nil
    end
  end

  if builder_state.scaling_active_task and (not focus or focus.task ~= builder_state.scaling_active_task) then
    focus = {
      id = "scaling-active-task",
      title = common.humanize_identifier(builder_state.scaling_active_task.scaling_pattern_name or builder_state.scaling_active_task.id or "scaling task"),
      task = builder_state.scaling_active_task,
      display_task = builder_state.scaling_active_task,
      execution_kind = "task"
    }
    model_state.scaling_focus = focus
  end

  if not focus and scaling_phase_active then
    local state = instances.ensure_state(builder_state)
    local display_task = state and state.scaling_display_task or nil
    focus = {
      id = "scaling-phase",
      title = display_task and common.humanize_identifier(display_task.scaling_pattern_name or display_task.id or "scaling") or "Scale Production",
      task = nil,
      display_task = display_task,
      execution_kind = "scaling-phase"
    }
    model_state.scaling_focus = focus
  end

  if focus then
    scaling.status = builder_state.task_state and status.get_task_phase_status{
      task_state = builder_state.task_state,
      display_task = focus.display_task or focus.task
    } or "ready"
  elseif scaling_phase_active then
    scaling.status = status.get_task_phase_status{
      task_state = builder_state.task_state,
      display_task = nil
    }
  else
    scaling.status = "ready"
  end

  return focus
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

local function build_milestone_thresholds_node(snapshot, adapter, milestone)
  local thresholds_node = new_instance("milestone-thresholds-" .. milestone.name, "Thresholds", "sequence")

  for _, threshold in ipairs(milestone.inventory_thresholds or {}) do
    local count = snapshot.entity and adapter.get_item_count(snapshot.entity, threshold.name) or 0
    local threshold_child = new_instance(
      "milestone-threshold-" .. milestone.name .. "-" .. threshold.name,
      "Have " .. common.humanize_identifier(threshold.name) .. " x" .. tostring(threshold.count) ..
        " (" .. tostring(count) .. "/" .. tostring(threshold.count) .. ")",
      "action"
    )
    threshold_child.status = count >= threshold.count and "completed" or "pending"
    instances.add_child(thresholds_node, threshold_child)
  end

  finalize_group_status(thresholds_node)
  return thresholds_node
end

local function build_milestone_node(builder_data, snapshot, adapter, milestone, active_context)
  local is_completed = milestone_is_completed(snapshot, milestone)
  local active = active_context.owner_kind == "milestone" and active_context.milestone_name == milestone.name

  local node_status = "pending"
  if active then
    node_status = status.get_task_phase_status(snapshot)
  elseif is_completed and not milestone.repeat_when_eligible then
    node_status = "completed"
  elseif milestone_thresholds_met(snapshot, adapter, milestone) then
    node_status = "ready"
  end

  local node = new_instance(
    "milestone-" .. milestone.name,
    milestone.display_name or common.humanize_identifier(milestone.name),
    "sequence"
  )
  node.status = node_status
  node.active = active

  if active and snapshot.active_task and (
    snapshot.active_task.completed_scaling_milestone_name == milestone.name or
    snapshot.active_task.repeatable_scaling_milestone_name == milestone.name
  ) then
    node.meta.task = snapshot.active_task
    node.meta.display_task = snapshot.display_task or snapshot.active_task
    node.meta.execution_kind = "task"
  end

  if active then
    add_runtime_blockers(node, snapshot)
  end

  if milestone.inventory_thresholds and #milestone.inventory_thresholds > 0 then
    instances.add_child(node, build_milestone_thresholds_node(snapshot, adapter, milestone))
  end

  if milestone.required_items and #milestone.required_items > 0 then
    local requirements_node = build_requirements_node(
      builder_data,
      snapshot,
      adapter,
      "Requirements",
      milestone.required_items,
      active_context,
      "milestone-requirements-" .. milestone.name
    )
    instances.add_child(node, requirements_node)
    if active and requirements_node.active then
      node.active_child_id = requirements_node.id
    end
  end

  if active and not node.active_child_id then
    local action_node = build_action_node("milestone-action-" .. milestone.name, snapshot)
    instances.add_child(node, action_node)
    node.active_child_id = action_node.id
  end

  return node
end

local function build_pattern_node(builder_data, snapshot, adapter, pattern_name, active_context)
  local pattern = predicates.get_pattern(builder_data, pattern_name)
  local active = active_context.owner_kind == "pattern" and active_context.pattern_name == pattern_name
  local blockers = predicates.get_unlock_blockers(builder_data, snapshot, pattern_name)
  local site_count = (snapshot.resource_site_counts and snapshot.resource_site_counts[pattern_name]) or 0

  local node = new_instance(
    "pattern-" .. pattern_name,
    (pattern and pattern.display_name or common.humanize_identifier(pattern_name)) .. " (" .. tostring(site_count) .. " site(s))",
    "sequence"
  )

  for _, blocker in ipairs(blockers) do
    instances.add_blocker(node, blocker)
  end

  if active then
    node.status = status.get_task_phase_status(snapshot)
    node.active = true
    add_runtime_blockers(node, snapshot)
    if snapshot.active_task and snapshot.active_task.scaling_pattern_name == pattern_name then
      node.meta.task = snapshot.active_task
      node.meta.display_task = snapshot.display_task or snapshot.active_task
      node.meta.execution_kind = "task"
    end
  elseif #blockers > 0 then
    node.status = "blocked"
  else
    node.status = "ready"
  end

  if pattern and pattern.required_items and #pattern.required_items > 0 then
    local requirements_node = build_requirements_node(
      builder_data,
      snapshot,
      adapter,
      "Requirements",
      pattern.required_items,
      active_context,
      "pattern-requirements-" .. pattern_name
    )
    instances.add_child(node, requirements_node)
    if active and requirements_node.active then
      node.active_child_id = requirements_node.id
    end
  end

  if active and not node.active_child_id then
    local action_node = build_action_node("pattern-action-" .. pattern_name, snapshot)
    instances.add_child(node, action_node)
    node.active_child_id = action_node.id
  end

  return node
end

local function sync_scaling_details(model_state, builder_data, builder_state, snapshot, adapter)
  local scaling = model_state.scaling
  local active_context = get_active_context(snapshot)
  local milestones_root = new_instance("scaling-milestones", "Milestones", "selector")
  local patterns_root = new_instance("scaling-patterns", "Expansion Patterns", "selector")

  local active_milestone_id = nil
  for _, milestone in ipairs((builder_data.scaling and builder_data.scaling.production_milestones) or {}) do
    local child = build_milestone_node(builder_data, snapshot, adapter, milestone, active_context)
    if child.active then
      active_milestone_id = child.id
    end
    instances.add_child(milestones_root, child)
  end
  if active_milestone_id then
    milestones_root.active = true
    set_active_child(milestones_root, active_milestone_id)
  end
  finalize_group_status(milestones_root)

  local active_pattern_id = nil
  for _, pattern_name in ipairs((builder_data.scaling and builder_data.scaling.cycle_pattern_names) or {}) do
    local child = build_pattern_node(builder_data, snapshot, adapter, pattern_name, active_context)
    if child.active then
      active_pattern_id = child.id
    end
    instances.add_child(patterns_root, child)
  end
  if active_pattern_id then
    patterns_root.active = true
    set_active_child(patterns_root, active_pattern_id)
  end
  finalize_group_status(patterns_root)

  scaling.children = {milestones_root, patterns_root}
  scaling.active = scaling.status == "running" or scaling.status == "blocked"

  if active_milestone_id then
    scaling.active = true
    scaling.active_child_id = milestones_root.id
    milestones_root.active = true
  elseif active_pattern_id then
    scaling.active = true
    scaling.active_child_id = patterns_root.id
    patterns_root.active = true
  else
    scaling.active_child_id = nil
  end

  if scaling.active then
    add_runtime_blockers(scaling, snapshot)
  end
end

local function sync_build_out_focus_state(model_state, builder_data, builder_state)
  local build_out = model_state.build_out
  reset_instance(build_out, false)

  if not (builder_data.build_out and builder_data.build_out.enabled) then
    build_out.status = "pending"
    model_state.build_out_focus = nil
    return nil
  end

  local state = instances.ensure_state(builder_state)
  local display_task = state and state.scaling_display_task or nil
  local active_task = builder_state.scaling_active_task
  local active_task_is_build_out = task_is_build_out_task(builder_data, active_task)
  local display_task_is_build_out = task_is_build_out_task(builder_data, display_task)
  local build_out_phase_active =
    phase_name_starts_with(builder_state, "build-out") or
    (phase_name_starts_with(builder_state, "scaling") and (active_task_is_build_out or display_task_is_build_out))

  local focus = model_state.build_out_focus
  if focus then
    if focus.execution_kind == "task" then
      if active_task ~= focus.task then
        focus = nil
        model_state.build_out_focus = nil
      end
    elseif not build_out_phase_active then
      focus = nil
      model_state.build_out_focus = nil
    end
  end

  if active_task_is_build_out and (not focus or focus.task ~= active_task) then
    focus = {
      id = "build-out-active-task",
      title = common.humanize_identifier(active_task.completed_scaling_milestone_name or active_task.id or "build out task"),
      task = active_task,
      display_task = active_task,
      execution_kind = "task"
    }
    model_state.build_out_focus = focus
  end

  if not focus and build_out_phase_active then
    focus = {
      id = "build-out-phase",
      title = display_task and common.humanize_identifier(display_task.completed_scaling_milestone_name or display_task.id or "build out") or "Build Out",
      task = nil,
      display_task = display_task,
      execution_kind = "scaling-phase"
    }
    model_state.build_out_focus = focus
  end

  if focus then
    build_out.status = builder_state.task_state and status.get_task_phase_status{
      task_state = builder_state.task_state,
      display_task = focus.display_task or focus.task
    } or "ready"
  elseif all_milestones_completed(builder_state, builder_data.build_out.production_milestones) then
    build_out.status = "ready"
  else
    build_out.status = "pending"
  end

  return focus
end

local function sync_build_out_details(model_state, builder_data, builder_state, snapshot, adapter)
  local build_out = model_state.build_out
  local active_context = get_active_context(snapshot)
  local milestones_root = new_instance("build-out-milestones", "Milestones", "selector")
  local maintenance_node = new_instance("build-out-maintenance", "Patrol Mining Areas", "action")

  local active_milestone_id = nil
  for _, milestone in ipairs((builder_data.build_out and builder_data.build_out.production_milestones) or {}) do
    local child = build_milestone_node(builder_data, snapshot, adapter, milestone, active_context)
    if child.active then
      active_milestone_id = child.id
    end
    instances.add_child(milestones_root, child)
  end
  if active_milestone_id then
    milestones_root.active = true
    set_active_child(milestones_root, active_milestone_id)
  end
  finalize_group_status(milestones_root)

  local build_out_complete = all_milestones_completed(snapshot, (builder_data.build_out and builder_data.build_out.production_milestones) or {})
  if phase_name_starts_with(builder_state, "build-out-patrol") then
    maintenance_node.status = status.get_task_phase_status(snapshot)
    maintenance_node.active = true
    maintenance_node.meta.execution_kind = "build-out-maintenance"
  elseif build_out_complete then
    maintenance_node.status = "ready"
  else
    maintenance_node.status = "pending"
  end

  build_out.children = {milestones_root, maintenance_node}
  build_out.active = build_out.status == "running" or build_out.status == "blocked" or build_out.status == "ready"

  if active_milestone_id then
    build_out.active = true
    build_out.active_child_id = milestones_root.id
    milestones_root.active = true
  elseif maintenance_node.active then
    build_out.active = true
    build_out.active_child_id = maintenance_node.id
  else
    build_out.active_child_id = nil
  end

  if build_out.active then
    add_runtime_blockers(build_out, snapshot)
  end
end

function model.sync(builder_data, builder_state, options)
  local model_state = ensure_model(builder_data, builder_state)
  if not model_state then
    return nil
  end

  options = options or {}
  local snapshot = options.snapshot
  local adapter = options.adapter

  sync_manual(model_state, builder_data, builder_state, snapshot, adapter)
  sync_paused(model_state, builder_state, snapshot)
  sync_bootstrap(model_state, builder_data, builder_state, snapshot)
  sync_scaling_focus_state(model_state, builder_data, builder_state)
  sync_build_out_focus_state(model_state, builder_data, builder_state)
  if snapshot and adapter then
    sync_scaling_details(model_state, builder_data, builder_state, snapshot, adapter)
    sync_build_out_details(model_state, builder_data, builder_state, snapshot, adapter)
  end

  local root = model_state.root
  reset_instance(root, true)
  root.children = {model_state.manual, model_state.paused, model_state.bootstrap, model_state.scaling, model_state.build_out}
  root.active = true

  if builder_state.manual_goal_request then
    set_active_child(root, model_state.manual.id)
    root.status = model_state.manual.status
  elseif builder_state.manual_pause then
    set_active_child(root, model_state.paused.id)
    root.status = model_state.paused.status
  elseif model_state.bootstrap.status ~= "completed" then
    set_active_child(root, model_state.bootstrap.id)
    root.status = model_state.bootstrap.status
  elseif builder_data.scaling and builder_data.scaling.enabled and
    (not scaling_is_complete(builder_state) or task_is_scaling_task(builder_data, builder_state.scaling_active_task))
  then
    set_active_child(root, model_state.scaling.id)
    root.status = model_state.scaling.status
  elseif builder_data.build_out and builder_data.build_out.enabled then
    set_active_child(root, model_state.build_out.id)
    root.status = model_state.build_out.status
  else
    root.active_child_id = nil
    for _, child in ipairs(root.children or {}) do
      child.active = false
    end
    root.status = "completed"
  end

  builder_state.goal_model_root = root
  return model_state
end

function model.set_scaling_focus(builder_data, builder_state, focus)
  local model_state = ensure_model(builder_data, builder_state)
  if not model_state then
    return
  end

  if not focus then
    model_state.scaling_focus = nil
    return
  end

  model_state.scaling_focus = {
    id = focus.id or "scaling-focus",
    title = focus.title,
    task = focus.task,
    display_task = focus.display_task or focus.task,
    execution_kind = focus.execution_kind or (focus.task and "task" or "scaling-phase"),
    focus_kind = focus.focus_kind,
    focus_name = focus.focus_name
  }
end

function model.clear_scaling_focus(builder_data, builder_state)
  local model_state = ensure_model(builder_data, builder_state)
  if model_state then
    model_state.scaling_focus = nil
  end
end

function model.get_root(builder_data, builder_state)
  local model_state = ensure_model(builder_data, builder_state)
  return model_state and model_state.root or nil
end

function model.get_active_execution(builder_data, builder_state)
  local model_state = ensure_model(builder_data, builder_state)
  if not model_state then
    return nil
  end

  local execution_node = find_active_execution(model_state.root)
  if not execution_node then
    return nil
  end

  return execution_node.meta
end

function model.get_active_task(builder_data, builder_state)
  local execution = model.get_active_execution(builder_data, builder_state)
  if execution and execution.execution_kind == "task" then
    return execution.task
  end

  return nil
end

function model.get_display_task(builder_data, builder_state)
  local execution = model.get_active_execution(builder_data, builder_state)
  if execution then
    return execution.display_task or execution.task
  end

  local model_state = ensure_model(builder_data, builder_state)
  if model_state and model_state.build_out_focus and
    (model_state.root and model_state.root.active_child_id == model_state.build_out.id)
  then
    return model_state.build_out_focus.display_task or model_state.build_out_focus.task
  end

  if model_state and model_state.scaling_focus then
    return model_state.scaling_focus.display_task or model_state.scaling_focus.task
  end

  return nil
end

return model

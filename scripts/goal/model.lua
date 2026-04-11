local common = require("scripts.goal.common")
local instances = require("scripts.goal.instances")
local specs = require("scripts.goal.specs")
local status = require("scripts.goal.status")

local model = {}
local MODEL_VERSION = 1

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
    local found = find_active_execution(child)
    if found then
      return found
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
  local bootstrap = new_instance(spec_tree.bootstrap.id, spec_tree.bootstrap.title, spec_tree.bootstrap.kind)
  local scaling = new_instance(spec_tree.scaling.id, spec_tree.scaling.title, spec_tree.scaling.kind)

  root.children = {manual, bootstrap, scaling}
  ensure_bootstrap_children(bootstrap, builder_data)

  state.model = {
    version = MODEL_VERSION,
    specs = spec_tree,
    root = root,
    manual = manual,
    bootstrap = bootstrap,
    scaling = scaling,
    scaling_focus = nil
  }

  return state.model
end

local function sync_manual(model_state, builder_state)
  local manual = model_state.manual
  reset_instance(manual, false)

  local request = builder_state.manual_goal_request
  if not request then
    manual.status = "pending"
    return
  end

  manual.title = "Manual Goal: " .. (request.display_name or request.component_name or "request")
  manual.status = "ready"
  local current_index = request.current_task_index or 1
  local current_task = request.tasks and request.tasks[current_index] or nil
  local active_status = status.get_task_phase_status{
    task_state = builder_state.task_state,
    display_task = current_task
  }

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
      manual.active_child_id = child.id
      manual.status = active_status
    else
      child.status = "pending"
    end

    manual.children[#manual.children + 1] = child
  end

  if current_task == nil then
    manual.status = "completed"
  end
end

local function sync_bootstrap(model_state, builder_data, builder_state)
  local bootstrap = model_state.bootstrap
  reset_instance(bootstrap, true)
  ensure_bootstrap_children(bootstrap, builder_data)

  local bootstrap_plan = builder_data.plans and builder_data.plans.bootstrap or nil
  local tasks = (bootstrap_plan and bootstrap_plan.tasks) or {}
  local current_index = builder_state.task_index or 1
  local current_task = tasks[current_index]
  local active_status = status.get_task_phase_status{
    task_state = builder_state.task_state,
    display_task = current_task
  }

  for index, child in ipairs(bootstrap.children) do
    reset_instance(child, false)
    if index < current_index then
      child.status = "completed"
    elseif index == current_index and current_task then
      child.status = active_status
      child.meta.task = current_task
      child.meta.display_task = current_task
      child.meta.execution_kind = "task"
      bootstrap.active_child_id = child.id
    else
      child.status = "pending"
    end
  end

  if current_index > #tasks then
    bootstrap.status = "completed"
  elseif current_task then
    bootstrap.status = active_status
  else
    bootstrap.status = "pending"
  end
end

local function sync_scaling(model_state, builder_data, builder_state)
  local scaling = model_state.scaling
  reset_instance(scaling, false)

  if not (builder_data.scaling and builder_data.scaling.enabled) then
    scaling.status = "pending"
    model_state.scaling_focus = nil
    return
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
    local child = new_instance(
      focus.id or "scaling-focus",
      focus.title or "Scaling Focus",
      focus.execution_kind == "task" and "action" or "selector"
    )
    child.status = builder_state.task_state and status.get_task_phase_status{
      task_state = builder_state.task_state,
      display_task = focus.display_task or focus.task
    } or "ready"
    child.active = true
    child.meta.task = focus.task
    child.meta.display_task = focus.display_task or focus.task
    child.meta.execution_kind = focus.execution_kind or "scaling-phase"
    child.meta.focus_kind = focus.focus_kind
    child.meta.focus_name = focus.focus_name
    scaling.children = {child}
    scaling.active_child_id = child.id
    scaling.status = child.status
  elseif scaling_phase_active then
    scaling.status = status.get_task_phase_status{
      task_state = builder_state.task_state,
      display_task = nil
    }
  else
    scaling.status = "ready"
  end
end

function model.sync(builder_data, builder_state)
  local model_state = ensure_model(builder_data, builder_state)
  if not model_state then
    return nil
  end

  sync_manual(model_state, builder_state)
  sync_bootstrap(model_state, builder_data, builder_state)
  sync_scaling(model_state, builder_data, builder_state)

  local root = model_state.root
  reset_instance(root, true)
  root.children = {model_state.manual, model_state.bootstrap, model_state.scaling}
  root.active = true

  if builder_state.manual_goal_request then
    root.active_child_id = model_state.manual.id
    model_state.manual.active = true
    root.status = model_state.manual.status
  elseif model_state.bootstrap.status ~= "completed" then
    root.active_child_id = model_state.bootstrap.id
    model_state.bootstrap.active = true
    if model_state.bootstrap.active_child_id then
      for _, child in ipairs(model_state.bootstrap.children) do
        child.active = child.id == model_state.bootstrap.active_child_id
      end
    end
    root.status = model_state.bootstrap.status
  elseif builder_data.scaling and builder_data.scaling.enabled then
    root.active_child_id = model_state.scaling.id
    model_state.scaling.active = true
    if model_state.scaling.active_child_id then
      for _, child in ipairs(model_state.scaling.children) do
        child.active = child.id == model_state.scaling.active_child_id
      end
    end
    root.status = model_state.scaling.status
  else
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

  return nil
end

return model

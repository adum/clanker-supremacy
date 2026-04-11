local common = require("scripts.goal.common")

local instances = {}

function instances.ensure_state(builder_state)
  if not builder_state then
    return nil
  end

  if builder_state.goal_engine == nil then
    builder_state.goal_engine = {}
  end

  local state = builder_state.goal_engine

  if state.trace == nil then
    state.trace = {
      next_id = 1,
      events = {}
    }
  end

  if state.last_status_by_id == nil then
    state.last_status_by_id = {}
  end

  if state.last_active_goal_id == nil then
    state.last_active_goal_id = nil
  end

  if state.scaling_display_task == nil then
    state.scaling_display_task = nil
  end

  return state
end

function instances.make_blocker(kind, message, meta)
  if type(kind) == "table" then
    return {
      kind = kind.kind or "generic",
      message = kind.message or "",
      meta = common.deep_copy(kind.meta or {})
    }
  end

  if message == nil then
    return {
      kind = "generic",
      message = kind or "",
      meta = {}
    }
  end

  return {
    kind = kind or "generic",
    message = message or "",
    meta = common.deep_copy(meta or {})
  }
end

function instances.blocker_message(blocker)
  if type(blocker) == "string" then
    return blocker
  end

  return blocker and blocker.message or ""
end

function instances.new_node(id, title, status)
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

function instances.add_child(parent, child)
  if child then
    parent.children[#parent.children + 1] = child
  end

  return child
end

function instances.add_blocker(node, blocker)
  local normalized = instances.make_blocker(blocker)
  if normalized.message ~= "" then
    node.blockers[#node.blockers + 1] = normalized
  end
end

return instances

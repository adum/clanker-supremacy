local instances = require("scripts.goal.instances")

local trace = {}

local function push_event(builder_state, tick, event_type, goal_id, title, status, detail, debug_log)
  local state = instances.ensure_state(builder_state)
  if not state then
    return
  end

  local event = {
    id = state.trace.next_id or 1,
    tick = tick,
    type = event_type,
    goal_id = goal_id,
    title = title,
    status = status,
    detail = detail
  }

  state.trace.next_id = event.id + 1
  state.trace.events[#state.trace.events + 1] = event

  while #state.trace.events > 40 do
    table.remove(state.trace.events, 1)
  end

  if debug_log then
    local message = "goal " .. event.type .. ": " .. (title or goal_id or "unknown")
    if status then
      message = message .. " [" .. status .. "]"
    end
    if detail and detail ~= "" then
      message = message .. " - " .. detail
    end
    debug_log(message)
  end
end

local function collect_status_map(node, statuses)
  if not node then
    return
  end

  statuses[node.id] = node.status

  for _, child in ipairs(node.children or {}) do
    collect_status_map(child, statuses)
  end
end

local function find_node_by_id(node, goal_id)
  if not node then
    return nil
  end

  if node.id == goal_id then
    return node
  end

  for _, child in ipairs(node.children or {}) do
    local found = find_node_by_id(child, goal_id)
    if found then
      return found
    end
  end

  return nil
end

local function find_active_goal(node)
  if not node then
    return nil
  end

  for _, child in ipairs(node.children or {}) do
    if child.active then
      return find_active_goal(child) or child
    end
  end

  if node.active and node.id ~= "root" then
    return node
  end

  return nil
end

function trace.sync_from_root(builder_state, root, tick, debug_log)
  local state = instances.ensure_state(builder_state)
  if not state then
    return
  end

  local current_status_by_id = {}
  collect_status_map(root, current_status_by_id)
  local first_sync = next(state.last_status_by_id) == nil

  if not first_sync then
    for goal_id, status in pairs(current_status_by_id) do
      local previous_status = state.last_status_by_id[goal_id]
      if previous_status ~= status then
        local node = find_node_by_id(root, goal_id)
        local title = node and node.title or nil
        local detail = nil

        if node and status == "blocked" and node.blockers and #node.blockers > 0 then
          detail = instances.blocker_message(node.blockers[1])
        end

        local event_type = "goal-status"
        if status == "running" then
          event_type = "goal-start"
        elseif status == "blocked" then
          event_type = "goal-blocked"
        elseif status == "completed" then
          event_type = "goal-complete"
        elseif status == "ready" then
          event_type = "goal-ready"
        end

        push_event(builder_state, tick, event_type, goal_id, title, status, detail, debug_log)
      end
    end
  end

  state.last_status_by_id = current_status_by_id

  local active_goal = find_active_goal(root)
  local active_goal_id = active_goal and active_goal.id or nil
  if active_goal_id ~= state.last_active_goal_id then
    push_event(
      builder_state,
      tick,
      "goal-focus",
      active_goal_id or "none",
      active_goal and active_goal.title or "No Goal",
      active_goal and active_goal.status or nil,
      nil,
      debug_log
    )
    state.last_active_goal_id = active_goal_id
  end
end

function trace.get_recent_lines(builder_state, limit)
  local state = instances.ensure_state(builder_state)
  if not state then
    return {}
  end

  local lines = {}
  local start_index = math.max(1, #state.trace.events - (limit or 4) + 1)

  for index = start_index, #state.trace.events do
    local event = state.trace.events[index]
    local line = (event.type or "goal-event") .. ": " .. (event.title or event.goal_id or "unknown")
    if event.status then
      line = line .. " [" .. event.status .. "]"
    end
    if event.detail and event.detail ~= "" then
      line = line .. " - " .. event.detail
    end
    lines[#lines + 1] = line
  end

  return lines
end

return trace

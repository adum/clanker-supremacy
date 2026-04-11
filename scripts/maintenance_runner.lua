local maintenance_runner = {}

local function ensure_state(builder_state)
  builder_state.maintenance_state = builder_state.maintenance_state or {
    recent_actions = {}
  }

  return builder_state.maintenance_state
end

local function append_recent_action(builder_state, action)
  local state = ensure_state(builder_state)
  state.recent_actions[#state.recent_actions + 1] = action

  local max_actions = 8
  while #state.recent_actions > max_actions do
    table.remove(state.recent_actions, 1)
  end
end

function maintenance_runner.record_actions(builder_state, pass_name, tick, actions)
  for _, action in ipairs(actions or {}) do
    append_recent_action(
      builder_state,
      {
        pass_name = pass_name,
        tick = tick,
        summary = action
      }
    )
  end
end

function maintenance_runner.get_recent_action_lines(builder_state, max_lines)
  local state = ensure_state(builder_state)
  local lines = {}
  local start_index = math.max(1, #state.recent_actions - ((max_lines or 4) - 1))

  for index = start_index, #state.recent_actions do
    local action = state.recent_actions[index]
    lines[#lines + 1] = action.summary
  end

  return lines
end

function maintenance_runner.run(builder_state, tick, passes)
  ensure_state(builder_state)

  for _, pass in ipairs(passes or {}) do
    local actions = pass.run(builder_state, tick) or {}
    maintenance_runner.record_actions(builder_state, pass.name, tick, actions)
  end
end

function maintenance_runner.ensure_state(builder_state)
  return ensure_state(builder_state)
end

return maintenance_runner

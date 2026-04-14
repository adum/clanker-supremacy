local goal_engine = require("scripts.goal_engine")
local goal_tree = require("scripts.goal_tree")
local maintenance_runner = require("scripts.maintenance_runner")

local commands_module = {}

local function clear_display_task(builder_state)
  if builder_state and builder_state.goal_engine then
    builder_state.goal_engine.scaling_display_task = nil
  end
end

local function describe_entry_timing_settings(settings, context)
  local lines = {
    "entry-timing=" .. (settings.enabled and "on" or "off")
  }

  if settings.active_entry then
    local line =
      "entry-timing-active=" ..
      settings.active_entry.name ..
      " tick=" .. tostring(settings.active_entry.tick)
    if settings.active_entry.context and settings.active_entry.context ~= "" then
      line = line .. " " .. settings.active_entry.context
    end
    lines[#lines + 1] = line
  end

  if settings.last_completed_entry then
    local last_completed = settings.last_completed_entry
    local line = "entry-timing-last-completed=" .. last_completed.name
    if last_completed.tick ~= nil then
      line = line .. " tick=" .. tostring(last_completed.tick)
    end
    if last_completed.context and last_completed.context ~= "" then
      line = line .. " " .. last_completed.context
    end
    lines[#lines + 1] = line
  end

  return lines
end

local function parse_manual_component_request(command, builder_state, context)
  local parameter = command.parameter or ""
  local tokens = {}
  for token in string.gmatch(parameter, "%S+") do
    tokens[#tokens + 1] = token
  end

  local component_name = tokens[1]
  if not component_name then
    return nil, nil, "usage: /" .. command.name .. " <component> [here|x y]"
  end

  local position = nil
  if tokens[2] == "here" then
    local player = context.get_command_player(command)
    if player and player.valid then
      position = context.clone_position(player.position)
    elseif builder_state and builder_state.entity and builder_state.entity.valid then
      position = context.clone_position(builder_state.entity.position)
    end
  elseif tokens[2] then
    local x = tonumber(tokens[2])
    local y = tonumber(tokens[3])
    if not (x and y) then
      return nil, nil, "expected coordinates as <x y> or the keyword 'here'"
    end
    position = {x = x, y = y}
  end

  return component_name, position
end

local function describe_builder_state(builder_state, context)
  if not builder_state then
    return {
      "builder: missing"
    }
  end

  local entity = builder_state.entity
  local lines = {
    "debug=" .. tostring(context.debug_enabled()),
    "builder-position=" .. context.format_position(entity.position),
    "surface=" .. entity.surface.name
  }

  local walking_state = entity.walking_state
  if walking_state then
    lines[#lines + 1] = "walking=" .. tostring(walking_state.walking) .. " direction=" .. context.format_direction(walking_state.direction)
  end

  local task = context.get_active_task(builder_state)
  if task then
    lines[#lines + 1] = "task=" .. task.id .. " phase=" .. (builder_state.task_state and builder_state.task_state.phase or "uninitialized")
  elseif builder_state.manual_pause and not builder_state.manual_goal_request then
    lines[#lines + 1] = "task=paused phase=manual-pause"
  elseif context.builder_data.scaling and context.builder_data.scaling.enabled then
    local scaling_phase = builder_state.task_state and builder_state.task_state.phase or "planning"
    local cycle_pattern_names = context.builder_data.scaling.cycle_pattern_names or {}
    local pattern_index = builder_state.scaling_pattern_index or 1
    local pattern_name = cycle_pattern_names[pattern_index] or "none"
    lines[#lines + 1] = "task=scaling phase=" .. scaling_phase
    lines[#lines + 1] = "scaling-pattern=" .. pattern_name
  else
    lines[#lines + 1] = "task=complete"
  end

  local task_state = builder_state.task_state
  if task_state then
    if task_state.wait_reason then
      lines[#lines + 1] = "wait-reason=" .. task_state.wait_reason
    end
    if task_state.resource_position then
      lines[#lines + 1] = "resource-position=" .. context.format_position(task_state.resource_position)
    end
    if task_state.build_position then
      lines[#lines + 1] = "build-position=" .. context.format_position(task_state.build_position)
      lines[#lines + 1] = "build-direction=" .. context.format_direction(task_state.build_direction)
    end
    if task_state.downstream_machine_position then
      lines[#lines + 1] = "downstream-machine-position=" .. context.format_position(task_state.downstream_machine_position)
    end
    if task_state.output_container_position then
      lines[#lines + 1] = "output-container-position=" .. context.format_position(task_state.output_container_position)
    end
    if task_state.target_position then
      lines[#lines + 1] = "target-position=" .. context.format_position(task_state.target_position)
    end
    if task_state.target_item_name then
      lines[#lines + 1] = "target-item=" .. task_state.target_item_name
    end
    if task_state.source_id then
      lines[#lines + 1] = "source-id=" .. task_state.source_id
    end
    if task_state.target_kind then
      lines[#lines + 1] = "target-kind=" .. task_state.target_kind
    end
    if task_state.target_name then
      lines[#lines + 1] = "target-name=" .. task_state.target_name
    end
    if task_state.harvest_complete_tick then
      lines[#lines + 1] = "harvest-complete-tick=" .. task_state.harvest_complete_tick
    end
    if task_state.next_attempt_tick then
      lines[#lines + 1] = "next-attempt-tick=" .. task_state.next_attempt_tick
    end
    if task_state.pause_until_tick then
      lines[#lines + 1] = "pause-until-tick=" .. task_state.pause_until_tick
    end
    if task_state.next_phase then
      lines[#lines + 1] = "next-phase=" .. task_state.next_phase
    end
    if task_state.pause_reason then
      lines[#lines + 1] = "pause-reason=" .. task_state.pause_reason
    end
  end

  if builder_state.manual_pause then
    lines[#lines + 1] = "builder-paused=true"
    if builder_state.manual_pause.reason then
      lines[#lines + 1] = "builder-pause-reason=" .. builder_state.manual_pause.reason
    end
    if builder_state.manual_pause.since_tick then
      lines[#lines + 1] = "builder-pause-since-tick=" .. builder_state.manual_pause.since_tick
    end
  end

  if builder_state.next_container_scan_tick then
    lines[#lines + 1] = "next-container-scan-tick=" .. builder_state.next_container_scan_tick
  end
  if builder_state.next_machine_refuel_tick then
    lines[#lines + 1] = "next-machine-refuel-tick=" .. builder_state.next_machine_refuel_tick
  end
  if builder_state.next_machine_input_supply_tick then
    lines[#lines + 1] = "next-machine-input-supply-tick=" .. builder_state.next_machine_input_supply_tick
  end
  if builder_state.next_machine_output_collection_tick then
    lines[#lines + 1] = "next-machine-output-collection-tick=" .. builder_state.next_machine_output_collection_tick
  end
  if builder_state.completed_scaling_milestones then
    lines[#lines + 1] = "completed-scaling-milestones=" .. context.count_table_entries(builder_state.completed_scaling_milestones)
  end

  lines[#lines + 1] = "production-sites=" .. #context.ensure_production_sites()
  lines[#lines + 1] = "resource-sites=" .. #context.ensure_resource_sites()

  if builder_state.goal_model_root then
    lines[#lines + 1] = "goal=" .. goal_tree.get_root_goal_line(builder_state.goal_model_root)
    for _, path_line in ipairs(builder_state.goal_path_lines or {}) do
      lines[#lines + 1] = "goal-path=" .. path_line
    end
    for _, blocker_line in ipairs(builder_state.goal_blocker_lines or {}) do
      lines[#lines + 1] = "goal-blocker=" .. blocker_line
    end
  end

  for _, maintenance_line in ipairs(maintenance_runner.get_recent_action_lines(builder_state, 4)) do
    lines[#lines + 1] = "maintenance=" .. maintenance_line
  end

  for _, trace_line in ipairs(goal_engine.get_recent_trace_lines(builder_state, 4)) do
    lines[#lines + 1] = "goal-trace=" .. trace_line
  end

  return lines
end

function commands_module.status(command, context)
  context.ensure_debug_settings()

  local builder_state = context.get_builder_state()
  if builder_state then
    context.update_goal_model(builder_state, game.tick)
  end

  local lines = describe_builder_state(builder_state, context)
  for _, line in ipairs(lines) do
    context.reply_to_command(command, line)
  end
end

function commands_module.toggle_debug(command, context)
  context.ensure_debug_settings()

  local parameter = command.parameter and string.lower(command.parameter) or nil
  if parameter == "on" then
    storage.debug_enabled = true
    context.reply_to_command(command, "debug logging enabled")
    return
  end

  if parameter == "off" then
    storage.debug_enabled = false
    context.reply_to_command(command, "debug logging disabled")
    return
  end

  context.reply_to_command(
    command,
    "debug logging is " .. (context.debug_enabled() and "on" or "off") .. "; use /enemy-builder-debug on or /enemy-builder-debug off"
  )
end

function commands_module.entry_timing(command, context)
  context.ensure_entry_timing_settings()

  local parameter = command.parameter or ""
  local tokens = {}
  for token in string.gmatch(parameter, "%S+") do
    tokens[#tokens + 1] = string.lower(token)
  end

  local action = tokens[1] or "status"
  if action == "status" then
    for _, line in ipairs(describe_entry_timing_settings(context.get_entry_timing_settings(), context)) do
      context.reply_to_command(command, line)
    end
    return
  end

  if action == "on" then
    context.set_entry_timing_enabled(true)
    context.reply_to_command(command, "entry timing enabled")
    return
  end

  if action == "off" then
    context.set_entry_timing_enabled(false)
    context.reply_to_command(command, "entry timing disabled")
    return
  end

  context.reply_to_command(
    command,
    "usage: /enemy-builder-entry-timing [status|on|off]"
  )
end

function commands_module.retask(command, context)
  local builder_state = context.get_builder_state()
  if not builder_state then
    context.reply_to_command(command, "no builder entity is active")
    return
  end

  builder_state.task_state = nil
  builder_state.scaling_active_task = nil
  clear_display_task(builder_state)
  context.set_idle(builder_state.entity)
  context.debug_log("manual retask requested at " .. context.format_position(builder_state.entity.position))
  if context.is_builder_paused(builder_state) then
    context.reply_to_command(command, "builder task state cleared; it remains paused until unpaused or given a manual goal")
  else
    context.reply_to_command(command, "builder task state cleared; it will re-evaluate on the next tick")
  end
end

function commands_module.goals(command, context)
  local builder_state = context.ensure_builder_for_command(command)
  if not builder_state then
    context.reply_to_command(command, "no builder entity is active")
    return
  end

  context.update_goal_model(builder_state, game.tick)
  for _, line in ipairs(goal_tree.format_tree_lines(builder_state.goal_model_root, false)) do
    context.reply_to_command(command, line)
  end
end

function commands_module.manual_plan(command, context)
  local builder_state = context.ensure_builder_for_command(command)
  local component_name, position, error_message = parse_manual_component_request(command, builder_state, context)
  if error_message then
    context.reply_to_command(command, error_message)
    context.reply_to_command(command, "components: " .. table.concat(goal_tree.list_component_names(context.builder_data), ", "))
    return
  end

  if not builder_state then
    context.reply_to_command(command, "no builder entity is active")
    return
  end

  local lines, preview_error = goal_tree.describe_plan_preview(
    context.builder_data,
    context.build_runtime_snapshot(builder_state, game.tick),
    {
      get_item_count = context.get_item_count,
      get_recipe = context.get_recipe
    },
    component_name,
    position
  )

  if preview_error then
    context.reply_to_command(command, preview_error)
    context.reply_to_command(command, "components: " .. table.concat(goal_tree.list_component_names(context.builder_data), ", "))
    return
  end

  for _, line in ipairs(lines or {}) do
    context.reply_to_command(command, line)
  end
end

function commands_module.manual_build(command, context)
  local builder_state = context.ensure_builder_for_command(command)
  local component_name, position, error_message = parse_manual_component_request(command, builder_state, context)
  if error_message then
    context.reply_to_command(command, error_message)
    context.reply_to_command(command, "components: " .. table.concat(goal_tree.list_component_names(context.builder_data), ", "))
    return
  end

  if not builder_state then
    context.reply_to_command(command, "no builder entity is active")
    return
  end

  local request, request_error = goal_tree.instantiate_manual_request(context.builder_data, component_name, position)
  if request_error then
    context.reply_to_command(command, request_error)
    context.reply_to_command(command, "components: " .. table.concat(goal_tree.list_component_names(context.builder_data), ", "))
    return
  end

  builder_state.manual_goal_request = request
  builder_state.task_state = nil
  clear_display_task(builder_state)
  context.set_idle(builder_state.entity)
  context.record_recovery(builder_state, "manual goal injected for " .. request.display_name)
  context.debug_log("manual goal injected: " .. request.display_name .. (position and " at " .. context.format_position(position) or ""))
  if context.is_builder_paused(builder_state) then
    context.reply_to_command(command, "manual goal queued: " .. request.display_name .. "; builder will return to paused idle afterward")
  else
    context.reply_to_command(command, "manual goal queued: " .. request.display_name)
  end
end

function commands_module.cancel_manual(command, context)
  local builder_state = context.get_builder_state()
  if not builder_state or not builder_state.manual_goal_request then
    context.reply_to_command(command, "no manual goal is active")
    return
  end

  local display_name = builder_state.manual_goal_request.display_name or builder_state.manual_goal_request.component_name or "manual goal"
  builder_state.manual_goal_request = nil
  builder_state.task_state = nil
  clear_display_task(builder_state)
  context.set_idle(builder_state.entity)
  context.debug_log("manual goal cancelled: " .. display_name)
  if context.is_builder_paused(builder_state) then
    context.reply_to_command(command, "cancelled " .. display_name .. "; builder remains paused")
  else
    context.reply_to_command(command, "cancelled " .. display_name)
  end
end

function commands_module.pause(command, context)
  local builder_state = context.get_builder_state()
  if not builder_state then
    context.reply_to_command(command, "no builder entity is active")
    return
  end

  local was_paused = context.is_builder_paused(builder_state)
  local cancelled_manual_name = builder_state.manual_goal_request and
    (builder_state.manual_goal_request.display_name or builder_state.manual_goal_request.component_name or "manual goal") or nil
  local had_task = builder_state.task_state ~= nil or builder_state.scaling_active_task ~= nil or context.get_active_task(builder_state) ~= nil

  context.pause_builder(builder_state, game.tick, "manual-command")
  context.record_recovery(builder_state, "manual pause requested")
  context.update_goal_model(builder_state, game.tick)
  context.debug_log("manual pause requested at " .. context.format_position(builder_state.entity.position))

  if cancelled_manual_name then
    context.reply_to_command(command, "builder paused; cancelled " .. cancelled_manual_name)
  elseif had_task then
    context.reply_to_command(command, (was_paused and "builder remains paused" or "builder paused") .. "; current task cleared")
  elseif was_paused then
    context.reply_to_command(command, "builder is already paused")
  else
    context.reply_to_command(command, "builder paused")
  end
end

function commands_module.unpause(command, context)
  local builder_state = context.get_builder_state()
  if not builder_state then
    context.reply_to_command(command, "no builder entity is active")
    return
  end

  if not context.is_builder_paused(builder_state) then
    context.reply_to_command(command, "builder is not paused")
    return
  end

  context.unpause_builder(builder_state)
  context.record_recovery(builder_state, "manual pause cleared")
  context.update_goal_model(builder_state, game.tick)
  context.debug_log("manual pause cleared at " .. context.format_position(builder_state.entity.position))
  context.reply_to_command(command, "builder unpaused")
end

function commands_module.register(context)
  local definitions = {
    {"enemy-builder-status", "Show the current Enemy Builder state.", commands_module.status},
    {"enemy-builder-goals", "Show the current Enemy Builder goal tree.", commands_module.goals},
    {"enemy-builder-debug", "Toggle Enemy Builder debug logging. Use on or off.", commands_module.toggle_debug},
    {"enemy-builder-entry-timing", "Inspect or configure Enemy Builder entry timing logs.", commands_module.entry_timing},
    {"enemy-builder-pause", "Pause the Enemy Builder until manually resumed or given a manual goal.", commands_module.pause},
    {"enemy-builder-unpause", "Resume the Enemy Builder after a manual pause.", commands_module.unpause},
    {"enemy-builder-retask", "Clear the current Enemy Builder task state and retry.", commands_module.retask},
    {"enemy-builder-plan", "Preview a manual Enemy Builder component plan.", commands_module.manual_plan},
    {"enemy-builder-build", "Queue a manual Enemy Builder component build.", commands_module.manual_build},
    {"enemy-builder-cancel-manual", "Cancel the active manual Enemy Builder goal.", commands_module.cancel_manual}
  }

  for _, definition in ipairs(definitions) do
    local name = definition[1]
    if commands.commands[name] then
      commands.remove_command(name)
    end
    commands.add_command(name, definition[2], function(command)
      context.run_timed_entry(
        "command:" .. name,
        function()
          if command.parameter and command.parameter ~= "" then
            return "command=" .. name .. " parameter=" .. command.parameter
          end
          return "command=" .. name
        end,
        definition[3],
        command,
        context
      )
    end)
  end
end

return commands_module

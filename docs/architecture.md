# Enemy Builder Architecture

Status: draft

This document defines the target architecture for the `enemy-builder` mod as it grows beyond a single bootstrap script. The goal is to make behavior easier to extend, easier to debug, and easier to reason about in both code and UI.

## Goals

- Keep the mod maintainable as new production chains, structures, and combat behaviors are added.
- Make the builder's behavior legible to the human developer at all times.
- Make the builder's internal reasoning explicit, structured, and recoverable.
- Keep most strategy and configuration data-driven without turning the mod into an unreadable DSL.
- Make it easy to manually test a single component or sub-goal without waiting for the full autonomous loop.

## Core Principles

1. Strategic behavior is a strict nested hierarchy of goals.
2. Maintenance behavior is separate from the goal tree and always runs as a bounded background loop.
3. Every goal has explicit requirements, blockers, status, and recovery policy.
4. The UI and logs read from the same structured runtime state that drives execution.
5. The planner chooses goals. The executor performs actions. Discovery and registry code own world facts.
6. A save should never appear "idle" without a recorded reason such as blocked, waiting, or recovering.

## Current Problems

The current implementation works for prototyping but concentrates too much responsibility in a single runtime file.

- `scripts/builder_runtime.lua` currently mixes planning, execution, world discovery, UI, logging, commands, save normalization, and maintenance.
- `shared/builder_data.lua` currently mixes recipes, site patterns, logistics settings, milestone policy, UI config, and prototype-facing constants.
- The builder's intent is reconstructed from ad hoc task fields rather than represented directly as a goal tree.
- Recovery exists in some places but is not a uniform contract.

## High-Level Runtime Model

The runtime should be split into two major systems:

1. Goal system
2. Maintenance system

The goal system owns intentional progress. The maintenance system owns cheap local upkeep.

### Goal System

The goal system is a strict tree. Every non-leaf goal has child goals. A parent goal is complete only when its completion rule is satisfied, usually after one or more child goals complete.

Recommended goal node kinds:

- `sequence`: run children in order
- `selector`: choose the first viable child
- `repeat_until`: repeat a child or child set until a predicate is satisfied
- `action`: leaf node that delegates to an action handler

The important constraint is that this is still a tree. A goal may choose among children, but at runtime it should always expose one active path from root to current leaf.

### Maintenance System

Maintenance is not part of the goal tree.

It includes behaviors such as:

- pulling resources out of nearby chests
- collecting outputs from nearby furnaces or assemblers
- putting coal into burner machines
- putting ingredients into nearby assemblers

These behaviors are local, opportunistic, and bounded. They should never replace the strategic goal or become a long-running plan on their own.

## Goal Tree Design

Each goal exists in two forms:

- `GoalSpec`: static definition
- `GoalInstance`: runtime state stored in `storage`

### GoalSpec

Suggested fields:

```lua
{
  id = "expand-steel-production",
  title = "Expand steel production",
  kind = "sequence",
  children = {...},
  requirements = {...},
  success = {...},
  recovery_policy = {...},
  ui = {
    short_title = "Expand steel",
    category = "scaling"
  }
}
```

### GoalInstance

Suggested fields:

```lua
{
  spec_id = "expand-steel-production",
  status = "running",
  active_child_index = 2,
  requirements = {...},
  blockers = {...},
  started_tick = 12345,
  last_progress_tick = 12410,
  attempt_count = 3,
  recovery_state = nil,
  trace_path = {"root", "scale-production", "expand-steel-production"}
}
```

### Goal Status Values

Use a small, explicit status set:

- `pending`
- `ready`
- `running`
- `blocked`
- `recovering`
- `completed`
- `failed`

At any point, the active path in the UI should be derivable by walking from the root through the active child at each level until a leaf is reached.

### Requirements

Requirements are conditions that must be true for a goal to start or complete.

Examples:

- `inventory-at-least`
- `site-count-at-least`
- `entity-exists`
- `layout-site-available`
- `goal-completed`

Example:

```lua
{
  type = "site-count-at-least",
  pattern = "iron_smelting",
  count = 5
}
```

### Blockers

Blockers explain why progress is not happening right now.

Examples:

- no valid build site found
- anchor entity disappeared
- movement stalled
- waiting for steel output
- missing required item with no producer yet

Blockers should be structured data first and formatted text second.

```lua
{
  type = "waiting-for-output",
  item = "steel-plate",
  site_pattern = "steel_smelting",
  next_retry_tick = 62500
}
```

## Failure Detection and Recovery

Every action goal must implement a progress contract.

An action should be able to answer:

- did it start successfully
- did it make progress recently
- is it blocked
- can it recover locally
- should it fail upward

### Required Action Handler Interface

Each leaf action handler should implement something close to:

```lua
can_start(context, goal_instance)
start(context, goal_instance)
tick(context, goal_instance)
detect_stall(context, goal_instance)
recover(context, goal_instance)
abort(context, goal_instance)
```

### Recovery Policy

Recovery should happen in layers:

1. Leaf goal tries local recovery.
2. If local recovery fails, the leaf marks itself failed or blocked.
3. Parent goal decides whether to retry, choose an alternate child, or bubble the failure upward.
4. If nothing can resolve the problem, the root goal becomes blocked with a concrete reason.

Recommended reusable recovery policies:

- `retry-same-target`
- `refresh-world-and-replan`
- `choose-alternate-site`
- `rollback-partial-build`
- `fail-to-parent`

### Architectural Invariant

The builder should never silently do nothing.

If no visible progress is happening, one of these must be true:

- a goal is `running`
- a goal is `blocked`
- a goal is `recovering`
- the builder is explicitly idle with a stated reason

## Maintenance Loop Design

The maintenance loop runs independently of the goal tree and is intentionally conservative.

### Rules

- Run on fixed intervals, not every tick.
- Use strict radius limits around the builder.
- Use strict per-pass budgets such as max entities scanned or max items moved.
- Never walk long distances for maintenance.
- Never wait for maintenance to become possible.
- Never replace the strategic goal.

### Maintenance Passes

Initial passes:

- collect nearby container contents
- collect nearby machine outputs
- refuel nearby burner machines
- supply nearby assembler inputs

Each pass should emit structured trace events such as:

- `maintenance/collect-output`
- `maintenance/refuel`
- `maintenance/supply-input`

The overlay should show recent maintenance actions separately from the strategic goal path.

## World Model and Registry

World discovery and world facts should move out of the planner.

The world layer should own:

- site discovery
- site registration
- production chain registration
- entity reference validation
- queries such as "find eligible iron smelting anchors"

This prevents planner code from scanning raw entities directly.

Suggested responsibilities:

- `discovery.lua`: scan the world and register known structures
- `sites.lua`: create, update, and clean site records
- `queries.lua`: answer planner questions
- `entity_refs.lua`: validate and normalize entity references

## Planner vs Executor

The planner should be mostly pure. It reads context and emits a decision.

The executor performs the next leaf action selected by the planner.

### Planner Output

The planner should produce a structured decision object:

```lua
{
  goal_path = {
    "root",
    "scale-production",
    "expand-steel-production",
    "collect-steel"
  },
  summary = "Expand steel production",
  blockers = {},
  next_action = {
    kind = "collect-from-site",
    site_pattern = "steel_smelting",
    target_item = "steel-plate"
  }
}
```

This decision object should drive:

- the top-left UI
- debug commands
- log formatting
- save-state reasoning

## UI and Developer Communication

The goal tree must be visible in the UI.

Recommended overlay sections:

- `Goal`: current high-level root or branch goal
- `Path`: active nested goal path
- `Activity`: current leaf action
- `Blockers`: current blockers on the active path
- `Maintenance`: recent maintenance actions
- `Inventory`: current builder inventory

Example:

```text
Goal: Scale production
Path:
- Expand steel production
- Establish first steel line
- Collect steel plates

Activity: Moving to steel furnace
Blockers: none
Maintenance: refueled 2 furnaces, collected from 1 chest
```

### Logging

Logs should be structured around goal transitions and maintenance events.

Examples:

- `goal-start`
- `goal-complete`
- `goal-blocked`
- `goal-recovering`
- `goal-failed`
- `maintenance-refuel`
- `maintenance-collect`

Every log line should include a stable goal path when applicable.

## Manual Goal Injection and Plan Preview

The same goal engine should support manual developer requests.

This is important for testing sub-goals such as "build the firearm magazine outpost here" without waiting for the autonomous planner to reach it.

### Manual Modes

- `plan-only`
- `execute`

Example commands:

```text
/enemy-builder-plan firearm_magazine_outpost here
/enemy-builder-build firearm_magazine_outpost here
/enemy-builder-build-at firearm_magazine_outpost 120.5 -34.5
/enemy-builder-cancel-manual
```

### Manual Goal Rules

- Manual requests instantiate the same goal subtree used by autonomous play.
- Manual requests temporarily preempt autonomous strategic goals.
- Maintenance continues to run while a manual goal is active.
- When the manual goal completes or is cancelled, control returns to autonomous planning.

### Plan Preview

Plan preview should display:

- goal tree
- required items
- missing items
- predicted blockers
- chosen anchor or target position
- whether execution is currently feasible

## Data and Configuration Structure

The current `shared/builder_data.lua` should be split by concern.

Suggested structure:

```text
shared/
  config/
    goals.lua
    patterns.lua
    recipes.lua
    milestones.lua
    logistics.lua
    ui.lua
    validate.lua
```

Guidelines:

- Keep patterns, recipes, thresholds, search radii, and limits in data.
- Keep action handlers, predicate evaluation, and recovery code in Lua modules.
- Validate config on init and on configuration change.

## Proposed Module Layout

```text
control.lua

scripts/
  runtime.lua
  goal/
    engine.lua
    planner.lua
    instances.lua
    predicates.lua
    recovery.lua
    status.lua
  world/
    model.lua
    discovery.lua
    sites.lua
    queries.lua
    entity_refs.lua
  actions/
    move.lua
    build.lua
    collect.lua
    craft.lua
    transfer.lua
    wait.lua
  maintenance/
    runner.lua
    collect_outputs.lua
    collect_containers.lua
    refuel.lua
    supply_inputs.lua
  debug/
    trace.lua
    overlay.lua
    commands.lua
    markers.lua

shared/
  config/
    goals.lua
    patterns.lua
    recipes.lua
    milestones.lua
    logistics.lua
    ui.lua
    validate.lua
```

## Testing Strategy

The design should support three levels of testing.

### 1. Headless Scenario Smoke Tests

Examples:

- fresh bootstrap
- scaling loop
- steel production
- firearm magazine outpost
- save migration from older stuck states

### 2. Goal-Level Tests

Given a world snapshot or synthetic setup:

- can the planner produce the expected goal path
- does a goal become blocked for the right reason
- does recovery choose the correct fallback

### 3. Manual In-Game Tests

Use manual plan and build commands to exercise a single component in isolation.

## Migration Plan

Do not rewrite the mod in one pass.

### Phase 1

- Add this architecture document.
- Introduce a goal instance model in storage.
- Add a structured decision object for UI and logs.

### Phase 2

- Wrap current bootstrap and scaling logic in goal nodes without changing behavior.
- Keep current executor logic mostly intact.

### Phase 3

- Extract world discovery and registry code into `scripts/world`.
- Extract maintenance passes into `scripts/maintenance`.

### Phase 4

- Replace ad hoc task logic with explicit goal planning and action handlers.
- Move overlay and logging to structured trace data.

### Phase 5

- Add manual plan and build commands backed by the goal engine.
- Add plan preview UI.

## Near-Term Implementation Priorities

Recommended first steps:

1. Introduce `GoalSpec`, `GoalInstance`, and `decision` objects in storage.
2. Make the overlay render from `decision` instead of reconstructing meaning from `task_state`.
3. Separate maintenance passes from strategic planning in code, even if behavior stays the same.
4. Extract site discovery and site query logic into a dedicated world layer.
5. Add manual plan and build entry points after the goal tree is stable enough to reuse.

## Summary

The target architecture is:

- a strict hierarchical goal tree for strategic behavior
- a separate bounded maintenance loop for local upkeep
- explicit requirements, blockers, statuses, and recovery on every goal
- a world layer that owns discovered facts
- an executor layer that performs leaf actions
- a UI and logging system driven by structured decision data
- a manual goal injection path for testing sub-goals and components

This design should keep the mod understandable as it grows, while also making the builder's reasoning visible and debuggable.

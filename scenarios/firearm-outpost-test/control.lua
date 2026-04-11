local test_prefix = "[enemy-builder-test] "
local target_position = {x = 32, y = 0}
local builder_position = {x = 0, y = 0}

local function log_message(message)
  log(test_prefix .. message)
end

local function make_area(center, half_width, half_height)
  return {
    left_top = {
      x = center.x - half_width,
      y = center.y - half_height
    },
    right_bottom = {
      x = center.x + half_width,
      y = center.y + half_height
    }
  }
end

local function create_grass_tiles(area)
  local tiles = {}

  for x = math.floor(area.left_top.x), math.ceil(area.right_bottom.x) do
    for y = math.floor(area.left_top.y), math.ceil(area.right_bottom.y) do
      tiles[#tiles + 1] = {
        name = "grass-1",
        position = {x = x, y = y}
      }
    end
  end

  return tiles
end

local function clear_test_area(surface, area)
  surface.request_to_generate_chunks(target_position, 3)
  surface.force_generate_chunk_requests()
  surface.set_tiles(create_grass_tiles(area), true)

  for _, entity in ipairs(surface.find_entities_filtered{area = area}) do
    if entity.valid and entity.name ~= "character" and entity.type ~= "player-port" then
      entity.destroy()
    end
  end

  surface.destroy_decoratives{area = area}
end

script.on_init(function()
  if not remote.interfaces["enemy-builder-test"] then
    error("enemy-builder test scenario: remote interface 'enemy-builder-test' is unavailable")
  end

  game.tick_paused = false
  game.speed = 1

  local surface = game.surfaces["nauvis"] or game.surfaces[1]
  if not surface then
    error("enemy-builder test scenario: nauvis surface is unavailable")
  end

  surface.always_day = true

  local area = make_area(target_position, 40, 24)
  clear_test_area(surface, area)

  remote.call("enemy-builder-test", "setup_manual_test", {
    case_name = "firearm_outpost_physical_feed",
    component_name = "firearm_magazine_site",
    builder_position = builder_position,
    target_position = target_position,
    surface_name = surface.name,
    suppress_player_autospawn = true,
    forbid_direct_turret_ammo_transfer = true,
    inventory = {
      {name = "coal", count = 20},
      {name = "copper-plate", count = 250},
      {name = "iron-plate", count = 400},
      {name = "steel-plate", count = 30},
      {name = "wood", count = 20}
    },
    assertion = {
      case_name = "firearm_outpost_physical_feed",
      surface_name = surface.name,
      area = area,
      deadline_offset_ticks = 18000,
      primary_entity_name = "enemy-builder-firearm-magazine-assembler",
      required_recipe_name = "firearm-magazine",
      turret_ammo_item_name = "firearm-magazine",
      minimum_turret_ammo_count = 1,
      expected_counts = {
        ["enemy-builder-firearm-magazine-assembler"] = 1,
        ["gun-turret"] = 2,
        ["burner-inserter"] = 2,
        ["small-electric-pole"] = 4,
        ["solar-panel"] = 4
      }
    }
  })

  log_message("setup complete; queued firearm_outpost_physical_feed")
end)

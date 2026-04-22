local constants = {}

constants.gather_sources = {
  {
    id = "trees",
    entity_type = "tree",
    search_radii = {64, 128, 256, 512},
    yields = {
      {name = "wood", count = 4}
    }
  },
  {
    id = "rocks",
    decorative_names = {
      "huge-rock",
      "big-rock",
      "big-sand-rock",
      "medium-rock",
      "small-rock",
      "tiny-rock",
      "medium-sand-rock",
      "small-sand-rock"
    },
    search_radii = {64, 128, 256},
    yields = {
      {name = "stone", count = 8}
    }
  }
}

constants.firearm_magazine_assembler_name = "enemy-builder-firearm-magazine-assembler"
constants.clanker_artillery_item_name = "clanker-artillery"
constants.clanker_artillery_entity_name = "clanker-artillery"
constants.clanker_artillery_cannon_name = "clanker-artillery-cannon"
constants.clanker_artillery_range = 60
constants.enemy_builder_physical_damage_1_technology_name = "enemy-builder-physical-damage-1"
constants.enemy_builder_research_technology_name = constants.enemy_builder_physical_damage_1_technology_name

constants.ammo_defense_required_items = {
  {name = "burner-inserter", count = 2},
  {name = "gun-turret", count = 2},
  {name = "small-electric-pole", count = 4},
  {name = "solar-panel", count = 4},
  {name = "iron-plate", count = 80}
}

constants.ammo_defense_layout_elements = {
  {
    id = "left-burner-inserter",
    site_role = "burner-inserter",
    entity_name = "burner-inserter",
    offset = {x = -2, y = 0},
    direction_name = "east",
    placement_search_radius = 0.5,
    placement_step = 0.5,
    fuel = {
      name = "coal",
      count = 4
    }
  },
  {
    id = "right-burner-inserter",
    site_role = "burner-inserter",
    entity_name = "burner-inserter",
    offset = {x = 2, y = 0},
    direction_name = "west",
    placement_search_radius = 0.5,
    placement_step = 0.5,
    fuel = {
      name = "coal",
      count = 4
    }
  },
  {
    id = "left-turret",
    site_role = "turret",
    entity_name = "gun-turret",
    offset = {x = -3, y = 0},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "right-turret",
    site_role = "turret",
    entity_name = "gun-turret",
    offset = {x = 3, y = 0},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "power-pole-1",
    site_role = "power-pole",
    entity_name = "small-electric-pole",
    offset = {x = 0, y = -2},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "power-pole-2",
    site_role = "power-pole",
    entity_name = "small-electric-pole",
    offset = {x = 0, y = -5},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "power-pole-3",
    site_role = "power-pole",
    entity_name = "small-electric-pole",
    offset = {x = 0, y = -8},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "power-pole-4",
    site_role = "power-pole",
    entity_name = "small-electric-pole",
    offset = {x = 0, y = -11},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "solar-panel-1",
    site_role = "solar-panel",
    entity_name = "solar-panel",
    offset = {x = -3, y = -5},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "solar-panel-2",
    site_role = "solar-panel",
    entity_name = "solar-panel",
    offset = {x = 3, y = -5},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "solar-panel-3",
    site_role = "solar-panel",
    entity_name = "solar-panel",
    offset = {x = -3, y = -8},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "solar-panel-4",
    site_role = "solar-panel",
    entity_name = "solar-panel",
    offset = {x = 3, y = -8},
    placement_search_radius = 0.5,
    placement_step = 0.5
  }
}

return constants

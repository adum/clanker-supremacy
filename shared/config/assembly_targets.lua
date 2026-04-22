return {
  solar_panel_factory = {
    display_name = "solar panel factory",
    target_item_name = "solar-panel",
    defer_power_poles_until_end = true,
    place_local_poles_with_power_task = true,
    anchor_mode = "base-infra-free-space",
    store_root_assembler_as_anchor_entity = true,
    skip_initial_power_validation = true,
    base_infra_search = {
      max_origins = 10,
      pole_search_radius = 96,
      use_registered_sites = true,
      include_power_poles = true
    },
    free_rectangle = {
      min_x = -1,
      max_x = 14,
      min_y = -8,
      max_y = 3
    },
    power_anchor_entity_name = "small-electric-pole",
    source_route_splitter = {
      entity_name = "splitter",
      item_name = "splitter"
    },
    source_route_extractor = {
      entity_name = "burner-inserter",
      item_name = "burner-inserter",
      fuel = {
        name = "coal",
        count = 4
      }
    },
    local_poles = {
      {
        id = "power-pole-entry",
        site_role = "power-pole",
        entity_name = "small-electric-pole",
        item_name = "small-electric-pole",
        offset = {x = 0, y = 1},
        is_power_entry = true
      },
      {
        id = "power-pole-cable",
        site_role = "power-pole",
        entity_name = "small-electric-pole",
        item_name = "small-electric-pole",
        offset = {x = 1, y = -1}
      },
      {
        id = "power-pole-circuit",
        site_role = "power-pole",
        entity_name = "small-electric-pole",
        item_name = "small-electric-pole",
        offset = {x = 5, y = -1}
      },
      {
        id = "power-pole-solar",
        site_role = "power-pole",
        entity_name = "small-electric-pole",
        item_name = "small-electric-pole",
        offset = {x = 9, y = -1}
      }
    },
    assembler_nodes = {
      {
        id = "copper-cable-assembler",
        site_role = "assembly-node",
        entity_name = "assembling-machine-1",
        item_name = "assembling-machine-1",
        recipe_name = "copper-cable",
        offset = {x = 2, y = -3}
      },
      {
        id = "electronic-circuit-assembler",
        site_role = "assembly-node",
        entity_name = "assembling-machine-1",
        item_name = "assembling-machine-1",
        recipe_name = "electronic-circuit",
        offset = {x = 6, y = -3}
      },
      {
        id = "solar-panel-assembler",
        site_role = "assembly-root",
        entity_name = "assembling-machine-1",
        item_name = "assembling-machine-1",
        recipe_name = "solar-panel",
        offset = {x = 10, y = -3}
      }
    },
    output_containers = {
      {
        id = "solar-panel-output-chest",
        site_role = "output-container",
        entity_name = "wooden-chest",
        item_name = "wooden-chest",
        offset = {x = 13, y = -3}
      }
    },
    internal_inserters = {
      {
        id = "copper-cable-to-circuit",
        site_role = "internal-inserter",
        source_node_id = "copper-cable-assembler",
        target_node_id = "electronic-circuit-assembler",
        entity_name = "burner-inserter",
        item_name = "burner-inserter",
        offset = {x = 4, y = -3},
        direction_name = "west",
        fuel = {
          name = "coal",
          count = 4
        }
      },
      {
        id = "circuit-to-solar-panel",
        site_role = "internal-inserter",
        source_node_id = "electronic-circuit-assembler",
        target_node_id = "solar-panel-assembler",
        entity_name = "burner-inserter",
        item_name = "burner-inserter",
        offset = {x = 8, y = -3},
        direction_name = "west",
        fuel = {
          name = "coal",
          count = 4
        }
      }
    },
    output_inserters = {
      {
        id = "solar-panel-output",
        site_role = "output-inserter",
        source_node_id = "solar-panel-assembler",
        target_container_id = "solar-panel-output-chest",
        entity_name = "burner-inserter",
        item_name = "burner-inserter",
        offset = {x = 12, y = -3},
        direction_name = "west",
        fuel = {
          name = "coal",
          count = 4
        }
      }
    },
    raw_input_routes = {
      {
        id = "iron-plate-line",
        item_name = "iron-plate",
        route_target_offset = {x = 6, y = -7},
        local_belt_offsets = {
          {x = 6, y = -6}
        },
        local_belt_direction_name = "south",
        input_inserters = {
          {
            id = "iron-to-electronic-circuit",
            site_role = "input-inserter",
            target_node_id = "electronic-circuit-assembler",
            entity_name = "burner-inserter",
            item_name = "burner-inserter",
            offset = {x = 6, y = -5},
            direction_name = "north",
            fuel = {
              name = "coal",
              count = 4
            }
          }
        }
      },
      {
        id = "copper-plate-to-solar-line",
        item_name = "copper-plate",
        route_target_offset = {x = 10, y = -7},
        local_belt_offsets = {
          {x = 10, y = -6}
        },
        local_belt_direction_name = "south",
        input_inserters = {
          {
            id = "copper-to-solar-panel",
            site_role = "input-inserter",
            target_node_id = "solar-panel-assembler",
            entity_name = "burner-inserter",
            item_name = "burner-inserter",
            offset = {x = 10, y = -5},
            direction_name = "north",
            fuel = {
              name = "coal",
              count = 4
            }
          }
        }
      },
      {
        id = "copper-plate-to-cable-line",
        item_name = "copper-plate",
        route_target_offset = {x = 2, y = -7},
        local_belt_offsets = {
          {x = 2, y = -6}
        },
        local_belt_direction_name = "south",
        input_inserters = {
          {
            id = "copper-to-cable",
            site_role = "input-inserter",
            target_node_id = "copper-cable-assembler",
            entity_name = "burner-inserter",
            item_name = "burner-inserter",
            offset = {x = 2, y = -5},
            direction_name = "north",
            fuel = {
              name = "coal",
              count = 4
            }
          }
        }
      },
      {
        id = "steel-plate-line",
        item_name = "steel-plate",
        route_target_offset = {x = 10, y = 1},
        local_belt_offsets = {
          {x = 10, y = 0}
        },
        local_belt_direction_name = "north",
        input_inserters = {
          {
            id = "steel-to-solar-panel",
            site_role = "input-inserter",
            target_node_id = "solar-panel-assembler",
            entity_name = "burner-inserter",
            item_name = "burner-inserter",
            offset = {x = 10, y = -1},
            direction_name = "south",
            fuel = {
              name = "coal",
              count = 4
            }
          }
        }
      },
    }
  },
  gun_turret_factory = {
    display_name = "gun turret factory",
    target_item_name = "gun-turret",
    defer_power_poles_until_end = true,
    place_local_poles_with_power_task = true,
    anchor_mode = "base-infra-free-space",
    store_root_assembler_as_anchor_entity = true,
    skip_initial_power_validation = true,
    base_infra_search = {
      max_origins = 10,
      pole_search_radius = 96,
      use_registered_sites = true,
      include_power_poles = true
    },
    free_rectangle = {
      min_x = -1,
      max_x = 10,
      min_y = -8,
      max_y = 3
    },
    power_anchor_entity_name = "small-electric-pole",
    source_route_splitter = {
      entity_name = "splitter",
      item_name = "splitter"
    },
    source_route_extractor = {
      entity_name = "burner-inserter",
      item_name = "burner-inserter",
      fuel = {
        name = "coal",
        count = 4
      }
    },
    local_poles = {
      {
        id = "power-pole-entry",
        site_role = "power-pole",
        entity_name = "small-electric-pole",
        item_name = "small-electric-pole",
        offset = {x = 0, y = 1},
        is_power_entry = true
      },
      {
        id = "power-pole-gear",
        site_role = "power-pole",
        entity_name = "small-electric-pole",
        item_name = "small-electric-pole",
        offset = {x = 1, y = -1}
      },
      {
        id = "power-pole-turret",
        site_role = "power-pole",
        entity_name = "small-electric-pole",
        item_name = "small-electric-pole",
        offset = {x = 5, y = -1}
      }
    },
    assembler_nodes = {
      {
        id = "iron-gear-assembler",
        site_role = "assembly-node",
        entity_name = "assembling-machine-1",
        item_name = "assembling-machine-1",
        recipe_name = "iron-gear-wheel",
        offset = {x = 2, y = -3}
      },
      {
        id = "gun-turret-assembler",
        site_role = "assembly-root",
        entity_name = "assembling-machine-1",
        item_name = "assembling-machine-1",
        recipe_name = "gun-turret",
        offset = {x = 6, y = -3}
      }
    },
    output_containers = {
      {
        id = "gun-turret-output-chest",
        site_role = "output-container",
        entity_name = "wooden-chest",
        item_name = "wooden-chest",
        offset = {x = 9, y = -3}
      }
    },
    internal_inserters = {
      {
        id = "gear-to-gun-turret",
        site_role = "internal-inserter",
        source_node_id = "iron-gear-assembler",
        target_node_id = "gun-turret-assembler",
        entity_name = "burner-inserter",
        item_name = "burner-inserter",
        offset = {x = 4, y = -3},
        direction_name = "west",
        fuel = {
          name = "coal",
          count = 4
        }
      }
    },
    output_inserters = {
      {
        id = "gun-turret-output",
        site_role = "output-inserter",
        source_node_id = "gun-turret-assembler",
        target_container_id = "gun-turret-output-chest",
        entity_name = "burner-inserter",
        item_name = "burner-inserter",
        offset = {x = 8, y = -3},
        direction_name = "west",
        fuel = {
          name = "coal",
          count = 4
        }
      }
    },
    raw_input_routes = {
      {
        id = "iron-plate-to-gear-line",
        item_name = "iron-plate",
        route_target_offset = {x = 2, y = -7},
        local_belt_offsets = {
          {x = 2, y = -6}
        },
        local_belt_direction_name = "south",
        input_inserters = {
          {
            id = "iron-to-gears",
            site_role = "input-inserter",
            target_node_id = "iron-gear-assembler",
            entity_name = "burner-inserter",
            item_name = "burner-inserter",
            offset = {x = 2, y = -5},
            direction_name = "north",
            fuel = {
              name = "coal",
              count = 4
            }
          }
        }
      },
      {
        id = "iron-plate-to-turret-line",
        item_name = "iron-plate",
        route_target_offset = {x = 6, y = -7},
        local_belt_offsets = {
          {x = 6, y = -6}
        },
        local_belt_direction_name = "south",
        input_inserters = {
          {
            id = "iron-to-gun-turret",
            site_role = "input-inserter",
            target_node_id = "gun-turret-assembler",
            entity_name = "burner-inserter",
            item_name = "burner-inserter",
            offset = {x = 6, y = -5},
            direction_name = "north",
            fuel = {
              name = "coal",
              count = 4
            }
          }
        }
      },
      {
        id = "copper-plate-line",
        item_name = "copper-plate",
        route_target_offset = {x = 6, y = 1},
        local_belt_offsets = {
          {x = 6, y = 0}
        },
        local_belt_direction_name = "north",
        input_inserters = {
          {
            id = "copper-to-gun-turret",
            site_role = "input-inserter",
            target_node_id = "gun-turret-assembler",
            entity_name = "burner-inserter",
            item_name = "burner-inserter",
            offset = {x = 6, y = -1},
            direction_name = "south",
            fuel = {
              name = "coal",
              count = 4
            }
          }
        }
      },
    }
  }
}

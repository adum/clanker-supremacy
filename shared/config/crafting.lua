return {
  recipes = {
    ["wooden-chest"] = {
      craft_ticks = 30,
      ingredients = {
        {name = "wood", count = 4}
      }
    },
    ["stone-furnace"] = {
      craft_ticks = 210,
      ingredients = {
        {name = "stone", count = 5}
      }
    },
    ["iron-gear-wheel"] = {
      craft_ticks = 30,
      ingredients = {
        {name = "iron-plate", count = 2}
      }
    },
    ["copper-cable"] = {
      craft_ticks = 15,
      result_count = 2,
      ingredients = {
        {name = "copper-plate", count = 1}
      }
    },
    ["electronic-circuit"] = {
      craft_ticks = 30,
      ingredients = {
        {name = "iron-plate", count = 1},
        {name = "copper-cable", count = 3}
      }
    },
    ["burner-mining-drill"] = {
      craft_ticks = 120,
      ingredients = {
        {name = "iron-gear-wheel", count = 3},
        {name = "iron-plate", count = 3},
        {name = "stone-furnace", count = 1}
      }
    },
    ["assembling-machine-1"] = {
      craft_ticks = 30,
      ingredients = {
        {name = "iron-plate", count = 9},
        {name = "iron-gear-wheel", count = 5},
        {name = "electronic-circuit", count = 3}
      }
    },
    ["burner-inserter"] = {
      craft_ticks = 30,
      ingredients = {
        {name = "iron-plate", count = 1},
        {name = "iron-gear-wheel", count = 1}
      }
    },
    ["transport-belt"] = {
      craft_ticks = 15,
      result_count = 2,
      ingredients = {
        {name = "iron-plate", count = 1},
        {name = "iron-gear-wheel", count = 1}
      }
    },
    ["underground-belt"] = {
      craft_ticks = 60,
      result_count = 2,
      ingredients = {
        {name = "iron-plate", count = 10},
        {name = "transport-belt", count = 5}
      }
    },
    ["splitter"] = {
      craft_ticks = 60,
      ingredients = {
        {name = "electronic-circuit", count = 5},
        {name = "iron-plate", count = 5},
        {name = "transport-belt", count = 4}
      }
    },
    ["small-electric-pole"] = {
      craft_ticks = 30,
      result_count = 2,
      ingredients = {
        {name = "wood", count = 1},
        {name = "copper-cable", count = 2}
      }
    },
    ["gun-turret"] = {
      craft_ticks = 480,
      ingredients = {
        {name = "iron-gear-wheel", count = 10},
        {name = "copper-plate", count = 10},
        {name = "iron-plate", count = 20}
      }
    },
    ["solar-panel"] = {
      craft_ticks = 600,
      ingredients = {
        {name = "steel-plate", count = 5},
        {name = "electronic-circuit", count = 15},
        {name = "copper-plate", count = 5}
      }
    }
  }
}

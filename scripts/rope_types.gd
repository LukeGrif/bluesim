extends Reference

# The test-rope options shown in the menu (and accepted by BLUESIM_ROPE etc.,
# see globals.gd). Shared by the menu, the rope (target_rope.gd) and the post.

# Rope materials: density of the rope (kg/m3) against the pool's fresh
# water (1000 kg/m3) decides whether it floats or sinks. 0 = a fixed rod
# with no physics (the original test rope; K/L lean it).
const MATERIALS = [
	{"key": "fixed", "name": "Fixed rod (no physics)", "density": 0.0},
	{"key": "polypropylene", "name": "Polypropylene (floats)", "density": 910.0},
	{"key": "dyneema", "name": "Dyneema / HMPE (floats slightly)", "density": 975.0},
	{"key": "nylon", "name": "Nylon (sinks slowly)", "density": 1140.0},
	{"key": "polyester", "name": "Polyester (sinks)", "density": 1380.0},
	{"key": "leadcore", "name": "Lead-core (sinks fast)", "density": 2000.0},
]

# How a physics rope is held. "surface_floor" is pinned at the water surface
# and at the floor (the length is the depth); the others have a free end.
const SETUPS = [
	{"key": "surface_floor", "name": "Surface to floor"},
	{"key": "hanging", "name": "Hanging from the surface"},
	{"key": "standing", "name": "Standing on the floor"},
]

const LENGTHS = [5.0, 10.0, 20.0]  # m, for a rope with a free end

const CURRENT_SPEEDS = [0.0, 0.1, 0.25, 0.5]  # m/s
# where the current comes from: angle from the ROV's forward direction when
# the rope is placed, turning left (seen from above)
const CURRENT_DIRECTIONS = [
	{"key": "left", "name": "from the left", "angle": 90.0},
	{"key": "right", "name": "from the right", "angle": -90.0},
	{"key": "ahead", "name": "from ahead", "angle": 0.0},
	{"key": "behind", "name": "from behind", "angle": 180.0},
]

const POSTS = [
	{"key": "none", "name": "No post", "diameter": 0.0},
	{"key": "pile", "name": "Pile, 0.3 m", "diameter": 0.3},
	{"key": "pole", "name": "Pole, 0.1 m", "diameter": 0.1},
]


static func find(list, key):
	for i in range(list.size()):
		if typeof(list[i]) == TYPE_DICTIONARY and list[i]["key"] == key:
			return i
	return -1

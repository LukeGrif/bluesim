extends Node

const colors = {
	"blizzard_blue": Color("#a5d6f1"),
}

export var surface_ambient = colors['blizzard_blue']
export var deep_ambient = colors['blizzard_blue']
export var current_ambient = colors['blizzard_blue']
export var deep_factor = 0.0
export var enable_godray = true
export var fancy_water = true
export var ping360_enabled = true
export var wait_SITL = false
export var isHTML5 = false
export var physics_rate = 60
export var wind_dir = 0
export var wind_speed = 5
var active_vehicle = null
var active_level = ""
var sitl_pid = 0
var external_sitl = false

# Test rope, current and post (scripts/rope_types.gd lists the options).
# Chosen in the menu, or set before starting with environment variables:
#   BLUESIM_ROPE=nylon,hanging,10     material, setup, length (m)
#   BLUESIM_CURRENT=0.25,left         speed (m/s), where it comes from
#   BLUESIM_POST=pile                 none, pile or pole
var rope_material = 0  # index into RopeTypes.MATERIALS
var rope_setup = 0  # index into RopeTypes.SETUPS
var rope_length = 10.0
var current_speed = 0.0
var current_direction = 0  # index into RopeTypes.CURRENT_DIRECTIONS
var current_velocity = Vector3()  # world frame, set when the rope is placed
var post_type = 0  # index into RopeTypes.POSTS
# BLUESIM_CAPTURE=<folder>: make training pictures (scripts/capture.gd)
var capturing = OS.get_environment("BLUESIM_CAPTURE") != ""

const RopeTypes = preload("res://scripts/rope_types.gd")


func _ready():
	isHTML5 = OS.get_name() == "HTML5"
	read_test_settings_from_environment()


func read_test_settings_from_environment():
	var rope = OS.get_environment("BLUESIM_ROPE").to_lower().split(",")
	if rope.size() >= 1 and RopeTypes.find(RopeTypes.MATERIALS, rope[0]) >= 0:
		rope_material = RopeTypes.find(RopeTypes.MATERIALS, rope[0])
	if rope.size() >= 2 and RopeTypes.find(RopeTypes.SETUPS, rope[1]) >= 0:
		rope_setup = RopeTypes.find(RopeTypes.SETUPS, rope[1])
	if rope.size() >= 3 and float(rope[2]) > 0:
		rope_length = float(rope[2])
	var current = OS.get_environment("BLUESIM_CURRENT").to_lower().split(",")
	if current.size() >= 1 and current[0] != "":
		current_speed = max(0.0, float(current[0]))
	if current.size() >= 2 and RopeTypes.find(RopeTypes.CURRENT_DIRECTIONS, current[1]) >= 0:
		current_direction = RopeTypes.find(RopeTypes.CURRENT_DIRECTIONS, current[1])
	var post = RopeTypes.find(RopeTypes.POSTS, OS.get_environment("BLUESIM_POST").to_lower())
	if post >= 0:
		post_type = post

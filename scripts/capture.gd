extends Node

# Training data for rope segmentation (sim-to-real), made automatically.
# Start BlueSim with BLUESIM_CAPTURE set to a folder (it goes straight to the
# pool, no SITL needed):
#   BLUESIM_CAPTURE=~/rope_data ./run_bluesim.sh
#   BLUESIM_CAPTURE_COUNT=1000        number of pictures (default 500)
#   BLUESIM_CAPTURE_SIZE=1920x1080    picture size (default: the BlueROV2 camera's)
#   BLUESIM_CAPTURE_SEED=1            random seed (default 1, for a repeatable set)
# Every picture is taken by a camera like the BlueROV2's (80 deg horizontal
# field of view), with randomised rope (type, lean, current, look),
# water (colour, visibility) and light, in one of two ways:
# - ROV view (most pictures): from the ROV's own camera, tilted down so the
#   gripper is in the picture, with the ROV approaching the rope, at the jaws
#   or with the rope in the jaws (the ROV is moved there for the picture);
# - orbit view: from anywhere 0.25-4 m around the rope (or, a quarter of
#   them, the ROV's tether). About 1 in 10 has no rope in view.
# Hard negatives: many pictures also have tether-like cables (random colour,
# mostly yellow) crossing the rope, lying alongside it or looping in front of
# the camera/gripper, and some ropes are yellow, so a detector learns the
# rope's shape and texture, not "yellow = tether".
# The physics is paused for each picture, so the label matches it exactly.
# Writes images/NNNNNN.png, rov_depth/NNNNNN.png (distance to the ROV's own
# parts, for what the gripper hides) and labels/NNNNNN.json (camera model,
# the rope's centre line in camera coordinates, its diameter, the ROV's
# tether, the cables, the post, the settings).
# Rope_Detection/dataset/make_masks.py turns the labels into masks.

const RopeTypes = preload("res://scripts/rope_types.gd")

const HFOV = 80.0  # deg, BlueROV2 Low-Light HD USB Camera
const PICTURES_PER_SCENE = 20  # new rope/post/current after this many pictures
const SETTLE_TIME = 3.0  # s of physics after building a new rope
const MOVE_TIME = 0.3  # s of physics between pictures (the rope moves a bit)
const NO_ROPE_FRACTION = 0.1
const TETHER_VIEW_FRACTION = 0.25  # pictures aimed at the ROV's tether instead of the rope
const TETHER_DIAMETER = 0.012  # m, as drawn (rope/section.tscn)
const TETHER_PIECE = 0.145  # m, length of each tether piece
const MIN_DISTANCE = 0.25  # m
const MAX_DISTANCE = 4.0
const ROV_VIEW_FRACTION = 0.6  # pictures from the ROV's camera, gripper in view
const JAWS = Vector3(0, -0.26, 0.12)  # middle of the jaws from the camera, ROV frame (forward +Z)
const DEPTH_LAYER = 19  # render layer of the ROV's depth copies (only the depth camera sees it)
const DEPTH_MAX = 4.0  # m, distance range of rov_depth/ pictures
const SCENE_LAYER = 18  # render layer of the rope, tether and cables (hidden from the scene-depth camera)
const SCENE_QUAD_LAYER = 17  # render layer of the scene-depth camera's full-screen quad (only it sees it)
const SCENE_DEPTH_MAX = 30.0  # m, distance range of scene_depth/ pictures
# The scene-depth camera's picture: every pixel's distance to whatever the
# world has there (walls, floor, pilings, a wreck, the ROV), from the depth
# buffer, in the same encoding as DEPTH_SHADER (blue 1 = nothing: open water).
const SCENE_DEPTH_SHADER = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disable, shadows_disabled;
uniform float max_depth = 30.0;
void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 0.0, 1.0);  // the whole screen
}
void fragment() {
	float d = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	if (d >= 0.99999) {
		ALBEDO = vec3(1.0);
	} else {
		vec3 ndc = vec3(SCREEN_UV, d) * 2.0 - 1.0;
		vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		view.xyz /= view.w;
		float x = clamp(length(view.xyz) / max_depth, 0.0, 0.9999);
		ALBEDO = vec3(floor(x * 255.0) / 255.0, fract(x * 255.0), 0.0);
	}
	ALPHA = 1.0;
}
"""
const DEPTH_SHADER = """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;
uniform float max_depth = 4.0;
void fragment() {
	// distance from the camera in red (coarse) and green (fine); blue 0 marks the ROV
	float x = clamp(length(VERTEX) / max_depth, 0.0, 0.9999);
	ALBEDO = vec3(floor(x * 255.0) / 255.0, fract(x * 255.0), 0.0);
}
"""

var folder = ""
var count = 500
var size = Vector2(1920, 1080)
var rng = RandomNumberGenerator.new()
var viewport = null
var camera = null
var lamp = null
var environment = null
var rope = null
var post = null
var sun = null
var index = 0
var state = "wait"
var timer = 0.0
var frames = 0
var info = {}  # settings of the current scene, saved in each label
var rov = null
var rov_bodies = []  # the ROV and its two jaws
var saved_transforms = {}  # where they were before a ROV view
var ljoint = null
var rjoint = null
var depth_viewport = null
var depth_camera = null
var scene_viewport = null
var scene_camera = null
var cables = []  # this picture's tether-like cables: {node, diameter, points, kind}


func _ready():
	folder = OS.get_environment("BLUESIM_CAPTURE")
	if folder == "":
		set_process(false)
		return
	if folder.begins_with("~"):
		folder = OS.get_environment("HOME") + folder.substr(1)
	pause_mode = Node.PAUSE_MODE_PROCESS  # keeps running while the physics is paused
	if OS.get_environment("BLUESIM_CAPTURE_COUNT") != "":
		count = int(OS.get_environment("BLUESIM_CAPTURE_COUNT"))
	var s = OS.get_environment("BLUESIM_CAPTURE_SIZE").to_lower().split("x")
	if s.size() == 2 and int(s[0]) > 0 and int(s[1]) > 0:
		size = Vector2(int(s[0]), int(s[1]))
	rng.seed = int(OS.get_environment("BLUESIM_CAPTURE_SEED")) if OS.get_environment("BLUESIM_CAPTURE_SEED") != "" else 1
	var dir = Directory.new()
	dir.make_dir_recursive(folder + "/images")
	dir.make_dir_recursive(folder + "/labels")
	dir.make_dir_recursive(folder + "/rov_depth")
	dir.make_dir_recursive(folder + "/scene_depth")
	print("Capture: %d pictures, %dx%d, into %s" % [count, size.x, size.y, folder])


func setup_camera():
	var rov_camera = get_tree().get_root().find_node("BlueRov", true, false).get_node("Camera")
	viewport = Viewport.new()
	viewport.size = size
	viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	viewport.shadow_atlas_size = rov_camera.get_viewport().shadow_atlas_size
	viewport.shadow_atlas_quad_1 = rov_camera.get_viewport().shadow_atlas_quad_1
	camera = Camera.new()
	camera.keep_aspect = Camera.KEEP_WIDTH  # fov is horizontal
	camera.fov = HFOV
	camera.near = 0.05
	camera.far = rov_camera.far
	camera.cull_mask = rov_camera.cull_mask
	environment = rov_camera.environment.duplicate()
	environment.background_mode = Environment.BG_COLOR
	camera.environment = environment
	lamp = SpotLight.new()  # the ROV's lights, next to the camera
	lamp.spot_angle = 45.0
	lamp.spot_range = 10.0
	camera.add_child(lamp)
	viewport.add_child(camera)
	add_child(viewport)
	camera.current = true
	sun = get_tree().get_root().find_node("sun", true, false)
	setup_rov_depth(rov_camera)
	setup_scene_depth()


# A second camera that sees only copies of the ROV's parts, drawn as their
# distance from the camera, so make_masks.py knows where the gripper/frame
# hides the rope (and where the rope is in front of the jaws).
func setup_rov_depth(rov_camera):
	rov = rov_camera.get_parent()
	var assembly = rov.get_parent()
	rov_bodies = [rov]
	for name in ["RigidBody", "RigidBody2"]:  # the jaws
		if assembly.has_node(name):
			rov_bodies.append(assembly.get_node(name))
	ljoint = assembly.get_node("ljoint")
	rjoint = assembly.get_node("rjoint")
	camera.cull_mask &= ~(1 << DEPTH_LAYER)
	rov_camera.cull_mask &= ~(1 << DEPTH_LAYER)
	depth_viewport = Viewport.new()
	depth_viewport.size = size
	depth_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	depth_viewport.hdr = false
	depth_viewport.keep_3d_linear = true
	depth_camera = Camera.new()
	depth_camera.keep_aspect = Camera.KEEP_WIDTH
	depth_camera.fov = HFOV
	depth_camera.near = camera.near
	depth_camera.far = DEPTH_MAX + 1.0
	depth_camera.cull_mask = 1 << DEPTH_LAYER
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1, 1, 1)
	depth_camera.environment = env
	depth_viewport.add_child(depth_camera)
	add_child(depth_viewport)
	depth_camera.current = true
	var material = ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = DEPTH_SHADER
	material.set_shader_param("max_depth", DEPTH_MAX)
	for body in rov_bodies:
		add_depth_copies(body, material)


# A third camera that sees the world without the rope, tether and cables
# (moved to SCENE_LAYER), rendering a full-screen quad that turns its depth
# buffer into distances: make_masks.py hides the rope wherever something
# (a piling, a wreck, the floor) is in front of it, in any world.
func setup_scene_depth():
	for c in all_cameras(get_tree().get_root()):  # no other camera draws the quad
		c.cull_mask &= ~(1 << SCENE_QUAD_LAYER)
	scene_viewport = Viewport.new()
	scene_viewport.size = size
	scene_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	scene_viewport.hdr = false
	scene_viewport.keep_3d_linear = true
	scene_viewport.shadow_atlas_size = 0
	scene_camera = Camera.new()
	scene_camera.keep_aspect = Camera.KEEP_WIDTH
	scene_camera.fov = HFOV
	scene_camera.near = camera.near
	scene_camera.far = camera.far
	scene_camera.cull_mask = (camera.cull_mask & ~(1 << SCENE_LAYER) & ~(1 << DEPTH_LAYER)) | (1 << SCENE_QUAD_LAYER)
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1, 1, 1)
	scene_camera.environment = env
	scene_viewport.add_child(scene_camera)
	add_child(scene_viewport)
	scene_camera.current = true
	var material = ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = SCENE_DEPTH_SHADER
	material.set_shader_param("max_depth", SCENE_DEPTH_MAX)
	var quad = MeshInstance.new()
	quad.mesh = QuadMesh.new()
	quad.material_override = material
	quad.layers = 1 << SCENE_QUAD_LAYER
	quad.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
	quad.extra_cull_margin = 16384
	quad.transform = Transform(Basis(), Vector3(0, 0, -1))
	scene_camera.add_child(quad)


func all_cameras(node):
	var out = []
	if node is Camera:
		out.append(node)
	for child in node.get_children():
		out += all_cameras(child)
	return out


# Move a node's meshes to SCENE_LAYER (still drawn by the capture camera).
func hide_from_scene_depth(node):
	if node is MeshInstance:
		node.layers = 1 << SCENE_LAYER
	for child in node.get_children():
		hide_from_scene_depth(child)


func add_depth_copies(node, material):
	for child in node.get_children():
		add_depth_copies(child, material)
		# only what the camera sees (the sonar's beam is a hidden mesh, layers 0)
		if child is MeshInstance and child.layers & camera.cull_mask and child.is_visible_in_tree() \
				and not child.name.begins_with("light_glow"):
			var copy = MeshInstance.new()
			copy.mesh = child.mesh
			copy.material_override = material
			copy.layers = 1 << DEPTH_LAYER
			copy.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
			child.add_child(copy)


func _process(delta):
	if state == "wait":
		rope = get_tree().get_root().find_node("TargetRope", true, false)
		post = get_tree().get_root().find_node("TestPost", true, false)
		if rope != null and rope.placed:
			setup_camera()
			state = "scene"
		return
	if state == "scene":
		new_scene()
		get_tree().paused = false
		timer = SETTLE_TIME
		state = "settle"
	elif state == "settle":
		timer -= delta
		if timer <= 0:
			get_tree().paused = true
			new_view()
			depth_camera.global_transform = camera.global_transform
			scene_camera.global_transform = camera.global_transform
			frames = 3  # let the new view render
			state = "render"
	elif state == "render":
		frames -= 1
		if frames <= 0:
			save()
			restore_rov()
			clear_cables()
			index += 1
			if index >= count:
				print("Capture: done, %d pictures in %s" % [count, folder])
				get_tree().quit()
				return
			if index % PICTURES_PER_SCENE == 0:
				state = "scene"
			else:
				get_tree().paused = false
				timer = MOVE_TIME
				state = "settle"


# A new rope (type, setup, lean, current, colour) and post.
func new_scene():
	var rov_camera = get_tree().get_root().find_node("BlueRov", true, false).get_node("Camera")
	var ahead = -rov_camera.global_transform.basis.z
	ahead.y = 0
	ahead = ahead.normalized()
	var point = rov_camera.global_transform.origin + ahead * 3.0
	# a real (physics) rope: never the fixed rod, a featureless straight pole
	Globals.rope_material = rng.randi_range(1, RopeTypes.MATERIALS.size() - 1)
	Globals.rope_setup = rng.randi_range(0, RopeTypes.SETUPS.size() - 1)
	Globals.rope_length = RopeTypes.LENGTHS[rng.randi_range(0, RopeTypes.LENGTHS.size() - 1)]
	Globals.current_speed = RopeTypes.CURRENT_SPEEDS[rng.randi_range(0, RopeTypes.CURRENT_SPEEDS.size() - 1)]
	Globals.current_direction = rng.randi_range(0, RopeTypes.CURRENT_DIRECTIONS.size() - 1)
	rope.lean_side = rng.randi_range(0, rope.LEANS_SIDE.size() - 1)
	rope.lean_ahead = rng.randi_range(0, rope.LEANS_AHEAD.size() - 1)
	rope.place_at(point, ahead)
	# no test post (pile/pole) in the pictures: it isn't in the real scenes
	Globals.post_type = 0
	post.place_at(point)
	# the jaws open or closed for this scene (they move while it settles)
	var jaws_open = rng.randf() < 0.6
	set_jaws(1.0 if jaws_open else -1.0)
	info = {
		"jaws_open": jaws_open,
		"rope": RopeTypes.MATERIALS[Globals.rope_material]["key"],
		"setup": RopeTypes.SETUPS[Globals.rope_setup]["key"],
		"length": Globals.rope_length,
		"current": Globals.current_speed,
	}


# A random rope look: twisted or braided (not smooth: real ropes have strands), coloured like a
# marine rope (or a red like the real one, or anything), sometimes with a
# tracer/fleck or loose fibres, so a detector learns the rope's shape and
# texture rather than one colour.
func random_look():
	var r = rng.randf()
	var construction = 0 if r < 0.5 else 1
	var color
	r = rng.randf()
	if r < 0.3:  # reds like the real rope
		color = Color.from_hsv(fposmod(rng.randf_range(-0.05, 0.04), 1.0), rng.randf_range(0.6, 1.0), rng.randf_range(0.35, 0.9))
	elif r < 0.45:  # yellows, like the tether, so yellow alone never means "tether"
		color = Color.from_hsv(rng.randf_range(0.1, 0.18), rng.randf_range(0.6, 1.0), rng.randf_range(0.5, 1.0))
	elif r < 0.8:  # a marine rope colour, varied a little
		var base = RopeTypes.LOOKS[rng.randi_range(0, RopeTypes.LOOKS.size() - 1)]["color"]
		color = Color.from_hsv(fposmod(base.h + rng.randf_range(-0.03, 0.03), 1.0),
			clamp(base.s * rng.randf_range(0.8, 1.2), 0.0, 1.0), clamp(base.v * rng.randf_range(0.7, 1.2), 0.03, 1.0))
	else:  # anything
		color = Color.from_hsv(rng.randf(), rng.randf_range(0.0, 1.0), rng.randf_range(0.1, 1.0))
	var tracer = null
	if construction < 2 and rng.randf() < 0.3:
		var tracers = [Color(0.9, 0.9, 0.9), Color(0.75, 0.05, 0.05), Color(0.05, 0.2, 0.7), Color(0.95, 0.75, 0.05), Color(0.03, 0.03, 0.03)]
		tracer = tracers[rng.randi_range(0, tracers.size() - 1)] if rng.randf() < 0.8 else Color.from_hsv(rng.randf(), 0.8, 0.8)
	var fuzz = rng.randf_range(0.3, 1.0) if construction == 0 and rng.randf() < 0.15 else 0.0
	return {"key": "random", "name": "random", "construction": construction, "color": color, "tracer": tracer, "fuzz": fuzz}


# Water, light, a camera pose (from the ROV or from around the rope) and
# some tether-like cables.
func new_view():
	set_jaws(0.0)
	var points = rope.rope_points()
	var water = get_tree().get_root().find_node("water", true, false)
	var surface = water.global_transform.origin.y
	var tether = tether_pieces()
	for key in ["phase", "camera_tilt_deg"]:
		info.erase(key)
	var near = null  # [point on the rope, its direction] that the picture is about
	if rng.randf() < ROV_VIEW_FRACTION:
		near = rov_view(points, surface)
	else:
		near = orbit_view(points, surface, tether)
	add_cables(near[0], near[1], surface)
	set_looks(tether)
	hide_from_scene_depth(rope)
	for piece in tether:
		hide_from_scene_depth(piece)

# The camera somewhere around a point on the rope (or the tether).
func orbit_view(points, surface, tether):
	# a random point along the rope, under water (or, sometimes, on the tether,
	# so the detector sees plenty of tether and learns it is not the rope)
	var target = null
	var along = Vector3.UP
	var at_tether = not tether.empty() and rng.randf() < TETHER_VIEW_FRACTION
	if at_tether:
		target = tether[rng.randi_range(0, tether.size() - 1)].global_transform.origin
	for _i in range(0 if at_tether else 50):
		var k = rng.randi_range(0, points.size() - 2)
		var p = points[k].linear_interpolate(points[k + 1], rng.randf())
		if p.y < surface - 0.5:
			target = p
			along = (points[k + 1] - points[k]).normalized()
			break
	if target == null:
		target = points[-1]
	# camera somewhere around it, not inside the post
	var position = target
	for _i in range(50):
		var distance = exp(rng.randf_range(log(MIN_DISTANCE), log(MAX_DISTANCE)))
		var heading = rng.randf_range(0, 2 * PI)
		var elevation = deg2rad(rng.randf_range(-30, 30))
		position = target + distance * Vector3(cos(elevation) * cos(heading), sin(elevation), cos(elevation) * sin(heading))
		position.y = min(position.y, surface - 0.3)
		if post.info() == null:
			break
		var axis = post.info()["top"]
		if Vector2(position.x - axis.x, position.z - axis.z).length() > post.diameter() / 2.0 + 0.2:
			break
	var up = Vector3.UP
	var t = Transform(Basis(), position).looking_at(target, up)
	# turn so the rope isn't always in the middle, and sometimes out of view
	var vfov = rad2deg(2 * atan(tan(deg2rad(HFOV / 2)) * size.y / size.x))
	var yaw = rng.randf_range(-0.45, 0.45) * HFOV
	var pitch = rng.randf_range(-0.45, 0.45) * vfov
	var looking_away = rng.randf() < NO_ROPE_FRACTION
	if looking_away:
		yaw = rng.randf_range(70, 180) * (1 if rng.randf() < 0.5 else -1)
	t.basis = t.basis.rotated(Vector3.UP, deg2rad(yaw))
	t.basis = t.basis.rotated(t.basis.x.normalized(), deg2rad(pitch))
	t.basis = t.basis.rotated(t.basis.z.normalized(), deg2rad(rng.randf_range(-10, 10)))
	camera.global_transform = t

	info["view"] = "orbit"
	info["aimed_at_tether"] = at_tether
	info["looking_away"] = looking_away
	if at_tether:  # cables near the camera rather than the rope
		return [camera.global_transform.origin - camera.global_transform.basis.z.normalized() * 1.0, along]
	return [target, along]


# The ROV's own camera, tilted down so the jaws are in the picture: the ROV
# is moved (for this picture only) to approach the rope, be at the jaws or
# have the rope in them.
func rov_view(points, surface):
	var bottom = points[0].y
	for q in points:
		bottom = min(bottom, q.y)
	var k = 0
	var p = null
	for _i in range(50):
		k = rng.randi_range(0, points.size() - 2)
		var q = points[k].linear_interpolate(points[k + 1], rng.randf())
		if q.y < surface - 0.7 and q.y > bottom + 0.4:
			p = q
			break
	if p == null:
		k = int(points.size() / 2) - 1
		p = points[k]
	var along = (points[k + 1] - points[k]).normalized()
	var heading = rng.randf_range(0, 2 * PI)
	var forward = Vector3(sin(heading), 0, cos(heading))
	var side = Vector3.UP.cross(forward)
	# where the rope is from the middle of the jaws (ahead, to the side, up)
	var phase
	var ahead
	var across
	var height
	var r = rng.randf()
	if r < 0.25:
		phase = "in_jaws"
		ahead = rng.randf_range(-0.04, 0.04)
		across = rng.randf_range(-0.03, 0.03)
		height = rng.randf_range(-0.05, 0.05)
	elif r < 0.5:
		phase = "at_jaws"
		ahead = rng.randf_range(0.06, 0.35)
		across = rng.randf_range(-0.15, 0.15)
		height = rng.randf_range(-0.1, 0.1)
	elif r < 0.92:
		phase = "approach"
		ahead = exp(rng.randf_range(log(0.35), log(2.5)))
		across = rng.randf_range(-0.5, 0.5) * ahead
		height = rng.randf_range(-0.3, 0.3)
	else:
		phase = "rope_beside"  # rope off to the side, maybe out of view
		ahead = rng.randf_range(0.3, 2.0)
		across = rng.randf_range(1.0, 2.0) * (1 if rng.randf() < 0.5 else -1)
		height = rng.randf_range(-0.3, 0.3)
	var jaws_world = p - forward * ahead - side * across - Vector3.UP * height
	var basis = Basis(side, Vector3.UP, forward)
	basis = basis.rotated(Vector3.UP, deg2rad(rng.randf_range(-10, 10)))
	basis = basis.rotated(basis.x.normalized(), deg2rad(rng.randf_range(-4, 4)))
	basis = basis.rotated(basis.z.normalized(), deg2rad(rng.randf_range(-4, 4)))
	var rov_camera = rov.get_node("Camera")
	var origin = jaws_world - basis.xform(rov_camera.transform.origin + JAWS)
	origin.y = min(origin.y, surface - 0.4)
	move_rov(Transform(basis, origin))
	# tilt the camera down (the real one tilts +/-90 deg; BlueSim's 45)
	var tilt = rng.randf_range(25, 45) if rng.randf() < 0.85 else rng.randf_range(0, 25)
	var old_tilt = rov_camera.rotation_degrees.x
	rov_camera.rotation_degrees.x = -tilt
	camera.global_transform = rov_camera.global_transform
	rov_camera.rotation_degrees.x = old_tilt
	info["view"] = "rov"
	info["phase"] = phase
	info["camera_tilt_deg"] = tilt
	info["aimed_at_tether"] = false
	info["looking_away"] = false
	return [p, along]


func move_rov(t):
	restore_rov()
	var delta = t * rov.global_transform.affine_inverse()
	for body in rov_bodies:
		saved_transforms[body] = body.global_transform
		body.global_transform = delta * body.global_transform


func restore_rov():
	for body in saved_transforms:
		body.global_transform = saved_transforms[body]
	saved_transforms = {}


func set_jaws(speed):
	if ljoint != null:
		ljoint.set_param(HingeJoint.PARAM_MOTOR_TARGET_VELOCITY, speed)
		rjoint.set_param(HingeJoint.PARAM_MOTOR_TARGET_VELOCITY, -speed)


# Water, light and the rope's and tether's looks for this picture.
func set_looks(tether):
	# water: tint and visibility; light: sun, ambient and the ROV's lamp
	var tint = Color.from_hsv(rng.randf_range(0.45, 0.62), rng.randf_range(0.3, 0.9), rng.randf_range(0.15, 0.7))
	environment.background_color = tint
	environment.fog_color = tint
	environment.fog_depth_begin = rng.randf_range(0.0, 2.0)
	environment.fog_depth_end = environment.fog_depth_begin + exp(rng.randf_range(log(2.0), log(30.0)))
	environment.ambient_light_color = tint.lightened(rng.randf_range(0.0, 0.5))
	environment.ambient_light_energy = rng.randf_range(0.2, 1.2)
	lamp.light_energy = rng.randf_range(0.0, 4.0) if rng.randf() < 0.7 else 0.0
	if sun != null:
		sun.light_energy = rng.randf_range(0.0, 1.0)
	# a new rope look for every picture (it's only a change of colours in the shader)
	var look = random_look()
	rope.set_look(look)
	info["rope_color"] = [look["color"].r, look["color"].g, look["color"].b]
	info["construction"] = ["3-strand", "braided", "smooth"][look["construction"]]
	info["tracer"] = look["tracer"] != null
	info["fuzz"] = look["fuzz"]
	# the tether in a random colour (mostly yellow, like a Fathom tether)
	var tether_color = random_tether_color()
	if not tether.empty():
		var mesh_instance = tether[0].get_node("MeshInstance")
		var material = mesh_instance.mesh.material  # shared by all the pieces
		if material is SpatialMaterial:
			material.albedo_color = tether_color
	info["tether_color"] = [tether_color.r, tether_color.g, tether_color.b]
	info["visibility_m"] = environment.fog_depth_end
	info["water_color"] = [tint.r, tint.g, tint.b]
	info["lamp"] = lamp.light_energy


# The ROV's tether pieces (RigidBody capsules along their Z axis), in order.
func tether_pieces():
	var holder = get_tree().get_root().find_node("theter", true, false)
	var out = []
	if holder != null:
		for child in holder.get_children():
			if child is RigidBody and child.has_node("MeshInstance"):
				out.append(child)
	return out


func random_tether_color():
	var r = rng.randf()
	if r < 0.5:  # yellow
		return Color.from_hsv(rng.randf_range(0.11, 0.15), rng.randf_range(0.7, 1.0), rng.randf_range(0.6, 1.0))
	var colors = [Color(0.05, 0.2, 0.7), Color(0.03, 0.03, 0.03), Color(0.9, 0.9, 0.88), Color(0.95, 0.4, 0.05), Color(0.1, 0.45, 0.15), Color(0.5, 0.5, 0.5)]
	var c = colors[rng.randi_range(0, colors.size() - 1)]
	return Color.from_hsv(c.h, c.s, clamp(c.v * rng.randf_range(0.7, 1.2), 0.02, 1.0))


func random_unit():
	var v = Vector3(rng.randfn(), rng.randfn(), rng.randfn())
	return v.normalized() if v.length() > 1e-6 else Vector3.UP


# Hard negatives: 0-2 cables like a tether (smooth, 6-16 mm, mostly yellow)
# crossing the rope, alongside it, or in front of the camera/gripper (some
# looped). make_masks.py labels them as tether.
func add_cables(anchor, along, surface):
	var r = rng.randf()
	var n = 0 if r < 0.4 else (1 if r < 0.85 else 2)
	var kinds = []
	for _i in range(n):
		r = rng.randf()
		var kind
		if info["view"] == "rov":
			kind = "front" if r < 0.45 else ("cross" if r < 0.8 else "alongside")
		else:
			kind = "cross" if r < 0.45 else ("alongside" if r < 0.75 else "front")
		var diameter = rng.randf_range(0.006, 0.016)
		var points = cable_points(kind, anchor, along, diameter)
		for k in range(points.size()):
			points[k].y = min(points[k].y, surface - diameter)
		var material = SpatialMaterial.new()
		material.albedo_color = random_tether_color()
		material.roughness = rng.randf_range(0.3, 0.8)
		material.params_cull_mode = SpatialMaterial.CULL_DISABLED
		var node = MeshInstance.new()
		node.mesh = tube_mesh(points, diameter / 2.0)
		node.material_override = material
		node.layers = 1 << SCENE_LAYER
		add_child(node)
		cables.append({"node": node, "diameter": diameter, "points": points})
		kinds.append(kind)
	info["cables"] = kinds


func cable_points(kind, anchor, along, diameter):
	var cam = camera.global_transform
	var look = -cam.basis.z.normalized()
	var centre
	var direction
	var length
	var bend
	var loop = false
	if kind == "front":
		var distance = rng.randf_range(0.15, 0.8)
		centre = cam.origin + distance * (look + cam.basis.x.normalized() * rng.randf_range(-0.4, 0.4)
			+ cam.basis.y.normalized() * rng.randf_range(-0.3, 0.3))
		direction = look.cross(random_unit()).normalized()
		length = rng.randf_range(1.0, 3.0)
		bend = rng.randf_range(0.1, 0.5)
		loop = rng.randf() < 0.5
	else:
		var away = along.cross(random_unit()).normalized()  # perpendicular to the rope
		var clearance = rope.DIAMETER / 2.0 + diameter / 2.0 + 0.01
		centre = anchor + away * (clearance + rng.randf_range(0.0, 0.35)) * (1 if rng.randf() < 0.5 else -1)
		if kind == "cross":
			direction = along.cross(away).normalized().linear_interpolate(along, rng.randf_range(-0.5, 0.5)).normalized()
			length = rng.randf_range(2.0, 5.0)
			bend = rng.randf_range(0.05, 0.3)
		else:
			direction = (along + random_unit() * 0.15).normalized()
			length = rng.randf_range(1.5, 4.0)
			bend = rng.randf_range(0.02, 0.15)
	var p0 = centre - direction * length / 2.0
	var p3 = centre + direction * length / 2.0
	var p1
	var p2
	if loop:  # control points crossed over: the cable makes a loop near the middle
		p1 = p3 + random_unit() * bend * length * 0.5
		p2 = p0 + random_unit() * bend * length * 0.5
	else:
		p1 = p0 + (p3 - p0) / 3.0 + random_unit() * bend * length * 0.3
		p2 = p0 + (p3 - p0) * 2.0 / 3.0 + random_unit() * bend * length * 0.3
	var out = []
	var steps = 80
	for i in range(steps + 1):
		var t = float(i) / steps
		var u = 1.0 - t
		out.append(u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3)
	return out


# A round tube along the points (frames carried along, so it doesn't twist).
func tube_mesh(points, radius):
	var sides = 10
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var normal = null
	var rings = []
	var normals = []
	for i in range(points.size()):
		var t = (points[min(i + 1, points.size() - 1)] - points[max(i - 1, 0)]).normalized()
		if normal == null:
			normal = t.cross(Vector3.UP if abs(t.y) < 0.9 else Vector3.RIGHT).normalized()
		normal = (normal - t * t.dot(normal)).normalized()
		var binormal = t.cross(normal)
		var ring = []
		var ring_normals = []
		for j in range(sides):
			var a = 2 * PI * j / sides
			var o = normal * cos(a) + binormal * sin(a)
			ring.append(points[i] + o * radius)
			ring_normals.append(o)
		rings.append(ring)
		normals.append(ring_normals)
	for i in range(points.size() - 1):
		for j in range(sides):
			var j2 = (j + 1) % sides
			for v in [[i, j], [i + 1, j], [i, j2], [i, j2], [i + 1, j], [i + 1, j2]]:
				st.add_normal(normals[v[0]][v[1]])
				st.add_vertex(rings[v[0]][v[1]])
	return st.commit()


func clear_cables():
	for c in cables:
		c["node"].queue_free()
	cables = []


func to_camera(p, cam):
	var q = p - cam.origin
	return [q.dot(cam.basis.x.normalized()), q.dot(cam.basis.y.normalized()), q.dot(-cam.basis.z.normalized())]


# Each tether piece as a [start, end] pair of camera-frame points.
func tether_segments(cam):
	var out = []
	for piece in tether_pieces():
		var t = piece.global_transform
		var half = t.basis.z.normalized() * (TETHER_PIECE / 2.0)
		out.append([to_camera(t.origin + half, cam), to_camera(t.origin - half, cam)])
	return out


func save():
	var name = "%06d" % index
	var image = viewport.get_texture().get_data()
	image.flip_y()
	image.convert(Image.FORMAT_RGB8)
	image.save_png(folder + "/images/" + name + ".png")
	var depth = depth_viewport.get_texture().get_data()
	depth.flip_y()
	depth.convert(Image.FORMAT_RGB8)
	depth.save_png(folder + "/rov_depth/" + name + ".png")
	var scene_depth = scene_viewport.get_texture().get_data()
	scene_depth.flip_y()
	scene_depth.convert(Image.FORMAT_RGB8)
	scene_depth.save_png(folder + "/scene_depth/" + name + ".png")
	var cam = camera.global_transform
	var cable_labels = []
	for c in cables:
		var pts = []
		for p in c["points"]:
			pts.append(to_camera(p, cam))
		cable_labels.append({"diameter": c["diameter"], "points": pts})
	var f = (size.x / 2.0) / tan(deg2rad(HFOV / 2.0))
	var line = []
	for p in rope.rope_points():
		line.append(to_camera(p, cam))
	var label = {
		"image": "images/" + name + ".png",
		"width": int(size.x), "height": int(size.y),
		"hfov_deg": HFOV, "fx": f, "fy": f, "cx": size.x / 2.0, "cy": size.y / 2.0,
		"axes": "points are [right, up, ahead] in metres from the camera",
		"rope": {"diameter": rope.DIAMETER, "points": line},
		"tether": {"diameter": TETHER_DIAMETER, "segments": tether_segments(cam)},
		"cables": cable_labels,
		"rov_depth": "rov_depth/" + name + ".png",
		"rov_depth_max_m": DEPTH_MAX,
		"scene_depth": "scene_depth/" + name + ".png",
		"scene_depth_max_m": SCENE_DEPTH_MAX,
		"level": Globals.active_level,
		"post": null,
		"settings": info,
	}
	if post.info() != null:
		label["post"] = {
			"diameter": post.diameter(),
			"top": to_camera(post.info()["top"], cam),
			"bottom": to_camera(post.info()["bottom"], cam),
		}
	var file = File.new()
	file.open(folder + "/labels/" + name + ".json", File.WRITE)
	file.store_string(JSON.print(label))
	file.close()
	if index % 50 == 0:
		print("Capture: %d / %d" % [index, count])

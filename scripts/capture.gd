extends Node

# Training data for rope segmentation (sim-to-real), made automatically.
# Start BlueSim with BLUESIM_CAPTURE set to a folder (it goes straight to the
# pool, no SITL needed):
#   BLUESIM_CAPTURE=~/rope_data ./run_bluesim.sh
#   BLUESIM_CAPTURE_COUNT=1000        number of pictures (default 500)
#   BLUESIM_CAPTURE_SIZE=1920x1080    picture size (default: the BlueROV2 camera's)
#   BLUESIM_CAPTURE_SEED=1            random seed (default 1, for a repeatable set)
# Every picture is taken by a camera like the BlueROV2's (80 deg horizontal
# field of view) at a random distance (0.25-4 m) and angle around the test
# rope, with randomised rope (type, lean, current, colour), post, water
# (colour, visibility) and light. About 1 in 10 has no rope in view.
# The physics is paused for each picture, so the label matches it exactly.
# Writes images/NNNNNN.png and labels/NNNNNN.json (camera model, the rope's
# centre line in camera coordinates, its diameter, the post, the settings);
# Rope_Detection/dataset/make_masks.py turns the labels into masks.

const RopeTypes = preload("res://scripts/rope_types.gd")

const HFOV = 80.0  # deg, BlueROV2 Low-Light HD USB Camera
const PICTURES_PER_SCENE = 20  # new rope/post/current after this many pictures
const SETTLE_TIME = 3.0  # s of physics after building a new rope
const MOVE_TIME = 0.3  # s of physics between pictures (the rope moves a bit)
const NO_ROPE_FRACTION = 0.1
const MIN_DISTANCE = 0.25  # m
const MAX_DISTANCE = 4.0

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
			frames = 3  # let the new view render
			state = "render"
	elif state == "render":
		frames -= 1
		if frames <= 0:
			save()
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
	Globals.rope_material = rng.randi_range(0, RopeTypes.MATERIALS.size() - 1)
	Globals.rope_setup = rng.randi_range(0, RopeTypes.SETUPS.size() - 1)
	Globals.rope_length = RopeTypes.LENGTHS[rng.randi_range(0, RopeTypes.LENGTHS.size() - 1)]
	Globals.current_speed = RopeTypes.CURRENT_SPEEDS[rng.randi_range(0, RopeTypes.CURRENT_SPEEDS.size() - 1)]
	Globals.current_direction = rng.randi_range(0, RopeTypes.CURRENT_DIRECTIONS.size() - 1)
	rope.lean_side = rng.randi_range(0, rope.LEANS_SIDE.size() - 1)
	rope.lean_ahead = rng.randi_range(0, rope.LEANS_AHEAD.size() - 1)
	var color
	if rng.randf() < 0.6:  # mostly reds, like the real rope
		color = Color.from_hsv(fposmod(rng.randf_range(-0.05, 0.04), 1.0), rng.randf_range(0.6, 1.0), rng.randf_range(0.35, 0.9))
	else:
		color = Color.from_hsv(rng.randf(), rng.randf_range(0.3, 1.0), rng.randf_range(0.2, 1.0))
	rope.set_color(color)
	rope.place_at(point, ahead)
	rope.set_color(color)
	Globals.post_type = rng.randi_range(0, RopeTypes.POSTS.size() - 1)
	var right = Vector3(-ahead.z, 0, ahead.x)
	post.place_at(point + right * rng.randf_range(-2.0, 2.0) + ahead * rng.randf_range(-1.5, 1.5))
	info = {
		"rope": RopeTypes.MATERIALS[Globals.rope_material]["key"],
		"setup": RopeTypes.SETUPS[Globals.rope_setup]["key"],
		"length": Globals.rope_length,
		"current": Globals.current_speed,
		"rope_color": [color.r, color.g, color.b],
	}


# Water, light and a camera pose looking at (or, sometimes, away from) the rope.
func new_view():
	var points = rope.rope_points()
	var water = get_tree().get_root().find_node("water", true, false)
	var surface = water.global_transform.origin.y
	# a random point along the rope, under water
	var target = null
	for _i in range(50):
		var k = rng.randi_range(0, points.size() - 2)
		var p = points[k].linear_interpolate(points[k + 1], rng.randf())
		if p.y < surface - 0.5:
			target = p
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
	info["looking_away"] = looking_away
	info["visibility_m"] = environment.fog_depth_end
	info["water_color"] = [tint.r, tint.g, tint.b]
	info["lamp"] = lamp.light_energy


func to_camera(p, cam):
	var q = p - cam.origin
	return [q.dot(cam.basis.x.normalized()), q.dot(cam.basis.y.normalized()), q.dot(-cam.basis.z.normalized())]


func save():
	var name = "%06d" % index
	var image = viewport.get_texture().get_data()
	image.flip_y()
	image.convert(Image.FORMAT_RGB8)
	image.save_png(folder + "/images/" + name + ".png")
	var cam = camera.global_transform
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

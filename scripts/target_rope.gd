extends Spatial

# The test rope for the rope detection / cutting / following code
# (Rope_Detection repo). Its material, setup, length and the water current
# are chosen in the menu (scripts/rope_types.gd, Globals):
#   - a fixed rod (no physics) from the surface to the floor, which K/L lean
#   - a physics rope (rope_segment.gd): a chain of 2 inch pieces with weight,
#     buoyancy, water drag and added mass, pinned at the surface and/or the
#     floor, that bends and moves in the current and can be held by the
#     gripper (BlueROV2Heavy.gd)
# It is placed DISTANCE m in front of the ROV camera when the level starts.
# Keys:
#   P  place it in front of the ROV again (rebuilds it)
#   N  next rope material
#   M  next rope look (colour and construction, rope/rope.shader)
#   V  next current speed
#   K  lean the fixed rod sideways (seen from the ROV): 0, 20, 40, -20, -40 deg
#   L  lean the fixed rod towards / away from the ROV: 0, 20, -20 deg
#
# The label at the bottom of the window shows the true position of the rope
# relative to the ROV camera, and the same (plus the whole rope as a line of
# points, and the post) is sent as JSON over UDP to TRUTH_PORT 10 times a
# second, for the detector's log and the training-data capture.
# The real rope is 2 inch (50.8 mm) diameter and red.

const RopeTypes = preload("res://scripts/rope_types.gd")
const RopeSegment = preload("res://scripts/rope_segment.gd")

const DIAMETER = 0.0508  # m
const RopeShader = preload("res://rope/rope.shader")
const DISTANCE = 3.0  # m in front of the camera when placed
const FLOOR_SEARCH = 200.0  # m along the rope to look for the floor
const DEFAULT_LENGTH = 40.0  # m below the surface, if no floor is found
const LEANS_SIDE = [0.0, 20.0, 40.0, -20.0, -40.0]  # deg, + = top leans right
const LEANS_AHEAD = [0.0, 20.0, -20.0]  # deg, + = top leans away from the ROV
const PIECE_LENGTH = 0.25  # m, length of each physics piece (longer for very long ropes)
const MAX_PIECES = 140
const ROPE_LAYER = 1 << 10  # physics pieces: collide with the world, not with each other
const TRUTH_PORT = 5603
const TRUTH_INTERVAL = 0.1  # s

var rov = null
var camera = null
var label = null
var layer = null
var placed = false
var place_timer = 0.5  # wait for the level to load before placing
var lean_side = 0
var lean_ahead = 0
var anchor = Vector3()  # point DISTANCE m ahead of the camera when placed
var forward = Vector3(1, 0, 0)  # ROV's level forward direction when placed
var direction = Vector3(0, 1, 0)  # fixed rod: unit vector up the rod
var pieces = []  # physics rope pieces, top to bottom
var look = {}  # how it looks: an entry of RopeTypes.LOOKS (colour may be changed)
var materials = []  # one per mesh, so the strands run on from piece to piece
var truth_out = PacketPeerUDP.new()
var truth_timer = 0.0


func _ready():
	add_to_group("target_rope")
	# The label goes on the main window, not in this (ROV camera) viewport,
	# so it doesn't show up in the video sent to the control software.
	layer = CanvasLayer.new()
	label = Label.new()
	label.add_color_override("font_color", Color(1, 1, 1))
	label.add_color_override("font_color_shadow", Color(0, 0, 0))
	layer.add_child(label)
	get_tree().get_root().call_deferred("add_child", layer)
	truth_out.set_dest_address("127.0.0.1", TRUTH_PORT)


func _exit_tree():
	if layer != null:
		layer.queue_free()


func _physics_process(delta):
	if rov == null:
		rov = get_tree().get_root().find_node("BlueRov", true, false)
		if rov == null:
			return
		camera = rov.get_node("Camera")
	if not placed:
		place_timer -= delta
		if place_timer <= 0:
			place_in_front()
		return
	var truth = rope_from_camera()
	update_label(truth)
	truth_timer += delta
	if truth_timer >= TRUTH_INTERVAL:
		truth_timer = 0.0
		truth_out.put_packet(JSON.print(truth).to_utf8())


func _unhandled_input(event):
	if not (event is InputEventKey and event.pressed and not event.echo) or rov == null:
		return
	if event.scancode == KEY_P:
		place_in_front()
	elif event.scancode == KEY_N:
		Globals.rope_material = (Globals.rope_material + 1) % RopeTypes.MATERIALS.size()
		build_rope()
	elif event.scancode == KEY_M:
		Globals.rope_look = (Globals.rope_look + 1) % RopeTypes.LOOKS.size()
		set_look(RopeTypes.LOOKS[Globals.rope_look])
	elif event.scancode == KEY_V:
		var i = RopeTypes.CURRENT_SPEEDS.find(Globals.current_speed)
		Globals.current_speed = RopeTypes.CURRENT_SPEEDS[(i + 1) % RopeTypes.CURRENT_SPEEDS.size()]
		update_current()
	elif event.scancode == KEY_K and is_fixed():
		lean_side = (lean_side + 1) % LEANS_SIDE.size()
		build_rope()
	elif event.scancode == KEY_L and is_fixed():
		lean_ahead = (lean_ahead + 1) % LEANS_AHEAD.size()
		build_rope()


func is_fixed():
	return RopeTypes.MATERIALS[Globals.rope_material]["density"] <= 0.0


func surface_y():
	var water = get_tree().get_root().find_node("water", true, false)
	if water != null:
		return water.global_transform.origin.y
	return rov.global_transform.origin.y + 10.0


# First solid, non-moving thing along a ray (the floor or a wall).
func first_hit(from, to):
	var space_state = get_world().direct_space_state
	var exclude = [rov]
	for _i in range(16):
		var hit = space_state.intersect_ray(from, to, exclude)
		if hit.empty():
			return null
		if hit.collider is RigidBody or hit.collider.is_in_group("target_rope") \
				or hit.collider.is_in_group("test_post"):
			exclude.append(hit.collider)
			continue
		return hit.position
	return null


# Put the rope DISTANCE m straight ahead of the ROV camera (level, ignoring pitch).
func place_in_front():
	var cam = camera.global_transform
	forward = -cam.basis.z  # a camera looks along its -Z
	forward.y = 0
	if forward.length() < 0.01:
		forward = rov.global_transform.basis.z
		forward.y = 0
	place_at(cam.origin + forward * DISTANCE, forward.normalized())


# Put the rope through point (horizontally) with forward as "ahead" for the
# lean and the current direction.
func place_at(point, ahead):
	forward = ahead
	anchor = point
	update_current()
	build_rope()
	placed = true


# The current, relative to the ROV's heading when the rope was placed.
func update_current():
	var angle = deg2rad(RopeTypes.CURRENT_DIRECTIONS[Globals.current_direction]["angle"])
	var from_dir = forward.rotated(Vector3.UP, angle)
	Globals.current_velocity = -from_dir * Globals.current_speed
	print("Current %.2f m/s %s" % [Globals.current_speed,
		RopeTypes.CURRENT_DIRECTIONS[Globals.current_direction]["name"]])


func clear_rope():
	for child in get_children():
		remove_child(child)
		child.queue_free()
	pieces = []
	materials = []


func build_rope():
	clear_rope()
	if is_fixed():
		build_fixed_rod()
	else:
		build_physics_rope()


# A material for a mesh that starts along_offset m along the rope; along_z:
# the mesh runs along its Z axis (capsules) rather than Y (the rod),
# along_sign: which way along that axis is further down the rope.
func rope_material(along_offset, along_z, along_sign):
	if look.empty():
		look = RopeTypes.LOOKS[Globals.rope_look].duplicate()
	var material = ShaderMaterial.new()
	material.shader = RopeShader
	material.set_shader_param("radius", DIAMETER / 2.0)
	material.set_shader_param("lay_length", DIAMETER * 3.3)
	material.set_shader_param("along_offset", along_offset)
	material.set_shader_param("along_z", along_z)
	material.set_shader_param("along_sign", along_sign)
	apply_look(material)
	materials.append(material)
	return material


func apply_look(material):
	material.set_shader_param("base_color", look["color"])
	material.set_shader_param("construction", float(look["construction"]))
	material.set_shader_param("tracer", 0.0 if look["tracer"] == null else 1.0)
	if look["tracer"] != null:
		material.set_shader_param("tracer_color", look["tracer"])
	material.set_shader_param("fuzz", look["fuzz"])


# Change how the rope looks (a RopeTypes.LOOKS-style dictionary) in place.
func set_look(new_look):
	look = new_look.duplicate()
	for material in materials:
		apply_look(material)


func set_color(c):
	if look.empty():
		look = RopeTypes.LOOKS[Globals.rope_look].duplicate()
	look["color"] = c
	for material in materials:
		apply_look(material)


func build_fixed_rod():
	# lean the vertical: sideways about the forward axis, then towards/away
	# about the sideways axis (both as seen from the ROV when it was placed)
	var right = Vector3(-forward.z, 0, forward.x)
	direction = Vector3(0, 1, 0)
	direction = direction.rotated(forward, deg2rad(LEANS_SIDE[lean_side]))
	direction = direction.rotated(right, -deg2rad(LEANS_AHEAD[lean_ahead]))
	direction = direction.normalized()

	# top at the water surface, bottom where the line meets the floor
	var top = anchor + direction * ((surface_y() - anchor.y) / direction.y)
	var bottom = first_hit(top, top - direction * FLOOR_SEARCH)
	if bottom == null:
		bottom = top - direction * (DEFAULT_LENGTH / direction.y)
	var length = top.distance_to(bottom)

	var body = StaticBody.new()
	body.add_to_group("target_rope")
	add_child(body)
	# the cylinder runs along its local Y axis
	var x_axis = direction.cross(forward).normalized()
	var z_axis = x_axis.cross(direction).normalized()
	body.global_transform = Transform(Basis(x_axis, direction, z_axis), (top + bottom) / 2.0)

	var mesh = CylinderMesh.new()
	mesh.top_radius = DIAMETER / 2.0
	mesh.bottom_radius = DIAMETER / 2.0
	mesh.height = length
	mesh.radial_segments = 16
	mesh.rings = int(clamp(length / 0.03, 1, 2000))  # for the lumpy outline
	mesh.material = rope_material(length / 2.0, false, -1.0)
	var mesh_instance = MeshInstance.new()
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)

	var shape = CylinderShape.new()
	shape.radius = DIAMETER / 2.0
	shape.height = length
	var collision = CollisionShape.new()
	collision.shape = shape
	body.add_child(collision)
	print("Rope: fixed rod %.1f m in front of the ROV camera, %.1f m long, leaning %d deg sideways, %d deg away" % [
		DISTANCE, length, LEANS_SIDE[lean_side], LEANS_AHEAD[lean_ahead]])


func build_physics_rope():
	var material_info = RopeTypes.MATERIALS[Globals.rope_material]
	var setup = RopeTypes.SETUPS[Globals.rope_setup]["key"]
	var surface = surface_y()
	var floor_hit = first_hit(Vector3(anchor.x, surface, anchor.z), Vector3(anchor.x, surface - FLOOR_SEARCH, anchor.z))
	var floor_y = surface - DEFAULT_LENGTH if floor_hit == null else floor_hit.y
	var depth = surface - floor_y

	# laid out straight up and down to start with; the physics takes it from there
	var top_y
	var length
	if setup == "surface_floor":
		top_y = surface
		length = depth
	elif setup == "hanging":
		top_y = surface
		length = min(Globals.rope_length, depth)
	else:  # standing
		length = min(Globals.rope_length, depth)
		top_y = floor_y + length
	var count = int(clamp(ceil(length / PIECE_LENGTH), 2, MAX_PIECES))
	var piece = length / count

	var mesh = CapsuleMesh.new()  # along its local Z in Godot 3
	mesh.radius = DIAMETER / 2.0
	mesh.mid_height = piece  # the round ends overlap the next piece, filling the bends
	mesh.radial_segments = 16
	mesh.rings = 8
	var shape = CapsuleShape.new()
	shape.radius = DIAMETER / 2.0
	shape.height = piece

	var previous = null
	for i in range(count):
		var body = RigidBody.new()
		body.set_script(RopeSegment)
		body.collision_layer = ROPE_LAYER
		body.collision_mask = 1
		var mesh_instance = MeshInstance.new()
		mesh_instance.mesh = mesh
		mesh_instance.rotation_degrees = Vector3(90, 0, 0)  # capsule Z -> piece Y (+Z points down the rope)
		mesh_instance.material_override = rope_material((i + 0.5) * piece, true, 1.0)
		body.add_child(mesh_instance)
		var collision = CollisionShape.new()
		collision.shape = shape
		collision.rotation_degrees = Vector3(90, 0, 0)
		body.add_child(collision)
		add_child(body)
		body.setup(DIAMETER, piece, material_info["density"])
		body.global_transform = Transform(Basis(), Vector3(anchor.x, top_y - (i + 0.5) * piece, anchor.z))
		pieces.append(body)
		var joint_y = top_y - i * piece
		if previous != null:
			pin(previous, body, joint_y)
		previous = body

	# pinned ends: to the surface (a buoy) and/or the floor (an anchor)
	if setup == "surface_floor" or setup == "hanging":
		pin(make_anchor(Vector3(anchor.x, top_y, anchor.z)), pieces[0], top_y)
	if setup == "surface_floor" or setup == "standing":
		pin(make_anchor(Vector3(anchor.x, floor_y, anchor.z)), pieces[-1], top_y - length)
	print("Rope: %s, %s, %.1f m (%d pieces) %.1f m in front of the ROV camera" % [
		material_info["name"], RopeTypes.SETUPS[Globals.rope_setup]["name"], length, count, DISTANCE])


func make_anchor(position):
	var body = StaticBody.new()
	add_child(body)
	body.global_transform = Transform(Basis(), position)
	return body


func pin(a, b, y):
	var joint = PinJoint.new()
	add_child(joint)
	joint.global_transform = Transform(Basis(), Vector3(anchor.x, y, anchor.z))
	joint.set_node_a(a.get_path())
	joint.set_node_b(b.get_path())


# The rope's centre line as a list of world points, top to bottom.
func rope_points():
	if pieces.empty():
		for child in get_children():
			if child is StaticBody and child.is_in_group("target_rope"):
				var t = child.global_transform
				var length = 0.0
				for c in child.get_children():
					if c is CollisionShape:
						length = c.shape.height
				var half = t.basis.y.normalized() * length / 2.0
				return [t.origin + half, t.origin - half]
		return []
	var points = []
	for i in range(pieces.size()):
		var t = pieces[i].global_transform
		var half = t.basis.y.normalized() * pieces[i].length / 2.0
		if i == 0:
			points.append(t.origin + half)
		points.append(t.origin - half)
	return points


# The rope relative to the ROV camera: the closest point of its centre line
# (ahead along the view, right, up, in metres) and its direction there (unit
# vector up the rope, as [right, up, ahead]), its lean, the whole centre line
# as [right, up, ahead] points, the post if there is one, and the camera's
# depth below the surface.
func rope_from_camera():
	var cam = camera.global_transform
	var cam_right = cam.basis.x.normalized()
	var cam_up = cam.basis.y.normalized()
	var cam_ahead = -cam.basis.z.normalized()
	var points = rope_points()
	var best = null
	var best_dir = Vector3(0, 1, 0)
	for i in range(points.size() - 1):
		var a = points[i]
		var b = points[i + 1]
		var ab = b - a
		var t = clamp((cam.origin - a).dot(ab) / max(ab.length_squared(), 1e-9), 0.0, 1.0)
		var p = a + ab * t
		if best == null or p.distance_to(cam.origin) < best.distance_to(cam.origin):
			best = p
			best_dir = (a - b).normalized()  # up the rope (points go top to bottom)
	if best == null:
		best = anchor
	var rel = best - cam.origin
	var dir = [best_dir.dot(cam_right), best_dir.dot(cam_up), best_dir.dot(cam_ahead)]
	var line = []
	for p in points:
		var q = p - cam.origin
		line.append([q.dot(cam_right), q.dot(cam_up), q.dot(cam_ahead)])
	var truth = {
		"t": OS.get_ticks_msec() / 1000.0,
		"ahead": rel.dot(cam_ahead),
		"right": rel.dot(cam_right),
		"up": rel.dot(cam_up),
		"dir": dir,
		"lean_side": rad2deg(atan2(dir[0], dir[1])),
		"lean_ahead": rad2deg(atan2(dir[2], dir[1])),
		"depth": surface_y() - cam.origin.y,
		"rope": RopeTypes.MATERIALS[Globals.rope_material]["key"],
		"look": look.get("key", ""),
		"setup": RopeTypes.SETUPS[Globals.rope_setup]["key"],
		"current": Globals.current_speed,
		"diameter": DIAMETER,
		"points": line,
	}
	var post = get_tree().get_root().find_node("TestPost", true, false)
	if post != null and post.has_method("info") and post.info() != null:
		var info = post.info()
		var top = info["top"] - cam.origin
		var bottom = info["bottom"] - cam.origin
		truth["post"] = {
			"diameter": info["diameter"],
			"top": [top.dot(cam_right), top.dot(cam_up), top.dot(cam_ahead)],
			"bottom": [bottom.dot(cam_right), bottom.dot(cam_up), bottom.dot(cam_ahead)],
		}
	return truth


func update_label(truth):
	label.rect_position = Vector2(10, get_tree().get_root().size.y - 30)
	var kind = RopeTypes.MATERIALS[Globals.rope_material]["name"] + ", " + look.get("name", "")
	label.text = "Rope: %.2f m ahead, %.2f m %s, lean %d/%d deg  [%s, current %.2f m/s]   P: move  N: rope  M: look  V: current  K/L: lean" % [
		truth["ahead"], abs(truth["right"]), "right" if truth["right"] >= 0 else "left",
		truth["lean_side"], truth["lean_ahead"], kind, Globals.current_speed]

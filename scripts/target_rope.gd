extends Spatial

# A fixed rope from the water surface to the floor, for testing the rope
# detection / cutting / following code (Rope_Detection repo).
# It is placed DISTANCE metres in front of the ROV camera when the level
# starts. Keys:
#   P  move it in front of the ROV again
#   K  lean it sideways (seen from the ROV):   0, 20, 40, -20, -40 deg
#   L  lean it towards / away from the ROV:     0, 20, -20 deg
# The rope always passes through the point DISTANCE m ahead of the camera,
# so a leaning rope still crosses the middle of the picture.
#
# The label at the bottom of the window shows the true position of the rope
# relative to the ROV camera, and the same is sent as JSON over UDP to
# TRUTH_PORT (10 per second) so the detector can log its estimates against
# the truth. The real rope is 2 inch (50.8 mm) diameter and red.

const DIAMETER = 0.0508  # m
const COLOR = Color(0.8, 0.05, 0.04)
const DISTANCE = 3.0  # m in front of the camera when placed
const FLOOR_SEARCH = 200.0  # m along the rope to look for the floor
const DEFAULT_LENGTH = 40.0  # m below the surface, if no floor is found
const LEANS_SIDE = [0.0, 20.0, 40.0, -20.0, -40.0]  # deg, + = top leans right
const LEANS_AHEAD = [0.0, 20.0, -20.0]  # deg, + = top leans away from the ROV
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
var anchor = Vector3()  # point on the rope DISTANCE m ahead of the camera
var forward = Vector3(1, 0, 0)  # ROV's level forward direction when placed
var direction = Vector3(0, 1, 0)  # unit vector up the rope
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
	elif event.scancode == KEY_K:
		lean_side = (lean_side + 1) % LEANS_SIDE.size()
		build_rope()
	elif event.scancode == KEY_L:
		lean_ahead = (lean_ahead + 1) % LEANS_AHEAD.size()
		build_rope()


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
		if hit.collider is RigidBody or hit.collider.is_in_group("target_rope"):
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
	forward = forward.normalized()
	anchor = cam.origin + forward * DISTANCE
	build_rope()
	placed = true


func build_rope():
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

	for child in get_children():
		remove_child(child)
		child.queue_free()

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
	mesh.rings = 1
	var material = SpatialMaterial.new()
	material.albedo_color = COLOR
	material.roughness = 0.9
	mesh.material = material
	var mesh_instance = MeshInstance.new()
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)

	var shape = CylinderShape.new()
	shape.radius = DIAMETER / 2.0
	shape.height = length
	var collision = CollisionShape.new()
	collision.shape = shape
	body.add_child(collision)
	print("Rope placed %.1f m in front of the ROV camera, %.1f m long, leaning %d deg sideways, %d deg away" % [
		DISTANCE, length, LEANS_SIDE[lean_side], LEANS_AHEAD[lean_ahead]])


# The rope relative to the ROV camera: the closest point of its centre line
# (ahead along the view, right, up, in metres) and its direction (unit
# vector up the rope, same axes), plus the camera depth below the surface.
func rope_from_camera():
	var cam = camera.global_transform
	var closest = anchor + direction * (cam.origin - anchor).dot(direction)
	var rel = closest - cam.origin
	var cam_right = cam.basis.x.normalized()
	var cam_up = cam.basis.y.normalized()
	var cam_ahead = -cam.basis.z.normalized()
	return {
		"t": OS.get_ticks_msec() / 1000.0,
		"ahead": rel.dot(cam_ahead),
		"right": rel.dot(cam_right),
		"up": rel.dot(cam_up),
		"dir": [direction.dot(cam_right), direction.dot(cam_up), direction.dot(cam_ahead)],
		"lean_side": LEANS_SIDE[lean_side],
		"lean_ahead": LEANS_AHEAD[lean_ahead],
		"depth": surface_y() - cam.origin.y,
	}


func update_label(truth):
	label.rect_position = Vector2(10, get_tree().get_root().size.y - 30)
	label.text = "Rope: %.2f m ahead, %.2f m %s, lean %d/%d deg   P: move  K/L: lean" % [
		truth["ahead"], abs(truth["right"]), "right" if truth["right"] >= 0 else "left",
		truth["lean_side"], truth["lean_ahead"]]

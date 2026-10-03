extends Spatial

# A fixed rope hanging straight down from the water surface to the floor,
# for testing the rope detection / cutting code (Rope_Detection repo).
# It is placed DISTANCE metres in front of the ROV camera when the level
# starts; P moves it in front of the ROV again. The label at the bottom of
# the window shows the true distance from the ROV camera to the rope (centre line),
# to check the detector's distance estimate against.
#
# The real rope is 2 inch (50.8 mm) diameter and red.

const DIAMETER = 0.0508  # m
const COLOR = Color(0.8, 0.05, 0.04)
const DISTANCE = 3.0  # m in front of the camera when placed
const FLOOR_SEARCH = 200.0  # m below the surface to look for the floor
const DEFAULT_LENGTH = 40.0  # m, if no floor is found

var rov = null
var camera = null
var label = null
var placed = false
var place_timer = 0.5  # wait for the level to load before placing
var layer = null


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
	update_label()


func _unhandled_input(event):
	if event is InputEventKey and event.pressed and not event.echo and event.scancode == KEY_P:
		if rov != null:
			place_in_front()


func surface_y():
	var water = get_tree().get_root().find_node("water", true, false)
	if water != null:
		return water.global_transform.origin.y
	return rov.global_transform.origin.y + 10.0


func floor_y(x, z, top):
	var space_state = get_world().direct_space_state
	var exclude = [rov]
	var from = Vector3(x, top, z)
	var to = Vector3(x, top - FLOOR_SEARCH, z)
	for _i in range(16):
		var hit = space_state.intersect_ray(from, to, exclude)
		if hit.empty():
			break
		if hit.collider is RigidBody or hit.collider.is_in_group("target_rope"):
			exclude.append(hit.collider)
			continue
		return hit.position.y
	return top - DEFAULT_LENGTH


# Put the rope DISTANCE m straight ahead of the ROV camera (level, ignoring pitch).
func place_in_front():
	var cam = camera.global_transform
	var forward = -cam.basis.z  # a camera looks along its -Z
	forward.y = 0
	if forward.length() < 0.01:
		forward = rov.global_transform.basis.z
		forward.y = 0
	forward = forward.normalized()
	var pos = cam.origin + forward * DISTANCE
	var top = surface_y()
	var bottom = floor_y(pos.x, pos.z, top)
	build(Vector3(pos.x, (top + bottom) / 2.0, pos.z), top - bottom)
	placed = true
	print("Rope placed %.1f m in front of the ROV camera, %.1f m long" % [DISTANCE, top - bottom])


func build(center, length):
	for child in get_children():
		remove_child(child)
		child.queue_free()

	var body = StaticBody.new()
	body.add_to_group("target_rope")
	add_child(body)
	body.global_transform = Transform(Basis(), center)

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


func rope_position():
	for child in get_children():
		if child is StaticBody:
			return child.global_transform.origin
	return null


func update_label():
	var rope = rope_position()
	if rope == null or camera == null:
		return
	# rope centre line from the camera, horizontally: ahead and to the right
	var cam = camera.global_transform
	var rel = rope - cam.origin
	rel.y = 0
	var forward = -cam.basis.z
	forward.y = 0
	forward = forward.normalized()
	var ahead = rel.dot(forward)
	var right = rel.dot(Vector3(-forward.z, 0, forward.x))
	label.rect_position = Vector2(10, get_tree().get_root().size.y - 30)
	label.text = "Rope: %.2f m ahead of the camera, %.2f m %s  (P: move it in front)" % [
		ahead, abs(right), "right" if right >= 0 else "left"]

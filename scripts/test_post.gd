extends Spatial

# A fixed post (pile or pole, chosen in the menu or with BLUESIM_POST) from
# the floor to just above the water surface, for rope manipulation tests
# such as wrapping a rope around it. It is placed DISTANCE m ahead of the
# ROV camera and SIDE m to the right of that, beside where the test rope
# goes; J places it there again. Grey, so it isn't mistaken for the rope.

const RopeTypes = preload("res://scripts/rope_types.gd")

const DISTANCE = 3.0  # m ahead of the camera
const SIDE = 1.5  # m to the right
const ABOVE_SURFACE = 0.3  # m
const COLOR = Color(0.55, 0.55, 0.5)

var rov = null
var camera = null
var body = null
var top = Vector3()
var bottom = Vector3()
var place_timer = 0.6  # wait for the level to load before placing


func _physics_process(delta):
	if rov == null:
		rov = get_tree().get_root().find_node("BlueRov", true, false)
		if rov == null:
			return
		camera = rov.get_node("Camera")
	if place_timer > 0:
		place_timer -= delta
		if place_timer <= 0:
			place_in_front()


func _unhandled_input(event):
	if event is InputEventKey and event.pressed and not event.echo and event.scancode == KEY_J and rov != null:
		if Globals.post_type == 0:
			Globals.post_type = RopeTypes.find(RopeTypes.POSTS, "pile")
		place_in_front()


func diameter():
	return RopeTypes.POSTS[Globals.post_type]["diameter"]


func place_in_front():
	var cam = camera.global_transform
	var forward = -cam.basis.z
	forward.y = 0
	forward = forward.normalized()
	var right = Vector3(-forward.z, 0, forward.x)
	place_at(cam.origin + forward * DISTANCE + right * SIDE)


# Put the post (of Globals.post_type) at spot (horizontally), or remove it.
func place_at(spot):
	if body != null:
		remove_child(body)
		body.queue_free()
		body = null
	if diameter() <= 0.0:
		return
	var water = get_tree().get_root().find_node("water", true, false)
	var surface = water.global_transform.origin.y if water != null else spot.y + 10.0
	var floor_y = surface - 40.0
	var space_state = get_world().direct_space_state
	var exclude = [rov]
	for _i in range(16):
		var hit = space_state.intersect_ray(Vector3(spot.x, surface, spot.z), Vector3(spot.x, surface - 200.0, spot.z), exclude)
		if hit.empty():
			break
		if hit.collider is RigidBody or hit.collider.is_in_group("target_rope"):
			exclude.append(hit.collider)
			continue
		floor_y = hit.position.y
		break
	top = Vector3(spot.x, surface + ABOVE_SURFACE, spot.z)
	bottom = Vector3(spot.x, floor_y, spot.z)
	var height = top.y - bottom.y

	body = StaticBody.new()
	body.add_to_group("test_post")
	add_child(body)
	body.global_transform = Transform(Basis(), (top + bottom) / 2.0)
	var mesh = CylinderMesh.new()
	mesh.top_radius = diameter() / 2.0
	mesh.bottom_radius = diameter() / 2.0
	mesh.height = height
	mesh.radial_segments = 24
	var material = SpatialMaterial.new()
	material.albedo_color = COLOR
	material.roughness = 1.0
	mesh.material = material
	var mesh_instance = MeshInstance.new()
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)
	var shape = CylinderShape.new()
	shape.radius = diameter() / 2.0
	shape.height = height
	var collision = CollisionShape.new()
	collision.shape = shape
	body.add_child(collision)
	print("Post: %s, %.1f m ahead and %.1f m right of the ROV camera" % [
		RopeTypes.POSTS[Globals.post_type]["name"], DISTANCE, SIDE])


# Where the post is (for the ground truth), or null without one.
func info():
	if body == null:
		return null
	return {"top": top, "bottom": bottom, "diameter": diameter()}

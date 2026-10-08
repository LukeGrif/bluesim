tool
extends RigidBody

const THRUST = 50
const RANGEFINDER_MAX = 50.0  # m, downward rangefinder / DVL altitude range
# ROV camera stream for the control software (external SITL mode only):
# raw RGB frames in UDP chunks, see send_video_frame(). The stream has its
# own camera, set up like the BlueROV2's Low-Light HD USB Camera: 1920x1080
# with an 80 deg horizontal field of view (BLUESIM_VIDEO_SIZE=1280x720 etc.
# for a smaller picture with the same view).
const VIDEO_PORT = 5602
const VIDEO_SIZE = Vector2(1920, 1080)
const CAMERA_HFOV = 80.0  # deg
const VIDEO_INTERVAL = 0.1  # s (10 frames/s)
const VIDEO_CHUNK = 60000  # payload bytes per UDP packet
const VIDEO_CHUNKS_PER_TICK = 40  # packets sent per rendered frame (paces a big frame)

var interface = PacketPeerUDP.new()  # UDP socket for fdm in (server)
var peer = null
var start_time = OS.get_ticks_msec()

var last_velocity = Vector3(0, 0, 0)
var calculated_acceleration = Vector3(0, 0, 0)

var buoyancy = 1.6 + self.mass * 9.8  # Newtons
var _initial_position = 0
var phys_time = 0
var rangefinder_exclude = []
var surface_y = null  # height of the water surface in the scene
var video_out = PacketPeerUDP.new()
var video_timer = 0.0
var video_frame_id = 0
var video_queue = []  # packets of the current frame still to send
# Holding the test rope: when the gripper has been closing for GRASP_AFTER
# seconds with a rope piece between the jaws, that piece is pinned to the ROV
# (simulated jaws can't reliably squeeze a rope), until the gripper opens.
const GRASP_AFTER = 0.5  # s of closing
const ROPE_LAYER = 1 << 10  # target_rope.gd's physics pieces
var gripper_command = 0  # 1 opening, -1 closing, 0 stopped
var gripper_closed = false
var last_gripper_servo = 0  # last SERVO10 command seen: 1 open, -1 close, 0 stop
var last_tilt_servo = 0.5  # last SERVO11 (camera tilt) seen, 0-1
var closing_time = 0.0
var grasp_area = null
var grasp_joint = null
var grasped_piece = null
var stream_viewport = null
var stream_camera = null

onready var light_glows = [$light_glow, $light_glow2, $light_glow3, $light_glow4]

onready var ljoint = get_tree().get_root().find_node("ljoint", true, false)
onready var rjoint = get_tree().get_root().find_node("rjoint", true, false)
onready var wait_SITL = Globals.wait_SITL


func connect_fmd_in():
	if interface.listen(9002) != OK:
		print("Failed to connect fdm_in")


func get_servos():
	if not peer:
		interface.set_dest_address("127.0.0.1", interface.get_packet_port())

	if not interface.get_available_packet_count():
		if wait_SITL:
			interface.wait()
		else:
			return

	var buffer = StreamPeerBuffer.new()
	buffer.data_array = interface.get_packet()

	var magic = buffer.get_u16()
	buffer.seek(2)
	var _framerate = buffer.get_u16()
	#print(_framerate)
	buffer.seek(4)
	var _framecount = buffer.get_u16()

	if magic != 18458:
		return
	for i in range(0, 15):
		buffer.seek(8 + i * 2)
		actuate_servo(i, (float(buffer.get_u16()) - 1000) / 1000)


func send_fdm():
	var buffer = StreamPeerBuffer.new()

	buffer.put_double((OS.get_ticks_msec() - start_time) / 1000.0)

	var _basis = transform.basis

# These are the same but mean different things, let's keep both for now
	var toNED = Basis(Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(1, 0, 0))

	toNED = Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))

	var toFRD = Basis(Vector3(0, -1, 0), Vector3(0, 0, -1), Vector3(1, 0, 0))

	var _angular_velocity = toFRD.xform(_basis.xform_inv(angular_velocity))
	var gyro = [_angular_velocity.x, _angular_velocity.y, _angular_velocity.z]

	var _acceleration = toFRD.xform(_basis.xform_inv(calculated_acceleration))

	var accel = [_acceleration.x, _acceleration.y, _acceleration.z]

	# var orientation = toFRD.xform(Vector3(-rotation.x, - rotation.y, -rotation.z))
	var quaternon = Basis(-_basis.z, _basis.x, _basis.y).rotated(Vector3(1, 0, 0), PI).rotated(Vector3(1, 0, 0), PI / 2).get_rotation_quat()

	var euler = quaternon.get_euler()
	euler = [euler.y, euler.x, euler.z]

	var _velocity = toNED.xform(self.linear_velocity)
	var velo = [_velocity.x, _velocity.y, _velocity.z]

	# SITL treats altitude 0 as the water surface (it derives the depth sensor
	# pressure from it), so report the down position relative to the surface.
	var _position = toNED.xform(self.transform.origin)
	var pos = [_position.x, _position.y, _position.z + get_surface_y()]

	var IMU_fmt = {"gyro": gyro, "accel_body": accel}
	var JSON_fmt = {
		"timestamp": phys_time,
		"imu": IMU_fmt,
		"position": pos,
		"quaternion": [quaternon.w, quaternon.x, quaternon.y, quaternon.z],
		"velocity": velo,
		"rng_1": measure_range()
	}
	var JSON_string = "\n" + JSON.print(JSON_fmt) + "\n"
	buffer.put_utf8_string(JSON_string)
	interface.put_packet(buffer.data_array)


# The camera for the stream: an off-screen viewport the size of the real
# camera's picture, with the real camera's field of view, following $Camera
# (including its tilt). The window keeps showing $Camera as before.
func setup_stream_camera():
	var size = VIDEO_SIZE
	var env_size = OS.get_environment("BLUESIM_VIDEO_SIZE")
	if env_size != "":
		var parts = env_size.to_lower().split("x")
		if parts.size() == 2 and int(parts[0]) > 0 and int(parts[1]) > 0:
			size = Vector2(int(parts[0]), int(parts[1]))
	var main_viewport = $Camera.get_viewport()
	stream_viewport = Viewport.new()
	stream_viewport.size = size
	stream_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	stream_viewport.hdr = main_viewport.hdr
	stream_viewport.msaa = main_viewport.msaa
	stream_viewport.shadow_atlas_size = main_viewport.shadow_atlas_size
	stream_viewport.shadow_atlas_quad_1 = main_viewport.shadow_atlas_quad_1
	stream_camera = Camera.new()
	stream_camera.keep_aspect = Camera.KEEP_WIDTH  # fov is horizontal
	stream_camera.fov = CAMERA_HFOV
	stream_camera.near = $Camera.near
	stream_camera.far = $Camera.far
	stream_camera.cull_mask = $Camera.cull_mask
	stream_camera.environment = $Camera.environment
	stream_viewport.add_child(stream_camera)
	add_child(stream_viewport)  # shares the scene's 3D world
	stream_camera.current = true
	print("Camera stream: %dx%d, %.0f deg horizontal field of view, UDP %d" % [size.x, size.y, CAMERA_HFOV, VIDEO_PORT])


# Send the ROV camera image to the control software. Each frame is split
# into UDP packets with a 16-byte little-endian header:
#   "BSV1", frame id (u32), chunk index (u16), chunk count (u16),
#   width (u16), height (u16)
# followed by that chunk of the RGB8 pixel rows (top row first).
# The packets go out VIDEO_CHUNKS_PER_TICK per rendered frame rather than
# all at once, so a 1080p frame (6 MB) doesn't overflow the receiver's
# socket buffer; a new frame replaces any packets of the last one not sent.
func send_video_frame():
	var img = stream_viewport.get_texture().get_data()
	if img == null or img.is_empty():
		return
	img.flip_y()
	img.convert(Image.FORMAT_RGB8)
	var width = img.get_width()
	var height = img.get_height()
	var data = img.get_data()
	var count = int(ceil(float(data.size()) / VIDEO_CHUNK))
	video_frame_id = (video_frame_id + 1) % 4294967296
	video_queue = []
	for i in range(count):
		var packet = StreamPeerBuffer.new()
		packet.put_data("BSV1".to_ascii())
		packet.put_u32(video_frame_id)
		packet.put_u16(i)
		packet.put_u16(count)
		packet.put_u16(width)
		packet.put_u16(height)
		packet.put_data(data.subarray(i * VIDEO_CHUNK, min((i + 1) * VIDEO_CHUNK, data.size()) - 1))
		video_queue.append(packet.data_array)


func _process(delta):
	if Engine.is_editor_hint() or Globals.isHTML5 or not Globals.external_sitl or Globals.capturing:
		return
	if Globals.active_vehicle != self:
		return
	if stream_camera == null:
		setup_stream_camera()
	stream_camera.global_transform = $Camera.global_transform
	for _i in range(min(VIDEO_CHUNKS_PER_TICK, video_queue.size())):
		video_out.put_packet(video_queue.pop_front())
	video_timer += delta
	if video_timer >= VIDEO_INTERVAL:
		video_timer = 0.0
		send_video_frame()


func get_surface_y():
	if surface_y == null:
		var water = get_tree().get_root().find_node("water", true, false)
		if water == null:
			return 0.0
		surface_y = water.global_transform.origin.y
	return surface_y


# Distance to the seafloor along the vehicle's down axis, like a downward
# rangefinder or DVL. Read by SITL as rangefinder 1 (RNGFND1_TYPE = 100).
func measure_range():
	var origin = global_transform.origin
	var target = origin - global_transform.basis.y.normalized() * RANGEFINDER_MAX
	var space_state = get_world().direct_space_state
	for _i in range(8):
		var hit = space_state.intersect_ray(origin, target, rangefinder_exclude)
		if hit.empty():
			break
		if hit.collider is RigidBody or hit.collider.is_in_group("target_rope"):
			# the tether, gripper, loose objects and the test rope are not the seafloor
			rangefinder_exclude.append(hit.collider)
			continue
		return origin.distance_to(hit.position)
	return RANGEFINDER_MAX + 1.0  # out of range


func get_motors_table_entry(thruster):
	
	var thruster_vector = (thruster.transform.basis*Vector3(1,0,0)).normalized()
	var roll = Vector3(0,0,-1).cross(thruster.translation).normalized().dot(thruster_vector)
	var pitch = Vector3(1,0,0).cross(thruster.translation).normalized().dot(thruster_vector)
	var yaw = Vector3(0,1,0).cross(thruster.translation).normalized().dot(thruster_vector)
	var forward = Vector3(0,0,-1).dot(thruster_vector)
	var lateral = Vector3(1,0,0).dot(thruster_vector)
	var vertical = Vector3(0,-1,0).dot(thruster_vector)
	if abs(roll) < 0.15 or not thruster.roll_factor:
		roll = 0
	if abs(pitch) < 0.15 or not thruster.pitch_factor:
		pitch = 0
	if abs(yaw) < 0.15 or not thruster.yaw_factor:
		yaw = 0
	if abs(vertical) < 0.15 or not thruster.vertical_factor :
		vertical = 0
	if abs(forward) < 0.15 or not thruster.forward_factor:
		forward = 0
	if abs(lateral) < 0.15 or not thruster.lateral_factor:
		lateral = 0
	return [roll, pitch, yaw, vertical, forward, lateral]

func calculate_motors_matrix():
	print("Calculated Motors Matrix:")
	var thrusters = []
	var i = 1
	for child in get_children():
		if child.get_class() ==  "Thruster":
			thrusters.append(child)
	for thruster in thrusters:
		var entry = get_motors_table_entry(thruster)
		entry.insert(0, i)
		i = i + 1
		print("add_motor_raw_6dof(AP_MOTORS_MOT_%s,\t%s,\t%s,\t%s,\t%s,\t%s,\t%s);" % entry)

func _ready():
	if Engine.is_editor_hint():
		calculate_motors_matrix()
		return
	if Globals.active_vehicle == "bluerovheavy":
		$Camera.set_current(true)
	# BLUESIM_CAMERA_TILT=35: camera tilted 35 deg down (the gripper in view)
	if OS.get_environment("BLUESIM_CAMERA_TILT") != "":
		$Camera.rotation_degrees.x = -clamp(float(OS.get_environment("BLUESIM_CAMERA_TILT")), -45.0, 45.0)
	_initial_position = get_global_transform().origin
	set_physics_process(true)
	if typeof(Globals.active_vehicle) == TYPE_STRING and Globals.active_vehicle == "bluerovheavy":
		Globals.active_vehicle = self
	else:
		return
	rangefinder_exclude.append(self)
	setup_grasp_area()
	video_out.set_dest_address("127.0.0.1", VIDEO_PORT)
	if not Globals.isHTML5:
		connect_fmd_in()


func _physics_process(delta):
	if Engine.is_editor_hint():
		return
	phys_time = phys_time + 1.0 / Globals.physics_rate
	process_keys()
	if Globals.isHTML5:
		return
	calculated_acceleration = (self.linear_velocity - last_velocity) / delta
	# the accelerometer feels gravity; use the value the physics engine applies
	calculated_acceleration.y += ProjectSettings.get_setting("physics/3d/default_gravity")
	last_velocity = self.linear_velocity
	get_servos()
	apply_current()
	update_grasp(delta)
	send_fdm()


# The water current pushes the ROV like its drag (linear_damp) would: with
# the thrusters off it drifts at the current's speed.
func apply_current():
	if Globals.current_velocity.length() > 0.0:
		add_central_force(Globals.current_velocity * mass * linear_damp)


# The space between the open jaws, in the ROV's frame (forward is +Z):
# 0.02-0.21 m ahead of the camera and ~0.26 m below it.
func setup_grasp_area():
	grasp_area = Area.new()
	grasp_area.collision_layer = 0
	grasp_area.collision_mask = ROPE_LAYER
	grasp_area.monitorable = false
	var shape = BoxShape.new()
	shape.extents = Vector3(0.07, 0.06, 0.1)
	var collision = CollisionShape.new()
	collision.shape = shape
	grasp_area.add_child(collision)
	add_child(grasp_area)
	grasp_area.transform = Transform(Basis(), $Camera.transform.origin + Vector3(0, -0.26, 0.12))


func update_grasp(delta):
	if gripper_command == -1:
		closing_time += delta
		if closing_time >= GRASP_AFTER:
			gripper_closed = true
	else:
		closing_time = 0.0
	if gripper_command == 1:
		gripper_closed = false

	if gripper_closed and grasp_joint == null:
		var centre = grasp_area.global_transform.origin
		var best = null
		for body in grasp_area.get_overlapping_bodies():
			if body.is_in_group("rope_segment") and (best == null or
					body.global_transform.origin.distance_to(centre) < best.global_transform.origin.distance_to(centre)):
				best = body
		if best != null:
			# pin it where the rope's centre line passes the middle of the jaws
			var axis = best.global_transform.basis.y.normalized()
			var point = best.global_transform.origin + axis * axis.dot(centre - best.global_transform.origin)
			grasp_joint = PinJoint.new()
			add_child(grasp_joint)
			grasp_joint.global_transform = Transform(Basis(), point)
			grasp_joint.set_node_a(get_path())
			grasp_joint.set_node_b(best.get_path())
			grasped_piece = best
			print("Gripper: holding the rope")
	elif not gripper_closed and grasp_joint != null:
		remove_child(grasp_joint)
		grasp_joint.queue_free()
		grasp_joint = null
		grasped_piece = null
		print("Gripper: let go of the rope")
	elif grasp_joint != null and not is_instance_valid(grasped_piece):
		# the rope was rebuilt
		grasp_joint.queue_free()
		grasp_joint = null
		grasped_piece = null


func add_force_local(force: Vector3, pos: Vector3):
	var pos_local = self.transform.basis.xform(pos)
	var force_local = self.transform.basis.xform(force)
	self.add_force(force_local, pos_local)


# Drive the jaws: 1 open, -1 close, 0 stop. The hinges' motors turn the
# left jaw outwards (open) at a negative speed and the right one at a
# positive speed (the other way round shuts them).
func drive_jaws(command):
	ljoint.set_param(6, -command)
	rjoint.set_param(6, command)
	gripper_command = command


func actuate_servo(id, percentage):
	if percentage <= 0:
		return  # no output on this channel

	var force = (percentage - 0.5) * 2 * -THRUST
	match id:
		0:
			self.add_force_local($t1.transform.basis*Vector3(force,0,0), $t1.translation)
		1:
			self.add_force_local($t2.transform.basis*Vector3(force,0,0), $t2.translation)
		2:
			self.add_force_local($t3.transform.basis*Vector3(force,0,0), $t3.translation)
		3:
			self.add_force_local($t4.transform.basis*Vector3(force,0,0), $t4.translation)
		4:
			self.add_force_local($t5.transform.basis*Vector3(force,0,0), $t5.translation)
		5:
			self.add_force_local($t6.transform.basis*Vector3(force,0,0), $t6.translation)
		6:
			self.add_force_local($t7.transform.basis*Vector3(force,0,0), $t7.translation)
		7:
			self.add_force_local($t8.transform.basis*Vector3(force,0,0), $t8.translation)
		8:
			# SERVO9: ArduSub's lights output (SERVO9_FUNCTION = Lights1)
			percentage -= 0.1
			$light1.light_energy = percentage * 5
			$light2.light_energy = percentage * 5
			$light3.light_energy = percentage * 5
			$light4.light_energy = percentage * 5
			$scatterlight.light_energy = percentage * 2.5
			if percentage < 0.01 and light_glows[0].get_parent() != null:
				for light in light_glows:
					self.remove_child(light)
			elif percentage > 0.01 and light_glows[0].get_parent() == null:
				for light in light_glows:
					self.add_child(light)
		9:
			# SERVO10: gripper, as the control software drives it
			# (MAV_CMD_DO_SET_SERVO: 1900 open, 1100 close, 1500 stop).
			# The app opens/closes with a 2 s pulse, which moves the real
			# gripper all the way; a slow computer runs BlueSim slower than
			# real time, so the same 2 s would only open it partly. So a pulse
			# moves the jaws all the way (the hinge limits stop them), and only
			# a change of the servo is acted on, so the keys work too.
			var command = 1 if percentage > 0.6 else (-1 if percentage < 0.4 else 0)
			if command != last_gripper_servo:
				last_gripper_servo = command
				if command != 0:
					drive_jaws(command)
		10:
			# SERVO11: camera tilt. Only a change is acted on, so the keys
			# (and BLUESIM_CAMERA_TILT) aren't overridden by a servo that
			# just sits at its middle position.
			if abs(percentage - last_tilt_servo) > 0.01:
				last_tilt_servo = percentage
				$Camera.rotation_degrees.x = -45 + 90 * percentage


func _unhandled_input(event):
	if event is InputEventKey:
		# There are for debugging:
		# Some forces:
		if event.pressed and event.scancode == KEY_X:
			self.add_central_force(Vector3(30, 0, 0))
		if event.pressed and event.scancode == KEY_Y:
			self.add_central_force(Vector3(0, 30, 0))
		if event.pressed and event.scancode == KEY_Z:
			self.add_central_force(Vector3(0, 0, 30))
		# Reset position
		if event.pressed and event.scancode == KEY_R:
			set_translation(_initial_position)
		# Some torques
		if event.pressed and event.scancode == KEY_Q:
			self.add_torque(self.transform.basis.xform(Vector3(15, 0, 0)))
		if event.pressed and event.scancode == KEY_T:
			self.add_torque(self.transform.basis.xform(Vector3(0, 15, 0)))
		if event.pressed and event.scancode == KEY_E:
			self.add_torque(self.transform.basis.xform(Vector3(0, 0, 15)))
		# Some hard-coded positions (used to check accelerometer)
		if event.pressed and event.scancode == KEY_U:
			self.look_at(Vector3(0, 100, 0), Vector3(0, 0, 1))  # expects +X
			mode = RigidBody.MODE_STATIC
		if event.pressed and event.scancode == KEY_I:
			self.look_at(Vector3(100, 0, 0), Vector3(0, 100, 0))  #expects +Z
			mode = RigidBody.MODE_STATIC
		if event.pressed and event.scancode == KEY_O:
			self.look_at(Vector3(100, 0, 0), Vector3(0, 0, -100))  #expects +Y
			mode = RigidBody.MODE_STATIC

		if event.pressed and event.is_action("camera_switch"):
			if $Camera.is_current():
				$Camera.clear_current(true)
			else:
				$Camera.set_current(true)

	if event.is_action("lights_up"):
		var percentage = min(max(0, $light1.light_energy + 0.1), 5)
		if percentage > 0:
			for light in light_glows:
				self.add_child(light)
		$light1.light_energy = percentage
		$light2.light_energy = percentage
		$light3.light_energy = percentage
		$light4.light_energy = percentage
		$scatterlight.light_energy = percentage * 0.5

	if event.is_action("lights_down"):
		var percentage = min(max(0, $light1.light_energy - 0.1), 5)
		$light1.light_energy = percentage
		$light2.light_energy = percentage
		$light3.light_energy = percentage
		$light4.light_energy = percentage
		$scatterlight.light_energy = percentage * 0.5
		if percentage == 0:
			for light in light_glows:
				self.remove_child(light)


func process_keys():
	if Input.is_action_pressed("forward"):
		self.add_force_local(Vector3(0, 0, 40), Vector3(0, -0.05, 0))
	elif Input.is_action_pressed("backwards"):
		self.add_force_local(Vector3(0, 0, -40), Vector3(0, -0.05, 0))

	if Input.is_action_pressed("strafe_right"):
		self.add_force_local(Vector3(-40, 0, 0), Vector3(0, -0.05, 0))
	elif Input.is_action_pressed("strafe_left"):
		self.add_force_local(Vector3(40, 0, 0), Vector3(0, -0.05, 0))

	if Input.is_action_pressed("upwards"):
		self.add_force_local(Vector3(0, 70, 0), Vector3(0, -0.05, 0))
	elif Input.is_action_pressed("downwards"):
		self.add_force_local(Vector3(0, -70, 0), Vector3(0, -0.05, 0))

	if Input.is_action_pressed("rotate_left"):
		self.add_torque(self.transform.basis.xform(Vector3(0, 20, 0)))
	elif Input.is_action_pressed("rotate_right"):
		self.add_torque(self.transform.basis.xform(Vector3(0, -20, 0)))

	if Input.is_action_pressed("camera_up"):
		$Camera.rotation_degrees.x = min($Camera.rotation_degrees.x + 0.1, 45)
	elif Input.is_action_pressed("camera_down"):
		$Camera.rotation_degrees.x = max($Camera.rotation_degrees.x - 0.1, -45)

	if Input.is_action_pressed("gripper_open"):
		drive_jaws(1)
	elif Input.is_action_pressed("gripper_close"):
		drive_jaws(-1)
	elif not Globals.external_sitl and not Globals.capturing:  # with SITL the gripper servo drives it (capture sets the jaws itself)
		drive_jaws(0)

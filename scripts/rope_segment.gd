extends RigidBody

# One piece of a physics rope (built by target_rope.gd). The rope is a chain
# of these joined by pin joints; each piece gets, every physics step:
#   - its weight minus its buoyancy: (rope density - water density) * volume * g
#   - water drag on the flow relative to it (Morison), split into the part
#     across the piece (form drag, Cd 1.2 on the projected area d * L) and
#     the part along it (skin friction, Cd 0.01 on the surface area pi * d * L)
#   - added mass: the water it has to push aside when it accelerates
#     (Ca = 1, the displaced water's mass, added to its own)
# The flow is relative to Globals.current_velocity, so a current bends the rope.
# Forces are turned into a velocity change here (not add_force) so they apply
# for exactly one step, whatever the physics engine.

const RHO_WATER = 1000.0  # kg/m3, fresh water (pool)
const CD_NORMAL = 1.2
const CD_TANGENT = 0.01
const C_ADDED_MASS = 1.0

var diameter = 0.0508
var length = 0.25
var density = 1140.0
var net_weight = 0.0  # N, + = sinks
var area_normal = 0.0  # m2, projected area across the piece
var area_surface = 0.0  # m2, wetted surface area


func setup(rope_diameter, piece_length, rope_density):
	diameter = rope_diameter
	length = piece_length
	density = rope_density
	var volume = PI * diameter * diameter / 4.0 * length
	var g = ProjectSettings.get_setting("physics/3d/default_gravity")
	mass = (density + C_ADDED_MASS * RHO_WATER) * volume
	net_weight = (density - RHO_WATER) * volume * g
	area_normal = diameter * length
	area_surface = PI * diameter * length
	gravity_scale = 0.0  # weight and buoyancy are applied below
	linear_damp = 0.0  # water drag is applied below
	angular_damp = 2.0  # rough stand-in for drag against spinning
	can_sleep = false
	add_to_group("rope_segment")


func _integrate_forces(state):
	var flow = state.linear_velocity - Globals.current_velocity  # through the water
	var axis = state.transform.basis.y.normalized()  # along the piece
	var along = axis * axis.dot(flow)
	var across = flow - along
	var drag = -0.5 * RHO_WATER * CD_NORMAL * area_normal * across.length() * across
	drag += -0.5 * RHO_WATER * CD_TANGENT * area_surface * along.length() * along
	var drag_dv = drag / mass * state.step
	if drag_dv.length() > flow.length():
		# quadratic drag can at most stop the motion through the water in one step
		drag_dv = -flow
	state.linear_velocity += drag_dv + Vector3(0, -net_weight / mass * state.step, 0)

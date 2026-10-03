extends GridContainer

# Menu choices for the test rope, the water current and the post
# (scripts/rope_types.gd), stored in Globals before the level loads.

const RopeTypes = preload("res://scripts/rope_types.gd")


func _ready():
	columns = 2
	add_choice("Rope", names(RopeTypes.MATERIALS), Globals.rope_material, "_on_material")
	add_choice("Rope setup", names(RopeTypes.SETUPS), Globals.rope_setup, "_on_setup")
	var lengths = []
	for l in RopeTypes.LENGTHS:
		lengths.append("%d m (free end)" % l)
	var length_index = RopeTypes.LENGTHS.find(Globals.rope_length)
	add_choice("Rope length", lengths, max(length_index, 0), "_on_length")
	var speeds = []
	for v in RopeTypes.CURRENT_SPEEDS:
		speeds.append("none" if v == 0.0 else "%.2f m/s" % v)
	add_choice("Current", speeds, max(RopeTypes.CURRENT_SPEEDS.find(Globals.current_speed), 0), "_on_current")
	add_choice("Current from", names(RopeTypes.CURRENT_DIRECTIONS), Globals.current_direction, "_on_direction")
	add_choice("Post", names(RopeTypes.POSTS), Globals.post_type, "_on_post")


func names(list):
	var out = []
	for item in list:
		out.append(item["name"])
	return out


func add_choice(title, items, selected, method):
	var label = Label.new()
	label.text = title
	add_child(label)
	var option = OptionButton.new()
	for item in items:
		option.add_item(item)
	option.select(selected)
	option.size_flags_horizontal = SIZE_EXPAND_FILL
	option.connect("item_selected", self, method)
	add_child(option)


func _on_material(index):
	Globals.rope_material = index


func _on_setup(index):
	Globals.rope_setup = index


func _on_length(index):
	Globals.rope_length = RopeTypes.LENGTHS[index]


func _on_current(index):
	Globals.current_speed = RopeTypes.CURRENT_SPEEDS[index]


func _on_direction(index):
	Globals.current_direction = index


func _on_post(index):
	Globals.post_type = index

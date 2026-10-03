extends PanelContainer

# Declare member variables here. Examples:
# var a = 2
# var b = "text"


# Called when the node enters the scene tree for the first time.
func _ready():
	if Globals.isHTML5:
		Globals.physics_rate = 60
	else:
		Globals.physics_rate = 200
	Engine.iterations_per_second = Globals.physics_rate
	$VBoxContainer/physicsRate.text = 'Physics: ' + String(Globals.physics_rate) + ' Hz'
	$VBoxContainer/physicsRateSlider.value = Globals.physics_rate
	if Globals.external_sitl:
		# keep the frame rate up so the physics (and SITL) runs in real time
		for toggle in ["godrayToggle", "dirtparticlesToggle", "fancyWaterToggle", "Ping360Toggle"]:
			get_node("VBoxContainer/" + toggle).pressed = false


# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
#	pass


func _input(event):
	if event.is_action_pressed("ui_cancel"):
		if not self.is_visible():
			self.show()
		else:
			self.hide()


func _on_HSlider_value_changed(value):
	Globals.physics_rate = value
	Engine.iterations_per_second = value
	$VBoxContainer/physicsRate.text = 'Physics: ' + String(Globals.physics_rate) + 'Hz'

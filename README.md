# BlueSim
BlueROV2 Simulator.

# Download

 - [Windows](https://github.com/bluerobotics/bluesim/releases/download/latest/bluesim-windows.zip)
 - [Mac](https://github.com/bluerobotics/bluesim/releases/download/latest/bluesim-mac.zip)
 - [Linux](https://github.com/bluerobotics/bluesim/releases/download/latest/bluesim-linux.zip)
 - [Web](https://github.com/bluerobotics/bluesim/releases/download/latest/bluesim-web.zip) (Works better on firefox)

# Usage

  1. Open [QGroundControl](http://qgroundcontrol.com/)
  2. Set up a new communication link at TCP 127.0.0.1, port 5760.
  3. Launch BlueSim
  4. Chooset BlueRov2 Heavy
  5. Connect the new link in QGC
  6. Drive around using the gamepad as if controlling a real BlueRov2.


# Default keys:

If there is not SITL instance attached, these keys can be used to control the ROV:

|      Action      |  Key  |
|:----------------:|:-----:|
| Downwards        | Shift |
| Upwards          | Space |
| Forward          |   Up  |
| Backwards        |  Down |
| Rotate right     | Right |
| Rotate left      |  Left |
| Strafe right     |   D   |
| Strafe left      |   A   |
| Lights down      |   1   |
| Lights up        |   2   |
| Open gripper     |   3   |
| Close gripper    |   4   |
| Tilt camera down |   5   |
| Tilt camera up   |   6   |
| Rope 3 m ahead   |   P   |
| Next rope type   |   N   |
| Current speed    |   V   |
| Lean the fixed rope sideways / towards |  K / L  |
| Post beside the rope |   J   |

# Camera stream (external SITL)

When started with `BLUESIM_EXTERNAL_SITL=1` (`run_bluesim.sh`), BlueSim sends
the ROV camera to UDP 5602 for the control software, 10 frames/s. The stream
has its own camera set up like the BlueROV2's Low-Light HD USB Camera:
**1920x1080, 80° horizontal field of view** (no lens distortion), following
the ROV camera and its tilt. The window keeps its own view. On a slow GPU use
a smaller picture with the same view: `BLUESIM_VIDEO_SIZE=1280x720 ./run_bluesim.sh`.
Each frame is raw RGB in UDP packets (header described in
`scripts/BlueROV2Heavy.gd`), paced over a few rendered frames so a 6 MB frame
doesn't overflow the receiver.

# Test rope, current and post

The pool has a **2 inch (50.8 mm) red test rope** 3 m in front of the ROV
camera, for the rope detection / cutting / following code
([Rope_Detection](https://github.com/LukeGrif/Rope_Detection)). Choose it in
the **menu** (under Pool), or before starting with environment variables:

| Menu | Choices | Environment variable |
|---|---|---|
| Rope | Fixed rod (no physics), Polypropylene (floats, 910 kg/m³), Dyneema/HMPE (floats slightly, 975), Nylon (sinks slowly, 1140), Polyester (sinks, 1380), Lead-core (sinks fast, 2000) | `BLUESIM_ROPE=nylon,hanging,10` (material, setup, length) |
| Rope look | Red 3-strand, Blue polypropylene 3-strand, Yellow polypropylene 3-strand, Orange 3-strand, Green 3-strand, White nylon 3-strand, Manila (natural fibre) 3-strand, Navy braid with white fleck, White braid with red tracer, Royal blue braid, Black braid, Smooth red (the old plain rope) | `BLUESIM_ROPE_LOOK=blue` (`red`, `blue`, `yellow`, `orange`, `green`, `white`, `manila`, `navy_braid`, `white_braid`, `blue_braid`, `black_braid`, `smooth_red`) |
| Rope setup | Surface to floor (pinned at both), Hanging from the surface (free bottom end), Standing on the floor (free top end) | |
| Rope length | 5, 10, 20 m (for a free end) | |
| Current / from | none, 0.1, 0.25, 0.5 m/s; from the left, right, ahead, behind (relative to the ROV when the rope is placed) | `BLUESIM_CURRENT=0.25,left` |
| Post | none, pile 0.3 m, pole 0.1 m | `BLUESIM_POST=pile` |
| (camera tilt) | degrees down, up to 45 (35 puts the gripper's jaws at the bottom of the picture) | `BLUESIM_CAMERA_TILT=35` |

Material keys: `fixed`, `polypropylene`, `dyneema`, `nylon`, `polyester`,
`leadcore`; setups `surface_floor`, `hanging`, `standing`, `u_shape` (a U
hanging from two points at the surface 3 m apart across the ROV's view; its
length is the menu's 5/10/20 m; always a physics rope, nylon if "fixed" is
chosen), e.g. `BLUESIM_ROPE=nylon,u_shape,10`.

| Key | |
|---|---|
| P | put the rope 3 m in front of the ROV again (rebuilds it) |
| N | next rope material |
| M | next rope look |
| V | next current speed |
| K / L | lean the fixed rod sideways (0, 20, 40, -20, -40°) / towards or away (0, 20, -20°) |
| J | put the post 3 m ahead and 1.5 m right of the ROV (a pile if none was chosen) |

### Rope look

The rope is drawn by a procedural shader (`rope/rope.shader`, no textures)
that looks like real marine rope close up:

- **3-strand (laid)**: three strands twisted round each other with dark
  grooves between them, yarns running across each strand, fibre texture and
  a scalloped outline;
- **braided**: a 16-carrier over-under cover, like double braid;
- **tracer / fleck**: coloured yarns in one strand or two carriers
  (e.g. navy with white fleck, white with a red tracer);
- **fuzz**: loose fibres for natural rope (manila).

The pattern runs on continuously along the physics rope and its colour is a
setting, so any colour can be made (the training capture uses random ones).
The look doesn't change the physics (choose the material separately).

### Rope physics

A physics rope (`scripts/rope_segment.gd`) is a chain of 25 cm pieces joined
by pin joints (free to bend). Every physics step each piece gets:

- **weight minus buoyancy**: (rope density − 1000 kg/m³) × volume × g, so
  polypropylene floats up and polyester sinks;
- **water drag** on the flow through the water (piece velocity minus the
  current), Morison style: across the piece with Cd 1.2 on its projected area
  (d × L), along it with Cd 0.01 on its surface (π d L);
- **added mass**: the displaced water's mass (Ca = 1) added to its own, so it
  accelerates like a body in water, not in air.

The current also pushes the ROV (through its drag), so DYNAMIC has to hold
station against it.

Checked against the steady lean of a straight rope with a free end in a
uniform current (drag across the rope balances its weight in water:
½ ρ Cd d U² cos²θ = w sinθ), 10 m ropes:

| Rope, current | Simulated | Theory |
|---|---|---|
| Nylon, 0.25 m/s | 30.7° | 30.5° |
| Nylon, 0.5 m/s | 56.6° | 56.5° |
| Polyester, 0.25 m/s | 14.1° | 13.8° |
| Lead-core, 0.25 m/s | 5.7° | 5.4° |
| Polypropylene (standing), 0.25 m/s | 39.5° | 39.4° |

The rope stretches less than 1 %. It takes a minute or two to settle after a
change (the lower part has to move metres through the water), as a real rope
would. "Surface to floor" is pinned at exactly the depth, so it's taut: it
only bows as far as the joints give. Not modelled: rope elasticity and
bending stiffness, vortex shedding (strumming), a buoy that bobs at the
surface.

### Holding the rope

When the gripper has been **closing for 0.5 s with a rope piece between the
jaws**, that piece is pinned to the ROV (simulated jaws can't reliably
squeeze a rope); it stays held until the gripper **opens**. Close with the app's
gripper buttons (servo 10) or key 4, open with key 3. An open or close command
from the app (a 2 s pulse, which opens the real gripper fully) moves the jaws
all the way, however slowly BlueSim runs. The rope is then towed by
the ROV, with its drag and weight acting on the ROV. The log prints
`Gripper: holding the rope` / `let go of the rope`. Tested: centred on a
hanging nylon rope, closed, and reversed: the rope stayed in the jaws and was
dragged to a 60° lean; opening let it go.

### Post

A fixed grey post from the floor to above the surface (pile 0.3 m or pole
0.1 m), 3 m ahead and 1.5 m to the right of the ROV camera when placed, for
manipulation tests such as wrapping the rope round it.

### Ground truth

The line at the bottom of the window shows where the rope really is relative to
the ROV camera (drawn on the window only, not in the camera stream). The same
is sent 10 times a second as JSON on **UDP 5603**:

```json
{"t": 12.3, "ahead": 0.81, "right": -0.01, "up": 0.0, "dir": [0.0, 1.0, 0.0],
 "lean_side": 0, "lean_ahead": 0, "depth": 6.2, "rope": "nylon", "setup": "hanging",
 "current": 0.25, "diameter": 0.0508, "points": [[0.1, 2.0, 0.8], ...],
 "post": {"diameter": 0.3, "top": [...], "bottom": [...]}}
```

`ahead`/`right`/`up`: the closest point of the rope's centre line to the
camera, in metres in the camera's axes; `dir`: the unit vector up the rope
there, as [right, up, ahead]; `lean_side`/`lean_ahead`: its lean (+ = top
leans right / away); `points`: the whole centre line, top to bottom;
`depth`: the camera's depth. Rope_Detection logs its estimates against this
(`python3 main.py --log`).

# Training pictures (sim-to-real)

```bash
BLUESIM_CAPTURE=~/rope_data BLUESIM_CAPTURE_COUNT=2000 ./run_bluesim.sh
```

goes straight to the pool (or another world, `BLUESIM_LEVEL` below; no
SITL) and saves pictures with exact labels for
training a rope detector, then quits. Each picture is taken by a camera like
the BlueROV2's (1920x1080, 80° horizontal; `BLUESIM_CAPTURE_SIZE=960x540`
for smaller ones), in one of two ways:

- **ROV view (60 %)**: from the ROV's own camera tilted down 25–45° (some
  less) so the gripper's jaws are at the bottom of the picture, as they will
  be in most real footage. For each picture the ROV is moved next to the
  rope: approaching it (0.35–2.5 m), at the jaws, with the rope in the jaws,
  or with the rope off to one side. The jaws are open or closed per rope.
- **orbit view (40 %)**: from anywhere 0.25–4 m around the rope (a quarter
  of these aimed at the ROV's tether), about 1 in 10 looking away (no rope).

with randomised:

- rope: material (a physics rope, never the fixed rod: a featureless
  straight pole isn't what a real rope looks like), setup, length, current
  (each new rope), and for every picture its look: 3-strand or braided
  (never smooth); colour (30 % reds like
  the real rope, 15 % yellows, 35 % marine rope colours, 20 % anything); 30 %
  with a tracer/fleck; some with loose fibres. So a detector has to learn the
  rope's shape and texture, not one colour
- **hard negatives**: 0–2 tether-like cables per picture (smooth, 6–16 mm,
  half yellow like a Fathom tether, otherwise blue, black, white, orange,
  green, grey): crossing the rope, lying alongside it (4–35 cm away), or in
  front of the camera/gripper, half of those looped. The ROV's own tether
  also gets a random colour. With yellow ropes too, colour alone never
  separates rope from tether
- no test post (pile/pole): it's only for the manual tests (`J`)
- water: tint and visibility (2–30 m), ambient light, sun, the ROV's lamp

A new rope is built every 20 pictures; the physics runs a little between
pictures and is paused for each one, so the label matches it exactly (the
ROV is put back before the physics runs again). `BLUESIM_CAPTURE_SEED`
(default 1) makes a set repeatable.

Output: `images/NNNNNN.png`, `rov_depth/NNNNNN.png` (the distance to the
ROV's own parts, rendered, so the masks know where the jaws hide the rope),
`scene_depth/NNNNNN.png` (the distance to the world itself: walls, floor,
pilings, a wreck, everything but the rope, tether and cables, so the masks
hide the rope wherever the world is in front of it, in any world; up to
30 m) and `labels/NNNNNN.json` (camera model `fx fy cx cy`, the rope's centre line
in camera coordinates and its diameter, the ROV's tether, the cables, the
post, the settings including `view`, `phase` and `camera_tilt_deg`).
`Rope_Detection/dataset/make_masks.py` turns them into masks and a class
picture (background, rope, tether, ROV).

# SITL integration:

    Before opening Bluesim (it launches its own SITL instance), run:

 `sim_vehicle.py -j6 -L RATBeach -v ArduSub -f vectored_6dof --model JSON --out=udpout:0.0.0.0:14550`

# External Levels

External levels can be loaded by placing a .pck file in the "levels" folder at the same level as the simulator executable (the folder is created at first run if it does not exist).

The pck file must have a `custom_level.tscn` scene, which will be loaded in runtime and added as a child to `baselevel.tscn`, which contains the ROV, water, sky, and other basic functionality.
The root node at "custom_level.tscn" should preferably be a spatial node with all your custom 3D scene within it.

`BLUESIM_LEVEL` starts a world without the menu (for captures, or with
`run_bluesim.sh`):

| `BLUESIM_LEVEL=` | world |
|---|---|
| `pool` (default) | the pool |
| `harbour.tscn` (or `res://levels/harbour.tscn`) | a test harbour: sandy seabed 14 m down, wooden pilings and a box-shaped wreck near the rope, rocks |
| `sunken_ship.pck` | a .pck level: a full path, or a file in the `levels` folder next to the Godot program or in this project's `levels/` folder |

The test rope is put 3 m in front of the ROV in any world. For training
pictures from several worlds, `Rope_Detection/dataset/collect_sim.sh` takes
`LEVELS="pool harbour.tscn sunken_ship.pck"` (one world per run, in turn).

## Sunken Ship Level

![image](https://user-images.githubusercontent.com/4013804/104868028-09e92800-5921-11eb-9b51-67f947707725.png)
A sample level with a sunken ship can be downloaded [here](https://drive.google.com/file/d/1WH4l-l8qXnWUa5BHHtIDgaU-UnMEJ2H_/view?usp=share_link).

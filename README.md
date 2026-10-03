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
| Close gripper    |   3   |
| Open gripper     |   4   |
| Tilt camera down |   5   |
| Tilt camera up   |   6   |
| Rope 3 m ahead   |   P   |
| Lean rope sideways / towards |  K / L  |

# Test rope

The pool has a fixed **red rope, 2 inch (50.8 mm) diameter**, from the water
surface to the floor, for the rope detection / cutting / following code
([Rope_Detection](https://github.com/LukeGrif/Rope_Detection)). It is placed
3 m in front of the ROV camera when the level loads.

| Key | Rope |
|---|---|
| P | move it 3 m in front of the ROV again |
| K | lean it sideways (as seen from the ROV): 0, 20, 40, -20, -40° |
| L | lean it towards / away from the ROV: 0, 20, -20° |

A leaning rope still passes through the point 3 m ahead of the camera, so it
crosses the middle of the picture. The rope is solid (the ROV and gripper
touch it) and the downward rangefinder ignores it.

**Ground truth:** the line at the bottom of the window shows where the rope
really is relative to the ROV camera (drawn on the window only, not in the
camera stream). The same is sent 10 times a second as JSON on **UDP 5603**:

```json
{"t": 12.3, "ahead": 0.81, "right": -0.01, "up": 0.0, "dir": [0.0, 1.0, 0.0],
 "lean_side": 0, "lean_ahead": 0, "depth": 6.2}
```

`ahead`/`right`/`up` are the closest point of the rope's centre line to the
camera, in metres in the camera's axes; `dir` is the unit vector up the rope in
the same axes; `depth` is the camera's depth below the surface. Rope_Detection
logs its estimates against this (`python3 main.py --log`).

Settings are at the top of `scripts/target_rope.gd` (diameter, colour,
distance, lean angles, port).

# SITL integration:

    Before opening Bluesim (it launches its own SITL instance), run:

 `sim_vehicle.py -j6 -L RATBeach -v ArduSub -f vectored_6dof --model JSON --out=udpout:0.0.0.0:14550`

# External Levels

External levels can be loaded by placing a .pck file in the "levels" folder at the same level as the simulator executable (the folder is created at first run if it does not exist).

The pck file must have a `custom_level.tscn` scene, which will be loaded in runtime and added as a child to `baselevel.tscn`, which contains the ROV, water, sky, and other basic functionality.
The root node at "custom_level.tscn" should preferably be a spatial node with all your custom 3D scene within it.

## Sunken Ship Level

![image](https://user-images.githubusercontent.com/4013804/104868028-09e92800-5921-11eb-9b51-67f947707725.png)
A sample level with a sunken ship can be downloaded [here](https://drive.google.com/file/d/1WH4l-l8qXnWUa5BHHtIDgaU-UnMEJ2H_/view?usp=share_link).

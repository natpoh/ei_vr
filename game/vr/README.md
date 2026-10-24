# Evil Islands VR layer

VR for the Cursed Lands remake of Evil Islands. Everything in this folder is
MIT-licensed (see `LICENSE`); the rest of the game is Cursed Lands under
Apache-2.0 (see `../../LICENSE.md` and `../../THIRD_PARTY_NOTICES.md`).

## Running (prototype)

From the repository root, with a running OpenXR runtime (Virtual Desktop,
SteamVR, Oculus):

```
Play-VR.cmd
```

It starts Godot 4.7 with `--xr-mode on --rendering-driver vulkan`. Menus and
loading run on the monitor (the runtime shows its desktop). Once a zone is on,
the headset shows the world from the game camera's eye (F6 cycles the views;
first person puts it at the hero's eyes) and the game's interface hangs as a
panel in front of you, with a yellow dot for the mouse pointer. Ctrl+F12 or
the runtime's recenter puts the current head pose back on the eye.

## Godot 4.7 multiview pitfalls handled here

- SMAA and any 3D scale below 1.0 make every headset frame fail (black
  headset): the headset viewport uses FXAA at scale 1.0.
- Shaders reading `hint_depth_texture` / `hint_screen_texture` as `sampler2D`
  see one eye's layer in both eyes: they are rewritten to `sampler2DArray` at
  `VIEW_INDEX` while the headset is on; water reflections are off there.
- The game's own culling and LOD read its rig camera, which therefore turns
  with the head.

## Outside this folder

- `game/project.godot`: the `EIVR` autoload and the `[xr]` section (OpenXR is
  off unless `--xr-mode on` is given; multiview shaders are on).

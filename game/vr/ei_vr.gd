extends Node
## Evil Islands VR (MIT, see res://vr/LICENSE): plays the Cursed Lands remake in
## an OpenXR headset.
##
## Start with `--xr-mode on --rendering-driver vulkan` (see Play-VR.cmd). Without
## an initialized OpenXR interface this node does nothing, so the flat game is
## unchanged.
##
## While a zone is on (no movie, no scripted camera hold) the headset shows the
## game world from the game camera's eye: DirectControl.apply_camera or the
## CameraRig place that eye earlier in the same frame, and the headset adds its
## own rotation and movement on top (the origin is placed so the pose taken at
## the last recenter lands on the game's eye, facing the game's heading).
## Recenter: the runtime's recenter (hold the headset's system button) or
## Ctrl+F12.
##
## The world is drawn for the headset by its own SubViewport (`xr_view`) that
## shares the game's World3D. The main window stops drawing 3D and draws only
## the game's interface on a transparent background; that picture hangs in the
## headset as a panel in front of the player (`panel`), with a dot for the mouse
## pointer, so menus, dialogs and the HUD stay usable without the monitor.

const EYE_NEAR := 0.03   # DirectControl's first-person near plane
const GAME_CAMERA_FOV := 110.0   # covers both eyes of current headsets
## Render layer 24, outside the game's 20 scene layers: only the headset
## camera draws the interface panel (never the water mirror or other cameras).
const UI_LAYER := 1 << 23
const PANEL_WIDTH := 1.6        # metres
const PANEL_DISTANCE := 1.9     # in front of the head
const PANEL_DROP := 0.25        # below the recentered eye height
const PANEL_FOLLOW_DEG := 35.0  # the panel turns after the head beyond this

var xr: XRInterface
var xr_view: SubViewport
var origin: XROrigin3D
var camera: XRCamera3D
var panel: MeshInstance3D
var cursor: MeshInstance3D
var game: Game
var vr_view := false
var _calib_pos := Vector3.ZERO   # headset position (origin space) that maps to the eye
var _calib_yaw := 0.0            # headset yaw that maps to the game's heading
var _need_recenter := true
var _game_eye := Transform3D.IDENTITY   # the game's camera pose before the head turned it
var _written := Transform3D.IDENTITY    # the head pose we last gave the game's camera
var _panel_yaw := 0.0
var _panel_chasing := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000   # after CameraRig / DirectControl placed the eye
	xr = XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		print("EIVR: OpenXR is not running; VR off")
		set_process(false)
		set_process_unhandled_key_input(false)
		return
	# The runtime paces the frames; vsync on the monitor would halve the rate.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if xr.has_signal("pose_recentered"):
		xr.connect("pose_recentered", func(): _need_recenter = true)
	_build_view()
	_build_panel()
	get_tree().node_added.connect(_on_node_added)
	_pick_refresh_rate()
	print("EIVR: OpenXR running (%s), refresh %.0f Hz" % [xr.get_name(), _refresh_rate()])


## The headset's own viewport. Its anti-aliasing is fixed to what Godot 4.7
## supports in multiview: SMAA and any 3D scale below 1 make every frame fail
## ("Layers of our texture doesn't match view count", black headset).
func _build_view() -> void:
	xr_view = SubViewport.new()
	xr_view.name = "EIVRView"
	xr_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	xr_view.msaa_3d = Viewport.MSAA_DISABLED
	xr_view.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	xr_view.use_taa = false
	xr_view.scaling_3d_scale = 1.0
	xr_view.audio_listener_enable_3d = false   # the game's camera keeps the sound
	add_child(xr_view)
	origin = XROrigin3D.new()
	origin.name = "EIVROrigin"
	camera = XRCamera3D.new()
	camera.name = "EIVRCamera"
	camera.near = EYE_NEAR
	camera.cull_mask |= UI_LAYER
	origin.add_child(camera)
	xr_view.add_child(origin)


func _build_panel() -> void:
	panel = MeshInstance3D.new()
	panel.name = "EIVRPanel"
	panel.layers = UI_LAYER
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	panel.mesh = QuadMesh.new()
	panel.material_override = _overlay_material(null, 10)
	panel.visible = false
	origin.add_child(panel)
	cursor = MeshInstance3D.new()
	cursor.name = "EIVRCursor"
	cursor.layers = UI_LAYER
	cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dot := QuadMesh.new()
	dot.size = Vector2(0.018, 0.018)
	cursor.mesh = dot
	var m := _overlay_material(null, 11)
	m.albedo_color = Color(1.0, 0.85, 0.3)
	cursor.material_override = m
	panel.add_child(cursor)


## Unlit, drawn over the world (no depth test), no fog or shadows.
static func _overlay_material(tex: Texture2D, priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.disable_fog = true
	m.disable_receive_shadows = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	m.render_priority = priority
	m.albedo_texture = tex
	return m


## The game holds about 50-90 fps in the headset; when the runtime offers a
## lower rate than its default, take the lowest of at least 72 Hz, so the
## runtime synthesizes fewer frames (`-- --eivr-hz=90` picks another).
const WANTED_HZ := 72.0


func _pick_refresh_rate() -> void:
	if not xr.has_method("get_available_display_refresh_rates"):
		return
	var wanted := WANTED_HZ
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--eivr-hz="):
			wanted = arg.trim_prefix("--eivr-hz=").to_float()
	var rates: Array = xr.call("get_available_display_refresh_rates")
	var best := 0.0
	for r: float in rates:
		if r >= wanted - 0.5 and (best == 0.0 or r < best):
			best = r
	print("EIVR: refresh rates offered %s, asking for %.0f Hz" % [rates, best])
	if best > 0.0:
		xr.set("display_refresh_rate", best)


func _on_node_added(n: Node) -> void:
	if n is Game:
		game = n


func _refresh_rate() -> float:
	return float(xr.get("display_refresh_rate")) if "display_refresh_rate" in xr else 0.0


func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_F12 and k.ctrl_pressed:
		_need_recenter = true
		get_viewport().set_input_as_handled()


func _wanted() -> bool:
	if not is_instance_valid(game) or game.world == null or game.rig == null or game.direct == null:
		return false
	if game.session and game.session.movie_active():
		return false
	return not game.rig.held


func _process(dt: float) -> void:
	var want := _wanted()
	if want != vr_view:
		_set_vr_view(want)
	if not vr_view:
		return
	# The game's own eye for this frame. If the game did not move its camera
	# since we turned it with the head (see below), reuse the game's last pose.
	var eye := game.rig.camera.global_transform
	if eye.is_equal_approx(_written):
		eye = _game_eye
	else:
		_game_eye = eye
	var yaw := eye.basis.get_euler().y
	var head := camera.transform   # tracked pose in origin space
	if _need_recenter:
		_calib_pos = head.origin
		_calib_yaw = head.basis.get_euler().y
		_panel_yaw = _calib_yaw
		_need_recenter = false
		print("EIVR: recentered at height %.2f m" % _calib_pos.y)
	var b := Basis(Vector3.UP, yaw - _calib_yaw)
	origin.global_transform = Transform3D(b, eye.origin - b * _calib_pos)
	camera.far = game.rig.camera.far
	# Culling, LOD, object fading and occluder checks in the game read its
	# rig camera; turn it with the head and widen it to the headset's field so
	# they work on what the headset shows (water and terrain pieces otherwise
	# change when the head turns).
	_written = camera.global_transform
	game.rig.camera.global_transform = _written
	game.rig.camera.fov = GAME_CAMERA_FOV
	_place_panel(head, dt)
	_patch_tick(dt)
	_debug_tick(dt)


## The interface panel hangs in front of the head, a little below the eyes, and
## turns after the head once the head looks more than PANEL_FOLLOW_DEG away.
func _place_panel(head: Transform3D, dt: float) -> void:
	var head_yaw := head.basis.get_euler().y
	if absf(angle_difference(_panel_yaw, head_yaw)) > deg_to_rad(PANEL_FOLLOW_DEG):
		_panel_chasing = true
	if _panel_chasing:
		_panel_yaw = lerp_angle(_panel_yaw, head_yaw, 1.0 - exp(-dt * 5.0))
		if absf(angle_difference(_panel_yaw, head_yaw)) < deg_to_rad(3.0):
			_panel_chasing = false
	var root := get_tree().root
	var size := root.get_visible_rect().size
	var q := panel.mesh as QuadMesh
	q.size = Vector2(PANEL_WIDTH, PANEL_WIDTH * size.y / maxf(size.x, 1.0))
	var pb := Basis(Vector3.UP, _panel_yaw)
	panel.transform = Transform3D(pb, Vector3(head.origin.x, _calib_pos.y - PANEL_DROP, head.origin.z)
		+ pb * Vector3(0.0, 0.0, -PANEL_DISTANCE))
	# The OS pointer is not part of the window picture: show where it is.
	var mouse := root.get_mouse_position()
	cursor.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
		and Rect2(Vector2.ZERO, size).has_point(mouse)
	cursor.position = Vector3((mouse.x / size.x - 0.5) * q.size.x, (0.5 - mouse.y / size.y) * q.size.y, 0.002)


## Screen-reading shaders that ask for a mipmapped screen texture (water,
## heat haze) make Godot 4.7 build the screen mip chain, which fails in
## multiview; they read the plain screen texture in the headset (see
## stereo_shader_code). New materials (fires, zones) appear later, so the scan
## repeats.
const SCREEN_MIP := "hint_screen_texture, filter_linear_mipmap"
const SCREEN_PLAIN := "hint_screen_texture, filter_linear"
var _patch_t := 0.0
var _patched := {}


func _patch_tick(dt: float) -> void:
	_patch_t -= dt
	if _patch_t > 0.0:
		return
	_patch_t = 3.0
	var count := 0
	for n in game.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		count += _patch_material(g.material_override)
		count += _patch_material(g.material_overlay)
		var mi := g as MeshInstance3D
		if mi and mi.mesh:
			for i in mi.get_surface_override_material_count():
				count += _patch_material(mi.get_surface_override_material(i))
			for i in mi.mesh.get_surface_count():
				count += _patch_material(mi.mesh.surface_get_material(i))
	if count:
		print("EIVR: %d shaders switched to their stereo version" % count)
	# Full-screen 2D passes that read the screen (GameData's gamma ramp) would
	# cover the interface picture with an opaque copy of the window; the panel
	# shows the interface only, so they are hidden while the headset is on.
	var hidden := 0
	for n in get_tree().root.find_children("*", "CanvasItem", true, false):
		var ci := n as CanvasItem
		if ci.visible and not _hidden_2d.has(ci) and _reads_screen(ci.material):
			ci.visible = false
			_hidden_2d.append(ci)
			hidden += 1
	if hidden:
		print("EIVR: hid %d screen-reading 2D passes" % hidden)


var _hidden_2d: Array[CanvasItem] = []


func _reads_screen(m: Material) -> bool:
	var sm := m as ShaderMaterial
	return sm != null and sm.shader != null and sm.shader.code.contains("hint_screen_texture")


func _show_2d_passes() -> void:
	for ci in _hidden_2d:
		if is_instance_valid(ci):
			ci.visible = true
	_hidden_2d.clear()


## Water reflections (Natural = screen-space, Mirror = one reflected camera)
## are a single flat picture laid over both eyes by screen position, so each
## eye sees the reflected scene (and the hero in it) in a different place. In
## the headset the water keeps only its sky reflection; the material values
## come back when the headset view is off.
var _water := {}   # ShaderMaterial -> [reflections, mirror]
var _water_shader := {}   # Shader -> has the water reflection switches


func _mute_water(sm: ShaderMaterial) -> void:
	if _water.has(sm):
		return
	if not _water_shader.has(sm.shader):
		_water_shader[sm.shader] = sm.shader.code.contains("uniform bool reflections")
	if not _water_shader[sm.shader]:
		return
	_water[sm] = [sm.get_shader_parameter("reflections"), sm.get_shader_parameter("mirror")]
	sm.set_shader_parameter("reflections", false)
	sm.set_shader_parameter("mirror", 0.0)


func _restore_water() -> void:
	for sm: ShaderMaterial in _water:
		if is_instance_valid(sm):
			sm.set_shader_parameter("reflections", _water[sm][0])
			sm.set_shader_parameter("mirror", _water[sm][1])
	_water.clear()


func _patch_material(m: Material) -> int:
	var sm := m as ShaderMaterial
	if sm == null or sm.shader == null:
		return 0
	_mute_water(sm)
	if _patched.has(sm.shader):
		return 0
	var code := sm.shader.code
	var vr := stereo_shader_code(code)
	if vr == code:
		_patched[sm.shader] = ""
		return 0
	_patched[sm.shader] = code
	sm.shader.code = vr
	return 1


## Puts back the flat code of every shader `stereo_shader_code` changed.
func _restore_shaders() -> void:
	for sh: Shader in _patched:
		if is_instance_valid(sh) and _patched[sh] != "":
			sh.code = _patched[sh]
	_patched.clear()


## The headset version of a game shader. In multiview the depth and screen
## textures hold one layer per eye: a `sampler2D` reads the first layer for
## both eyes, so the shore line (water depth), soft particles and torch
## halos sit in a different place in each eye. They become `sampler2DArray`
## read at the eye's layer. The water drops its screen-space reflection
## tracer (its own EI_NO_WATER_REFLECTIONS switch), whose helper functions
## cannot see VIEW_INDEX, and the screen mip chain, which multiview lacks.
static func stereo_shader_code(code: String) -> String:
	if not code.begins_with("shader_type spatial"):
		return code
	var out := code.replace(SCREEN_MIP, SCREEN_PLAIN)
	if out.contains("#ifndef EI_NO_WATER_REFLECTIONS") and not out.contains("#define EI_NO_WATER_REFLECTIONS"):
		out = out.replace("shader_type spatial;", "shader_type spatial;\n#define EI_NO_WATER_REFLECTIONS")
	if out.contains("uniform sampler2D depth_tex : hint_depth_texture"):
		out = out.replace("uniform sampler2D depth_tex : hint_depth_texture",
			"uniform sampler2DArray depth_tex : hint_depth_texture")
		# Water: the shore thickness helper gets the eye from fragment().
		out = out.replace("vec3 scene_pos(vec2 uv, mat4 inv_proj) {", "vec3 scene_pos(vec2 uv, mat4 inv_proj, uint ei_view) {")
		out = out.replace("textureLod(depth_tex, uv, 0.0)", "textureLod(depth_tex, vec3(uv, float(ei_view)), 0.0)")
		out = out.replace("scene_pos(SCREEN_UV, INV_PROJECTION_MATRIX)", "scene_pos(SCREEN_UV, INV_PROJECTION_MATRIX, VIEW_INDEX)")
		# Soft particles and halos read it directly in fragment().
		out = out.replace("texture(depth_tex, SCREEN_UV)", "texture(depth_tex, vec3(SCREEN_UV, float(VIEW_INDEX)))")
	return out


var _debug_t := 0.0
var _debug_file: FileAccess

## Prototype diagnostics, flushed so they survive a hang: user://eivr_debug.log.
func _debug_tick(dt: float) -> void:
	_debug_t -= dt
	if _debug_t > 0.0:
		return
	_debug_t = 2.0
	if _debug_file == null:
		_debug_file = FileAccess.open("user://eivr_debug.log", FileAccess.WRITE)
		if _debug_file == null:
			return
	var cur := xr_view.get_camera_3d()
	_debug_file.store_line("%.1f xr_view use_xr=%s current=%s size=%s panel=%s fps=%d" % [
		Time.get_ticks_msec() / 1000.0, xr_view.use_xr, cur.name if cur else "none",
		xr_view.size, panel.global_position, Engine.get_frames_per_second()])
	_debug_file.flush()


## The headset renders two 2.5k views at up to 120 Hz; SSAO, SSIL and
## volumetric fog of the flat High preset are too heavy for that. They are
## off while the headset view is on; the saved values come back after.
var _saved_envs := []


func _vr_environment(on: bool) -> void:
	if on:
		_saved_envs.clear()
		for n in game.find_children("*", "WorldEnvironment", true, false):
			var env := (n as WorldEnvironment).environment
			if env:
				_saved_envs.append([env, env.ssao_enabled, env.ssil_enabled, env.volumetric_fog_enabled])
				env.ssao_enabled = false
				env.ssil_enabled = false
				env.volumetric_fog_enabled = false
	else:
		for e: Array in _saved_envs:
			if is_instance_valid(e[0]):
				e[0].ssao_enabled = e[1]
				e[0].ssil_enabled = e[2]
				e[0].volumetric_fog_enabled = e[3]
		_saved_envs.clear()


func _set_vr_view(on: bool) -> void:
	vr_view = on
	var root := get_tree().root
	if on:
		_vr_environment(true)
		xr_view.world_3d = root.find_world_3d()
		xr_view.size = Vector2i(xr.get_render_target_size())
		xr_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		xr_view.use_xr = true
		camera.current = true
		# The window keeps only the interface, on a transparent background,
		# for the panel; the headset view draws the world.
		root.disable_3d = true
		root.transparent_bg = true
		(panel.material_override as StandardMaterial3D).albedo_texture = root.get_texture()
		panel.visible = true
		_need_recenter = true
		_patch_t = 0.0
	else:
		panel.visible = false
		(panel.material_override as StandardMaterial3D).albedo_texture = null
		root.disable_3d = false
		root.transparent_bg = false
		xr_view.use_xr = false
		xr_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_show_2d_passes()
		_restore_water()
		_restore_shaders()
		if is_instance_valid(game):
			_vr_environment(false)
	print("EIVR: headset view %s" % ("on" if on else "off"))

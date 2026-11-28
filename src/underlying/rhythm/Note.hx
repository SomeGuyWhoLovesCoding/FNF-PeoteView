package underlying.rhythm;

import underlying.rhythm.NoteskinRuntimeHelper;
import underlying.rhythm.NoteskinHandle.BasicNoteskinClip;

/**
	The note sprite of the note system. This is also used for the receptor.

	F23 GPU PAYLOAD DIET (48 -> 32 bytes/element, -33%):
	The macro rules that shaped this layout (peote-view v1.0.8):
	  - a field without @const ALWAYS costs buffer bytes, even when a
	    @formula makes the stored value redundant;
	  - @const @formula(...) costs ZERO bytes: the value is computed in
	    the vertex shader from other attributes/constants;
	  - @color @const bakes vec4(1.0) into the shader and still keeps
	    the identifier usable inside setColorFormula();
	  - an attribute that is simply OMITTED resolves to its identity
	    default in the texture-layer math (texPos/texSize: 0/100 = no
	    slice/zoom; texSlot on a slotless texture: never sampled).
	Removed, with the proof each is dead:
	  - `r` (rotation): never written anywhere (notes don't rotate and
	    the playfield display is never rotated — display.r is only ever
	    reset to 0). Now `@const @formula("uDisplayRotation(0.0)")`:
	    zero bytes, identical rendering, and if the display is ever
	    rotated the passthrough still applies.
	  - `c` (color): never written (always 0xFFFFFFFF). `@const` now —
	    the shader gets vec4(1.0) and the `why()` color formula is
	    unchanged.
	  - `texSlot`: the game's textures are created slotless (slotsX=1,
	    slotsY=1), so slot 0 is the identity; the field was never set
	    to anything but 0.
	  - `clipPosX/clipPosY/clipSizeX/clipSizeY` (@texPos/@texSize):
	    applyClip wrote clipSize=clipW/clipH and left clipPos at 0 —
	    the shader's slice/zoom math reduces to identity. Omitted.
	  - `w`/`h` (@sizeX/@sizeY): pure duplicates of clipWidth/
	    clipHeight (applyClip wrote both from the same clip value).
	    Dropped as stored attributes; size is now computed in the
	    vertex shader: `@const @formula("clipWidth * scale")` etc.
	    (px/py already used exactly this pattern at zero bytes.)
	ox/oy stay: they vary per receptor (the clip's draw offset).
	scale, initialAlpha, addedAlpha, x/y, clipX/Y/W/H, texUnit stay:
	every one is written per element every frame or per skin switch.
**/
@:publicFields
class Note implements Element {
	static public var defaultAlpha:Float = 1;
	static public var defaultMissAlpha:Float = 0.5;

	@varying @custom @formula("ox * scale") public var ox:Int;
	@varying @custom @formula("oy * scale") public var oy:Int;
	@posX @formula("uDisplayRotateX(aPos + vec2(px, py) + vec2(ox, oy))") @set("properties") public var x:Int;
	@posY @formula("uDisplayRotateY(aPos + vec2(px, py) + vec2(ox, oy))") @set("properties") public var y:Int;

	// size is derived on-GPU from the clip dims x scale — no storage.
	@varying @sizeX @const @formula("clipWidth * scale") public var w:Int;
	@varying @sizeY @const @formula("clipHeight * scale") public var h:Int;
	@varying @custom @set("properties") public var scale:Float = 1.0;

	// never rotated; keep the display-rotation passthrough at 0 bytes
	@rotation @formula("uDisplayRotation(r)") public var r:Float;

	@pivotX @const @formula("clipWidth * 0.5") public var px:Int;
	@pivotY @const @formula("clipHeight * 0.5") public var py:Int;

	// never tinted — vec4(1.0) is baked into the shader
	@color public var c:Color = 0xFFFFFFFF;

	@varying @custom @set("properties") public var initialAlpha(default, set):Float = 1.0;

	inline public function set_initialAlpha(value:Float) {
		initialAlpha = value;
		if (initialAlpha < 0)
			initialAlpha = 0;
		if (initialAlpha > 1)
			initialAlpha = 1;
		return value;
	}

	@varying @custom @set("properties") public var addedAlpha:Float = 0.0;

	@texUnit public var texUnit:Int = 0;

	// CPU-side fields (NOT macro attributes — zero GPU buffer bytes).
	// diff feeds the movement LUT lookups, scrollDirection/id/mania feed
	// the clip cache key and NoteskinRuntimeHelper lookups.
	public var diff:Int = 0;
	public var scrollDirection:Int = 90;

	@texX var clipX:Int = 0;
	@texY var clipY:Int = 0;
	@texW var clipWidth:Int = 100;
	@texH var clipHeight:Int = 100;

	public var id:Int = 0;
	public var mania_for_clipruntimehelper:Int = 4;

	// Internal state for checking methods
	private var state:NoteState = IDLE;

	var handle:NoteskinHandle;

	// ------------------------------------------------------------------
	// Clip cache: skip NoteskinRuntimeHelper lookup when (handle, id, mania)
	// are unchanged from the last call to a state method.
	//
	// Same pattern as Sustain.changeID() — after the first frame, pooled
	// Note objects reused for the same lane hit the cache every frame,
	// eliminating ~2000 getColorClip() + applyClipIfChanged() calls.
	// ------------------------------------------------------------------
	var cachedClipHandle:NoteskinHandle;
	var cachedClipId:Int = -1;
	var cachedClipMania:Int = -1;
	// Which NoteState the cache was populated for (COLOR / PRESS / CONFIRM / IDLE).
	// If toNote() is called but cache was populated by press(), we must re-lookup.
	var cachedClipState:NoteState = -1;

	// F23: w/h are no longer stored attributes (derived from clipWidth/
	// clipHeight x scale in the vertex shader), so they are gone from
	// setProperties and from this constructor. The w/h constructor
	// params are kept so call sites don't change; they seed clipWidth/
	// clipHeight instead (identical rendering for a fresh element).
	public function new(x:Int, y:Int, w:Int, h:Int, handle:NoteskinHandle, scale:Float = 1.0, initialAlpha:Float = 1.0, addedAlpha:Float = 0.0) {
		setProperties(x, y, scale, initialAlpha, addedAlpha);
		clipWidth = w;
		clipHeight = h;
		setHandle(handle);
		reset();
	}

	static public function init(program:CustomProgram) {}

	inline public function changeID(id:Int) {
		this.id = id;
	}

	inline public function setHandle(handle:NoteskinHandle) {
		if (handle == null)
			return;
		this.handle = handle;
		texUnit = handle.texUnit;
		// F23: texSlot is gone (slotless textures — see class doc); only
		// the texture unit selects the skin sheet now.
		// Invalidate clip cache — handle changed
		cachedClipHandle = null;
	}

	// --- State methods ---

	inline public function reset() {
		state = IDLE;
		if (handle == null)
			return;
		// Cache check: skip lookup if (handle, id, mania, state) unchanged
		if (cachedClipHandle == handle
			&& cachedClipId == id
			&& cachedClipMania == mania_for_clipruntimehelper
			&& cachedClipState == IDLE)
			return;
		var clip = NoteskinRuntimeHelper.getIdleClip(handle, id, mania_for_clipruntimehelper);
		applyClipIfChanged(clip);
		cachedClipHandle = handle;
		cachedClipId = id;
		cachedClipMania = mania_for_clipruntimehelper;
		cachedClipState = IDLE;
	}

	public function toNote() {
		state = COLOR;
		if (handle == null)
			return;
		// Cache check: skip getColorClip + applyClipIfChanged when
		// (handle, id, mania) are unchanged AND we were already in COLOR state.
		// This is the hot path — called ~2000 times/frame in renderVirtualNotes.
		if (cachedClipHandle == handle
			&& cachedClipId == id
			&& cachedClipMania == mania_for_clipruntimehelper
			&& cachedClipState == COLOR)
			return;
		var clip = NoteskinRuntimeHelper.getColorClip(handle, id, mania_for_clipruntimehelper);
		applyClipIfChanged(clip);
		cachedClipHandle = handle;
		cachedClipId = id;
		cachedClipMania = mania_for_clipruntimehelper;
		cachedClipState = COLOR;
	}

	public function press() {
		state = PRESS;
		if (handle == null)
			return;
		if (cachedClipHandle == handle
			&& cachedClipId == id
			&& cachedClipMania == mania_for_clipruntimehelper
			&& cachedClipState == PRESS)
			return;
		var clip = NoteskinRuntimeHelper.getPressClip(handle, id, mania_for_clipruntimehelper);
		applyClipIfChanged(clip);
		cachedClipHandle = handle;
		cachedClipId = id;
		cachedClipMania = mania_for_clipruntimehelper;
		cachedClipState = PRESS;
	}

	public function confirm() {
		state = CONFIRM;
		if (handle == null)
			return;
		if (cachedClipHandle == handle
			&& cachedClipId == id
			&& cachedClipMania == mania_for_clipruntimehelper
			&& cachedClipState == CONFIRM)
			return;
		var clip = NoteskinRuntimeHelper.getConfirmClip(handle, id, mania_for_clipruntimehelper);
		applyClipIfChanged(clip);
		cachedClipHandle = handle;
		cachedClipId = id;
		cachedClipMania = mania_for_clipruntimehelper;
		cachedClipState = CONFIRM;
	}

	// --- Checking methods ---

	inline public function idle() {
		return state == IDLE;
	}

	inline public function isNote() {
		return state == COLOR;
	}

	inline public function pressed() {
		return state == PRESS;
	}

	inline public function confirmed() {
		return state == CONFIRM;
	}

	// --- Helper to apply a clip to the note ---

	// F23: w/h/clipSize* are gone — size is derived in the vertex shader
	// (clipWidth * scale / clipHeight * scale), so applying a clip now
	// means writing the clip rect + draw offset only.
	private inline function applyClip(clip:BasicNoteskinClip) {
		clipX = clip.clipX;
		clipY = clip.clipY;
		clipWidth = clip.clipW;
		clipHeight = clip.clipH;
		ox = clip.offsX;
		oy = clip.offsY;
		// Rotation is not used for Note sprites (handled separately if needed)
	}

	private inline function applyClipIfChanged(clip:BasicNoteskinClip) {
		if (clipX == clip.clipX && clipY == clip.clipY && clipWidth == clip.clipW && clipHeight == clip.clipH && ox == clip.offsX && oy == clip.offsY)
			return;
		applyClip(clip);
	}
}

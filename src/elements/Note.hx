package elements;

import haxe.Int64;

import structures.notes.NoteskinRuntimeHelper;
import structures.notes.NoteskinHandle.BasicNoteskinClip;

/**
	The note sprite of the note system. This is also used for the receptor.
**/
@:publicFields
class Note implements Element {
	static public var defaultAlpha:Float = 1;
	static public var defaultMissAlpha:Float = 0.5;

	@varying @custom @formula("ox * scale") public var ox:Int;
	@varying @custom @formula("oy * scale") public var oy:Int;
	// Positions are sampled from the note-movement LUT on the GPU when
	// `aLutMode` is 1 (`uLutPos`), otherwise the CPU-written `aPos` is used
	// (receptors and the CPU fallback path).
	@posX @formula("uDisplayRotateX(uLutPos(aScrollBase, aLane, aLutMode, aPos, vec2(0.0, 0.0)) + vec2(px, py) + vec2(ox, oy))") @set("properties") public var x:Int;
	@posY @formula("uDisplayRotateY(uLutPos(aScrollBase, aLane, aLutMode, aPos, vec2(0.0, 0.0)) + vec2(px, py) + vec2(ox, oy))") @set("properties") public var y:Int;

	@varying @sizeX @formula("w * scale") @set("properties") public var w:Int = 100;
	@varying @sizeY @formula("h * scale") @set("properties") public var h:Int = 100;
	@varying @custom @set("properties") public var scale:Float = 1.0;

	@rotation @formula("uDisplayRotation(r)") public var r:Float;

	@pivotX @const @formula("w * 0.5") public var px:Int;
	@pivotY @const @formula("h * 0.5") public var py:Int;

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

	// --- Note-movement LUT binding ---
	// `aScrollBase` = the note's song time (ms), `aLane` = the allocated LUT
	// row for this note's (type,index), `aLutMode` = 1 when the GPU LUT is
	// active (0 otherwise). These are written once when the note spawns.
	@varying @custom @set("properties") public var aScrollBase:Float = 0.0;
	@varying @custom @set("properties") public var aLane:Float = 0.0;
	@varying @custom @set("properties") public var aLutMode:Float = 0.0;

	@texUnit public var texUnit:Int = 0;
	@texSlot public var texSlot:Int = 0;

	public var diff:Int = 0;
	public var scrollDirection:Int = 90;

	@texX var clipX:Int = 0;
	@texY var clipY:Int = 0;
	@texW var clipWidth:Int = 100;
	@texH var clipHeight:Int = 100;
	@texPosX var clipPosX:Int = 0;
	@texPosY var clipPosY:Int = 0;
	@texSizeX var clipSizeX:Int = 100;
	@texSizeY var clipSizeY:Int = 100;

	public var id:Int = 0;
	public var mania_for_clipruntimehelper:Int = 4;

	// Identifies which global note this buffer slot held last frame, so the
	// spawn-time constants (aScrollBase / aLane / aLutMode) are only written
	// once per note instead of every frame.
	public var lastWrittenGlobalIndex:Int64 = -1;

	// Internal state for checking methods
	private var state:NoteState = IDLE;

	var handle:NoteskinHandle;

	inline public function new(x:Int, y:Int, w:Int, h:Int, handle:NoteskinHandle, scale:Float = 1.0, initialAlpha:Float = 1.0, addedAlpha:Float = 0.0) {
		setProperties(x, y, w, h, scale, initialAlpha, addedAlpha);
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
		texSlot = handle.texSlot;
	}

	// --- State methods ---

	/** Returns true when the clip actually changed (buffer needs an update). */
	inline public function reset():Bool {
		state = IDLE;
		if (handle == null)
			return false;
		var clip = NoteskinRuntimeHelper.getIdleClip(handle, id, mania_for_clipruntimehelper);
		return applyClipIfChanged(clip);
	}

	/** Returns true when the clip actually changed (buffer needs an update). */
	inline public function toNote():Bool {
		state = COLOR;
		if (handle == null)
			return false;
		//BOTTLENECK: high per-note per-frame getColorClip lookup + applyClip (10 @set("properties") writes) dirty-flags every note for GPU re-upload; clip is lane-constant | FIX: cache clip per (handle, lane); skip re-derivation when state+id unchanged
		var clip = NoteskinRuntimeHelper.getColorClip(handle, id, mania_for_clipruntimehelper);
		return applyClipIfChanged(clip);
	}

	/** Returns true when the clip actually changed (buffer needs an update). */
	inline public function press():Bool {
		state = PRESS;
		if (handle == null)
			return false;
		var clip = NoteskinRuntimeHelper.getPressClip(handle, id, mania_for_clipruntimehelper);
		return applyClipIfChanged(clip);
	}

	/** Returns true when the clip actually changed (buffer needs an update). */
	inline public function confirm():Bool {
		state = CONFIRM;
		if (handle == null)
			return false;
		var clip = NoteskinRuntimeHelper.getConfirmClip(handle, id, mania_for_clipruntimehelper);
		return applyClipIfChanged(clip);
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

	private inline function applyClip(clip:BasicNoteskinClip) {
		clipX = clip.clipX;
		clipY = clip.clipY;
		w = clip.clipW;
		h = clip.clipH;
		clipWidth = clip.clipW;
		clipHeight = clip.clipH;
		clipSizeX = clip.clipW;
		clipSizeY = clip.clipH;
		ox = clip.offsX;
		oy = clip.offsY;
		// Rotation is not used for Note sprites (handled separately if needed)
	}

	private inline function applyClipIfChanged(clip:BasicNoteskinClip):Bool {
		if (clipX == clip.clipX && clipY == clip.clipY
			&& w == clip.clipW && h == clip.clipH
			&& clipWidth == clip.clipW && clipHeight == clip.clipH
			&& clipSizeX == clip.clipW && clipSizeY == clip.clipH
			&& ox == clip.offsX && oy == clip.offsY)
			return false;
		applyClip(clip);
		return true;
	}
}

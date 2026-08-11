package elements;

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
	@posX @formula("uDisplayRotateX(aPos + vec2(px, py) + vec2(ox, oy))") @set("properties") public var x:Int;
	@posY @formula("uDisplayRotateY(aPos + vec2(px, py) + vec2(ox, oy))") @set("properties") public var y:Int;

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

	inline public function reset() {
		state = IDLE;
		if (handle == null)
			return;
		var clip = NoteskinRuntimeHelper.getIdleClip(handle, id, mania_for_clipruntimehelper);
		applyClipIfChanged(clip);
	}

	inline public function toNote() {
		state = COLOR;
		if (handle == null)
			return;
		//BOTTLENECK: high per-note per-frame getColorClip lookup + applyClip (10 @set("properties") writes) dirty-flags every note for GPU re-upload; clip is lane-constant | FIX: cache clip per (handle, lane); skip re-derivation when state+id unchanged
		var clip = NoteskinRuntimeHelper.getColorClip(handle, id, mania_for_clipruntimehelper);
		applyClipIfChanged(clip);
	}

	inline public function press() {
		state = PRESS;
		if (handle == null)
			return;
		var clip = NoteskinRuntimeHelper.getPressClip(handle, id, mania_for_clipruntimehelper);
		applyClipIfChanged(clip);
	}

	inline public function confirm() {
		state = CONFIRM;
		if (handle == null)
			return;
		var clip = NoteskinRuntimeHelper.getConfirmClip(handle, id, mania_for_clipruntimehelper);
		applyClipIfChanged(clip);
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

	private inline function applyClipIfChanged(clip:BasicNoteskinClip) {
		if (clipX == clip.clipX && clipY == clip.clipY
			&& w == clip.clipW && h == clip.clipH
			&& clipWidth == clip.clipW && clipHeight == clip.clipH
			&& clipSizeX == clip.clipW && clipSizeY == clip.clipH
			&& ox == clip.offsX && oy == clip.offsY)
			return;
		applyClip(clip);
	}
}

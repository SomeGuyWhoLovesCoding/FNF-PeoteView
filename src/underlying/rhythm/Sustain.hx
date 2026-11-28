package underlying.rhythm;

/**
	The sustain note of the note sprite.

	Rewritten to accept two separate texture coordinates | `bodyCoord` (the
	"hold piece" region that tiles along the sustain length) and `tailCoord`
	(the "hold end" region drawn at the tip) | plus a texture rotation value
	(0 / 90 / 180 / 270) so any sustain texture can be rendered regardless
	of the angle it was exported at.

	## Texture coordinates

	Each rect is passed as four float varyings (x, y, w, h in texture pixels)
	and assembled into a `vec4` in the shader.

	## Rotation

	The rotation rotates the **texture sampling** (not the quad), so a
	horizontally-exported hold piece (wider than tall) can be tiled along a
	vertical sustain by passing `texRotation = 90`.

	## Coordinate system

	- `vTexCoord.x` runs along the sustain **length** (0 = start, 1 = tail end).
	- `vTexCoord.y` runs across the sustain **thickness** (0 = one edge, 1 = other).
	- The body tiles via `fract()` along the length; the tail occupies the
	  final portion at its native aspect ratio.

	## Tail aspect ratio

	The tail uses its **own** scale (`drawThick / tailThick`), independent of
	the body's scale. This ensures the tail never distorts when the sustain's
	thickness differs from the body's or tail's native thickness. When the
	tail doesn't fit in the sustain length, it is **cropped** at native scale
	rather than stretched.

	@since Development
**/
class Sustain implements Element {
	// ========================================================================
	// Position & Size
	// ========================================================================
	@posX @formula("uDisplayRotateX(aPos)") @set("properties") public var x:Int;
	@posY @formula("uDisplayRotateY(aPos)") @set("properties") public var y:Int;

	@varying @sizeX @formula("w * speed") @set("properties") public var w:Int;
	@varying @sizeY @formula("h * scale") @set("properties") public var h:Int;

	@rotation @formula("uDisplayRotation(r)") @set("properties") public var r:Float;
	@pivotY @const @formula("h * 0.5") public var py:Int;

	@color public var c:Color = 0xFFFFFFFF;

	@varying @custom @set("properties") public var speed:Float = 1.0;
	@varying @custom @set("properties") public var scale:Float = 1.0;

	/**
		Multi-texture slot selectors (same as Note). `texUnit` is this
		sustain's skin's index into `NoteskinManager.textureCache`;
		`texSlot` is always 0.

		Updated by `setHandle(handle)` so the sustain starts sampling
		from the new skin's sheet the moment the strumline switches
		handles — no shader re-injection needed.
	**/
	@texUnit public var texUnit:Int = 0;

	// F23: texSlot dropped — the game's textures are created slotless
	// (slotsX=1, slotsY=1), so slot 0 is the identity and the field was
	// never anything but 0.

	// ========================================================================
	// Texture Coordinates (body = "hold piece", tail = "hold end")
	// ========================================================================
	// F23: all nine fields are Int now. Every writer stores integer pixel
	// coordinates (BasicNoteskinClip.clipX..clipH are Int) or one of
	// 0/90/180/270 (TextureRotation.toDegrees():Int) — the Float
	// declarations were paying 4 bytes each for values that fit a short.
	// Int-declared @custom fields pack as 2-byte shorts in the buffer
	// (same mechanism as Note's clipX/Y/W/H); the vertex shader
	// promotes them to float varyings, so vec4(bodyX, bodyY, bodyW,
	// bodyH) and the slice() shader are byte-identical in behavior.
	// 9 fields x 2 bytes = 18 bytes/sustain saved.
	// Body texture rect in pixels: (x, y, w, h).
	@varying @custom @set("properties") public var bodyX:Int = 0;
	@varying @custom @set("properties") public var bodyY:Int = 0;
	@varying @custom @set("properties") public var bodyW:Int = 0;
	@varying @custom @set("properties") public var bodyH:Int = 0;

	// Tail texture rect in pixels: (x, y, w, h).
	@varying @custom @set("properties") public var tailX:Int = 0;
	@varying @custom @set("properties") public var tailY:Int = 0;
	@varying @custom @set("properties") public var tailW:Int = 0;
	@varying @custom @set("properties") public var tailH:Int = 0;

	// Texture rotation in degrees: 0, 90, 180, or 270.
	@varying @custom @set("properties") public var texRotation:Int = 0;

	// F23: invTileWidth/invTileHeight are GONE as element fields. The
	// slice() shader always used the literals baked at injection time
	// (1.0/texture.width, 1.0/texture.height — the function PARAMETERS
	// shadowed these varyings, so the per-element values were never
	// sampled). setProgramsSustainShader now passes the literals
	// directly in the color formula. 8 bytes/sustain saved.

	// ========================================================================
	// State
	// ========================================================================
	static public var defaultAlpha:Float = 0.6;
	static public var defaultMissAlpha:Float = 0.3;

	public var length:Int;
	public var diff:Int = 0;
	public var scrollDirection:Int = 90;
	public var parent:Note;

	// Per-clip lookup tables, populated externally.
	// Each entry: [bodyX, bodyY, bodyW, bodyH, tailX, tailY, tailW, tailH].
	static public var holdCoords:Array<Array<Float>> = [];
	static public var rotations:Array<Int> = [];

	public var mania_for_clipruntimehelper:Int = 4;

	public var handle:NoteskinHandle; // new

	var cachedClipHandle:NoteskinHandle;
	var cachedClipId:Int = -1;
	var cachedClipMania:Int = -1;

	static public function init(program:CustomProgram) {}

	inline public function new(x:Int, y:Int, w:Int, h:Int, handle:NoteskinHandle, r:Float, s:Float, sc:Float, tile:Int) {
		this.handle = handle;
		setProperties(x, y, w, h, r, s, sc, 0, 36, 20, 36, 40, 36, 20, 36, 0);
		setHandle(handle);
	}

	/**
		Propagate `texUnit` from a noteskin handle to this sustain.
		Called from the constructor and from `Strumline.set_noteskinHandle`
		whenever the active skin changes.

		After this call, the sustain's `@texUnit` attribute points at the
		new skin's slot in `NoteskinManager.textureCache`, so the shader
		will sample from that skin's sheet on the next draw.

		If `handle` is null, this is a no-op.
	**/
	inline public function setHandle(handle:NoteskinHandle) {
		if (handle == null)
			return;
		this.handle = handle;
		texUnit = handle.texUnit;
		// F23: texSlot dropped (slotless textures) and invTileWidth/
		// invTileHeight dropped (the shader bakes the literals — the
		// per-element values were never sampled, see class doc).
	}

	/**
		Set the body/tail coords and rotation from the helper for this lane.
	**/
	inline public function changeID(id:Int) {
		//BOTTLENECK: high per-sustain per-frame changeID does 2 clip lookups + ~10 @set("properties") writes, re-uploading every sustain's clip coords each frame | FIX: cache body/tail clip per lane; only set fields when changed
		if (cachedClipHandle == handle && cachedClipId == id && cachedClipMania == mania_for_clipruntimehelper)
			return;
		var bodyClip = NoteskinRuntimeHelper.getHoldBodyClip(handle, id, mania_for_clipruntimehelper);
		var tailClip = NoteskinRuntimeHelper.getHoldTailClip(handle, id, mania_for_clipruntimehelper);

		bodyX = bodyClip.clipX;
		bodyY = bodyClip.clipY;
		bodyW = bodyClip.clipW;
		bodyH = bodyClip.clipH;

		tailX = tailClip.clipX;
		tailY = tailClip.clipY;
		tailW = tailClip.clipW;
		tailH = tailClip.clipH;

		h = bodyH; // F23: bodyH is Int now — no rounding needed

		texRotation = bodyClip.rotation.toDegrees();

		cachedClipHandle = handle;
		cachedClipId = id;
		cachedClipMania = mania_for_clipruntimehelper;
	}
}

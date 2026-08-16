package rhythm;

import haxe.Json;
import sys.io.File;
import sys.FileSystem;
import tooling.TextureSystem;

/**
	Noteskin handle class.

	Each mania config now carries per-clip-type indexes so that
	idle, press, color, confirm, holdBody and holdTail can each
	reference independent clip slots.

	## Multi-texture architecture

	This handle does NOT own a `Texture` directly — the `Texture`
	lives in `TextureSystem.pool` under a per-skin key
	(`'noteskin_<skinName>'` — keyed by FOLDER NAME, not `data.name`,
	so folders with colliding `data.name` values don't share a pool
	entry) AND is registered in the shared
	`NoteskinManager.textureCache` (an `Array<Texture>`). The handle
	stores:
	  - `textureKey`: the string key into `TextureSystem.pool`
	  - `texture`:    a cached reference to the `Texture` (so callers
					  can read `texture.width` / `texture.height`)
	  - `texUnit`:    this skin's index into `NoteskinManager.textureCache`
					  (used as the per-element `@texUnit` value on
					  Note / Sustain elements so they sample from THIS
					  skin's slot of the multi-texture)
	  - `texSlot`:    always `0` (each skin occupies a single slot —
					  no sub-packing)

	`loadTexture()` calls `TextureSystem.createTexture(textureKey,
	sheetPath, false, true)` (premultiply = true). The actual file IO
	and alpha-premultiplication happen inside TextureSystem — no lime
	`Image` is touched in this class.

	`setProgramsTexture()` calls `program.setMultiTexture(
	NoteskinManager.textureCache, identifier)` to bind ALL cached
	skin textures to the program at once. Each Note / Sustain element
	then carries `@texUnit` / `@texSlot` attributes that tell the
	shader which slot to sample from. Switching noteskins is therefore
	just a matter of updating each element's `@texUnit` / `@texSlot`
	via `setHandle()` — no `setTexture` re-binding or shader
	re-injection required on a switch.

	`dispose()` clears the cached `texture` reference but does NOT
	call `TextureSystem.disposeTexture()` — the GPU memory stays
	allocated so the skin can be re-bound quickly on a switch.

	## Default data fallback

	If `data.json` is missing or fails to parse, the constructor falls
	back to the in-memory `DEFAULT_DATA` template (a deep copy, so it is
	safe to mutate the resulting `data` field).
**/
@:publicFields
class NoteskinHandle {
	/**
		The skin's folder name (the leaf directory name under
		`assets/images/noteskins/`). Set in the constructor and used as
		the unique identifier for this skin across the manager.

		⚠ This is the FOLDER NAME, not `data.name`. Two different folders
		can have a `data.json` whose `name` field collides (e.g. both
		say `"default"` because the user duplicated a folder, or because
		a folder is missing `data.json` and the constructor fell back to
		`DEFAULT_DATA` which has `name = "default"`). The folder name is
		guaranteed unique by the filesystem, so it's the only safe key
		for `textureKey` and for `NoteskinManager.currentLoadedNoteskins`.
	**/
	var skinName:String = "";

	var textureKey:String = "";

	var texture:Texture = null;

	var texUnit:Int = 0;

	var texSlot:Int = 0;

	var loaded:Bool = false;

	var mania:Int = 1;

	var data:NoteskinData;
	var folder:String = "";

	/**
		In-memory default noteskin data template.
		Mirrors the on-disk `data.json` that `NoteskinEditor.createDefaultDataJson()`
		writes, so any code path that needs a "default noteskin" can fall back to
		this without touching the filesystem.

		⚠ SHARED TEMPLATE — do NOT mutate this directly. Call `defaultData()` to
		get a fresh deep copy that you can safely modify.
	**/
	static var DEFAULT_DATA:NoteskinData = {
		name: "default",
		sparrowImg: "sheet.png",
		configMania: [
			{
				offsetX: 0,
				offsetY: 0,
				gap: 112,
				scale: 1.0,
				idleIndexes: [0, 1, 2, 3],
				pressIndexes: [0, 1, 2, 3],
				colorIndexes: [0, 1, 2, 3],
				confirmIndexes: [0, 1, 2, 3],
				holdBodyIndexes: [0, 1, 2, 3],
				holdTailIndexes: [0, 1, 2, 3]
			}
		],
		clip: [
			{
				idle: {
					clipX: 436,
					clipY: 301,
					clipW: 109,
					clipH: 111,
					offsX: 0,
					offsY: 0
				},
				press: {
					clipX: 546,
					clipY: 301,
					clipW: 99,
					clipH: 100,
					offsX: 0,
					offsY: 0
				},
				color: {
					clipX: 226,
					clipY: 384,
					clipW: 108,
					clipH: 110,
					offsX: 0,
					offsY: 0
				},
				confirm: {
					clipX: 1,
					clipY: 1,
					clipW: 240,
					clipH: 243,
					offsX: 0,
					offsY: 0
				},
				holdBody: {
					clipX: 145,
					clipY: 467,
					clipW: 35,
					clipH: 31,
					offsX: 0,
					offsY: 0
				},
				holdTail: {
					clipX: 73,
					clipY: 467,
					clipW: 35,
					clipH: 45,
					offsX: 0,
					offsY: 0
				}
			},
			{
				idle: {
					clipX: 114,
					clipY: 357,
					clipW: 111,
					clipH: 109,
					offsX: 0,
					offsY: 0
				},
				press: {
					clipX: 548,
					clipY: 191,
					clipW: 99,
					clipH: 98,
					offsX: 0,
					offsY: 0
				},
				color: {
					clipX: 1,
					clipY: 245,
					clipW: 112,
					clipH: 110,
					offsX: 0,
					offsY: 0
				},
				confirm: {
					clipX: 242,
					clipY: 1,
					clipW: 191,
					clipH: 192,
					offsX: 0,
					offsY: 0
				},
				holdBody: {
					clipX: 181,
					clipY: 467,
					clipW: 35,
					clipH: 30,
					offsX: 0,
					offsY: 0
				},
				holdTail: {
					clipX: 1,
					clipY: 467,
					clipW: 35,
					clipH: 45,
					offsX: 0,
					offsY: 0
				}
			},
			{
				idle: {
					clipX: 436,
					clipY: 191,
					clipW: 111,
					clipH: 109,
					offsX: 0,
					offsY: 0
				},
				press: {
					clipX: 444,
					clipY: 413,
					clipW: 101,
					clipH: 99,
					offsX: 0,
					offsY: 0
				},
				color: {
					clipX: 1,
					clipY: 356,
					clipW: 112,
					clipH: 110,
					offsX: 0,
					offsY: 0
				},
				confirm: {
					clipX: 242,
					clipY: 194,
					clipW: 193,
					clipH: 189,
					offsX: 0,
					offsY: 0
				},
				holdBody: {
					clipX: 217,
					clipY: 495,
					clipW: 35,
					clipH: 30,
					offsX: 0,
					offsY: 0
				},
				holdTail: {
					clipX: 37,
					clipY: 467,
					clipW: 35,
					clipH: 45,
					offsX: 0,
					offsY: 0
				}
			},
			{
				idle: {
					clipX: 114,
					clipY: 245,
					clipW: 110,
					clipH: 111,
					offsX: 0,
					offsY: 0
				},
				press: {
					clipX: 546,
					clipY: 402,
					clipW: 97,
					clipH: 99,
					offsX: 0,
					offsY: 0
				},
				color: {
					clipX: 335,
					clipY: 413,
					clipW: 108,
					clipH: 110,
					offsX: 0,
					offsY: 0
				},
				confirm: {
					clipX: 434,
					clipY: 1,
					clipW: 189,
					clipH: 189,
					offsX: 0,
					offsY: 0
				},
				holdBody: {
					clipX: 181,
					clipY: 498,
					clipW: 35,
					clipH: 30,
					offsX: 0,
					offsY: 0
				},
				holdTail: {
					clipX: 109,
					clipY: 467,
					clipW: 35,
					clipH: 45,
					offsX: 0,
					offsY: 0
				}
			}
		]
	};

	/**
		Returns a fresh deep copy of `DEFAULT_DATA`.
		Use this whenever the caller may mutate the resulting `NoteskinData`
		(e.g. when using it as a fallback inside `new()`).
	**/
	static function defaultData():NoteskinData {
		var src = DEFAULT_DATA;
		return {
			name: src.name,
			sparrowImg: src.sparrowImg,
			configMania: [
				for (cfg in src.configMania)
					{
						offsetX: cfg.offsetX,
						offsetY: cfg.offsetY,
						gap: cfg.gap,
						scale: cfg.scale,
						idleIndexes: cfg.idleIndexes.copy(),
						pressIndexes: cfg.pressIndexes.copy(),
						colorIndexes: cfg.colorIndexes.copy(),
						confirmIndexes: cfg.confirmIndexes.copy(),
						holdBodyIndexes: cfg.holdBodyIndexes.copy(),
						holdTailIndexes: cfg.holdTailIndexes.copy()
					}
			],
			clip: [
				for (c in src.clip)
					{
						idle: cloneClip(c.idle),
						press: cloneClip(c.press),
						color: cloneClip(c.color),
						confirm: cloneClip(c.confirm),
						holdBody: cloneClip(c.holdBody),
						holdTail: cloneClip(c.holdTail)
					}
			]
		};
	}

	/** Deep-copy a single `BasicNoteskinClip`. */
	static inline function cloneClip(c:BasicNoteskinClip):BasicNoteskinClip {
		return {
			clipX: c.clipX,
			clipY: c.clipY,
			clipW: c.clipW,
			clipH: c.clipH,
			offsX: c.offsX,
			offsY: c.offsY,
			rotation: c.rotation
		};
	}

	function new(skin:String) {
		skinName = skin;
		folder = 'assets/images/noteskins/$skin';
		var path = Paths.asset('$folder/data.json');

		//BOTTLENECK: low synchronous File.getContent + Json.parse on main thread for every skin load (constructor) — NoteskinManager.init loads up to 15 skins and each editor skin-switch blocks here | FIX: pre-parse + cache data once, background-load new skins
		var rawData:Dynamic = null;
		try {
			var content = File.getContent(path);
			rawData = Json.parse(content);
		} catch (e) {
			// data.json is missing or unparseable — fall back to the in-memory
			// DEFAULT_DATA template (deep-copied so callers can mutate safely).
			trace('NoteskinHandle: failed to load data.json at "$path" ($e); falling back to DEFAULT_DATA');
			data = defaultData();
			return;
		}

		// --- Parse clips ---
		var rawClips:Array<Dynamic> = rawData.clip;
		var clips:Array<NoteskinReceptorProperties> = [];

		if (rawClips != null) {
			for (rawClip in rawClips) {
				clips.push({
					idle: parseClip(rawClip.idle),
					press: parseClip(rawClip.press),
					color: parseClip(rawClip.color),
					confirm: parseClip(rawClip.confirm),
					holdBody: parseClip(rawClip.holdBody),
					holdTail: parseClip(rawClip.holdTail)
				});
			}
		}

		// --- Parse configs ---
		var rawConfigMania:Array<Dynamic> = rawData.configMania;
		var configs:Array<NoteskinConfig> = [];

		if (rawConfigMania != null) {
			for (rawConfig in rawConfigMania) {
				configs.push(parseConfig(rawConfig));
			}
		}

		data = {
			name: rawData.name != null ? rawData.name : "default",
			sparrowImg: rawData.sparrowImg != null ? rawData.sparrowImg : "notes.png",
			configMania: configs,
			clip: clips
		};
	}

	/**
		Create this skin's sheet texture in `TextureSystem.pool` AND
		register it in `NoteskinManager.textureCache`.

		Steps:
		  1. `TextureSystem.createTexture(textureKey, sheetPath, false, true)`
			 — creates the GPU texture (handles file IO + alpha
			 premultiplication internally; no lime `Image` touched here).
		  2. `TextureSystem.getTexture(textureKey)` — caches the `Texture`
			 reference on this handle so callers can read `.width` / `.height`.
		  3. `NoteskinManager.registerTexture(texture)` — appends the
			 `Texture` to the shared `textureCache` array and assigns
			 this handle's `texUnit` to its index in that array. The
			 `texSlot` stays at `0` (one Texture per unit, no sub-packing).

		After this call:
		  - `textureKey` is `'noteskin_<skinName>'` (folder-name-based —
			unique per skin folder even if `data.name` collides)
		  - `texture` is the `Texture` from `TextureSystem.pool` (or null
			if the sheet file doesn't exist or `createTexture` failed)
		  - `texUnit` is this skin's index in `NoteskinManager.textureCache`
		  - `texSlot` is `0`
		  - `loaded` is true iff `texture != null`

		Idempotent: re-calling on an already-loaded handle is a no-op
		(the texture stays in the pool and the cache; `texUnit` is
		preserved).

		If the sheet file doesn't exist, a warning is traced and the
		handle stays unloaded. The handle is still usable for data
		lookups (clip coordinates, mania configs) but elements rendered
		with a null texture will sample garbage — the failure is
		visually obvious.
	**/
	function loadTexture():Void {
		if (loaded)
			return;

		var sheetPath = Paths.asset('$folder/${data.sparrowImg}');
		if (!FileSystem.exists(sheetPath)) {
			trace('NoteskinHandle: sheet texture not found at "$sheetPath" for skin "$skinName" (data.name="${data.name}")');
			return;
		}

		textureKey = 'noteskin_${skinName}';

		TextureSystem.createTexture(textureKey, sheetPath, false, true);

		// Fetch the Texture reference so callers can read .width/.height.
		texture = TextureSystem.getTexture(textureKey);
		if (texture == null) {
			trace('NoteskinHandle: TextureSystem.createTexture failed for skin "$skinName" (key=$textureKey)');
			return;
		}

		texUnit = NoteskinManager.registerTexture(texture);
		texSlot = 0;

		loaded = true;
		trace('NoteskinHandle: loaded skin "$skinName" (data.name="${data.name}") sheet (${texture.width}x${texture.height}) '
			+ 'into TextureSystem.pool["$textureKey"] and NoteskinManager.textureCache[$texUnit]');
	}

	/**
		Bind the shared `NoteskinManager.textureCache` to a `CustomProgram`
		as a multi-texture under the given identifier (defaults to
		`"noteTexV2"`).

		Calls `program.setMultiTexture(NoteskinManager.textureCache, identifier)`
		— peote-view binds every `Texture` in the array as a separate
		sampler, and auto-generates the `<identifier>_ID` uniform that the
		injected fragment shaders reference. Each Note / Sustain element's
		`@texUnit` / `@texSlot` attributes then select which slot to
		sample from at draw time.

		This MUST be called once at program creation time (in the editor's
		`initRendering`). It does NOT need to be re-called on a noteskin
		switch — switching is handled by updating each element's
		`@texUnit` / `@texSlot` via `setHandle()`.

		The identifier is REQUIRED for `setProgramsNoteShader()` and
		`setProgramsSustainShader()` because both shader fragments
		reference the auto-generated `<identifier>_ID` uniform.
	**/
	function setProgramsTexture(program:CustomProgram, identifier:String = "noteTexV2") {
		if (NoteskinManager.textureCache == null || NoteskinManager.textureCache.length == 0) {
			trace('NoteskinHandle.setProgramsTexture: NoteskinManager.textureCache is empty — skipping');
			return;
		}
		program.setMultiTexture(NoteskinManager.textureCache, identifier);
	}

	function setProgramsNoteShader(program:CustomProgram) {
		program.injectIntoFragmentShader('
			vec4 why(int textureID, float initialAlpha, float addedAlpha)
			{
				vec4 tex = getTextureColor(textureID, vTexCoord);
				if (tex.a == 0.0) return tex;
				float newA = clamp(tex.a * initialAlpha + addedAlpha, 0.0, 1.0);
				return vec4(tex.rgb * (newA / tex.a), newA);
			}
		');
		program.setColorFormula('c * why(noteTexV2_ID, initialAlpha, addedAlpha)');
	}

	/**
		Inject the sustain tiling/rotation shader into a program.

		## Baked texture dimensions (multi-texture caveat)

		The shader bakes `1.0/texture.width` and `1.0/texture.height` as
		float literals (via `Util.toFloatString`) at injection time,
		using THIS handle's texture dimensions. With multi-texture
		(different skins can have different sheet dimensions), the
		baked literals are only CORRECT for sustains whose `@texUnit`
		matches this handle's `texUnit`.

		In practice this means: the sustain preview is accurate for the
		skin that was active when `initRendering()` first injected the
		shader. Switching to a different-sized skin will render sustains
		with slightly wrong UV scaling (note rendering is unaffected —
		it uses `vTexCoord` directly, not the baked literals).

		To make this fully correct for multi-texture, the shader would
		need per-element `invTexW` / `invTexH` varyings on `Sustain`.
		That's deliberately NOT done here per the user's instruction
		("I didn't mean add the invTexW/H to Sustain.hx. Undo that —
		I already got it").

		## Why not re-inject on switch?

		Because the sustain program is bound to a multi-texture array
		(`setMultiTexture` in `initRendering`), the program itself
		doesn't change on a skin switch — only each Sustain element's
		`@texUnit` / `@texSlot` change. Re-injecting the shader on
		every switch would recompile the fragment shader (slow) and
		still wouldn't fix the per-element dimension mismatch (would
		just shift it to whichever skin was switched to). So we
		inject ONCE at program creation and accept the caveat above.
	**/
	function setProgramsSustainShader(program:CustomProgram) {
		if (texture == null) {
			trace('NoteskinHandle.setProgramsSustainShader: texture is null for "${data.name}" — skipping');
			return;
		}

		var invTileW = Util.toFloatString(1.0 / texture.width);
		var invTileH = Util.toFloatString(1.0 / texture.height);

		program.injectIntoFragmentShader('
			// --- Rotation helper ---
			// Rotates a [0,1] UV by 0 / 90 / 180 / 270 degrees.
			// Uses range checks instead of == because texRotation is a
			// @varying float | interpolation between vertices can introduce
			// tiny precision drift (e.g. 89.9998) that breaks exact compares.
			vec2 sustainRotateUV(vec2 uv, float rot) {
				rot = mod(rot + 360.0, 360.0);
				if (rot > 45.0 && rot < 135.0)       return vec2(uv.y, 1.0 - uv.x);
				if (rot >= 135.0 && rot < 225.0)     return vec2(1.0 - uv.x, 1.0 - uv.y);
				if (rot >= 225.0 && rot < 315.0)     return vec2(1.0 - uv.y, uv.x);
				return uv;
			}

			bool sustainIsSwapped(float rot) {
				rot = mod(rot + 360.0, 360.0);
				return (rot > 45.0 && rot < 135.0) || (rot >= 225.0 && rot < 315.0);
			}

			vec4 slice(int textureID, vec4 bodyCoord, vec4 tailCoord, float texRotation, float invTileW, float invTileH) {
				vec2 coord = vTexCoord;

				// After rotation, the length-axis and thickness-axis may swap.
				// For 0 / 180 the rect\'s width (z) is along the sustain length
				// and height (w) is across the thickness. For 90 / 270 they swap.
				bool swapped = sustainIsSwapped(texRotation);

				float bodyLen   = swapped ? bodyCoord.w : bodyCoord.z;
				float bodyThick = swapped ? bodyCoord.z : bodyCoord.w;
				float tailLen   = swapped ? tailCoord.w : tailCoord.z;
				float tailThick = swapped ? tailCoord.z : tailCoord.w;

				float drawLen   = vSize.x;  // sustain length (drawn)
				float drawThick = vSize.y;  // sustain thickness (drawn)

				// Body scale | used ONLY for body tiling.
				float bodyPxScale = drawThick / max(bodyThick, 0.001);
				float bodyDrawLen = bodyLen * bodyPxScale;

				// Tail scale | uses the TAIL\'s own thickness, NOT the body\'s.
				// This preserves the tail\'s native aspect ratio regardless of
				// how the body\'s thickness compares. Without this, when the
				// sustain\'s thickness drops below the tail\'s native thickness,
				// the tail\'s length and thickness scales diverge and the tail
				// appears stretched along its length.
				float tailPxScale = drawThick / max(tailThick, 0.001);
				float tailDrawLen = tailLen * tailPxScale;

				vec2 localCoord;
				vec4 rect;

				if (tailDrawLen >= drawLen) {
					// --- Tail doesn\'t fit (or exactly fits) ---
					// Render ONLY the tail, CROPPED to the sustain length.
					// The tail texture is sampled at its NATIVE scale | we
					// show only the fraction that fits, not stretched.
					// This prevents the tail from disappearing when the
					// sustain is too short (which happened because UVs were
					// being compressed beyond the texture bounds).
					float visibleFrac = drawLen / max(tailDrawLen, 0.001);
					visibleFrac = min(visibleFrac, 1.0);
					// Show the TIP of the tail (the end cap), which is the
					// visible portion at the sustain\'s end.
					localCoord = vec2(1.0 - visibleFrac + coord.x * visibleFrac, coord.y);
					rect = tailCoord;
				} else {
					// --- Normal: body fills [0, tailStart], tail fills [tailStart, 1] ---
					float tailStart = 1.0 - (tailDrawLen / max(drawLen, 0.001));

					if (coord.x > tailStart) {
						// Tail region | remap coord.x from [tailStart, 1] to [0, 1]
						// so the tail texture spans its full length within this region.
						localCoord = vec2(
							(coord.x - tailStart) / max(1.0 - tailStart, 0.001),
							coord.y
						);
						rect = tailCoord;
					} else {
						// Body region - tile along the length using fract().
						// Map [0, tailStart] -> [N, 0] so tailStart always
						// lands on a tile boundary (fract = 0), matching the
						// old shader\'s (1.0 - coord.x / tail.x) approach.
						float numTiles = tailStart * drawLen / max(bodyDrawLen, 0.001);
						float tiledX = fract((1.0 - coord.x / max(tailStart, 0.001)) * numTiles);
						localCoord = vec2(tiledX, coord.y);
						rect = bodyCoord;
					}
				}

				// Rotate the local coord within [0,1], then map to
				// full-texture UV space using the rect\'s pixel position+size.
				// invTileW / invTileH are baked as float literals at shader
				// injection time (1.0/texture.width, 1.0/texture.height).
				vec2 rotated = sustainRotateUV(localCoord, texRotation);
				vec2 uv = (rect.xy + rotated * rect.zw) * vec2(invTileW, invTileH);

				// Clamp to [0,1] to prevent out-of-bounds sampling when
				// coords are near texture edges (which made the tail disappear).
				uv = clamp(uv, vec2(0.0), vec2(1.0));

				return getTextureColor(textureID, uv);
			}
		');

		program.setColorFormula('c * slice(noteTexV2_ID, vec4(bodyX, bodyY, bodyW, bodyH), vec4(tailX, tailY, tailW, tailH), texRotation, invTileWidth, invTileHeight)');
	}

	/**
		Dispose this handle's reference to its texture.

		Clears `texture`, `textureKey`, `texUnit`, `texSlot`, and
		`loaded`. Does NOT call `TextureSystem.disposeTexture()` —
		the GPU memory stays allocated so the skin can be re-bound
		quickly on a switch.

		Safe to call multiple times. Safe to call on a handle that was
		never loaded.
	**/
	function dispose() {
		// Just clear our references — TextureSystem.pool and
		// NoteskinManager.textureCache still own the Texture. The
		// manager's disposeAll() is responsible for actually freeing
		// GPU memory via TextureSystem.disposeTexture + clearing the
		// textureCache array.
		loaded = false;
		texture = null;
		textureKey = "";
		texUnit = 0;
		texSlot = 0;
	}

	// --- Getters for clip data by index ---

	inline function getClip(index:Int):NoteskinReceptorProperties {
		if (data.clip != null && index >= 0 && index < data.clip.length) {
			return data.clip[index];
		}
		return defaultClip();
	}

	inline function getClipState(index:Int, state:Int):BasicNoteskinClip {
		var clip = getClip(index);
		return switch (state) {
			case 0: clip.idle;
			case 1: clip.color;
			case 2: clip.press;
			case 3: clip.confirm;
			case 4: clip.holdBody;
			case 5: clip.holdTail;
			default: clip.idle;
		};
	}

	static inline function getIndexesForState(config:NoteskinConfig, state:Int):Array<Int> {
		return switch (state) {
			case 0: config.idleIndexes;
			case 1: config.colorIndexes;
			case 2: config.pressIndexes;
			case 3: config.confirmIndexes;
			case 4: config.holdBodyIndexes;
			case 5: config.holdTailIndexes;
			default: config.idleIndexes;
		};
	}

	static function parseClip(raw:Dynamic):BasicNoteskinClip {
		return {
			clipX: raw.clipX,
			clipY: raw.clipY,
			clipW: raw.clipW,
			clipH: raw.clipH,
			offsX: raw.offsX,
			offsY: raw.offsY,
			rotation: TextureRotation.parse(raw.rotation)
		};
	}

	static function parseConfig(raw:Dynamic):NoteskinConfig {
		var oldIndexes:Array<Int> = raw.indexes;
		var hasOld = oldIndexes != null && oldIndexes.length > 0;

		return {
			offsetX: raw.offsetX != null ? raw.offsetX : 0,
			offsetY: raw.offsetY != null ? raw.offsetY : 0,
			gap: raw.gap != null ? raw.gap : 112,
			scale: raw.scale != null ? raw.scale : 1.0,
			idleIndexes: raw.idleIndexes != null ? raw.idleIndexes : [],
			pressIndexes: raw.pressIndexes != null ? raw.pressIndexes : [],
			colorIndexes: raw.colorIndexes != null ? raw.colorIndexes : [],
			confirmIndexes: raw.confirmIndexes != null ? raw.confirmIndexes : [],
			holdBodyIndexes: raw.holdBodyIndexes != null ? raw.holdBodyIndexes : [],
			holdTailIndexes: raw.holdTailIndexes != null ? raw.holdTailIndexes : []
		};
	}

	/** Shared default receptor properties. */
	static function defaultClip():NoteskinReceptorProperties {
		return {
			idle: {
				clipX: 0,
				clipY: 0,
				clipW: 100,
				clipH: 100,
				offsX: 0,
				offsY: 0
			},
			press: {
				clipX: 0,
				clipY: 0,
				clipW: 100,
				clipH: 100,
				offsX: 0,
				offsY: 0
			},
			color: {
				clipX: 0,
				clipY: 0,
				clipW: 100,
				clipH: 100,
				offsX: 0,
				offsY: 0
			},
			confirm: {
				clipX: 0,
				clipY: 0,
				clipW: 100,
				clipH: 100,
				offsX: 0,
				offsY: 0
			},
			holdBody: {
				clipX: 0,
				clipY: 0,
				clipW: 35,
				clipH: 31,
				offsX: 0,
				offsY: 0
			},
			holdTail: {
				clipX: 0,
				clipY: 0,
				clipW: 35,
				clipH: 45,
				offsX: 0,
				offsY: 0
			}
		};
	}
}

// ============================================================================

enum abstract TextureRotation(Float) from Float to Float {
	var POS0 = 0.0;
	var POS90 = 90.0;
	var POS180 = 180.0;
	var NEG90 = -90.0;

	public inline function next():TextureRotation {
		var v:Float = this;
		if (v == 0.0)
			return POS90;
		if (v == 90.0)
			return POS180;
		if (v == 180.0)
			return NEG90;
		return POS0;
	}

	public inline function prev():TextureRotation {
		var v:Float = this;
		if (v == 0.0)
			return NEG90;
		if (v == 90.0)
			return POS0;
		if (v == 180.0)
			return POS90;
		return POS180;
	}

	public inline function toDegrees():Int {
		return Std.int(this);
	}

	public static function parse(val:Dynamic):TextureRotation {
		if (val == null)
			return POS0;

		if (Std.isOfType(val, Float)) {
			var f:Float = val;
			if (f == 0.0)
				return POS0;
			if (f == 90.0)
				return POS90;
			if (f == 180.0)
				return POS180;
			if (f == -90.0)
				return NEG90;
			return POS0;
		}

		var s:String = Std.string(val);
		return switch (s.toLowerCase()) {
			case "pos0": POS0;
			case "pos90": POS90;
			case "pos180": POS180;
			case "neg90": NEG90;
			default: POS0;
		};
	}
}

// ============================================================================

@:publicFields
@:structInit
class NoteskinData {
	var name:String;
	var sparrowImg:String;
	var configMania:Array<NoteskinConfig>;
	var clip:Array<NoteskinReceptorProperties>; // flat clip pool — index-to-clipping
}

// ============================================================================

@:publicFields
@:structInit
class NoteskinConfig {
	var offsetX:Int;
	var offsetY:Int;
	var gap:Int;
	var scale:Float;

	var idleIndexes:Array<Int>;
	var pressIndexes:Array<Int>;
	var colorIndexes:Array<Int>;
	var confirmIndexes:Array<Int>;
	var holdBodyIndexes:Array<Int>;
	var holdTailIndexes:Array<Int>;
}

// ============================================================================

@:publicFields
@:structInit
class NoteskinReceptorProperties {
	var idle:BasicNoteskinClip;
	var press:BasicNoteskinClip;
	var color:BasicNoteskinClip;
	var confirm:BasicNoteskinClip;
	var holdBody:BasicNoteskinClip;
	var holdTail:BasicNoteskinClip;
}

// ============================================================================

@:publicFields
@:structInit
class BasicNoteskinClip {
	var clipX:Int;
	var clipY:Int;
	var clipW:Int;
	var clipH:Int;
	var offsX:Int;
	var offsY:Int;
	var rotation:TextureRotation = POS0;
}

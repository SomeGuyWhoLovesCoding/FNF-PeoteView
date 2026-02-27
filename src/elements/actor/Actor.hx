package elements.actor;

import atlas.SparrowAtlas.SubTexture;
import atlas.AnimateAtlas;
import atlas.AnimateAtlas.AnimateSprite;
import atlas.AnimateAtlas.ResolvedLeaf;
import atlas.AnimateAtlas.ResolvedFrame;
import elements.actor.*;

enum AtlasType {
	SPARROW;
	ANIMATE;
	AUTO;
}

class AnimateMatrixFragShader {
	public static function setup(program:Program, textureIdentifier:String) {
		program.injectIntoFragmentShader('
			vec4 getColor(int texId, float _ma, float _mb, float _mc, float _md,
						float _rotated, float _originU, float _originV)
			{
				vec2 uv = vTexCoord; // [0,1] over the AABB quad

				// Map AABB UV → normalized sprite UV using pre-baked matrix
				// (_ma/_mb/_mc/_md already encode inverse * aabb-to-local scaling)
				float su = _ma * uv.x + _mc * uv.y;
				float sv = _mb * uv.x + _md * uv.y;

				// Add the normalized sprite origin offset
				su += _originU;
				sv += _originV;

				// If sprite is stored rotated 90° CW in the atlas, swap axes
				if (_rotated == 1.0) {
					float tmp = su;
					su = 1.0 - sv;
					sv = tmp;
				}

				if (su < 0.0 || su > 1.0 || sv < 0.0 || sv > 1.0) {
					return vec4(0.0);
				}

				return getTextureColor(texId, vec2(su, sv));
			}
		');

		program.setColorFormula('getColor(${textureIdentifier}_ID, _ma, _mb, _mc, _md, _rotated, _originU, _originV)');
	}
}

/**
	Actor element object.
	Works with Sparrow or Animate Atlas.
	For Animate atlas, manages a dynamic pool of ActorElements — one per
	visible leaf sprite — so each part of a composite character can carry
	its own accumulated world transform.
	@since Development
**/
@:publicFields
class Actor extends ActorElement
{
	static var buffers:Map<String, Buffer<ActorElement>> = [];
	var buffer(default, null):Buffer<ActorElement>;
	static var programs:Map<String, Program> = [];
	var program(default, null):Program;
	static var cachedActorDatas:Map<String, ActorData> = [];
	static var cachedAtlases:Map<String, Dynamic> = [];

	var name(default, null):String;
	var tag(default, null):Null<String>;
	var atlasType(default, null):AtlasType;
	var sparrowAtlas(default, null):SparrowAtlas;
	var animateAtlas(default, null):AnimateAtlas;
	var data(default, null):ActorData;

	var finishAnim:String = "";
	var finishCallback:Void->Void;
	var folder:String = "";
	var display(default, null):CustomDisplay;

	// -------------------------------------------------------------------------
	// Animate compositor: pool of leaf elements, one per visible sprite part
	// -------------------------------------------------------------------------

	/** Live pool of leaf ActorElements. Grows as needed, never shrinks. */
	var leafPool:Array<ActorElement> = [];
	/** How many leaves are active in the current frame. */
	var activeLeafCount:Int = 0;

	/** The resolved frames for the currently playing animation. */
	var currentResolvedFrames:Array<ResolvedFrame> = [];

	// -------------------------------------------------------------------------
	// Sparrow / shared animation state
	// -------------------------------------------------------------------------

	var startingFrameIndex:Int = 0;
	var endingFrameIndex:Int = 0;
	var frameIndex:Int = 0;
	var fps:Float;
	var frameDurationMs:Float;
	var frameTimeRemaining:Float;
	var loop:Bool;
	var indicesMode:Bool;
	var indices:Array<Int>;
	var firstFrameWidth(default, null):Float;

	var shake:Bool;
	var startingShakeFrame:Int;
	var endingShakeFrame:Int;

	var animationRunning(default, null):Bool;

	// Precomputed sing / miss pose data
	private var precomputedSingPoses_animData:Array<ActorAnimationData> = [];
	private var precomputedSingPoses_range:Array<Array<Int>> = [];
	private var precomputedMissPoses_animData:Array<ActorAnimationData> = [];
	private var precomputedMissPoses_range:Array<Array<Int>> = [];

	// -------------------------------------------------------------------------
	// Construction
	// -------------------------------------------------------------------------

	function new(display:CustomDisplay, tag:Null<String>, name:String,
				 x:Int = 0, y:Int = 0, fps:Int = 24,
				 folder:String = "images/characters/",
				 addBufferAndProgram:Bool = true, dontCopy:Bool = false)
	{
		this.display = display;
		super(Math.ffloor(x), Math.ffloor(y));

		this.folder = folder;
		this.name   = name;
		this.tag    = tag;

		var spritesheetDataPath = "";
		var atlasKey = '$name/$folder';
		atlasType = AUTO;

		if (cachedAtlases[atlasKey] == null) {
			var spritemapPath = path(name, folder, SPRITEMAP);
			var animationPath = path(name, folder, ANIMATION);

			if (pathExists(name, folder, SPRITEMAP) && pathExists(name, folder, ANIMATION)) {
				var dataPath        = StringTools.replace(spritemapPath, "spritemap1.png", "spritemap1.json");
				var spritemapContent = sys.io.File.getContent(dataPath);
				var animationContent = sys.io.File.getContent(animationPath);
				spritesheetDataPath  = spritemapPath;

				animateAtlas = new AnimateAtlas(spritemapContent, animationContent, spritemapPath);
				cachedAtlases[atlasKey] = animateAtlas;
				atlasType = ANIMATE;
			} else if (pathExists(name, folder, XML)) {
				spritesheetDataPath = path(name, folder, XML);
				sparrowAtlas = SparrowAtlas.parse(sys.io.File.getContent(spritesheetDataPath));
				cachedAtlases[atlasKey] = sparrowAtlas;
				atlasType = SPARROW;
			} else {
				throw "Atlas data doesn't exist for: " + name;
			}
		} else {
			var cached = cachedAtlases[atlasKey];
			if (Std.isOfType(cached, SparrowAtlas)) {
				sparrowAtlas = cached;
				atlasType    = SPARROW;
			} else if (Std.isOfType(cached, AnimateAtlas)) {
				animateAtlas = cached;
				atlasType    = ANIMATE;
			}
		}

		if (cachedActorDatas[atlasKey] == null && pathExists(name, folder, DATA)) {
			cachedActorDatas[atlasKey] = data = ActorData.parse(path(name, folder, DATA));
		} else if (cachedActorDatas[atlasKey] != null) {
			data = cachedActorDatas[atlasKey];
		}

		var imagePathToUse = switch (atlasType) {
			case SPARROW: sparrowAtlas.imagePath;
			case ANIMATE: animateAtlas.imagePath;
			default:      "";
		};

		if (imagePathToUse != "" && addBufferAndProgram) {
			if (tag == null) throw "Tag cannot be null when addBufferAndProgram is true";

			if (buffers[tag] == null) buffers[tag] = new Buffer<ActorElement>(64);
			buffer = buffers[tag];

			if (programs[tag] == null) {
				programs[tag] = new Program(buffer);
				program = programs[tag];
				program.blendEnabled    = true;
				program.blendSrc        = program.blendSrcAlpha = BlendFactor.ONE;
				program.blendDst        = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

				var texName = name + "Char";
				var texPath = StringTools.replace(spritesheetDataPath,
					(atlasType == SPARROW ? "data.xml" : "Animation.json"),
					imagePathToUse);
				TextureSystem.createTexture(texName, texPath, false, true);
				TextureSystem.setTexture(program, texName, texName);

				// Set up the matrix-based UV distortion shader for Animate atlas.
				// For Sparrow the matrix varyings default to identity (a=1,b=0,c=0,d=1)
				// so the shader is a no-op and Sparrow rendering is unaffected.
				if (atlasType == ANIMATE)
					AnimateMatrixFragShader.setup(program, texName);
			} else {
				program = programs[tag];
			}

			display.addProgram(program);
		}

		setFps(fps);
		mirror = !data.flip;
		scale  = data.scale;
	}

	// -------------------------------------------------------------------------
	// Leaf pool management (Animate atlas only)
	// -------------------------------------------------------------------------

	/**
	 * Ensure the leaf pool has at least `count` elements.
	 * New elements are added to the buffer automatically.
	 */
	function ensureLeafPool(count:Int) {
		while (leafPool.length < count) {
			var el = new ActorElement(this.x, this.y);
			el.scale  = this.scale;
			el.mirror = this.mirror;
			if (buffer != null) buffer.addElement(el);
			leafPool.push(el);
		}
	}

	/**
	 * Hide all leaves beyond `count` by zeroing their size.
	 */
	function hideExcessLeaves(count:Int) {
		for (i in count...activeLeafCount) {
			leafPool[i].w = 0;
			leafPool[i].h = 0;
			if (buffer != null) buffer.updateElement(leafPool[i]);
		}
		activeLeafCount = count;
	}

	// -------------------------------------------------------------------------
	// Path helpers
	// -------------------------------------------------------------------------

	inline function addToBuffer() {
		if (buffer != null) buffer.addElement(this);
	}

	static function path(name:String, folder:String, type:CharacterPathType) {
		var result = 'assets/$folder$name';
		switch (type) {
			case SPRITESHEET: result += '/sheet.png';
			case XML:         result += '/data.xml';
			case ANIMATION:   result += '/Animation.json';
			case SPRITEMAP:   result += '/spritemap1.png';
			case DATA:        result += '/charData.json';
			default:
		}
		return result;
	}

	static function pathExists(name:String, folder:String, type:CharacterPathType) {
		return sys.FileSystem.exists(path(name, folder, type));
	}

	// -------------------------------------------------------------------------
	// FPS
	// -------------------------------------------------------------------------

	function setFps(fps:Float) {
		this.fps        = fps;
		frameDurationMs = 1000.0 / fps;
		frameTimeRemaining = frameDurationMs;
	}

	// -------------------------------------------------------------------------
	// Precompute sing / miss poses
	// -------------------------------------------------------------------------

	function preComputeSingPosesOfAnimations(anims:Array<String>) {
		var dat = data.data;
		for (i in 0...anims.length) {
			var str = anims[i];
			if (!dat.exists(str)) continue;
			var animData = data.data[str];
			precomputedSingPoses_animData[i] = animData;
			if (atlasType == SPARROW)
				precomputedSingPoses_range[i] = sparrowAtlas.animMap[animData.name];
		}
	}

	function preComputeMissPosesOfAnimations(anims:Array<String>) {
		var dat = data.data;
		for (i in 0...anims.length) {
			var str = anims[i];
			if (!dat.exists(str)) continue;
			var animData = data.data[str];
			precomputedMissPoses_animData[i] = animData;
			if (atlasType == SPARROW)
				precomputedMissPoses_range[i] = sparrowAtlas.animMap[animData.name];
		}
	}

	// -------------------------------------------------------------------------
	// Internal: shared setup called by all playAnimation* variants
	// -------------------------------------------------------------------------

	/**
	 * Apply charData animation metadata (offsets, fps, indices) and set up
	 * the frame range for both Sparrow and Animate atlas types.
	 *
	 * @param symbolName  The atlas symbol / Sparrow prefix to play.
	 * @param animData    Optional charData entry (provides offsets, fps, indices).
	 * @param sparrowRange  [start, end] indices into sparrowAtlas.subTextures (Sparrow only).
	 */
	function setupAnimation(symbolName:String, animData:ActorAnimationData,
							sparrowRange:Array<Int>) {
		frameIndex = 0;

		if (animData != null) {
			adjust_x = -animData.offsets[0];
			if (mirror) adjust_x = -adjust_x;
			adjust_y = -animData.offsets[1];

			var ind = animData.indices;
			indicesMode = ind != null && ind.length != 0;
			indices     = ind;
			loop        = animData.loop;
			setFps(animData.fps);
		} else {
			indicesMode = false;
			indices     = null;
		}

		switch (atlasType) {
			case SPARROW:
				if (sparrowRange == null) return;
				startingFrameIndex = sparrowRange[0];
				endingFrameIndex   = indicesMode
					? startingFrameIndex + indices.length
					: sparrowRange[1];

			case ANIMATE:
				var frames = indicesMode
					? animateAtlas.getResolvedFramesSubset(symbolName, indices)
					: animateAtlas.getResolvedFrames(symbolName);

				if (frames == null || frames.length == 0) return;
				currentResolvedFrames = frames;
				startingFrameIndex    = 0;
				endingFrameIndex      = frames.length;

			default: return;
		}

		animationRunning = true;
		changeFrame();
	}

	// -------------------------------------------------------------------------
	// Public play methods
	// -------------------------------------------------------------------------

	function playAnimation(animKey:String, loop:Bool = false) {
		this.loop = loop;
		var animData   = data.data.exists(animKey) ? data.data[animKey] : null;
		var symbolName = animData != null ? animData.name : animKey;
		this.name      = symbolName;

		var sparrowRange = (atlasType == SPARROW)
			? sparrowAtlas.animMap[symbolName]
			: null;

		setupAnimation(symbolName, animData, sparrowRange);
	}

	function playAnimationFromSingId(id:Int, loop:Bool = false) {
		id %= precomputedSingPoses_animData.length;
		this.loop = loop;

		var animData = precomputedSingPoses_animData[id];
		if (animData == null) return;
		this.name = animData.name;

		var sparrowRange = (atlasType == SPARROW) ? precomputedSingPoses_range[id] : null;
		setupAnimation(animData.name, animData, sparrowRange);
	}

	function playAnimationFromMissId(id:Int, loop:Bool = false) {
		id %= precomputedMissPoses_animData.length;
		this.loop = loop;

		var animData = precomputedMissPoses_animData[id];
		if (animData == null) return;
		this.name = animData.name;

		var sparrowRange = (atlasType == SPARROW) ? precomputedMissPoses_range[id] : null;
		setupAnimation(animData.name, animData, sparrowRange);
	}

	function stopAnimation() {
		animationRunning = false;
	}

	// -------------------------------------------------------------------------
	// Update / render
	// -------------------------------------------------------------------------

	function endOfAnimation():Bool {
		if (frameIndex >= endingFrameIndex - startingFrameIndex) {
			animationRunning = false;
			if (finishAnim != "") {
				if (finishCallback != null) { finishCallback(); finishCallback = null; }
				playAnimation(finishAnim);
				finishAnim = "";
			}
			return true;
		}
		return false;
	}

	function update(deltaTime:Float) {
		if (!animationRunning) return;

		frameTimeRemaining -= deltaTime;
		if (frameTimeRemaining <= 0) {
			if (loop) frameIndex = (frameIndex + 1) % (endingFrameIndex - startingFrameIndex);
			else      frameIndex++;

			if (shake && frameIndex > endingShakeFrame)
				frameIndex = startingShakeFrame;

			if (endOfAnimation() && !loop) return;

			changeFrame();
			frameTimeRemaining = frameDurationMs;
		}
	}

	function render() {
		if (atlasType == ANIMATE) {
			for (i in 0...activeLeafCount) {
				if (buffer != null) buffer.updateElement(leafPool[i]);
			}
		} else {
			if (buffer != null) buffer.updateElement(this);
		}
	}

	function updateBuffer() { render(); }

	// -------------------------------------------------------------------------
	// Frame changing
	// -------------------------------------------------------------------------

	function changeFrame() {
		switch (atlasType) {
			case SPARROW:
				var frameIdx = startingFrameIndex + (indicesMode ? indices[frameIndex] : frameIndex);
				configure(sparrowAtlas.subTextures[frameIdx]);

			case ANIMATE:
				if (currentResolvedFrames == null || frameIndex >= currentResolvedFrames.length) return;
				var resolvedFrame:ResolvedFrame = currentResolvedFrames[frameIndex];
				applyResolvedFrame(resolvedFrame);

			default:
		}
	}

	/**
	 * Distribute a resolved frame's leaves across the leaf pool.
	 * Each leaf gets its own ActorElement configured with the sprite's clip rect
	 * and the decomposed world-space transform.
	 */
	function applyResolvedFrame(resolvedFrame:ResolvedFrame) {
		var count = resolvedFrame.length;
		ensureLeafPool(count);
		hideExcessLeaves(count);
		activeLeafCount = count;

		for (i in 0...count) {
			var leaf = resolvedFrame[i];
			var el   = leafPool[i];
			el.scale  = this.scale;
			el.mirror = this.mirror;
			applyLeafTransform(el, leaf, i);
		}
	}

	/**
	 * Configure clip rect, size, and full world transform for one leaf element.
	 *
	 * COORDINATE SPACE
	 * ----------------
	 * In Adobe Animate, a symbol instance matrix rotates the symbol content
	 * around its own registration point (0,0 = top-left for ASI leaves), then
	 * translates that origin to (tx, ty) in the parent space.
	 *
	 * ActorElement rotates around its CENTER (px = w/2, py = h/2).
	 * To reconcile: compute where the CENTER of the rotated sprite lands,
	 * and feed that to adjust_x/y:
	 *
	 *   center_world = (tx + vw/2*cos(A) - vh/2*sin(A),
	 *                   ty + vw/2*sin(A) + vh/2*cos(A))
	 *
	 *   adjust_x = center_world_x - vw/2   (vw/2 cancels with px in the formula)
	 *   adjust_y = center_world_y - vh/2
	 *
	 * MATRIX / UV DISTORTION
	 * ----------------------
	 * The quad is sized to the AABB of the transformed sprite corners (w/h).
	 * The fragment shader receives the raw a/b/c/d matrix components and applies
	 * the inverse transform to UV coordinates, so skew and non-uniform scale are
	 * rendered correctly within the axis-aligned quad.
	 * clipWidth/clipHeight always hold raw atlas pixel dimensions so UV sampling
	 * is never broken by the visual transform.
	 */
	function applyLeafTransform(el:ActorElement, leaf:ResolvedLeaf, leafIndex:Int) {
		var sprite = leaf.sprite;
		var s      = this.scale;

		var a  = leaf.a;
		var b  = leaf.b;
		var c  = leaf.c;
		var d  = leaf.d;
		var tx = leaf.tx;
		var ty = leaf.ty;

		// Raw atlas dimensions (before any atlas-rotation swap)
		var aw:Float = sprite.width;
		var ah:Float = sprite.height;

		if (sprite.rotated) {
			aw = sprite.height;
			ah = sprite.width;
		}

		// Four corners in LOCAL sprite content space
		var corners = [
			{x: 0.0, y: 0.0},
			{x: aw,  y: 0.0},
			{x: aw,  y: ah},
			{x: 0.0, y: ah}
		];

		// World-space corners (scaled)
		var minX =  Math.POSITIVE_INFINITY;
		var minY =  Math.POSITIVE_INFINITY;
		var maxX =  Math.NEGATIVE_INFINITY;
		var maxY =  Math.NEGATIVE_INFINITY;

		for (corner in corners) {
			var wx = (a * corner.x + c * corner.y + tx) * s;
			var wy = (b * corner.x + d * corner.y + ty) * s;
			if (wx < minX) minX = wx;
			if (wx > maxX) maxX = wx;
			if (wy < minY) minY = wy;
			if (wy > maxY) maxY = wy;
		}

		var vws = maxX - minX;
		var vhs = maxY - minY;
		var centerX = (minX + maxX) * 0.5;
		var centerY = (minY + maxY) * 0.5;

		el.w = vws;
		el.h = vhs;
		el.r = 0; // No quad rotation — AABB approach, shader handles skew

		el.adjust_x = this.adjust_x + centerX - vws * 0.5;
		el.adjust_y = this.adjust_y + centerY - vhs * 0.5;

		// Clip rect — raw atlas coords, never transformed
		el.clipX      = sprite.x;
		el.clipY      = sprite.y;
		el.rotated    = sprite.rotated;
		el.clipWidth  = sprite.width;
		el.clipHeight = sprite.height;
		el.flipX      = false;
		el.flipY      = false;

		// Normalize the matrix: strip scale and translation so the shader only
		// sees pure rotation/skew. The shader maps AABB UV → local sprite UV.
		// 
		// The sprite occupies [0..aw] x [0..ah] in local space.
		// In AABB UV space (0..1), a pixel at (u,v) corresponds to world position:
		//   world = (minX + u*vws, minY + v*vhs)  (unscaled, before actor scale)
		// We need to invert back to local sprite UV:
		//   local = M_inv * ((world/s) - t)
		// Then normalize to [0..1]: (local.x / aw, local.y / ah)
		//
		// Pass the AABB→local transform to the shader instead of the raw matrix.
		// Precompute the 2x2 inverse once here on the CPU.
		var det = a * d - b * c;
		if (Math.abs(det) < 1e-8) {
			// Degenerate matrix — just pass identity, show sprite as-is
			el._ma = 1.0; el._mb = 0.0; el._mc = 0.0; el._md = 1.0;
		} else {
			// Inverse of the 2x2 rotation/skew matrix (without scale baked in yet)
			var invA =  d / det;
			var invB = -b / det;
			var invC = -c / det;
			var invD =  a / det;

			// The shader's UV (u,v) is in [0,1] over the AABB quad.
			// Map u -> world-x-unscaled = minX/s + u * vws/s
			// Map v -> world-y-unscaled = minY/s + v * vhs/s
			// Then apply inverse matrix and subtract tx/ty to get local coords.
			// Then divide by aw/ah to get sprite UV.
			// 
			// Bake the vws/s and vhs/s scaling into the matrix passed to the shader
			// so the shader only needs: localUV = invM * (aabbUV * aabbSize - origin)
			// where aabbSize = (vws/s, vhs/s) and origin = (tx, ty).
			//
			// Pass as two vec2 uniforms OR pack into _ma/_mb/_mc/_md as a scaled matrix:
			//   _ma = invA * (vws/s) / aw    _mc = invC * (vhs/s) / aw
			//   _mb = invB * (vws/s) / ah    _md = invD * (vhs/s) / ah
			// And the shader just does: localUV = mat * uv + offset
			var vwsU = vws / s;
			var vhsU = vhs / s;

			el._ma = invA * vwsU / aw;
			el._mb = invB * vwsU / ah;
			el._mc = invC * vhsU / aw;
			el._md = invD * vhsU / ah;

			// In applyLeafTransform, after computing invA/B/C/D:
			// The AABB corner (0,0) in UV space corresponds to world point (minX, minY).
			// In local sprite space that's: inv * ((minX/s - tx), (minY/s - ty))
			var originLocalX = invA * (minX/s - tx) + invC * (minY/s - ty);
			var originLocalY = invB * (minX/s - tx) + invD * (minY/s - ty);
			el._originU = originLocalX / aw;  // add these as new @varying fields
			el._originV = originLocalY / ah;
		}

		el.scale = 1.0;
		el.x = this.x;
		el.y = this.y;

		if (leafIndex == 0 && frameIndex == 0) firstFrameWidth = vws;
	}

	// -------------------------------------------------------------------------
	// Single-sprite configure (Sparrow path — unchanged, matrix varyings stay
	// at their default identity values so the shader is a no-op)
	// -------------------------------------------------------------------------

	public function configure(subTexture:Dynamic) {
		var width:Int;
		var height:Int;
		var xOffset:Float  = 0;
		var yOffset:Float  = 0;
		var flipX:Bool     = false;
		var flipY:Bool     = false;
		var frameWidth:Float = 0;

		if (Std.isOfType(subTexture, SubTexture)) {
			var config:SubTexture = cast subTexture;
			width  = config.width;
			height = config.height;
			rotated = config.rotated;

			if (frameIndex == 0) firstFrameWidth = width;

			xOffset    = config.frameX    == null ? 0     : config.frameX;
			yOffset    = config.frameY    == null ? 0     : config.frameY;
			flipX      = config.flipX     == null ? false : config.flipX;
			flipY      = config.flipY     == null ? false : config.flipY;
			frameWidth = config.frameWidth == null ? 0    : config.frameWidth;

			off_x = -xOffset * scale;
			if (mirror) off_x = -off_x + (frameWidth - width);
			off_y = -yOffset * scale;

			if (rotated) { var t = width; width = height; height = t; }

			clipX = config.x;
			clipY = config.y;
		} else {
			return;
		}

		// Sparrow sets w/h directly. w/h are not used on the Sparrow path.
		// _ma/_mb/_mc/_md stay at their default identity values (1,0,0,1) so the
		// fragment shader inverse is also identity and UVs are passed through unchanged.
		w           = width;
		h           = height;
		this.flipX  = flipX;
		this.flipY  = flipY;
		clipWidth   = width;
		clipHeight  = height;
	}

	// -------------------------------------------------------------------------
	// Dispose
	// -------------------------------------------------------------------------

	function dispose() {
		for (el in leafPool) {
			el.w = 0;
			el.h = 0;
			if (buffer != null) buffer.updateElement(el);
		}
		leafPool        = [];
		activeLeafCount = 0;

		if (buffer  != null) buffer.clear();
		if (program != null) display.removeProgram(program);
	}
}

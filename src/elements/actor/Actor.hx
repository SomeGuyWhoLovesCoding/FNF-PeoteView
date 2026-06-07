package elements.actor;

import atlas.AnimateAtlas;
import atlas.SparrowAtlas.SubTexture;
import elements.actor.*;

/**
	Shared foundation for atlas-backed actor elements.

	Owns the buffer/program infrastructure, charData, animation state machine,
	leaf-pool helpers, and the public play/stop/update/render surface that
	both atlas variants expose identically.

	@since Development
**/
@:publicFields
class Actor extends ActorElement
{
	// ── Static caches ────────────────────────────────────────────────────────

	static var buffers:FakeStringMap<Buffer<ActorElement>>  = new FakeStringMap<Buffer<ActorElement>>();
	static var programs:FakeStringMap<CustomProgram>        = new FakeStringMap<CustomProgram>();
	static var cachedActorDatas:FakeStringMap<ActorData>    = new FakeStringMap<ActorData>();
	static var cachedAtlases:FakeStringMap<Any>         = new FakeStringMap<Any>();

	// ── Instance identity ────────────────────────────────────────────────────

	var name(default, null):String;
	var tag(default, null):Null<String>;
	var atlasType(default, null):AtlasType;
	var data(default, null):ActorData;

	// ── Render infrastructure ────────────────────────────────────────────────

	var buffer(default, null):Buffer<ActorElement>;
	var program(default, null):CustomProgram;
	var display(default, null):CustomDisplay;
	var folder:String = "";

	// ── Animation callbacks ──────────────────────────────────────────────────

	var finishAnim:String     = "";
	var finishCallback:Void->Void;

	// ── Animation state ──────────────────────────────────────────────────────

	var startingFrameIndex:Int = 0;
	var endingFrameIndex:Int   = 0;
	var frameIndex:Int         = 0;
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

	// ── Precomputed pose caches ──────────────────────────────────────────────

	private var precomputedSingPoses_animData:Array<ActorAnimationData> = [];
	private var precomputedSingPoses_range:Array<Array<Int>>            = [];
	private var precomputedMissPoses_animData:Array<ActorAnimationData> = [];
	private var precomputedMissPoses_range:Array<Array<Int>>            = [];

	// ── Construction ─────────────────────────────────────────────────────────

	function new(display:CustomDisplay, tag:Null<String>, name:String,
				 x:Int = 0, y:Int = 0, fps:Int = 24,
				 ?folder:String = "images/characters/", addBufferAndProgram:Bool = true)
	{
		this.display = display;
		super(Math.ffloor(x), Math.ffloor(y));

		this.folder = folder;
		this.name   = name;
		this.tag    = tag;

		setFps(fps);
	}

	// ── Create helper ────────────────────────────────────────────────────────

	static function create(display:CustomDisplay, tag:String, name:String,
				 x:Int = 0, y:Int = 0, fps:Int = 24,
				 ?folder:String = "images/characters/", addBufferAndProgram:Bool = true):Actor {
		var atlasKey = '$name/$folder';
		var useAnimate = cachedAtlases.get(atlasKey) != null
			? Std.isOfType(cachedAtlases.get(atlasKey), AnimateAtlas)
			: pathExists(name, folder, SPRITEMAP) && pathExists(name, folder, ANIMATION);
		return useAnimate
			? new AnimateActor(display, tag, name, x, y, fps, folder, addBufferAndProgram)
			: new SparrowActor(display, tag, name, x, y, fps, folder, addBufferAndProgram);
	}

	// ── Buffer helpers ───────────────────────────────────────────────────────

	inline function addToBuffer() {
		if (buffer != null) buffer.addElement(this);
	}

	// ── Path helpers ─────────────────────────────────────────────────────────

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

	// ── FPS ──────────────────────────────────────────────────────────────────

	function setFps(fps:Float) {
		this.fps           = fps;
		frameDurationMs    = 1000.0 / fps;
		frameTimeRemaining = frameDurationMs;
	}

	// ── Pose precomputation ──────────────────────────────────────────────────

	function preComputeSingPosesOfAnimations(anims:Array<String>) {
		var dat = data.data;
		for (i in 0...anims.length) {
			var str = anims[i];
			if (!dat.exists(str)) continue;
			var animData = data.data.get(str);
			precomputedSingPoses_animData[i] = animData;
			precomputeSingRange(i, animData);
		}
	}

	function preComputeMissPosesOfAnimations(anims:Array<String>) {
		var dat = data.data;
		for (i in 0...anims.length) {
			var str = anims[i];
			if (!dat.exists(str)) continue;
			var animData = data.data.get(str);
			precomputedMissPoses_animData[i] = animData;
			precomputeMissRange(i, animData);
		}
	}

	/** Override in subclasses to cache atlas-specific range data. */
	private function precomputeSingRange(i:Int, animData:ActorAnimationData) {}
	private function precomputeMissRange(i:Int, animData:ActorAnimationData) {}

	// ── Core animation setup ─────────────────────────────────────────────────

	/**
	 * Apply charData animation metadata and delegate atlas-specific
	 * frame-range setup to the subclass via `resolveAnimationRange`.
	 */
	function setupAnimation(symbolName:String, animData:ActorAnimationData,
							sparrowRange:Array<Int>) {
		frameIndex = 0;

		if (animData != null) {
			adjust_x = -animData.offsets[0];
			if (mirror) adjust_x = -adjust_x;
			adjust_y = -animData.offsets[1];

			var ind  = animData.indices;
			indicesMode = ind != null && ind.length != 0;
			indices     = ind;
			loop        = animData.loop;
			setFps(animData.fps);
		} else {
			indicesMode = false;
			indices     = null;
		}

		resolveAnimationRange(symbolName, sparrowRange);
		animationRunning = true;
		changeFrame();
	}

	/** Override in subclasses to set startingFrameIndex / endingFrameIndex. */
	private function resolveAnimationRange(symbolName:String, sparrowRange:Array<Int>) {}

	// ── Public play / stop ───────────────────────────────────────────────────

	function playAnimation(animKey:String, loop:Bool = false) {
		this.loop  = loop;
		var animData   = data.data.exists(animKey) ? data.data.get(animKey) : null;
		var symbolName = animData != null ? animData.name : animKey;
		this.name      = symbolName;

		var sparrowRange = sparrowRangeFor(symbolName);
		setupAnimation(symbolName, animData, sparrowRange);
	}

	function playAnimationFromSingId(id:Int, loop:Bool = false) {
		id       %= precomputedSingPoses_animData.length;
		this.loop = loop;

		var animData = precomputedSingPoses_animData[id];
		if (animData == null) return;
		this.name = animData.name;

		setupAnimation(animData.name, animData, precomputedSingPoses_range[id]);
	}

	function playAnimationFromMissId(id:Int, loop:Bool = false) {
		id       %= precomputedMissPoses_animData.length;
		this.loop = loop;

		var animData = precomputedMissPoses_animData[id];
		if (animData == null) return;
		this.name = animData.name;

		setupAnimation(animData.name, animData, precomputedMissPoses_range[id]);
	}

	function stopAnimation() {
		animationRunning = false;
	}

	/** Override to return the Sparrow frame range for a symbol (null for Animate). */
	private function sparrowRangeFor(symbolName:String):Array<Int> { return null; }

	// ── Update / render ──────────────────────────────────────────────────────

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
		renderImpl();
	}

	function updateBuffer() { render(); }

	/** Override in subclasses to push the right elements to the buffer. */
	private function renderImpl() {}

	/** Override in subclasses to apply the current frameIndex to the element. */
	function changeFrame() {}

	// ── Dispose ──────────────────────────────────────────────────────────────

	function dispose() {
		if (buffer  != null) buffer.clear();
		if (program != null) display.removeProgram(program);
	}
}

package elements.actor.sparrow;

import atlas.SparrowAtlas.SubTexture;
import elements.actor.*;

/**
	Sparrow atlas actor element object.
	Originally meant to be in the field of the gameplay state.
	@since Development
**/
@:publicFields
class Actor extends ActorElement
{
	// Stuff for initialization and shit
	var buffer:Buffer<ActorElement>;
	var program:Program;
	static var cachedActorDatas:Map<String, ActorData> = [];
	static var cachedAtlases:Map<String, SparrowAtlas> = [];

	var name(default, null):String;
	var atlas(default, null):SparrowAtlas;
	var data(default, null):ActorData;

	var finishAnim:String = "";
	var finishCallback:Void->Void;

	var folder:String = "";

	var display(default, null):CustomDisplay;

	function new(display:CustomDisplay, name:String, x:Int = 0, y:Int = 0, fps:Int = 24, folder:String = "images/characters/", addBufferAndProgram:Bool = true, dontCopy:Bool = false) {
		this.display = display;

		super(Math.ffloor(x), Math.ffloor(y));

		this.folder = folder;

		this.name = name;

		var spritesheetDataPath = "";
		var atlasKey = '$name/$folder';

		if (cachedAtlases[atlasKey] == null && pathExists(name, folder, XML)) {
			spritesheetDataPath = path(name, folder, XML);
			cachedAtlases[atlasKey] = atlas = SparrowAtlas.parse(sys.io.File.getContent(spritesheetDataPath));
		} else if (cachedAtlases[atlasKey] != null) {
			atlas = cachedAtlases[atlasKey];
		} else {
			throw "Atlas data doesn't exist: " + path(name, folder, NONE);
		}

		if (cachedActorDatas[atlasKey] == null && pathExists(name, folder, DATA)) {
			cachedActorDatas[atlasKey] = data = ActorData.parse(path(name, folder, DATA));
		} else if (cachedActorDatas[atlasKey] != null) {
			data = cachedActorDatas[atlasKey];
		}

		if (atlas.imagePath != "" && addBufferAndProgram) {
			if (buffer == null) {
				buffer = new Buffer<ActorElement>(1);
			}

			if (program == null) {
				program = new Program(buffer);
				program.blendEnabled = true;
				program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
				program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

				display.addProgram(program);

				var texName = name + "Char";
				TextureSystem.createTexture(texName, StringTools.replace(spritesheetDataPath, "data.xml", atlas.imagePath), false, true);
				TextureSystem.setTexture(program, texName, texName);
			}
		}

		setFps(fps);

		mirror = !data.flip;
		scale = data.scale;
	}

	inline function addToBuffer() {
		if (buffer != null)
			buffer.addElement(this);
	}

	static function path(name:String, folder:String, type:CharacterPathType) {
		var result = 'assets/$folder$name';

		switch (type) {
			case IMAGE:
				result += '/sheet.png';
			case XML:
				result += '/data.xml';
			case JSON:
				result += '/data.json';
			case DATA:
				result += '/charData.json';
			default:
		}

		return result;
	}

	// This is here to improve readability
	static function pathExists(name:String, folder:String, type:CharacterPathType) {
		return sys.FileSystem.exists(path(name, folder, type));
	}

	// Now for the animation stuff
	// Part of the code is originally from jobf's sparrow atlas demo on peote-view

	var startingFrameIndex:Int;
	var endingFrameIndex:Int;
	var frameIndex:Int;
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

	function setFps(fps:Float) {
		this.fps = fps;
		frameDurationMs = 1000.0 / fps;
		frameTimeRemaining = frameDurationMs;
	}

	// This is there because singing poses are just common.
	private var precomputedSingPoses_animData:Array<ActorAnimationData> = [];
	private var precomputedSingPoses_range:Array<Array<Int>> = [];

	function preComputeSingPosesOfAnimations(anims:Array<String>) {
		var dat = data.data;
		for (i in 0...anims.length) {
			var str = anims[i];
			if (!dat.exists(str)) continue;
			var name = data.data[str].name;
			precomputedSingPoses_animData[i] = data.data[str];
			precomputedSingPoses_range[i] = atlas.animMap[name];
		}
	}

	// This is there because missing poses are just common.
	private var precomputedMissPoses_animData:Array<ActorAnimationData> = [];
	private var precomputedMissPoses_range:Array<Array<Int>> = [];

	function preComputeMissPosesOfAnimations(anims:Array<String>) {
		var dat = data.data;
		for (i in 0...anims.length) {
			var str = anims[i];
			if (!dat.exists(str)) continue;
			var name = data.data[str].name;
			precomputedMissPoses_animData[i] = data.data[str];
			precomputedMissPoses_range[i] = atlas.animMap[name];
		}
	}

	function playAnimationFromSingId(id:Int, loop:Bool = false) {
		id %= precomputedSingPoses_animData.length;
		//Sys.println(id);

		frameIndex = 0;
		this.loop = loop;

		var oldName = name;

		var animData = precomputedSingPoses_animData[id];
		if (animData == null) return;

		name = animData.name;

		adjust_x = -animData.offsets[0];
		if (mirror) adjust_x = -adjust_x;
		adjust_y = -animData.offsets[1];

		var ind = animData.indices;

		indicesMode = ind != null && ind.length != 0;
		indices = ind;

		loop = animData.loop;

		setFps(animData.fps);

		var animMap = precomputedSingPoses_range[id];
		if (animMap == null) return;
		startingFrameIndex = animMap[0];
		endingFrameIndex = indicesMode ? startingFrameIndex + indices.length : animMap[1];
		animationRunning = true;

		changeFrame();
	}

	function playAnimationFromMissId(id:Int, loop:Bool = false) {
		id %= precomputedMissPoses_animData.length;

		frameIndex = 0;
		this.loop = loop;

		var oldName = name;

		var animData = precomputedMissPoses_animData[id];
		if (animData == null) return;

		name = animData.name;

		adjust_x = -animData.offsets[0];
		if (mirror) adjust_x = -adjust_x;
		adjust_y = -animData.offsets[1];

		var ind = animData.indices;

		indicesMode = ind != null && ind.length != 0;
		indices = ind;

		loop = animData.loop;

		setFps(animData.fps);

		var animMap = precomputedMissPoses_range[id];
		if (animMap == null) return;
		startingFrameIndex = animMap[0];
		endingFrameIndex = indicesMode ? startingFrameIndex + indices.length : animMap[1];
		animationRunning = true;

		changeFrame();
	}

	function playAnimation(name:String, loop:Bool = false) {
		frameIndex = 0;
		this.loop = loop;

		var animDataMap = data.data;
		if (animDataMap.exists(name)) {
			var oldName = name;

			var animData = animDataMap[name];

			name = animData.name;

			adjust_x = -animData.offsets[0];
			if (mirror) adjust_x = -adjust_x;
			adjust_y = -animData.offsets[1];

			var ind = animData.indices;

			indicesMode = ind != null && ind.length != 0;
			indices = ind;

			loop = animData.loop;

			setFps(animData.fps);
		} else {
			indicesMode = false;
			indices = null;
		}

		var animMap = atlas.animMap[name];
		if (animMap == null) return;
		startingFrameIndex = animMap[0];
		endingFrameIndex = indicesMode ? startingFrameIndex + indices.length : animMap[1];
		animationRunning = true;

		changeFrame();
	}

	function stopAnimation() {
		animationRunning = false;
	}

	function endOfAnimation():Bool {
		if (frameIndex >= endingFrameIndex - startingFrameIndex) {
			animationRunning = false;
			if (finishAnim != "") {
				if (finishCallback != null) {
					finishCallback();
					finishCallback = null;
				}
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
			else frameIndex++;

			if (shake && frameIndex > endingShakeFrame) {
				frameIndex = startingShakeFrame;
			}

			if (endOfAnimation() && !loop) {
				return;
			}

			changeFrame();
			frameTimeRemaining = frameDurationMs;
		}
	}

	function render() {
		if (buffer != null) buffer.updateElement(this);
	}

	function updateBuffer() {
		if (buffer != null) buffer.updateElement(this);
	}

	public function configure(config:SubTexture) {
		var width = config.width;
		var height = config.height;

		rotated = config.rotated;

		if (frameIndex == 0) {
			firstFrameWidth = width;
		}

		var xOffset = config.frameX == null ? 0 : config.frameX;
		var yOffset = config.frameY == null ? 0 : config.frameY;
		var flipX = config.flipX == null ? false : config.flipX;
		var flipY = config.flipY == null ? false : config.flipY;
		var frameWidth = config.frameWidth == null ? 0 : config.frameWidth;

		off_x = -xOffset * scale;
		if (mirror) off_x = -off_x + (frameWidth - width); // yes, I actually had to do this to fix mirrored frame offsets and shit.
		off_y = -yOffset * scale;

		if (rotated) {
			var rotatedWidth = height;
			var rotatedHeight = width;
			width = rotatedWidth;
			height = rotatedHeight;
		}

		w = width;
		h = height;
		this.flipX = flipX;
		this.flipY = flipY;
		clipX = config.x;
		clipY = config.y;
		clipWidth = width;
		clipHeight = height;
	}

	function changeFrame() {
		var frameIdx = startingFrameIndex;

		if (indicesMode) {
			frameIdx += indices[frameIndex];
		} else {
			frameIdx += frameIndex;
		}

		configure(atlas.subTextures[frameIdx]);
	}

	function dispose() {
		if (buffer != null) {
			buffer.clear();
		}

		if (program != null) {
			display.removeProgram(program);
		}
	}
}
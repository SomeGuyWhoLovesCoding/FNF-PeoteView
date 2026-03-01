package elements.actor;

import atlas.SparrowAtlas;
import atlas.SparrowAtlas.SubTexture;
import elements.actor.*;

/**
	Actor backed by a Sparrow spritesheet atlas.

	Handles XML parsing, frame-range lookup, and single-quad rendering.
	The inherited fragment shader receives identity matrix varyings by default,
	making the UV distortion path a no-op on the Sparrow code route.

	@since Development
**/
@:publicFields
class SparrowActor extends Actor
{
	var sparrowAtlas(default, null):SparrowAtlas;

	// ── Construction ─────────────────────────────────────────────────────────

	function new(display:CustomDisplay, tag:Null<String>, name:String,
				 x:Int = 0, y:Int = 0, fps:Int = 24,
				 folder:String = "images/characters/",
				 addBufferAndProgram:Bool = true)
	{
		super(display, tag, name, x, y, fps, folder, addBufferAndProgram);

		atlasType = SPARROW;

		// ── Atlas loading ──────────────────────────────────────────────────

		var atlasKey = '$name/$folder';

		if (Actor.cachedAtlases[atlasKey] == null) {
			if (!Actor.pathExists(name, folder, XML))
				throw "Sparrow atlas data doesn't exist for: " + name;

			sparrowAtlas = SparrowAtlas.parse(
				sys.io.File.getContent(Actor.path(name, folder, XML))
			);
			Actor.cachedAtlases[atlasKey] = sparrowAtlas;
		} else {
			sparrowAtlas = Actor.cachedAtlases[atlasKey];
		}

		// ── Character data ─────────────────────────────────────────────────

		if (Actor.cachedActorDatas[atlasKey] == null && Actor.pathExists(name, folder, DATA)) {
			Actor.cachedActorDatas[atlasKey] = data = ActorData.parse(Actor.path(name, folder, DATA));
		} else if (Actor.cachedActorDatas[atlasKey] != null) {
			data = Actor.cachedActorDatas[atlasKey];
		}

		// ── Buffer & program ───────────────────────────────────────────────

		if (sparrowAtlas.imagePath != "" && addBufferAndProgram) {
			if (tag == null) throw "Tag cannot be null when addBufferAndProgram is true";

			if (Actor.buffers[tag] == null) Actor.buffers[tag] = new Buffer<ActorElement>(64);
			buffer = Actor.buffers[tag];

			if (Actor.programs[tag] == null) {
				Actor.programs[tag] = new CustomProgram(buffer);
				program = Actor.programs[tag];
				program.blendEnabled = true;
				program.blendSrc     = program.blendSrcAlpha = BlendFactor.ONE;
				program.blendDst     = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

				var texName = name + "Char";
				var xmlPath = Actor.path(name, folder, XML);
				var texPath = StringTools.replace(xmlPath, "data.xml", sparrowAtlas.imagePath);
				TextureSystem.createTexture(texName, texPath, false, true);
				TextureSystem.setTexture(program, texName, texName);

				// Sparrow uses identity matrix varyings — the UV distortion shader
				// is a no-op here; nothing extra is injected.
			} else {
				program = Actor.programs[tag];
			}

			display.addProgram(program);
		}

		mirror = !data.flip;
		scale  = data.scale;
	}

	// ── Pose precomputation ───────────────────────────────────────────────────

	override private function precomputeSingRange(i:Int, animData:ActorAnimationData) {
		precomputedSingPoses_range[i] = sparrowAtlas.animMap[animData.name];
	}

	override private function precomputeMissRange(i:Int, animData:ActorAnimationData) {
		precomputedMissPoses_range[i] = sparrowAtlas.animMap[animData.name];
	}

	// ── Atlas range resolution ────────────────────────────────────────────────

	override private function sparrowRangeFor(symbolName:String):Array<Int> {
		return sparrowAtlas.animMap[symbolName];
	}

	override private function resolveAnimationRange(symbolName:String, sparrowRange:Array<Int>) {
		if (sparrowRange == null) return;
		startingFrameIndex = sparrowRange[0];
		endingFrameIndex   = indicesMode
			? startingFrameIndex + indices.length
			: sparrowRange[1];
	}

	// ── Frame rendering ───────────────────────────────────────────────────────

	override function changeFrame() {
		var frameIdx = startingFrameIndex + (indicesMode ? indices[frameIndex] : frameIndex);
		configure(sparrowAtlas.subTextures[frameIdx]);
	}

	override private function renderImpl() {
		if (buffer != null) buffer.updateElement(this);
	}

	// ── Sparrow frame configuration ───────────────────────────────────────────

	/**
	 * Apply a SubTexture to this element: clips, offsets, flip flags.
	 * Matrix varyings (_ma/_mb/_mc/_md) remain at their default identity
	 * values so the shared UV distortion shader is a transparent no-op.
	 */
	public function configure(subTexture:Dynamic) {
		if (!Std.isOfType(subTexture, SubTexture)) return;
		var config:SubTexture = cast subTexture;

		var width  = config.width;
		var height = config.height;
		rotated    = config.rotated;

		if (frameIndex == 0) firstFrameWidth = width;

		var xOffset    = config.frameX     == null ? 0     : config.frameX;
		var yOffset    = config.frameY     == null ? 0     : config.frameY;
		var flipX      = config.flipX      == null ? false : config.flipX;
		var flipY      = config.flipY      == null ? false : config.flipY;
		var frameWidth = config.frameWidth == null ? 0     : config.frameWidth;

		off_x = -xOffset * scale;
		if (mirror) off_x = -off_x + (frameWidth - width);
		off_y = -yOffset * scale;

		if (rotated) { var t = width; width = height; height = t; }

		clipX      = config.x;
		clipY      = config.y;
		w          = width;
		h          = height;
		this.flipX = flipX;
		this.flipY = flipY;
		clipWidth  = width;
		clipHeight = height;
	}
}

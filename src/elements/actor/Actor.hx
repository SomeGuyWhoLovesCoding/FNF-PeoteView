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
     */
	function applyLeafTransform(el:ActorElement, leaf:ResolvedLeaf, leafIndex:Int) {
		var sprite = leaf.sprite;
		var s      = this.scale;

		// Decompose accumulated matrix into rotation + scale
		// Column 0: (a, b)  Column 1: (c, d)
		var scaleX   = Math.sqrt(leaf.a * leaf.a + leaf.b * leaf.b);
		var scaleY   = Math.sqrt(leaf.c * leaf.c + leaf.d * leaf.d);
		var angleDeg = Math.atan2(leaf.b, leaf.a) * (180.0 / Math.PI);

		// Visual size after atlas-rotation swap + correct scale axis assignment.
		// For rotated sprites, the matrix col0 (scaleX) runs along atlas-width = visual-height,
		// and col1 (scaleY) runs along atlas-height = visual-width. So we must scale the
		// atlas dimensions first, THEN swap — not swap first and then scale.
		var aws = sprite.width  * scaleX;  // scaled atlas width
		var ahs = sprite.height * scaleY;  // scaled atlas height

		// After -90° correction: visual width = atlas height, visual height = atlas width
		var vws:Float = sprite.rotated ? ahs : aws;
		var vhs:Float = sprite.rotated ? aws : ahs;

		// Full render angle: symbol rotation + atlas-packing correction
		var renderDeg = sprite.rotated ? angleDeg - 90.0 : angleDeg;
		var A    = renderDeg * (Math.PI / 180.0);
		var cosA = Math.cos(A);
		var sinA = Math.sin(A);

		// Pivot compensation: Animate rotates around the sprite top-left (0,0).
		// ActorElement rotates around its center. Compute where the center of the
		// SCALED sprite ends up after rotation around the top-left, so we can feed
		// that world position to adjust_x/y.
		//
		//   cx = (vws/2)*cos(A) - (vhs/2)*sin(A)
		//   cy = (vws/2)*sin(A) + (vhs/2)*cos(A)
		//
		// adjust = tx + cx - vws/2   (the vws/2 cancels with px = el.w/2 in the formula)
		var cx = (vws * 0.5) * cosA - (vhs * 0.5) * sinA;
		var cy = (vws * 0.5) * sinA + (vhs * 0.5) * cosA;

		el.adjust_x = this.adjust_x + (leaf.tx + cx - vws * 0.5);
		el.adjust_y = this.adjust_y + (leaf.ty + cy - vhs * 0.5);

		// Quad size: scaled dimensions (scale baked in, el.scale = actor scale only)
		el.w = vws;
		el.h = vhs;
		el.off_x = 0;
		el.off_y = 0;

		// Clip rect: always raw atlas dimensions
		el.clipX      = sprite.x;
		el.clipY      = sprite.y;
		el.clipWidth  = sprite.width;
		el.clipHeight = sprite.height;
		el.flipX      = false;
		el.flipY      = false;

		// Rotation: rotated=true → shader applies -90° atlas correction.
		// _angle carries the symbol's own rotation. Formula combines both.
		el.rotated = sprite.rotated;
		el._angle  = angleDeg;

		// Actor-level scale only (leaf scale is baked into w/h)
		el.scale = s;

		el.x = this.x;
		el.y = this.y;

		if (leafIndex == 0 && frameIndex == 0) firstFrameWidth = vws;
	}

    // -------------------------------------------------------------------------
    // Single-sprite configure (Sparrow path, unchanged)
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
        // Hide all leaf elements (zero size so they don't render)
        for (el in leafPool) {
            el.w = 0;
            el.h = 0;
            if (buffer != null) buffer.updateElement(el);
        }
        leafPool     = [];
        activeLeafCount = 0;

        if (buffer != null)  buffer.clear();
        if (program != null) display.removeProgram(program);
    }
}

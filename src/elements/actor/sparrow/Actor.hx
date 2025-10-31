package elements.actor.sparrow;

import atlas.SparrowAtlas.SubTexture;
import atlas.SparrowAtlas.AnimationData;
import elements.actor.*;

/**
    Sparrow atlas actor element object.
    Handles animation playback and rendering using SparrowAtlas.
**/
@:publicFields
class Actor extends ActorElement {
    var buffer:Buffer<ActorElement>;
    var program:Program;

    static var cachedActorDatas:Map<String, ActorData> = [];
    static var cachedAtlases:Map<String, SparrowAtlas> = [];

    var name(default, null):String;
    var atlas(default, null):SparrowAtlas;
    var data(default, null):ActorData;
    var display(default, null):CustomDisplay;

    var folder:String = "";

    // Animation state
    var currentAnim:AnimationData;
    var animName:String;
    var frameIndex:Int;
    var fps:Float;
    var frameDurationMs:Float;
    var frameTimeRemaining:Float;
    var loop:Bool;
    var indicesMode:Bool;
    var indices:Array<Int>;

    var shake:Bool;
    var startingShakeFrame:Int;
    var endingShakeFrame:Int;

    var finishAnim:String = "";
    var finishCallback:Void->Void;
    var animationRunning:Bool;

    var firstFrameWidth(default, null):Float;

    function new(display:CustomDisplay, name:String, x:Int = 0, y:Int = 0, fps:Int = 24, folder:String = "images/characters/", addBufferAndProgram:Bool = true, dontCopy:Bool = false) {
        this.display = display;
        super(Math.ffloor(x), Math.ffloor(y));

        this.folder = folder;
        this.name = name;

        var atlasKey = '$name/$folder';
        loadAtlas(atlasKey);
        loadActorData(atlasKey);

        if (atlas.imagePath != "" && addBufferAndProgram) setupRendering(atlasKey);

        setFps(fps);

        mirror = !data.flip;
        scale = data.scale;
    }

    // --- Loading helpers ---
    inline function loadAtlas(key:String) {
        if (cachedAtlases[key] == null && pathExists(name, folder, XML)) {
            cachedAtlases[key] = atlas = SparrowAtlas.parse(sys.io.File.getContent(path(name, folder, XML)));
        } else if (cachedAtlases[key] != null) {
            atlas = cachedAtlases[key];
        } else {
            throw "Atlas data doesn't exist: " + path(name, folder, NONE);
        }
    }

    inline function loadActorData(key:String) {
        if (cachedActorDatas[key] == null && pathExists(name, folder, DATA)) {
            cachedActorDatas[key] = data = ActorData.parse(path(name, folder, DATA));
        } else if (cachedActorDatas[key] != null) {
            data = cachedActorDatas[key];
        }
    }

    inline function setupRendering(atlasKey:String) {
        if (buffer == null) buffer = new Buffer<ActorElement>(1);
        if (program == null) {
            program = new Program(buffer);
            program.blendEnabled = true;
            program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
            program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;
            display.addProgram(program);

            var texName = name + "Char";
            TextureSystem.createTexture(texName, StringTools.replace(path(name, folder, XML), "data.xml", atlas.imagePath), false, true);
            TextureSystem.setTexture(program, texName, texName);
        }
    }

    // --- FPS & Animation ---
    inline function setFps(fps:Float) {
        this.fps = fps;
        frameDurationMs = 1000.0 / fps;
        frameTimeRemaining = frameDurationMs;
    }

    function playAnimation(name:String, loop:Bool = false) {
        frameIndex = 0;
        this.loop = loop;

        // ActorData override
        if (data.data.exists(name)) {
            var ad = data.data[name];
            animName = ad.name;

            adjust_x = -ad.offsets[0];
            if (mirror) adjust_x = -adjust_x;
            adjust_y = -ad.offsets[1];

            indicesMode = ad.indices != null && ad.indices.length > 0;
            indices = ad.indices;

            loop = ad.loop;
            setFps(ad.fps);
        } else {
            animName = name;
            indicesMode = false;
            indices = null;
        }

        currentAnim = atlas.animations[animName];
        if (currentAnim == null) return;

        animationRunning = true;
        changeFrame();
    }

    function stopAnimation() {
        animationRunning = false;
    }

    function endOfAnimation():Bool {
        var totalFrames = indicesMode ? indices.length : currentAnim.frames.length;
        if (frameIndex >= totalFrames) {
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
        if (buffer != null) buffer.updateElement(this);
        if (!animationRunning) return;

        frameTimeRemaining -= deltaTime;

        if (frameTimeRemaining <= 0) {
            frameIndex++;
            if (loop) {
                var totalFrames = indicesMode ? indices.length : currentAnim.frames.length;
                frameIndex %= totalFrames;
            }

            if (shake && frameIndex > endingShakeFrame) {
                frameIndex = startingShakeFrame;
            }

            if (endOfAnimation() && !loop) return;

            changeFrame();
            frameTimeRemaining = frameDurationMs;
        }
    }

    // --- Frame handling ---
    function changeFrame() {
        if (currentAnim == null) return;

        var frame:SubTexture = indicesMode
            ? currentAnim.frames[indices[frameIndex]]
            : currentAnim.frames[frameIndex];

        configure(frame);
    }

    public function configure(frame:SubTexture) {
        var width = frame.width;
        var height = frame.height;

        if (frameIndex == 0) firstFrameWidth = width;

        var xOffset = frame.frameX == null ? 0 : frame.frameX;
        var yOffset = frame.frameY == null ? 0 : frame.frameY;
        var flipX = frame.flipX == null ? false : frame.flipX;
        var flipY = frame.flipY == null ? false : frame.flipY;
        var frameWidth = frame.frameWidth == null ? 0 : frame.frameWidth;

        off_x = -xOffset * scale;
        if (mirror) off_x = -off_x + (frameWidth - width);
        off_y = -yOffset * scale;

        w = width;
        h = height;
        this.flipX = flipX;
        this.flipY = flipY;
        clipX = frame.x;
        clipY = frame.y;
        clipWidth = width;
        clipHeight = height;
    }

    // --- Buffer & cleanup ---
    inline function addToBuffer() {
        if (buffer != null) buffer.addElement(this);
    }

    function updateBuffer() {
        if (buffer != null) buffer.updateElement(this);
    }

    function dispose() {
        if (buffer != null) buffer.clear();
        if (program != null) display.removeProgram(program);
    }

    // --- File helpers ---
    static function path(name:String, folder:String, type:CharacterPathType):String {
        var result = 'assets/$folder$name';
        switch (type) {
            case IMAGE: result += '/sheet.png';
            case XML: result += '/data.xml';
            case JSON: result += '/data.json';
            case DATA: result += '/charData.json';
            default:
        }
        return result;
    }

    static function pathExists(name:String, folder:String, type:CharacterPathType):Bool {
        return sys.FileSystem.exists(path(name, folder, type));
    }
}

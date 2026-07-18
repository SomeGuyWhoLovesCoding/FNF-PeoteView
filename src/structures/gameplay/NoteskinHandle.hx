package structures.gameplay;

import haxe.Json;
import sys.io.File;
import sys.FileSystem;
import lime.graphics.Image;

/** Noteskin handle. Owns per-skin sheet metadata (texUnit/texSlot pair from the
    shared TextureCache) plus data.json contents. The actual texture is owned
    by `NoteskinManager.textureCache` (a peote-view `TextureCache`) — this
    handle just remembers which (unit, slot) within that cache holds this
    skin's sheet. Folder-name-keyed to avoid data.name collisions. **/
@:publicFields
class NoteskinHandle {
    /** Skin folder name. Used as the unique key for the manager — NOT data.name,
        which can collide across folders. */
    var skinName:String = "";

    /** Source image. Kept on the handle so the sustain shader can read the
        image's dimensions (the master texture's dims are the BUCKET size,
        which differs from this image's size when packed into a bigger bucket).
        After close-fit resize, image dims == bucket dims. */
    var image:Image = null;

    /** The TextureData handed to `NoteskinManager.registerTextureData`. Kept
        on the handle so `dispose()` can pass it back to
        `textureCache.removeData(textureData)` to release the slot. */
    var textureData:TextureData = null;

    /** Which bucket (texture unit) this skin's sheet landed in. Used as the
        per-element @texUnit value so the shader samples this skin's bucket. */
    var texUnit:Int = 0;

    /** Which slot within the bucket's master texture holds this skin's sheet.
        Used as the per-element @texSlot value so peote-view offsets UVs to the
        right sub-rect of the master texture. */
    var texSlot:Int = 0;

    /** True once loadTexture() has created the texture and registered it. */
    var loaded:Bool = false;

    /** Current mania key count. Set by Strumline. */
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
        configMania: [{
            offsetX: 0,
            offsetY: 0,
            gap: 112,
            scale: 1.0,
            idleIndexes:     [0, 1, 2, 3],
            pressIndexes:    [0, 1, 2, 3],
            colorIndexes:    [0, 1, 2, 3],
            confirmIndexes:  [0, 1, 2, 3],
            holdBodyIndexes: [0, 1, 2, 3],
            holdTailIndexes: [0, 1, 2, 3]
        }],
        clip: [
            {
                idle:     {clipX: 436, clipY: 301, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                press:    {clipX: 546, clipY: 301, clipW: 99,  clipH: 100, offsX: 0, offsY: 0},
                color:    {clipX: 226, clipY: 384, clipW: 108, clipH: 110, offsX: 0, offsY: 0},
                confirm:  {clipX: 1,   clipY: 1,   clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                holdBody: {clipX: 145, clipY: 467, clipW: 35,  clipH: 31,  offsX: 0, offsY: 0},
                holdTail: {clipX: 73,  clipY: 467, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
            },
            {
                idle:     {clipX: 114, clipY: 357, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                press:    {clipX: 548, clipY: 191, clipW: 99,  clipH: 98,  offsX: 0, offsY: 0},
                color:    {clipX: 1,   clipY: 245, clipW: 112, clipH: 110, offsX: 0, offsY: 0},
                confirm:  {clipX: 242, clipY: 1,   clipW: 191, clipH: 192, offsX: 0, offsY: 0},
                holdBody: {clipX: 181, clipY: 467, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                holdTail: {clipX: 1,   clipY: 467, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
            },
            {
                idle:     {clipX: 436, clipY: 191, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                press:    {clipX: 444, clipY: 413, clipW: 101, clipH: 99,  offsX: 0, offsY: 0},
                color:    {clipX: 1,   clipY: 356, clipW: 112, clipH: 110, offsX: 0, offsY: 0},
                confirm:  {clipX: 242, clipY: 194, clipW: 193, clipH: 189, offsX: 0, offsY: 0},
                holdBody: {clipX: 217, clipY: 495, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                holdTail: {clipX: 37,  clipY: 467, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
            },
            {
                idle:     {clipX: 114, clipY: 245, clipW: 110, clipH: 111, offsX: 0, offsY: 0},
                press:    {clipX: 546, clipY: 402, clipW: 97,  clipH: 99,  offsX: 0, offsY: 0},
                color:    {clipX: 335, clipY: 413, clipW: 108, clipH: 110, offsX: 0, offsY: 0},
                confirm:  {clipX: 434, clipY: 1,   clipW: 189, clipH: 189, offsX: 0, offsY: 0},
                holdBody: {clipX: 181, clipY: 498, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                holdTail: {clipX: 109, clipY: 467, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
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
            configMania: [for (cfg in src.configMania) {
                offsetX: cfg.offsetX,
                offsetY: cfg.offsetY,
                gap: cfg.gap,
                scale: cfg.scale,
                idleIndexes:     cfg.idleIndexes.copy(),
                pressIndexes:    cfg.pressIndexes.copy(),
                colorIndexes:    cfg.colorIndexes.copy(),
                confirmIndexes:  cfg.confirmIndexes.copy(),
                holdBodyIndexes: cfg.holdBodyIndexes.copy(),
                holdTailIndexes: cfg.holdTailIndexes.copy()
            }],
            clip: [for (c in src.clip) {
                idle:     cloneClip(c.idle),
                press:    cloneClip(c.press),
                color:    cloneClip(c.color),
                confirm:  cloneClip(c.confirm),
                holdBody: cloneClip(c.holdBody),
                holdTail: cloneClip(c.holdTail)
            }]
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
                    idle:     parseClip(rawClip.idle),
                    press:    parseClip(rawClip.press),
                    color:    parseClip(rawClip.color),
                    confirm:  parseClip(rawClip.confirm),
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

    /** Load the sheet image, pack it into the shared TextureCache, and store
        the returned (texUnit, texSlot) pair. Idempotent.

        The cache picks the smallest bucket whose slot dimensions are >= the
        image's dimensions (the "resize to be bigger" path) and packs into a
        free slot of that bucket. Images > 4096x4096 throw — see
        NoteskinManager.MAX_TEXTURE_DIMENSION. **/
    function loadTexture():Void {
        //trace("Loaded - true");
        if (loaded) return;

        var sheetPath = Paths.asset('$folder/${data.sparrowImg}');
        if (!FileSystem.exists(sheetPath)) {
            trace('NoteskinHandle: sheet texture not found at "$sheetPath" for skin "$skinName"');
            return;
        }

        // Load the source image. We keep the reference on `image` so the
        // sustain shader can read this image's dimensions (the master
        // texture in the cache is sized to the BUCKET, not the image).
        image = Image.fromFile(sheetPath);
        if (image == null) {
            trace('NoteskinHandle: Image.fromFile failed for skin "$skinName" (path=$sheetPath)');
            return;
        }

        // Close-fit resize: if the image dimensions don't EXACTLY match any
        // bucket but are "close enough" (within RESIZE_FIT_TOLERANCE), resize
        // the image up to the bucket's exact dimensions. peote-view's
        // TextureCache.addData requires exact dimension matches per slot, so
        // without this a 1000x480 sheet would be rejected even though it
        // clearly belongs in the 1024x512 bucket.
        //
        // We resize the Image in-place (lime's Image.resize mutates the
        // underlying pixel buffer). Note: lime's default resize is bilinear
        // for upscaling — adequate for art sheets, no extra quality config
        // needed here.
        var bucket = NoteskinManager.findClosestFitBucket(image.width, image.height);
        if (bucket == null) {
            // Image is much smaller than any fitting bucket, or all fitting
            // buckets are too loose a match. Pass it through to peote-view
            // anyway — it may still handle it (or reject with its own error,
            // which the try/catch below will surface).
            trace('NoteskinHandle: WARNING — "$skinName" (${image.width}x${image.height}) is not close to any bucket; trying registerTextureData as-is');
        } else if (bucket.w != image.width || bucket.h != image.height) {
            trace('NoteskinHandle: close-fit resizing "$skinName" from ${image.width}x${image.height} to ${bucket.w}x${bucket.h}');
            image.resize(bucket.w, bucket.h);
        }

        // Convert Image to TextureData with premultiplied alpha.
        // This replicates TextureSystem.createTexture's premultiply logic —
        // we can't use TextureSystem directly because it creates a Texture in
        // its own pool, and we want a TextureData to hand to
        // TextureCache.addData instead.
        //
        // Premultiplication scales RGB by alpha so the shader can use
        // (src*alpha + dst) blending without dark fringes on translucent
        // edges. The noteskins render with alpha blending enabled, so this
        // matters for visual quality.
        textureData = new TextureData(image.width, image.height, TextureFormat.RGBA);
        textureData.bytes = haxe.io.Bytes.alloc(image.width * image.height * 4);
        var srcBytes = image.data.toBytes();
        for (i in 0...textureData.bytes.length >> 2) {
            var fullARGB = srcBytes.getInt32(i << 2);
            var a = (fullARGB >>> 24) & 0xFF;
            var r = (fullARGB >>> 16) & 0xFF;
            var g = (fullARGB >>> 8)  & 0xFF;
            var b = (fullARGB)        & 0xFF;
            // Scale RGB by alpha (>> 8 is divide by 256, close enough to /255).
            r = (r * a) >> 8;
            g = (g * a) >> 8;
            b = (b * a) >> 8;
            var premul = (a << 24) | (r << 16) | (g << 8) | b;
            textureData.bytes.setInt32(i << 2, premul);
        }

        // Pack into the shared TextureCache. registerTextureData returns
        // peote-view's {unit, slot} placement (or null if all slots full).
        // Throws if textureData > MAX_TEXTURE_DIMENSION — let it propagate.
        var placement:{unit:Int, slot:Int} = null;
        try {
            placement = NoteskinManager.registerTextureData(textureData);
        } catch (e:Dynamic) {
            trace('NoteskinHandle: registerTextureData threw for skin "$skinName" (${image.width}x${image.height}): $e');
            textureData = null;
            image = null;
            return;
        }
        if (placement == null) {
            trace('NoteskinHandle: registerTextureData returned null for skin "$skinName" (all slots full?)');
            textureData = null;
            image = null;
            return;
        }

        // Stash the (unit, slot) pair onto the handle so Note/Sustain's
        // setHandle() can propagate them to the @texUnit / @texSlot
        // element attributes.
        texUnit = placement.unit;
        texSlot = placement.slot;
        loaded = true;
        trace('NoteskinHandle: loaded skin "$skinName" (${image.width}x${image.height}) -> unit=$texUnit, slot=$texSlot');
    }

    /** Bind NoteskinManager.textureCache (a peote-view TextureCache) to a
        program as a multi-texture under `identifier` (default "noteTexV2").
        Call once at program creation; no re-binding needed on skin switch —
        peote-view rebinds the bucket textures at draw time based on each
        element's @texUnit, and offsets UVs by @texSlot automatically. **/
    function setProgramsTexture(program:CustomProgram, identifier:String = "noteTexV2") {
        if (NoteskinManager.textureCache == null) {
            trace('NoteskinHandle.setProgramsTexture: textureCache null — skipping');
            return;
        }
        program.setMultiTexture(NoteskinManager.textureCache.textures, identifier);
    }

    function setProgramsNoteShader(program:CustomProgram) {
        program.injectIntoFragmentShader(
        '
            vec4 why(int textureID, float initialAlpha, float addedAlpha)
            {
                vec4 tex = getTextureColor(textureID, vTexCoord);
                if (tex.a == 0.0) return tex;
                float newA = clamp(tex.a * initialAlpha + addedAlpha, 0.0, 1.0);
                return vec4(tex.rgb * (newA / tex.a), newA);
            }
        ');
        program.setColorFormula( 'c * why(noteTexV2_ID, initialAlpha, addedAlpha)' );
    }

    /** Inject the sustain tiling/rotation shader. Bakes 1/texW and 1/texH as
        float literals from THIS handle's source IMAGE dimensions.

        After `loadTexture`'s close-fit resize, `image.width`/`image.height`
        EQUAL the bucket's dimensions for any skin that was resized (which is
        the common case). For exact-match skins (no resize needed), the image
        dimensions also match the bucket. So the baked literals are correct for
        THIS skin's bucket — but they're still wrong for OTHER skins in OTHER
        buckets, since this shader is only injected once per program at init
        time using the FIRST cached skin's dimensions.

        A proper fix is the mat4-as-texture-array trick: pack all 13 buckets'
        `(invW, invH)` into 4 mat4 uniforms and look up by `textureID` in the
        shader. See notes in `NoteskinManager.BUCKET_SIZES` and the mat4
        approach discussed in the worklog. **/
    function setProgramsSustainShader(program:CustomProgram) {
        if (image == null) {
            trace('NoteskinHandle.setProgramsSustainShader: image is null for "$skinName" — skipping');
            return;
        }

        var invTileW = Util.toFloatString(1.0 / image.width);
        var invTileH = Util.toFloatString(1.0 / image.height);

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

            vec4 slice(int textureID, vec4 bodyCoord, vec4 tailCoord, float texRotation) {
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
                vec2 uv = (rect.xy + rotated * rect.zw) * vec2($invTileW, $invTileH);

                // Clamp to [0,1] to prevent out-of-bounds sampling when
                // coords are near texture edges (which made the tail disappear).
                uv = clamp(uv, vec2(0.0), vec2(1.0));

                return getTextureColor(textureID, uv);
            }
        ');

        program.setColorFormula('c * slice(noteTexV2_ID, vec4(bodyX, bodyY, bodyW, bodyH), vec4(tailX, tailY, tailW, tailH), texRotation)');
    }

    /** Clear this handle's references and release its slot back to the
        shared TextureCache (so another skin can reuse it later). The cache
        itself stays alive until NoteskinManager.disposeAll().
        Safe to call multiple times. **/
    function dispose() {
        // Release the slot back to the cache. peote-view's removeData
        // takes the same TextureData reference we passed to addData, so
        // it can find the slot in its textureDataMap and mark it free.
        if (textureData != null && NoteskinManager.textureCache != null) {
            try {
                NoteskinManager.textureCache.removeData(textureData);
            } catch (e:Dynamic) {
                trace('NoteskinHandle.dispose: removeData failed for "$skinName": $e');
            }
        }
        loaded = false;
        image = null;
        textureData = null;
        texUnit = 0;
        texSlot = 0;
    }

    // --- Getters for clip data by index ---

    /** Get the NoteskinReceptorProperties for a given clip index. */
    inline function getClip(index:Int):NoteskinReceptorProperties {
        if (data.clip != null && index >= 0 && index < data.clip.length) {
            return data.clip[index];
        }
        return defaultClip();
    }

    /** Get a specific clip type for a given clip index. */
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

    /** Get the clip index array for a given edit state from a config. */
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
        // Support both old format (single "indexes") and new format (per-type indexes).
        var oldIndexes:Array<Int> = raw.indexes;
        var hasOld = oldIndexes != null && oldIndexes.length > 0;

        return {
            offsetX: raw.offsetX != null ? raw.offsetX : 0,
            offsetY: raw.offsetY != null ? raw.offsetY : 0,
            gap: raw.gap != null ? raw.gap : 112,
            scale: raw.scale != null ? raw.scale : 1.0,
            idleIndexes:     raw.idleIndexes != null     ? raw.idleIndexes     : (hasOld ? oldIndexes.copy() : []),
            pressIndexes:    raw.pressIndexes != null    ? raw.pressIndexes    : (hasOld ? oldIndexes.copy() : []),
            colorIndexes:    raw.colorIndexes != null    ? raw.colorIndexes    : (hasOld ? oldIndexes.copy() : []),
            confirmIndexes:  raw.confirmIndexes != null  ? raw.confirmIndexes  : (hasOld ? oldIndexes.copy() : []),
            holdBodyIndexes: raw.holdBodyIndexes != null ? raw.holdBodyIndexes : (hasOld ? oldIndexes.copy() : []),
            holdTailIndexes: raw.holdTailIndexes != null ? raw.holdTailIndexes : (hasOld ? oldIndexes.copy() : [])
        };
    }

    /** Shared default receptor properties. */
    static function defaultClip():NoteskinReceptorProperties {
        return {
            idle:     {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0},
            press:    {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0},
            color:    {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0},
            confirm:  {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0},
            holdBody: {clipX: 0, clipY: 0, clipW: 35,  clipH: 31,  offsX: 0, offsY: 0},
            holdTail: {clipX: 0, clipY: 0, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
        };
    }
}

// ============================================================================

enum abstract TextureRotation(Float) from Float to Float {
    /** 0° — no rotation. */
    var POS0   = 0.0;
    /** 90° clockwise. */
    var POS90  = 90.0;
    /** 180°. */
    var POS180 = 180.0;
    /** 90° counter-clockwise (270°). */
    var NEG90  = -90.0;

    /** Cycle to the next rotation value. */
    public inline function next():TextureRotation {
        var v:Float = this;
        if (v == 0.0)   return POS90;
        if (v == 90.0)  return POS180;
        if (v == 180.0) return NEG90;
        return POS0;
    }

    /** Cycle to the previous rotation value. */
    public inline function prev():TextureRotation {
        var v:Float = this;
        if (v == 0.0)   return NEG90;
        if (v == 90.0)  return POS0;
        if (v == 180.0) return POS90;
        return POS180;
    }

    /** To degrees. */
    public inline function toDegrees():Int {
        return Std.int(this);
    }

    /**
        Parse from JSON value — accepts numeric degrees or legacy
        string formats ("POS0", "POS90", "POS180", "NEG90").
        Defaults to POS0.
    **/
    public static function parse(val:Dynamic):TextureRotation {
        if (val == null) return POS0;

        if (Std.isOfType(val, Float)) {
            var f:Float = val;
            if (f == 0.0)   return POS0;
            if (f == 90.0)  return POS90;
            if (f == 180.0) return POS180;
            if (f == -90.0) return NEG90;
            return POS0;
        }

        var s:String = Std.string(val);
        return switch (s.toLowerCase()) {
            case "pos0":   POS0;
            case "pos90":  POS90;
            case "pos180": POS180;
            case "neg90":  NEG90;
            default:       POS0;
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

    /** Per-mania-key clip index for the IDLE state. */
    var idleIndexes:Array<Int>;
    /** Per-mania-key clip index for the PRESS state. */
    var pressIndexes:Array<Int>;
    /** Per-mania-key clip index for the COLOR overlay. */
    var colorIndexes:Array<Int>;
    /** Per-mania-key clip index for the CONFIRM state. */
    var confirmIndexes:Array<Int>;
    /** Per-mania-key clip index for the HOLD_BODY state. */
    var holdBodyIndexes:Array<Int>;
    /** Per-mania-key clip index for the HOLD_TAIL state. */
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

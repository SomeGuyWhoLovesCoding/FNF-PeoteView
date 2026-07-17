package structures.gameplay;

import sys.FileSystem;

using StringTools;

/** Noteskin manager. Owns a shared `TextureCache` (peote-view) bound to programs
    via `setMultiTexture`. Skins get packed into the smallest bucket that fits
    ("resize to be bigger" — an image smaller than the bucket still lands there,
    never the other way). Each NoteskinHandle's `(texUnit, texSlot)` pair —
    returned by `cache.addData(textureData)` — becomes the per-element selector that
    Note/Sustain use to sample the right skin's slot of the right bucket.

    Bucket layout (13 texture units total — one Texture per bucket type, since
    slot counts are capped to what fits in one 4096x4096 master texture):
      256x256 (16 slots) / 256x512 (16) / 512x256 (16) / 512x512 (16) /
      512x1024 (16) / 1024x512 (16) / 1024x1024 (16) / 1024x2048 (8) /
      2048x1024 (8) / 2048x2048 (4) / 2048x4096 (2) / 4096x2048 (2) /
      4096x4096 (1)
    Total: 137 noteskin slots across 13 GL texture units.
    POT buckets use `powerOfTwo:true`; NPOT use `powerOfTwo:false`.
    Images larger than 4096x4096 throw on `registerTextureData` (no bucket fits). **/
@:publicFields
class NoteskinManager {
    /** Max image dimension accepted by `registerTextureData`. Matches the largest
        bucket in `textureCache`. Images exceeding this throw immediately —
        peote-view would also reject them, but with a less clear error. **/
    static var MAX_TEXTURE_DIMENSION:Int = 4096;

    // --- Bucket configs ---
    // POT buckets (square power-of-two sizes) use powerOfTwo:true.
    // NPOT buckets (off-square or non-POT sizes) use powerOfTwo:false.
    // Both share maxTextureSize:4096 — the master texture for any bucket
    // won't exceed 4096 in either dimension.
    static var textureConfigPOT:TextureConfig = { maxTextureSize: 4096, powerOfTwo: true };
    static var textureConfig:TextureConfig    = { maxTextureSize: 4096, powerOfTwo: false };

    /** Bucket size table. MUST match the order of entries passed to
        `new TextureCache([...])` in init() — `findClosestFitBucket` and
        `setBucketUniforms` (if added later for the mat4 sustain-shader trick)
        both depend on this ordering. **/
    static var BUCKET_SIZES:Array<{w:Int, h:Int}> = [
        {w: 256,  h: 256 }, {w: 256,  h: 512 }, {w: 512,  h: 256 },
        {w: 512,  h: 512 }, {w: 512,  h: 1024}, {w: 1024, h: 512 },
        {w: 1024, h: 1024}, {w: 1024, h: 2048}, {w: 2048, h: 1024},
        {w: 2048, h: 2048}, {w: 2048, h: 4096}, {w: 4096, h: 2048},
        {w: 4096, h: 4096}
    ];

    /** Tolerance for the "close to fit" resize. If an image's dimensions are
        both >= this fraction of a bucket's dimensions AND <= the bucket's
        dimensions, the image gets resized UP to match the bucket exactly.
        0.75 means an image as small as 75% of the bucket (e.g. 768x384 →
        1024x512) is still considered "close". Set to 1.0 to disable the
        resize (only exact matches pass through unchanged). **/
    static var RESIZE_FIT_TOLERANCE:Float = 0.75;

    /** The shared peote-view TextureCache. null until init(). Programs bind
        this directly via `setMultiTexture(cache, identifier)`. Each entry
        in the array below becomes one GL texture unit; `slots` is how many
        images pack into that unit's master texture. **/
    static var textureCache:TextureCache = null;

    static var currentLoadedNoteskins:FakeStringMap<NoteskinHandle> = new FakeStringMap<NoteskinHandle>();

    /** Scan `assets/images/noteskins/`, create a handle for every skin folder,
        and loadTexture() each one. Peote-view's TextureCache handles slot
        allocation and bucketing automatically; skins that fail to load (sheet
        missing, oversized, all slots full) are kept as handles with
        `loaded=false` so the manager still knows about them.
        Idempotent — call disposeAll() first for a clean slate. **/
    static function init() {
        if (textureCache != null || currentLoadedNoteskins.keys.length > 0) {
            disposeAll();
        }

        // Build the cache with 13 buckets. Slot counts are capped to what
        // fits in ONE 4096x4096 master texture per bucket — otherwise
        // peote-view's TextureCache creates multiple Textures per bucket
        // type to satisfy the slot request, and each Texture burns a
        // texture unit. With these counts, each bucket = 1 Texture = 1
        // unit → 13 units total.
        //
        // Slot-count math (slots that fit in a 4096x4096 master per bucket):
        //   256x256  → 16x16 = 256 (cap at 16)
        //   256x512  → 16x8  = 128 (cap at 16)
        //   512x256  → 8x16  = 128 (cap at 16)
        //   512x512  → 8x8   = 64  (cap at 16)
        //   512x1024 → 8x4   = 32  (cap at 16)
        //   1024x512 → 4x8   = 32  (cap at 16)
        //   1024x1024→ 4x4   = 16  (cap at 16)
        //   1024x2048→ 4x2   = 8   (cap at 8)
        //   2048x1024→ 2x4   = 8   (cap at 8)
        //   2048x2048→ 2x2   = 4   (cap at 4)
        //   2048x4096→ 2x1   = 2   (cap at 2)
        //   4096x2048→ 1x2   = 2   (cap at 2)
        //   4096x4096→ 1x1   = 1   (cap at 1)
        // Total slots: 16*7 + 8*2 + 4 + 2*2 + 1 = 137 noteskins across 13 units.
        textureCache = new TextureCache([
            { width: 256,  height: 256,  slots: 16, config: textureConfigPOT },
            { width: 256,  height: 512,  slots: 16, config: textureConfig    },
            { width: 512,  height: 256,  slots: 16, config: textureConfig    },
            { width: 512,  height: 512,  slots: 16, config: textureConfigPOT },
            { width: 512,  height: 1024, slots: 16, config: textureConfig    },
            { width: 1024, height: 512,  slots: 16, config: textureConfig    },
            { width: 1024, height: 1024, slots: 16, config: textureConfigPOT },
            { width: 1024, height: 2048, slots: 8,  config: textureConfig    },
            { width: 2048, height: 1024, slots: 8,  config: textureConfig    },
            { width: 2048, height: 2048, slots: 4,  config: textureConfigPOT },
            { width: 2048, height: 4096, slots: 2,  config: textureConfig    },
            { width: 4096, height: 2048, slots: 2,  config: textureConfig    },
            { width: 4096, height: 4096, slots: 1,  config: textureConfigPOT },
        ]);

        var skinFolder = Paths.asset('assets/images/noteskins');
        var skinFolderFolders = FileSystem.readDirectory(skinFolder);

        var skinNames:Array<String> = [];
        for (dir in skinFolderFolders) {
            var subfolder = '$skinFolder/$dir';
            trace(subfolder);
            if (subfolder.endsWith(".png") || subfolder.endsWith(".xml") || subfolder.endsWith(".txt")) continue;
            if (!FileSystem.isDirectory(subfolder)) continue;

            // Pick up any folder with data.json OR a sheet PNG. NoteskinHandle
            // falls back to DEFAULT_DATA (sparrowImg="sheet.png") when data.json
            // is missing, so newly-created folders are switchable immediately.
            var folderFiles = FileSystem.readDirectory(subfolder);
            var hasDataJson = folderFiles.contains("data.json");
            var hasAnyPng = false;
            for (f in folderFiles) {
                if (f.endsWith(".png")) { hasAnyPng = true; break; }
            }
            if (hasDataJson || hasAnyPng) {
                skinNames.push(dir);
            }
        }

        for (skinName in skinNames) {
            var handle = new NoteskinHandle(skinName);
            handle.loadTexture();
            if (!handle.loaded) {
                trace('NoteskinManager.init: skin "$skinName" failed to load — handle exists but has no slot');
            }
            currentLoadedNoteskins.set(skinName, handle);
        }

        var skinLen = currentLoadedNoteskins.keys.length;
        var loadedCount = 0;
        for (name in currentLoadedNoteskins.keys) {
            var h = currentLoadedNoteskins.get(name);
            if (h != null && h.loaded) loadedCount++;
        }
        trace('NoteskinManager.init: $skinLen skin(s) — $loadedCount loaded, ${skinLen - loadedCount} failed');

        trace('NoteskinManager.init: per-skin summary:');
        for (name in currentLoadedNoteskins.keys) {
            var h = currentLoadedNoteskins.get(name);
            if (h != null) {
                trace('  "$name" -> unit=${h.texUnit}, slot=${h.texSlot}, loaded=${h.loaded}');
            }
        }
    }

    /** Find the smallest bucket that fits `imageW`×`imageH` AND is "close enough"
        to it (both ratios >= `RESIZE_FIT_TOLERANCE`). Returns null if no bucket
        qualifies — either the image is too small relative to every fitting
        bucket (would need too much upscaling) or larger than 4096 in either dim.

        Used by `NoteskinHandle.loadTexture` to decide whether to resize the
        source image up to the bucket's exact dimensions before passing it
        to `registerTextureData`. peote-view's `TextureCache.addData` requires
        exact dimension matches per slot, so without this resize step a
        1000×480 sheet would be rejected even though it clearly belongs in
        the 1024×512 bucket. **/
    static function findClosestFitBucket(imageW:Int, imageH:Int):{w:Int, h:Int} {
        var best:{w:Int, h:Int} = null;
        var bestArea = 0;
        for (b in BUCKET_SIZES) {
            // Image must FIT in the bucket (both dims <= bucket dims) — we
            // only resize UP, never down. Larger images are handled by the
            // 4096 throw in registerTextureData.
            if (imageW > b.w || imageH > b.h) continue;
            // Image must be CLOSE to the bucket — at least RESIZE_FIT_TOLERANCE
            // of the bucket's size in both axes. Without this check, a tiny
            // 100x100 image would get stretched 2.5x to 256x256 and look awful.
            var wRatio = imageW / b.w;
            var hRatio = imageH / b.h;
            if (wRatio < RESIZE_FIT_TOLERANCE || hRatio < RESIZE_FIT_TOLERANCE) continue;
            // Pick the SMALLEST fitting bucket — minimizes wasted UV space
            // in the bucket's master texture.
            var area = b.w * b.h;
            if (best == null || area < bestArea) {
                best = b;
                bestArea = area;
            }
        }
        return best;
    }

    /** Pack a TextureData into the shared TextureCache and return the placement
        peote-view assigned (`{unit, slot}`). The caller (NoteskinHandle.loadTexture)
        copies those onto its own `texUnit` / `texSlot` fields so Note/Sustain
        elements can sample the right slot of the right bucket.

        Returns null if no bucket fits (all slots full or textureData larger
        than MAX_TEXTURE_DIMENSION). Throws if textureCache is null.

        peote-view's `addData` does its own smallest-fitting-bucket search and
        slot allocation, but it does NOT resize — the caller is responsible for
        ensuring the textureData fits an existing bucket (see
        NoteskinHandle.loadTexture's close-fit resize step). **/
    static function registerTextureData(textureData:TextureData):{unit:Int, slot:Int} {
        if (textureData == null) throw 'NoteskinManager.registerTextureData: textureData is null';
        if (textureData.width > MAX_TEXTURE_DIMENSION || textureData.height > MAX_TEXTURE_DIMENSION) {
            throw 'NoteskinManager.registerTextureData: textureData ${textureData.width}x${textureData.height} exceeds '
                + 'max ${MAX_TEXTURE_DIMENSION}x${MAX_TEXTURE_DIMENSION} (no texture-cache bucket fits)';
        }
        if (textureCache == null) {
            throw 'NoteskinManager.registerTextureData: textureCache is null — call NoteskinManager.init() first';
        }
        return textureCache.addData(textureData);
    }

    /** Get a loaded handle by name. Returns null if not found. Skins that
        failed to load return with loaded=false — caller should check before
        binding. **/
    static function get(skinName:String):NoteskinHandle {
        var handle = currentLoadedNoteskins.get(skinName);
        if (handle == null) return null;

        if (!handle.loaded) {
            trace('NoteskinManager.get: "$skinName" not loaded — texUnit falls back to 0');
        }
        return handle;
    }

    /** Free the entire TextureCache (drops every bucket's master texture) and
        clear all per-skin handles. Call init() again to rebuild from disk.

        peote-view's `TextureCache` doesn't expose a `dispose()` method, so we
        iterate its `textures` array and dispose each `Texture` individually
        (this is what frees the actual GPU memory). **/
    static function disposeAll() {
        if (currentLoadedNoteskins != null) {
            for (name in currentLoadedNoteskins.keys) {
                var handle = currentLoadedNoteskins.get(name);
                if (handle != null) handle.dispose();
            }
        }
        if (textureCache != null) {
            for (tex in textureCache.textures) {
                try { tex.dispose(); } catch (e) {}
            }
            textureCache = null;
        }
        currentLoadedNoteskins = new FakeStringMap<NoteskinHandle>();
        trace('NoteskinManager.disposeAll: dropped all skins + TextureCache');
    }

    /** Dispose a single skin. Releases the slot back to the cache (so another
        skin can reuse it later) and marks the handle unloaded. Does NOT shift
        other handles' texUnit/texSlot — peote-view's slot indices stay stable
        per-element across the lifetime of the cache. **/
    static function disposeSkin(skinName:String) {
        var handle = currentLoadedNoteskins.get(skinName);
        if (handle == null) return;

        handle.dispose();
        trace('NoteskinManager.disposeSkin: disposed "$skinName"');
    }
}

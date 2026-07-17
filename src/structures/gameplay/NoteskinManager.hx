package structures.gameplay;

import sys.FileSystem;
import system.TextureSystem;

using StringTools;

/**
    Noteskin manager class.

    Owns the shared `textureCache:Array<Texture>` that all noteskin
    sheet textures live in. Each `NoteskinHandle` registers its
    `Texture` here on `loadTexture()`, and the resulting index in the
    array becomes the handle's `texUnit` (the per-element multi-texture
    selector used by `Note` / `Sustain` elements).

    ## Multi-texture architecture

    Programs bind the entire `textureCache` once via
    `program.setMultiTexture(textureCache, "noteTexV2")` (called from
    `NoteskinHandle.setProgramsTexture`). Switching noteskins does NOT
    require re-binding — each element just updates its `@texUnit` /
    `@texSlot` attributes from the new handle via `setHandle()`.

    ## Cap + overflow

    `MAX_CACHED_NOTESKINS = 15` is the hard cap on simultaneously-loaded
    skin textures. The first 15 skins discovered in
    `assets/images/noteskins/` get `loadTexture()` called on them at
    `init()` time, register their `Texture` in `textureCache`, and are
    immediately available for binding. Any extras are parked (handle
    exists, `loaded == false`) — switching to a parked skin requires
    extending the manager to evict an LRU slot, which is not yet
    implemented.

    ## Texture ownership

    All textures live in BOTH:
      - `TextureSystem.pool` (under per-skin key `'noteskin_<skinName>'`
        where `<skinName>` is the FOLDER NAME, not `data.name` — this
        prevents two folders with colliding `data.name` values from
        sharing the same pool entry, which would otherwise cause
        `setMultiTexture` to throw "textureLayer cannot contain same
        texture twice") so `disposeTexture(key)` can free GPU memory
        on shutdown.
      - `NoteskinManager.textureCache` (an `Array<Texture>`) so
        `setMultiTexture(cache, name)` can bind them all to a program.

    Call `disposeAll()` to free every cached texture (via
    `TextureSystem.disposeTexture`) and clear all tracking state.
**/
@:publicFields
class NoteskinManager {
    /**
        Hard cap on how many noteskins can have their sheet texture
        simultaneously loaded into `textureCache`.

        15 is a reasonable default — typical GL_MAX_TEXTURE_IMAGE_UNITS
        is 16, leaving one unit for UI / framebuffer / etc. Each
        noteskin sheet is typically 512x512 to 2048x2048, so 15 skins
        is roughly 4-16 MB of GPU memory (depending on format).

        If the user has more than this many noteskins on disk, the
        extras are parked (handle exists but `loaded == false`) and
        NOT registered in `textureCache`. Switching to a parked skin
        currently traces a warning — full LRU eviction + slot
        reassignment is a future enhancement.
    **/
    static var MAX_CACHED_NOTESKINS:Int = 15;

    /**
        The shared multi-texture cache. Each entry is one noteskin's
        sheet `Texture`. Indices in this array are the `texUnit` values
        that `Note` / `Sustain` elements use to select which skin to
        sample from.

        Populated by `registerTexture(texture)` (called from
        `NoteskinHandle.loadTexture()`). Passed to programs via
        `program.setMultiTexture(textureCache, "noteTexV2")` (called
        from `NoteskinHandle.setProgramsTexture()`).

        `null` until `init()` is called.
    **/
    static var textureCache:Array<Texture> = null;

    static var currentLoadedNoteskins:FakeStringMap<NoteskinHandle> = new FakeStringMap<NoteskinHandle>();

    // =========================================================================
    // Initialization
    // =========================================================================

    /**
        Initialize the manager: scan the noteskins folder, create a
        handle for every skin, and call `loadTexture()` on the first
        `MAX_CACHED_NOTESKINS` so their sheet textures are in
        `textureCache`. Extras are parked (handle exists but
        `loaded == false`).

        Idempotent: calling this when already initialized will re-scan
        the noteskins folder and rebuild everything. Call `disposeAll()`
        first if you want a clean slate.
    **/
    static function init() {
        // Drop any prior state (defensive — caller should normally
        // call disposeAll() first).
        if (textureCache != null || currentLoadedNoteskins.keys.length > 0) {
            disposeAll();
        }

        textureCache = [];

        var skinFolder = Paths.asset('assets/images/noteskins');
        var skinFolderFolders = FileSystem.readDirectory(skinFolder);

        var skinNames:Array<String> = [];
        for (dir in skinFolderFolders) {
            var subfolder = '$skinFolder/$dir';
            trace(subfolder);
            if (subfolder.endsWith(".png") || subfolder.endsWith(".xml") || subfolder.endsWith(".txt")) continue;
            if (!FileSystem.isDirectory(subfolder)) continue;

            // Include any folder that has data.json OR a sheet PNG.
            // Folders with only a PNG get picked up too — NoteskinHandle's
            // constructor falls back to DEFAULT_DATA if data.json is
            // missing, and DEFAULT_DATA.sparrowImg defaults to "sheet.png".
            // This ensures newly-created skin folders are switchable
            // from the start (the editor writes data.json lazily on
            // first edit, but we still want to switch TO them before
            // that first edit happens).
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

        var totalSkins = skinNames.length;

        // Warn if we're over the cap.
        if (totalSkins > MAX_CACHED_NOTESKINS) {
            trace('NoteskinManager.init: WARNING — found $totalSkins noteskins but the cache cap is $MAX_CACHED_NOTESKINS. '
                + 'Only the first $MAX_CACHED_NOTESKINS will have their textures loaded into textureCache; '
                + 'the remaining ${totalSkins - MAX_CACHED_NOTESKINS} will be parked (handle exists, loaded=false) '
                + 'and switching to them will currently trace a warning.');
        }

        // Create a handle for every skin. The first N get loadTexture()
        // (which registers their texture in textureCache and assigns
        // their texUnit); the rest are parked (loaded == false).
        for (i => skinName in skinNames) {
            var handle = new NoteskinHandle(skinName);
            if (i < MAX_CACHED_NOTESKINS) {
                handle.loadTexture();
                if (!handle.loaded) {
                    // loadTexture failed (sheet missing, etc.) — don't
                    // mark it as cached, but still keep the handle for
                    // data lookups.
                    trace('NoteskinManager.init: skin "$skinName" failed to load — handle exists but has no texture');
                }
            } else {
                // Parked skin — handle exists but texture not loaded.
                trace('NoteskinManager.init: parked "$skinName" (over $MAX_CACHED_NOTESKINS cap)');
            }
            currentLoadedNoteskins.set(skinName, handle);
        }

        var skinLen = currentLoadedNoteskins.keys.length;
        var cachedLen = textureCache != null ? textureCache.length : 0;
        trace('NoteskinManager.init: initialized with $skinLen skin(s) — '
            + '$cachedLen cached in textureCache, ${skinLen - cachedLen} parked');

        // Per-skin summary: log each skin's folder name, texUnit, and
        // textureKey. This makes it easy to verify at startup that every
        // skin got a DISTINCT texUnit — if two skins share texUnit=0,
        // switching between them won't visually change the texture
        // (both sample from slot 0).
        trace('NoteskinManager.init: per-skin summary:');
        for (name in currentLoadedNoteskins.keys) {
            var h = currentLoadedNoteskins.get(name);
            if (h != null) {
                trace('  "$name" -> texUnit=${h.texUnit}, loaded=${h.loaded}, '
                    + 'textureKey="${h.textureKey}", data.name="${h.data != null ? h.data.name : "??"}"');
            }
        }
    }

    /**
        Append a `Texture` to the shared `textureCache` and return its
        index. Called from `NoteskinHandle.loadTexture()` after the
        texture is created in `TextureSystem.pool`.

        The returned index becomes the handle's `texUnit` — the value
        that `Note` / `Sustain` elements copy into their `@texUnit`
        attribute via `setHandle()` so the shader samples from THIS
        skin's slot of the multi-texture.

        If `textureCache` is null (i.e. `init()` hasn't been called
        yet), initializes it as an empty array first — this lets a
        `NoteskinHandle` be loaded before the manager is initialized
        (e.g. for an editor-side fallback path).
    **/
    static function registerTexture(texture:Texture):Int {
        if (textureCache == null) textureCache = [];
        textureCache.push(texture);
        return textureCache.length - 1;
    }

    // =========================================================================
    // Lookup
    // =========================================================================

    /**
        Get a loaded noteskin handle by name. Returns null if not found.

        If the skin is currently parked (because there were more than
        `MAX_CACHED_NOTESKINS` on disk), this currently traces a
        warning and returns the parked handle (which has `loaded ==
        false` and `texUnit == 0`). The caller should check
        `handle.loaded` before binding.
    **/
    static function get(skinName:String):NoteskinHandle {
        var handle = currentLoadedNoteskins.get(skinName);
        if (handle == null) return null;

        if (!handle.loaded) {
            // Parked skin — full LRU swap-in is a future enhancement.
            // For now, just trace and return the parked handle so the
            // caller can decide what to do (fall back, error out, etc.).
            trace('NoteskinManager.get: "$skinName" is parked (over $MAX_CACHED_NOTESKINS cap) — '
                + 'returning handle with loaded=false, texUnit will fall back to 0');
        }
        return handle;
    }

    // =========================================================================
    // Disposal
    // =========================================================================

    /**
        Dispose all loaded noteskin handles and free every cached
        texture from `TextureSystem.pool` + `textureCache`.

        For each cached handle, calls `TextureSystem.disposeTexture(handle.textureKey)`
        to free the GPU memory and remove the texture from the pool.
        Then clears `textureCache`, `currentLoadedNoteskins`.

        After this, `init()` must be called again before any skin can
        be used.
    **/
    static function disposeAll() {
        if (currentLoadedNoteskins != null) {
            for (name in currentLoadedNoteskins.keys) {
                var handle = currentLoadedNoteskins.get(name);
                if (handle != null && handle.loaded && handle.textureKey != null && handle.textureKey != "") {
                    try {
                        TextureSystem.disposeTexture(handle.textureKey);
                    } catch (e) {
                        // Ignore — we're dropping everything anyway.
                    }
                    handle.dispose();
                }
            }
        }
        textureCache = null;
        currentLoadedNoteskins = new FakeStringMap<NoteskinHandle>();
        trace('NoteskinManager.disposeAll: dropped all skins + textures + textureCache');
    }

    /**
        Dispose a single noteskin handle by name.

        - If the skin is cached: calls `TextureSystem.disposeTexture()`
          to free its GPU memory and remove it from the pool, marks it
          unloaded. Does NOT remove the entry from `textureCache`
          (that would shift indices and break other handles' `texUnit`
          values — instead the slot stays reserved with a now-disposed
          texture, which is safe because the handle is no longer
          "loaded" so no element should be sampling from it).
        - If the skin is parked: just clears the handle's state (no
          texture to dispose).

        The handle is left in `currentLoadedNoteskins` (marked
        unloaded). A subsequent `get(skinName)` will return it with
        `loaded == false`.
    **/
    static function disposeSkin(skinName:String) {
        var handle = currentLoadedNoteskins.get(skinName);
        if (handle == null) return;

        if (handle.loaded && handle.textureKey != null && handle.textureKey != "") {
            try {
                TextureSystem.disposeTexture(handle.textureKey);
            } catch (e) {
                trace('NoteskinManager.disposeSkin: disposeTexture failed for "$skinName": $e');
            }
        }

        handle.dispose();
        trace('NoteskinManager.disposeSkin: disposed "$skinName"');
    }
}

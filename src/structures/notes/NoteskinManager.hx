package structures.notes;

import sys.FileSystem;
import system.TextureSystem;

using StringTools;

/**
	Noteskin manager. Owns the shared `textureCache:Array<Texture>` bound to
	programs via `setMultiTexture`. Each NoteskinHandle's index in this array
	becomes its `texUnit` (the per-element selector Note/Sustain use to sample
	the right skin). Textures also live in `TextureSystem.pool` under
	`'noteskin_<skinName>'` (folder-name-keyed) for disposal. MAX_CACHED_NOTESKINS
	caps simultaneous loaded textures; extras are parked (handle exists, not loaded).

	⚠ WIP! NEED A WAY TO EFFECTIVELY MAKE MY OWN TEXTURE UNIT-SLOT ISSUE THAT DOESN'T CONSUME
	ALL OF THE RAM LIKE PEOTEVIEW TEXTURECACHE DOES. WILL BE BACK LATER.
**/
@:publicFields
class NoteskinManager {
	/** Hard cap on simultaneously-loaded skin textures. 15 leaves one texture
		unit free for UI/framebuffer out of the typical 16 GL_MAX_TEXTURE_IMAGE_UNITS. **/
	static var MAX_CACHED_NOTESKINS:Int = 15;

	/** Shared multi-texture cache. Indices are the `texUnit` values Note/Sustain
		elements use to select which skin to sample. Null until init(). **/
	static var textureCache:Array<Texture> = null;

	static var currentLoadedNoteskins:FakeStringMap<NoteskinHandle> = new FakeStringMap<NoteskinHandle>();

	/** Scan `assets/images/noteskins/`, create a handle for every skin folder,
		and loadTexture() the first MAX_CACHED_NOTESKINS. Extras are parked.
		Idempotent — call disposeAll() first for a clean slate. **/
	static function init() {
		if (textureCache != null || currentLoadedNoteskins.keys.length > 0) {
			disposeAll();
		}

		textureCache = [];

		var skinFolder = Paths.asset('assets/images/noteskins');
		var skinFolderFolders = FileSystem.readDirectory(skinFolder);

		var skinNames:Array<String> = [];
		for (dir in skinFolderFolders) {
			var subfolder = '$skinFolder/$dir';
			// trace(subfolder);
			if (subfolder.endsWith(".png") || subfolder.endsWith(".xml") || subfolder.endsWith(".txt"))
				continue;
			if (!FileSystem.isDirectory(subfolder))
				continue;

			// Pick up any folder with data.json OR a sheet PNG. NoteskinHandle
			// falls back to DEFAULT_DATA (sparrowImg="sheet.png") when data.json
			// is missing, so newly-created folders are switchable immediately.
			var folderFiles = FileSystem.readDirectory(subfolder);
			var hasDataJson = folderFiles.contains("data.json");
			var hasAnyPng = false;
			for (f in folderFiles) {
				if (f.endsWith(".png")) {
					hasAnyPng = true;
					break;
				}
			}
			if (hasDataJson || hasAnyPng) {
				skinNames.push(dir);
			}
		}

		var totalSkins = skinNames.length;
		if (totalSkins > MAX_CACHED_NOTESKINS) {
			trace('NoteskinManager.init: WARNING — $totalSkins skins found, cap is $MAX_CACHED_NOTESKINS. '
				+ 'First $MAX_CACHED_NOTESKINS get textures; ${totalSkins - MAX_CACHED_NOTESKINS} parked.');
		}

		//BOTTLENECK: low init() synchronously loadTexture()s up to MAX_CACHED_NOTESKINS full sheets (PNG decode + premultiply on main thread) — multi-hundred-ms stall at startup/editor entry | FIX: lazy-load the active skin first, queue the rest
		for (i => skinName in skinNames) {
			var handle = new NoteskinHandle(skinName);
			if (i < MAX_CACHED_NOTESKINS) {
				handle.loadTexture();
				if (!handle.loaded) {
					trace('NoteskinManager.init: skin "$skinName" failed to load — handle exists but has no texture');
				}
			} else {
				trace('NoteskinManager.init: parked "$skinName" (over $MAX_CACHED_NOTESKINS cap)');
			}
			currentLoadedNoteskins.set(skinName, handle);
		}

		var skinLen = currentLoadedNoteskins.keys.length;
		var cachedLen = textureCache != null ? textureCache.length : 0;
		trace('NoteskinManager.init: $skinLen skin(s) — $cachedLen cached, ${skinLen - cachedLen} parked');

		trace('NoteskinManager.init: per-skin summary:');
		for (name in currentLoadedNoteskins.keys) {
			var h = currentLoadedNoteskins.get(name);
			if (h != null) {
				trace('  "$name" -> texUnit=${h.texUnit}, loaded=${h.loaded}, key="${h.textureKey}"');
			}
		}
	}

	/** Append a Texture to textureCache and return its index (the handle's texUnit). **/
	static function registerTexture(texture:Texture):Int {
		if (textureCache == null)
			textureCache = [];
		textureCache.push(texture);
		return textureCache.length - 1;
	}

	/** Get a loaded handle by name. Returns null if not found. Parked skins
		return with loaded=false — caller should check before binding. **/
	static function get(skinName:String):NoteskinHandle {
		var handle = currentLoadedNoteskins.get(skinName);
		if (handle == null)
			return null;

		if (!handle.loaded) {
			trace('NoteskinManager.get: "$skinName" is parked — loaded=false, texUnit falls back to 0');
		}
		return handle;
	}

	/** Free every cached texture via TextureSystem.disposeTexture and clear all state. **/
	static function disposeAll() {
		if (currentLoadedNoteskins != null) {
			for (name in currentLoadedNoteskins.keys) {
				var handle = currentLoadedNoteskins.get(name);
				if (handle != null && handle.loaded && handle.textureKey != null && handle.textureKey != "") {
					try {
						TextureSystem.disposeTexture(handle.textureKey);
					} catch (e) {}
					handle.dispose();
				}
			}
		}
		textureCache = null;
		currentLoadedNoteskins = new FakeStringMap<NoteskinHandle>();
		trace('NoteskinManager.disposeAll: dropped all skins + textures + textureCache');
	}

	/** Dispose a single skin. Does NOT remove the slot from textureCache (would
		shift other handles' texUnit); just frees GPU memory and marks unloaded. **/
	static function disposeSkin(skinName:String) {
		var handle = currentLoadedNoteskins.get(skinName);
		if (handle == null)
			return;

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

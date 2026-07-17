package structures.gameplay;

import haxe.Json;
import sys.io.File;
import sys.FileSystem;

using StringTools;

/**
    Noteskin manager class.
    Each noteskin handle is stored in a string map that can load them
    on runtime automatically. The manager calls loadTexture() on each
    handle after creation so the texture is ready for use.

    Call dispose() on individual handles (or disposeAll()) to free
    their textures when no longer needed.
**/
@:publicFields
class NoteskinManager {
    static var currentLoadedNoteskins:FakeStringMap<NoteskinHandle> = new FakeStringMap<NoteskinHandle>();

    static function init() {
        var skinFolder = Paths.asset('assets/images/noteskins');
        var skinFolderFolders = FileSystem.readDirectory(skinFolder);
        for (dir in skinFolderFolders) {
            var subfolder = '$skinFolder/$dir';
            trace(subfolder);
            if (subfolder.endsWith(".png") || subfolder.endsWith(".xml") || subfolder.endsWith(".txt")) continue;
            var folderFiles = FileSystem.readDirectory(subfolder);
            if (folderFiles.contains("data.json")) {
                var noteskinName = dir;
                var handle = new NoteskinHandle(noteskinName);
                handle.loadTexture();
                currentLoadedNoteskins.set(noteskinName, handle);
            }
        }
        var skinLen = currentLoadedNoteskins.keys.length;
        trace('NoteskinManager: initialized with ${skinLen} skin' + (skinLen >= 2 ? "s" : ''));
    }

    /** Get a loaded noteskin handle by name. Returns null if not found. */
    inline static function get(skinName:String):NoteskinHandle {
        return currentLoadedNoteskins.get(skinName);
    }

    /** Dispose all loaded noteskin handles, freeing their textures. */
    static function disposeAll() {
        for (name in currentLoadedNoteskins.keys) {
            var handle = currentLoadedNoteskins.get(name);
            if (handle != null) {
                handle.dispose();
            }
        }
        currentLoadedNoteskins = new FakeStringMap<NoteskinHandle>();
        trace('NoteskinManager: disposed all skins');
    }

    /** Dispose a single noteskin handle by name. */
    static function disposeSkin(skinName:String) {
        var handle = currentLoadedNoteskins.get(skinName);
        if (handle != null) {
            handle.dispose();
        }
    }
}
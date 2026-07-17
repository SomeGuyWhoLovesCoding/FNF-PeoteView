package structures.gameplay;

import haxe.Json;
import sys.io.File;
import sys.FileSystem;

/**
    Noteskin amanger class.
    Each noteskin handle is passed on by a string map that can load them on runtime automatically.
**/
@:publicFields
class NoteskinManager {
    static var currentLoadedNoteskins:FakeStringMap<NoteskinHandle> = new FakeStringMap<NoteskinHandle>();

    static function init() {
        var skinFolder = Paths.asset('assets/images/noteskins');
        var skinFolderFolders = FileSystem.readDirectory(skinFolder);
        for (dir in skinFolderFolders) {
            var folderFiles = FileSystem.readDirectory(dir);
            if (folderFiles.contains("data.json")) {
                var noteskinName = dir.split("/")[0];
                currentLoadedNoteskins.set(noteskinName, new NoteskinHandle(noteskinName));
            }
        }
        trace('placeholder - init with folders:' + skinFolderFolders);
    }

    inline static function getNoteskinFromName(skin:String) {
        return currentLoadedNoteskins.get(skin);
    }
}
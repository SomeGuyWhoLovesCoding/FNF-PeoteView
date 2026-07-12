package structures;

import data.SaveData;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/**
	Noteskin editor debug that's accessed from Main Menu (Debug Keybind).
	Shows a live strumline preview via `NoteSystem.notesBuf` and exposes per-index clip/offset editing.
	@since 0.94
**/
@:publicFields
class NoteskinEditor {
	var roof(default, null):CustomDisplay;
	var display(default, null):CustomDisplay;
	var view(default, null):CustomDisplay;

	function new() {
		
	}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		this.roof = roof;
		this.display = display;
		this.view = view;

        // buncha bullshit you have to do, yada yada yada...
        // sigh
    }

    function dispose() {
        
    }
}

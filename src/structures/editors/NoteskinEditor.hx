package structures.editors;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import structures.editors.noteskin.NoteskinEditorState;

/**
    Noteskin editor debug that's accessed from Main Menu (Debug Keybind).
    Shows a live strumline preview via `NoteSystem.notesBuf` and exposes per-index clip/offset editing.
    Also shows a grid for visual reference of how the strumline would look ingame for clip.

    This class is a thin facade around `NoteskinEditorState`, which in turn is
    backed by the helper modules in `structures.editors.noteskin`:
    - `NoteskinEditorManiaManager`   — noteskin loading + mania config CRUD
    - `NoteskinEditorRenderer`       — grid, textures, receptors, visual updates
    - `NoteskinEditorClipEditor`     — clip lookup, value editing, mode toggling
    - `NoteskinEditorInputHandler`   — keyboard / mouse events, drag logic
    - `NoteskinEditorUI`             — instructions text + create-mania popup

    Existing call sites (`new NoteskinEditor()`, `editor.init(...)`,
    `editor.update(dt)`, `editor.handleKeyDown(...)`, etc.) keep working
    unchanged — every public method is forwarded to the underlying state.
    Direct field access previously available via `@:publicFields` is reachable
    through `editor.state.*` (and `editor.state.<helper>.*` for sub-modules).

    @since 0.94
**/
class NoteskinEditor {
    /**
        The underlying state object. Exposed (read-only) so external code that
        previously read fields like `editor.disposed`, `editor.display`, or
        `editor.showEditor` can still reach them via `editor.state.*`.
    **/
    public var state(default, null):NoteskinEditorState;

    public var disposed:Bool;

    public function new() {
        state = new NoteskinEditorState();
    }

    public function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
        disposed = false;
        state.init(roof, display, view);
    }

    public function toggleEditor() {
        state.toggleEditor();
    }

    public function dispose() {
        state.dispose();
        disposed = true;
    }

    public function show() {
        state.show();
    }

    public function hide() {
        state.hide();
    }

    public function update(deltaTime:Float) {
        state.update(deltaTime);
    }

    public function handleKeyDown(key:KeyCode, modifier:KeyModifier) {
        state.inputHandler.handleKeyDown(key, modifier);
    }
}

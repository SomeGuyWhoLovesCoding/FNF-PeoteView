package structures.editors.noteskin;

import lime.ui.MouseCursor;
import lime.app.Application;
import structures.gameplay.NoteskinHandle.NoteskinData;
import structures.gameplay.NoteskinHandle.NoteskinConfig;

/**
    Noteskin editor debug that's accessed from Main Menu (Debug Keybind).
    Shows a live strumline preview via `NoteSystem.notesBuf` and exposes per-index clip/offset editing.
    Also shows a grid for visual reference of how the strumline would look ingame for clip.
    @since 0.94
**/
@:publicFields
class NoteskinEditorState {
    var disposed(default, null):Bool;

    var roof(default, null):CustomDisplay;
    var display(default, null):CustomDisplay;
    var view(default, null):CustomDisplay;

    // Helper instances
    var clipEditor:NoteskinEditorClipEditor;
    var inputHandler:NoteskinEditorInputHandler;
    var maniaManager:NoteskinEditorManiaManager;
    var renderer:NoteskinEditorRenderer;
    var ui:NoteskinEditorUI;

    // Editor state
    var currentManiaIndex:Int = 0; // Which mania config we're viewing
    var availableManiaConfigs:Array<NoteskinConfig> = []; // All mania configs from the noteskin
    var createManiaPopupActive:Bool = false;
    var createManiaInput:String = "";
    var createManiaError:String = "";
    var createManiaKeyCount:Int = 0;
    var currentState:EditState = IDLE;
    var currentReceptorIndex:Int = 0;
    var currentLane:Int = 0;
    var selectedIndex:Int = 0;
    var maxReceptors:Int = 4; // Default mania 4
    var editMode:EditMode = CLIP_POS;
    var isCtrlPressed:Bool = false;
    var isShiftPressed:Bool = false;
    var isAltPressed:Bool = false;
    var globalScaleMode:Bool = false; // false = offset, true = scale

    // Noteskin data
    var noteskinHandle:NoteskinHandle;
    var noteskinData:NoteskinData;
    var currentConfig:NoteskinConfig;
    var currentSkinName:String = "default";

    // Rendering
    var noteBuf:Buffer<Note>;
    var noteProg:CustomProgram;
    var texture:Texture;

    // Grid overlay
    var gridBuf:Buffer<RepeatSprite>;
    var gridProg:CustomProgram;
    var gridSprites:Array<RepeatSprite> = [];

    // Receptor preview
    var receptorSprites:Array<Note> = [];

    // UI state
    var showEditor:Bool = false;
    var selectedProperty:String = "clipX";
    var propertyValue:Int = 0;
    var editingValue:Bool = false;
    var needsRender:Bool = false;
    var popupBackground:RepeatSprite = null;

    // Mouse state
    var isDragging:Bool = false;
    var dragStartX:Float = 0;
    var dragStartY:Float = 0;
    var lastDragX:Float = 0;
    var lastDragY:Float = 0;
    var dragStartClipX:Int = 0;
    var dragStartClipY:Int = 0;
    var dragStartClipW:Int = 0;
    var dragStartClipH:Int = 0;
    var dragStartOffsX:Int = 0;
    var dragStartOffsY:Int = 0;
    var dragMode:Int = 0; // 0 = move (clipX/Y), 1 = resize right (clipW), 2 = resize bottom (clipH), 3 = resize corner (clipW/H), 4 = offset X, 5 = offset Y, 6 = offset both

    // Long press state for spritesheet mode
    var isHoldingMouse:Bool = false;
    var isLongPress:Bool = false;
    var longPressTimer:Float = 0;
    var longPressThreshold:Float = 400; // milliseconds
    var mouseDownX:Float = 0;
    var mouseDownY:Float = 0;
    var spriteSheetMode:Bool = false;
    var longPressTriggered:Bool = false;
    var spritesheetSelectedIndex:Int = -1;

    // Spritesheet view offset (extra space above to see what's outside)
    static inline var SPRITESHEET_VIEW_OFFSET:Int = 300;

    // Texture name constants
    static inline var NOTESKIN_TEXTURE_NAME:String = "noteskinTexV2";
    static inline var GRID_TEXTURE_NAME:String = "gridTexV2";

    // Instructions text
    var instructionsText:Text;

    public function new() {
        // Create helper instances (order matters: state refs are set, but they
        // don't do any work in their constructors)
        maniaManager = new NoteskinEditorManiaManager(this);
        renderer = new NoteskinEditorRenderer(this);
        clipEditor = new NoteskinEditorClipEditor(this);
        ui = new NoteskinEditorUI(this);
        inputHandler = new NoteskinEditorInputHandler(this);

        // Default noteskin
        maniaManager.loadNoteskin("default");
    }

    public function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
        disposed = false;

        this.roof = roof;
        this.display = display;
        this.view = view;

        renderer.createGrid();
        renderer.initRendering();
        renderer.createReceptors();

        // Initialize instructions text AFTER display is set
        ui.initInstructionsText();

        show();

        inputHandler.addEvents();
    }

    public function toggleEditor() {
        showEditor = !showEditor;
        if (showEditor) {
            if (texture == null) {
                texture = renderer.getCombinedNoteskinTexture();
                if (noteProg != null) {
                    noteProg.setTexture(texture, NOTESKIN_TEXTURE_NAME, true);
                }
            }

            if (gridProg != null && !gridProg.isIn(view)) {
                view.addProgram(gridProg);
            }

            if (noteProg != null && !noteProg.isIn(view)) {
                view.addProgram(noteProg);
            }

            spriteSheetMode = false;
            spritesheetSelectedIndex = -1;
            renderer.updateReceptorVisuals();

            if (instructionsText != null) {
                instructionsText.alpha = 1;
                ui.updateInstructionsText();
            }

            trace('Noteskin Editor opened');
        } else {
            if (noteProg != null && noteProg.isIn(view)) {
                view.removeProgram(noteProg);
            }
            if (gridProg != null && gridProg.isIn(view)) {
                view.removeProgram(gridProg);
            }

            if (instructionsText != null) {
                instructionsText.alpha = 0;
            }

            inputHandler.setCursor(MouseCursor.ARROW);
            isDragging = false;
            isHoldingMouse = false;
            isLongPress = false;
            longPressTriggered = false;
            spriteSheetMode = false;
            spritesheetSelectedIndex = -1;

            trace('Noteskin Editor closed');
        }
    }

    public function dispose() {
        inputHandler.removeEvents();

        if (showEditor) toggleEditor();

        // Remove popup background if it exists
        if (popupBackground != null) {
            gridBuf.removeElement(popupBackground);
            popupBackground = null;
        }

        if (noteProg != null && noteProg.isIn(display)) {
            display.removeProgram(noteProg);
        }

        if (gridProg != null && gridProg.isIn(display)) {
            display.removeProgram(gridProg);
        }

        if (noteBuf != null) {
            noteBuf.clear();
            noteBuf = null;
        }

        if (gridBuf != null) {
            gridBuf.clear();
            gridBuf = null;
        }

        if (receptorSprites != null) {
            for (note in receptorSprites) {
                note = null;
            }
            receptorSprites = null;
        }

        if (gridSprites != null) {
            for (sprite in gridSprites) {
                sprite = null;
            }
            gridSprites = null;
        }

        if (instructionsText != null) {
            instructionsText.removeProgram();
            instructionsText = null;
        }

        display = null;
        view = null;
        roof = null;

        disposed = true;
    }

    public function show() {
        if (!showEditor) toggleEditor();
    }

    public function hide() {
        if (showEditor) toggleEditor();
    }

    public function update(deltaTime:Float) {
        // Render create mania popup if active
        if (createManiaPopupActive) {
            ui.renderCreateManiaPopup();
            return;
        }

        // Check for long press in the update loop
        if (isHoldingMouse && !longPressTriggered && !isDragging) {
            longPressTimer += deltaTime;
            if (longPressTimer >= longPressThreshold) {
                // Long press detected
                longPressTriggered = true;
                isHoldingMouse = false;

                if (spriteSheetMode) {
                    // EXIT spritesheet mode
                    spriteSheetMode = false;
                    spritesheetSelectedIndex = -1;
                    trace('Spritesheet mode disabled - returning to normal view');
                    // Reset cursor
                    inputHandler.setCursor(MouseCursor.ARROW);
                    // Update visuals
                    renderer.updateReceptorVisuals();
                    ui.updateInstructionsText();
                } else {
                    // ENTER spritesheet mode
                    clipEditor.toggleSpritesheetMode();
                }
            }
        }
    }
}

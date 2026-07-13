package structures.editors.noteskin;

import structures.gameplay.NoteskinHandle.BasicNoteskinClip;

@:publicFields
class NoteskinEditorUI {
    var state:NoteskinEditorState;

    public function new(state:NoteskinEditorState) {
        this.state = state;
    }

    function initInstructionsText() {
        if (state.instructionsText == null) {
            var markers = [
                new TextFormatMarkerPair('#M1#', Color.CYAN),
                new TextFormatMarkerPair('#M2#', 0xFFFF5353),
                new TextFormatMarkerPair('#M3#', 0xFF53FF53),
                new TextFormatMarkerPair('#M4#', 0xFF5353FF),
                new TextFormatMarkerPair('#M5#', Color.YELLOW),
                new TextFormatMarkerPair('#M6#', 0xFFFF9933), // Orange for edit mode
                new TextFormatMarkerPair('#M7#', 0xFFFF33FF), // Pink for offset mode
                new TextFormatMarkerPair('#M8#', 0xFF33FF33), // Green for clip index mode
                new TextFormatMarkerPair('#M9#', 0xFFFF00FF) // Magenta for spritesheet mode
            ];

            // Create text with the display
            state.instructionsText = new Text("NOTESKIN_EDITOR_INSTRUCTIONS", 4, 3, state.display, "", "vcr");
            state.instructionsText.scale = 0.7;
            state.instructionsText.alpha = 0; // Start hidden
            state.instructionsText.multiline = true;
            state.instructionsText.alignment = RIGHT;
            state.instructionsText.spacerPercent = -0.1;
            state.instructionsText.outlineColor = Color.BLACK;
            state.instructionsText.outlineSize = 1;
            state.instructionsText.setMarkerPairs(markers);

            // Set initial text
            state.instructionsText.text = buildInstructionsText();

            // Position at top-right
            positionInstructionsTextTopRight();

            // Add to display immediately (but keep alpha 0 so it's hidden)
            state.instructionsText.addProgram();
        }
    }

    function buildInstructionsText():String {
        if (state.createManiaPopupActive) return "";

        var stateName = state.clipEditor.getStateName(state.currentState);
        var stateColor = switch(state.currentState) {
            case IDLE: "#M1#";
            case NOTE: "#M2#";
            case PRESS: "#M3#";
            case CONFIRM: "#M4#";
            default: "";
        };

        var clip = state.clipEditor.getClipForIndex(state.selectedIndex);
        var basicClip:BasicNoteskinClip = state.clipEditor.getBasicClipForState(clip, state.currentState);
        var currentValue = state.clipEditor.getClipValue(basicClip);

        var editModeName = state.clipEditor.getEditModeName(state.editMode);
        var editModeColor = state.clipEditor.getEditModeColor(state.editMode);

        var spritesheetText = state.spriteSheetMode ?
            "#M9#[SPRITESHEET MODE - Mouse only!]\n" +
            "Drag to pan view | Press ESC or Hold click to exit#M9#\n" :
            "";

        var maniaText = 'Mania: #M5#[${state.currentManiaIndex + 1}/${state.availableManiaConfigs.length + 1} - ${state.maxReceptors}K]#M5#\n';
        var gapText = 'Gap: #M5#[${state.currentConfig.gap}]#M5#\n';

        var globalText = "";
        if (state.editMode == GLOBAL_TRANSFORM) {
            var modeName = state.globalScaleMode ? "Scale" : "Offset";
            var modeColor = state.globalScaleMode ? "#M4#" : "#M6#";
            globalText = 'Global Transform: ${modeColor}$modeName${modeColor}\n';
            if (state.globalScaleMode) {
                globalText += '#M5#Scale: ${Math.round(state.currentConfig.scale * 100) / 100}#M5#\n';
            } else {
                globalText += '#M5#Offset X: ${state.currentConfig.offsetX}, Y: ${state.currentConfig.offsetY}#M5#\n';
            }
            globalText += "#M1#CTRL+SPACE: Toggle Offset/Scale#M1#\n";
        }

        return
            "NOTESKIN EDITOR INSTRUCTIONS:\n" +
            (!state.spriteSheetMode ? "TAB or Mouse Wheel: Cycle animation state (SHIFT+TAB to go backwards)\n" : "") +
            "CTRL+TAB: Toggle edit mode\n" +
            "SHIFT+CTRL+TAB: Switch mania\n" +
            "CTRL+SHIFT+SPACE: Create new mania\n" +
            "ALT+LEFT/RIGHT or ALT+MouseWheel: Adjust gap\n" +
            "CTRL+ALT+LEFT/RIGHT or CTRL+ALT+MouseWheel: Adjust gap (10x)\n" +
            (!state.spriteSheetMode && state.editMode == GLOBAL_TRANSFORM ?
                "Arrow Keys: Adjust Offset/Scale\n" :
                (state.spriteSheetMode ? "Arrow Keys or TAB: Switch receptor index\n" :
                "Arrow Keys: Edit X/Y values\n")) +
            "CTRL+Arrow Keys: Adjust value (+10)\n" +
            (!state.spriteSheetMode && state.editMode != GLOBAL_TRANSFORM ? "SHIFT+LEFT/RIGHT: Switch receptor index\n" : "") +
            (!state.spriteSheetMode && state.editMode == GLOBAL_TRANSFORM ? "LEFT/RIGHT: Adjust offset/scale\n" : "") +
            "Hold Click: Toggle spritesheet view\n" +
            "Mouse Drag: Modify current properties\n" +
            "ESC: Close editor\n" +
            (state.spriteSheetMode ? "#M9#[SPRITESHEET MODE - Mouse only!]\n" +
            "Drag to pan view | Press ESC or hold click to exit#M9#\n" :
            "") +
            maniaText +
            gapText +
            globalText +
            'Current State: ${stateColor}${stateName}${stateColor}\n' +
            'Selected Receptor: #M5#[${state.selectedIndex + 1}/${state.maxReceptors}]#M5#' +
            (state.editMode != GLOBAL_TRANSFORM ? '\nEdit Mode: ${editModeColor}${editModeName}${editModeColor}' : '');
    }

    function updateInstructionsText() {
        if (state.instructionsText != null && state.showEditor) {
            // If popup is active, don't update with normal instructions
            if (state.createManiaPopupActive) return;

            var newText = buildInstructionsText();
            if (state.instructionsText.text != newText) {
                state.instructionsText.text = newText;
            }
            state.instructionsText.scale = 0.7;
            positionInstructionsTextTopRight();
            state.instructionsText.alpha = 1;
        }
    }

    function positionInstructionsTextTopRight() {
        state.instructionsText.y = 4;
        state.instructionsText.x = Main.INITIAL_WIDTH - (state.instructionsText.width + 4);
    }

    function renderCreateManiaPopup() {
        if (!state.createManiaPopupActive || state.instructionsText == null) return;

        // Create or update popup background
        if (state.popupBackground == null) {
            state.popupBackground = new RepeatSprite(0, 0, 0, 0);
            state.popupBackground.c = 0x000000FF; // Black
            state.popupBackground.c.aF = 0.6; // 60% opacity
            state.gridBuf.addElement(state.popupBackground);
        }

        // Build popup text
        var popupText =
            "    #M6#=== CREATE NEW MANIA ===#M6#\n" +
            "How many keys this time?\n" +
            "(Enter a number 1-64)\n\n" +
            '#M5#Keys: ${state.createManiaInput}#M5#\n';

        if (state.createManiaError != "") {
            popupText += '#M2#${state.createManiaError}#M2#\n';
        }

        popupText +=
            "\n#M1#[ENTER] Confirm#M1#   #M3#[ESC] Cancel#M3#";

        // Update instructions text
        state.instructionsText.text = popupText;
        state.instructionsText.alignment = LEFT;
        state.instructionsText.scale = 1.2;
        state.instructionsText.alpha = 1;

        // Force the text to recalculate its dimensions by calling update
        // This ensures width/height are correct before positioning
        state.instructionsText.refresh();

        // Center the text on screen
        state.instructionsText.x = (Main.INITIAL_WIDTH - state.instructionsText.width) / 2;
        state.instructionsText.y = (Main.INITIAL_HEIGHT - state.instructionsText.height) / 2;

        // Update popup background to match instructions text bounds
        var padding = 20;
        state.popupBackground.x = Std.int(state.instructionsText.x - padding);
        state.popupBackground.y = Std.int(state.instructionsText.y - padding);
        state.popupBackground.w = Std.int(state.instructionsText.width + padding * 2);
        state.popupBackground.h = Std.int(state.instructionsText.height + padding * 2);
        state.gridBuf.updateElement(state.popupBackground);
        state.gridBuf.update();
    }
}

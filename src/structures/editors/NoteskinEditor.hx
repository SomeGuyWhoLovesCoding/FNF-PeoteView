package structures.editors;

// ============================================================================
// Imports
// ============================================================================

// Standard library
import haxe.Json;
import sys.io.File as Sys_Fili;
import sys.FileSystem;

// Lime
import lime.app.Application;
import lime.graphics.Image;
import lime.math.Rectangle;
import lime.math.Vector2;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseCursor;
import lime.ui.MouseWheelMode;

// Project
import structures.gameplay.NoteskinHandle;
import structures.gameplay.NoteskinHandle.BasicNoteskinClip;
import structures.gameplay.NoteskinHandle.NoteskinConfig;
import structures.gameplay.NoteskinHandle.NoteskinData;
import structures.gameplay.NoteskinHandle.NoteskinReceptorProperties;

// ============================================================================
// Enums
// ============================================================================

private enum abstract EditState(Int) from Int to Int {
    var IDLE;
    var COLOR;
    var PRESS;
    var CONFIRM;
}

private enum abstract EditMode(Int) from Int to Int {
    var CLIP_POS;
    var CLIP_SIZE;
    var OFFSET;
    var CLIP_ID;
    var GLOBAL_TRANSFORM;
}

// ============================================================================
// Clip Editor — per-clip value editing, selection, and spritesheet toggling
// ============================================================================

@:publicFields
private class NoteskinEditorClipEditor {
    private inline static var MAX_KEYS = 64;

    var state:NoteskinEditor;

    public function new(state:NoteskinEditor) {
        this.state = state;
    }

    /** Shared default receptor properties. Used everywhere a placeholder clip is needed. */
    static function defaultClip():NoteskinReceptorProperties {
        return {
            idle:     {clipX: 3,   clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            press:    {clipX: 115, clipY: 229, clipW: 99,  clipH: 100, offsX: 0, offsY: 0},
            color:    {clipX: 3,   clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            confirm:  {clipX: 3,   clipY: 3,   clipW: 240, clipH: 243, offsX: 0, offsY: 0},
            holdBody: {clipX: 441, clipY: 229, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
            holdTail: {clipX: 460, clipY: 3,   clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
        };
    }

    function getBasicClipForState(clip:NoteskinReceptorProperties, editState:EditState):BasicNoteskinClip {
        return switch(editState) {
            case IDLE:    clip.idle;
            case COLOR:   clip.color;
            case PRESS:   clip.press;
            case CONFIRM: clip.confirm;
            default:      clip.idle;
        }
    }

    function getClipIndexForReceptor(index:Int):Int {
        if (state.currentConfig.indexes != null && index < state.currentConfig.indexes.length) {
            return state.currentConfig.indexes[index];
        }
        return index;
    }

    function getClipForIndex(index:Int):NoteskinReceptorProperties {
        var clips = state.noteskinData.clip;
        if (clips != null && index < clips.length) {
            return clips[index];
        }
        return defaultClip();
    }

    function updateClipInConfig(index:Int, editState:EditState, clip:BasicNoteskinClip) {
        var clips = state.noteskinData.clip;
        if (clips != null && index < clips.length) {
            var currentClip = clips[index];
            switch(editState) {
                case IDLE:    currentClip.idle = clip;
                case COLOR:   currentClip.color = clip;
                case PRESS:   currentClip.press = clip;
                case CONFIRM: currentClip.confirm = clip;
                default:
            }
        }
    }

    function getClipValue(clip:BasicNoteskinClip):Int {
        switch(state.selectedProperty) {
            case "clipX": return clip.clipX;
            case "clipY": return clip.clipY;
            case "clipW": return clip.clipW;
            case "clipH": return clip.clipH;
            case "offsX": return clip.offsX;
            case "offsY": return clip.offsY;
            case "clipIndex":
                if (state.currentConfig.indexes != null && state.selectedIndex < state.currentConfig.indexes.length) {
                    return state.currentConfig.indexes[state.selectedIndex];
                }
                return state.selectedIndex;
            default: return 0;
        }
    }

    function adjustSelectedValue(amount:Int) {
        if (state.spriteSheetMode) return;

        // Disallow clipIndex edits while in preview-clips mania — would produce garbage renders.
        if (state.selectedProperty == "clipIndex"
            && state.currentManiaIndex >= state.availableManiaConfigs.length) {
            trace('CLIPINDEX: Please back out of preview clip mania first, so that way you don\'t get a garbage render from it.');
            return;
        }

        var clipIndex = getClipIndexForReceptor(state.selectedIndex);
        var clip = getClipForIndex(clipIndex);
        var basicClip = getBasicClipForState(clip, state.currentState);

        var isClipIndexProperty = false;

        switch(state.selectedProperty) {
            case "clipX": basicClip.clipX -= amount;
            case "clipY": basicClip.clipY -= amount;
            case "clipW": basicClip.clipW += amount;
            case "clipH": basicClip.clipH += amount;
            case "offsX": basicClip.offsX += amount;
            case "offsY": basicClip.offsY += amount;
            case "clipIndex":
                isClipIndexProperty = true;
                if (state.currentConfig.indexes == null) {
                    state.currentConfig.indexes = [];
                }
                while (state.currentConfig.indexes.length <= state.selectedIndex) {
                    state.currentConfig.indexes.push(state.currentConfig.indexes.length);
                }
                if (state.currentConfig.indexes[state.selectedIndex] + amount >= MAX_KEYS) {
                    state.currentConfig.indexes[state.selectedIndex] = MAX_KEYS - 1;
                    trace('CLIPINDEX: Max indexes reached. (attempted $MAX_KEYS+1)');
                    return;
                }
                state.currentConfig.indexes[state.selectedIndex] += amount;
                if (state.currentConfig.indexes[state.selectedIndex] < 0) {
                    state.currentConfig.indexes[state.selectedIndex] = 0;
                }
                // Auto-create new clips if the index exceeds the current clip count.
                while (state.noteskinData.clip.length <= state.currentConfig.indexes[state.selectedIndex]
                       && state.noteskinData.clip.length < MAX_KEYS) {
                    state.noteskinData.clip.push(defaultClip());
                    trace('Created new clip at index ${state.noteskinData.clip.length - 1}');
                }
                // Update maxReceptors if we're in preview mode.
                if (state.currentManiaIndex == state.availableManiaConfigs.length) {
                    state.maxReceptors = state.noteskinData.clip.length;
                    state.currentConfig.indexes = [for (i in 0...state.noteskinData.clip.length) i];
                }
            default: state.selectedProperty = "clipX";
        }

        if (!isClipIndexProperty) {
            var currentClipIndex = getClipIndexForReceptor(state.selectedIndex);
            updateClipInConfig(currentClipIndex, state.currentState, basicClip);
        }

        state.renderer.updateReceptorVisuals();

        trace('${getStateName(state.currentState)}.${state.selectedProperty} = ${getClipValue(basicClip)}');
        state.ui.updateInstructionsText();
    }

    function toggleProperty() {
        if (state.spriteSheetMode) return;
        var properties = getPropertiesForMode(state.editMode);
        var currentIndex = properties.indexOf(state.selectedProperty);
        state.selectedProperty = properties[(currentIndex + 1) % properties.length];
        trace('Editing property: ${state.selectedProperty}');
        state.ui.updateInstructionsText();
    }

    function getPropertiesForMode(mode:EditMode):Array<String> {
        return switch(mode) {
            case CLIP_POS: ["clipX", "clipY"];
            case CLIP_SIZE: ["clipW", "clipH"];
            case OFFSET: ["offsX", "offsY"];
            case CLIP_ID: ["clipIndex"];
            default: ["clipX", "clipY"];
        }
    }

    function adjustAxisValue(amount:Int, axis:String) {
        if (state.spriteSheetMode) return;

        var propertyToEdit:String;

        switch(state.editMode) {
            case CLIP_POS:  propertyToEdit = axis == "X" ? "clipX" : "clipY";
            case CLIP_SIZE: propertyToEdit = axis == "X" ? "clipW" : "clipH";
            case OFFSET:    propertyToEdit = axis == "X" ? "offsX" : "offsY";
            case CLIP_ID:
                state.selectedProperty = "clipIndex";
                adjustSelectedValue(amount);
                return;
            default: return;
        }

        state.selectedProperty = propertyToEdit;
        adjustSelectedValue(amount);
    }

    function toggleAxisProperty() {
        if (state.spriteSheetMode) return;

        var properties = getPropertiesForMode(state.editMode);
        if (properties.length <= 1) return;

        var currentAxis = state.selectedProperty.charAt(state.selectedProperty.length - 1);
        var newAxis = currentAxis == "X" ? "Y" : "X";
        var baseName = state.selectedProperty.substring(0, state.selectedProperty.length - 1);
        var newProperty = baseName + newAxis;

        if (properties.indexOf(newProperty) != -1) {
            state.selectedProperty = newProperty;
        } else {
            state.selectedProperty = properties[0];
        }

        trace('Editing property: ${state.selectedProperty}');
        state.ui.updateInstructionsText();
    }

    function selectNextIndex() {
        state.selectedIndex = (state.selectedIndex + 1) % state.maxReceptors;
        if (state.spriteSheetMode) {
            state.spritesheetSelectedIndex = state.selectedIndex;
        }
        state.renderer.updateReceptorVisuals();
        state.ui.updateInstructionsText();
    }

    function selectPreviousIndex() {
        state.selectedIndex = (state.selectedIndex - 1 + state.maxReceptors) % state.maxReceptors;
        if (state.spriteSheetMode) {
            state.spritesheetSelectedIndex = state.selectedIndex;
        }
        state.renderer.updateReceptorVisuals();
        state.ui.updateInstructionsText();
    }

    function toggleState(increment:Int) {
        if (state.spriteSheetMode) {
            // In spritesheet mode, TAB controls the selected receptor index instead.
            if (increment > 0) selectNextIndex();
            else                selectPreviousIndex();
            return;
        }
        var newState:Int = state.currentState + increment;
        if (newState < 0) newState = 3;
        if (newState >= 4) newState = 0;
        state.renderer.updateReceptorState(newState);
        trace('State changed to: ${getStateName(state.currentState)}');
    }

    function getStateName(editState:EditState):String {
        return switch(editState) {
            case IDLE:    "IDLE";
            case COLOR:   "COLOR";
            case PRESS:   "PRESS";
            case CONFIRM: "CONFIRM";
            default:      "unknown";
        }
    }

    function toggleEditMode() {
        if (state.spriteSheetMode) return;

        state.editMode = (state.editMode + 1) % 5;

        // Reset global transform sub-mode when leaving GLOBAL_TRANSFORM.
        if (state.editMode != GLOBAL_TRANSFORM) {
            state.globalScaleMode = false;
        }

        checkInvalidClipIDPlace();

        switch(state.editMode) {
            case CLIP_POS:
                if (state.selectedProperty == "clipW" || state.selectedProperty == "clipH"
                    || state.selectedProperty == "offsX" || state.selectedProperty == "offsY"
                    || state.selectedProperty == "clipIndex") state.selectedProperty = "clipX";
            case CLIP_SIZE:
                if (state.selectedProperty == "clipX" || state.selectedProperty == "clipY"
                    || state.selectedProperty == "offsX" || state.selectedProperty == "offsY"
                    || state.selectedProperty == "clipIndex") state.selectedProperty = "clipW";
            case OFFSET:
                if (state.selectedProperty == "clipX" || state.selectedProperty == "clipY"
                    || state.selectedProperty == "clipW" || state.selectedProperty == "clipH"
                    || state.selectedProperty == "clipIndex") state.selectedProperty = "offsX";
            case CLIP_ID:
                if (state.selectedProperty == "clipX" || state.selectedProperty == "clipY"
                    || state.selectedProperty == "clipW" || state.selectedProperty == "clipH"
                    || state.selectedProperty == "offsX" || state.selectedProperty == "offsY") state.selectedProperty = "clipIndex";
            case GLOBAL_TRANSFORM:
                state.selectedProperty = "global";
        }
        trace('Edit mode: ${getEditModeName(state.editMode)}');
        state.ui.updateInstructionsText();
    }

    function checkInvalidClipIDPlace() {
        // Bump out of CLIP_ID when entering preview-clips mania — would render garbage data.
        if (state.editMode == CLIP_ID && state.currentManiaIndex >= state.availableManiaConfigs.length) {
            trace('CLIPINDEX: Please back out of preview clip mania first for this mode, that way you don\'t render garbage data.');
            state.editMode++;

            // Only ever fires CLIP_ID -> GLOBAL_TRANSFORM, so sync the per-mode state
            // to match what `toggleEditMode` would have done. Without this, calling
            // `checkInvalidClipIDPlace()` standalone (e.g. right after `switchMania`
            // from the input handler) leaves `selectedProperty` stale and never
            // refreshes the on-screen text.
            if (state.editMode == GLOBAL_TRANSFORM) {
                state.selectedProperty = "global";
            }
            state.ui.updateInstructionsText();
        }
    }

    function getEditModeName(mode:EditMode):String {
        return switch(mode) {
            case CLIP_POS:        "Position (clipX/Y)";
            case CLIP_SIZE:       "Size (clipW/H)";
            case OFFSET:          "Offset (offsX/Y)";
            case CLIP_ID:         "Clip Index";
            case GLOBAL_TRANSFORM:"Thanks for playing";
            default:              "Unknown";
        }
    }

    function getEditModeColor(mode:EditMode):String {
        return switch(mode) {
            case CLIP_POS:         "#M6#";
            case CLIP_SIZE:        "#M4#";
            case OFFSET:           "#M7#";
            case CLIP_ID:          "#M8#";
            default:               "#M5#";
        }
    }

    function getSelectedNote():Note {
        return state.receptorSprites[state.selectedIndex];
    }

    function getSelectedClip():BasicNoteskinClip {
        var clipIndex = getClipIndexForReceptor(state.selectedIndex);
        var clip = getClipForIndex(clipIndex);
        return getBasicClipForState(clip, state.currentState);
    }

    /**
        Returns the index of the receptor whose sprite contains the given
        screen coordinates, or -1 if no receptor is hit. Uses the same bounds
        logic as `handleMouseDown` (note.x/y/w/h, no offset).
    **/
    function findReceptorAt(mouseX:Float, mouseY:Float):Int {
        for (i in 0...state.receptorSprites.length) {
            var note = state.receptorSprites[i];
            if (mouseX >= note.x && mouseX <= note.x + note.w
                && mouseY >= note.y && mouseY <= note.y + note.h) {
                return i;
            }
        }
        return -1;
    }

    function toggleSpritesheetMode() {
        state.spriteSheetMode = !state.spriteSheetMode;
        if (state.spriteSheetMode) {
            state.spritesheetSelectedIndex = state.selectedIndex;
            trace('Spritesheet mode enabled - showing full texture for receptor ${state.selectedIndex + 1}');
        } else {
            state.spritesheetSelectedIndex = -1;
            trace('Spritesheet mode disabled - returning to normal view');
            state.inputHandler.setCursor(MouseCursor.ARROW);
        }
        state.renderer.updateReceptorVisuals();
        state.ui.updateInstructionsText();
    }
}

// ============================================================================
// Mania Manager — loading noteskins, switching/creating manias, gap adjusting
// ============================================================================

@:publicFields
private class NoteskinEditorManiaManager {
    var state:NoteskinEditor;

    public function new(state:NoteskinEditor) {
        this.state = state;
    }

    function loadNoteskin(skinName:String) {
        state.currentSkinName = skinName;
        var skinFolder = 'assets/images/noteskins/$skinName';

        try {
            // Create data.json if missing.
            var dataPath = Paths.asset('$skinFolder/data.json');
            if (!FileSystem.exists(dataPath)) {
                createDefaultDataJson(skinFolder);
            }

            state.noteskinHandle = new NoteskinHandle(skinName);
            state.noteskinData = state.noteskinHandle.data;

            // Store all mania configs.
            state.availableManiaConfigs = state.noteskinData.configMania != null
                ? state.noteskinData.configMania.copy()
                : [];

            // Fall back to a default 4K mania if none exist.
            if (state.availableManiaConfigs.length == 0) {
                state.availableManiaConfigs.push({
                    offsetX: 0, offsetY: 0, gap: 112, scale: 1.0, indexes: [0, 1, 2, 3]
                });
            }

            state.currentManiaIndex = 0;
            state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];

            updateMaxReceptorsFromConfig();

            // Ensure we have clips for all receptors.
            var clips = state.noteskinData.clip;
            var numReceptors = clips != null ? clips.length : 0;
            if (numReceptors < state.maxReceptors) {
                while (clips.length < state.maxReceptors) {
                    clips.push(NoteskinEditorClipEditor.defaultClip());
                }
            }

            if (state.selectedIndex >= state.maxReceptors) {
                state.selectedIndex = state.maxReceptors - 1;
            }
        } catch (e) {
            trace('Failed to load noteskin $skinName: $e');
            createDefaultNoteskin();
        }
    }

    function createDefaultDataJson(skinFolder:String) {
        try {
            // Default data.json with 4 receptors using actual texture coords from the XML.
            var defaultData = {
                name: "default",
                sparrowImg: "notes.png",
                configMania: [{
                    offsetX: 0, offsetY: 0, gap: 112, scale: 1.0, indexes: [0, 1, 2, 3]
                }],
                clip: [
                    {
                        idle:     {clipX: 3,   clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        press:    {clipX: 115, clipY: 229, clipW: 99,  clipH: 100, offsX: 0, offsY: 0},
                        color:    {clipX: 3,   clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        confirm:  {clipX: 3,   clipY: 3,   clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 229, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 3,   clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
                    },
                    {
                        idle:     {clipX: 346, clipY: 3,   clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        press:    {clipX: 3,   clipY: 230, clipW: 99,  clipH: 98,  offsX: 0, offsY: 0},
                        color:    {clipX: 346, clipY: 3,   clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        confirm:  {clipX: 246, clipY: 3,   clipW: 189, clipH: 189, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 262, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 51,  clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
                    },
                    {
                        idle:     {clipX: 233, clipY: 3,   clipW: 110, clipH: 111, offsX: 0, offsY: 0},
                        press:    {clipX: 217, clipY: 230, clipW: 97,  clipH: 99,  offsX: 0, offsY: 0},
                        color:    {clipX: 233, clipY: 3,   clipW: 110, clipH: 111, offsX: 0, offsY: 0},
                        confirm:  {clipX: 197, clipY: 249, clipW: 193, clipH: 189, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 295, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 147, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
                    },
                    {
                        idle:     {clipX: 346, clipY: 115, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        press:    {clipX: 337, clipY: 227, clipW: 101, clipH: 99,  offsX: 0, offsY: 0},
                        color:    {clipX: 346, clipY: 115, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        confirm:  {clipX: 3,   clipY: 249, clipW: 191, clipH: 192, offsX: 0, offsY: 0},
                        holdBody: {clipX: 460, clipY: 195, clipW: 35,  clipH: 31,  offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 99,  clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
                    }
                ]
            };

            var jsonStr = Json.stringify(defaultData, null, "  ");
            var dataPath = Paths.asset('$skinFolder/data.json');
            Sys_Fili.saveContent(dataPath, jsonStr);
            trace('Created default data.json at $dataPath');
        } catch (e) {
            trace('Failed to create default data.json: $e');
        }
    }

    function updateMaxReceptorsFromConfig() {
        if (state.currentConfig.indexes != null) {
            state.maxReceptors = state.currentConfig.indexes.length;
            if (state.maxReceptors < 1) {
                state.maxReceptors = 1;
                state.currentConfig.indexes = [0];
            }
        } else {
            state.maxReceptors = 4;
            state.currentConfig.indexes = [0, 1, 2, 3];
        }
    }

    function generateManiaFromClips():NoteskinConfig {
        // Preview mania — one index per clip.
        var clipCount = state.noteskinData.clip != null ? state.noteskinData.clip.length : 0;
        var indexes:Array<Int> = [for (i in 0...clipCount) i];
        return {
            offsetX: 0, offsetY: 0, gap: 114, scale: 1.0, indexes: indexes
        };
    }

    function switchMania(direction:Int) {
        if (state.availableManiaConfigs.length == 0) return;

        var totalManias = state.availableManiaConfigs.length + 1; // +1 for preview mania
        var newIndex = state.currentManiaIndex + direction;
        if (newIndex < 0) newIndex = totalManias - 1;
        if (newIndex >= totalManias) newIndex = 0;

        state.currentManiaIndex = newIndex;

        if (state.currentManiaIndex < state.availableManiaConfigs.length) {
            state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];
        } else {
            state.currentConfig = generateManiaFromClips();
        }

        updateMaxReceptorsFromConfig();

        // Ensure clips exist for all receptors.
        var clips = state.noteskinData.clip;
        while (clips.length < state.maxReceptors) {
            clips.push(NoteskinEditorClipEditor.defaultClip());
        }

        if (state.selectedIndex >= state.maxReceptors) {
            state.selectedIndex = state.maxReceptors - 1;
        }
        if (state.spritesheetSelectedIndex >= state.maxReceptors) {
            state.spritesheetSelectedIndex = state.maxReceptors - 1;
        }

        state.renderer.createReceptors();
        state.renderer.updateReceptorVisuals();
        state.ui.updateInstructionsText();

        var modeName = state.currentManiaIndex >= state.availableManiaConfigs.length
            ? "Preview All Clips"
            : '${state.maxReceptors}K';
        trace('Switched to mania ${state.currentManiaIndex + 1}/${totalManias} - $modeName');
    }

    function createNewMania() {
        state.createManiaPopupActive = true;
        state.createManiaInput = "";
        state.createManiaError = "";
        state.createManiaKeyCount = 0;

        // Remove any stale popup background.
        if (state.popupBackground != null) {
            state.gridBuf.removeElement(state.popupBackground);
            state.popupBackground = null;
        }

        trace('Create Mania popup opened - Enter number of keys');
    }

    function createDefaultNoteskin() {
        state.noteskinData = {
            name: "default",
            sparrowImg: "notes.png",
            configMania: [{
                offsetX: 0, offsetY: 0, gap: 112, scale: 1.0, indexes: [0, 1, 2, 3]
            }],
            clip: []
        };
        state.availableManiaConfigs = state.noteskinData.configMania.copy();
        state.currentManiaIndex = 0;
        state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];
        updateMaxReceptorsFromConfig();

        for (i in 0...state.maxReceptors) {
            state.noteskinData.clip.push(NoteskinEditorClipEditor.defaultClip());
        }
    }

    function confirmCreateMania() {
        var keyCount = Std.parseInt(state.createManiaInput);
        if (keyCount == null || keyCount <= 0 || keyCount > 64) {
            state.createManiaError = "Please enter a valid number between 0 and 64";
            return;
        }

        // Reject duplicates.
        for (config in state.availableManiaConfigs) {
            if (config.indexes != null && config.indexes.length == keyCount) {
                state.createManiaError = 'Mania with $keyCount keys already exists!';
                return;
            }
        }

        var indexes:Array<Int> = [for (i in 0...keyCount) i];
        var newMania:NoteskinConfig = {
            offsetX: 0, offsetY: 0, gap: 112, scale: 1.0, indexes: indexes
        };

        state.availableManiaConfigs.push(newMania);

        fillMissingManias(keyCount);
        sortManiasByKeyCount();

        var newIndex = state.availableManiaConfigs.indexOf(newMania);
        if (newIndex != -1) {
            state.currentManiaIndex = newIndex;
            state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];
            updateMaxReceptorsFromConfig();

            var clips = state.noteskinData.clip;
            while (clips.length < state.maxReceptors) {
                clips.push(NoteskinEditorClipEditor.defaultClip());
            }

            state.renderer.createReceptors();
            state.renderer.updateReceptorVisuals();
            state.ui.updateInstructionsText();
            trace('Created new mania with $keyCount keys');
        }

        // Close popup.
        state.createManiaPopupActive = false;
        state.createManiaInput = "";
        state.createManiaError = "";

        if (state.popupBackground != null) {
            state.gridBuf.removeElement(state.popupBackground);
            state.popupBackground = null;
            state.gridBuf.update();
        }

        state.ui.updateInstructionsText();
    }

    function fillMissingManias(maxKeys:Int) {
        // Track which key counts already exist.
        var existingKeyCounts:Array<Int> = [];
        for (config in state.availableManiaConfigs) {
            if (config.indexes != null) {
                existingKeyCounts.push(config.indexes.length);
            }
        }

        // Fill in missing manias from 1 to maxKeys.
        for (i in 1...maxKeys) {
            if (existingKeyCounts.indexOf(i) != -1) continue;

            var indexes:Array<Int> = [for (j in 0...i) j];
            state.availableManiaConfigs.push({
                offsetX: 0, offsetY: 0, gap: 112, scale: 1.0, indexes: indexes
            });
            trace('Auto-created mania with $i keys');
        }
    }

    function cancelCreateMania() {
        state.createManiaPopupActive = false;
        state.createManiaInput = "";
        state.createManiaError = "";

        if (state.popupBackground != null) {
            state.gridBuf.removeElement(state.popupBackground);
            state.popupBackground = null;
            state.gridBuf.update();
        }

        trace('Create Mania cancelled');
    }

    function sortManiasByKeyCount() {
        // Dedupe by key count, then sort ascending.
        var seenKeyCounts:Array<Int> = [];
        var uniqueManias:Array<NoteskinConfig> = [];

        for (config in state.availableManiaConfigs) {
            if (config.indexes != null) {
                var keyCount = config.indexes.length;
                if (seenKeyCounts.indexOf(keyCount) == -1) {
                    seenKeyCounts.push(keyCount);
                    uniqueManias.push(config);
                }
            }
        }

        state.availableManiaConfigs = uniqueManias;
        state.availableManiaConfigs.sort(function(a:NoteskinConfig, b:NoteskinConfig) {
            var lenA = a.indexes != null ? a.indexes.length : 0;
            var lenB = b.indexes != null ? b.indexes.length : 0;
            return lenA - lenB;
        });
    }

    function adjustGap(amount:Int) {
        if (state.currentConfig == null) return;
        state.currentConfig.gap += amount;
        if (state.currentConfig.gap < 1)   state.currentConfig.gap = 1;
        if (state.currentConfig.gap > 500) state.currentConfig.gap = 500;

        state.renderer.createReceptors();
        state.renderer.updateReceptorVisuals();
        state.ui.updateInstructionsText();
        trace('Gap adjusted to: ${state.currentConfig.gap}');
    }
}

// ============================================================================
// Renderer — texture loading, receptor/grid creation, visual updates
// ============================================================================

@:publicFields
private class NoteskinEditorRenderer {
    var state:NoteskinEditor;

    public function new(state:NoteskinEditor) {
        this.state = state;
    }

    function createGrid() {
        try {
            if (state.gridBuf == null) {
                state.gridBuf = new Buffer<RepeatSprite>(16, 16, true);
            }
            if (state.gridProg == null) {
                state.gridProg = new CustomProgram(state.gridBuf);
            }
            state.view.addProgram(state.gridProg);
        } catch (e) {
            trace('Failed to create grid: $e');
        }
    }

    function updateGridPosition() {
        for (sprite in state.gridSprites) {
            state.gridBuf.removeElement(sprite);
        }
        state.gridSprites = [];

        var gap = state.currentConfig.gap != 0 ? state.currentConfig.gap : 112;
        var offsetX = state.currentConfig.offsetX;
        var offsetY = state.currentConfig.offsetY;
        var startX = (Main.INITIAL_WIDTH - (state.maxReceptors * gap)) / 2 + offsetX;
        var y = Main.INITIAL_HEIGHT / 2 + offsetY;
        var scale = state.currentConfig.scale;

        for (i in 0...state.maxReceptors) {
            if (i >= state.receptorSprites.length) break;

            var receptor = state.receptorSprites[i];
            var clipIndex = state.clipEditor.getClipIndexForReceptor(i);
            var clip = state.clipEditor.getClipForIndex(clipIndex);
            var basicClip = state.clipEditor.getBasicClipForState(clip, state.currentState);

            var gridSprite = new RepeatSprite(
                Math.round(receptor.x + basicClip.offsX),
                Math.round(receptor.y + basicClip.offsY),
                Math.round(basicClip.clipW * scale),
                Math.round(basicClip.clipH * scale)
            );

            gridSprite.c.setFloatRGB(0, 1, 1);
            gridSprite.c.aF = 0.125;
            gridSprite.c.luminanceF = 0.125;

            if (state.spriteSheetMode && i == state.spritesheetSelectedIndex) {
                gridSprite.x += Math.round(NoteskinEditor.SPRITESHEET_VIEW_OFFSET * scale);
                gridSprite.y += Math.round(NoteskinEditor.SPRITESHEET_VIEW_OFFSET * scale);
            }

            state.gridSprites.push(gridSprite);
            state.gridBuf.addElement(gridSprite);
        }

        state.gridBuf.update();
    }

    function initRendering() {
        state.texture = getCombinedNoteskinTexture();

        if (state.noteBuf == null) {
            state.noteBuf = new Buffer<Note>(16, 16, true);
        }
        if (state.noteProg == null) {
            state.noteProg = new CustomProgram(state.noteBuf);
            Note.init(state.noteProg, NoteskinEditor.NOTESKIN_TEXTURE_NAME, state.texture);
        }

        state.view.addProgram(state.noteProg);
    }

    function getCombinedNoteskinTexture():Texture {
        var existingTex = TextureSystem.getTexture(NoteskinEditor.NOTESKIN_TEXTURE_NAME);
        if (existingTex != null) {
            return existingTex;
        }

        try {
            var skinFolder = 'assets/images/noteskins/${state.currentSkinName}';

            var notesPath = Paths.asset('$skinFolder/notes.png');
            var confirmPath = Paths.asset('$skinFolder/confirm.png');

            var notesExists = FileSystem.exists(notesPath);
            var confirmExists = FileSystem.exists(confirmPath);

            if (!notesExists && !confirmExists) {
                notesPath = Paths.asset('assets/images/noteskins/default/notes.png');
                confirmPath = Paths.asset('assets/images/noteskins/default/confirm.png');
                notesExists = FileSystem.exists(notesPath);
                confirmExists = FileSystem.exists(confirmPath);
            }

            if (!notesExists) {
                trace('Notes texture not found, creating blank');
                return createBlankTexture();
            }

            var notesImage = Image.fromFile(notesPath);
            var confirmImage = confirmExists ? Image.fromFile(confirmPath) : null;

            var combinedWidth = notesImage.width + (confirmImage != null ? confirmImage.width : 0);
            var combinedHeight = Std.int(Math.max(notesImage.height, confirmImage != null ? confirmImage.height : 0));

            var combinedImage = new Image(null, 0, 0, combinedWidth, combinedHeight, 0x00000000);

            var sourceRect = new Rectangle(0, 0, notesImage.width, notesImage.height);
            var destPoint = new Vector2(0, 0);
            combinedImage.copyPixels(notesImage, sourceRect, destPoint);

            if (confirmImage != null) {
                var confirmRect = new Rectangle(0, 0, confirmImage.width, confirmImage.height);
                var confirmDest = new Vector2(notesImage.width, 0);
                combinedImage.copyPixels(confirmImage, confirmRect, confirmDest);
            }

            var pixelData = combinedImage.getPixels(new Rectangle(0, 0, combinedWidth, combinedHeight), RGBA32);

            // Premultiply alpha so the texture composites correctly.
            var premultipliedData = haxe.io.Bytes.alloc(pixelData.length);
            for (i in 0...pixelData.length >> 2) {
                var fullARGB = pixelData.getInt32(i << 2);

                var a = (fullARGB >>> 24) & 0xFF;
                var r = (fullARGB >>> 16) & 0xFF;
                var g = (fullARGB >>> 8)  & 0xFF;
                var b = (fullARGB)        & 0xFF;

                r = (r * a) >> 8;
                g = (g * a) >> 8;
                b = (b * a) >> 8;

                var premul = (a << 24) | (r << 16) | (g << 8) | b;
                premultipliedData.setInt32(i << 2, premul);
            }

            var textureData = new TextureData(combinedWidth, combinedHeight, TextureFormat.RGBA);
            textureData.bytes = premultipliedData;

            var texture = new Texture(textureData.width, textureData.height, null, {
                format: TextureFormat.RGBA,
                powerOfTwo: false,
                smoothExpand: SaveData.state.graphics.antialiasing,
                smoothShrink: SaveData.state.graphics.antialiasing
            });
            texture.setData(textureData);

            TextureSystem.pool[NoteskinEditor.NOTESKIN_TEXTURE_NAME] = texture;

            return texture;
        } catch (e) {
            trace('Failed to load combined noteskin texture: $e');
            return createBlankTexture();
        }
    }

    function createBlankTexture():Texture {
        try {
            var blankData = new TextureData(500, 500, TextureFormat.RGBA);
            blankData.bytes = haxe.io.Bytes.alloc(500 * 500 * 4);
            for (i in 0...blankData.bytes.length >> 2) {
                blankData.bytes.setInt32(i << 2, 0xFFFFFFFF);
            }
            var texture = new Texture(500, 500, null, {
                format: TextureFormat.RGBA,
                powerOfTwo: false,
                smoothExpand: false,
                smoothShrink: false
            });
            texture.setData(blankData);
            return texture;
        } catch (e) {
            trace('Failed to create blank texture: $e');
            return null;
        }
    }

    // Preview-clips mode lays receptors out in rows of PREVIEW_COLS so a noteskin
    // with dozens of clips stays readable. Normal manias keep the single-row layout.
    static inline var PREVIEW_COLS:Int = 11;

    function isPreviewMania():Bool {
        return state.currentManiaIndex >= state.availableManiaConfigs.length;
    }

    function getReceptorPosition(i:Int, gap:Float, offsetX:Float, offsetY:Float):{x:Float, y:Float} {
        if (isPreviewMania()) {
            var col = i % PREVIEW_COLS;
            var row = Math.floor(i / PREVIEW_COLS);
            var totalRows = Math.ceil(state.maxReceptors / PREVIEW_COLS);
            // Each row is centered independently so a short final row doesn't sit flush-left.
            var receptorsInThisRow = Math.min(PREVIEW_COLS, state.maxReceptors - row * PREVIEW_COLS);
            var startX = (Main.INITIAL_WIDTH - (receptorsInThisRow * gap)) / 2 + offsetX;
            // Vertically center the whole block of rows around the usual y baseline.
            var centerY = Main.INITIAL_HEIGHT / 2.36 + offsetY;
            var rowHeight = gap; // square grid
            var x = startX + (col * gap);
            var y = centerY + (row - (totalRows - 1) / 2) * rowHeight;
            return {x: x, y: y};
        } else {
            var startX = (Main.INITIAL_WIDTH - (state.maxReceptors * gap)) / 2 + offsetX;
            var y = Main.INITIAL_HEIGHT / 1.4 + offsetY;
            return {x: startX + (i * gap), y: y};
        }
    }

    function createReceptors() {
        for (sprite in state.receptorSprites) {
            state.noteBuf.removeElement(sprite);
        }
        state.receptorSprites = [];

        var gap = state.currentConfig.gap != 0 ? state.currentConfig.gap : 112;
        var offsetX = state.currentConfig.offsetX;
        var offsetY = state.currentConfig.offsetY;
        var scale = state.currentConfig.scale;

        for (i in 0...state.maxReceptors) {
            var pos = getReceptorPosition(i, gap, offsetX, offsetY);
            var note = new Note(
                Std.int(pos.x),
                Std.int(pos.y),
                100, 100,
                scale,
                scale,
                0.0
            );

            var clipIndex = state.clipEditor.getClipIndexForReceptor(i);
            var clip = state.clipEditor.getClipForIndex(clipIndex);
            applyClipToNote(note, state.currentState, clip);
            note.changeID(clipIndex);

            if (state.currentManiaIndex >= state.availableManiaConfigs.length) {
                note.initialAlpha = 0.9;
            }

            state.receptorSprites.push(note);
            state.noteBuf.addElement(note);
        }

        state.noteBuf.update();
    }

    function applyClipToNote(note:Note, editState:EditState, clip:NoteskinReceptorProperties) {
        var basicClip = state.clipEditor.getBasicClipForState(clip, editState);

        var scale = state.currentConfig.scale;

        note.clipX = basicClip.clipX;
        note.clipY = basicClip.clipY;
        note.clipWidth = basicClip.clipW;
        note.clipHeight = basicClip.clipH;
        note.clipPosX = 0;
        note.clipPosY = 0;
        note.clipSizeX = basicClip.clipW;
        note.clipSizeY = basicClip.clipH;
        note.w = basicClip.clipW;
        note.h = basicClip.clipH;
        note.ox = basicClip.offsX;
        note.oy = basicClip.offsY;
        note.scale = scale;
    }

    function updateGlobalTransform() {
        createReceptors();
        updateReceptorVisuals();
        state.ui.updateInstructionsText();
        if (state.globalScaleMode) {
            trace('Global Scale: ${state.currentConfig.scale}');
        } else {
            trace('Global Offset: (${state.currentConfig.offsetX}, ${state.currentConfig.offsetY})');
        }
    }

    function updateReceptorVisuals() {
        var gap = state.currentConfig.gap != 0 ? state.currentConfig.gap : 112;
        var offsetX = state.currentConfig.offsetX;
        var offsetY = state.currentConfig.offsetY;
        var scale = state.currentConfig.scale;

        for (i in 0...state.receptorSprites.length) {
            var note = state.receptorSprites[i];

            var clipIndex = state.clipEditor.getClipIndexForReceptor(i);
            var clip = state.clipEditor.getClipForIndex(clipIndex);

            var pos = getReceptorPosition(i, gap, offsetX, offsetY);
            note.x = Std.int(pos.x);
            note.y = Std.int(pos.y);
            note.scale = scale;

            if (state.spriteSheetMode && i == state.spritesheetSelectedIndex) {
                var basicClip = state.clipEditor.getBasicClipForState(clip, state.currentState);

                note.c = 0xFF66FFFF;
                note.initialAlpha = 0.5;

                // Show the full texture around the clip — clipX/Y becomes the clip's
                // top-left minus the view offset, dimensions become the texture size.
                note.clipX = basicClip.clipX - NoteskinEditor.SPRITESHEET_VIEW_OFFSET;
                note.clipY = basicClip.clipY - NoteskinEditor.SPRITESHEET_VIEW_OFFSET;
                note.clipWidth = state.texture.width + NoteskinEditor.SPRITESHEET_VIEW_OFFSET;
                note.clipHeight = state.texture.height + NoteskinEditor.SPRITESHEET_VIEW_OFFSET;
                note.clipSizeX = state.texture.width + NoteskinEditor.SPRITESHEET_VIEW_OFFSET;
                note.clipSizeY = state.texture.height + NoteskinEditor.SPRITESHEET_VIEW_OFFSET;
                note.w = state.texture.width + NoteskinEditor.SPRITESHEET_VIEW_OFFSET;
                note.h = state.texture.height + NoteskinEditor.SPRITESHEET_VIEW_OFFSET;
                note.ox = basicClip.offsX;
                note.oy = basicClip.offsY;
                note.x -= Math.round(NoteskinEditor.SPRITESHEET_VIEW_OFFSET * scale);
                note.y -= Math.round(NoteskinEditor.SPRITESHEET_VIEW_OFFSET * scale);
            } else {
                if (i == state.selectedIndex) {
                    note.c = 0x00FFAAFF;
                } else {
                    note.c = 0xFFFFFFFF;
                }
                note.initialAlpha = 1.0;
                applyClipToNote(note, state.currentState, clip);
            }

            note.changeID(clipIndex);
            state.noteBuf.updateElement(note);
        }

        state.noteBuf.update();
        updateGridPosition();
        state.ui.updateInstructionsText();
    }

    function updateReceptorState(newState:EditState) {
        state.currentState = newState;
        updateReceptorVisuals();
        state.ui.updateInstructionsText();
    }
}

// ============================================================================
// UI — instructions text and create-mania popup rendering
// ============================================================================

@:publicFields
private class NoteskinEditorUI {
    var state:NoteskinEditor;

    public function new(state:NoteskinEditor) {
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
                new TextFormatMarkerPair('#M6#', 0xFFFF9933), // Orange — edit mode
                new TextFormatMarkerPair('#M7#', 0xFFFF33FF), // Pink   — offset mode
                new TextFormatMarkerPair('#M8#', 0xFF33FF33), // Green  — clip index mode
                new TextFormatMarkerPair('#M9#', 0xFFFF00FF)  // Magenta — spritesheet mode
            ];

            state.instructionsText = new Text("NOTESKIN_EDITOR_INSTRUCTIONS", 4, 3, state.display, "", "vcr");
            state.instructionsText.scale = 0.7;
            state.instructionsText.alpha = 0; // Start hidden
            state.instructionsText.multiline = true;
            state.instructionsText.alignment = RIGHT;
            state.instructionsText.spacerPercent = -0.1;
            state.instructionsText.outlineColor = Color.BLACK;
            state.instructionsText.outlineSize = 1;
            state.instructionsText.setMarkerPairs(markers);

            state.instructionsText.text = buildInstructionsText();

            positionInstructionsTextTopRight();

            state.instructionsText.addProgram();
        }
    }

    function buildInstructionsText():String {
        if (state.createManiaPopupActive) return "";

        var stateName = state.clipEditor.getStateName(state.currentState);
        var stateColor = switch(state.currentState) {
            case IDLE:    "#M1#";
            case COLOR:   "#M2#";
            case PRESS:   "#M3#";
            case CONFIRM: "#M4#";
            default:      "";
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
            "SHIFT+UP/DOWN: Switch mania\n" +
            "SHIFT+SPACE: Create new mania\n" +
            "ALT+LEFT/RIGHT or ALT+MouseWheel: Adjust gap\n" +
            "CTRL+ALT+LEFT/RIGHT or CTRL+ALT+MouseWheel: Adjust gap (10x)\n" +
            (!state.spriteSheetMode && state.editMode == GLOBAL_TRANSFORM ?
                "Arrow Keys: Adjust Offset/Scale\n" :
                (state.spriteSheetMode ? "Click, Arrow Keys, or TAB: Switch receptor index\n" :
                "Arrow Keys: Edit X/Y values\n")) +
            "CTRL+Arrow Keys: Adjust value (+10)\n" +
            (!state.spriteSheetMode && state.editMode != GLOBAL_TRANSFORM ? "Click receptor or SHIFT+LEFT/RIGHT: Switch receptor\n" : "") +
            (!state.spriteSheetMode && state.editMode == GLOBAL_TRANSFORM ? "LEFT/RIGHT or SHIFT+MouseWheel: Adjust offset/scale\n" : "") +
            "Hold Click: Toggle spritesheet view\n" +
            (!state.spriteSheetMode && state.editMode == GLOBAL_TRANSFORM && !state.globalScaleMode ?
                "Mouse Drag: Move strumline offset X/Y\n" :
                "Mouse Drag: Modify current properties\n") +
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
            if (state.createManiaPopupActive) {
                state.instructionsText.alignment = LEFT;
                return;
            }

            var newText = buildInstructionsText();
            if (state.instructionsText.text != newText) {
                state.instructionsText.text = newText;
            }
            state.instructionsText.alignment = RIGHT;
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

        // Create popup background on first frame.
        if (state.popupBackground == null) {
            state.popupBackground = new RepeatSprite(0, 0, 0, 0);
            state.popupBackground.c = 0x000000FF;
            state.popupBackground.c.aF = 0.6;
            state.gridBuf.addElement(state.popupBackground);
        }

        var popupText =
            "#M6#=== CREATE NEW MANIA ===#M6#\n" +
            "How many keys this time?\n" +
            "(Enter a number 1-64)\n\n" +
            '#M5#Keys: ${state.createManiaInput != "" ? state.createManiaInput : "_"}#M5#\n';

        if (state.createManiaError != "") {
            popupText += '#M2#${state.createManiaError}#M2#\n';
        }

        popupText += "\n#M1#[ENTER] Confirm#M1#   #M3#[ESC] Cancel#M3#";

        state.instructionsText.text = popupText;
        state.instructionsText.alignment = CENTER;
        state.instructionsText.scale = 1.2;
        state.instructionsText.alpha = 1;

        // Force the text to recalculate its dimensions before positioning.
        state.instructionsText.refresh();

        state.instructionsText.x = (Main.INITIAL_WIDTH - state.instructionsText.width) / 2;
        state.instructionsText.y = (Main.INITIAL_HEIGHT - state.instructionsText.height) / 2;

        var padding = 20;
        state.popupBackground.x = Std.int(state.instructionsText.x - padding);
        state.popupBackground.y = Std.int(state.instructionsText.y - padding);
        state.popupBackground.w = Std.int(state.instructionsText.width + padding * 2);
        state.popupBackground.h = Std.int(state.instructionsText.height + padding * 2);
        state.gridBuf.updateElement(state.popupBackground);
        state.gridBuf.update();
    }
}

// ============================================================================
// Input Handler — keyboard and mouse event routing
// ============================================================================

@:publicFields
private class NoteskinEditorInputHandler {
    var state:NoteskinEditor;

    public function new(state:NoteskinEditor) {
        this.state = state;
    }

    function addEvents() {
        #if !android
        var window = Application.current.window;
        window.onKeyDown.add(handleKeyDown);
        window.onKeyUp.add(handleKeyUp);
        window.onMouseDown.add(handleMouseDown);
        window.onMouseUp.add(handleMouseUp);
        window.onMouseMove.add(handleMouseMove);
        window.onMouseWheel.add(handleMouseWheel);
        #end
    }

    function removeEvents() {
        #if !android
        var window = Application.current.window;
        window.onKeyDown.remove(handleKeyDown);
        window.onKeyUp.remove(handleKeyUp);
        window.onMouseDown.remove(handleMouseDown);
        window.onMouseUp.remove(handleMouseUp);
        window.onMouseMove.remove(handleMouseMove);
        window.onMouseWheel.remove(handleMouseWheel);
        #end
    }

    function setCursor(cursor:MouseCursor) {
        var window = Application.current.window;
        if (window != null) {
            window.cursor = cursor;
        }
    }

    // --- Key Handling ---

    public function handleKeyDown(key:KeyCode, modifier:KeyModifier) {
        state.isCtrlPressed  = (modifier & KeyModifier.CTRL)  != 0;
        state.isShiftPressed = (modifier & KeyModifier.SHIFT) != 0;
        state.isAltPressed   = (modifier & KeyModifier.ALT)   != 0;

        if (state.createManiaPopupActive) {
            handleCreateManiaPopupInput(key);
            return;
        }

        if (key == KeyCode.ESCAPE) {
            if (state.spriteSheetMode) {
                state.clipEditor.toggleSpritesheetMode();
            } else {
                state.toggleEditor();
            }
            return;
        }

        if (!state.showEditor) return;

        // CTRL+SPACE toggles global transform sub-mode (Offset vs Scale).
        if (key == KeyCode.SPACE && state.isCtrlPressed) {
            if (state.editMode == GLOBAL_TRANSFORM) {
                state.globalScaleMode = !state.globalScaleMode;
                var modeName = state.globalScaleMode ? "Scale" : "Offset";
                trace('Global transform mode: $modeName');
                state.ui.updateInstructionsText();
            }
            return;
        }

        switch(key) {
            case KeyCode.SPACE:
                if (state.isShiftPressed) {
                    state.maniaManager.createNewMania();
                } else if (!state.spriteSheetMode && state.editMode != GLOBAL_TRANSFORM) {
                    state.clipEditor.toggleAxisProperty();
                }
            case KeyCode.UP:
                if (state.isShiftPressed) {
                    state.maniaManager.switchMania(1);
                    state.clipEditor.checkInvalidClipIDPlace();
                } else if (state.spriteSheetMode) {
                    state.clipEditor.selectPreviousIndex();
                } else if (state.isCtrlPressed && state.editMode != CLIP_ID && state.editMode != GLOBAL_TRANSFORM) {
                    state.clipEditor.adjustAxisValue(-10, "Y");
                } else if (state.editMode == GLOBAL_TRANSFORM) {
                    if (state.globalScaleMode) {
                        state.currentConfig.scale += 0.05;
                        state.renderer.updateGlobalTransform();
                    } else {
                        state.currentConfig.offsetY -= state.isCtrlPressed ? 10 : 1;
                        state.renderer.updateGlobalTransform();
                    }
                } else {
                    state.clipEditor.adjustAxisValue(-1, "Y");
                }
            case KeyCode.DOWN:
                if (state.isShiftPressed) {
                    state.maniaManager.switchMania(-1);
                    state.clipEditor.checkInvalidClipIDPlace();
                } else if (state.spriteSheetMode) {
                    state.clipEditor.selectNextIndex();
                } else if (state.isCtrlPressed && state.editMode != CLIP_ID && state.editMode != GLOBAL_TRANSFORM) {
                    state.clipEditor.adjustAxisValue(10, "Y");
                } else if (state.editMode == GLOBAL_TRANSFORM) {
                    if (state.globalScaleMode) {
                        state.currentConfig.scale -= 0.05;
                        if (state.currentConfig.scale < 0.1) state.currentConfig.scale = 0.1;
                        state.renderer.updateGlobalTransform();
                    } else {
                        state.currentConfig.offsetY += state.isCtrlPressed ? 10 : 1;
                        state.renderer.updateGlobalTransform();
                    }
                } else {
                    state.clipEditor.adjustAxisValue(1, "Y");
                }
            case KeyCode.LEFT:
                if (state.spriteSheetMode) {
                    state.clipEditor.selectPreviousIndex();
                } else if (state.isAltPressed) {
                    state.maniaManager.adjustGap(state.isCtrlPressed ? -10 : -1);
                } else if (state.isShiftPressed) {
                    state.clipEditor.selectPreviousIndex();
                } else if (state.isCtrlPressed && state.editMode != CLIP_ID && state.editMode != GLOBAL_TRANSFORM) {
                    state.clipEditor.adjustAxisValue(-10, "X");
                } else if (state.editMode == GLOBAL_TRANSFORM) {
                    if (state.globalScaleMode) {
                        state.currentConfig.scale -= 0.05;
                        if (state.currentConfig.scale < 0.1) state.currentConfig.scale = 0.1;
                        state.renderer.updateGlobalTransform();
                    } else {
                        state.currentConfig.offsetX -= state.isCtrlPressed ? 10 : 1;
                        state.renderer.updateGlobalTransform();
                    }
                } else {
                    state.clipEditor.adjustAxisValue(-1, "X");
                }
            case KeyCode.RIGHT:
                if (state.spriteSheetMode) {
                    state.clipEditor.selectNextIndex();
                } else if (state.isAltPressed) {
                    state.maniaManager.adjustGap(state.isCtrlPressed ? 10 : 1);
                } else if (state.isShiftPressed) {
                    state.clipEditor.selectNextIndex();
                } else if (state.isCtrlPressed && state.editMode != CLIP_ID && state.editMode != GLOBAL_TRANSFORM) {
                    state.clipEditor.adjustAxisValue(10, "X");
                } else if (state.editMode == GLOBAL_TRANSFORM) {
                    if (state.globalScaleMode) {
                        state.currentConfig.scale += 0.05;
                        state.renderer.updateGlobalTransform();
                    } else {
                        state.currentConfig.offsetX += state.isCtrlPressed ? 10 : 1;
                        state.renderer.updateGlobalTransform();
                    }
                } else {
                    state.clipEditor.adjustAxisValue(1, "X");
                }
            case KeyCode.TAB:
                if (state.isCtrlPressed) {
                    if (!state.spriteSheetMode) state.clipEditor.toggleEditMode();
                } else {
                    state.clipEditor.toggleState(state.isShiftPressed ? -1 : 1);
                }
            default:
        }
    }

    public function handleKeyUp(key:KeyCode, modifier:KeyModifier) {
        state.isCtrlPressed  = (modifier & KeyModifier.CTRL)  != 0;
        state.isShiftPressed = (modifier & KeyModifier.SHIFT) != 0;
        state.isAltPressed   = (modifier & KeyModifier.ALT)   != 0;
    }

    function handleCreateManiaPopupInput(key:KeyCode) {
        switch(key) {
            case KeyCode.ESCAPE:
                state.maniaManager.cancelCreateMania();
                state.ui.updateInstructionsText();
            case KeyCode.RETURN:
                state.maniaManager.confirmCreateMania();
            case KeyCode.BACKSPACE:
                if (state.createManiaInput.length > 0) {
                    state.createManiaInput = state.createManiaInput.substring(0, state.createManiaInput.length - 1);
                    state.createManiaError = "";
                }
            default:
        }

        // Numeric input (regular + numpad).
        var num = key - 0x30;             // '0' key
        var num2 = key - 0x40000059;      // Numpad keys
        if (((num >= 0 && num < 10) || (num2 >= 0 && num2 < 10)) && state.createManiaInput.length < 2) {
            var digit = num >= 0 && num < 10 ? num : num2;
            state.createManiaInput += Std.string(digit);
            state.createManiaError = "";
        }
    }

    // --- Mouse Handling ---

    function handleMouseDown(mouseX:Float, mouseY:Float, button:MouseButton) {
        if (!state.showEditor || button != MouseButton.LEFT) return;
        if (Application.current.window == null) return;

        // Click-to-select: if the click landed on a receptor, select it first
        // so the user doesn't have to cycle with SHIFT+LEFT/RIGHT.
        var hitIndex = state.clipEditor.findReceptorAt(mouseX, mouseY);
        if (hitIndex != -1 && hitIndex != state.selectedIndex) {
            state.selectedIndex = hitIndex;
            if (state.spriteSheetMode) {
                state.spritesheetSelectedIndex = hitIndex;
            }
            state.renderer.updateReceptorVisuals();
            state.ui.updateInstructionsText();
        }

        var note = state.clipEditor.getSelectedNote();
        if (note == null) return;

        var sx = note.x;
        var sy = note.y;
        var sw = note.w;
        var sh = note.h;

        var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;

        if (inSprite) {
            // Start holding for long press detection (works in both modes).
            state.isHoldingMouse = true;
            state.isLongPress = false;
            state.longPressTriggered = false;
            state.mouseDownX = mouseX;
            state.mouseDownY = mouseY;
            state.longPressTimer = 0;
            // In spritesheet mode, drag starts on move, not on down.
        } else {
            startDrag(mouseX, mouseY);
        }
    }

    function startDrag(mouseX:Float, mouseY:Float) {
        // Cancel any pending long press.
        state.isHoldingMouse = false;
        state.isLongPress = false;
        state.longPressTriggered = false;

        // Spritesheet mode — pan the view by modifying clipX/Y.
        if (state.spriteSheetMode) {
            state.isDragging = true;
            state.dragStartX = mouseX;
            state.dragStartY = mouseY;
            state.lastDragX = mouseX;
            state.lastDragY = mouseY;
            var clip = state.clipEditor.getSelectedClip();
            state.dragStartClipX = clip.clipX;
            state.dragStartClipY = clip.clipY;
            state.dragMode = 0;
            setCursor(MouseCursor.MOVE);
            return;
        }

        var note = state.clipEditor.getSelectedNote();
        if (note == null) return;

        var sx = note.x;
        var sy = note.y;
        var sw = note.w;
        var sh = note.h;

        // Edge detection margin — how close the cursor must be to register
        // as "on the edge" vs. "in the middle".
        var margin = 10;
        var nearRight  = Math.abs(mouseX - (sx + sw)) <= margin;
        var nearBottom = Math.abs(mouseY - (sy + sh)) <= margin;

        state.isDragging = true;
        state.dragStartX = mouseX;
        state.dragStartY = mouseY;
        state.lastDragX = mouseX;
        state.lastDragY = mouseY;

        var clip = state.clipEditor.getSelectedClip();
        state.dragStartClipX = clip.clipX;
        state.dragStartClipY = clip.clipY;
        state.dragStartClipW = clip.clipW;
        state.dragStartClipH = clip.clipH;
        state.dragStartOffsX = clip.offsX;
        state.dragStartOffsY = clip.offsY;

        // Drag mode is LOCKED at drag start — it does not change for the
        // rest of the drag, no matter where the cursor moves.
        //
        // CLIP_SIZE resize is restricted to three zones:
        //   - Bottom-right corner  → resize W + H  (mode 3)
        //   - Bottom edge only     → resize H only (mode 2)
        //   - Right edge only      → resize W only (mode 1)
        // Clicking anywhere else in CLIP_SIZE is a no-op (mode -1) — the
        // drag starts but does nothing, so the lock is explicit.
        switch(state.editMode) {
            case CLIP_POS:
                state.dragMode = 0;
                setCursor(MouseCursor.MOVE);
            case CLIP_SIZE:
                if (nearRight && nearBottom) {
                    state.dragMode = 3;  // Corner — both
                    setCursor(MouseCursor.RESIZE_NWSE);
                } else if (nearBottom) {
                    state.dragMode = 2;  // Bottom edge — height only
                    setCursor(MouseCursor.RESIZE_NS);
                } else if (nearRight) {
                    state.dragMode = 1;  // Right edge — width only
                    setCursor(MouseCursor.RESIZE_WE);
                } else {
                    state.dragMode = -1; // Not on a resize zone — no-op
                    setCursor(MouseCursor.ARROW);
                }
            case OFFSET:
                if (nearRight) {
                    state.dragMode = 4;
                    setCursor(MouseCursor.RESIZE_WE);
                } else if (nearBottom) {
                    state.dragMode = 5;
                    setCursor(MouseCursor.RESIZE_NS);
                } else {
                    state.dragMode = 6;
                    setCursor(MouseCursor.MOVE);
                }
            case CLIP_ID:
                state.dragMode = -1;
                setCursor(MouseCursor.ARROW);
            case GLOBAL_TRANSFORM:
                if (state.globalScaleMode) {
                    // Scale sub-mode — 1D value on a 2D drag is ambiguous; use arrow keys.
                    state.dragMode = -1;
                    setCursor(MouseCursor.ARROW);
                } else {
                    // Offset sub-mode — drag anywhere moves the whole strumline.
                    // Reuse dragStartOffsX/Y to capture the global offset at drag start
                    // (semantically identical: "offset at drag start").
                    state.dragMode = 0;
                    state.dragStartOffsX = state.currentConfig.offsetX;
                    state.dragStartOffsY = state.currentConfig.offsetY;
                    setCursor(MouseCursor.MOVE);
                }
            default:
                state.dragMode = 0;
                setCursor(MouseCursor.MOVE);
        }
    }

    function handleMouseUp(mouseX:Float, mouseY:Float, button:MouseButton) {
        if (button != MouseButton.LEFT) return;
        if (Application.current.window == null) return;

        state.isHoldingMouse = false;
        state.isLongPress = false;

        state.isDragging = false;
        setCursor(MouseCursor.ARROW);
        state.dragMode = 0;
    }

    function handleMouseMove(mouseX:Float, mouseY:Float) {
        if (!state.showEditor) return;
        if (Application.current.window == null) return;

        var note = state.clipEditor.getSelectedNote();
        if (note == null) return;

        // Cancel long press and start drag if the mouse moved too far.
        // Use the ORIGINAL click position (state.mouseDownX/Y) — not the
        // current cursor position — so edge detection (corner / bottom /
        // right) evaluates where the user actually clicked, not where the
        // cursor ended up after moving 10px to trigger the threshold.
        // Without this, clicking the corner and dragging away would
        // mis-detect the zone and pick the wrong resize mode.
        if (state.isHoldingMouse && !state.longPressTriggered) {
            var dx = Math.abs(mouseX - state.mouseDownX);
            var dy = Math.abs(mouseY - state.mouseDownY);
            if (dx > 5 || dy > 5) {
                state.isHoldingMouse = false;
                startDrag(state.mouseDownX, state.mouseDownY);
                return;
            }
        }

        if (state.isDragging) {
            var dx = mouseX - state.dragStartX;
            var dy = mouseY - state.dragStartY;

            // Spritesheet pan.
            if (state.spriteSheetMode) {
                var clip = state.clipEditor.getSelectedClip();
                clip.clipX = Std.int(state.dragStartClipX - dx);
                clip.clipY = Std.int(state.dragStartClipY - dy);
                state.selectedProperty = "clipX";

                var clipIndex = state.clipEditor.getClipIndexForReceptor(state.selectedIndex);
                state.clipEditor.updateClipInConfig(clipIndex, state.currentState, clip);
                state.renderer.updateReceptorVisuals();
                state.ui.updateInstructionsText();
                setCursor(MouseCursor.MOVE);
                return;
            }

            var clip = state.clipEditor.getSelectedClip();

            switch(state.editMode) {
                case CLIP_POS:
                    clip.clipX = Std.int(state.dragStartClipX - dx);
                    clip.clipY = Std.int(state.dragStartClipY - dy);
                    state.selectedProperty = "clipX";

                case CLIP_SIZE:
                    // Mode -1 = no-op (clicked outside a resize zone). Skip
                    // the clip update entirely — nothing to do.
                    if (state.dragMode == -1) return;
                    switch(state.dragMode) {
                        case 1:
                            clip.clipW = Std.int(Math.max(1, state.dragStartClipW + dx));
                            state.selectedProperty = "clipW";
                        case 2:
                            clip.clipH = Std.int(Math.max(1, state.dragStartClipH + dy));
                            state.selectedProperty = "clipH";
                        case 3:
                            clip.clipW = Std.int(Math.max(1, state.dragStartClipW + dx));
                            clip.clipH = Std.int(Math.max(1, state.dragStartClipH + dy));
                            state.selectedProperty = "clipW";
                        default:
                    }

                case OFFSET:
                    switch(state.dragMode) {
                        case 4:
                            clip.offsX = Std.int(state.dragStartOffsX + dx);
                            state.selectedProperty = "offsX";
                        case 5:
                            clip.offsY = Std.int(state.dragStartOffsY + dy);
                            state.selectedProperty = "offsY";
                        case 6:
                            clip.offsX = Std.int(state.dragStartOffsX + dx);
                            clip.offsY = Std.int(state.dragStartOffsY + dy);
                            state.selectedProperty = "offsX";
                        default:
                    }

                case GLOBAL_TRANSFORM:
                    // Global offset drag — only applies in offset sub-mode;
                    // scale sub-mode is handled by arrow keys.
                    if (state.globalScaleMode) return;
                    state.currentConfig.offsetX = Std.int(state.dragStartOffsX + dx);
                    state.currentConfig.offsetY = Std.int(state.dragStartOffsY + dy);
                    state.renderer.updateGlobalTransform();
                    setCursor(MouseCursor.MOVE);
                    return;
                default:
                    return;
            }

            var clipIndex = state.clipEditor.getClipIndexForReceptor(state.selectedIndex);
            state.clipEditor.updateClipInConfig(clipIndex, state.currentState, clip);
            state.renderer.updateReceptorVisuals();
            state.ui.updateInstructionsText();

            // Update cursor based on drag mode.
            switch(state.editMode) {
                case CLIP_POS:
                    setCursor(MouseCursor.MOVE);
                case CLIP_SIZE:
                    switch(state.dragMode) {
                        case 1: setCursor(MouseCursor.RESIZE_WE);
                        case 2: setCursor(MouseCursor.RESIZE_NS);
                        case 3: setCursor(MouseCursor.RESIZE_NWSE);
                        default:
                    }
                case OFFSET:
                    switch(state.dragMode) {
                        case 4: setCursor(MouseCursor.RESIZE_WE);
                        case 5: setCursor(MouseCursor.RESIZE_NS);
                        case 6: setCursor(MouseCursor.MOVE);
                        default:
                    }
                default:
            }
        } else {
            // Hover state — update cursor.
            if (!state.spriteSheetMode) {
                // Global offset drag works anywhere on screen, so show MOVE everywhere
                // (not just on a sprite) when in offset sub-mode. Scale sub-mode has
                // no drag — show ARROW.
                if (state.editMode == GLOBAL_TRANSFORM) {
                    setCursor(state.globalScaleMode ? MouseCursor.ARROW : MouseCursor.MOVE);
                    return;
                }

                var clip = state.clipEditor.getSelectedClip();
                var sx = note.x + clip.offsX;
                var sy = note.y + clip.offsY;
                var sw = note.w;
                var sh = note.h;
                var margin = 10;

                var nearRight  = Math.abs(mouseX - (sx + sw)) <= margin;
                var nearBottom = Math.abs(mouseY - (sy + sh)) <= margin;
                var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;

                // Hover cursor mirrors the locked drag modes exactly:
                // CLIP_SIZE only resizes from corner / bottom / right.
                // The middle of the sprite shows ARROW (no resize there).
                if (inSprite && state.editMode != CLIP_ID) {
                    switch(state.editMode) {
                        case CLIP_POS:
                            setCursor(MouseCursor.MOVE);
                        case CLIP_SIZE:
                            if (nearRight && nearBottom)       setCursor(MouseCursor.RESIZE_NWSE);
                            else if (nearBottom)               setCursor(MouseCursor.RESIZE_NS);
                            else if (nearRight)                setCursor(MouseCursor.RESIZE_WE);
                            else                               setCursor(MouseCursor.ARROW);
                        case OFFSET:
                            if (nearRight)                     setCursor(MouseCursor.RESIZE_WE);
                            else if (nearBottom)               setCursor(MouseCursor.RESIZE_NS);
                            else                               setCursor(MouseCursor.MOVE);
                        default:
                            setCursor(MouseCursor.ARROW);
                    }
                } else {
                    setCursor(MouseCursor.ARROW);
                }
            } else {
                var sx = note.x;
                var sy = note.y;
                var sw = note.w;
                var sh = note.h;
                var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;
                setCursor(inSprite ? MouseCursor.MOVE : MouseCursor.ARROW);
            }
        }
    }

    function handleMouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode) {
        if (!state.showEditor) return;

        // ALT+Wheel: adjust gap.
        if (state.isAltPressed && !state.globalScaleMode) {
            var amount = deltaY > 0 ? (state.isCtrlPressed ? 10 : 1) : (state.isCtrlPressed ? -10 : -1);
            state.maniaManager.adjustGap(amount);
            return;
        }

        // SHIFT+Wheel in scale sub-mode: adjust scale.
        if (state.isShiftPressed && state.globalScaleMode) {
            state.currentConfig.scale += deltaY < 0 ? -0.05 : 0.05;
            if (state.currentConfig.scale < 0.1) state.currentConfig.scale = 0.1;
            state.renderer.updateGlobalTransform();
            return;
        }

        if (deltaY > 0) {
            if (state.spriteSheetMode) state.clipEditor.selectNextIndex();
            else                       state.clipEditor.toggleState(1);
        } else if (deltaY < 0) {
            if (state.spriteSheetMode) state.clipEditor.selectPreviousIndex();
            else                       state.clipEditor.toggleState(-1);
        }
    }
}

// ============================================================================
// Noteskin Editor — main class (file entry point)
// ============================================================================

/**
    Noteskin editor debug that's accessed from Main Menu (Debug Keybind).
    Shows a live strumline preview via `NoteSystem.notesBuf` and exposes
    per-index clip/offset editing.
    Also shows a grid for visual reference of how the strumline would look
    ingame for clip.
    @since 0.94
**/
@:publicFields
class NoteskinEditor {
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
    var currentManiaIndex:Int = 0;
    var availableManiaConfigs:Array<NoteskinConfig> = [];
    var createManiaPopupActive:Bool = false;
    var createManiaInput:String = "";
    var createManiaError:String = "";
    var createManiaKeyCount:Int = 0;
    var currentState:EditState = IDLE;
    var currentReceptorIndex:Int = 0;
    var currentLane:Int = 0;
    var selectedIndex:Int = 0;
    var maxReceptors:Int = 4;
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
    // 0 = move (clipX/Y), 1 = resize right (clipW), 2 = resize bottom (clipH),
    // 3 = resize corner (clipW/H), 4 = offset X, 5 = offset Y, 6 = offset both
    var dragMode:Int = 0;

    // Long press state for spritesheet mode
    var isHoldingMouse:Bool = false;
    var isLongPress:Bool = false;
    var longPressTimer:Float = 0;
    var longPressThreshold:Float = 400; // ms
    var mouseDownX:Float = 0;
    var mouseDownY:Float = 0;
    var spriteSheetMode:Bool = false;
    var longPressTriggered:Bool = false;
    var spritesheetSelectedIndex:Int = -1;

    // Spritesheet view offset — extra space above to see what's outside the clip.
    static inline var SPRITESHEET_VIEW_OFFSET:Int = 300;

    // Texture name constants
    static inline var NOTESKIN_TEXTURE_NAME:String = "noteskinTexV2";
    static inline var GRID_TEXTURE_NAME:String = "gridTexV2";

    // Instructions text
    var instructionsText:Text;

    public function new() {
        // Helper constructors don't do any work — they only store the back-reference.
        maniaManager  = new NoteskinEditorManiaManager(this);
        renderer      = new NoteskinEditorRenderer(this);
        clipEditor    = new NoteskinEditorClipEditor(this);
        ui            = new NoteskinEditorUI(this);
        inputHandler  = new NoteskinEditorInputHandler(this);

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

        // Initialize instructions text AFTER display is set.
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
        // Render create-mania popup if active.
        if (createManiaPopupActive) {
            ui.renderCreateManiaPopup();
            return;
        }

        // Long press detection.
        if (isHoldingMouse && !longPressTriggered && !isDragging) {
            longPressTimer += deltaTime;
            if (longPressTimer >= longPressThreshold) {
                longPressTriggered = true;
                isHoldingMouse = false;

                if (spriteSheetMode) {
                    // EXIT spritesheet mode.
                    spriteSheetMode = false;
                    spritesheetSelectedIndex = -1;
                    trace('Spritesheet mode disabled - returning to normal view');
                    inputHandler.setCursor(MouseCursor.ARROW);
                    renderer.updateReceptorVisuals();
                    ui.updateInstructionsText();
                } else {
                    // ENTER spritesheet mode.
                    clipEditor.toggleSpritesheetMode();
                }
            }
        }
    }
}

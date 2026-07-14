package structures.editors.noteskin;

import lime.ui.MouseCursor;
import structures.gameplay.NoteskinHandle.NoteskinReceptorProperties;
import structures.gameplay.NoteskinHandle.BasicNoteskinClip;

@:publicFields
class NoteskinEditorClipEditor {
    private inline static var MAX_KEYS = 64;

    var state:NoteskinEditorState;

    public function new(state:NoteskinEditorState) {
        this.state = state;
    }

    function getBasicClipForState(clip:NoteskinReceptorProperties, editState:EditState):BasicNoteskinClip {
        return switch(editState) {
            case IDLE: clip.idle;
            case COLOR: clip.color; // was clip.press because the ai mistook it as a type of press. I also forgot it was called "color" in the first place.
            case PRESS: clip.press;
            case CONFIRM: clip.confirm;
            default: clip.idle;
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
        return {
            idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
            color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
            holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
            holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
        };
    }

    function updateClipInConfig(index:Int, editState:EditState, clip:BasicNoteskinClip) {
        var clips = state.noteskinData.clip;
        if (clips != null && index < clips.length) {
            var currentClip = clips[index];
            switch(editState) {
                case IDLE: currentClip.idle = clip;
                case COLOR: currentClip.color = clip;
                case PRESS: currentClip.press = clip;
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

        // Check if we're in preview clips mode and trying to modify clipIndex
        if (state.selectedProperty == "clipIndex") {
            if (state.currentManiaIndex >= state.availableManiaConfigs.length) {
                trace('CLIPINDEX: Please back out of preview clip mania first, so that way you don\'t get a garbage render from it.');
                return;
            }
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
                // Create new clip if index exceeds clip count
                while (state.noteskinData.clip.length <= state.currentConfig.indexes[state.selectedIndex] && state.noteskinData.clip.length < MAX_KEYS) {
                    var defaultClip:NoteskinReceptorProperties = {
                        idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
                        color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
                    };
                    state.noteskinData.clip.push(defaultClip);
                    trace('Created new clip at index ${state.noteskinData.clip.length - 1}');
                }
                // Update maxReceptors if we're in preview mode
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
            case CLIP_POS:
                propertyToEdit = axis == "X" ? "clipX" : "clipY";
            case CLIP_SIZE:
                propertyToEdit = axis == "X" ? "clipW" : "clipH";
            case OFFSET:
                propertyToEdit = axis == "X" ? "offsX" : "offsY";
            case CLIP_ID:
                state.selectedProperty = "clipIndex";
                adjustSelectedValue(amount);
                return;
            default:
                return;
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
            // In spritesheet mode, TAB controls the selected receptor index
            if (increment > 0) {
                selectNextIndex();
            } else {
                selectPreviousIndex();
            }
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
            case IDLE: "IDLE";
            case COLOR: "COLOR";
            case PRESS: "PRESS";
            case CONFIRM: "CONFIRM";
            default: "unknown";
        }
    }

    function toggleEditMode() {
        if (state.spriteSheetMode) return;

        // Store the current mode before changing
        var previousMode = state.editMode;
        var newMode:Int = state.editMode + 1;
        if (newMode > 4) newMode = 0;

        state.editMode = newMode;

        // Reset global transform mode when leaving GLOBAL_TRANSFORM
        if (state.editMode != GLOBAL_TRANSFORM) {
            state.globalScaleMode = false;
        }

        checkInvalidClipIDPlace();

        switch(state.editMode) {
            case CLIP_POS:
                if (state.selectedProperty == "clipW" || state.selectedProperty == "clipH" ||
                    state.selectedProperty == "offsX" || state.selectedProperty == "offsY" ||
                    state.selectedProperty == "clipIndex") state.selectedProperty = "clipX";
            case CLIP_SIZE:
                if (state.selectedProperty == "clipX" || state.selectedProperty == "clipY" ||
                    state.selectedProperty == "offsX" || state.selectedProperty == "offsY" ||
                    state.selectedProperty == "clipIndex") state.selectedProperty = "clipW";
            case OFFSET:
                if (state.selectedProperty == "clipX" || state.selectedProperty == "clipY" ||
                    state.selectedProperty == "clipW" || state.selectedProperty == "clipH" ||
                    state.selectedProperty == "clipIndex") state.selectedProperty = "offsX";
            case CLIP_ID:
                if (state.selectedProperty == "clipX" || state.selectedProperty == "clipY" ||
                    state.selectedProperty == "clipW" || state.selectedProperty == "clipH" ||
                    state.selectedProperty == "offsX" || state.selectedProperty == "offsY") state.selectedProperty = "clipIndex";
            case GLOBAL_TRANSFORM:
                state.selectedProperty = "global";
        }
        trace('Edit mode: ${getEditModeName(state.editMode)}');
        state.ui.updateInstructionsText();
    }

    function checkInvalidClipIDPlace() {
        // Check if we're trying to enter CLIP_ID while in preview clips mode
        if (state.editMode == CLIP_ID && state.currentManiaIndex >= state.availableManiaConfigs.length) {
            trace('CLIPINDEX: Please back out of preview clip mania first for this mode, that way you don\'t render garbage data.');
            // Go to the next mode instead of forcing to CLIP_POS
            state.editMode++;

            // The bump only ever fires CLIP_ID -> GLOBAL_TRANSFORM, so sync the
            // per-mode state to match — same housekeeping `toggleEditMode` does
            // after it calls this function. Without this, calling
            // `checkInvalidClipIDPlace()` standalone (e.g. right after
            // `switchMania` from the input handler) leaves `selectedProperty`
            // stale and never refreshes the on-screen text, so the visual
            // edit-mode indicator stays stuck on CLIP_ID.
            if (state.editMode == GLOBAL_TRANSFORM) {
                state.selectedProperty = "global";
            }
            state.ui.updateInstructionsText();
        }
    }

    function getEditModeName(mode:EditMode):String {
        return switch(mode) {
            case CLIP_POS: "Position (clipX/Y)";
            case CLIP_SIZE: "Size (clipW/H)";
            case OFFSET: "Offset (offsX/Y)";
            case CLIP_ID: "Clip Index";
            case GLOBAL_TRANSFORM: "Thanks for playing";
            default: "Unknown";
        }
    }

    function getEditModeColor(mode:EditMode):String {
        return switch(mode) {
            case CLIP_POS: "#M6#";
            case CLIP_SIZE: "#M4#";
            case OFFSET: "#M7#";
            case CLIP_ID: "#M8#";
            default: "#M5#";
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

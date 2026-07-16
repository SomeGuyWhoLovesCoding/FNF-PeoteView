package structures.editors;

// ============================================================================
// Imports
// ============================================================================

// Standard library
import haxe.Json;
import StringTools;
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
import structures.gameplay.NoteskinHandle.TextureRotation;
import elements.Sustain;

using StringTools;

// ============================================================================
// Enums
// ============================================================================

private enum abstract EditState(Int) from Int to Int {
    var IDLE;
    var COLOR;
    var PRESS;
    var CONFIRM;
    var HOLD_BODY;
    var HOLD_TAIL;
}

private enum abstract EditMode(Int) from Int to Int {
    var CLIP_POS;
    var CLIP_SIZE;
    var OFFSET;
    var CLIP_ID;
    var GLOBAL_TRANSFORM;
}

// ============================================================================
// GUI Atlas Frame -- parsed from gui_buttons.xml (Adobe Animate export).
// ============================================================================

typedef GuiAtlasFrame = {
    var name:String;
    var x:Int;
    var y:Int;
    var width:Int;
    var height:Int;
    var frameX:Int;
    var frameY:Int;
    var frameWidth:Int;
    var frameHeight:Int;
};

// ============================================================================
// NoteskinGUISprite -- lightweight sprite for GUI button labels.
// Uses frame data parsed from gui_buttons.xml (1024x512 atlas, 25 frames).
// Each frame is rendered at its native pixel dimensions -- NO stretching.
// ============================================================================

@:publicFields
class NoteskinGUISprite implements Element {
    @posX @formula("uDisplayRotateX(aPos)")  var x:Float = 0.0;
    @posY @formula("uDisplayRotateY(aPos)") var y:Float = 0.0;

    @sizeX var w:Float = 0.0;
    @sizeY var h:Float = 0.0;

    @texX var clipX:Int = 0;
    @texY var clipY:Int = 0;
    @texW var clipWidth:Int = 191;
    @texH var clipHeight:Int = 97;

    @texPosX  var clipPosX:Int = 0;
    @texPosY  var clipPosY:Int = 0;
    @custom @varying @texSizeX var clipSizeX:Int = 191;
    @custom @varying @texSizeY var clipSizeY:Int = 97;

    @rotation @formula("uDisplayRotation(r)") var r:Float = 0.0;

    @color var c:Color = 0xFFFFFFFF;

    @color private var alphaColor:Color = 0xFFFFFFFF;

    var alpha(get, set):Float;

    inline function get_alpha() {
        return alphaColor.aF;
    }

    inline function set_alpha(value:Float) {
        value = Math.max(value, 0);
        alphaColor.luminanceF = value;
        return alphaColor.aF = value;
    }

    @varying @custom private var _flip:Float = 0.0;
    @varying @custom var plainColor:Float = 0.0;

    var flip(get, set):Bool;

    inline function get_flip() {
        return _flip != 0.0;
    }

    inline function set_flip(value:Bool) {
        _flip = value ? 1.0 : 0.0;
        return value;
    }

    var curID(default, null):Int = 0;

    var OPTIONS = { texRepeatX: false, texRepeatY: false, blend: true };

    // Atlas dimensions (1024x512)
    static inline var ATLAS_W:Int = 1024;
    static inline var ATLAS_H:Int = 512;

    // Frame data parsed from gui_buttons.xml -- 25 frames total.
    // 8 frames are 191x97 (wide), 17 frames are ~101x97 (square/trimmed).
    public static var ATLAS_FRAMES:Array<GuiAtlasFrame> = [
        { name: "instance 10000", x: 0,   y: 0,   width: 191, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10001", x: 0,   y: 97,  width: 191, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10002", x: 191, y: 0,   width: 191, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10003", x: 0,   y: 194, width: 191, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10004", x: 191, y: 97,  width: 191, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10005", x: 382, y: 0,   width: 191, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10006", x: 573, y: 0,   width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10007", x: 0,   y: 388, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10008", x: 191, y: 291, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10009", x: 382, y: 194, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10010", x: 484, y: 97,  width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10011", x: 101, y: 388, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10012", x: 292, y: 291, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10013", x: 483, y: 194, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10014", x: 202, y: 388, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10015", x: 393, y: 291, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10016", x: 303, y: 388, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10017", x: 0,   y: 291, width: 191, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10018", x: 191, y: 194, width: 191, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10019", x: 494, y: 291, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10020", x: 404, y: 388, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10021", x: 505, y: 388, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10022", x: 382, y: 97,  width: 102, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10023", x: 585, y: 97,  width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
        { name: "instance 10024", x: 584, y: 194, width: 101, height: 97, frameX: 0, frameY: 0, frameWidth: 191, frameHeight: 97 },
    ];

    static function init(program:CustomProgram, name:String, texture:Texture) {
        program.setTexture(texture, name, true);

        if (Main.current.upscale) {
            program.injectIntoFragmentShader(Shaders.UPSCALE_FRAGMENT_SHADER);
            program.setColorFormula('
                mix(iconPixel(${name}_ID, vTexCoord, vec2(clipSizeX, 0.0), vec2(clipSizeY, 0.0)), c, plainColor) * alphaColor
            ');
        }
        else {
            program.injectIntoFragmentShader('
                vec4 getTexColor( int textureID, vec4 c, float plainColor )
                {
                    return mix(getTextureColor(textureID, vTexCoord), c, plainColor);
                }
            ');
            program.setColorFormula('getTexColor(${name}_ID, c, plainColor) * alphaColor');
        }
    }

    function new() {}

    /**
        Set this sprite to display frame `id` (0-17).
        Uses ATLAS_FRAMES for all UV and size data -- pixel-perfect, no stretching.
    */
    inline function changeID(id:Int) {
        if (id < 0) id = 0;
        if (id >= ATLAS_FRAMES.length) id = ATLAS_FRAMES.length - 1;
        var f = ATLAS_FRAMES[id];
        // Inset UV rectangle by 1px on each edge to prevent adjacent-frame
        // bleeding caused by GPU texel interpolation at subpixel boundaries.
        clipX = f.x + 1;
        clipY = f.y + 1;
        clipWidth = f.width - 2;
        clipHeight = f.height - 2;
        clipSizeX = f.width - 2;
        clipSizeY = f.height - 2;
        w = f.width;
        h = f.height;
        curID = id;
    }
}

// ============================================================================
// GridBackgroundSprite -- square sprite for the scrolling grid background.
// Uses texture repeat (texRepeatX/Y = true) to tile a grid pattern infinitely.
// Sprite x/y positions (Float) are shifted for smooth diagonal scrolling.
// Four squares in a 2x2 arrangement cover the viewport seamlessly.
// ============================================================================

@:publicFields
class GridBackgroundSprite implements Element {
    @posX var x:Float = 0.0;
    @posY var y:Float = 0.0;
    @sizeX var w:Float = 0.0;
    @sizeY var h:Float = 0.0;

    @texX var clipX:Int = 0;
    @texY var clipY:Int = 0;
    @texW var clipWidth:Int = 64;
    @texH var clipHeight:Int = 64;

    @texPosX var clipPosX:Int = 0;
    @texPosY var clipPosY:Int = 0;
    @custom @varying @texSizeX var clipSizeX:Int = 64;
    @custom @varying @texSizeY var clipSizeY:Int = 64;

    @color var c:Color = 0xFFFFFFFF;

    var OPTIONS = { texRepeatX: true, texRepeatY: true, blend: false };

    // Size of one grid tile (64x64 = 2x2 checkerboard duplicated 32x32).
    static inline var TILE_SIZE:Int = 64;

    static function init(program:CustomProgram, name:String, texture:Texture) {
        program.setTexture(texture, name, true);

        if (Main.current.upscale) {
            program.injectIntoFragmentShader(Shaders.UPSCALE_FRAGMENT_SHADER);
            program.setColorFormula('
                iconPixel(${name}_ID, vTexCoord, vec2(clipSizeX, 0.0), vec2(clipSizeY, 0.0))
            ');
        }
        else {
            program.injectIntoFragmentShader('
                vec4 getBgTexColor(int textureID, vec4 c)
                {
                    return getTextureColor(textureID, vTexCoord);
                }
            ');
            program.setColorFormula('getBgTexColor(${name}_ID, c)');
        }
    }

    function new() {}
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
            case IDLE:      clip.idle;
            case COLOR:     clip.color;
            case PRESS:     clip.press;
            case CONFIRM:   clip.confirm;
            case HOLD_BODY: clip.holdBody;
            case HOLD_TAIL: clip.holdTail;
            default:        clip.idle;
        }
    }

    /** Get the indexes array for a given edit state. */
    function getIndexesForState(editState:EditState):Array<Int> {
        var cfg = state.currentConfig;
        return switch(editState) {
            case IDLE:      cfg.idleIndexes;
            case COLOR:     cfg.colorIndexes;
            case PRESS:     cfg.pressIndexes;
            case CONFIRM:   cfg.confirmIndexes;
            case HOLD_BODY: cfg.holdBodyIndexes;
            case HOLD_TAIL: cfg.holdTailIndexes;
            default:        cfg.idleIndexes;
        };
    }

    function getClipIndexForReceptor(index:Int):Int {
        var idxArr = getIndexesForState(state.currentState);
        if (idxArr != null && index < idxArr.length) {
            return idxArr[index];
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
                case IDLE:      currentClip.idle = clip;
                case COLOR:     currentClip.color = clip;
                case PRESS:     currentClip.press = clip;
                case CONFIRM:   currentClip.confirm = clip;
                case HOLD_BODY: currentClip.holdBody = clip;
                case HOLD_TAIL: currentClip.holdTail = clip;
                default:
            }
        }
    }

    // for one purpose, to actually see
    function getClipValue(clip:BasicNoteskinClip):Int {
        switch(state.selectedProperty) {
            case "clipX": return clip.clipX;
            case "clipY": return clip.clipY;
            case "clipW": return clip.clipW;
            case "clipH": return clip.clipH;
            case "offsX": return clip.offsX;
            case "offsY": return clip.offsY;
            case "clipIndex":
                var idxArr = getIndexesForState(state.currentState);
                if (idxArr != null && state.selectedIndex < idxArr.length) {
                    return idxArr[state.selectedIndex];
                }
                return state.selectedIndex;
            case "rotation": return clip.rotation.toDegrees();
            default: return 0;
        }
    }

    function adjustSelectedValue(amount:Int) {
        if (state.spriteSheetMode) return;

        // Block property modifications when the selected receptor is off-screen.
        if (!isReceptorOnScreen(state.selectedIndex)) return;

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
                var idxArr = getIndexesForState(state.currentState);
                if (idxArr == null) {
                    idxArr = [];
                    switch(state.currentState) {
                        case IDLE:      state.currentConfig.idleIndexes = idxArr;
                        case COLOR:     state.currentConfig.colorIndexes = idxArr;
                        case PRESS:     state.currentConfig.pressIndexes = idxArr;
                        case CONFIRM:   state.currentConfig.confirmIndexes = idxArr;
                        case HOLD_BODY: state.currentConfig.holdBodyIndexes = idxArr;
                        case HOLD_TAIL: state.currentConfig.holdTailIndexes = idxArr;
                        default:        state.currentConfig.idleIndexes = idxArr;
                    }
                }
                while (idxArr.length <= state.selectedIndex) {
                    idxArr.push(idxArr.length);
                }
                if (idxArr[state.selectedIndex] + amount >= MAX_KEYS) {
                    idxArr[state.selectedIndex] = MAX_KEYS - 1;
                    trace('CLIPINDEX: Max indexes reached. (attempted $MAX_KEYS+1)');
                    return;
                }
                idxArr[state.selectedIndex] += amount;
                if (idxArr[state.selectedIndex] < 0) {
                    idxArr[state.selectedIndex] = 0;
                }
                // Auto-create new clips if the index exceeds the current clip count.
                while (state.noteskinData.clip.length <= idxArr[state.selectedIndex]
                       && state.noteskinData.clip.length < MAX_KEYS) {
                    state.noteskinData.clip.push(defaultClip());
                    trace('Created new clip at index ${state.noteskinData.clip.length - 1}');
                }
                // Update maxReceptors if we're in preview mode.
                if (state.currentManiaIndex == state.availableManiaConfigs.length) {
                    state.maxReceptors = state.noteskinData.clip.length;
                    var fillIdx = [for (i in 0...state.noteskinData.clip.length) i];
                    state.currentConfig.idleIndexes = fillIdx.copy();
                    state.currentConfig.pressIndexes = fillIdx.copy();
                    state.currentConfig.colorIndexes = fillIdx.copy();
                    state.currentConfig.confirmIndexes = fillIdx.copy();
                    state.currentConfig.holdBodyIndexes = fillIdx.copy();
                    state.currentConfig.holdTailIndexes = fillIdx.copy();
                }
            case "rotation":
                if (amount > 0) basicClip.rotation = basicClip.rotation.next();
                else if (amount < 0) basicClip.rotation = basicClip.rotation.prev();
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
            // In spritesheet mode, left/right controls the selected receptor index instead.
            if (increment > 0) selectNextIndex();
            else                selectPreviousIndex();
            return;
        }
        var newState:Int = state.currentState + increment;
        if (newState < 0) newState = 5;
        if (newState >= 6) newState = 0;
        state.renderer.updateReceptorState(newState);
        trace('State changed to: ${getStateName(state.currentState)}');
    }

    function toggleStateEqual(currentState:EditState) {
        if (state.spriteSheetMode) {
            return;
        }
        var newState:Int = currentState;
        if (newState < 0) newState = 5;
        if (newState >= 6) newState = 0;
        state.renderer.updateReceptorState(currentState);
        trace('State changed to: ${getStateName(state.currentState)}');
    }

    function getStateName(editState:EditState):String {
        return switch(editState) {
            case IDLE:      "IDLE";
            case COLOR:     "COLOR";
            case PRESS:     "PRESS";
            case CONFIRM:   "CONFIRM";
            case HOLD_BODY: "SUST. NOTE";
            case HOLD_TAIL: "SUST. TAIL";
            default:        "unknown";
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

    /** Jump directly to a specific edit mode (used by ALT+1..4 keybinds).
        Mirrors toggleEditMode's bookkeeping: clears globalScaleMode when
        leaving GLOBAL_TRANSFORM, runs checkInvalidClipIDPlace, and resets
        selectedProperty to the new mode's default. **/
    function setEditMode(idx:Int) {
        if (state.spriteSheetMode) return;
        if (idx < 0 || idx > 4) return;

        state.editMode = idx;
        if (state.editMode != GLOBAL_TRANSFORM) {
            state.globalScaleMode = false;
        }
        checkInvalidClipIDPlace();

        // Reset selectedProperty to the new mode's default so the
        // arrow-key editor lands on a sensible axis immediately.
        switch(state.editMode) {
            case CLIP_POS:          state.selectedProperty = "clipX";
            case CLIP_SIZE:         state.selectedProperty = "clipW";
            case OFFSET:            state.selectedProperty = "offsX";
            case CLIP_ID:           state.selectedProperty = "clipIndex";
            case GLOBAL_TRANSFORM:  state.selectedProperty = "global";
        }

        trace('Edit mode set to: ${getEditModeName(state.editMode)}');
        state.ui.updateInstructionsText();
    }

    function checkInvalidClipIDPlace() {
        // Bump out of CLIP_ID when entering preview-clips mania — would render garbage data.
        if (state.editMode == CLIP_ID && state.currentManiaIndex >= state.availableManiaConfigs.length) {
            trace('CLIPINDEX: Please back out of preview clip mania first for this mode, that way you don\'t render garbage data.');
            state.editMode = GLOBAL_TRANSFORM;
            state.selectedProperty = "global";
            state.ui.updateInstructionsText();
        }
    }

    function getEditModeName(mode:EditMode):String {
        return switch(mode) {
            case CLIP_POS:          "Position (clipX/Y)";
            case CLIP_SIZE:         "Size (clipW/H)";
            case OFFSET:            "Offset (offsX/Y)";
            case CLIP_ID:           "Clip Index";
            case GLOBAL_TRANSFORM:  "Thanks for playing";
            default:                "Unknown";
        }
    }

    function getEditModeColor(mode:EditMode):String {
        return switch(mode) {
            case CLIP_POS:          "#M6#";
            case CLIP_SIZE:         "#M4#";
            case OFFSET:            "#M7#";
            case CLIP_ID:           "#M8#";
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

    /** Cycle the rotation of hold body and hold tail clips.
        direction > 0 = next, direction < 0 = prev.
        Always targets holdBody + holdTail since the Sustain shader
        applies a single texRotation to both body and tail sampling. */
    function rotateCurrentClip(direction:Int) {
        if (state.spriteSheetMode) return;

        var clipIndex = getClipIndexForReceptor(state.selectedIndex);
        var clip = getClipForIndex(clipIndex);

        var newRotation:TextureRotation =
            if (direction > 0) clip.holdBody.rotation.next()
            else               clip.holdBody.rotation.prev();

        clip.holdBody.rotation = newRotation;
        clip.holdTail.rotation = newRotation;

        updateClipInConfig(clipIndex, HOLD_BODY, clip.holdBody);
        updateClipInConfig(clipIndex, HOLD_TAIL, clip.holdTail);
        state.renderer.updateSustainVisuals();
        trace('holdBody.rotation = holdTail.rotation = ${newRotation}\u00b0');
        state.ui.updateInstructionsText();
    }

    /** Adjust the visual rotation (r) of a sustain sprite by the given degrees. */
    function rotateSustainSprite(receptorIndex:Int, degrees:Float) {
        if (state.spriteSheetMode) return;
        if (receptorIndex < 0 || receptorIndex >= state.maxReceptors) return;

        // Ensure the array is large enough
        while (state.sustainRotations.length <= receptorIndex) {
            state.sustainRotations.push(0.0);
        }

        state.sustainRotations[receptorIndex] += degrees;

        // Apply to the actual sustain sprite if it exists
        if (receptorIndex < state.sustainSprites.length) {
            var s = state.sustainSprites[receptorIndex];
            if (s != null) {
                s.r = state.sustainRotations[receptorIndex];
                if (state.sustainBuf != null) {
                    state.sustainBuf.updateElement(s);
                    state.sustainBuf.update();
                }
            }
        }

        trace('sustain[${receptorIndex}].r = ${state.sustainRotations[receptorIndex]}\u00b0');
        state.ui.updateInstructionsText();
    }

    /**
        Returns the index of the receptor whose sprite contains the given
        screen coordinates, or -1 if no receptor is hit. Uses the same bounds
        logic as `handleMouseDown` (note.x/y/w/h, no offset).
    **/
    function findReceptorAt(mouseX:Float, mouseY:Float):Int {
        var scale = state.currentConfig.scale;
        for (i in 0...state.receptorSprites.length) {
            var note = state.receptorSprites[i];
            var sw = note.w * scale;
            var sh = note.h * scale;
            if (mouseX >= note.x && mouseX <= note.x + sw
                && mouseY >= note.y && mouseY <= note.y + sh) {
                return i;
            }
        }
        return -1;
    }

    /** Returns true if the receptor at the given index is at least
        partially visible on screen.  Returns false when the entire
        sprite rectangle is outside the viewport. */
    function isReceptorOnScreen(index:Int):Bool {
        if (index < 0 || index >= state.receptorSprites.length) return false;
        var note = state.receptorSprites[index];
        if (note == null) return false;
        var scale = state.currentConfig.scale;
        var sw = note.w * scale;
        var sh = note.h * scale;
        return (note.x + sw > 0 && note.x < Main.INITIAL_WIDTH
             && note.y + sh > 0 && note.y < Main.INITIAL_HEIGHT);
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

            // Generate default 1K-4K configs if none exist.
            if (state.availableManiaConfigs.length == 0) {
                for (k in 1...5) {
                    var idx = [for (j in 0...k) j];
                    state.availableManiaConfigs.push({
                        offsetX: 0, offsetY: 0, gap: 112, scale: 1.0,
                        idleIndexes: idx.copy(), pressIndexes: idx.copy(), colorIndexes: idx.copy(),
                        confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
                    });
                }
            }

            // Recreate full 1K-NK mania range and ensure enough clips.
            var clips = state.noteskinData.clip;
            var totalClips = clips != null ? clips.length : 0;
            var highestManiaKeys = 0;
            for (cfg in state.availableManiaConfigs) {
                if (cfg.idleIndexes != null && cfg.idleIndexes.length > highestManiaKeys)
                    highestManiaKeys = cfg.idleIndexes.length;
            }
            var targetKeys = Std.int(Math.max(totalClips, highestManiaKeys));
            if (targetKeys > 0) {
                // Clear existing manias and recreate 1K through NK.
                state.availableManiaConfigs = [];
                for (k in 1...targetKeys + 1) {
                    var idx = [for (j in 0...k) j];
                    state.availableManiaConfigs.push({
                        offsetX: 0, offsetY: 0, gap: 112, scale: 1.0,
                        idleIndexes: idx.copy(), pressIndexes: idx.copy(), colorIndexes: idx.copy(),
                        confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
                    });
                }
                sortManiasByKeyCount();
                // Ensure clips exist for every index the highest mania references.
                while (clips.length < targetKeys) {
                    clips.push(NoteskinEditorClipEditor.defaultClip());
                }
            }

            state.currentManiaIndex = Std.int(Math.max(state.currentManiaIndex, state.availableManiaConfigs.length - 1));
            state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];

            updateMaxReceptorsFromConfig();

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
            var idx = [0, 1, 2, 3];
            var defaultData = {
                name: "default",
                sparrowImg: "sheet.png",
                configMania: [{
                    offsetX: 0, offsetY: 0, gap: 112, scale: 1.0,
                    idleIndexes: idx.copy(), pressIndexes: idx.copy(), colorIndexes: idx.copy(),
                    confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
                }],
                clip: [
                    {
                        idle:     {clipX: 3,   clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        press:    {clipX: 115, clipY: 229, clipW: 99,  clipH: 100, offsX: 0, offsY: 0},
                        color:    {clipX: 115, clipY: 116, clipW: 108, clipH: 110, offsX: 0, offsY: 0},
                        confirm:  {clipX: 3,   clipY: 3,   clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 229, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 3,   clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
                    },
                    {
                        idle:     {clipX: 346, clipY: 3,   clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        press:    {clipX: 3,   clipY: 230, clipW: 99,  clipH: 98,  offsX: 0, offsY: 0},
                        color:    {clipX: 3,   clipY: 3,   clipW: 112, clipH: 110, offsX: 0, offsY: 0},
                        confirm:  {clipX: 246, clipY: 3,   clipW: 189, clipH: 189, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 262, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 51,  clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
                    },
                    {
                        idle:     {clipX: 233, clipY: 3,   clipW: 110, clipH: 111, offsX: 0, offsY: 0},
                        press:    {clipX: 217, clipY: 230, clipW: 97,  clipH: 99,  offsX: 0, offsY: 0},
                        color:    {clipX: 226, clipY: 117, clipW: 108, clipH: 110, offsX: 0, offsY: 0},
                        confirm:  {clipX: 197, clipY: 249, clipW: 193, clipH: 189, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 295, clipW: 35,  clipH: 30,  offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 147, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
                    },
                    {
                        idle:     {clipX: 346, clipY: 115, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        press:    {clipX: 337, clipY: 227, clipW: 101, clipH: 99,  offsX: 0, offsY: 0},
                        color:    {clipX: 118, clipY: 3,   clipW: 112, clipH: 110, offsX: 0, offsY: 0},
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
        var idxArr = state.currentConfig.idleIndexes;
        if (idxArr != null && idxArr.length > 0) {
            state.maxReceptors = idxArr.length;
        } else {
            state.maxReceptors = 4;
        }
    }

    function generateManiaFromClips():NoteskinConfig {
        // Preview mania — one index per clip.
        var clipCount = state.noteskinData.clip != null ? state.noteskinData.clip.length : 0;
        var idx = [for (i in 0...clipCount) i];
        return {
            offsetX: 0, offsetY: 0, gap: 114, scale: 1.0,
            idleIndexes: idx, pressIndexes: idx.copy(), colorIndexes: idx.copy(),
            confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
        };
    }

    /** Save the current noteskin data back to data.json, overwriting the file. */
    function saveNoteskin() {
        try {
            // Sync the current mania config back into the data.
            state.noteskinData.configMania = state.availableManiaConfigs;

            var skinFolder = 'assets/images/noteskins/${state.currentSkinName}';
            var dataPath = Paths.asset('$skinFolder/data.json');
            var jsonStr = haxe.Json.stringify(state.noteskinData, null, "  ");
            Sys_Fili.saveContent(dataPath, jsonStr);

            trace('Noteskin saved to $dataPath');
        } catch (e) {
            trace('Failed to save noteskin: $e');
        }
    }

    function switchMania(direction:Int) {
        if (state.availableManiaConfigs.length == 0) return;

        var totalManias = state.availableManiaConfigs.length + 1; // +1 for preview mania
        var newIndex = state.currentManiaIndex + direction;
        if (newIndex < 0) newIndex = totalManias - 1;
        if (newIndex >= totalManias) newIndex = 0;

        state.currentManiaIndex = newIndex;

        // Reset preview scroll when switching manias
        state.previewScrollOffset = 0;
        state.isPreviewScrolling = false;

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

        // Remove any stale popup backgrounds.
        if (state.popupBackground != null) {
            state.gridBuf.removeElement(state.popupBackground);
            state.popupBackground = null;
        }

        if (state.instructionsBackground != null) {
            state.gridBuf.removeElement(state.instructionsBackground);
            state.instructionsBackground = null;
        }

        trace('Create Mania popup opened - Enter number of keys');
    }

    function createDefaultNoteskin() {
        var idx = [0, 1, 2, 3];
        state.noteskinData = {
            name: "default",
            sparrowImg: "sheet.png",
            configMania: [{
                offsetX: 0, offsetY: 0, gap: 112, scale: 1.0,
                idleIndexes: idx.copy(), pressIndexes: idx.copy(), colorIndexes: idx.copy(),
                confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
            }],
            clip: []
        };
        state.availableManiaConfigs = state.noteskinData.configMania.copy();
        state.currentManiaIndex = Std.int(Math.max(state.currentManiaIndex, state.availableManiaConfigs.length - 1));
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
            if (config.idleIndexes != null && config.idleIndexes.length == keyCount) {
                state.createManiaError = 'Mania with $keyCount keys already exists!';
                return;
            }
        }

        var idx = [for (i in 0...keyCount) i];
        var newMania:NoteskinConfig = {
            offsetX: 0, offsetY: 0, gap: 112, scale: 1.0,
            idleIndexes: idx.copy(), pressIndexes: idx.copy(), colorIndexes: idx.copy(),
            confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
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

        if (state.instructionsText != null) {
            state.instructionsText.alpha = 0;
        }
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
            if (config.idleIndexes != null) {
                existingKeyCounts.push(config.idleIndexes.length);
            }
        }

        // Fill in missing manias from 1 to maxKeys.
        // Each filled mania goes through the same setup as confirmCreateMania:
        // sort, select, update maxReceptors, ensure clips, rebuild receptors,
        // refresh visuals/instructions, and trace.
        for (i in 1...maxKeys) {
            if (existingKeyCounts.indexOf(i) != -1) continue;

            var idx = [for (j in 0...i) j];
            var newMania:NoteskinConfig = {
                offsetX: 0, offsetY: 0, gap: 112, scale: 1.0,
                idleIndexes: idx.copy(), pressIndexes: idx.copy(), colorIndexes: idx.copy(),
                confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
            };

            state.availableManiaConfigs.push(newMania);

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
                trace('Auto-created mania with $i keys');
            }
        }
    }

    function cancelCreateMania() {
        state.createManiaPopupActive = false;
        state.createManiaInput = "";
        state.createManiaError = "";

        // Hide the popup text and remove the popup overlay.
        if (state.instructionsText != null) {
            state.instructionsText.alpha = 0;
        }
        if (state.popupBackground != null) {
            state.gridBuf.removeElement(state.popupBackground);
            state.popupBackground = null;
        }
        state.gridBuf.update();

        trace('Create Mania cancelled');
    }

    function sortManiasByKeyCount() {
        // Dedupe by key count, then sort ascending.
        var seenKeyCounts:Array<Int> = [];
        var uniqueManias:Array<NoteskinConfig> = [];

        for (config in state.availableManiaConfigs) {
            if (config.idleIndexes != null) {
                var keyCount = config.idleIndexes.length;
                if (seenKeyCounts.indexOf(keyCount) == -1) {
                    seenKeyCounts.push(keyCount);
                    uniqueManias.push(config);
                }
            }
        }

        state.availableManiaConfigs = uniqueManias;
        state.availableManiaConfigs.sort(function(a:NoteskinConfig, b:NoteskinConfig) {
            var lenA = a.idleIndexes != null ? a.idleIndexes.length : 0;
            var lenB = b.idleIndexes != null ? b.idleIndexes.length : 0;
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

    /** Import clip data from a vanilla FNF-style Sparrow/Starling texture atlas XML.

        Naming convention (case-insensitive, only first frame kept):
          - `arrow{DIR}0000`              -> idle       (e.g. "arrowLEFT0000")
          - `{DIR} press0000`             -> press      (e.g. "left press0000")
          - `{DIR} confirm0000`           -> confirm    (e.g. "left confirm0000")
          - `{COLOR}0000`                 -> color      (e.g. "purple0000")
          - `{COLOR} hold piece0000`      -> holdBody   (e.g. "purple hold piece0000")
          - `{COLOR} hold end0000`        -> holdTail   (e.g. "purple hold end0000")
          - `{COLOR} end hold0000`        -> holdTail   (typo variant)

        Directions assigned receptors in FNF standard order: left, down, up, right.
        Colors map to directions via vanilla FNF mapping:
          purple -> left, blue -> down, green -> up, red -> right.
    **/

    /** Returns true if every term in `terms` is found (case-insensitive) in `haystack`, regardless of order. */
    static function allTermsPresent(haystack:String, terms:Array<String>):Bool {
        var lower = haystack.toLowerCase();
        for (t in terms) {
            if (lower.indexOf(t.toLowerCase()) == -1)
                return false;
        }
        return true;
    }

    function importFromAtlas() {
        var skinFolder = 'assets/images/noteskins/${state.currentSkinName}';
        var pngName = state.noteskinData.sparrowImg;
        var dotIdx = pngName.lastIndexOf(".");
        var prefix = dotIdx > 0 ? pngName.substring(0, dotIdx) : pngName;
        var xmlPath = Paths.asset('$skinFolder/$prefix.xml');

        if (!FileSystem.exists(xmlPath)) {
            trace('Atlas XML not found: $xmlPath');
            return;
        }

        try {
            var xmlContent = Sys_Fili.getContent(xmlPath);
            var xml = Xml.parse(xmlContent);
            var root = xml.firstElement();
            if (root == null) {
                trace('Atlas XML has no root element');
                return;
            }

            // Vanilla FNF direction order (left, down, up, right).
            var vanillaDirOrder = ["left", "down", "up", "right"];

            // Vanilla FNF color -> direction mapping.
            var colorToDir = new Map<String, String>();
            colorToDir.set("purple", "left");
            colorToDir.set("blue", "down");
            colorToDir.set("green", "up");
            colorToDir.set("red", "right");

            var knownColors = ["purple", "blue", "green", "red", "yellow", "pink", "orange", "cyan", "white"];
            var knownDirs = ["left", "down", "up", "right"];

            // --- Pass 1: classify every SubTexture, only keep first frame ---

            var entries:Array<{group:String, clipType:String, x:Int, y:Int, w:Int, h:Int, offsX:Int, offsY:Int}> = [];
            var seenKeys = new Map<String, Bool>();

            for (elem in root.elements()) {
                if (elem.nodeName != "SubTexture") continue;

                var name = elem.get("name");
                if (name == null) continue;

                var sx = Std.parseInt(elem.get("x"));
                var sy = Std.parseInt(elem.get("y"));
                var sw = Std.parseInt(elem.get("width"));
                var sh = Std.parseInt(elem.get("height"));
                if (sx == null || sy == null || sw == null || sh == null) continue;

                var sox = Std.parseInt(elem.get("frameX"));
                var soy = Std.parseInt(elem.get("frameY"));
                var ox = sox != null ? sox : 0;
                var oy = soy != null ? soy : 0;

                var nameLower = name.toLowerCase();

                // Trim last 4 characters (Sparrow frame number, e.g. "0000").
                var trimmed = nameLower;
                if (trimmed.length > 4) trimmed = trimmed.substring(0, trimmed.length - 4);
                if (trimmed.length > 0 && trimmed.charAt(trimmed.length - 1) == " ")
                    trimmed = trimmed.substring(0, trimmed.length - 1);
                if (trimmed.length == 0) continue;

                // --- Clip type detection (vanilla FNF format) ---

                var clipType:String = null;
                var groupKeyword:String = null;

                // "arrow{DIR}" camelCase or "arrow {DIR}" -> idle
                if (StringTools.startsWith(trimmed, "arrow")) {
                    var dirPart = trimmed.substring(5);
                    if (StringTools.startsWith(dirPart, " ")) dirPart = dirPart.substring(1);
                    for (d in knownDirs) {
                        if (dirPart == d) {
                            clipType = "idle";
                            groupKeyword = d;
                            break;
                        }
                    }
                }

                if (clipType == null) {
                    // "{DIR} confirm" -> confirm
                    for (d in knownDirs) {
                        if (allTermsPresent(trimmed, [d, "confirm"])) {
                            clipType = "confirm";
                            groupKeyword = d;
                            break;
                        }
                    }
                }

                if (clipType == null) {
                    // "{DIR} press" -> press
                    for (d in knownDirs) {
                        if (allTermsPresent(trimmed, [d, "press"])) {
                            clipType = "press";
                            groupKeyword = d;
                            break;
                        }
                    }
                }

                if (clipType == null) {
                    // Color-based entries
                    var foundColor:String = null;
                    for (c in knownColors) {
                        if (trimmed.indexOf(c) != -1) { foundColor = c; break; }
                    }
                    if (foundColor == null && trimmed.indexOf("pruple") != -1) foundColor = "pruple";

                    if (foundColor != null) {
                        if (allTermsPresent(trimmed, ["hold", "piece"])) {
                            clipType = "holdBody";
                            groupKeyword = foundColor;
                        } else if (allTermsPresent(trimmed, ["hold", "end"]) || allTermsPresent(trimmed, ["end", "hold"])) {
                            clipType = "holdTail";
                            groupKeyword = foundColor;
                        } else if (trimmed == foundColor) {
                            clipType = "color";
                            groupKeyword = foundColor;
                        }
                    }
                }

                if (clipType == null || groupKeyword == null) continue;

                // Normalize typo "pruple" -> "purple"
                if (groupKeyword == "pruple") groupKeyword = "purple";

                // Dedup: only keep first frame per (group, clipType).
                var dedupKey = groupKeyword + ":" + clipType;
                if (seenKeys.exists(dedupKey)) continue;
                seenKeys.set(dedupKey, true);

                entries.push({group: groupKeyword, clipType: clipType, x: sx, y: sy, w: sw, h: sh, offsX: ox, offsY: oy});
            }

            if (entries.length == 0) {
                trace('No valid SubTexture entries found in $xmlPath');
                return;
            }

            // --- Pass 2: determine receptors, map groups, assign clips ---

            // Collect direction groups in vanilla order.
            var dirGroupsFound:Array<String> = [];
            for (d in vanillaDirOrder) {
                for (e in entries) {
                    if (e.group == d) { dirGroupsFound.push(d); break; }
                }
            }

            // Collect color groups in known order.
            var colorGroupsFound:Array<String> = [];
            for (c in knownColors) {
                for (e in entries) {
                    if (e.group == c) { colorGroupsFound.push(c); break; }
                }
            }

            // Use direction groups as receptors (standard vanilla order).
            var receptorNames = dirGroupsFound.length > 0 ? dirGroupsFound : colorGroupsFound;

            var keyCount = receptorNames.length;
            if (keyCount == 0) {
                trace('No receptor groups found in $xmlPath');
                return;
            }

            // Clear ALL existing clips and create exactly keyCount new ones.
            state.noteskinData.clip = [];
            var clips = state.noteskinData.clip;
            for (i in 0...keyCount) {
                clips.push(NoteskinEditorClipEditor.defaultClip());
            }

            // Build group -> receptor index map.
            var groupToReceptor = new Map<String, Int>();
            for (i in 0...receptorNames.length)
                groupToReceptor.set(receptorNames[i], i);

            // Map color groups to receptors via vanilla color->direction mapping.
            var colorToReceptor = new Map<String, Int>();
            for (c in colorGroupsFound) {
                var targetDir = colorToDir.get(c);
                if (targetDir != null) {
                    var ri = groupToReceptor.get(targetDir);
                    if (ri != null) colorToReceptor.set(c, ri);
                }
            }

            // Assign entries into clip slots.
            for (entry in entries) {
                var receptorIndex = groupToReceptor.get(entry.group);
                if (receptorIndex == null)
                    receptorIndex = colorToReceptor.get(entry.group);
                if (receptorIndex == null) continue;

                var clipData:BasicNoteskinClip = {
                    clipX: entry.x, clipY: entry.y,
                    clipW: entry.w, clipH: entry.h,
                    offsX: entry.offsX, offsY: entry.offsY,
                    rotation: TextureRotation.POS0
                };

                var clip = clips[receptorIndex];
                switch (entry.clipType) {
                    case "idle":     clip.idle = clipData;
                    case "press":    clip.press = clipData;
                    case "confirm":  clip.confirm = clipData;
                    case "color":    clip.color = clipData;
                    case "holdBody": clip.holdBody = clipData;
                    case "holdTail": clip.holdTail = clipData;
                    default:
                }

                trace('Imported: ${entry.group} ${entry.clipType} [receptor $receptorIndex] (${entry.x}, ${entry.y}, ${entry.w}, ${entry.h}) offs(${entry.offsX}, ${entry.offsY})');
            }

            // Ensure a mania config exists for this key count.
            var configs = state.noteskinData.configMania;
            var foundConfig:NoteskinConfig = null;
            for (cfg in configs) {
                if (cfg.idleIndexes != null && cfg.idleIndexes.length == keyCount) {
                    foundConfig = cfg;
                    break;
                }
            }
            if (foundConfig == null) {
                var idx = [for (i in 0...keyCount) i];
                foundConfig = {
                    offsetX: 0, offsetY: 0, gap: 112, scale: 1.0,
                    idleIndexes: idx.copy(), pressIndexes: idx.copy(), colorIndexes: idx.copy(),
                    confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
                };
                configs.push(foundConfig);
                trace('Created new mania config for $keyCount keys');
            }

            // Mirror confirmCreateMania: after ensuring the keyCount config
            // exists, fill in 1K..(NK-1)K so the mania bar shows the full
            // 1K-NK range with NK active (e.g. [4/4 - 4K]).
            state.availableManiaConfigs = configs.copy();
            fillMissingManias(keyCount);
            sortManiasByKeyCount();

            // After sort, refetch the index of the just-imported keyCount
            // config (sort may have moved it).
            var newIndex = state.availableManiaConfigs.indexOf(foundConfig);
            if (newIndex != -1) {
                state.currentManiaIndex = newIndex;
                state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];
            } else {
                state.currentConfig = foundConfig;
            }
            updateMaxReceptorsFromConfig();

            if (state.selectedIndex >= state.maxReceptors) {
                state.selectedIndex = state.maxReceptors - 1;
            }

            // Refresh everything.
            state.renderer.createReceptors();
            state.renderer.createSustains();
            state.renderer.updateReceptorVisuals();
            if (state.showSustainPreview) state.renderer.updateSustainVisuals();
            state.ui.updateInstructionsText();

            trace('Vanilla import complete: ${entries.length} entries, $keyCount receptors (${receptorNames.join(", ")}) from $xmlPath');
            if (dirGroupsFound.length > 0) {
                trace('Direction groups: ${dirGroupsFound.join(", ")}');
                if (colorGroupsFound.length > 0) trace('Color groups: ${colorGroupsFound.join(", ")}');
            } else {
                trace('Groups: ${receptorNames.join(", ")}');
            }
        } catch (e) {
            trace('Failed to import vanilla atlas: $e');
        }
    }

    /** Import clip data from an 18K+ letter-based Sparrow/Starling atlas XML.

        Naming convention (case-insensitive):
          - `{L}0000`              -> idle        (e.g. "A0000")
          - `{L} press0000`       -> press       (e.g. "A press0000")
          - `{L} confirm0000`     -> confirm     (e.g. "A confirm0000")
          - `{L} hold0000`        -> holdBody    (e.g. "A hold0000")
          - `{L} tail0000`        -> holdTail    (e.g. "A tail0000")

        `{L}` is a single uppercase letter (A-Z).  Each unique letter
        becomes one receptor, sorted alphabetically (A=0, B=1, ...).
        Animation frames beyond 0000 are skipped (first frame kept).
        Entries whose group is not a single letter (arrow*, kill, live, etc.)
        are ignored.
    **/
    function importFromAtlas18K() {
        var skinFolder = 'assets/images/noteskins/${state.currentSkinName}';
        var pngName = state.noteskinData.sparrowImg;
        var dotIdx = pngName.lastIndexOf(".");
        var prefix = dotIdx > 0 ? pngName.substring(0, dotIdx) : pngName;
        var xmlPath = Paths.asset('$skinFolder/$prefix.xml');

        if (!FileSystem.exists(xmlPath)) {
            trace('Atlas XML not found: $xmlPath');
            return;
        }

        try {
            var xmlContent = Sys_Fili.getContent(xmlPath);
            var xml = Xml.parse(xmlContent);
            var root = xml.firstElement();
            if (root == null) {
                trace('Atlas XML has no root element');
                return;
            }

            // --- Pass 1: classify every SubTexture into (group, clipType) ---

            var entries:Array<{group:String, clipType:String, x:Int, y:Int, w:Int, h:Int, offsX:Int, offsY:Int}> = [];
            var seen = new Map<String, Bool>();

            for (elem in root.elements()) {
                if (elem.nodeName != "SubTexture") continue;

                var name = elem.get("name");
                if (name == null) continue;

                var sx = Std.parseInt(elem.get("x"));
                var sy = Std.parseInt(elem.get("y"));
                var sw = Std.parseInt(elem.get("width"));
                var sh = Std.parseInt(elem.get("height"));
                if (sx == null || sy == null || sw == null || sh == null) continue;

                // Sparrow trimmed-frame offsets (frameX/frameY)
                var sox = Std.parseInt(elem.get("frameX"));
                var soy = Std.parseInt(elem.get("frameY"));
                var ox = sox != null ? sox : 0;
                var oy = soy != null ? soy : 0;

                var nameLower = name.toLowerCase();

                // Trim last 4 characters (Sparrow frame number, e.g. "0000").
                var trimmed = nameLower;
                if (trimmed.length > 4) trimmed = trimmed.substring(0, trimmed.length - 4);
                // Strip trailing space left after digit removal.
                if (trimmed.length > 0 && trimmed.charAt(trimmed.length - 1) == " ")
                    trimmed = trimmed.substring(0, trimmed.length - 1);
                if (trimmed.length == 0) continue;

                // Group: first character must be a single letter a-z.
                // Reject multi-word names where the first word is longer than 1 char
                // (e.g. "arrowcircle", "kill", "live").
                var firstChar = trimmed.charAt(0);
                if (firstChar < 'a' || firstChar > 'z') continue;

                var sp = trimmed.indexOf(" ");
                if (sp == -1 && trimmed.length > 1) continue;  // no space, >1 char = skip
                if (sp != -1 && sp != 1) continue;              // first word >1 char = skip

                var group = firstChar;

                // Determine clip type from the keyword after the group letter.
                var rest = (sp != -1) ? trimmed.substring(sp + 1) : "";
                var clipType:String;
                if (rest == "confirm")       clipType = "confirm";
                else if (rest == "hold")    clipType = "holdBody";
                else if (rest == "press")   clipType = "press";
                else if (rest == "tail")    clipType = "holdTail";
                else                        clipType = "idle";

                // Deduplicate: only keep first occurrence (frame 0000).
                var dedupeKey = group + ":" + clipType;
                if (seen.exists(dedupeKey)) continue;
                seen.set(dedupeKey, true);

                entries.push({group: group, clipType: clipType, x: sx, y: sy, w: sw, h: sh, offsX: ox, offsY: oy});
            }

            if (entries.length == 0) {
                trace('No valid SubTexture entries found in $xmlPath');
                return;
            }

            // --- Pass 2: clear ALL clips, determine receptors, create only what's needed ---

            // Collect unique groups, sorted alphabetically (A=0, B=1, ...).
            var groupSet = new Map<String, Bool>();
            for (e in entries) groupSet.set(e.group, true);
            var receptorNames = [for (g in groupSet.keys()) g];
            receptorNames.sort(function(a:String, b:String):Int {
                if (a < b) return -1;
                if (a > b) return 1;
                return 0;
            });

            var keyCount = receptorNames.length;

            // --- Clear ALL existing clips and create exactly keyCount new ones ---
            state.noteskinData.clip = [];
            var clips = state.noteskinData.clip;
            for (i in 0...keyCount) {
                clips.push(NoteskinEditorClipEditor.defaultClip());
            }

            // Build group -> receptor index map.
            var groupToReceptor = new Map<String, Int>();
            for (i in 0...receptorNames.length)
                groupToReceptor.set(receptorNames[i], i);

            // Assign entries into clip slots.
            for (entry in entries) {
                var receptorIndex = groupToReceptor.get(entry.group);
                if (receptorIndex == null) continue;

                var clipData:BasicNoteskinClip = {
                    clipX: entry.x, clipY: entry.y,
                    clipW: entry.w, clipH: entry.h,
                    offsX: entry.offsX, offsY: entry.offsY,
                    rotation: TextureRotation.POS0
                };

                var clip = clips[receptorIndex];
                switch (entry.clipType) {
                    case "idle":     clip.idle = clipData;
                    case "press":    clip.press = clipData;
                    case "confirm":  clip.confirm = clipData;
                    case "color":    clip.color = clipData;
                    case "holdBody": clip.holdBody = clipData;
                    case "holdTail": clip.holdTail = clipData;
                    default:
                }

                trace('Imported: ${entry.group} ${entry.clipType} [receptor $receptorIndex] (${entry.x}, ${entry.y}, ${entry.w}, ${entry.h}) offs(${entry.offsX}, ${entry.offsY})');
            }

            // --- Ensure a mania config exists for this key count ---
            var configs = state.noteskinData.configMania;
            var foundConfig:NoteskinConfig = null;
            for (cfg in configs) {
                if (cfg.idleIndexes != null && cfg.idleIndexes.length == keyCount) {
                    foundConfig = cfg;
                    break;
                }
            }
            if (foundConfig == null) {
                var idx = [for (i in 0...keyCount) i];
                foundConfig = {
                    offsetX: 0, offsetY: 0, gap: 112, scale: 1.0,
                    idleIndexes: idx.copy(), pressIndexes: idx.copy(), colorIndexes: idx.copy(),
                    confirmIndexes: idx.copy(), holdBodyIndexes: idx.copy(), holdTailIndexes: idx.copy()
                };
                configs.push(foundConfig);
                trace('Created new mania config for $keyCount keys');
            }

            // Mirror confirmCreateMania: after ensuring the keyCount config
            // exists, fill in 1K..(NK-1)K so the mania bar shows the full
            // 1K-NK range with NK active (e.g. [4/4 - 4K]).
            state.availableManiaConfigs = configs.copy();
            fillMissingManias(keyCount);
            sortManiasByKeyCount();

            // After sort, refetch the index of the just-imported keyCount
            // config (sort may have moved it).
            var newIndex = state.availableManiaConfigs.indexOf(foundConfig);
            if (newIndex != -1) {
                state.currentManiaIndex = newIndex;
                state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];
            } else {
                state.currentConfig = foundConfig;
            }
            updateMaxReceptorsFromConfig();

            if (state.selectedIndex >= state.maxReceptors) {
                state.selectedIndex = state.maxReceptors - 1;
            }

            // Refresh everything.
            state.renderer.createReceptors();
            state.renderer.createSustains();
            state.renderer.updateReceptorVisuals();
            if (state.showSustainPreview) state.renderer.updateSustainVisuals();
            state.ui.updateInstructionsText();

            trace('Lettered Import complete: ${entries.length} entries, $keyCount receptors (${receptorNames.join(", ")}) from $xmlPath');
        } catch (e) {
            trace('Failed to import lettered atlas: $e');
        }
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
            // --- Scrolling grid background (bottommost layer) ---
            if (state.backgroundBuf == null) {
                state.backgroundBuf = new Buffer<GridBackgroundSprite>(4, 4, true);
            }
            if (state.backgroundProg == null) {
                state.backgroundProg = new CustomProgram(state.backgroundBuf);
                // Generate a 64x64 checkerboard tile texture procedurally.
                // The 2x2 pattern (dark/light, light/dark) is duplicated 32x32
                // times to fill the full 64x64 tile.
                var tileSize = GridBackgroundSprite.TILE_SIZE;
                var darkR = 18, darkG = 18, darkB = 24;
                var lightR = 35, lightG = 35, lightB = 48;
                var gridBytes = haxe.io.Bytes.alloc(tileSize * tileSize * 4);
                for (py in 0...tileSize) {
                    for (px in 0...tileSize) {
                        var idx = (py * tileSize + px) * 4;
                        // Standard checkerboard: matches the 2x2 pattern
                        // [dark][light] / [light][dark] tiled 32x32.
                        var isDark = ((px & 1) + (py & 1)) != 1;
                        var r = isDark ? darkR : lightR;
                        var g = isDark ? darkG : lightG;
                        var b = isDark ? darkB : lightB;
                        gridBytes.set(idx, r);
                        gridBytes.set(idx + 1, g);
                        gridBytes.set(idx + 2, b);
                        gridBytes.set(idx + 3, 255);
                    }
                }

                var gridTexData = new TextureData(tileSize, tileSize, TextureFormat.RGBA);
                gridTexData.bytes = gridBytes;
                var gridTex = new Texture(tileSize, tileSize, null, {
                    format: TextureFormat.RGBA,
                    powerOfTwo: true,
                    smoothExpand: false,
                    smoothShrink: false
                });
                gridTex.setData(gridTexData);
                state.backgroundTexture = gridTex;
                TextureSystem.pool[NoteskinEditor.BACKGROUND_TEXTURE_NAME] = gridTex;

                GridBackgroundSprite.init(
                    state.backgroundProg,
                    NoteskinEditor.BACKGROUND_TEXTURE_NAME,
                    gridTex
                );
            }

            // Create 4 square sprites in a 2x2 arrangement for seamless 2D scrolling.
            // Each square is max(screenW, screenH) so the 2x2 block always covers the viewport.
            var tileSize = GridBackgroundSprite.TILE_SIZE;
            var S:Float = Main.INITIAL_WIDTH;
            if (Main.INITIAL_HEIGHT > S) S = Main.INITIAL_HEIGHT;
            S = Math.ceil(S);
            state.backgroundSprites = [];
            // Base offsets for 2x2 grid: top-left, top-right, bottom-left, bottom-right
            var bx = [0.0, -S, 0.0, -S];
            var by = [0.0, 0.0, -S, -S];
            for (i in 0...4) {
                var spr = new GridBackgroundSprite();
                spr.x = bx[i];
                spr.y = by[i];
                spr.w = S;
                spr.h = S;
                spr.clipWidth = tileSize;
                spr.clipHeight = tileSize;
                spr.clipSizeX = tileSize;
                spr.clipSizeY = tileSize;
                state.backgroundSprites.push(spr);
                state.backgroundBuf.addElement(spr);
            }

            // --- Receptor grid overlay (above background, below receptors) ---
            if (state.receptorGridBuf == null) {
                state.receptorGridBuf = new Buffer<RepeatSprite>(16, 16, true);
            }
            if (state.receptorGridProg == null) {
                state.receptorGridProg = new CustomProgram(state.receptorGridBuf);
            }

            // --- GUI overlay (above receptors, below guiSprite labels) ---
            if (state.gridBuf == null) {
                state.gridBuf = new Buffer<RepeatSprite>(16, 16, true);
            }
            if (state.gridProg == null) {
                state.gridProg = new CustomProgram(state.gridBuf);
            }
        } catch (e) {
            trace('Failed to create grid: $e');
        }
    }

    function updateGridPosition() {
        for (sprite in state.gridSprites) {
            state.receptorGridBuf.removeElement(sprite);
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
                Math.round(receptor.x + (basicClip.offsX * scale)),
                Math.round(receptor.y + (basicClip.offsY * scale)),
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
            state.receptorGridBuf.addElement(gridSprite);
        }

        state.receptorGridBuf.update();
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

        // Note: programs are added to view in init() in the correct z-order.

        // Sustain preview
        if (state.sustainBuf == null) {
            state.sustainBuf = new Buffer<Sustain>(16, 16, true);
        }
        if (state.sustainProg == null) {
            state.sustainProg = new CustomProgram(state.sustainBuf);
            Sustain.init(state.sustainProg, NoteskinEditor.NOTESKIN_TEXTURE_NAME, state.texture);
        }
    }

    function initGUISprites() {
        if (state.guiTextureLoaded) return;

        try {
            var guiTexPath = Paths.asset('assets/images/noteskins/gui_buttons.png');
            if (!FileSystem.exists(guiTexPath)) {
                trace('GUI buttons texture not found, skipping GUI sprites');
                return;
            }
            var guiImage = Image.fromFile(guiTexPath);
            var guiData = new TextureData(guiImage.width, guiImage.height, TextureFormat.RGBA);
            guiData.bytes = guiImage.getPixels(new Rectangle(0, 0, guiImage.width, guiImage.height), RGBA32);

            var guiTex = new Texture(guiImage.width, guiImage.height, null, {
                format: TextureFormat.RGBA,
                powerOfTwo: false,
                smoothExpand: SaveData.state.graphics.antialiasing,
                smoothShrink: SaveData.state.graphics.antialiasing
            });
            guiTex.setData(guiData);
            TextureSystem.pool[NoteskinEditor.GUI_TEXTURE_NAME] = guiTex;
            state.guiTexture = guiTex;

            state.guiSpriteBuf = new Buffer<NoteskinGUISprite>(32, 32, true);
            state.guiSpriteProg = new CustomProgram(state.guiSpriteBuf);
            NoteskinGUISprite.init(state.guiSpriteProg, NoteskinEditor.GUI_TEXTURE_NAME, guiTex);

            // Note: programs are added to view in init() in the correct z-order.

            state.guiTextureLoaded = true;
            trace('GUI sprite buffer initialized (${guiImage.width}x${guiImage.height})');
        } catch (e) {
            trace('Failed to init GUI sprites: $e');
        }
    }

    function createImportButton() {
        var btnH = NoteskinEditor.IMPORT_BUTTON_HEIGHT;
        var btnSaveW = NoteskinEditor.SAVE_BUTTON_WIDTH;
        var btn4W = NoteskinEditor.IMPORT_BUTTON_WIDTH;
        var btn18W = NoteskinEditor.IMPORT_BUTTON_18K_WIDTH;
        var totalW = btnSaveW + 4 + btn4W + 4 + btn18W;
        var margin = 4;

        // Position at bottom-left, next to the left button panel
        var btnY = Main.INITIAL_HEIGHT - btnH - margin;
        var rowX = 4 + margin; // aligned with left panel

        // Save noteskin button (dark blue)
        var btnSaveX = rowX;
        state.saveButtonBox = new RepeatSprite(btnSaveX, btnY, btnSaveW, btnH);
        state.saveButtonBox.c = 0x000088FF;
        state.saveButtonBox.c.aF = 0.85;
        state.gridBuf.addElement(state.saveButtonBox);

        state.saveButtonText = new Text(
            "SAVE_NOTESKIN_BTN", btnSaveX + 6, btnY + 9,
            state.display, "SAVE NOTESKIN", "vcr"
        );
        state.saveButtonText.scale = 0.5;
        state.saveButtonText.alpha = 0; // hidden until editor opens
        state.saveButtonText.addProgram();

        // Vanilla import button
        var btn4X = rowX + btnSaveW + 4;
        state.importButtonBox = new RepeatSprite(btn4X, btnY, btn4W, btnH);
        state.importButtonBox.c = 0x000000FF;
        state.importButtonBox.c.aF = 0.75;
        state.gridBuf.addElement(state.importButtonBox);

        state.importButtonText = new Text(
            "IMPORT_ATLAS_BTN", btn4X + 6, btnY + 9,
            state.display, "IMPT. VANILLA XML", "vcr"
        );
        state.importButtonText.scale = 0.5;
        state.importButtonText.alpha = 0; // hidden until editor opens
        state.importButtonText.addProgram();

        // 18K import button
        var btn18X = rowX + btnSaveW + 4 + btn4W + 4;
        state.importButton18KBox = new RepeatSprite(btn18X, btnY, btn18W, btnH);
        state.importButton18KBox.c = 0x000000FF;
        state.importButton18KBox.c.aF = 0.75;
        state.gridBuf.addElement(state.importButton18KBox);

        state.importButton18KText = new Text(
            "IMPORT_ATLAS_18K_BTN", btn18X + 6, btnY + 9,
            state.display, "IMPT. LETTERED XML", "vcr"
        );
        state.importButton18KText.scale = 0.5;
        state.importButton18KText.alpha = 0; // hidden until editor opens
        state.importButton18KText.addProgram();
    }

    function getCombinedNoteskinTexture():Texture {
        var existingTex = TextureSystem.getTexture(NoteskinEditor.NOTESKIN_TEXTURE_NAME);
        if (existingTex != null) {
            return existingTex;
        }

        try {
            var skinFolder = 'assets/images/noteskins/${state.currentSkinName}';

            var sheetPath = Paths.asset('$skinFolder/sheet.png');
            var sheetExists = FileSystem.exists(sheetPath);

            if (!sheetExists) {
                sheetPath = Paths.asset('assets/images/noteskins/default/sheet.png');
                sheetExists = FileSystem.exists(sheetPath);
            }

            if (!sheetExists) {
                trace('Sheet texture not found, creating blank');
                return createBlankTexture();
            }

            var sheetImage = Image.fromFile(sheetPath);

            var pixelData = sheetImage.getPixels(new Rectangle(0, 0, sheetImage.width, sheetImage.height), RGBA32);

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

            var textureData = new TextureData(sheetImage.width, sheetImage.height, TextureFormat.RGBA);
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
            trace('Failed to load noteskin texture: $e');
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
    static inline var PREVIEW_COLS:Int = 6;

    /** Clamp previewScrollOffset so content stays reachable vertically. */
    function clampPreviewScroll() {
        if (!isPreviewMania() || state.maxReceptors == 0) {
            state.previewScrollOffset = 0;
            return;
        }
        var gap = state.currentConfig.gap != 0 ? state.currentConfig.gap : 112;
        var totalRows = Math.ceil(state.maxReceptors / PREVIEW_COLS);
        var centerY = Main.INITIAL_HEIGHT / 2.36;
        var halfContent = ((totalRows - 1) / 2.0) * gap;

        // At offset=0 the block is centered around centerY.
        // Positive offset pushes content down (reveals top rows).
        // Negative offset pushes content up (reveals bottom rows).
        // Allow top row center to reach gap/2 from screen top:
        var maxScroll = halfContent - centerY + (gap * 0.5);
        // Allow bottom row center to reach gap*1.7 from screen bottom:
        var minScroll = Main.INITIAL_HEIGHT - centerY - halfContent - (gap * 1.7);

        // If content fits on screen, don't allow any scrolling.
        if (maxScroll < 0) maxScroll = 0;
        if (minScroll > 0) minScroll = 0;

        if (state.previewScrollOffset > maxScroll) state.previewScrollOffset = maxScroll;
        if (state.previewScrollOffset < minScroll) state.previewScrollOffset = minScroll;
    }

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
            var y = centerY + (row - (totalRows - 1) / 2) * rowHeight + state.previewScrollOffset;
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

        createSustains();
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
        updateSustainVisuals();
        updateGridPosition();
        state.ui.updateInstructionsText();
    }

    function createSustains() {
        for (s in state.sustainSprites) {
            state.sustainBuf.removeElement(s);
        }
        state.sustainSprites = [];

        var gap = state.currentConfig.gap != 0 ? state.currentConfig.gap : 112;
        var offsetX = state.currentConfig.offsetX;
        var offsetY = state.currentConfig.offsetY;
        var scale = state.currentConfig.scale;

        for (i in 0...state.maxReceptors) {
            var pos = getReceptorPosition(i, gap, offsetX, offsetY);
            // Use per-state indexes: body from holdBodyIndexes, tail from holdTailIndexes.
            var bodyIdxArr = state.clipEditor.getIndexesForState(HOLD_BODY);
            var tailIdxArr = state.clipEditor.getIndexesForState(HOLD_TAIL);
            var bodyClip = state.clipEditor.getClipForIndex(bodyIdxArr[i]);
            var tailClip = state.clipEditor.getClipForIndex(tailIdxArr[i]);

            var sustain = new Sustain(
                Std.int(pos.x),
                Std.int(pos.y),
                100, 30,
                -90, 1.0, 1.0, 0
            );

            // Center sustain on the receptor's visual center so it
            // pokes out of the middle of the receptor (growing upward).
            // xOffset centers horizontally, yOffset centers vertically.
            var idleIdxArr = state.clipEditor.getIndexesForState(IDLE);
            var idleClip = state.clipEditor.getClipForIndex(idleIdxArr[i]).idle;
            var idleDrawnW = idleClip.clipW * scale;
            var idleDrawnH = idleClip.clipH * scale;
            // NoteVB.hx followNote approach: place sustain at receptor center.
            var xOffset = Std.int(idleClip.offsX * scale + idleDrawnW / 2);
            var yOffset = Std.int(idleClip.offsY * scale + idleDrawnH / 2);

            sustain.x += xOffset;
            sustain.y += yOffset;
            sustain.scale = scale;

            sustain.bodyX = bodyClip.holdBody.clipX;
            sustain.bodyY = bodyClip.holdBody.clipY;
            sustain.bodyW = bodyClip.holdBody.clipW;
            sustain.bodyH = bodyClip.holdBody.clipH;
            sustain.tailX = tailClip.holdTail.clipX;
            sustain.tailY = tailClip.holdTail.clipY;
            sustain.tailW = tailClip.holdTail.clipW;
            sustain.tailH = tailClip.holdTail.clipH;

            sustain.texRotation = bodyClip.holdBody.rotation.toDegrees();

            // Apply stored visual rotation for this receptor
            if (i < state.sustainRotations.length) {
                sustain.r = state.sustainRotations[i];
            } else {
                sustain.r = -90.0;
            }

            sustain.c.aF = 0.0;
            sustain.c.luminanceF = 0.0;

            state.sustainSprites.push(sustain);
            state.sustainBuf.addElement(sustain);
        }
    }

    function updateSustainVisuals() {
        var gap = state.currentConfig.gap != 0 ? state.currentConfig.gap : 112;
        var offsetX = state.currentConfig.offsetX;
        var offsetY = state.currentConfig.offsetY;
        var scale = state.currentConfig.scale;

        for (i in 0...state.sustainSprites.length) {
            var sustain = state.sustainSprites[i];
            if (sustain == null) continue;

            // Use per-state indexes: body from holdBodyIndexes, tail from holdTailIndexes.
            var bodyIdxArr = state.clipEditor.getIndexesForState(HOLD_BODY);
            var tailIdxArr = state.clipEditor.getIndexesForState(HOLD_TAIL);
            var bodyClip = state.clipEditor.getClipForIndex(bodyIdxArr[i]);
            var tailClip = state.clipEditor.getClipForIndex(tailIdxArr[i]);

            var pos = getReceptorPosition(i, gap, offsetX, offsetY);

            // Center sustain on the receptor's visual center so it
            // pokes out of the middle of the receptor (growing upward).
            // xOffset centers horizontally, yOffset centers vertically.
            var idleIdxArr = state.clipEditor.getIndexesForState(IDLE);
            var idleClip = state.clipEditor.getClipForIndex(idleIdxArr[i]).idle;
            var idleDrawnW = idleClip.clipW * scale;
            var idleDrawnH = idleClip.clipH * scale;
            // NoteVB.hx followNote approach: place sustain at receptor center.
            var xOffset = Std.int(idleClip.offsX * scale + idleDrawnW / 2);
            var yOffset = Std.int(idleClip.offsY * scale + idleDrawnH / 2);

            sustain.x = Std.int(pos.x) + xOffset;
            sustain.y = Std.int(pos.y) + yOffset;
            sustain.scale = scale;

            sustain.bodyX = bodyClip.holdBody.clipX;
            sustain.bodyY = bodyClip.holdBody.clipY;
            sustain.bodyW = bodyClip.holdBody.clipW;
            sustain.bodyH = bodyClip.holdBody.clipH;
            sustain.tailX = tailClip.holdTail.clipX;
            sustain.tailY = tailClip.holdTail.clipY;
            sustain.tailW = tailClip.holdTail.clipW;
            sustain.tailH = tailClip.holdTail.clipH;

            sustain.texRotation = bodyClip.holdBody.rotation.toDegrees();

            // Apply stored visual rotation for this receptor
            if (i < state.sustainRotations.length) {
                sustain.r = state.sustainRotations[i];
            } else {
                sustain.r = -90.0;
            }

            sustain.c.aF = state.showSustainPreview ? 0.5 : 0.0;
            sustain.c.luminanceF = state.showSustainPreview ? 0.5 : 0.0;

            state.sustainBuf.updateElement(sustain);
        }

        state.sustainBuf.update();
    }

    function updateReceptorState(newState:EditState) {
        state.currentState = newState;
        updateReceptorVisuals();
        state.ui.updateInstructionsText();
    }
}

// ============================================================================

@:publicFields
private class NoteskinEditorUI {
    var state:NoteskinEditor;

    // Layout constants
    static inline var BTN_GAP:Int = 3;
    static inline var PANEL_PAD:Int = 5;
    static inline var STATE_SCALE:Float = 0.8;
    static inline var BTN_SCALE:Float = 0.84;

    // Section colors
    static inline var COL_STATE_BG:Int   = 0x002244FF;
    static inline var COL_STATE_ACT:Int  = 0x004488FF;
    static inline var COL_MODE_BG:Int    = 0x332200FF;
    static inline var COL_MODE_ACT:Int   = 0x664400FF;
    static inline var COL_ACTION_BG:Int  = 0x003322FF;
    static inline var COL_ACTION_ACT:Int = 0x006644FF;
    static inline var COL_DANGER_BG:Int  = 0x440000FF;
    static inline var COL_DANGER_ACT:Int = 0x880000FF;
    static inline var COL_INFO_BG:Int    = 0x222233FF;

    // Marker pairs shared by state readout text and popups
    static var MARKERS(get, null):Array<TextFormatMarkerPair>;
    static function get_MARKERS():Array<TextFormatMarkerPair> {
        if (MARKERS == null) {
            MARKERS = [
                new TextFormatMarkerPair('#M1#', Color.CYAN),
                new TextFormatMarkerPair('#M2#', 0xFFFF5353),
                new TextFormatMarkerPair('#M3#', 0xFF53FF53),
                new TextFormatMarkerPair('#M4#', 0xFF5353FF),
                new TextFormatMarkerPair('#M5#', Color.YELLOW),
                new TextFormatMarkerPair('#M6#', 0xFFFF9933),
                new TextFormatMarkerPair('#M7#', 0xFFFF33FF),
                new TextFormatMarkerPair('#M8#', 0xFF33FF33),
                new TextFormatMarkerPair('#M9#', 0xFFFF00FF),
                new TextFormatMarkerPair('#M10#', 0xFF00CED1),
                new TextFormatMarkerPair('#M11#', 0xFFFF6347)
            ];
        }
        return MARKERS;
    }

    public function new(state:NoteskinEditor) {
        this.state = state;
    }

    // --- Frame assignment: each action maps 1:1 to its XML frame index ---
    // #1=Position  #2=Size  #3=Offset  #4=ClipID  #5=GlobalTransform
    // #6=ToggleSustain  #7=+90sustTexRot  #8=-90sustTexRot
    // #9=+90sustRot  #10=-90sustRot  #11=+1gap  #12=-1gap
    // #13=+10gap  #14=-10gap  #15=switchMania  #16=spritesheetMode
    // #17=openInstructions  #18=createMania

    static function getSpriteFrame(action:String):Int {
        return switch(action) {
            case "mode_clippos":        0;
            case "mode_clipsize":       1;
            case "mode_offset":         2;
            case "mode_clipid":         3;
            case "mode_global":         4;
            case "sustain_toggle":      5;
            case "sust_texrot_p90":     6;
            case "sust_texrot_m90":     7;
            case "sust_rot_p45":        8;
            case "sust_rot_m45":        9;
            case "gap_p1":              10;
            case "gap_m1":              11;
            case "gap_p10":             12;
            case "gap_m10":             13;
            case "mania_switch_p1":     14;
            case "mania_switch_m1":     15;
            case "spritesheet_toggle":  16;
            case "show_instructions":   17;
            case "mania_create":        18;
            case "switch_state_idle":   19;
            case "switch_state_color":  20;
            case "switch_state_press":  21;
            case "switch_state_confirm":  22;
            case "switch_state_holdbody": 23;
            case "switch_state_holdtail": 24;
            default: -1;
        };
    }

    // --- Background color for a button action ---

    static function getBgColor(action:String):Int {
        if (action.startsWith("mode_"))       return COL_MODE_BG;
        if (action.startsWith("sust_"))       return COL_MODE_BG;
        if (action == "mania_create" || action == "show_instructions") return COL_DANGER_BG;
        if (action == "sustain_toggle")       return COL_ACTION_BG;

        return COL_ACTION_BG;
    }

    // --- Display size for a frame at 80% scale ---

    static function displayW(frameID:Int):Int {
        var f = NoteskinGUISprite.ATLAS_FRAMES[frameID];
        return Math.round(f.width * BTN_SCALE);
    }
    static function displayH(frameID:Int):Int {
        var f = NoteskinGUISprite.ATLAS_FRAMES[frameID];
        return Math.round(f.height * BTN_SCALE);
    }

    // --- Button factories ---

    function makeSpriteButton(x:Int, y:Int, action:String, frameID:Int, bgCol:Int):{box:RepeatSprite, sprite:NoteskinGUISprite, action:String} {
        var dw = displayW(frameID);
        var dh = displayH(frameID);
        var box = new RepeatSprite(x, y, dw, dh);
        box.c = bgCol;
        box.c.aF = 0.7;
        state.gridBuf.addElement(box);

        var sprite:NoteskinGUISprite = null;
        if (state.guiSpriteBuf != null) {
            sprite = new NoteskinGUISprite();
            sprite.x = x;
            sprite.y = y;
            sprite.changeID(frameID);
            sprite.w = dw;
            sprite.h = dh;
            sprite.alpha = 0.85;
            state.guiSpriteBuf.addElement(sprite);
            state.guiSprites.push(sprite);
        }

        return {box: box, sprite: sprite, action: action};
    }

    function makePlainButton(x:Int, y:Int, w:Int, h:Int, action:String, bgCol:Int):{box:RepeatSprite, sprite:NoteskinGUISprite, action:String} {
        var box = new RepeatSprite(x, y, w, h);
        box.c = bgCol;
        box.c.aF = 0.7;
        state.gridBuf.addElement(box);
        return {box: box, sprite: null, action: action};
    }

    // --- Build GUI panels (two separate panels: left=square, right=wide) ---

    function buildGUIPanel() {
        // 25 buttons total: 8 wide (191px, right) + 17 square (~101px, left)
        // Edit state buttons listed first so they appear at the top of the left panel.
        var allActions:Array<String> = [
            // Edit state buttons (square, top of left panel)
            "switch_state_idle",     // frame 19 — switch anim state #1
            "switch_state_color",    // frame 20 — switch anim state #2
            "switch_state_press",    // frame 21 — switch anim state #3
            "switch_state_confirm",  // frame 22 — switch anim state #4
            "switch_state_holdbody", // frame 23 — switch anim state #5
            "switch_state_holdtail", // frame 24 — switch anim state #6
            // Adjustment buttons (square, below edit states)
            "sust_texrot_p90",       // frame 6  — +90 deg sustain tex coord rotation
            "sust_texrot_m90",       // frame 7  — -90 deg sustain tex coord rotation
            "sust_rot_p45",          // frame 8  — +90 deg regular sustain rotation
            "sust_rot_m45",          // frame 9  — -90 deg regular sustain rotation
            "gap_p1",                // frame 10 — +1 gap adjustment
            "gap_m1",                // frame 11 — -1 gap adjustment
            "gap_p10",               // frame 12 — +10 gap adjustment
            "gap_m10",               // frame 13 — -10 gap adjustment
            "mania_switch_p1",       // frame 14 — +1 switch mania
            "mania_switch_m1",       // frame 15 — -1 switch mania
            // Wide buttons (right panel, 1 per row)
            "mode_clippos",          // frame 0  — Position
            "mode_clipsize",         // frame 1  — Size
            "mode_offset",           // frame 2  — Offset
            "mode_clipid",           // frame 3  — Clip ID
            "mode_global",           // frame 4  — Global Transform
            "sustain_toggle",        // frame 5  — Toggle Sustain
            "show_instructions",     // frame 17 — open instructions menu
            "mania_create",          // frame 18 — create new mania
        ];

        // Separate into square (<150px) and wide (191px) groups
        var squareDefs:Array<{action:String, w:Int, h:Int, frameID:Int}> = [];
        var wideDefs:Array<{action:String, w:Int, h:Int, frameID:Int}> = [];

        for (action in allActions) {
            var frameID = getSpriteFrame(action);
            if (frameID < 0) continue;
            var f = NoteskinGUISprite.ATLAS_FRAMES[frameID];
            var entry = {action: action, w: displayW(frameID), h: displayH(frameID), frameID: frameID};
            if (f.width < 150) {
                squareDefs.push(entry);
            } else {
                wideDefs.push(entry);
            }
        }

        var pad = PANEL_PAD;

        // === Left panel: square buttons, 2 per row, at top-left ===
        var sqW = squareDefs.length > 0 ? squareDefs[0].w : 0;
        var sqH = squareDefs.length > 0 ? squareDefs[0].h : 0;
        var leftColW = (sqW > 0) ? (sqW * 2 + BTN_GAP) : 0;
        var leftRows = Std.int(Math.ceil(squareDefs.length / 2));
        var leftContentH = (leftRows > 0) ? (leftRows * (sqH + BTN_GAP) - BTN_GAP) : 0;
        var leftPanelW = leftColW + pad * 2;
        var leftPanelH = leftContentH + pad * 2;
        var leftPanelX = 4;
        var leftPanelY = 4;

        if (state.guiLeftBackground == null) {
            state.guiLeftBackground = new RepeatSprite(leftPanelX, leftPanelY, leftPanelW, leftPanelH);
            state.guiLeftBackground.c = 0x000000FF;
            state.guiLeftBackground.c.aF = 0.7;
            state.gridBuf.addElement(state.guiLeftBackground);
        } else {
            state.guiLeftBackground.x = leftPanelX;
            state.guiLeftBackground.y = leftPanelY;
            state.guiLeftBackground.w = leftPanelW;
            state.guiLeftBackground.h = leftPanelH;
            state.gridBuf.updateElement(state.guiLeftBackground);
        }

        // Place square buttons in left panel
        var lx = 0;
        var ly = 0;
        for (i in 0...squareDefs.length) {
            var d = squareDefs[i];
            var bx = leftPanelX + pad + lx;
            var by = leftPanelY + pad + ly;
            var bgCol = getBgColor(d.action);
            state.guiButtons.push(makeSpriteButton(bx, by, d.action, d.frameID, bgCol));
            lx += d.w + BTN_GAP;
            if ((i + 1) % 2 == 0) { lx = 0; ly += d.h + BTN_GAP; }
        }

        // === Right panel: wide buttons, 1 per row, at top-right ===
        var wdW = wideDefs.length > 0 ? wideDefs[0].w : 0;
        var wdH = wideDefs.length > 0 ? wideDefs[0].h : 0;
        var rightColW = (wdW > 0) ? wdW : 0;
        var rightRows = wideDefs.length;
        var rightContentH = (rightRows > 0) ? (rightRows * (wdH + BTN_GAP) - BTN_GAP) : 0;
        var rightPanelW = rightColW + pad * 2;
        var rightPanelH = rightContentH + pad * 2;
        var rightPanelX = Main.INITIAL_WIDTH - rightPanelW - 4;
        var rightPanelY = 4;

        if (state.guiBackground == null) {
            state.guiBackground = new RepeatSprite(rightPanelX, rightPanelY, rightPanelW, rightPanelH);
            state.guiBackground.c = 0x000000FF;
            state.guiBackground.c.aF = 0.7;
            state.gridBuf.addElement(state.guiBackground);
        } else {
            state.guiBackground.x = rightPanelX;
            state.guiBackground.y = rightPanelY;
            state.guiBackground.w = rightPanelW;
            state.guiBackground.h = rightPanelH;
            state.gridBuf.updateElement(state.guiBackground);
        }

        // Place wide buttons in right panel (1 per row)
        var ry = 0;
        for (i in 0...wideDefs.length) {
            var d = wideDefs[i];
            var bx = rightPanelX + pad;
            var by = rightPanelY + pad + ry;
            var bgCol = getBgColor(d.action);
            state.guiButtons.push(makeSpriteButton(bx, by, d.action, d.frameID, bgCol));
            ry += d.h + BTN_GAP;
        }

        // Update the GUI sprite buffer after adding all sprites
        if (state.guiSpriteBuf != null) {
            state.guiSpriteBuf.update();
        }

        // --- State readout Text (to the left of the right panel) ---
        var readoutX = rightPanelX - pad - 180; // left-aligned, 180px wide area
        if (readoutX < leftPanelX + leftPanelW + 8) readoutX = leftPanelX + leftPanelW + 8;
        var readoutY = rightPanelY;
        if (state.guiStateText == null) {
            state.guiStateText = new Text("GUI_STATE_READOUT", readoutX, readoutY, state.display, "", "vcr");
            state.guiStateText.scale = STATE_SCALE;
            state.guiStateText.alpha = 0;
            state.guiStateText.multiline = true;
            state.guiStateText.alignment = RIGHT;
            state.guiStateText.spacerPercent = -0.15;
            state.guiStateText.outlineColor = Color.BLACK;
            state.guiStateText.outlineSize = 1;
            state.guiStateText.setMarkerPairs(MARKERS);
            state.guiStateText.addProgram();
        } else {
            state.guiStateText.x = readoutX;
            state.guiStateText.y = readoutY;
        }

        updateStateReadout();
        state.guiStateText.refresh();
    }

    // --- State readout ---

    function buildStateReadoutText():String {
        if (state.createManiaPopupActive) return "";
        if (state.showInstructionsPopup) return "";

        var stateName = state.clipEditor.getStateName(state.currentState);
        var stateColor = switch(state.currentState) {
            case IDLE:      "#M1#";
            case COLOR:     "#M2#";
            case PRESS:     "#M3#";
            case CONFIRM:   "#M4#";
            case HOLD_BODY: "#M10#";
            case HOLD_TAIL: "#M11#";
            default:        "";
        };

        var clipIndex = state.clipEditor.getClipIndexForReceptor(state.selectedIndex);
        var clip = state.clipEditor.getClipForIndex(clipIndex);
        var basicClip:BasicNoteskinClip = state.clipEditor.getBasicClipForState(clip, state.currentState);
        var basicHoldClip:BasicNoteskinClip = state.clipEditor.getClipForIndex(clipIndex).holdBody;

        var editModeName = state.clipEditor.getEditModeName(state.editMode);
        var editModeColor = state.clipEditor.getEditModeColor(state.editMode);

        var result = '';
        if (state.spriteSheetMode) {
            result += '#M9#[SPRITESHEET MODE]#M9#\n';
        }
        result += 'Mania: #M5#[${state.currentManiaIndex + 1}/${state.availableManiaConfigs.length + 1} - ${state.maxReceptors}K]#M5#\n';
        result += 'Gap: #M5#[${state.currentConfig.gap}px]#M5#\n';

        if (state.editMode == GLOBAL_TRANSFORM) {
            var modeName = state.globalScaleMode ? "Scale" : "Offset";
            var modeColor = state.globalScaleMode ? "#M4#" : "#M6#";
            result += 'Global: ${modeColor}$modeName${modeColor}\n';
            if (state.globalScaleMode) {
                result += '#M5#Scale: ${Math.round(state.currentConfig.scale * 100) / 100}#M5#\n';
            } else {
                result += '#M5#Off X:${state.currentConfig.offsetX} Y:${state.currentConfig.offsetY}#M5#\n';
            }
        }

        result += 'State: ${stateColor}${stateName}${stateColor}\n';
        result += 'Receptor: #M5#[${state.selectedIndex + 1}/${state.maxReceptors}]#M5#\n';

        if (state.editMode != GLOBAL_TRANSFORM) {
            result += 'Mode: ${editModeColor}${editModeName}${editModeColor}\n';
            result += '#M7#Pos: ${basicClip.clipX},${basicClip.clipY}  Sz: ${basicClip.clipW}x${basicClip.clipH}#M7#\n';
            result += '#M6#Off: ${basicClip.offsX},${basicClip.offsY}#M6#';
        }

        if (!state.spriteSheetMode) {
            result += '\nRot: #M10#${basicHoldClip.rotation}D#M10#';
        }

        if (state.currentManiaIndex == state.availableManiaConfigs.length) {
            result += '\n#M2#[CLIP PREVIEW ON]#M2#';
        }
        if (state.showSustainPreview) {
            result += '\n#M10#[SUSTAIN PREVIEW ON]#M10#';
        }

        return result;
    }

    function updateStateReadout() {
        if (state.guiStateText == null) return;
        // Anchor right edge of text to the left of the right black box.
        var pad = PANEL_PAD;
        state.guiStateText.refresh();
        var readoutX = state.guiBackground.x - pad - state.guiStateText.width;
        if (state.guiLeftBackground != null) {
            var minX = state.guiLeftBackground.x + state.guiLeftBackground.w + 8;
            if (readoutX < minX) readoutX = minX;
        }
        state.guiStateText.x = readoutX;
        state.guiStateText.y = state.guiBackground.y;
        var newText = buildStateReadoutText();
        if (state.guiStateText.text != newText) {
            state.guiStateText.text = newText;
        }
    }

    // --- Highlight active buttons ---

    function updateButtonHighlights() {
        for (btn in state.guiButtons) {
            var isActive = false;

            switch(btn.action) {
                case "mode_clippos":        isActive = (state.editMode == CLIP_POS);
                case "mode_clipsize":       isActive = (state.editMode == CLIP_SIZE);
                case "mode_offset":         isActive = (state.editMode == OFFSET);
                case "mode_clipid":         isActive = (state.editMode == CLIP_ID);
                case "mode_global":         isActive = (state.editMode == GLOBAL_TRANSFORM);
                case "sustain_toggle":      isActive = state.showSustainPreview;

                case "show_instructions":   isActive = state.showInstructionsPopup;
                default:
            }

            if (isActive) {
                btn.box.c.aF = 1.0;
            } else {
                btn.box.c.aF = 0.7;
            }
            state.gridBuf.updateElement(btn.box);

            // Also bump the GUI sprite alpha for active buttons
            if (btn.sprite != null) {
                btn.sprite.alpha = isActive ? 1.0 : 0.85;
                if (state.guiSpriteBuf != null) {
                    state.guiSpriteBuf.updateElement(btn.sprite);
                }
            }
        }
    }

    // --- Instructions popup ---

    function buildInstructionsPopupText():String {
        return
            "#M1#KEYBOARD / MOUSE INSTRUCTIONS#M1#\n\n" +
            "#M5#--- Edit State (1-6) ---#M5#\n" +
            "1=Idle  2=Color  3=Press\n4=Confirm  5=Sust.Note  6=Sust.Tail\n\n" +
            "#M2#--- Edit Mode (ALT+1-5) ---#M2#\n" +
            "1=Clip X/Y  2=Clip W/H\n3=Offset  4=Clip Index\n5=Global Transform\n\n" +
            "#M3#--- Navigation ---#M3#\n" +
            "Switch Mania: SHIFT+UP/DOWN\n" +
            "Switch Receptor: Click note\n" +
            "  or SHIFT+LEFT/RIGHT\n\n" +
            "#M4#--- Editing ---#M4#\n" +
            "Edit values: Arrow Keys\n" +
            "Adjust Gap: ALT+LEFT/RIGHT/Wheel\n" +
            "Move properties: Drag Mouse\n" +
            "#M9#(CTRL+ for 10x on all)#M9#\n\n" +
            "#M10#--- Sustain ---#M10#\n" +
            "Toggle preview: CTRL+R\n" +
            "Cycle rotation: hold R + LEFT/RIGHT\n" +
            "Click sustain top to rotate (debug)\n\n" +
            "#M5#--- Other ---#M5#\n" +
            "Create Mania: SHIFT+M\n" +
            "Toggle Axis: SPACE\n" +
            "Toggle Spritesheet: Hold click\n" +
            "Close editor: ESC\n\n" +
            "#M1#[ESC] Close this popup#M1#";
    }

    function ensureInstructionsText() {
        if (state.instructionsText != null) return;
        state.instructionsText = new Text("NOTESKIN_EDITOR_INSTRUCTIONS", 0, 0, state.display, "", "vcr");
        state.instructionsText.scale = 0.7;
        state.instructionsText.alpha = 0;
        state.instructionsText.multiline = true;
        state.instructionsText.alignment = LEFT;
        state.instructionsText.spacerPercent = -0.1;
        state.instructionsText.outlineColor = Color.BLACK;
        state.instructionsText.outlineSize = 1;
        state.instructionsText.setMarkerPairs(MARKERS);
        state.instructionsText.addProgram();
    }

    function renderInstructionsPopup() {
        if (!state.showInstructionsPopup) return;
        ensureInstructionsText();

        if (state.popupBackground == null) {
            state.popupBackground = new RepeatSprite(0, 0, 0, 0);
            state.popupBackground.c = 0x000000FF;
            state.popupBackground.c.aF = 0.75;
            state.gridBuf.addElement(state.popupBackground);
        }

        state.instructionsText.text = buildInstructionsPopupText();
        state.instructionsText.alignment = LEFT;
        state.instructionsText.scale = 0.7;
        state.instructionsText.alpha = 1;
        state.instructionsText.refresh();

        var padding = 12;
        var totalW = Std.int(state.instructionsText.width + padding * 2);
        var totalH = Std.int(state.instructionsText.height + padding * 2);
        var bgX = Std.int((Main.INITIAL_WIDTH - totalW) / 2);
        var bgY = Std.int((Main.INITIAL_HEIGHT - totalH) / 2);

        state.instructionsText.x = bgX + padding;
        state.instructionsText.y = bgY + padding;
        state.popupBackground.x = bgX;
        state.popupBackground.y = bgY;
        state.popupBackground.w = totalW;
        state.popupBackground.h = totalH;

        state.gridBuf.updateElement(state.popupBackground);
        state.gridBuf.update();
    }

    function hideInstructionsPopup() {
        state.showInstructionsPopup = false;
        if (state.popupBackground != null) {
            state.gridBuf.removeElement(state.popupBackground);
            state.popupBackground = null;
        }
        if (state.instructionsText != null) {
            state.instructionsText.alpha = 0;
        }
        state.ui.updateButtonHighlights();
    }

    // --- Init / Update ---

    function initInstructionsText() {
        buildGUIPanel();
        updateButtonHighlights();
        updateStateReadout();
    }

    function updateInstructionsText() {
        if (!state.showEditor) return;

        if (state.showInstructionsPopup) {
            renderInstructionsPopup();
            return;
        }

        if (state.createManiaPopupActive) {
            renderCreateManiaPopup();
            return;
        }

        updateStateReadout();
        updateButtonHighlights();
    }

    function positionInstructionsTextBottomRight() {
        // No-op
    }

    function renderCreateManiaPopup() {
        if (!state.createManiaPopupActive) return;
        ensureInstructionsText();

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
        if (key == KeyCode.R) state.isRPressed = true;

        if (state.createManiaPopupActive) {
            handleCreateManiaPopupInput(key);
            return;
        }

        if (key == KeyCode.ESCAPE) {
            if (state.showInstructionsPopup) {
                state.ui.hideInstructionsPopup();
                return;
            }
            if (state.spriteSheetMode) {
                state.clipEditor.toggleSpritesheetMode();
            } else {
                state.toggleEditor();
            }
            return;
        }

        if (!state.showEditor) return;

        // Block all other input while instructions popup is open
        if (state.showInstructionsPopup) return;

        // --- CTRL+R combination (rotation keybinds) ---
        if (state.isCtrlPressed) {
            switch (key) {
                case KeyCode.R:
                    state.showSustainPreview = !state.showSustainPreview;
                    state.renderer.updateSustainVisuals();
                    trace('Sustain preview: ${state.showSustainPreview ? "ON" : "OFF"}');
                    state.ui.updateInstructionsText();
                    return;
                default:
            }
        }

        // CTRL+SPACE toggles global transform sub-mode (Offset vs Scale).
        if (key == KeyCode.SPACE) {
            if (state.editMode == GLOBAL_TRANSFORM) {
                state.globalScaleMode = !state.globalScaleMode;
                var modeName = state.globalScaleMode ? "Scale" : "Offset";
                trace('Global transform mode: $modeName');
                state.ui.updateInstructionsText();
            }
            return;
        }

        // CTRL+1..6: jump directly to an edit state.
        // 1=IDLE, 2=COLOR, 3=PRESS, 4=CONFIRM, 5=HOLD_BODY, 6=HOLD_TAIL.
        if (!state.spriteSheetMode && !state.isAltPressed) {
            var newStateIdx:Int = switch(key) {
                case KeyCode.NUMBER_1 | KeyCode.NUMPAD_1:   0;
                case KeyCode.NUMBER_2 | KeyCode.NUMPAD_2:   1;
                case KeyCode.NUMBER_3 | KeyCode.NUMPAD_3: 2;
                case KeyCode.NUMBER_4 | KeyCode.NUMPAD_4:  3;
                case KeyCode.NUMBER_5 | KeyCode.NUMPAD_5:  4;
                case KeyCode.NUMBER_6 | KeyCode.NUMPAD_6:  5;
                default:            -1;
            };
            if (newStateIdx != -1) {
                state.renderer.updateReceptorState(newStateIdx);
                trace('Edit state set to: ${state.clipEditor.getStateName(state.currentState)}');
                return;
            }
        }

        // ALT+1..5: jump directly to an edit mode.
        // 1=CLIP_POS, 2=CLIP_SIZE, 3=OFFSET, 4=CLIP_ID, 5=GLOBAL_TRANSFORM.
        if (!state.spriteSheetMode && state.isAltPressed) {
            var newModeIdx:Int = switch(key) {
                case KeyCode.NUMBER_1 | KeyCode.NUMPAD_1:   0;
                case KeyCode.NUMBER_2 | KeyCode.NUMPAD_2:   1;
                case KeyCode.NUMBER_3 | KeyCode.NUMPAD_3: 2;
                case KeyCode.NUMBER_4 | KeyCode.NUMPAD_4:  3;
                case KeyCode.NUMBER_5 | KeyCode.NUMPAD_5:  4;
                default:            -1;
            };
            if (newModeIdx != -1) {
                state.clipEditor.setEditMode(newModeIdx);
                return;
            }
        }

        switch(key) {
            case KeyCode.M:
                if (state.isShiftPressed) {
                    state.maniaManager.createNewMania();
                }
            case KeyCode.SPACE:
                if (!state.spriteSheetMode && state.editMode != GLOBAL_TRANSFORM) {
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
                if (state.showSustainPreview && state.isRPressed && !(state.isAltPressed || state.isShiftPressed || state.isCtrlPressed)) {
                    state.clipEditor.rotateCurrentClip(-1);
                } else if (state.spriteSheetMode) {
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
                if (state.showSustainPreview && state.isRPressed &&!(state.isAltPressed || state.isShiftPressed || state.isCtrlPressed)) {
                    state.clipEditor.rotateCurrentClip(1);
                } else if (state.spriteSheetMode) {
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
            default:
        }
    }

    public function handleKeyUp(key:KeyCode, modifier:KeyModifier) {
        state.isCtrlPressed  = (modifier & KeyModifier.CTRL)  != 0;
        state.isShiftPressed = (modifier & KeyModifier.SHIFT) != 0;
        state.isAltPressed   = (modifier & KeyModifier.ALT)   != 0;
        if (key == KeyCode.R) state.isRPressed = false;
    }

    function handleCreateManiaPopupInput(key:KeyCode) {
        switch(key) {
            case KeyCode.ESCAPE:
                state.maniaManager.cancelCreateMania();
                state.ui.updateInstructionsText();
                return;
            case KeyCode.RETURN:
                state.maniaManager.confirmCreateMania();
                state.ui.updateInstructionsText();
                return;
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

    function handleGUIAction(action:String) {
        switch(action) {
            // Edit mode
            case "mode_clippos":  state.clipEditor.setEditMode(0);
            case "mode_clipsize": state.clipEditor.setEditMode(1);
            case "mode_offset":   state.clipEditor.setEditMode(2);
            case "mode_clipid":   state.clipEditor.setEditMode(3);
            case "mode_global":   state.clipEditor.setEditMode(4);
            // Sustain
            case "sustain_toggle":
                state.showSustainPreview = !state.showSustainPreview;
                state.renderer.updateSustainVisuals();
            // Sustain texture coord rotation (cycles TextureRotation enum on holdBody+holdTail)
            case "sust_texrot_p90":
                state.clipEditor.rotateCurrentClip(1);
            case "sust_texrot_m90":
                state.clipEditor.rotateCurrentClip(-1);
            // Regular sustain sprite rotation (adjusts visual r on sustain sprites)
            case "sust_rot_p45":
                state.clipEditor.rotateSustainSprite(state.selectedIndex, 90);
            case "sust_rot_m45":
                state.clipEditor.rotateSustainSprite(state.selectedIndex, -90);
            // Gap
            case "gap_m10": state.maniaManager.adjustGap(-10);
            case "gap_m1":  state.maniaManager.adjustGap(-1);
            case "gap_p1":  state.maniaManager.adjustGap(1);
            case "gap_p10": state.maniaManager.adjustGap(10);
            // Mania
            case "mania_switch_p1":
                state.maniaManager.switchMania(1);
                state.clipEditor.checkInvalidClipIDPlace();
            case "mania_switch_m1":
                state.maniaManager.switchMania(-1);
                state.clipEditor.checkInvalidClipIDPlace();
            case "mania_create":
                if (state.createManiaPopupActive)
                    state.maniaManager.cancelCreateMania();
                else
                    state.maniaManager.createNewMania();
            // Toggles
            case "show_instructions":
                state.showInstructionsPopup = true;
                state.ui.updateInstructionsText();
            case "switch_state_idle":
                state.clipEditor.toggleStateEqual(IDLE);
                state.clipEditor.checkInvalidClipIDPlace();
            case "switch_state_color":
                state.clipEditor.toggleStateEqual(COLOR);
                state.clipEditor.checkInvalidClipIDPlace();
            case "switch_state_press":
                state.clipEditor.toggleStateEqual(PRESS);
                state.clipEditor.checkInvalidClipIDPlace();
            case "switch_state_confirm":
                state.clipEditor.toggleStateEqual(CONFIRM);
                state.clipEditor.checkInvalidClipIDPlace();
            case "switch_state_holdbody":
                state.clipEditor.toggleStateEqual(HOLD_BODY);
                state.clipEditor.checkInvalidClipIDPlace();
            case "switch_state_holdtail":
                state.clipEditor.toggleStateEqual(HOLD_TAIL);
                state.clipEditor.checkInvalidClipIDPlace();
            default:
        }
        state.ui.updateInstructionsText();
    }

    function handleMouseDown(mouseX:Float, mouseY:Float, button:MouseButton) {
        if (!state.showEditor || button != MouseButton.LEFT) return;
        if (Application.current.window == null) return;

        // If create-mania popup is active, clicking on it confirms, clicking outside cancels.
        if (state.createManiaPopupActive) {
            if (state.popupBackground != null) {
                var bx = state.popupBackground.x;
                var by = state.popupBackground.y;
                var bw = state.popupBackground.w;
                var bh = state.popupBackground.h;
                if (mouseX >= bx && mouseX <= bx + bw && mouseY >= by && mouseY <= by + bh) {
                    // Clicked on the popup — confirm.
                    state.maniaManager.confirmCreateMania();
                } else {
                    // Clicked outside — cancel.
                    state.maniaManager.cancelCreateMania();
                }
            } else {
                // No popup background rendered yet — cancel.
                state.maniaManager.cancelCreateMania();
            }
            state.ui.updateInstructionsText();
            return;
        }

        // If instructions popup is showing, ESC closes it (handled in keydown),
        // but clicking anywhere outside the popup also closes it.
        if (state.showInstructionsPopup) {
            state.ui.hideInstructionsPopup();
            return;
        }

        // --- GUI panel button clicks (check BEFORE scroll so buttons
        //     always work even in preview-clips mania). ---
        for (btn in state.guiButtons) {
            if (btn.box == null) continue;
            var bx = btn.box.x;
            var by = btn.box.y;
            var bw = btn.box.w;
            var bh = btn.box.h;
            if (mouseX >= bx && mouseX <= bx + bw && mouseY >= by && mouseY <= by + bh) {
                handleGUIAction(btn.action);
                return;
            }
        }

        // Save noteskin button click.
        if (state.saveButtonBox != null) {
            var bx = state.saveButtonBox.x;
            var by = state.saveButtonBox.y;
            var bw = state.saveButtonBox.w;
            var bh = state.saveButtonBox.h;
            if (mouseX >= bx && mouseX <= bx + bw && mouseY >= by && mouseY <= by + bh) {
                state.maniaManager.saveNoteskin();
                return;
            }
        }

        // Import vanilla atlas button click.
        if (state.importButtonBox != null) {
            var bx = state.importButtonBox.x;
            var by = state.importButtonBox.y;
            var bw = state.importButtonBox.w;
            var bh = state.importButtonBox.h;
            if (mouseX >= bx && mouseX <= bx + bw && mouseY >= by && mouseY <= by + bh) {
                state.maniaManager.importFromAtlas();
                return;
            }
        }

        // Import lettered atlas button click.
        if (state.importButton18KBox != null) {
            var bx = state.importButton18KBox.x;
            var by = state.importButton18KBox.y;
            var bw = state.importButton18KBox.w;
            var bh = state.importButton18KBox.h;
            if (mouseX >= bx && mouseX <= bx + bw && mouseY >= by && mouseY <= by + bh) {
                state.maniaManager.importFromAtlas18K();
                return;
            }
        }

        // --- Preview mode vertical scroll (100px zones next to GUI panels) ---
        if (state.renderer.isPreviewMania() && !state.spriteSheetMode) {
            var hitIndex = state.clipEditor.findReceptorAt(mouseX, mouseY);
            if (hitIndex == -1) {
                var scrollZoneWidth:Float = 100.0;
                // Left scroll zone: 100px starting right after the left black box
                var leftScrollLeft = 0.0;
                var leftScrollRight = 0.0;
                if (state.guiLeftBackground != null) {
                    leftScrollLeft = state.guiLeftBackground.x + state.guiLeftBackground.w;
                    leftScrollRight = leftScrollLeft + scrollZoneWidth;
                }
                // Right scroll zone: 100px ending at the left edge of the right black box
                var rightScrollRight = 0.0;
                var rightScrollLeft = 0.0;
                if (state.guiBackground != null) {
                    rightScrollRight = state.guiBackground.x;
                    rightScrollLeft = rightScrollRight - scrollZoneWidth;
                }
                var inLeftZone = (leftScrollRight > 0) && (mouseX >= leftScrollLeft && mouseX < leftScrollRight);
                var inRightZone = (rightScrollLeft > 0) && (mouseX >= rightScrollLeft && mouseX < rightScrollRight);
                if (inLeftZone || inRightZone) {
                    state.isPreviewScrolling = true;
                    state.previewScrollStartY = mouseY;
                    state.previewScrollStartOffset = state.previewScrollOffset;
                    return;
                }
            }
        }

        // Debug: click the top of a sustain to cycle its rotation.
        // The sustain grows upward from its anchor (sustain.x, sustain.y),
        // so the "top" (tail tip) is at approximately sustain.y - sustainLength * scale.
        if (state.showSustainPreview && !state.spriteSheetMode) {
            var sustainLength = 100;
            var hitMargin = 15; // px tolerance for the click zone
            for (si in 0...state.sustainSprites.length) {
                var s = state.sustainSprites[si];
                if (s == null) continue;
                var sScale = s.scale != 0 ? s.scale : 1;
                var topY = s.y - sustainLength * sScale;
                // Hit zone: a horizontal band at the sustain's top
                if (mouseX >= s.x - hitMargin && mouseX <= s.x + hitMargin
                    && mouseY >= topY - hitMargin && mouseY <= topY + hitMargin) {
                    // Select this receptor and cycle rotation
                    if (si != state.selectedIndex) {
                        state.selectedIndex = si;
                        state.renderer.updateReceptorVisuals();
                    }
                    state.clipEditor.rotateCurrentClip(1);
                    return;
                }
            }
        }

        // Click-to-select: if the click landed on a receptor, select it first
        // so the user doesn't have to cycle with SHIFT+LEFT/RIGHT.
        // Blocked in spritesheet mode — you should only interact with the
        // currently selected receptor there (for clip panning).
        var hitAnyReceptor = false;
        if (!state.spriteSheetMode) {
            var hitIndex = state.clipEditor.findReceptorAt(mouseX, mouseY);
            if (hitIndex != -1) {
                hitAnyReceptor = true;
                if (hitIndex != state.selectedIndex) {
                    state.selectedIndex = hitIndex;
                    state.renderer.updateReceptorVisuals();
                    state.ui.updateInstructionsText();
                }
            }
        }

        // In GLOBAL_TRANSFORM mode, clicking empty space (no receptor hit)
        // toggles between Scale and Offset sub-mode.
        if (state.editMode == GLOBAL_TRANSFORM && !hitAnyReceptor) {
            state.globalScaleMode = !state.globalScaleMode;
            var modeName = state.globalScaleMode ? "Scale" : "Offset";
            trace('Global transform toggled to: $modeName');
            state.ui.updateInstructionsText();
            state.inputHandler.setCursor(state.globalScaleMode ? MouseCursor.ARROW : MouseCursor.MOVE);
            return;
        }

        var note = state.clipEditor.getSelectedNote();
        if (note == null) return;

        var scale = state.currentConfig.scale;
        var sx = note.x;
        var sy = note.y;
        var sw = note.w * scale;
        var sh = note.h * scale;

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

        var scale = state.currentConfig.scale;
        var sx = note.x;
        var sy = note.y;
        var sw = note.w * scale;
        var sh = note.h * scale;

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

        // Stop preview scroll drag.
        if (state.isPreviewScrolling) {
            state.isPreviewScrolling = false;
            setCursor(MouseCursor.ARROW);
            return;
        }

        state.isHoldingMouse = false;
        state.isLongPress = false;

        state.isDragging = false;
        setCursor(MouseCursor.ARROW);
        state.dragMode = 0;
    }

    function handleMouseMove(mouseX:Float, mouseY:Float) {
        if (!state.showEditor) return;
        if (Application.current.window == null) return;

        // Preview mode vertical drag-scroll
        // Drag up (mouseY decreases) → receptors go down (positive offset)
        // Drag down (mouseY increases) → receptors go up (negative offset)
        if (state.isPreviewScrolling) {
            var dy = state.previewScrollStartY - mouseY;
            state.previewScrollOffset = state.previewScrollStartOffset + (dy * 2);
            state.renderer.clampPreviewScroll();
            state.renderer.updateReceptorVisuals();
            state.inputHandler.setCursor(MouseCursor.MOVE);
            return;
        }

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
            // Block per-receptor drag modifications when off-screen.
            // (Global transform drag is exempt — it moves all receptors.)
            if (state.editMode != GLOBAL_TRANSFORM
                && !state.spriteSheetMode
                && !state.clipEditor.isReceptorOnScreen(state.selectedIndex)) {
                return;
            }

            var scale = state.currentConfig.scale;
            var dx = (mouseX - state.dragStartX) / scale;
            var dy = (mouseY - state.dragStartY) / scale;

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
                    state.currentConfig.offsetX = Std.int(state.dragStartOffsX + (dx * scale));
                    state.currentConfig.offsetY = Std.int(state.dragStartOffsY + (dy * scale));
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
                var scale = state.currentConfig.scale;
                var sx = note.x + clip.offsX * scale;
                var sy = note.y + clip.offsY * scale;
                var sw = note.w * scale;
                var sh = note.h * scale;
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
                var scale = state.currentConfig.scale;
                var sx = note.x;
                var sy = note.y;
                var sw = note.w * scale;
                var sh = note.h * scale;
                var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;
                setCursor(inSprite ? MouseCursor.MOVE : MouseCursor.ARROW);
            }
        }
    }

    function handleMouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode) {
        if (!state.showEditor) return;

        // ALT+Wheel: adjust gap.
        // Always available, including inside GLOBAL_TRANSFORM edit mode
        // (regardless of whether the sub-mode is Offset or Scale), so the
        // user can still tune gap without leaving the global transform mode.
        if (state.isAltPressed) {
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
    var currentManiaIndex:Int = 3;
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
    var isRPressed:Bool = false;
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

    // Scrolling grid background (bottommost layer)
    var backgroundBuf:Buffer<GridBackgroundSprite>;
    var backgroundProg:CustomProgram;
    var backgroundSprites:Array<GridBackgroundSprite> = [];
    var backgroundTexture:Texture;
    static inline var BACKGROUND_TEXTURE_NAME:String = "editorGridBgTexV2";

    // Receptor grid overlay (below receptors, above background)
    var receptorGridBuf:Buffer<RepeatSprite>;
    var receptorGridProg:CustomProgram;
    var gridSprites:Array<RepeatSprite> = [];

    // GUI overlay (above receptors, below guiSprite labels)
    var gridBuf:Buffer<RepeatSprite>;
    var gridProg:CustomProgram;

    // Receptor preview
    var receptorSprites:Array<Note> = [];

    // Sustain preview
    var sustainBuf:Buffer<Sustain>;
    var sustainProg:CustomProgram;
    var sustainSprites:Array<Sustain> = [];
    var showSustainPreview:Bool = false;
    var sustainRotations:Array<Float> = []; // per-receptor visual rotation (degrees)

    // Import from atlas buttons
    var saveButtonBox:RepeatSprite = null;
    var saveButtonText:Text = null;
    var importButtonBox:RepeatSprite = null;
    var importButtonText:Text = null;
    var importButton18KBox:RepeatSprite = null;
    var importButton18KText:Text = null;
    static inline var SAVE_BUTTON_WIDTH:Int = 115;
    static inline var IMPORT_BUTTON_WIDTH:Int = 130;
    static inline var IMPORT_BUTTON_18K_WIDTH:Int = 150;
    static inline var IMPORT_BUTTON_HEIGHT:Int = 30;

    // GUI panel buttons (created by NoteskinEditorUI)
    var guiButtons:Array<{box:RepeatSprite, sprite:NoteskinGUISprite, action:String}> = [];
    var guiBackground:RepeatSprite = null;        // right panel (wide buttons)
    var guiLeftBackground:RepeatSprite = null;    // left panel (square buttons)
    var guiStateText:Text = null;
    var showInstructionsPopup:Bool = false;

    // UI state
    var showEditor:Bool = false;
    var selectedProperty:String = "clipX";
    var propertyValue:Int = 0;
    var editingValue:Bool = false;
    var needsRender:Bool = false;
    var popupBackground:RepeatSprite = null;
    var instructionsBackground:RepeatSprite = null;

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

    // Preview mode vertical scroll (drag from empty boundaries)
    var previewScrollOffset:Float = 0.0;
    var backgroundScrollX:Float = 0.0; // accumulates X scroll offset for grid bg
    var backgroundScrollY:Float = 0.0; // accumulates Y scroll offset for grid bg
    var isPreviewScrolling:Bool = false;
    var previewScrollStartY:Float = 0.0;
    var previewScrollStartOffset:Float = 0.0;

    // Spritesheet view offset — extra space above to see what's outside the clip.
    static inline var SPRITESHEET_VIEW_OFFSET:Int = 300;

    // Texture name constants
    static inline var NOTESKIN_TEXTURE_NAME:String = "noteskinTexV2";
    static inline var GRID_TEXTURE_NAME:String = "gridTexV2";
    static inline var RECEPTOR_GRID_TEXTURE_NAME:String = "receptorGridTexV2";
    static inline var GUI_TEXTURE_NAME:String = "guiButtonsTexV2";

    // Instructions text
    var instructionsText:Text;

    // GUI sprite buffer (single buffer+program for all button label sprites)
    var guiSpriteBuf:Buffer<NoteskinGUISprite> = null;
    var guiSpriteProg:CustomProgram = null;
    var guiTexture:Texture = null;
    var guiSprites:Array<NoteskinGUISprite> = [];
    var guiTextureLoaded:Bool = false;

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
        renderer.initGUISprites();
        renderer.createImportButton();
        renderer.createReceptors();

        // Add all programs to view in correct z-order (bottom to top):
        // background → receptorGrid → note → sustain → grid(GUI) → guiSprite
        if (backgroundProg != null) view.addProgram(backgroundProg);
        if (receptorGridProg != null) view.addProgram(receptorGridProg);
        if (noteProg != null) view.addProgram(noteProg);
        if (sustainProg != null) view.addProgram(sustainProg);
        if (gridProg != null) view.addProgram(gridProg);
        if (guiSpriteProg != null) view.addProgram(guiSpriteProg);

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

            if (backgroundProg != null && !backgroundProg.isIn(view)) {
                view.addProgram(backgroundProg);
            }
            if (receptorGridProg != null && !receptorGridProg.isIn(view)) {
                view.addProgram(receptorGridProg);
            }
            if (noteProg != null && !noteProg.isIn(view)) {
                view.addProgram(noteProg);
            }

            if (sustainProg != null && !sustainProg.isIn(view)) {
                view.addProgram(sustainProg);
            }

            if (gridProg != null && !gridProg.isIn(view)) {
                view.addProgram(gridProg);
            }

            if (guiSpriteProg != null && !guiSpriteProg.isIn(view)) {
                view.addProgram(guiSpriteProg);
            }

            spriteSheetMode = false;
            spritesheetSelectedIndex = -1;
            showSustainPreview = false;
            renderer.updateReceptorVisuals();

            // Show all GUI panel buttons, sprites, and state text
            for (btn in guiButtons) {
                if (btn.box != null) btn.box.c.aF = 0.7;
            }
            for (s in guiSprites) {
                s.alpha = 0.85;
                if (guiSpriteBuf != null) guiSpriteBuf.updateElement(s);
            }
            if (guiSpriteBuf != null) guiSpriteBuf.update();
            if (guiStateText != null) guiStateText.alpha = 1;
            if (guiBackground != null) guiBackground.c.aF = 0.7;
            if (guiLeftBackground != null) guiLeftBackground.c.aF = 0.7;
            ui.updateInstructionsText();

            if (saveButtonText != null) {
                saveButtonText.alpha = 1;
            }
            if (importButtonText != null) {
                importButtonText.alpha = 1;
            }
            if (importButton18KText != null) {
                importButton18KText.alpha = 1;
            }

            trace('Noteskin Editor opened');
        } else {
            // Hide all GUI panel sprites and state text (keep programs in view
            // so the user can still see receptor positions and tweak them).
            for (s in guiSprites) {
                s.alpha = 0;
                if (guiSpriteBuf != null) guiSpriteBuf.updateElement(s);
            }
            if (guiSpriteBuf != null) guiSpriteBuf.update();
            if (guiStateText != null) guiStateText.alpha = 0;
            if (instructionsText != null) {
                instructionsText.alpha = 0;
            }
            if (showInstructionsPopup) {
                ui.hideInstructionsPopup();
            }

            if (saveButtonText != null) {
                saveButtonText.alpha = 0;
            }
            if (importButtonText != null) {
                importButtonText.alpha = 0;
            }
            if (importButton18KText != null) {
                importButton18KText.alpha = 0;
            }

            // Hide panel backgrounds and button boxes
            for (btn in guiButtons) {
                if (btn.box != null) btn.box.c.aF = 0;
            }
            if (guiBackground != null) guiBackground.c.aF = 0;
            if (guiLeftBackground != null) guiLeftBackground.c.aF = 0;
            if (saveButtonBox != null) saveButtonBox.c.aF = 0;
            if (importButtonBox != null) importButtonBox.c.aF = 0;
            if (importButton18KBox != null) importButton18KBox.c.aF = 0;
            if (gridBuf != null) gridBuf.update();

            inputHandler.setCursor(MouseCursor.ARROW);
            isDragging = false;
            isHoldingMouse = false;
            isLongPress = false;
            longPressTriggered = false;
            spriteSheetMode = false;
            spritesheetSelectedIndex = -1;
            showSustainPreview = false;

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

        // Clean up GUI panel buttons
        if (guiButtons != null) {
            for (btn in guiButtons) {
                if (btn.box != null) {
                    gridBuf.removeElement(btn.box);
                }
            }
            guiButtons = [];
        }
        if (guiBackground != null) {
            gridBuf.removeElement(guiBackground);
            guiBackground = null;
        }
        if (guiLeftBackground != null) {
            gridBuf.removeElement(guiLeftBackground);
            guiLeftBackground = null;
        }
        // Clean up GUI sprites
        if (guiSprites != null) {
            for (s in guiSprites) {
                if (guiSpriteBuf != null) guiSpriteBuf.removeElement(s);
            }
            guiSprites = [];
        }
        if (guiSpriteBuf != null) {
            guiSpriteBuf.clear();
            guiSpriteBuf = null;
        }
        if (guiSpriteProg != null) {
            if (view != null && guiSpriteProg.isIn(view)) view.removeProgram(guiSpriteProg);
            guiSpriteProg = null;
        }
        if (guiStateText != null) {
            guiStateText.removeProgram();
            guiStateText = null;
        }
        if (instructionsBackground != null) {
            gridBuf.removeElement(instructionsBackground);
            instructionsBackground = null;
        }

        if (saveButtonBox != null) {
            gridBuf.removeElement(saveButtonBox);
            saveButtonBox = null;
        }
        if (saveButtonText != null) {
            saveButtonText.removeProgram();
            saveButtonText = null;
        }
        if (importButtonBox != null) {
            gridBuf.removeElement(importButtonBox);
            importButtonBox = null;
        }
        if (importButtonText != null) {
            importButtonText.removeProgram();
            importButtonText = null;
        }
        if (importButton18KBox != null) {
            gridBuf.removeElement(importButton18KBox);
            importButton18KBox = null;
        }
        if (importButton18KText != null) {
            importButton18KText.removeProgram();
            importButton18KText = null;
        }

        if (noteProg != null && noteProg.isIn(display)) {
            display.removeProgram(noteProg);
        }
        if (gridProg != null && gridProg.isIn(display)) {
            display.removeProgram(gridProg);
        }
        if (receptorGridProg != null && receptorGridProg.isIn(display)) {
            display.removeProgram(receptorGridProg);
        }
        if (backgroundProg != null && backgroundProg.isIn(display)) {
            display.removeProgram(backgroundProg);
        }

        if (sustainProg != null && sustainProg.isIn(display)) {
            display.removeProgram(sustainProg);
        }

        if (noteBuf != null) {
            noteBuf.clear();
            noteBuf = null;
        }
        if (gridBuf != null) {
            gridBuf.clear();
            gridBuf = null;
        }
        if (receptorGridBuf != null) {
            receptorGridBuf.clear();
            receptorGridBuf = null;
        }
        if (backgroundBuf != null) {
            backgroundBuf.clear();
            backgroundBuf = null;
        }
        if (sustainBuf != null) {
            sustainBuf.clear();
            sustainBuf = null;
        }

        if (backgroundSprites != null) {
            backgroundSprites = [];
        }
        if (backgroundTexture != null) {
            backgroundTexture.dispose();
            backgroundTexture = null;
        }
        TextureSystem.pool.remove(BACKGROUND_TEXTURE_NAME);

        if (receptorSprites != null) {
            for (note in receptorSprites) {
                note = null;
            }
            receptorSprites = null;
        }
        if (sustainSprites != null) {
            for (s in sustainSprites) {
                s = null;
            }
            sustainSprites = null;
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

        // Don't process long press while instructions popup is open.
        if (showInstructionsPopup) return;

        // Auto-scroll the grid background via Float x/y-position.
        // 4 squares in a 2x2 arrangement tile seamlessly in both axes.
        // Half speed: 15 px/sec per axis (diagonal scroll).
        if (backgroundSprites.length > 0 && backgroundBuf != null) {
            backgroundScrollX += deltaTime / 20;
            backgroundScrollY += deltaTime / 20;

            var S:Float = Main.INITIAL_WIDTH;
            if (Main.INITIAL_HEIGHT > S) S = Main.INITIAL_HEIGHT;
            S = Math.ceil(S);

            var wrapX = backgroundScrollX % S;
            if (wrapX < 0) wrapX += S;
            var wrapY = backgroundScrollY % S;
            if (wrapY < 0) wrapY += S;

            // 2x2 grid offsets: each square is SxS, shifted by -S as needed.
            var ox = [0.0, -S, 0.0, -S];
            var oy = [0.0, 0.0, -S, -S];
            for (i in 0...backgroundSprites.length) {
                backgroundSprites[i].x = wrapX + ox[i];
                backgroundSprites[i].y = wrapY + oy[i];
                backgroundBuf.updateElement(backgroundSprites[i]);
            }
        }

        // Preview scroll: lerp back to clamped range if somehow out of bounds.
        if (!isPreviewScrolling) {
            var before = previewScrollOffset;
            renderer.clampPreviewScroll();
            if (previewScrollOffset != before) {
                // Overshot during drag — lerp back smoothly.
                var lerpFactor = Math.min(1.0, deltaTime * 12.0);
                previewScrollOffset = before + (previewScrollOffset - before) * lerpFactor;
                renderer.updateReceptorVisuals();
            }
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

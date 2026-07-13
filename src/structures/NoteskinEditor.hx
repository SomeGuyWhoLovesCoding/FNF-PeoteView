package structures;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseCursor;
import lime.ui.MouseWheelMode;
import lime.graphics.Image;
import lime.math.Vector2;
import lime.math.Rectangle;
import lime.app.Application;
import lime.ui.MouseButton;
import structures.gameplay.NoteskinHandle.NoteskinData;
import structures.gameplay.NoteskinHandle.NoteskinConfig;
import structures.gameplay.NoteskinHandle.NoteskinReceptorProperties;
import structures.gameplay.NoteskinHandle.BasicNoteskinClip;
import haxe.Json;
import sys.io.File as Sys_Fili;
import sys.FileSystem;

enum abstract EditState(Int) from Int to Int {
    var IDLE;
    var NOTE;
    var PRESS;
    var CONFIRM;
}

enum abstract EditMode(Int) from Int to Int {
    var CLIP_POS;
    var CLIP_SIZE;
    var OFFSET;
    var CLIP_ID;
    var GLOBAL_TRANSFORM;
}

/**
    Noteskin editor debug that's accessed from Main Menu (Debug Keybind).
    Shows a live strumline preview via `NoteSystem.notesBuf` and exposes per-index clip/offset editing.
    Also shows a grid for visual reference of how the strumline would look ingame for clip.
    @since 0.94
**/
@:publicFields
class NoteskinEditor {
    var disposed(default, null):Bool;

    var roof(default, null):CustomDisplay;
    var display(default, null):CustomDisplay;
    var view(default, null):CustomDisplay;

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
        // Default noteskin
        loadNoteskin("default");
    }

    public function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
        disposed = false;

        this.roof = roof;
        this.display = display;
        this.view = view;

        createGrid();
        initRendering();
        createReceptors();
        
        // Initialize instructions text AFTER display is set
        initInstructionsText();

        show();

        addEvents();
    }

    function addEvents() {
        #if !android
        var window = Application.current.window;
        window.onKeyDown.add(handleKeyDown);
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

    function initInstructionsText() {
        if (instructionsText == null) {
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
            instructionsText = new Text("NOTESKIN_EDITOR_INSTRUCTIONS", 4, 3, display, "", "vcr");
            instructionsText.scale = 0.7;
            instructionsText.alpha = 0; // Start hidden
            instructionsText.multiline = true;
            instructionsText.alignment = RIGHT;
            instructionsText.spacerPercent = -0.1;
            instructionsText.outlineColor = Color.BLACK;
            instructionsText.outlineSize = 1;
            instructionsText.setMarkerPairs(markers);
            
            // Set initial text
            instructionsText.text = buildInstructionsText();
            
            // Position at top-right
            positionInstructionsTextTopRight();
            
            // Add to display immediately (but keep alpha 0 so it's hidden)
            instructionsText.addProgram();
        }
    }

    function buildInstructionsText():String {
        if (createManiaPopupActive) return "";
        
        var stateName = getStateName(currentState);
        var stateColor = switch(currentState) {
            case IDLE: "#M1#";
            case NOTE: "#M2#";
            case PRESS: "#M3#";
            case CONFIRM: "#M4#";
            default: "";
        };
        
        var clip = getClipForIndex(selectedIndex);
        var basicClip:BasicNoteskinClip = getBasicClipForState(clip, currentState);
        var currentValue = getClipValue(basicClip);
        
        var editModeName = getEditModeName(editMode);
        var editModeColor = getEditModeColor(editMode);
        
        var spritesheetText = spriteSheetMode ? 
            "#M9#[SPRITESHEET MODE - Mouse only!]\n" +
            "Drag to pan view | Press ESC or Hold click to exit#M9#\n" : 
            "";
        
        var maniaText = 'Mania: #M5#[${currentManiaIndex + 1}/${availableManiaConfigs.length + 1} - ${maxReceptors}K]#M5#\n';
        var gapText = 'Gap: #M5#[${currentConfig.gap}]#M5#\n';
        
        var globalText = "";
        if (editMode == GLOBAL_TRANSFORM) {
            var modeName = globalScaleMode ? "Scale" : "Offset";
            var modeColor = globalScaleMode ? "#M4#" : "#M6#";
            globalText = 'Global Transform: ${modeColor}$modeName${modeColor}\n';
            if (globalScaleMode) {
                globalText += '#M5#Scale: ${Math.round(currentConfig.scale * 100) / 100}#M5#\n';
            } else {
                globalText += '#M5#Offset X: ${currentConfig.offsetX}, Y: ${currentConfig.offsetY}#M5#\n';
            }
            globalText += "#M1#CTRL+SPACE: Toggle Offset/Scale#M1#\n";
        }
        
        return 
            "NOTESKIN EDITOR INSTRUCTIONS:\n" +
            (!spriteSheetMode ? "TAB or Mouse Wheel: Cycle animation state (SHIFT+TAB to go backwards)\n" : "") +
            "CTRL+TAB: Toggle edit mode\n" +
            "SHIFT+CTRL+TAB: Switch mania\n" +
            "CTRL+SHIFT+SPACE: Create new mania\n" +
            "ALT+LEFT/RIGHT or ALT+MouseWheel: Adjust gap\n" +
            "CTRL+ALT+LEFT/RIGHT or CTRL+ALT+MouseWheel: Adjust gap (10x)\n" +
            (!spriteSheetMode && editMode == GLOBAL_TRANSFORM ? 
                "Arrow Keys: Adjust Offset/Scale\n" :
                (spriteSheetMode ? "Arrow Keys or TAB: Switch receptor index\n" :
                "Arrow Keys: Edit X/Y values\n")) +
            "CTRL+Arrow Keys: Adjust value (+10)\n" +
            (!spriteSheetMode && editMode != GLOBAL_TRANSFORM ? "SHIFT+LEFT/RIGHT: Switch receptor index\n" : "") +
            (!spriteSheetMode && editMode == GLOBAL_TRANSFORM ? "LEFT/RIGHT: Adjust offset/scale\n" : "") +
            "Hold Click: Toggle spritesheet view\n" +
            "Mouse Drag: Modify current properties\n" +
            "ESC: Close editor\n" +
            (spriteSheetMode ? "#M9#[SPRITESHEET MODE - Mouse only!]\n" +
            "Drag to pan view | Press ESC or hold click to exit#M9#\n" : 
            "") +
            maniaText +
            gapText +
            globalText +
            'Current State: ${stateColor}${stateName}${stateColor}\n' +
            'Selected Receptor: #M5#[${selectedIndex + 1}/${maxReceptors}]#M5#' +
            (editMode != GLOBAL_TRANSFORM ? '\nEdit Mode: ${editModeColor}${editModeName}${editModeColor}' : '');
    }

    function getBasicClipForState(clip:NoteskinReceptorProperties, state:EditState):BasicNoteskinClip {
        return switch(state) {
            case IDLE: clip.idle;
            case NOTE: clip.press;
            case PRESS: clip.press;
            case CONFIRM: clip.confirm;
            default: clip.idle;
        }
    }

    function loadNoteskin(skinName:String) {
        currentSkinName = skinName;
        var skinFolder = 'assets/images/noteskins/$skinName';
        
        try {
            // Check if data.json exists, create default if not
            var dataPath = Paths.asset('$skinFolder/data.json');
            if (!FileSystem.exists(dataPath)) {
                createDefaultDataJson(skinFolder);
            }
            
            noteskinHandle = new NoteskinHandle(skinName);
            noteskinData = noteskinHandle.data;
            
            // Store all mania configs
            availableManiaConfigs = noteskinData.configMania != null ? noteskinData.configMania.copy() : [];
            
            // If no configs exist, create a default one
            if (availableManiaConfigs.length == 0) {
                availableManiaConfigs.push({
                    offsetX: 0,
                    offsetY: 0,
                    gap: 112,
                    scale: 1.0,
                    indexes: [0, 1, 2, 3]
                });
            }
            
            // Set current config to first one
            currentManiaIndex = 0;
            currentConfig = availableManiaConfigs[currentManiaIndex];
            
            // Update maxReceptors based on current config
            updateMaxReceptorsFromConfig();

            // Get clips from the top-level clip array
            var clips = noteskinData.clip;
            
            // Ensure we have clips for all receptors
            var numReceptors = clips != null ? clips.length : 0;
            if (numReceptors < maxReceptors) {
                // Pad with defaults if needed - using actual texture coords from XML
                var defaultClip:NoteskinReceptorProperties = {
                    idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                    press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
                    color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                    confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                    holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                    holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
                };
                
                while (clips.length < maxReceptors) {
                    clips.push(defaultClip);
                }
            }
            
            // Ensure selectedIndex is within bounds
            if (selectedIndex >= maxReceptors) {
                selectedIndex = maxReceptors - 1;
            }
        } catch (e) {
            trace('Failed to load noteskin $skinName: $e');
            createDefaultNoteskin();
        }
    }

    function createDefaultDataJson(skinFolder:String) {
        try {
            // Create default data.json structure
            var defaultData = {
                name: "default",
                sparrowImg: "notes.png",
                configMania: [{
                    offsetX: 0,
                    offsetY: 0,
                    gap: 112,
                    scale: 1.0,
                    indexes: [0, 1, 2, 3]
                }],
                clip: [
                    {
                        idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
                        color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
                    },
                    {
                        idle: {clipX: 346, clipY: 3, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        press: {clipX: 3, clipY: 230, clipW: 99, clipH: 98, offsX: 0, offsY: 0},
                        color: {clipX: 346, clipY: 3, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        confirm: {clipX: 246, clipY: 3, clipW: 189, clipH: 189, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 262, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 51, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
                    },
                    {
                        idle: {clipX: 233, clipY: 3, clipW: 110, clipH: 111, offsX: 0, offsY: 0},
                        press: {clipX: 217, clipY: 230, clipW: 97, clipH: 99, offsX: 0, offsY: 0},
                        color: {clipX: 233, clipY: 3, clipW: 110, clipH: 111, offsX: 0, offsY: 0},
                        confirm: {clipX: 197, clipY: 249, clipW: 193, clipH: 189, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 295, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 147, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
                    },
                    {
                        idle: {clipX: 346, clipY: 115, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        press: {clipX: 337, clipY: 227, clipW: 101, clipH: 99, offsX: 0, offsY: 0},
                        color: {clipX: 346, clipY: 115, clipW: 111, clipH: 109, offsX: 0, offsY: 0},
                        confirm: {clipX: 3, clipY: 249, clipW: 191, clipH: 192, offsX: 0, offsY: 0},
                        holdBody: {clipX: 460, clipY: 195, clipW: 35, clipH: 31, offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 99, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
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
        if (currentConfig.indexes != null) {
            maxReceptors = currentConfig.indexes.length;
            // Ensure we have at least 1 receptor
            if (maxReceptors < 1) {
                maxReceptors = 1;
                currentConfig.indexes = [0];
            }
        } else {
            maxReceptors = 4;
            currentConfig.indexes = [0, 1, 2, 3];
        }
    }

    function generateManiaFromClips():NoteskinConfig {
        var clipCount = noteskinData.clip != null ? noteskinData.clip.length : 0;
        var indexes:Array<Int> = [];
        for (i in 0...clipCount) {
            indexes.push(i);
        }
        return {
            offsetX: 0,
            offsetY: 0,
            gap: 120,
            scale: 1.0,
            indexes: indexes
        };
    }

    function switchMania(direction:Int) {
        if (availableManiaConfigs.length == 0) return;
        
        var totalManias = availableManiaConfigs.length + 1; // +1 for preview mania
        var newIndex = currentManiaIndex + direction;
        if (newIndex < 0) newIndex = totalManias - 1;
        if (newIndex >= totalManias) newIndex = 0;
        
        currentManiaIndex = newIndex;

        if (currentManiaIndex < availableManiaConfigs.length) {
            // Normal mania
            currentConfig = availableManiaConfigs[currentManiaIndex];
        } else {
            // Preview mania - generate from all clips
            currentConfig = generateManiaFromClips();
        }
        
        // Update maxReceptors
        updateMaxReceptorsFromConfig();
        
        // Ensure clips exist for all receptors
        var clips = noteskinData.clip;
        var defaultClip:NoteskinReceptorProperties = {
            idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
            color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
            holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
            holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
        };
        
        while (clips.length < maxReceptors) {
            clips.push(defaultClip);
        }
        
        // Ensure selectedIndex is within bounds
        if (selectedIndex >= maxReceptors) {
            selectedIndex = maxReceptors - 1;
        }
        
        // Ensure spritesheet selected index is valid
        if (spritesheetSelectedIndex >= maxReceptors) {
            spritesheetSelectedIndex = maxReceptors - 1;
        }
        
        // Recreate receptors with new config
        createReceptors();
        updateReceptorVisuals();
        updateInstructionsText();
        
        var modeName = currentManiaIndex >= availableManiaConfigs.length ? "Preview All Clips" : '${maxReceptors}K';
        trace('Switched to mania ${currentManiaIndex + 1}/${totalManias} - $modeName');
    }

    function createNewMania() {
        // Show the popup
        createManiaPopupActive = true;
        createManiaInput = "";
        createManiaError = "";
        createManiaKeyCount = 0;
        
        // Remove any existing popup background just in case
        if (popupBackground != null) {
            gridBuf.removeElement(popupBackground);
            popupBackground = null;
        }
        
        trace('Create Mania popup opened - Enter number of keys');
    }

    function createDefaultNoteskin() {
        noteskinData = {
            name: "default",
            sparrowImg: "notes.png",
            configMania: [{
                offsetX: 0,
                offsetY: 0,
                gap: 112,
                scale: 1.0,
                indexes: [0, 1, 2, 3]
            }],
            clip: []
        };
        availableManiaConfigs = noteskinData.configMania.copy();
        currentManiaIndex = 0;
        currentConfig = availableManiaConfigs[currentManiaIndex];
        updateMaxReceptorsFromConfig();

        // Default clips using actual texture coordinates from the XML
        var defaultClip:NoteskinReceptorProperties = {
            idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
            color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
            holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
            holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
        };

        for (i in 0...maxReceptors) {
            noteskinData.clip.push(defaultClip);
        }
    }

    function confirmCreateMania() {
        // Parse the input
        var keyCount = Std.parseInt(createManiaInput);
        if (keyCount == null || keyCount <= 0) {
            createManiaError = "Please enter a valid positive number";
            return;
        }
        
        // Check if this mania already exists
        for (config in availableManiaConfigs) {
            if (config.indexes != null && config.indexes.length == keyCount) {
                createManiaError = 'Mania with $keyCount keys already exists!';
                return;
            }
        }
        
        // Create the new mania
        var indexes:Array<Int> = [];
        for (i in 0...keyCount) {
            indexes.push(i);
        }
        
        var newMania:NoteskinConfig = {
            offsetX: 0,
            offsetY: 0,
            gap: 112,
            scale: 1.0,
            indexes: indexes
        };
        
        // Add the new mania
        availableManiaConfigs.push(newMania);
        
        // Fill in missing manias from 1 to keyCount
        fillMissingManias(keyCount);
        
        // Sort manias by key count
        sortManiasByKeyCount();
        
        // Find the index of the new mania after sorting
        var newIndex = availableManiaConfigs.indexOf(newMania);
        if (newIndex != -1) {
            currentManiaIndex = newIndex;
            currentConfig = availableManiaConfigs[currentManiaIndex];
            updateMaxReceptorsFromConfig();
            
            // Ensure clips exist
            var clips = noteskinData.clip;
            var defaultClip:NoteskinReceptorProperties = {
                idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
                color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
            };
            while (clips.length < maxReceptors) {
                clips.push(defaultClip);
            }
            
            createReceptors();
            updateReceptorVisuals();
            updateInstructionsText();
            trace('Created new mania with $keyCount keys');
        }
        
        // Close the popup immediately and remove background
        createManiaPopupActive = false;
        createManiaInput = "";
        createManiaError = "";
        
        if (popupBackground != null) {
            gridBuf.removeElement(popupBackground);
            popupBackground = null;
            gridBuf.update();
        }
        
        // Restore instructions text
        updateInstructionsText();
    }

    function fillMissingManias(maxKeys:Int) {
        // Check which key counts already exist
        var existingKeyCounts:Array<Int> = [];
        for (config in availableManiaConfigs) {
            if (config.indexes != null) {
                existingKeyCounts.push(config.indexes.length);
            }
        }
        
        // Fill in missing manias from 1 to maxKeys
        for (i in 1...maxKeys) {
            // Skip if this key count already exists
            if (existingKeyCounts.indexOf(i) != -1) continue;
            
            // Create the missing mania
            var indexes:Array<Int> = [];
            for (j in 0...i) {
                indexes.push(j);
            }
            
            var newMania:NoteskinConfig = {
                offsetX: 0,
                offsetY: 0,
                gap: 112,
                scale: 1.0,
                indexes: indexes
            };
            
            availableManiaConfigs.push(newMania);
            trace('Auto-created mania with $i keys');
        }
    }

    function cancelCreateMania() {
        createManiaPopupActive = false;
        createManiaInput = "";
        createManiaError = "";
        
        // Remove popup background
        if (popupBackground != null) {
            gridBuf.removeElement(popupBackground);
            popupBackground = null;
            gridBuf.update();
        }
        
        trace('Create Mania cancelled');
    }

    function sortManiasByKeyCount() {
        // Remove any duplicate manias (same key count)
        var seenKeyCounts:Array<Int> = [];
        var uniqueManias:Array<NoteskinConfig> = [];
        
        for (config in availableManiaConfigs) {
            if (config.indexes != null) {
                var keyCount = config.indexes.length;
                if (seenKeyCounts.indexOf(keyCount) == -1) {
                    seenKeyCounts.push(keyCount);
                    uniqueManias.push(config);
                }
            }
        }
        
        availableManiaConfigs = uniqueManias;
        
        // Sort manias by their index length (key count)
        availableManiaConfigs.sort(function(a:NoteskinConfig, b:NoteskinConfig) {
            var lenA = a.indexes != null ? a.indexes.length : 0;
            var lenB = b.indexes != null ? b.indexes.length : 0;
            return lenA - lenB;
        });
    }

    function createGrid() {
        try {
            if (gridBuf == null) {
                gridBuf = new Buffer<RepeatSprite>(16, 16, true);
            }

            if (gridProg == null) {
                gridProg = new CustomProgram(gridBuf);
            }

            view.addProgram(gridProg);
        } catch (e) {
            trace('Failed to create grid: $e');
        }
    }

    function updateGridPosition() {
        for (sprite in gridSprites) {
            gridBuf.removeElement(sprite);
        }
        gridSprites = [];

        var gap = currentConfig.gap != 0 ? currentConfig.gap : 112;
        var offsetX = currentConfig.offsetX;
        var offsetY = currentConfig.offsetY;
        var startX = (Main.INITIAL_WIDTH - (maxReceptors * gap)) / 2 + offsetX;
        var y = Main.INITIAL_HEIGHT / 2 + offsetY;
        var scale = currentConfig.scale;

        for (i in 0...maxReceptors) {
            if (i >= receptorSprites.length) break;
            
            var receptor = receptorSprites[i];
            var clipIndex = getClipIndexForReceptor(i);
            var clip = getClipForIndex(clipIndex);
            var basicClip = getBasicClipForState(clip, currentState);

            var gridSprite = new RepeatSprite(
                Math.round(receptor.x + basicClip.offsX),
                Math.round(receptor.y + basicClip.offsY),
                Math.round(basicClip.clipW * scale),
                Math.round(basicClip.clipH * scale)
            );
            
            gridSprite.c.setFloatRGB(0, 1, 1);
            gridSprite.c.aF = 0.125;
            gridSprite.c.luminanceF = 0.125;

            if (spriteSheetMode && i == spritesheetSelectedIndex) {
                // In spritesheet mode, the grid should follow the spritesheet view with scale applied
                gridSprite.x += Math.round(SPRITESHEET_VIEW_OFFSET * scale);
                gridSprite.y += Math.round(SPRITESHEET_VIEW_OFFSET * scale);
            }

            gridSprites.push(gridSprite);
            gridBuf.addElement(gridSprite);
        }

        gridBuf.update();
    }

    function initRendering() {
        texture = getCombinedNoteskinTexture();
        
        if (noteBuf == null) {
            noteBuf = new Buffer<Note>(16, 16, true);
        }

        if (noteProg == null) {
            noteProg = new CustomProgram(noteBuf);
            Note.init(noteProg, NOTESKIN_TEXTURE_NAME, texture);
        }
        
        view.addProgram(noteProg);
    }

    function getCombinedNoteskinTexture():Texture {
        var existingTex = TextureSystem.getTexture(NOTESKIN_TEXTURE_NAME);
        if (existingTex != null) {
            return existingTex;
        }

        try {
            var skinFolder = 'assets/images/noteskins/$currentSkinName';
            
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

            TextureSystem.pool[NOTESKIN_TEXTURE_NAME] = texture;
            
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

    function createReceptors() {
        for (sprite in receptorSprites) {
            noteBuf.removeElement(sprite);
        }
        receptorSprites = [];

        var gap = currentConfig.gap != 0 ? currentConfig.gap : 112;
        var offsetX = currentConfig.offsetX;
        var offsetY = currentConfig.offsetY;
        var startX = (Main.INITIAL_WIDTH - (maxReceptors * gap)) / 2 + offsetX;
        var y = Main.INITIAL_HEIGHT / 2 + offsetY;
        var scale = currentConfig.scale;

        for (i in 0...maxReceptors) {
            var note = new Note(
                Std.int(startX + (i * gap)),
                Std.int(y),
                100, 100,
                scale,
                scale,
                0.0
            );
            
            var clipIndex = getClipIndexForReceptor(i);
            var clip = getClipForIndex(clipIndex);
            applyClipToNote(note, currentState, clip);
            note.changeID(clipIndex);
            
            if (currentManiaIndex >= availableManiaConfigs.length) {
                note.initialAlpha = 0.9;
            }
            
            receptorSprites.push(note);
            noteBuf.addElement(note);
        }

        noteBuf.update();
    }

    function getClipIndexForReceptor(index:Int):Int {
        if (currentConfig.indexes != null && index < currentConfig.indexes.length) {
            return currentConfig.indexes[index];
        }
        return index;
    }

    function getClipForIndex(index:Int):NoteskinReceptorProperties {
        var clips = noteskinData.clip;
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

    function applyClipToNote(note:Note, state:EditState, clip:NoteskinReceptorProperties) {
        var basicClip = getBasicClipForState(clip, state);

        var scale = currentConfig.scale;
        var scaledWidth = Std.int(basicClip.clipW * scale);
        var scaledHeight = Std.int(basicClip.clipH * scale);

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
        // Recreate all receptors with new global transform
        createReceptors();
        updateReceptorVisuals();
        updateInstructionsText();
        var modeName = globalScaleMode ? "Scale" : "Offset";
        if (globalScaleMode) {
            trace('Global Scale: ${currentConfig.scale}');
        } else {
            trace('Global Offset: (${currentConfig.offsetX}, ${currentConfig.offsetY})');
        }
    }

    function updateReceptorVisuals() {
        var gap = currentConfig.gap != 0 ? currentConfig.gap : 112;
        var offsetX = currentConfig.offsetX;
        var offsetY = currentConfig.offsetY;
        var startX = (Main.INITIAL_WIDTH - (maxReceptors * gap)) / 2 + offsetX;
        var y = Main.INITIAL_HEIGHT / 2 + offsetY;
        var scale = currentConfig.scale;

        var isPreview = currentManiaIndex >= availableManiaConfigs.length;

        for (i in 0...receptorSprites.length) {
            var note = receptorSprites[i];
            
            var clipIndex = getClipIndexForReceptor(i);
            var clip = getClipForIndex(clipIndex);
            
            note.x = Std.int(startX + (i * gap));
            note.y = Std.int(y);
            note.scale = scale;
            
            if (spriteSheetMode && i == spritesheetSelectedIndex) {
                var basicClip = getBasicClipForState(clip, currentState);
                
                note.c = 0xFF00FFFF;
                note.initialAlpha = 0.5;
                
                // The clipX/Y should be the actual clip position minus the offset to show the full texture
                // The width/height should be the full texture size
                note.clipX = basicClip.clipX - SPRITESHEET_VIEW_OFFSET;
                note.clipY = basicClip.clipY - SPRITESHEET_VIEW_OFFSET;
                note.clipWidth = texture.width + SPRITESHEET_VIEW_OFFSET;
                note.clipHeight = texture.height + SPRITESHEET_VIEW_OFFSET;
                note.clipSizeX = texture.width + SPRITESHEET_VIEW_OFFSET;
                note.clipSizeY = texture.height + SPRITESHEET_VIEW_OFFSET;
                // note.w and note.h are automatically scaled, so we just set the base size
                note.w = texture.width + SPRITESHEET_VIEW_OFFSET;
                note.h = texture.height + SPRITESHEET_VIEW_OFFSET;
                note.ox = basicClip.offsX;
                note.oy = basicClip.offsY;
                // Position offset for the spritesheet view - scaled to match the visual size
                note.x -= Math.round(SPRITESHEET_VIEW_OFFSET * scale);
                note.y -= Math.round(SPRITESHEET_VIEW_OFFSET * scale);
            } else {
                if (i == selectedIndex) {
                    note.c = 0x00FF00FF;
                } else {
                    note.c = 0xFFFFFFFF;
                }
                if (!isPreview) {
                    note.initialAlpha = 1.0;
                }
                applyClipToNote(note, currentState, clip);
            }
            
            note.changeID(clipIndex);
            noteBuf.updateElement(note);
        }

        noteBuf.update();
        updateGridPosition();
        updateInstructionsText();
    }

    function updateReceptorState(state:EditState) {
        currentState = state;
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function selectNextIndex() {
        selectedIndex = (selectedIndex + 1) % maxReceptors;
        if (spriteSheetMode) {
            spritesheetSelectedIndex = selectedIndex;
        }
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function selectPreviousIndex() {
        selectedIndex = (selectedIndex - 1 + maxReceptors) % maxReceptors;
        if (spriteSheetMode) {
            spritesheetSelectedIndex = selectedIndex;
        }
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function toggleState(increment:Int) {
        if (spriteSheetMode) {
            // In spritesheet mode, TAB controls the selected receptor index
            if (increment > 0) {
                selectNextIndex();
            } else {
                selectPreviousIndex();
            }
            return;
        }
        var newState:Int = currentState + increment;
        if (newState < 0) newState = 3;
        if (newState >= 4) newState = 0;
        updateReceptorState(newState);
        trace('State changed to: ${getStateName(currentState)}');
    }

    function getStateName(state:EditState):String {
        return switch(state) {
            case IDLE: "IDLE";
            case NOTE: "TO NOTE";
            case PRESS: "PRESS";
            case CONFIRM: "CONFIRM";
            default: "unknown";
        }
    }

    function toggleEditMode() {
        if (spriteSheetMode) return;
        
        // Store the current mode before changing
        var previousMode = editMode;
        var newMode:Int = editMode + 1;
        if (newMode > 4) newMode = 0;

        editMode = newMode;
        
        // Reset global transform mode when leaving GLOBAL_TRANSFORM
        if (editMode != GLOBAL_TRANSFORM) {
            globalScaleMode = false;
        }
        
        checkInvalidClipIDPlace();
        
        switch(editMode) {
            case CLIP_POS:
                if (selectedProperty == "clipW" || selectedProperty == "clipH" || 
                    selectedProperty == "offsX" || selectedProperty == "offsY" || 
                    selectedProperty == "clipIndex") selectedProperty = "clipX";
            case CLIP_SIZE:
                if (selectedProperty == "clipX" || selectedProperty == "clipY" || 
                    selectedProperty == "offsX" || selectedProperty == "offsY" || 
                    selectedProperty == "clipIndex") selectedProperty = "clipW";
            case OFFSET:
                if (selectedProperty == "clipX" || selectedProperty == "clipY" || 
                    selectedProperty == "clipW" || selectedProperty == "clipH" || 
                    selectedProperty == "clipIndex") selectedProperty = "offsX";
            case CLIP_ID:
                if (selectedProperty == "clipX" || selectedProperty == "clipY" || 
                    selectedProperty == "clipW" || selectedProperty == "clipH" || 
                    selectedProperty == "offsX" || selectedProperty == "offsY") selectedProperty = "clipIndex";
            case GLOBAL_TRANSFORM:
                selectedProperty = "global";
        }
        trace('Edit mode: ${getEditModeName(editMode)}');
        updateInstructionsText();
    }

    function checkInvalidClipIDPlace() {
        // Check if we're trying to enter CLIP_ID while in preview clips mode
        if (editMode == CLIP_ID && currentManiaIndex >= availableManiaConfigs.length) {
            trace('CLIPINDEX: Please back out of preview clip mania first for this mode, that way you don\'t render garbage data.');
            // Go to the next mode instead of forcing to CLIP_POS
            editMode++;
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

    function adjustSelectedValue(amount:Int) {
        if (spriteSheetMode) return;
        
        // Check if we're in preview clips mode and trying to modify clipIndex
        if (selectedProperty == "clipIndex" && currentManiaIndex >= availableManiaConfigs.length) {
            trace('CLIPINDEX: Please back out of preview clip mania first, so that way you don\'t get a garbage render from it.');
            return;
        }
        
        var clipIndex = getClipIndexForReceptor(selectedIndex);
        var clip = getClipForIndex(clipIndex);
        var basicClip = getBasicClipForState(clip, currentState);

        var isClipIndexProperty = false;

        switch(selectedProperty) {
            case "clipX": basicClip.clipX -= amount;
            case "clipY": basicClip.clipY -= amount;
            case "clipW": basicClip.clipW += amount;
            case "clipH": basicClip.clipH += amount;
            case "offsX": basicClip.offsX += amount;
            case "offsY": basicClip.offsY += amount;
            case "clipIndex":
                isClipIndexProperty = true;
                if (currentConfig.indexes == null) {
                    currentConfig.indexes = [];
                }
                while (currentConfig.indexes.length <= selectedIndex) {
                    currentConfig.indexes.push(currentConfig.indexes.length);
                }
                currentConfig.indexes[selectedIndex] += amount;
                if (currentConfig.indexes[selectedIndex] < 0) {
                    currentConfig.indexes[selectedIndex] = 0;
                }
                // Create new clip if index exceeds clip count
                while (noteskinData.clip.length <= currentConfig.indexes[selectedIndex]) {
                    var defaultClip:NoteskinReceptorProperties = {
                        idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
                        color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                        confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                        holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                        holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
                    };
                    noteskinData.clip.push(defaultClip);
                    trace('Created new clip at index ${noteskinData.clip.length - 1}');
                }
                // Update maxReceptors if we're in preview mode
                if (currentManiaIndex == availableManiaConfigs.length) {
                    maxReceptors = noteskinData.clip.length;
                    currentConfig.indexes = [for (i in 0...noteskinData.clip.length) i];
                }
            default: selectedProperty = "clipX";
        }

        if (!isClipIndexProperty) {
            var currentClipIndex = getClipIndexForReceptor(selectedIndex);
            updateClipInConfig(currentClipIndex, currentState, basicClip);
        }
        
        updateReceptorVisuals();

        trace('${getStateName(currentState)}.$selectedProperty = ${getClipValue(basicClip)}');
        updateInstructionsText();
    }

    function getClipValue(clip:BasicNoteskinClip):Int {
        switch(selectedProperty) {
            case "clipX": return clip.clipX;
            case "clipY": return clip.clipY;
            case "clipW": return clip.clipW;
            case "clipH": return clip.clipH;
            case "offsX": return clip.offsX;
            case "offsY": return clip.offsY;
            case "clipIndex":
                if (currentConfig.indexes != null && selectedIndex < currentConfig.indexes.length) {
                    return currentConfig.indexes[selectedIndex];
                }
                return selectedIndex;
            default: return 0;
        }
    }

    function updateClipInConfig(index:Int, state:EditState, clip:BasicNoteskinClip) {
        var clips = noteskinData.clip;
        if (clips != null && index < clips.length) {
            var currentClip = clips[index];
            switch(state) {
                case IDLE: currentClip.idle = clip;
                case NOTE: currentClip.press = clip;
                case PRESS: currentClip.press = clip;
                case CONFIRM: currentClip.confirm = clip;
                default:
            }
        }
    }

    function toggleProperty() {
        if (spriteSheetMode) return;
        var properties = getPropertiesForMode(editMode);
        var currentIndex = properties.indexOf(selectedProperty);
        selectedProperty = properties[(currentIndex + 1) % properties.length];
        trace('Editing property: $selectedProperty');
        updateInstructionsText();
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

    function adjustGap(amount:Int) {
        if (currentConfig == null) return;
        currentConfig.gap += amount;
        if (currentConfig.gap < 1) currentConfig.gap = 1;
        if (currentConfig.gap > 500) currentConfig.gap = 500;
        
        // Update all receptors with new gap
        createReceptors();
        updateReceptorVisuals();
        updateInstructionsText();
        trace('Gap adjusted to: ${currentConfig.gap}');
    }

    function updateInstructionsText() {
        if (instructionsText != null && showEditor) {
            // If popup is active, don't update with normal instructions
            if (createManiaPopupActive) return;
            
            var newText = buildInstructionsText();
            if (instructionsText.text != newText) {
                instructionsText.text = newText;
            }
            instructionsText.scale = 0.7;
            positionInstructionsTextTopRight();
            instructionsText.alpha = 1;
        }
    }
    
    function positionInstructionsTextTopRight() {
        instructionsText.y = 4;
        instructionsText.x = Main.INITIAL_WIDTH - (instructionsText.width + 4);
    }

    // === Mouse Handling ===

    function getSelectedNote():Note {
        return receptorSprites[selectedIndex];
    }

    function getSelectedClip():BasicNoteskinClip {
        var clipIndex = getClipIndexForReceptor(selectedIndex);
        var clip = getClipForIndex(clipIndex);
        return getBasicClipForState(clip, currentState);
    }

    function toggleSpritesheetMode() {
        spriteSheetMode = !spriteSheetMode;
        if (spriteSheetMode) {
            spritesheetSelectedIndex = selectedIndex;
            trace('Spritesheet mode enabled - showing full texture for receptor ${selectedIndex + 1}');
        } else {
            spritesheetSelectedIndex = -1;
            trace('Spritesheet mode disabled - returning to normal view');
            setCursor(MouseCursor.ARROW);
        }
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function handleMouseDown(mouseX:Float, mouseY:Float, button:MouseButton) {
        if (!showEditor || button != MouseButton.LEFT) return;
        if (Application.current.window == null) return;
        
        var note = getSelectedNote();
        if (note == null) return;
        
        var sx = note.x;
        var sy = note.y;
        var sw = note.w;
        var sh = note.h;
        
        var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;
        
        if (inSprite) {
            // Start holding for long press detection in BOTH modes
            isHoldingMouse = true;
            isLongPress = false;
            longPressTriggered = false;
            mouseDownX = mouseX;
            mouseDownY = mouseY;
            longPressTimer = 0;
            
            // If in spritesheet mode, we'll start dragging after a short delay
            // if the user doesn't long press first
            if (spriteSheetMode) {
                // Don't start drag immediately - wait to see if it's a long press
                // The drag will start in handleMouseMove if the mouse moves
            }
        } else {
            // Not on sprite, start drag if in edit mode
            startDrag(mouseX, mouseY);
        }
    }

    function startDrag(mouseX:Float, mouseY:Float) {
        // Cancel any pending long press
        isHoldingMouse = false;
        isLongPress = false;
        longPressTriggered = false;
        
        // Spritesheet mode dragging - pan the view by modifying clipX/Y
        if (spriteSheetMode) {
            isDragging = true;
            dragStartX = mouseX;
            dragStartY = mouseY;
            lastDragX = mouseX;
            lastDragY = mouseY;
            var clip = getSelectedClip();
            dragStartClipX = clip.clipX;
            dragStartClipY = clip.clipY;
            dragMode = 0;
            setCursor(MouseCursor.MOVE);
            return;
        }
        
        var note = getSelectedNote();
        if (note == null) return;
        
        var sx = note.x;
        var sy = note.y;
        var sw = note.w;
        var sh = note.h;
        
        var margin = 6;
        var nearRight = Math.abs(mouseX - (sx + sw)) <= margin;
        var nearBottom = Math.abs(mouseY - (sy + sh)) <= margin;
        var nearLeft = Math.abs(mouseX - sx) <= margin;
        var nearTop = Math.abs(mouseY - sy) <= margin;
        
        isDragging = true;
        dragStartX = mouseX;
        dragStartY = mouseY;
        lastDragX = mouseX;
        lastDragY = mouseY;
        
        var clip = getSelectedClip();
        dragStartClipX = clip.clipX;
        dragStartClipY = clip.clipY;
        dragStartClipW = clip.clipW;
        dragStartClipH = clip.clipH;
        dragStartOffsX = clip.offsX;
        dragStartOffsY = clip.offsY;
        
        // Determine drag mode based on edit mode and position
        switch(editMode) {
            case CLIP_POS:
                if (nearRight || nearLeft || nearBottom || nearTop) {
                    dragMode = 0;
                }
                setCursor(MouseCursor.MOVE);
            case CLIP_SIZE:
                if (nearRight && nearBottom) {
                    dragMode = 3;
                    setCursor(MouseCursor.RESIZE_NWSE);
                } else if (nearRight) {
                    dragMode = 1;
                    setCursor(MouseCursor.RESIZE_WE);
                } else if (nearBottom) {
                    dragMode = 2;
                    setCursor(MouseCursor.RESIZE_NS);
                } else {
                    dragMode = 3;
                    setCursor(MouseCursor.RESIZE_NWSE);
                }
            case OFFSET:
                if (nearRight) {
                    dragMode = 4;
                    setCursor(MouseCursor.RESIZE_WE);
                } else if (nearBottom) {
                    dragMode = 5;
                    setCursor(MouseCursor.RESIZE_NS);
                } else {
                    dragMode = 6;
                    setCursor(MouseCursor.MOVE);
                }
            case CLIP_ID:
                dragMode = -1;
                setCursor(MouseCursor.ARROW);
            default:
                dragMode = 0;
                setCursor(MouseCursor.MOVE);
        }
    }

    function handleMouseUp(mouseX:Float, mouseY:Float, button:MouseButton) {
        if (button != MouseButton.LEFT) return;
        if (Application.current.window == null) return;
        
        // Cancel long press
        isHoldingMouse = false;
        isLongPress = false;
        
        isDragging = false;
        setCursor(MouseCursor.ARROW);
        dragMode = 0;
    }

    function handleMouseMove(mouseX:Float, mouseY:Float) {
        if (!showEditor) return;
        if (Application.current.window == null) return;
        
        var note = getSelectedNote();
        if (note == null) return;
        
        // Check if mouse moved too far from start position (cancel long press or start drag)
        if (isHoldingMouse && !longPressTriggered) {
            var dx = Math.abs(mouseX - mouseDownX);
            var dy = Math.abs(mouseY - mouseDownY);
            if (dx > 10 || dy > 10) {
                isHoldingMouse = false;
                startDrag(mouseX, mouseY);
                return;
            }
        }
        
        if (isDragging) {
            var dx = mouseX - dragStartX;
            var dy = mouseY - dragStartY;
            
            // Spritesheet mode dragging - pan the view by modifying clipX/Y
            if (spriteSheetMode) {
                var clip = getSelectedClip();
                var newX = Std.int(dragStartClipX - dx);
                var newY = Std.int(dragStartClipY - dy);
                clip.clipX = newX;
                clip.clipY = newY;
                selectedProperty = "clipX";
                
                var clipIndex = getClipIndexForReceptor(selectedIndex);
                updateClipInConfig(clipIndex, currentState, clip);
                updateReceptorVisuals();
                updateInstructionsText();
                setCursor(MouseCursor.MOVE);
                return;
            }
            
            // Normal dragging for other edit modes
            var clip = getSelectedClip();
            
            switch(editMode) {
                case CLIP_POS:
                    var newX = Std.int(dragStartClipX - dx);
                    var newY = Std.int(dragStartClipY - dy);
                    clip.clipX = newX;
                    clip.clipY = newY;
                    selectedProperty = "clipX";
                    
                case CLIP_SIZE:
                    switch(dragMode) {
                        case 1:
                            var newW = Std.int(Math.max(1, dragStartClipW + dx));
                            clip.clipW = newW;
                            selectedProperty = "clipW";
                        case 2:
                            var newH = Std.int(Math.max(1, dragStartClipH + dy));
                            clip.clipH = newH;
                            selectedProperty = "clipH";
                        case 3:
                            var newW = Std.int(Math.max(1, dragStartClipW + dx));
                            var newH = Std.int(Math.max(1, dragStartClipH + dy));
                            clip.clipW = newW;
                            clip.clipH = newH;
                            selectedProperty = "clipW";
                        default:
                    }
                    
                case OFFSET:
                    switch(dragMode) {
                        case 4:
                            var newX = Std.int(dragStartOffsX + dx);
                            clip.offsX = newX;
                            selectedProperty = "offsX";
                        case 5:
                            var newY = Std.int(dragStartOffsY + dy);
                            clip.offsY = newY;
                            selectedProperty = "offsY";
                        case 6:
                            var newX = Std.int(dragStartOffsX + dx);
                            var newY = Std.int(dragStartOffsY + dy);
                            clip.offsX = newX;
                            clip.offsY = newY;
                            selectedProperty = "offsX";
                        default:
                    }
                    
                default:
                    return;
            }
            
            var clipIndex = getClipIndexForReceptor(selectedIndex);
            updateClipInConfig(clipIndex, currentState, clip);
            updateReceptorVisuals();
            updateInstructionsText();
            
            // Update cursor based on drag mode
            switch(editMode) {
                case CLIP_POS:
                    setCursor(MouseCursor.MOVE);
                case CLIP_SIZE:
                    switch(dragMode) {
                        case 1: setCursor(MouseCursor.RESIZE_WE);
                        case 2: setCursor(MouseCursor.RESIZE_NS);
                        case 3: setCursor(MouseCursor.RESIZE_NWSE);
                        default:
                    }
                case OFFSET:
                    switch(dragMode) {
                        case 4: setCursor(MouseCursor.RESIZE_WE);
                        case 5: setCursor(MouseCursor.RESIZE_NS);
                        case 6: setCursor(MouseCursor.MOVE);
                        default:
                    }
                default:
            }
        } else {
            // Hover state - update cursor
            if (!spriteSheetMode) {
                var clip = getSelectedClip();
                var sx = note.x + clip.offsX;
                var sy = note.y + clip.offsY;
                var sw = note.w;
                var sh = note.h;
                var margin = 6;
                
                var nearRight = Math.abs(mouseX - (sx + sw)) <= margin;
                var nearBottom = Math.abs(mouseY - (sy + sh)) <= margin;
                var nearLeft = Math.abs(mouseX - sx) <= margin;
                var nearTop = Math.abs(mouseY - sy) <= margin;
                var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;
                
                if (inSprite && editMode != CLIP_ID) {
                    switch(editMode) {
                        case CLIP_POS:
                            if (nearRight || nearLeft || nearBottom || nearTop) {
                                setCursor(MouseCursor.MOVE);
                            } else {
                                setCursor(MouseCursor.MOVE);
                            }
                        case CLIP_SIZE:
                            if (nearRight && nearBottom) {
                                setCursor(MouseCursor.RESIZE_NWSE);
                            } else if (nearRight) {
                                setCursor(MouseCursor.RESIZE_WE);
                            } else if (nearBottom) {
                                setCursor(MouseCursor.RESIZE_NS);
                            } else {
                                setCursor(MouseCursor.RESIZE_NWSE);
                            }
                        case OFFSET:
                            if (nearRight) {
                                setCursor(MouseCursor.RESIZE_WE);
                            } else if (nearBottom) {
                                setCursor(MouseCursor.RESIZE_NS);
                            } else {
                                setCursor(MouseCursor.MOVE);
                            }
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
        if (!showEditor) return;
        
        // ALT+MouseWheel: Adjust gap
        if (isAltPressed) {
            var amount = deltaY > 0 ? (isCtrlPressed ? 10 : 1) : (isCtrlPressed ? -10 : -1);
            adjustGap(amount);
            return;
        }
        
        if (deltaY > 0) {
            if (spriteSheetMode) {
                selectNextIndex();
            } else {
                toggleState(1);
            }
        } else if (deltaY < 0) {
            if (spriteSheetMode) {
                selectPreviousIndex();
            } else {
                toggleState(-1);
            }
        }
    }

    // Key handling
    public function handleKeyDown(key:KeyCode, modifier:KeyModifier) {
        // Track modifier states
        isCtrlPressed = (modifier & KeyModifier.CTRL) != 0;
        isShiftPressed = (modifier & KeyModifier.SHIFT) != 0;
        isAltPressed = (modifier & KeyModifier.ALT) != 0;
        
        if (createManiaPopupActive) {
            handleCreateManiaPopupInput(key);
            return;
        }
        
        if (key == KeyCode.ESCAPE) {
            if (spriteSheetMode) {
                toggleSpritesheetMode();
                return;
            }
            toggleEditor();
            return;
        }

        if (!showEditor) return;

        // CTRL+SPACE toggles global transform mode (X/Y vs Scale)
        if (key == KeyCode.SPACE && isCtrlPressed && !isShiftPressed) {
            if (editMode == GLOBAL_TRANSFORM) {
                globalScaleMode = !globalScaleMode;
                var modeName = globalScaleMode ? "Scale" : "Offset";
                trace('Global transform mode: $modeName');
                updateInstructionsText();
            }
            return;
        }

        switch(key) {
            case KeyCode.SPACE:
                if (isCtrlPressed && isShiftPressed) {
                    createNewMania();
                } else if (!spriteSheetMode && editMode != GLOBAL_TRANSFORM) {
                    toggleAxisProperty();
                }
            case KeyCode.UP:
                if (spriteSheetMode) {
                    selectPreviousIndex();
                } else if (isCtrlPressed && editMode != CLIP_ID && editMode != GLOBAL_TRANSFORM) {
                    adjustAxisValue(-10, "Y");
                } else if (editMode == GLOBAL_TRANSFORM) {
                    if (globalScaleMode) {
                        // Scale mode - UP increases scale
                        currentConfig.scale += 0.05;
                        updateGlobalTransform();
                    } else {
                        // Offset mode - UP decreases Y
                        currentConfig.offsetY -= isCtrlPressed ? 10 : 1;
                        updateGlobalTransform();
                    }
                } else {
                    adjustAxisValue(-1, "Y");
                }
            case KeyCode.DOWN:
                if (spriteSheetMode) {
                    selectNextIndex();
                } else if (isCtrlPressed && editMode != CLIP_ID && editMode != GLOBAL_TRANSFORM) {
                    adjustAxisValue(10, "Y");
                } else if (editMode == GLOBAL_TRANSFORM) {
                    if (globalScaleMode) {
                        // Scale mode - DOWN decreases scale
                        currentConfig.scale -= 0.05;
                        if (currentConfig.scale < 0.1) currentConfig.scale = 0.1;
                        updateGlobalTransform();
                    } else {
                        // Offset mode - DOWN increases Y
                        currentConfig.offsetY += isCtrlPressed ? 10 : 1;
                        updateGlobalTransform();
                    }
                } else {
                    adjustAxisValue(1, "Y");
                }
            case KeyCode.LEFT:
                if (spriteSheetMode) {
                    selectPreviousIndex();
                } else if (isAltPressed) {
                    adjustGap(isCtrlPressed ? -10 : -1);
                } else if (isShiftPressed) {
                    selectPreviousIndex();
                } else if (isCtrlPressed && editMode != CLIP_ID && editMode != GLOBAL_TRANSFORM) {
                    adjustAxisValue(-10, "X");
                } else if (editMode == GLOBAL_TRANSFORM) {
                    if (globalScaleMode) {
                        // Scale mode - LEFT decreases scale
                        currentConfig.scale -= 0.05;
                        if (currentConfig.scale < 0.1) currentConfig.scale = 0.1;
                        updateGlobalTransform();
                    } else {
                        // Offset mode - LEFT decreases X
                        currentConfig.offsetX -= isCtrlPressed ? 10 : 1;
                        updateGlobalTransform();
                    }
                } else {
                    adjustAxisValue(-1, "X");
                }
            case KeyCode.RIGHT:
                if (spriteSheetMode) {
                    selectNextIndex();
                } else if (isAltPressed) {
                    adjustGap(isCtrlPressed ? 10 : 1);
                } else if (isShiftPressed) {
                    selectNextIndex();
                } else if (isCtrlPressed && editMode != CLIP_ID && editMode != GLOBAL_TRANSFORM) {
                    adjustAxisValue(10, "X");
                } else if (editMode == GLOBAL_TRANSFORM) {
                    if (globalScaleMode) {
                        // Scale mode - RIGHT increases scale
                        currentConfig.scale += 0.05;
                        updateGlobalTransform();
                    } else {
                        // Offset mode - RIGHT increases X
                        currentConfig.offsetX += isCtrlPressed ? 10 : 1;
                        updateGlobalTransform();
                    }
                } else {
                    adjustAxisValue(1, "X");
                }
            case KeyCode.TAB:
                if (isCtrlPressed && isShiftPressed) {
                    switchMania(1);
                    checkInvalidClipIDPlace();
                } else if (isCtrlPressed) {
                    if (!spriteSheetMode) toggleEditMode();
                } else {
                    toggleState(isShiftPressed ? -1 : 1);
                }
            default:
        }
    }

    function renderCreateManiaPopup() {
        if (!createManiaPopupActive || instructionsText == null) return;
        
        // Create or update popup background
        if (popupBackground == null) {
            popupBackground = new RepeatSprite(0, 0, 0, 0);
            popupBackground.c = 0x000000FF; // Black
            popupBackground.c.aF = 0.6; // 60% opacity
            gridBuf.addElement(popupBackground);
        }
        
        // Build popup text
        var popupText = 
            "    #M6#=== CREATE NEW MANIA ===#M6#\n" +
            "How many keys this time?\n" +
            "(Enter a number 1-64)\n\n" +
            '#M5#Keys: $createManiaInput#M5#\n';
        
        if (createManiaError != "") {
            popupText += '#M2#$createManiaError#M2#\n';
        }
        
        popupText += 
            "\n#M1#[ENTER] Confirm#M1#   #M3#[ESC] Cancel#M3#";
        
        // Update instructions text
        instructionsText.text = popupText;
        instructionsText.alignment = LEFT;
        instructionsText.scale = 1.2;
        instructionsText.alpha = 1;
        
        // Force the text to recalculate its dimensions by calling update
        // This ensures width/height are correct before positioning
        instructionsText.refresh();
        
        // Center the text on screen
        instructionsText.x = (Main.INITIAL_WIDTH - instructionsText.width) / 2;
        instructionsText.y = (Main.INITIAL_HEIGHT - instructionsText.height) / 2;
        
        // Update popup background to match instructions text bounds
        var padding = 20;
        popupBackground.x = Std.int(instructionsText.x - padding);
        popupBackground.y = Std.int(instructionsText.y - padding);
        popupBackground.w = Std.int(instructionsText.width + padding * 2);
        popupBackground.h = Std.int(instructionsText.height + padding * 2);
        gridBuf.updateElement(popupBackground);
        gridBuf.update();
    }

    function handleCreateManiaPopupInput(key:KeyCode) {
        switch(key) {
            case KeyCode.ESCAPE:
                // ESC cancels the popup without closing the editor
                cancelCreateMania();
                // Restore instructions text after cancel
                updateInstructionsText();
            case KeyCode.RETURN:
                confirmCreateMania();
            case KeyCode.BACKSPACE:
                if (createManiaInput.length > 0) {
                    createManiaInput = createManiaInput.substring(0, createManiaInput.length - 1);
                    createManiaError = "";
                }
            default:
        }

        // Handle number input (supports both regular and numpad keys)
        var num = key - 0x30; // '0' key
        var num2 = key - 0x40000059; // Numpad keys
        if (((num >= 0 && num < 10) || (num2 >= 0 && num2 < 10)) && createManiaInput.length < 2) {
            // Use the actual number from the key
            var digit = num >= 0 && num < 10 ? num : num2;
            createManiaInput += Std.string(digit);
            createManiaError = "";
        }
    }

    function adjustAxisValue(amount:Int, axis:String) {
        if (spriteSheetMode) return;
        
        var propertyToEdit:String;
        
        switch(editMode) {
            case CLIP_POS:
                propertyToEdit = axis == "X" ? "clipX" : "clipY";
            case CLIP_SIZE:
                propertyToEdit = axis == "X" ? "clipW" : "clipH";
            case OFFSET:
                propertyToEdit = axis == "X" ? "offsX" : "offsY";
            case CLIP_ID:
                selectedProperty = "clipIndex";
                adjustSelectedValue(amount);
                return;
            default:
                return;
        }
        
        selectedProperty = propertyToEdit;
        adjustSelectedValue(amount);
    }

    function toggleAxisProperty() {
        if (spriteSheetMode) return;
        
        var properties = getPropertiesForMode(editMode);
        if (properties.length <= 1) return;
        
        var currentAxis = selectedProperty.charAt(selectedProperty.length - 1);
        var newAxis = currentAxis == "X" ? "Y" : "X";
        var baseName = selectedProperty.substring(0, selectedProperty.length - 1);
        var newProperty = baseName + newAxis;
        
        if (properties.indexOf(newProperty) != -1) {
            selectedProperty = newProperty;
        } else {
            selectedProperty = properties[0];
        }
        
        trace('Editing property: $selectedProperty');
        updateInstructionsText();
    }

    public function toggleEditor() {
        showEditor = !showEditor;
        if (showEditor) {
            if (texture == null) {
                texture = getCombinedNoteskinTexture();
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
            updateReceptorVisuals();
            
            if (instructionsText != null) {
                instructionsText.alpha = 1;
                updateInstructionsText();
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
            
            setCursor(MouseCursor.ARROW);
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
        removeEvents();

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
            renderCreateManiaPopup();
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
                    setCursor(MouseCursor.ARROW);
                    // Update visuals
                    updateReceptorVisuals();
                    updateInstructionsText();
                } else {
                    // ENTER spritesheet mode
                    toggleSpritesheetMode();
                }
            }
        }
    }
}
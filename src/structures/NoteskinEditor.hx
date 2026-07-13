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

/**
    Noteskin editor debug that's accessed from Main Menu (Debug Keybind).
    Shows a live strumline preview via `NoteSystem.notesBuf` and exposes per-index clip/offset editing.
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
    var currentState:Int = 0; // 0=idle, 1=toNote, 2=press, 3=confirm
    var currentReceptorIndex:Int = 0;
    var currentLane:Int = 0;
    var selectedIndex:Int = 0;
    var maxReceptors:Int = 4; // Default mania 4
    var editMode:Int = 0; // 0 = clipX/clipY, 1 = clipW/clipH, 2 = offsX/offsY, 3 = clipIndex

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

    // Modifier key tracking for mouse wheel
    var isCtrlPressed:Bool = false;
    var isShiftPressed:Bool = false;
    var isAltPressed:Bool = false;

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
    
    // Preview clips mode (extra mania)
    var previewClipsCameraX:Float = 0;
    var previewClipsCameraY:Float = 0;
    var previewClipsZoom:Float = 1.0;
    var previewGridSprites:Array<RepeatSprite> = [];
    
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
        window.onKeyDown.add(handleKeyUp);
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
            instructionsText.alignment = LEFT;
            instructionsText.spacerPercent = -0.1;
            instructionsText.outlineColor = Color.BLACK;
            instructionsText.outlineSize = 1;
            instructionsText.setMarkerPairs(markers);
            
            // Set initial text
            instructionsText.text = buildInstructionsText();
            
            // Position at bottom-left
            instructionsText.x = 4;
            instructionsText.y = Main.INITIAL_HEIGHT - (instructionsText.height + 4);
            
            // Add to display immediately (but keep alpha 0 so it's hidden)
            instructionsText.addProgram();
        }
    }

    function isPreviewClipsMode():Bool {
        return currentManiaIndex == availableManiaConfigs.length - 1 && 
               availableManiaConfigs.length > 0 && 
               noteskinData.clip != null && 
               noteskinData.clip.length > 0;
    }

    function buildInstructionsText():String {
        var stateName = getStateName(currentState);
        var stateColor = switch(currentState) {
            case 0: "#M1#";
            case 1: "#M2#";
            case 2: "#M3#";
            case 3: "#M4#";
            default: "";
        };
        
        // Get the current clip value
        var clip = getClipForIndex(selectedIndex);
        var basicClip:BasicNoteskinClip;
        switch(currentState) {
            case 0: basicClip = clip.idle;
            case 1: basicClip = clip.press;
            case 2: basicClip = clip.press;
            case 3: basicClip = clip.confirm;
            default: basicClip = clip.idle;
        }
        var currentValue = getClipValue(basicClip);
        
        var editModeName = getEditModeName(editMode);
        var editModeColor = getEditModeColor(editMode);
        
        var spritesheetText = spriteSheetMode ? 
            "#M9#[SPRITESHEET MODE - Mouse only!]\n" +
            "Drag to pan view | Press ESC or Hold click (400ms) to exit#M9#\n" : 
            "";
        
        var isPreview = isPreviewClipsMode();
        var modeName = isPreview ? "PREVIEW CLIPS" : '${maxReceptors}K';
        var maniaText = 'Mania: #M5#[${currentManiaIndex + 1}/${availableManiaConfigs.length} - $modeName]#M5#\n';
        
        var previewControls = isPreview ? 
            "#M6#Arrow Keys: Move camera | CTRL+MouseWheel: Zoom | SHIFT+MouseWheel: Move up/down#M6#\n" : "";
        
        return 
            "NOTESKIN EDITOR INSTRUCTIONS:\n" +
            (!spriteSheetMode && !isPreview ? "TAB: Cycle animation state (SHIFT+TAB to go backwards)\n" : "") +
            "CTRL+TAB: Toggle edit mode\n" +
            "SHIFT+CTRL+TAB: Switch mania\n" +
            "Mouse Wheel: Cycle animation state\n" +
            (spriteSheetMode ? "Arrow Keys or TAB: Switch receptor index\n" :
            isPreview ? "Arrow Keys: Move camera\n" :
            "Arrow Keys: Edit X/Y values\n") +
            "CTRL+Arrow Keys: Adjust value (10)\n" +
            (!spriteSheetMode && !isPreview ? "SHIFT+LEFT/RIGHT: Switch receptor index\n" : "") +
            "Hold Click (400ms): Toggle spritesheet view\n" +
            "Mouse Drag: Modify current properties\n" +
            "ESC: Close editor\n" +
            (spriteSheetMode ? "#M9#[SPRITESHEET MODE - Mouse only!]\n" +
            "Drag to pan view | Press ESC or Hold click (400ms) to exit#M9#\n" : 
            "") +
            previewControls +
            maniaText +
            'Current State: ${stateColor}${stateName}${stateColor}\n' +
            'Selected Receptor: #M5#[${selectedIndex + 1}/${maxReceptors}]#M5#\n' +
            'Edit Mode: ${editModeColor}${editModeName}${editModeColor}\n' +
            'Editing: #M5#${selectedProperty} = ${currentValue}#M5#';
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
                    indexes: [0, 1, 2, 3]
                });
            }
            
            // Add Preview Clips as a special mania at the end
            var totalClips = noteskinData.clip != null ? noteskinData.clip.length : 0;
            if (totalClips > 0) {
                var previewIndexes:Array<Int> = [];
                for (i in 0...totalClips) {
                    previewIndexes.push(i);
                }
                availableManiaConfigs.push({
                    offsetX: 0,
                    offsetY: 0,
                    gap: 90, // Slightly smaller gap for preview
                    indexes: previewIndexes
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

    function switchMania(direction:Int) {
        if (availableManiaConfigs.length == 0) return;
        
        var newIndex = currentManiaIndex + direction;
        if (newIndex < 0) newIndex = availableManiaConfigs.length - 1;
        if (newIndex >= availableManiaConfigs.length) newIndex = 0;
        
        var wasPreview = isPreviewClipsMode();
        currentManiaIndex = newIndex;
        currentConfig = availableManiaConfigs[currentManiaIndex];
        
        // Check if we're entering preview clips mode
        if (isPreviewClipsMode()) {
            trace('Entering Preview Clips mode');
            // Clear existing grid sprites
            clearPreviewClips();
            // Create preview clips receptors
            createPreviewClipsReceptors();
        } else {
            trace('Exiting Preview Clips mode');
            // Clear preview clips if any
            clearPreviewClips();
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
        }
        
        updateInstructionsText();
        
        var modeName = isPreviewClipsMode() ? "Preview Clips" : '${maxReceptors}K';
        trace('Switched to mania ${currentManiaIndex + 1}/${availableManiaConfigs.length} - $modeName');
    }

    function createDefaultNoteskin() {
        noteskinData = {
            name: "default",
            sparrowImg: "notes.png",
            configMania: [{
                offsetX: 0,
                offsetY: 0,
                gap: 112,
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

    function createGrid() {
        try {
            if (gridBuf == null) {
                gridBuf = new Buffer<RepeatSprite>(16, 16, true);
            }

            if (gridProg == null) {
                gridProg = new CustomProgram(gridBuf);
            }

            // Create grid sprites for each receptor
            var gap = currentConfig.gap != 0 ? currentConfig.gap : 112;
            var startX = (Main.INITIAL_WIDTH - (maxReceptors * gap)) / 2;
            var y = Main.INITIAL_HEIGHT / 2;

            for (i in 0...maxReceptors) {
                var gridSprite = new RepeatSprite(
                    Std.int(startX + (i * gap)),
                    Std.int(y),
                    100, 100
                );
                
                // Set color with low alpha
                gridSprite.c.aF = 0.125;
                gridSprite.c.luminanceF = 0.125;
                
                gridSprites.push(gridSprite);
                gridBuf.addElement(gridSprite);
            }

            view.addProgram(gridProg);
        } catch (e) {
            trace('Failed to create grid: $e');
        }
    }

    function updateGridPosition() {
        for (i in 0...gridSprites.length) {
            var gridSprite = gridSprites[i];
            
            if (i < receptorSprites.length) {
                var receptor = receptorSprites[i];

                var clipIndex = getClipIndexForReceptor(i);
                var clip = getClipForIndex(clipIndex);
                
                var basicClip:BasicNoteskinClip;
                switch(currentState) {
                    case 0: basicClip = clip.idle;
                    case 1: basicClip = clip.press;
                    case 2: basicClip = clip.press;
                    case 3: basicClip = clip.confirm;
                    default: basicClip = clip.idle;
                }

                gridSprite.x = receptor.x + basicClip.offsX;
                gridSprite.y = receptor.y + basicClip.offsY;
                gridSprite.w = basicClip.clipW;
                gridSprite.h = basicClip.clipH;
                gridSprite.c.aF = 0.25;

                if (spriteSheetMode && i == spritesheetSelectedIndex) {
                    gridSprite.x += SPRITESHEET_VIEW_OFFSET;
                    gridSprite.y += SPRITESHEET_VIEW_OFFSET;
                }
            }
            
            gridBuf.updateElement(gridSprite);
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

    function createPreviewClipsReceptors() {
        // Clear existing receptors
        for (sprite in receptorSprites) {
            noteBuf.removeElement(sprite);
        }
        receptorSprites = [];
        
        // Clear preview grid sprites
        clearPreviewClips();
        
        var totalClips = noteskinData.clip != null ? noteskinData.clip.length : 0;
        if (totalClips == 0) {
            trace('No clips to preview');
            return;
        }
        
        // Use the gap from the preview config
        var gap = currentConfig.gap != 0 ? currentConfig.gap : 90;
        
        // Calculate total width and starting position
        var totalWidth = totalClips * gap;
        var startX = (Main.INITIAL_WIDTH - totalWidth) / 2 + previewClipsCameraX;
        var y = Main.INITIAL_HEIGHT / 2 + previewClipsCameraY;
        
        for (i in 0...totalClips) {
            var clip = noteskinData.clip[i];
            var basicClip = clip.idle;
            
            var note = new Note(
                Std.int(startX + (i * gap)),
                Std.int(y),
                basicClip.clipW,
                basicClip.clipH,
                1,
                1,
                0.0
            );
            
            // Apply clip data
            note.clipX = basicClip.clipX;
            note.clipY = basicClip.clipY;
            note.clipWidth = basicClip.clipW;
            note.clipHeight = basicClip.clipH;
            note.clipPosX = 0;
            note.clipPosY = 0;
            note.clipSizeX = basicClip.clipW;
            note.clipSizeY = basicClip.clipH;
            note.w = Std.int(basicClip.clipW * previewClipsZoom);
            note.h = Std.int(basicClip.clipH * previewClipsZoom);
            note.ox = basicClip.offsX;
            note.oy = basicClip.offsY;
            note.changeID(i);
            
            // Color based on clip index
            note.initialAlpha = 0.9;
            
            receptorSprites.push(note);
            noteBuf.addElement(note);
            
            // Create grid for this clip
            var gridSprite = new RepeatSprite(
                Std.int(startX + (i * gap) + basicClip.offsX),
                Std.int(y + basicClip.offsY),
                Std.int(basicClip.clipW * previewClipsZoom),
                Std.int(basicClip.clipH * previewClipsZoom)
            );
            gridSprite.c.aF = 0.15;
            gridSprite.c.luminanceF = 0.15;
            previewGridSprites.push(gridSprite);
            gridBuf.addElement(gridSprite);
        }
        
        noteBuf.update();
        gridBuf.update();
        updateInstructionsText();
    }

    function clearPreviewClips() {
        for (grid in previewGridSprites) {
            gridBuf.removeElement(grid);
        }
        previewGridSprites = [];
        gridBuf.update();
    }

    function updatePreviewClipsVisuals() {
        var totalClips = noteskinData.clip != null ? noteskinData.clip.length : 0;
        if (totalClips == 0) return;
        
        var gap = currentConfig.gap != 0 ? currentConfig.gap : 90;
        var totalWidth = totalClips * gap;
        var startX = (Main.INITIAL_WIDTH - totalWidth) / 2 + previewClipsCameraX;
        var y = Main.INITIAL_HEIGHT / 2 + previewClipsCameraY;
        
        for (i in 0...totalClips) {
            if (i >= receptorSprites.length) break;
            
            var note = receptorSprites[i];
            var clip = noteskinData.clip[i];
            var basicClip = clip.idle;
            
            note.x = Std.int(startX + (i * gap));
            note.y = Std.int(y);
            note.w = basicClip.clipW;
            note.h = basicClip.clipH;
            
            applyClipToNote(note, 0, clip);
            note.changeID(i);
            
            noteBuf.updateElement(note);
            
            // Update grid
            if (i < previewGridSprites.length) {
                var grid = previewGridSprites[i];
                grid.x = Std.int(startX + (i * gap) + basicClip.offsX);
                grid.y = Std.int(y + basicClip.offsY);
                grid.w = basicClip.clipW;
                grid.h = basicClip.clipH;
                gridBuf.updateElement(grid);
            }
        }
        
        noteBuf.update();
        gridBuf.update();
        updateInstructionsText();
    }

    function createReceptors() {
        // If in preview clips mode, use the special preview creation
        if (isPreviewClipsMode()) {
            createPreviewClipsReceptors();
            return;
        }
        
        for (sprite in receptorSprites) {
            noteBuf.removeElement(sprite);
        }
        receptorSprites = [];

        var gap = currentConfig.gap != 0 ? currentConfig.gap : 112;
        var startX = (Main.INITIAL_WIDTH - (maxReceptors * gap)) / 2;
        var y = Main.INITIAL_HEIGHT / 2;

        for (i in 0...maxReceptors) {
            var note = new Note(
                Std.int(startX + (i * gap)),
                Std.int(y),
                100, 100,
                1.0,
                1.0,
                0.0
            );
            
            var clipIndex = getClipIndexForReceptor(i);
            var clip = getClipForIndex(clipIndex);
            applyClipToNote(note, currentState, clip);
            note.changeID(clipIndex);
            
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

    function applyClipToNote(note:Note, state:Int, clip:NoteskinReceptorProperties) {
        var basicClip:BasicNoteskinClip;
        
        switch(state) {
            case 0: basicClip = clip.idle;
            case 1: basicClip = clip.press;
            case 2: basicClip = clip.press;
            case 3: basicClip = clip.confirm;
            default: basicClip = clip.idle;
        }

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
    }

    function updateReceptorVisuals() {
        if (isPreviewClipsMode()) {
            updatePreviewClipsVisuals();
            return;
        }
        
        var gap = currentConfig.gap != 0 ? currentConfig.gap : 112;
        var startX = (Main.INITIAL_WIDTH - (maxReceptors * gap)) / 2;
        var y = Main.INITIAL_HEIGHT / 2;

        for (i in 0...receptorSprites.length) {
            var note = receptorSprites[i];
            
            var clipIndex = getClipIndexForReceptor(i);
            var clip = getClipForIndex(clipIndex);
            
            // Update position
            note.x = Std.int(startX + (i * gap));
            note.y = Std.int(y);
            
            if (spriteSheetMode && i == spritesheetSelectedIndex) {
                // Only the selected receptor shows the spritesheet
                var basicClip:BasicNoteskinClip;
                switch(currentState) {
                    case 0: basicClip = clip.idle;
                    case 1: basicClip = clip.press;
                    case 2: basicClip = clip.press;
                    case 3: basicClip = clip.confirm;
                    default: basicClip = clip.idle;
                }
                
                // Half-transparent magenta tint using initialAlpha
                note.c = 0xFF00FFFF; // Magenta (full color, alpha controlled separately)
                note.initialAlpha = 0.5; // 50% transparency
                
                // Use the user's corrected spritesheet visual code
                note.clipX = basicClip.clipX - SPRITESHEET_VIEW_OFFSET;
                note.clipY = basicClip.clipY - SPRITESHEET_VIEW_OFFSET;
                note.clipWidth = texture.width + SPRITESHEET_VIEW_OFFSET;
                note.clipHeight = texture.height + SPRITESHEET_VIEW_OFFSET;
                note.clipSizeX = texture.width + SPRITESHEET_VIEW_OFFSET;
                note.clipSizeY = texture.height + SPRITESHEET_VIEW_OFFSET;
                note.w = texture.width + SPRITESHEET_VIEW_OFFSET;
                note.h = texture.height + SPRITESHEET_VIEW_OFFSET;
                note.ox = basicClip.offsX;
                note.oy = basicClip.offsY;
                note.x -= SPRITESHEET_VIEW_OFFSET;
                note.y -= SPRITESHEET_VIEW_OFFSET;
            } else {
                // Normal mode
                if (i == selectedIndex) {
                    note.c = 0x00FF00FF; // Yellow highlight
                } else {
                    note.c = 0xFFFFFFFF; // White normal
                }
                // Reset initialAlpha to 1.0 for normal mode
                note.initialAlpha = 1.0;
                // Re-apply the clip from the noteskin data
                applyClipToNote(note, currentState, clip);
            }
            
            note.changeID(clipIndex);
            noteBuf.updateElement(note);
        }

        noteBuf.update();
        updateGridPosition();
        updateInstructionsText();
    }

    function updateReceptorState(state:Int) {
        currentState = state;
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function selectNextIndex() {
        if (isPreviewClipsMode()) {
            // In preview clips mode, arrow keys move camera instead
            return;
        }
        selectedIndex = (selectedIndex + 1) % maxReceptors;
        if (spriteSheetMode) {
            spritesheetSelectedIndex = selectedIndex;
        }
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function selectPreviousIndex() {
        if (isPreviewClipsMode()) {
            // In preview clips mode, arrow keys move camera instead
            return;
        }
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
        currentState = currentState + increment;
        if (currentState < 0) currentState = 3;
        if (currentState >= 4) currentState = 0;
        updateReceptorState(currentState);
        trace('State changed to: ${getStateName(currentState)}');
    }

    function getStateName(state:Int):String {
        switch(state) {
            case 0: return "IDLE";
            case 1: return "TO NOTE";
            case 2: return "PRESS";
            case 3: return "CONFIRM";
            default: return "unknown";
        }
    }

    function toggleEditMode() {
        if (spriteSheetMode || isPreviewClipsMode()) return;
        editMode = (editMode + 1) % 4;
        switch(editMode) {
            case 0:
                if (selectedProperty == "clipW") selectedProperty = "clipX";
                if (selectedProperty == "clipH") selectedProperty = "clipY";
                if (selectedProperty == "offsX") selectedProperty = "clipX";
                if (selectedProperty == "offsY") selectedProperty = "clipY";
                if (selectedProperty == "clipIndex") selectedProperty = "clipX";
            case 1:
                if (selectedProperty == "clipX") selectedProperty = "clipW";
                if (selectedProperty == "clipY") selectedProperty = "clipW";
                if (selectedProperty == "offsX") selectedProperty = "clipW";
                if (selectedProperty == "offsY") selectedProperty = "clipW";
                if (selectedProperty == "clipIndex") selectedProperty = "clipW";
            case 2:
                if (selectedProperty == "clipX") selectedProperty = "offsX";
                if (selectedProperty == "clipY") selectedProperty = "offsX";
                if (selectedProperty == "clipW") selectedProperty = "offsX";
                if (selectedProperty == "clipH") selectedProperty = "offsX";
                if (selectedProperty == "clipIndex") selectedProperty = "offsX";
            case 3:
                if (selectedProperty == "clipX") selectedProperty = "clipIndex";
                if (selectedProperty == "clipY") selectedProperty = "clipIndex";
                if (selectedProperty == "clipW") selectedProperty = "clipIndex";
                if (selectedProperty == "clipH") selectedProperty = "clipIndex";
                if (selectedProperty == "offsX") selectedProperty = "clipIndex";
                if (selectedProperty == "offsY") selectedProperty = "clipIndex";
        }
        trace('Edit mode: ${getEditModeName(editMode)}');
        updateInstructionsText();
    }

    function getEditModeName(mode:Int):String {
        switch(mode) {
            case 0: return "Position (clipX/Y)";
            case 1: return "Size (clipW/H)";
            case 2: return "Offset (offsX/Y)";
            case 3: return "Clip Index";
            default: return "Unknown";
        }
    }

    function getEditModeColor(mode:Int):String {
        switch(mode) {
            case 0: return "#M6#";
            case 1: return "#M4#";
            case 2: return "#M7#";
            case 3: return "#M8#";
            default: return "#M5#";
        }
    }

    function adjustSelectedValue(amount:Int) {
        if (spriteSheetMode || isPreviewClipsMode()) return;
        
        var clipIndex = getClipIndexForReceptor(selectedIndex);
        var clip = getClipForIndex(clipIndex);
        var basicClip:BasicNoteskinClip;
        
        switch(currentState) {
            case 0: basicClip = clip.idle;
            case 1: basicClip = clip.press;
            case 2: basicClip = clip.press;
            case 3: basicClip = clip.confirm;
            default: basicClip = clip.idle;
        }

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

    function updateClipInConfig(index:Int, state:Int, clip:BasicNoteskinClip) {
        var clips = noteskinData.clip;
        if (clips != null && index < clips.length) {
            var currentClip = clips[index];
            switch(state) {
                case 0: currentClip.idle = clip;
                case 1: currentClip.press = clip;
                case 2: currentClip.press = clip;
                case 3: currentClip.confirm = clip;
            }
        }
    }

    function toggleProperty() {
        if (spriteSheetMode || isPreviewClipsMode()) return;
        var properties = getPropertiesForMode(editMode);
        var currentIndex = properties.indexOf(selectedProperty);
        selectedProperty = properties[(currentIndex + 1) % properties.length];
        trace('Editing property: $selectedProperty');
        updateInstructionsText();
    }

    function getPropertiesForMode(mode:Int):Array<String> {
        switch(mode) {
            case 0: return ["clipX", "clipY"];
            case 1: return ["clipW", "clipH"];
            case 2: return ["offsX", "offsY"];
            case 3: return ["clipIndex"];
            default: return ["clipX", "clipY"];
        }
    }

    function updateInstructionsText() {
        if (instructionsText != null && showEditor) {
            var newText = buildInstructionsText();
            if (instructionsText.text != newText) {
                instructionsText.text = newText;
            }
            instructionsText.x = 4;
            instructionsText.y = Main.INITIAL_HEIGHT - (instructionsText.height + 4);
            instructionsText.alpha = 1;
        }
    }

    // === Mouse Handling ===

    function getSelectedNote():Note {
        return receptorSprites[selectedIndex];
    }

    function getSelectedClip():BasicNoteskinClip {
        var clipIndex = getClipIndexForReceptor(selectedIndex);
        var clip = getClipForIndex(clipIndex);
        switch(currentState) {
            case 0: return clip.idle;
            case 1: return clip.press;
            case 2: return clip.press;
            case 3: return clip.confirm;
            default: return clip.idle;
        }
    }

    function toggleSpritesheetMode() {
        if (isPreviewClipsMode()) return; // Disable spritesheet in preview mode
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
        
        // In preview clips mode, clicking starts camera drag
        if (isPreviewClipsMode()) {
            startDrag(mouseX, mouseY);
            return;
        }
        
        var note = getSelectedNote();
        if (note == null) return;
        
        var sx = note.x;
        var sy = note.y;
        var sw = note.w;
        var sh = note.h;
        
        var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;
        
        if (inSprite) {
            // Start holding for long press detection
            isHoldingMouse = true;
            isLongPress = false;
            longPressTriggered = false;
            mouseDownX = mouseX;
            mouseDownY = mouseY;
            longPressTimer = 0;
            
            if (spriteSheetMode) {
                // Don't start drag immediately - wait to see if it's a long press
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
        
        // Preview clips mode dragging - pan the view
        if (isPreviewClipsMode()) {
            isDragging = true;
            dragStartX = mouseX;
            dragStartY = mouseY;
            lastDragX = mouseX;
            lastDragY = mouseY;
            dragMode = 0;
            setCursor(MouseCursor.MOVE);
            return;
        }
        
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
        if (editMode == 0) { // Position mode - clipX/Y
            if (nearRight || nearLeft) {
                dragMode = 0;
                setCursor(MouseCursor.RESIZE_WE);
            } else if (nearBottom || nearTop) {
                dragMode = 0;
                setCursor(MouseCursor.RESIZE_NS);
            } else {
                dragMode = 0;
                setCursor(MouseCursor.MOVE);
            }
        } else if (editMode == 1) {
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
        } else if (editMode == 2) {
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
        } else {
            dragMode = -1;
            setCursor(MouseCursor.ARROW);
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
        
        // Always update mouse position for cursor changes
        var note = getSelectedNote();
        if (note == null) return;
        
        // Check if mouse moved too far from start position (cancel long press or start drag)
        if (isHoldingMouse && !longPressTriggered) {
            var dx = Math.abs(mouseX - mouseDownX);
            var dy = Math.abs(mouseY - mouseDownY);
            if (dx > 10 || dy > 10) {
                // Cancel long press
                isHoldingMouse = false;
                // Start dragging
                startDrag(mouseX, mouseY);
                return;
            }
        }
        
        if (isDragging) {
            var dx = mouseX - dragStartX;
            var dy = mouseY - dragStartY;
            
            // Preview clips mode dragging - pan the view
            if (isPreviewClipsMode()) {
                previewClipsCameraX += dx;
                previewClipsCameraY += dy;
                dragStartX = mouseX;
                dragStartY = mouseY;
                updatePreviewClipsVisuals();
                setCursor(MouseCursor.MOVE);
                return;
            }
            
            // Spritesheet mode dragging - pan the view by modifying clipX/Y
            if (spriteSheetMode) {
                var clip = getSelectedClip();
                var newX = Std.int(dragStartClipX - dx);
                var newY = Std.int(dragStartClipY - dy);
                clip.clipX = newX;
                clip.clipY = newY;
                selectedProperty = "clipX";
                
                // Update the clip in config
                var clipIndex = getClipIndexForReceptor(selectedIndex);
                updateClipInConfig(clipIndex, currentState, clip);
                
                // Update the visual display
                updateReceptorVisuals();
                updateInstructionsText();
                setCursor(MouseCursor.MOVE);
                return;
            }
            
            // Normal dragging for other edit modes
            var clip = getSelectedClip();
            
            switch(editMode) {
                case 0: // Position mode - clipX/Y
                    var newX = Std.int(dragStartClipX - dx);
                    var newY = Std.int(dragStartClipY - dy);
                    clip.clipX = newX;
                    clip.clipY = newY;
                    selectedProperty = "clipX";
                    
                case 1: // Size mode - clipW/H
                    switch(dragMode) {
                        case 1: // Resize right - only W
                            var newW = Std.int(Math.max(1, dragStartClipW + dx));
                            clip.clipW = newW;
                            selectedProperty = "clipW";
                        case 2: // Resize bottom - only H
                            var newH = Std.int(Math.max(1, dragStartClipH + dy));
                            clip.clipH = newH;
                            selectedProperty = "clipH";
                        case 3: // Corner resize - both W and H
                            var newW = Std.int(Math.max(1, dragStartClipW + dx));
                            var newH = Std.int(Math.max(1, dragStartClipH + dy));
                            clip.clipW = newW;
                            clip.clipH = newH;
                            selectedProperty = "clipW";
                        default:
                    }
                    
                case 2: // Offset mode - offsX/Y
                    switch(dragMode) {
                        case 4: // Offset X only
                            var newX = Std.int(dragStartOffsX + dx);
                            clip.offsX = newX;
                            selectedProperty = "offsX";
                        case 5: // Offset Y only
                            var newY = Std.int(dragStartOffsY + dy);
                            clip.offsY = newY;
                            selectedProperty = "offsY";
                        case 6: // Move both axes
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
            
            // Update the clip in config
            var clipIndex = getClipIndexForReceptor(selectedIndex);
            updateClipInConfig(clipIndex, currentState, clip);
            
            // Update the visual display
            updateReceptorVisuals();
            updateInstructionsText();
            
            // Update cursor based on drag mode
            switch(editMode) {
                case 0:
                    setCursor(MouseCursor.MOVE);
                case 1:
                    switch(dragMode) {
                        case 1: setCursor(MouseCursor.RESIZE_WE);
                        case 2: setCursor(MouseCursor.RESIZE_NS);
                        case 3: setCursor(MouseCursor.RESIZE_NWSE);
                        default:
                    }
                case 2:
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
            if (!spriteSheetMode && !isPreviewClipsMode()) {
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
                
                if (inSprite && editMode != 3) {
                    switch(editMode) {
                        case 0:
                            if (nearRight || nearLeft) {
                                setCursor(MouseCursor.RESIZE_WE);
                            } else if (nearBottom || nearTop) {
                                setCursor(MouseCursor.RESIZE_NS);
                            } else {
                                setCursor(MouseCursor.MOVE);
                            }
                        case 1:
                            if (nearRight && nearBottom) {
                                setCursor(MouseCursor.RESIZE_NWSE);
                            } else if (nearRight) {
                                setCursor(MouseCursor.RESIZE_WE);
                            } else if (nearBottom) {
                                setCursor(MouseCursor.RESIZE_NS);
                            } else {
                                setCursor(MouseCursor.RESIZE_NWSE);
                            }
                        case 2:
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
            } else if (isPreviewClipsMode()) {
                setCursor(MouseCursor.MOVE);
            } else {
                // In spritesheet mode, show move cursor on the selected receptor
                var sx = note.x;
                var sy = note.y;
                var sw = note.w;
                var sh = note.h;
                var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;
                if (inSprite) {
                    setCursor(MouseCursor.MOVE);
                } else {
                    setCursor(MouseCursor.ARROW);
                }
            }
        }
    }

    function handleMouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode) {
        if (!showEditor) return;
        
        if (isPreviewClipsMode()) {
            // Camera controls in preview clips mode
            if (isAltPressed) {
                // ALT + MouseWheel: Zoom in/out
                var zoomFactor = deltaY > 0 ? 1.1 : 0.9;
                previewClipsZoom *= zoomFactor;
                previewClipsZoom = Math.max(0.1, Math.min(3.0, previewClipsZoom));
                updatePreviewClipsVisuals();
                trace('Zoom: ${previewClipsZoom}');
            } else if (isCtrlPressed) {
                // CTRL + MouseWheel: Move left/right
                previewClipsCameraX += deltaY > 0 ? 20 : -20;
                updatePreviewClipsVisuals();
                trace('Camera X: ${previewClipsCameraX}');
            } else if (isShiftPressed) {
                // SHIFT + MouseWheel: Move up/down
                previewClipsCameraY += deltaY > 0 ? -20 : 20;
                updatePreviewClipsVisuals();
                trace('Camera Y: ${previewClipsCameraY}');
            }
            return;
        }
        
        // Normal mouse wheel controls TAB functionality
        if (deltaY > 0) {
            // Scroll up - cycle forward (like TAB)
            if (spriteSheetMode) {
                // In spritesheet mode, scroll changes the selected receptor index
                selectNextIndex();
            } else {
                toggleState(1);
            }
        } else if (deltaY < 0) {
            // Scroll down - cycle backward (like SHIFT+TAB)
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
        
        if (key == KeyCode.ESCAPE) {
            if (spriteSheetMode) {
                // Exit spritesheet mode first
                toggleSpritesheetMode();
                return;
            }
            toggleEditor();
            return;
        }

        if (!showEditor) return;

        var isShift = (modifier & KeyModifier.SHIFT) != 0;
        var isCtrl = (modifier & KeyModifier.CTRL) != 0;

        switch(key) {
            case KeyCode.UP:
                if (spriteSheetMode) {
                    // In spritesheet mode, UP changes receptor index
                    selectPreviousIndex();
                } else if (isPreviewClipsMode()) {
                    // In preview clips mode, UP moves camera up
                    previewClipsCameraY -= 20;
                    updatePreviewClipsVisuals();
                } else if (isCtrl) {
                    adjustAxisValue(-10, "Y");
                } else {
                    // Edit Y axis - decrease value (up = less Y)
                    adjustAxisValue(-1, "Y");
                }
            case KeyCode.DOWN:
                if (spriteSheetMode) {
                    // In spritesheet mode, DOWN changes receptor index
                    selectNextIndex();
                } else if (isPreviewClipsMode()) {
                    // In preview clips mode, DOWN moves camera down
                    previewClipsCameraY += 20;
                    updatePreviewClipsVisuals();
                } else if (isCtrl) {
                    adjustAxisValue(10, "Y");
                } else {
                    // Edit Y axis - increase value (down = more Y)
                    adjustAxisValue(1, "Y");
                }
            case KeyCode.LEFT:
                if (spriteSheetMode) {
                    // In spritesheet mode, LEFT changes receptor index
                    selectPreviousIndex();
                } else if (isPreviewClipsMode()) {
                    // In preview clips mode, LEFT moves camera left
                    previewClipsCameraX -= 20;
                    updatePreviewClipsVisuals();
                } else if (isShift) {
                    selectPreviousIndex();
                } else if (isCtrl) {
                    adjustAxisValue(-10, "X");
                } else {
                    // Edit X axis - decrease value (left = less X)
                    adjustAxisValue(-1, "X");
                }
            case KeyCode.RIGHT:
                if (spriteSheetMode) {
                    // In spritesheet mode, RIGHT changes receptor index
                    selectNextIndex();
                } else if (isPreviewClipsMode()) {
                    // In preview clips mode, RIGHT moves camera right
                    previewClipsCameraX += 20;
                    updatePreviewClipsVisuals();
                } else if (isShift) {
                    selectNextIndex();
                } else if (isCtrl) {
                    adjustAxisValue(10, "X");
                } else {
                    // Edit X axis - increase value (right = more X)
                    adjustAxisValue(1, "X");
                }
            case KeyCode.TAB:
                if (isCtrl && isShift) {
                    // SHIFT+CTRL+TAB switches mania
                    switchMania(1);
                } else if (isCtrl) {
                    if (!spriteSheetMode && !isPreviewClipsMode()) toggleEditMode();
                } else {
                    toggleState(isShift ? -1 : 1);
                }
            default:
        }
    }

    function handleKeyUp(key:KeyCode, modifier:KeyModifier) {
        // Update modifier states
        isCtrlPressed = (modifier & KeyModifier.CTRL) != 0;
        isShiftPressed = (modifier & KeyModifier.SHIFT) != 0;
        isAltPressed = (modifier & KeyModifier.ALT) != 0;
    }

    /**
        Adjust the current axis value based on the edit mode.
        @param amount - The amount to adjust (positive = increase, negative = decrease)
        @param axis - "X" or "Y" to determine which property to edit
    **/
    function adjustAxisValue(amount:Int, axis:String) {
        if (spriteSheetMode || isPreviewClipsMode()) return;
        
        // Determine which property to edit based on edit mode and axis
        var propertyToEdit:String;
        
        switch(editMode) {
            case 0: // Position mode - clipX/Y
                propertyToEdit = axis == "X" ? "clipX" : "clipY";
            case 1: // Size mode - clipW/H
                propertyToEdit = axis == "X" ? "clipW" : "clipH";
            case 2: // Offset mode - offsX/Y
                propertyToEdit = axis == "X" ? "offsX" : "offsY";
            case 3: // Clip Index mode - doesn't use X/Y
                // In clip index mode, adjust the index value
                selectedProperty = "clipIndex";
                adjustSelectedValue(amount);
                return;
            default:
                return;
        }
        
        // Set the property and adjust it
        selectedProperty = propertyToEdit;
        adjustSelectedValue(amount);
    }

    /**
        Toggle between X and Y properties for the current edit mode.
    **/
    function toggleAxisProperty() {
        if (spriteSheetMode || isPreviewClipsMode()) return;
        
        var properties = getPropertiesForMode(editMode);
        
        // Skip if only one property (like clipIndex mode)
        if (properties.length <= 1) return;
        
        // Determine which axis property we're currently on
        var currentAxis = selectedProperty.charAt(selectedProperty.length - 1);
        var newAxis = currentAxis == "X" ? "Y" : "X";
        
        // Build the new property name
        var baseName = selectedProperty.substring(0, selectedProperty.length - 1);
        var newProperty = baseName + newAxis;
        
        // Check if this property exists in the current mode's properties
        if (properties.indexOf(newProperty) != -1) {
            selectedProperty = newProperty;
        } else {
            // Fallback to first property in the list
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
            
            // Reset spritesheet mode when opening
            spriteSheetMode = false;
            spritesheetSelectedIndex = -1;
            
            // Reset preview clips camera
            previewClipsCameraX = 0;
            previewClipsCameraY = 0;
            previewClipsZoom = 1.0;
            
            // Reset to first mania config
            if (availableManiaConfigs.length > 0) {
                currentManiaIndex = 0;
                currentConfig = availableManiaConfigs[currentManiaIndex];
                updateMaxReceptorsFromConfig();
                createReceptors();
            }
            
            updateReceptorVisuals();
            
            if (instructionsText != null) {
                instructionsText.alpha = 1;
                updateInstructionsText();
            }
            
            trace('Noteskin Editor opened');
        } else {
            // Clear preview clips if any
            clearPreviewClips();
            
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

        // Clear preview clips
        clearPreviewClips();

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
        // Check for long press in the update loop
        if (isHoldingMouse && !longPressTriggered && !isDragging && !isPreviewClipsMode()) {
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
package structures;

import data.SaveData;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.graphics.Image;
import lime.math.Vector2;
import lime.math.Rectangle;
import lime.app.Application;
import lime.ui.MouseButton;
import elements.Note;
import elements.Sprite;
import elements.RepeatSprite;
import elements.Text;
import elements.TextFormatMarkerPair;
import elements.text.TextAlign;
import elements.text.ColorSpan;
import structures.gameplay.NoteskinHandle;
import structures.gameplay.NoteskinHandle.NoteskinData;
import structures.gameplay.NoteskinHandle.NoteskinConfig;
import structures.gameplay.NoteskinHandle.NoteskinReceptorProperties;
import structures.gameplay.NoteskinHandle.BasicNoteskinClip;
import system.TextureSystem;
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
    var roof(default, null):CustomDisplay;
    var display(default, null):CustomDisplay;
    var view(default, null):CustomDisplay;

    // Editor state
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
    var gridTexture:Texture;
    var gridSprites:Array<RepeatSprite> = [];

    // Receptor preview
    var receptorSprites:Array<Note> = [];

    // UI state
    var showEditor:Bool = false;
    var selectedProperty:String = "clipX";
    var propertyValue:Int = 0;
    var editingValue:Bool = false;
    var needsRender:Bool = false;

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
        #end
    }

    function removeEvents() {
        #if !android
        var window = Application.current.window;
        window.onKeyDown.remove(handleKeyDown);
        #end
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
                new TextFormatMarkerPair('#M8#', 0xFF33FF33) // Green for clip index mode
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
        
        return 
            "NOTESKIN EDITOR INSTRUCTIONS:\n" +
            "TAB: Cycle animation state (SHIFT+TAB to go backwards)\n" +
            "CTRL+TAB: Toggle edit mode\n" +
            "UP/DOWN: Adjust selected value (±1)\n" +
            "LEFT/RIGHT: Switch between X/Y (or W/H)\n" +
            "CTRL+LEFT/RIGHT: Adjust value (±10)\n" +
            "SHIFT+LEFT/RIGHT: Switch receptor index\n" +
            "SPACE: Cycle property\n" +
            "ESC: Close editor\n\n" +
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
            
            // Use first config or create default
            if (noteskinData.configMania != null && noteskinData.configMania.length > 0) {
                currentConfig = noteskinData.configMania[0];
            } else {
                // Create default config
                currentConfig = {
                    offsetX: 0,
                    offsetY: 0,
                    gap: 112,
                    indexes: []
                };
            }

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
        currentConfig = noteskinData.configMania[0];

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

    function createGridTexture():Texture {
        // Check if texture already exists
        var existingTex = TextureSystem.getTexture(GRID_TEXTURE_NAME);
        if (existingTex != null) {
            return existingTex;
        }

        try {
            // Create 24x24 grid texture
            var gridSize = 24;
            var data = haxe.io.Bytes.alloc(gridSize * gridSize * 4);
            
            // Fill with dark gray (fully opaque)
            for (i in 0...data.length >> 2) {
                data.setInt32(i << 2, 0xFF404040);
            }
            
            // Draw grid lines (every 8 pixels) - fully opaque colors
            for (y in 0...gridSize) {
                for (x in 0...gridSize) {
                    var isGridLine = (x % 8 == 0 || y % 8 == 0);
                    var isMajorGrid = (x % 8 == 0 && y % 8 == 0);
                    var idx = (y * gridSize + x) << 2;
                    
                    if (isGridLine) {
                        if (isMajorGrid) {
                            // Red for major intersections
                            data.setInt32(idx, 0xFFFF4444);
                        } else {
                            // Light gray for grid lines
                            data.setInt32(idx, 0xFF888888);
                        }
                    }
                }
            }

            // Create texture data with RGBA format (already opaque, no premult needed)
            var textureData = new TextureData(gridSize, gridSize, TextureFormat.RGBA);
            textureData.bytes = data;

            var texture = new Texture(textureData.width, textureData.height, null, {
                format: TextureFormat.RGBA,
                powerOfTwo: false,
                smoothExpand: false,
                smoothShrink: false
            });
            texture.setData(textureData);

            // Store in texture pool
            TextureSystem.pool[GRID_TEXTURE_NAME] = texture;
            
            return texture;
        } catch (e) {
            trace('Failed to create grid texture: $e');
            return createBlankTexture();
        }
    }

    function createGrid() {
        try {
            // Create grid texture
            gridTexture = createGridTexture();
            
            if (gridTexture == null) {
                trace('Grid texture is null, creating blank');
                gridTexture = createBlankTexture();
            }
            
            if (gridTexture == null) {
                trace('Failed to create grid texture, skipping grid');
                return;
            }
            
            if (gridBuf == null) {
                gridBuf = new Buffer<RepeatSprite>(16, 16, true);
            }

            if (gridProg == null) {
                gridProg = new CustomProgram(gridBuf);
                gridProg.setTexture(gridTexture, GRID_TEXTURE_NAME);
                gridProg.setColorFormula('c * getTextureColor(${GRID_TEXTURE_NAME}_ID, vTexCoord)');
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
                gridSprite.c = 0x44FFFFFF; // Semi-transparent white
                
                // IMPORTANT: For RepeatSprite, clipX and clipY should be 0
                // and clipWidth/clipHeight should match the texture size
                // The repeat will handle tiling across the sprite
                gridSprite.clipX = 0;
                gridSprite.clipY = 0;
                gridSprite.clipWidth = gridTexture.width;
                gridSprite.clipHeight = gridTexture.height;
                gridSprite.clipPosX = 0;
                gridSprite.clipPosY = 0;
                gridSprite.clipSizeX = gridTexture.width;
                gridSprite.clipSizeY = gridTexture.height;
                
                // Set the tile - this tells the shader which tile of the texture to use
                gridSprite.tile = 0;
                gridSprite.slot = 0;
                
                gridSprites.push(gridSprite);
                gridBuf.addElement(gridSprite);
            }

            // Update buffer once after adding all elements
            gridBuf.update();

            // Add to roof (behind everything)
            roof.addProgram(gridProg);
        } catch (e) {
            trace('Failed to create grid: $e');
        }
    }

    function updateGridPosition() {
        for (i in 0...gridSprites.length) {
            var gridSprite = gridSprites[i];
            
            // Match the size and position of the receptor
            if (i < receptorSprites.length) {
                var receptor = receptorSprites[i];
                gridSprite.x = receptor.x;
                gridSprite.y = receptor.y;
                gridSprite.w = receptor.w;
                gridSprite.h = receptor.h;
                gridSprite.clipWidth = gridSprite.clipSizeX = receptor.w;
                gridSprite.clipHeight = gridSprite.clipSizeY = receptor.h;
                
                // IMPORTANT: Don't change clipX/clipY here!
                // Keep them at 0 so the texture tiles properly
                // Only update the sprite size
                gridSprite.c.aF = 0.25;
            }
            
            gridBuf.updateElement(gridSprite);
        }
        gridBuf.update();
    }

    function initRendering() {
        // Create or get texture using TextureSystem
        texture = getCombinedNoteskinTexture();
        
        if (noteBuf == null) {
            noteBuf = new Buffer<Note>(16, 16, true);
        }

        if (noteProg == null) {
            noteProg = new CustomProgram(noteBuf);
            Note.init(noteProg, NOTESKIN_TEXTURE_NAME, texture);
        }
        
        // Then add note program (on top)
        display.addProgram(noteProg);
    }

    function getCombinedNoteskinTexture():Texture {
        // Check if texture already exists in pool
        var existingTex = TextureSystem.getTexture(NOTESKIN_TEXTURE_NAME);
        if (existingTex != null) {
            return existingTex;
        }

        try {
            var skinFolder = 'assets/images/noteskins/$currentSkinName';
            
            // Load both images
            var notesPath = Paths.asset('$skinFolder/notes.png');
            var confirmPath = Paths.asset('$skinFolder/confirm.png');

            // Check if files exist
            var notesExists = FileSystem.exists(notesPath);
            var confirmExists = FileSystem.exists(confirmPath);

            if (!notesExists && !confirmExists) {
                // Try default path
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

            // Create combined image
            var combinedWidth = notesImage.width + (confirmImage != null ? confirmImage.width : 0);
            var combinedHeight = Std.int(Math.max(notesImage.height, confirmImage != null ? confirmImage.height : 0));
            
            var combinedImage = new Image(null, 0, 0, combinedWidth, combinedHeight, 0x00000000);
            
            // Copy notes.png to the left
            var sourceRect = new Rectangle(0, 0, notesImage.width, notesImage.height);
            var destPoint = new Vector2(0, 0);
            combinedImage.copyPixels(notesImage, sourceRect, destPoint);
            
            // Copy confirm.png to the right if it exists
            if (confirmImage != null) {
                var confirmRect = new Rectangle(0, 0, confirmImage.width, confirmImage.height);
                var confirmDest = new Vector2(notesImage.width, 0);
                combinedImage.copyPixels(confirmImage, confirmRect, confirmDest);
            }

            // Get the raw pixel data from the combined image
            var pixelData = combinedImage.getPixels(new Rectangle(0, 0, combinedWidth, combinedHeight), RGBA32);
            
            // Premultiply alpha
            var premultipliedData = haxe.io.Bytes.alloc(pixelData.length);
            for (i in 0...pixelData.length >> 2) {
                var fullARGB = pixelData.getInt32(i << 2);
                
                var a = (fullARGB >>> 24) & 0xFF;
                var r = (fullARGB >>> 16) & 0xFF;
                var g = (fullARGB >>> 8)  & 0xFF;
                var b = (fullARGB)        & 0xFF;
                
                // Scale RGB by alpha
                r = (r * a) >> 8;
                g = (g * a) >> 8;
                b = (b * a) >> 8;
                
                var premul = (a << 24) | (r << 16) | (g << 8) | b;
                premultipliedData.setInt32(i << 2, premul);
            }
            
            // Create texture data with RGBA format (premultiplied)
            var textureData = new TextureData(combinedWidth, combinedHeight, TextureFormat.RGBA);
            textureData.bytes = premultipliedData;

            // Create texture with combined dimensions
            var texture = new Texture(textureData.width, textureData.height, null, {
                format: TextureFormat.RGBA,
                powerOfTwo: false,
                smoothExpand: SaveData.state.graphics.antialiasing,
                smoothShrink: SaveData.state.graphics.antialiasing
            });
            texture.setData(textureData);

            // Store in texture pool
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
            // Fill with white (premultiplied)
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
        // Clear existing sprites from buffer
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
            
            // Get the clip index for this receptor
            var clipIndex = getClipIndexForReceptor(i);
            
            // Get the clip data from the noteskin data using the clip index
            var clip = getClipForIndex(clipIndex);
            applyClipToNote(note, currentState, clip);
            
            // Set the note's ID to the clip index
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
        // Return default clip
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
            case 0: // idle
                basicClip = clip.idle;
            case 1: // toNote
                basicClip = clip.press; // Using press as toNote
            case 2: // press
                basicClip = clip.press;
            case 3: // confirm
                basicClip = clip.confirm;
            default:
                basicClip = clip.idle;
        }

        // Set clip properties directly - no reset needed
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
        var gap = currentConfig.gap != 0 ? currentConfig.gap : 112;
        var startX = (Main.INITIAL_WIDTH - (maxReceptors * gap)) / 2;
        var y = Main.INITIAL_HEIGHT / 2;

        for (i in 0...receptorSprites.length) {
            var note = receptorSprites[i];
            
            // Get the clip index for this receptor
            var clipIndex = getClipIndexForReceptor(i);
            
            // Get the clip data from the noteskin data using the clip index
            var clip = getClipForIndex(clipIndex);
            
            // Apply the clip based on current state
            applyClipToNote(note, currentState, clip);
            
            // Update position
            note.x = Std.int(startX + (i * gap));
            note.y = Std.int(y);
            
            // Highlight selected receptor
            if (i == selectedIndex) {
                note.c = 0xFFFF00FF; // Yellow highlight
            } else {
                note.c = 0xFFFFFFFF; // White normal
            }
            
            // Set the note's ID to the clip index
            note.changeID(clipIndex);
            
            noteBuf.updateElement(note);
        }

        noteBuf.update();
        
        // Update grid positions to match receptors
        updateGridPosition();
    }

    function updateReceptorState(state:Int) {
        currentState = state;
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function selectNextIndex() {
        selectedIndex = (selectedIndex + 1) % maxReceptors;
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function selectPreviousIndex() {
        selectedIndex = (selectedIndex - 1 + maxReceptors) % maxReceptors;
        updateReceptorVisuals();
        updateInstructionsText();
    }

    function toggleState(increment:Int) {
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
        editMode = (editMode + 1) % 4; // Now 4 modes
        // Update selected property based on edit mode
        switch(editMode) {
            case 0: // Position mode - clipX/clipY
                if (selectedProperty == "clipW") selectedProperty = "clipX";
                if (selectedProperty == "clipH") selectedProperty = "clipY";
                if (selectedProperty == "offsX") selectedProperty = "clipX";
                if (selectedProperty == "offsY") selectedProperty = "clipY";
                if (selectedProperty == "clipIndex") selectedProperty = "clipX";
            case 1: // Size mode - clipW/clipH
                if (selectedProperty == "clipX") selectedProperty = "clipW";
                if (selectedProperty == "clipY") selectedProperty = "clipW";
                if (selectedProperty == "offsX") selectedProperty = "clipW";
                if (selectedProperty == "offsY") selectedProperty = "clipW";
                if (selectedProperty == "clipIndex") selectedProperty = "clipW";
            case 2: // Offset mode - offsX/offsY
                if (selectedProperty == "clipX") selectedProperty = "offsX";
                if (selectedProperty == "clipY") selectedProperty = "offsX";
                if (selectedProperty == "clipW") selectedProperty = "offsX";
                if (selectedProperty == "clipH") selectedProperty = "offsX";
                if (selectedProperty == "clipIndex") selectedProperty = "offsX";
            case 3: // Clip Index mode
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

        // UP/DOWN adjusts the value of the selected property
        switch(selectedProperty) {
            case "clipX": basicClip.clipX += amount;
            case "clipY": basicClip.clipY += amount;
            case "clipW": basicClip.clipW += amount;
            case "clipH": basicClip.clipH += amount;
            case "offsX": basicClip.offsX += amount;
            case "offsY": basicClip.offsY += amount;
            case "clipIndex":
                isClipIndexProperty = true;
                // Adjust the clip index in the config
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
                // Ensure the clip index references a valid clip
                while (noteskinData.clip.length <= currentConfig.indexes[selectedIndex]) {
                    // Push a new default clip
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

        // Update the clip in config (only for non-clipIndex properties)
        if (!isClipIndexProperty) {
            // Get the clip at the current clipIndex and update it
            var currentClipIndex = getClipIndexForReceptor(selectedIndex);
            updateClipInConfig(currentClipIndex, currentState, basicClip);
        }
        
        // Always update the visual display
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
        // LEFT/RIGHT switches between the two properties in the current mode
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
            
            // Reposition in case height changed
            instructionsText.x = 4;
            instructionsText.y = Main.INITIAL_HEIGHT - (instructionsText.height + 4);
            instructionsText.alpha = 1;
        }
    }

    // Key handling
    public function handleKeyDown(key:KeyCode, modifier:KeyModifier) {
        // Special case: ESC always toggles the editor, even if it's closed
        if (key == KeyCode.ESCAPE) {
            toggleEditor();
            return;
        }

        // If editor is closed, ignore all other keys
        if (!showEditor) return;

        // Check modifiers
        var isShift = (modifier & KeyModifier.SHIFT) != 0;
        var isCtrl = (modifier & KeyModifier.CTRL) != 0;

        switch(key) {
            case KeyCode.UP:
                adjustSelectedValue(1);
            case KeyCode.DOWN:
                adjustSelectedValue(-1);
            case KeyCode.LEFT:
                if (isShift) {
                    selectPreviousIndex();
                } else if (isCtrl) {
                    adjustSelectedValue(-10);
                } else {
                    toggleProperty();
                }
            case KeyCode.RIGHT:
                if (isShift) {
                    selectNextIndex();
                } else if (isCtrl) {
                    adjustSelectedValue(10);
                } else {
                    toggleProperty();
                }
            case KeyCode.TAB:
                if (isCtrl) {
                    toggleEditMode();
                } else {
                    toggleState(isShift ? -1 : 1);
                }
            case KeyCode.SPACE:
                toggleProperty();
            default:
                // Do nothing
        }
    }

    public function toggleEditor() {
        showEditor = !showEditor;
        if (showEditor) {
            // Ensure texture is loaded
            if (texture == null) {
                texture = getCombinedNoteskinTexture();
                if (noteProg != null) {
                    noteProg.setTexture(texture, NOTESKIN_TEXTURE_NAME, true);
                }
            }
            
            // Add grid program first (behind)
            if (gridProg != null && !gridProg.isIn(roof)) {
                roof.addProgram(gridProg);
            }
            
            // Then add note program (on top)
            if (noteProg != null && !noteProg.isIn(roof)) {
                roof.addProgram(noteProg);
            }
            
            // Update all receptor visuals
            updateReceptorVisuals();
            
            // Show instructions
            if (instructionsText != null) {
                instructionsText.alpha = 1;
                updateInstructionsText();
            }
            
            trace('Noteskin Editor opened');
            trace('Controls: TAB=cycle state, CTRL+TAB=toggle edit mode, UP/DOWN=adjust value');
            trace('LEFT/RIGHT=switch X/Y (or W/H), CTRL+LEFT/RIGHT=±10, SHIFT+LEFT/RIGHT=change receptor');
            trace('SPACE=cycle property, ESC=close');
        } else {
            // Remove note program first, then grid
            if (noteProg != null && noteProg.isIn(roof)) {
                roof.removeProgram(noteProg);
            }
            if (gridProg != null && gridProg.isIn(roof)) {
                roof.removeProgram(gridProg);
            }
            
            // Hide instructions
            if (instructionsText != null) {
                instructionsText.alpha = 0;
            }
            
            trace('Noteskin Editor closed');
        }
    }

    public function dispose() {
        removeEvents();

        if (showEditor) toggleEditor();

        if (noteProg != null) {
            if (noteProg.isIn(display)) {
                display.removeProgram(noteProg);
            }
        }

        if (gridProg != null) {
            if (gridProg.isIn(display)) {
                display.removeProgram(gridProg);
            }
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

        // Remove instructions text
        if (instructionsText != null) {
            instructionsText.removeProgram();
            instructionsText = null;
        }

        display = null;
        view = null;
        roof = null;
    }

    // Public methods for external control

    public function show() {
        if (!showEditor) toggleEditor();
    }

    public function hide() {
        if (showEditor) toggleEditor();
    }

    public function update() {
        if (showEditor) {
            // Update receptor animations if needed
        }
    }
}
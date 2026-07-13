package structures.editors.noteskin;

import lime.graphics.Image;
import lime.math.Vector2;
import lime.math.Rectangle;
import sys.FileSystem;
import structures.gameplay.NoteskinHandle.NoteskinReceptorProperties;
import structures.gameplay.NoteskinHandle.BasicNoteskinClip;

@:publicFields
class NoteskinEditorRenderer {
    var state:NoteskinEditorState;

    public function new(state:NoteskinEditorState) {
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
                // In spritesheet mode, the grid should follow the spritesheet view with scale applied
                gridSprite.x += Math.round(NoteskinEditorState.SPRITESHEET_VIEW_OFFSET * scale);
                gridSprite.y += Math.round(NoteskinEditorState.SPRITESHEET_VIEW_OFFSET * scale);
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
            Note.init(state.noteProg, NoteskinEditorState.NOTESKIN_TEXTURE_NAME, state.texture);
        }

        state.view.addProgram(state.noteProg);
    }

    function getCombinedNoteskinTexture():Texture {
        var existingTex = TextureSystem.getTexture(NoteskinEditorState.NOTESKIN_TEXTURE_NAME);
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

            TextureSystem.pool[NoteskinEditorState.NOTESKIN_TEXTURE_NAME] = texture;

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
        for (sprite in state.receptorSprites) {
            state.noteBuf.removeElement(sprite);
        }
        state.receptorSprites = [];

        var gap = state.currentConfig.gap != 0 ? state.currentConfig.gap : 112;
        var offsetX = state.currentConfig.offsetX;
        var offsetY = state.currentConfig.offsetY;
        var startX = (Main.INITIAL_WIDTH - (state.maxReceptors * gap)) / 2 + offsetX;
        var y = Main.INITIAL_HEIGHT / 2 + offsetY;
        var scale = state.currentConfig.scale;

        for (i in 0...state.maxReceptors) {
            var note = new Note(
                Std.int(startX + (i * gap)),
                Std.int(y),
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
        state.ui.updateInstructionsText();
        var modeName = state.globalScaleMode ? "Scale" : "Offset";
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
        var startX = (Main.INITIAL_WIDTH - (state.maxReceptors * gap)) / 2 + offsetX;
        var y = Main.INITIAL_HEIGHT / 2 + offsetY;
        var scale = state.currentConfig.scale;

        var isPreview = state.currentManiaIndex >= state.availableManiaConfigs.length;

        for (i in 0...state.receptorSprites.length) {
            var note = state.receptorSprites[i];

            var clipIndex = state.clipEditor.getClipIndexForReceptor(i);
            var clip = state.clipEditor.getClipForIndex(clipIndex);

            note.x = Std.int(startX + (i * gap));
            note.y = Std.int(y);
            note.scale = scale;

            if (state.spriteSheetMode && i == state.spritesheetSelectedIndex) {
                var basicClip = state.clipEditor.getBasicClipForState(clip, state.currentState);

                note.c = 0xFF00FFFF;
                note.initialAlpha = 0.5;

                // The clipX/Y should be the actual clip position minus the offset to show the full texture
                // The width/height should be the full texture size
                note.clipX = basicClip.clipX - NoteskinEditorState.SPRITESHEET_VIEW_OFFSET;
                note.clipY = basicClip.clipY - NoteskinEditorState.SPRITESHEET_VIEW_OFFSET;
                note.clipWidth = state.texture.width + NoteskinEditorState.SPRITESHEET_VIEW_OFFSET;
                note.clipHeight = state.texture.height + NoteskinEditorState.SPRITESHEET_VIEW_OFFSET;
                note.clipSizeX = state.texture.width + NoteskinEditorState.SPRITESHEET_VIEW_OFFSET;
                note.clipSizeY = state.texture.height + NoteskinEditorState.SPRITESHEET_VIEW_OFFSET;
                // note.w and note.h are automatically scaled, so we just set the base size
                note.w = state.texture.width + NoteskinEditorState.SPRITESHEET_VIEW_OFFSET;
                note.h = state.texture.height + NoteskinEditorState.SPRITESHEET_VIEW_OFFSET;
                note.ox = basicClip.offsX;
                note.oy = basicClip.offsY;
                // Position offset for the spritesheet view - scaled to match the visual size
                note.x -= Math.round(NoteskinEditorState.SPRITESHEET_VIEW_OFFSET * scale);
                note.y -= Math.round(NoteskinEditorState.SPRITESHEET_VIEW_OFFSET * scale);
            } else {
                if (i == state.selectedIndex) {
                    note.c = 0x00FF00FF;
                } else {
                    note.c = 0xFFFFFFFF;
                }
                if (!isPreview) {
                    note.initialAlpha = 1.0;
                }
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

package structures.editors.noteskin;

import haxe.Json;
import sys.io.File as Sys_Fili;
import sys.FileSystem;
import structures.gameplay.NoteskinHandle;
import structures.gameplay.NoteskinHandle.NoteskinData;
import structures.gameplay.NoteskinHandle.NoteskinConfig;
import structures.gameplay.NoteskinHandle.NoteskinReceptorProperties;

@:publicFields
class NoteskinEditorManiaManager {
    var state:NoteskinEditorState;

    public function new(state:NoteskinEditorState) {
        this.state = state;
    }

    function loadNoteskin(skinName:String) {
        state.currentSkinName = skinName;
        var skinFolder = 'assets/images/noteskins/$skinName';

        try {
            // Check if data.json exists, create default if not
            var dataPath = Paths.asset('$skinFolder/data.json');
            if (!FileSystem.exists(dataPath)) {
                createDefaultDataJson(skinFolder);
            }

            state.noteskinHandle = new NoteskinHandle(skinName);
            state.noteskinData = state.noteskinHandle.data;

            // Store all mania configs
            state.availableManiaConfigs = state.noteskinData.configMania != null ? state.noteskinData.configMania.copy() : [];

            // If no configs exist, create a default one
            if (state.availableManiaConfigs.length == 0) {
                state.availableManiaConfigs.push({
                    offsetX: 0,
                    offsetY: 0,
                    gap: 112,
                    scale: 1.0,
                    indexes: [0, 1, 2, 3]
                });
            }

            // Set current config to first one
            state.currentManiaIndex = 0;
            state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];

            // Update maxReceptors based on current config
            updateMaxReceptorsFromConfig();

            // Get clips from the top-level clip array
            var clips = state.noteskinData.clip;

            // Ensure we have clips for all receptors
            var numReceptors = clips != null ? clips.length : 0;
            if (numReceptors < state.maxReceptors) {
                // Pad with defaults if needed - using actual texture coords from XML
                var defaultClip:NoteskinReceptorProperties = {
                    idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                    press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
                    color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                    confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                    holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                    holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
                };

                while (clips.length < state.maxReceptors) {
                    clips.push(defaultClip);
                }
            }

            // Ensure selectedIndex is within bounds
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
        if (state.currentConfig.indexes != null) {
            state.maxReceptors = state.currentConfig.indexes.length;
            // Ensure we have at least 1 receptor
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
        var clipCount = state.noteskinData.clip != null ? state.noteskinData.clip.length : 0;
        var indexes:Array<Int> = [];
        for (i in 0...clipCount) {
            indexes.push(i);
        }
        return {
            offsetX: 0,
            offsetY: 0,
            gap: 114,
            scale: 1.0,
            indexes: indexes
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
            // Normal mania
            state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];
        } else {
            // Preview mania - generate from all clips
            state.currentConfig = generateManiaFromClips();
        }

        // Update maxReceptors
        updateMaxReceptorsFromConfig();

        // Ensure clips exist for all receptors
        var clips = state.noteskinData.clip;
        var defaultClip:NoteskinReceptorProperties = {
            idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
            color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
            confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
            holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
            holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
        };

        while (clips.length < state.maxReceptors) {
            clips.push(defaultClip);
        }

        // Ensure selectedIndex is within bounds
        if (state.selectedIndex >= state.maxReceptors) {
            state.selectedIndex = state.maxReceptors - 1;
        }

        // Ensure spritesheet selected index is valid
        if (state.spritesheetSelectedIndex >= state.maxReceptors) {
            state.spritesheetSelectedIndex = state.maxReceptors - 1;
        }

        // Recreate receptors with new config
        state.renderer.createReceptors();
        state.renderer.updateReceptorVisuals();
        state.ui.updateInstructionsText();

        var modeName = state.currentManiaIndex >= state.availableManiaConfigs.length ? "Preview All Clips" : '${state.maxReceptors}K';
        trace('Switched to mania ${state.currentManiaIndex + 1}/${totalManias} - $modeName');
    }

    function createNewMania() {
        // Show the popup
        state.createManiaPopupActive = true;
        state.createManiaInput = "";
        state.createManiaError = "";
        state.createManiaKeyCount = 0;

        // Remove any existing popup background just in case
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
                offsetX: 0,
                offsetY: 0,
                gap: 112,
                scale: 1.0,
                indexes: [0, 1, 2, 3]
            }],
            clip: []
        };
        state.availableManiaConfigs = state.noteskinData.configMania.copy();
        state.currentManiaIndex = 0;
        state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];
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

        for (i in 0...state.maxReceptors) {
            state.noteskinData.clip.push(defaultClip);
        }
    }

    function confirmCreateMania() {
        // Parse the input
        var keyCount = Std.parseInt(state.createManiaInput);
        if (keyCount == null || keyCount <= 0) {
            state.createManiaError = "Please enter a valid positive number";
            return;
        }

        // Check if this mania already exists
        for (config in state.availableManiaConfigs) {
            if (config.indexes != null && config.indexes.length == keyCount) {
                state.createManiaError = 'Mania with $keyCount keys already exists!';
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
        state.availableManiaConfigs.push(newMania);

        // Fill in missing manias from 1 to keyCount
        fillMissingManias(keyCount);

        // Sort manias by key count
        sortManiasByKeyCount();

        // Find the index of the new mania after sorting
        var newIndex = state.availableManiaConfigs.indexOf(newMania);
        if (newIndex != -1) {
            state.currentManiaIndex = newIndex;
            state.currentConfig = state.availableManiaConfigs[state.currentManiaIndex];
            updateMaxReceptorsFromConfig();

            // Ensure clips exist
            var clips = state.noteskinData.clip;
            var defaultClip:NoteskinReceptorProperties = {
                idle: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                press: {clipX: 115, clipY: 229, clipW: 99, clipH: 100, offsX: 0, offsY: 0},
                color: {clipX: 3, clipY: 116, clipW: 109, clipH: 111, offsX: 0, offsY: 0},
                confirm: {clipX: 3, clipY: 3, clipW: 240, clipH: 243, offsX: 0, offsY: 0},
                holdBody: {clipX: 441, clipY: 229, clipW: 35, clipH: 30, offsX: 0, offsY: 0},
                holdTail: {clipX: 460, clipY: 3, clipW: 35, clipH: 45, offsX: 0, offsY: 0}
            };
            while (clips.length < state.maxReceptors) {
                clips.push(defaultClip);
            }

            state.renderer.createReceptors();
            state.renderer.updateReceptorVisuals();
            state.ui.updateInstructionsText();
            trace('Created new mania with $keyCount keys');
        }

        // Close the popup immediately and remove background
        state.createManiaPopupActive = false;
        state.createManiaInput = "";
        state.createManiaError = "";

        if (state.popupBackground != null) {
            state.gridBuf.removeElement(state.popupBackground);
            state.popupBackground = null;
            state.gridBuf.update();
        }

        // Restore instructions text
        state.ui.updateInstructionsText();
    }

    function fillMissingManias(maxKeys:Int) {
        // Check which key counts already exist
        var existingKeyCounts:Array<Int> = [];
        for (config in state.availableManiaConfigs) {
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

            state.availableManiaConfigs.push(newMania);
            trace('Auto-created mania with $i keys');
        }
    }

    function cancelCreateMania() {
        state.createManiaPopupActive = false;
        state.createManiaInput = "";
        state.createManiaError = "";

        // Remove popup background
        if (state.popupBackground != null) {
            state.gridBuf.removeElement(state.popupBackground);
            state.popupBackground = null;
            state.gridBuf.update();
        }

        trace('Create Mania cancelled');
    }

    function sortManiasByKeyCount() {
        // Remove any duplicate manias (same key count)
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

        // Sort manias by their index length (key count)
        state.availableManiaConfigs.sort(function(a:NoteskinConfig, b:NoteskinConfig) {
            var lenA = a.indexes != null ? a.indexes.length : 0;
            var lenB = b.indexes != null ? b.indexes.length : 0;
            return lenA - lenB;
        });
    }

    function adjustGap(amount:Int) {
        if (state.currentConfig == null) return;
        state.currentConfig.gap += amount;
        if (state.currentConfig.gap < 1) state.currentConfig.gap = 1;
        if (state.currentConfig.gap > 500) state.currentConfig.gap = 500;

        // Update all receptors with new gap
        state.renderer.createReceptors();
        state.renderer.updateReceptorVisuals();
        state.ui.updateInstructionsText();
        trace('Gap adjusted to: ${state.currentConfig.gap}');
    }
}

package structures.editors.noteskin;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseCursor;
import lime.ui.MouseWheelMode;
import lime.ui.MouseButton;
import lime.app.Application;
import structures.gameplay.NoteskinHandle.BasicNoteskinClip;

@:publicFields
class NoteskinEditorInputHandler {
    var state:NoteskinEditorState;

    public function new(state:NoteskinEditorState) {
        this.state = state;
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

    // === Key Handling ===

    public function handleKeyDown(key:KeyCode, modifier:KeyModifier) {
        // Track modifier states
        state.isCtrlPressed = (modifier & KeyModifier.CTRL) != 0;
        state.isShiftPressed = (modifier & KeyModifier.SHIFT) != 0;
        state.isAltPressed = (modifier & KeyModifier.ALT) != 0;

        if (state.createManiaPopupActive) {
            handleCreateManiaPopupInput(key);
            return;
        }

        if (key == KeyCode.ESCAPE) {
            if (state.spriteSheetMode) {
                state.clipEditor.toggleSpritesheetMode();
                return;
            }
            state.toggleEditor();
            return;
        }

        if (!state.showEditor) return;

        // CTRL+SPACE toggles global transform mode (X/Y vs Scale)
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
                        // Scale mode - UP increases scale
                        state.currentConfig.scale += 0.05;
                        state.renderer.updateGlobalTransform();
                    } else {
                        // Offset mode - UP decreases Y
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
                        // Scale mode - DOWN decreases scale
                        state.currentConfig.scale -= 0.05;
                        if (state.currentConfig.scale < 0.1) state.currentConfig.scale = 0.1;
                        state.renderer.updateGlobalTransform();
                    } else {
                        // Offset mode - DOWN increases Y
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
                        // Scale mode - LEFT decreases scale
                        state.currentConfig.scale -= 0.05;
                        if (state.currentConfig.scale < 0.1) state.currentConfig.scale = 0.1;
                        state.renderer.updateGlobalTransform();
                    } else {
                        // Offset mode - LEFT decreases X
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
                        // Scale mode - RIGHT increases scale
                        state.currentConfig.scale += 0.05;
                        state.renderer.updateGlobalTransform();
                    } else {
                        // Offset mode - RIGHT increases X
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

    function handleCreateManiaPopupInput(key:KeyCode) {
        switch(key) {
            case KeyCode.ESCAPE:
                // ESC cancels the popup without closing the editor
                state.maniaManager.cancelCreateMania();
                // Restore instructions text after cancel
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

        // Handle number input (supports both regular and numpad keys)
        var num = key - 0x30; // '0' key
        var num2 = key - 0x40000059; // Numpad keys
        if (((num >= 0 && num < 10) || (num2 >= 0 && num2 < 10)) && state.createManiaInput.length < 2) {
            // Use the actual number from the key
            var digit = num >= 0 && num < 10 ? num : num2;
            state.createManiaInput += Std.string(digit);
            state.createManiaError = "";
        }
    }

    // === Mouse Handling ===

    function handleMouseDown(mouseX:Float, mouseY:Float, button:MouseButton) {
        if (!state.showEditor || button != MouseButton.LEFT) return;
        if (Application.current.window == null) return;

        var note = state.clipEditor.getSelectedNote();
        if (note == null) return;

        var sx = note.x;
        var sy = note.y;
        var sw = note.w;
        var sh = note.h;

        var inSprite = mouseX >= sx && mouseX <= sx + sw && mouseY >= sy && mouseY <= sy + sh;

        if (inSprite) {
            // Start holding for long press detection in BOTH modes
            state.isHoldingMouse = true;
            state.isLongPress = false;
            state.longPressTriggered = false;
            state.mouseDownX = mouseX;
            state.mouseDownY = mouseY;
            state.longPressTimer = 0;

            // If in spritesheet mode, we'll start dragging after a short delay
            // if the user doesn't long press first
            if (state.spriteSheetMode) {
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
        state.isHoldingMouse = false;
        state.isLongPress = false;
        state.longPressTriggered = false;

        // Spritesheet mode dragging - pan the view by modifying clipX/Y
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

        var margin = 6;
        var nearRight = Math.abs(mouseX - (sx + sw)) <= margin;
        var nearBottom = Math.abs(mouseY - (sy + sh)) <= margin;
        var nearLeft = Math.abs(mouseX - sx) <= margin;
        var nearTop = Math.abs(mouseY - sy) <= margin;

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

        // Determine drag mode based on edit mode and position
        switch(state.editMode) {
            case CLIP_POS:
                if (nearRight || nearLeft || nearBottom || nearTop) {
                    state.dragMode = 0;
                }
                setCursor(MouseCursor.MOVE);
            case CLIP_SIZE:
                if (nearRight && nearBottom) {
                    state.dragMode = 3;
                    setCursor(MouseCursor.RESIZE_NWSE);
                } else if (nearRight) {
                    state.dragMode = 1;
                    setCursor(MouseCursor.RESIZE_WE);
                } else if (nearBottom) {
                    state.dragMode = 2;
                    setCursor(MouseCursor.RESIZE_NS);
                } else {
                    state.dragMode = 3;
                    setCursor(MouseCursor.RESIZE_NWSE);
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
                    // Scale sub-mode — mouse drag doesn't apply (1D value on a
                    // 2D drag is ambiguous). Use arrow keys instead.
                    state.dragMode = -1;
                    setCursor(MouseCursor.ARROW);
                } else {
                    // Offset sub-mode — drag anywhere moves the whole strumline.
                    // Reuse dragStartOffsX/Y to capture the global offset at
                    // drag start (semantically identical: "offset at drag start").
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

        // Cancel long press
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

        // Check if mouse moved too far from start position (cancel long press or start drag)
        if (state.isHoldingMouse && !state.longPressTriggered) {
            var dx = Math.abs(mouseX - state.mouseDownX);
            var dy = Math.abs(mouseY - state.mouseDownY);
            if (dx > 10 || dy > 10) {
                state.isHoldingMouse = false;
                startDrag(mouseX, mouseY);
                return;
            }
        }

        if (state.isDragging) {
            var dx = mouseX - state.dragStartX;
            var dy = mouseY - state.dragStartY;

            // Spritesheet mode dragging - pan the view by modifying clipX/Y
            if (state.spriteSheetMode) {
                var clip = state.clipEditor.getSelectedClip();
                var newX = Std.int(state.dragStartClipX - dx);
                var newY = Std.int(state.dragStartClipY - dy);
                clip.clipX = newX;
                clip.clipY = newY;
                state.selectedProperty = "clipX";

                var clipIndex = state.clipEditor.getClipIndexForReceptor(state.selectedIndex);
                state.clipEditor.updateClipInConfig(clipIndex, state.currentState, clip);
                state.renderer.updateReceptorVisuals();
                state.ui.updateInstructionsText();
                setCursor(MouseCursor.MOVE);
                return;
            }

            // Normal dragging for other edit modes
            var clip = state.clipEditor.getSelectedClip();

            switch(state.editMode) {
                case CLIP_POS:
                    var newX = Std.int(state.dragStartClipX - dx);
                    var newY = Std.int(state.dragStartClipY - dy);
                    clip.clipX = newX;
                    clip.clipY = newY;
                    state.selectedProperty = "clipX";

                case CLIP_SIZE:
                    switch(state.dragMode) {
                        case 1:
                            var newW = Std.int(Math.max(1, state.dragStartClipW + dx));
                            clip.clipW = newW;
                            state.selectedProperty = "clipW";
                        case 2:
                            var newH = Std.int(Math.max(1, state.dragStartClipH + dy));
                            clip.clipH = newH;
                            state.selectedProperty = "clipH";
                        case 3:
                            var newW = Std.int(Math.max(1, state.dragStartClipW + dx));
                            var newH = Std.int(Math.max(1, state.dragStartClipH + dy));
                            clip.clipW = newW;
                            clip.clipH = newH;
                            state.selectedProperty = "clipW";
                        default:
                    }

                case OFFSET:
                    switch(state.dragMode) {
                        case 4:
                            var newX = Std.int(state.dragStartOffsX + dx);
                            clip.offsX = newX;
                            state.selectedProperty = "offsX";
                        case 5:
                            var newY = Std.int(state.dragStartOffsY + dy);
                            clip.offsY = newY;
                            state.selectedProperty = "offsY";
                        case 6:
                            var newX = Std.int(state.dragStartOffsX + dx);
                            var newY = Std.int(state.dragStartOffsY + dy);
                            clip.offsX = newX;
                            clip.offsY = newY;
                            state.selectedProperty = "offsX";
                        default:
                    }

                case GLOBAL_TRANSFORM:
                    // Global offset drag — move the whole strumline by the
                    // mouse delta. Only applies in offset sub-mode; scale
                    // sub-mode is handled by arrow keys.
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

            // Update cursor based on drag mode
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
            // Hover state - update cursor
            if (!state.spriteSheetMode) {
                // Global offset drag works anywhere on screen, so show MOVE
                // cursor everywhere (not just on a sprite) when in offset
                // sub-mode. Scale sub-mode has no drag — show ARROW.
                if (state.editMode == GLOBAL_TRANSFORM) {
                    setCursor(state.globalScaleMode ? MouseCursor.ARROW : MouseCursor.MOVE);
                    return;
                }

                var clip = state.clipEditor.getSelectedClip();
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

                if (inSprite && state.editMode != CLIP_ID) {
                    switch(state.editMode) {
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
        if (!state.showEditor) return;

        // ALT+MouseWheel: Adjust gap
        if (state.isAltPressed) {
            var amount = deltaY > 0 ? (state.isCtrlPressed ? 10 : 1) : (state.isCtrlPressed ? -10 : -1);
            state.maniaManager.adjustGap(amount);
            return;
        }

        if (state.isShiftPressed && state.globalScaleMode) {
            // Scale mode - DOWN decreases scale
            state.currentConfig.scale += deltaY < 0 ? -0.05 : 0.05;
            if (state.currentConfig.scale < 0.1) state.currentConfig.scale = 0.1;
            state.renderer.updateGlobalTransform();
        }

        if (deltaY > 0) {
            if (state.spriteSheetMode) {
                state.clipEditor.selectNextIndex();
            } else {
                state.clipEditor.toggleState(1);
            }
        } else if (deltaY < 0) {
            if (state.spriteSheetMode) {
                state.clipEditor.selectPreviousIndex();
            } else {
                state.clipEditor.toggleState(-1);
            }
        }
    }
}

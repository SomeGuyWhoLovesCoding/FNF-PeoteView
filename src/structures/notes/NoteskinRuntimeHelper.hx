package structures.notes;

import structures.notes.NoteskinHandle.NoteskinData;
import structures.notes.NoteskinHandle.NoteskinConfig;
import structures.notes.NoteskinHandle.BasicNoteskinClip;
import structures.notes.NoteskinHandle.NoteskinReceptorProperties;

class NoteskinRuntimeHelper {
    inline static public function getIdleClip(handle:NoteskinHandle, lane:Int, mania:Int):BasicNoteskinClip {
        return getClipForState(handle, lane, IDLE, mania);
    }

    inline static public function getColorClip(handle:NoteskinHandle, lane:Int, mania:Int):BasicNoteskinClip {
        return getClipForState(handle, lane, COLOR, mania);
    }

    inline static public function getPressClip(handle:NoteskinHandle, lane:Int, mania:Int):BasicNoteskinClip {
        return getClipForState(handle, lane, PRESS, mania);
    }

    inline static public function getConfirmClip(handle:NoteskinHandle, lane:Int, mania:Int):BasicNoteskinClip {
        return getClipForState(handle, lane, CONFIRM, mania);
    }

    inline static public function getHoldBodyClip(handle:NoteskinHandle, lane:Int, mania:Int):BasicNoteskinClip {
        var data = handle.data;
        var cfg = getConfigForLane(handle, lane, mania);
        
        var idxArr:Array<Int> = cfg.holdBodyIndexes;
        if (idxArr == null || lane >= idxArr.length) return defaultClip().holdBody;
        var clipIdx = idxArr[lane];
        if (clipIdx >= data.clip.length) return defaultClip().holdBody;
        return data.clip[clipIdx].holdBody;
    }

    inline static public function getHoldTailClip(handle:NoteskinHandle, lane:Int, mania:Int):BasicNoteskinClip {
        var data = handle.data;
        var cfg = getConfigForLane(handle, lane, mania);

        var idxArr:Array<Int> = cfg.holdTailIndexes;
        if (idxArr == null || lane >= idxArr.length) return defaultClip().holdTail;
        var clipIdx = idxArr[lane];
        if (clipIdx >= data.clip.length) return defaultClip().holdTail;
        return data.clip[clipIdx].holdTail;
    }

    // Change getConfigForLane to use the passed mania
    inline static private function getConfigForLane(handle:NoteskinHandle, lane:Int, mania:Int):NoteskinConfig {
        var idx = mania - 1;  // ← use the passed mania, NOT handle.mania
        var configs = handle.data.configMania;
        if (configs != null && idx >= 0 && idx < configs.length) {
            return configs[idx];
        }
        // Last resort
        if (configs != null && configs.length > 0) return configs[0];
        return null;
    }

    // And the private helper
    inline static private function getClipForState(handle:NoteskinHandle, lane:Int, state:NoteState, mania:Int):BasicNoteskinClip {
        var data = handle.data;
        var cfg = getConfigForLane(handle, lane, mania);
        if (data == null || cfg == null) return defaultClipForState(state);

        var idxArr:Array<Int> = switch (state) {
            case IDLE:   cfg.idleIndexes;
            case COLOR:  cfg.colorIndexes;
            case PRESS:  cfg.pressIndexes;
            case CONFIRM:cfg.confirmIndexes;
            default:     cfg.idleIndexes;
        }
        if (idxArr == null || lane >= idxArr.length) return defaultClipForState(state);
        var clipIdx = idxArr[lane];
        if (clipIdx >= data.clip.length) return defaultClipForState(state);

        var clip = data.clip[clipIdx];
        return switch (state) {
            case IDLE:   clip.idle;
            case COLOR:  clip.color;
            case PRESS:  clip.press;
            case CONFIRM:clip.confirm;
            default:     clip.idle;
        }
    }

    inline static private function defaultClipForState(state:NoteState):BasicNoteskinClip {
        var def = defaultClip();
        return switch (state) {
            case IDLE:   def.idle;
            case COLOR:  def.color;
            case PRESS:  def.press;
            case CONFIRM:def.confirm;
            default:     def.idle;
        }
    }

    inline static private function defaultClip():NoteskinReceptorProperties {
        return {
            idle:     {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0, rotation: 0},
            press:    {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0, rotation: 0},
            color:    {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0, rotation: 0},
            confirm:  {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0, rotation: 0},
            holdBody: {clipX: 0, clipY: 0, clipW: 35,  clipH: 31,  offsX: 0, offsY: 0, rotation: 0},
            holdTail: {clipX: 0, clipY: 0, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0, rotation: 0}
        };
    }
}
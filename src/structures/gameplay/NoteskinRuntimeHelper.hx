package structures.gameplay;

import structures.gameplay.NoteskinHandle.NoteskinData;
import structures.gameplay.NoteskinHandle.NoteskinConfig;
import structures.gameplay.NoteskinHandle.BasicNoteskinClip;
import structures.gameplay.NoteskinHandle.NoteskinReceptorProperties;

class NoteskinRuntimeHelper {
    inline static public function getIdleClip(handle:NoteskinHandle, lane:Int):BasicNoteskinClip {
        return getClipForState(handle, lane, IDLE);
    }

    inline static public function getColorClip(handle:NoteskinHandle, lane:Int):BasicNoteskinClip {
        return getClipForState(handle, lane, COLOR);
    }

    inline static public function getPressClip(handle:NoteskinHandle, lane:Int):BasicNoteskinClip {
        return getClipForState(handle, lane, PRESS);
    }

    inline static public function getConfirmClip(handle:NoteskinHandle, lane:Int):BasicNoteskinClip {
        return getClipForState(handle, lane, CONFIRM);
    }

    static public function getHoldBodyClip(handle:NoteskinHandle, lane:Int):BasicNoteskinClip {
        var data = handle.data;
        var cfg = getConfigForLane(handle, lane);
        var idxArr = cfg.holdBodyIndexes;
        if (idxArr == null || lane >= idxArr.length) return defaultClip().holdBody;
        var clipIdx = idxArr[lane];
        if (clipIdx >= data.clip.length) return defaultClip().holdBody;
        return data.clip[clipIdx].holdBody;
    }

    static public function getHoldTailClip(handle:NoteskinHandle, lane:Int):BasicNoteskinClip {
        var data = handle.data;
        var cfg = getConfigForLane(handle, lane);
        var idxArr = cfg.holdTailIndexes;
        if (idxArr == null || lane >= idxArr.length) return defaultClip().holdTail;
        var clipIdx = idxArr[lane];
        if (clipIdx >= data.clip.length) return defaultClip().holdTail;
        return data.clip[clipIdx].holdTail;
    }

    // --- Internal helpers ---

    static private function getConfigForLane(handle:NoteskinHandle, lane:Int):NoteskinConfig {
        // Pick the config that matches the current mania key count.
        // configMania is 0-indexed: configMania[0] = 1-key, configMania[1] = 2-key, etc.
        // handle.mania is set by Strumline when the handle is assigned.
        var idx = handle.mania - 1;
        var configs = handle.data.configMania;
        if (configs != null && idx >= 0 && idx < configs.length) {
            return configs[idx];
        }
        // Fallback: try to find a config whose idleIndexes length matches mania
        if (configs != null) {
            for (cfg in configs) {
                if (cfg.idleIndexes != null && cfg.idleIndexes.length == handle.mania) {
                    return cfg;
                }
            }
        }
        // Last resort
        if (configs != null && configs.length > 0) return configs[0];
        return null;
    }

    static private function getClipForState(handle:NoteskinHandle, lane:Int, state:NoteState):BasicNoteskinClip {
        var data = handle.data;
        var cfg = getConfigForLane(handle, lane);
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

    static private function defaultClipForState(state:NoteState):BasicNoteskinClip {
        var def = defaultClip();
        return switch (state) {
            case IDLE:   def.idle;
            case COLOR:  def.color;
            case PRESS:  def.press;
            case CONFIRM:def.confirm;
            default:     def.idle;
        }
    }

    static private function defaultClip():NoteskinReceptorProperties {
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
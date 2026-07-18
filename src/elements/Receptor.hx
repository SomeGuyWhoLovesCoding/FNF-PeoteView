package elements;

/**
 * Represents a single receptor/lane, consolidating all per-index state 
 * previously held in parallel arrays within Strumline.
 * @since 0.94
**/
@:publicFields
class Receptor {
    var note:Note;
    
    var noteToHit:MetaNote;
    var noteToHit_sprite:Note;
    var noteToHit_index:Int64;
    
    var sustainToHold:MetaNote;
    var sustainToHold_index:Int64;
    var sustainToHold_duration:Int;
    
    var botHitToCheck:Bool;
    var playerHitToCheck:Bool;
    var fakeOverlapStorage:Float;
    
    var confirmTimer:ReceptorTimer;
    var sustainActive:Bool;
    var sustainResolved:Bool;

    var sustainPivotX:Int = 0;
    var sustainPivotY:Int = 0;
    
    function new(note:Note) {
        this.note = note;
        resetState();
    }
    
    function resetState() {
        noteToHit = null;
        noteToHit_sprite = null;
        noteToHit_index = 0;
        
        sustainToHold = null;
        sustainToHold_index = 0;
        sustainToHold_duration = 0;
        
        botHitToCheck = false;
        playerHitToCheck = false;
        fakeOverlapStorage = 0;
        
        confirmTimer = new ReceptorTimer(Math.POSITIVE_INFINITY, Math.POSITIVE_INFINITY, Math.POSITIVE_INFINITY);
        sustainActive = false;
        sustainResolved = false;
    }

    inline function updateAnimation(songPosition:Float) {
        if (songPosition > confirmTimer.tailTime) {
            note.press();
            confirmTimer.tailTime = Math.POSITIVE_INFINITY;
        }

        if (songPosition > confirmTimer.endTime) {
            note.reset();
            confirmTimer.startTime = Math.POSITIVE_INFINITY;
            confirmTimer.endTime = Math.POSITIVE_INFINITY;
        }
    }
}
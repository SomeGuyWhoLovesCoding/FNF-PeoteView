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
    
    var botTimer:Float;
    var sustainActive:Bool;
    var sustainResolved:Bool;
    
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
        
        botTimer = 0;
        sustainActive = false;
        sustainResolved = false;
    }
}
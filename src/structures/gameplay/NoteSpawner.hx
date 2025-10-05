package structures.gameplay;

/**
    The internal note handler.
    This class is responsible for spawning and despawning notes based on the song's position.
    It handles the culling of notes that are too far away from the current position, and it draws the notes that are within the spawn distance.
    It also handles the resetting of notes when the song position changes significantly.
    @since Development
**/
@:publicFields
class NoteSpawner {
    var bottom:Int64;
    var top:Int64;

    var spawnDist:Int64 = MetaNote.floatToMetaNotePosition(1600);
    var despawnDist:Int64 = MetaNote.floatToMetaNotePosition(300);

    var parent(default, null):NoteSystem;

    /**
     * Creates the note spawner.
     * @param parent The note system to implement this note spawner on.
     */
    function new(parent:NoteSystem) {
        this.parent = parent;
        bottom = zero;
        top = zero;
    }

    /**
     * Updates the note spawner.
     * @param pos The song's position in the note position format.
     */
    function update(pos:Int64) {
        // Cull notes outside the visible range first
        cullBottom(pos);
        cullTop(pos);

        var scrollSpeed = parent.parent.scrollSpeed;
        var prevNote:Null<MetaNote> = null;
        var noteSpr:Null<Note> = null;

        var i = bottom;
		while (i < top) {
            var n = File.getNote(i); // always fetch fresh

            // Determine lane
            var lane = parent.noteTypeFunctionality.exists(n.type) ? 1 : (n.type % parent.strumlines.length);
            var strumline = parent.strumlines[lane];
            var rec = strumline.buffer[n.index];

            // Compute vertical diff for this note
            var diff = MetaNote.metaNotePositionToSongTime(n.position - pos) * scrollSpeed;
            if (parent.parent.downScroll) diff = -diff;

            var newY = rec.y + Math.floor(diff);

            // Handle fake-overlap simulation
            var OVERLAP_PIXEL_THRESHOLD = 0;
            var prevY = (prevNote != null) ? strumline.fakeOverlapStorage[prevNote.index] : -99999;

            var overlap = noteSpr != null
                && prevNote != null
                && Math.abs(Math.floor(newY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT))
                            - Math.floor(prevY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT))) <= OVERLAP_PIXEL_THRESHOLD
                && prevNote.type == n.type
                && noteSpr.r == 0
                && noteSpr.scale == rec.scale
                && prevNote.duration == n.duration
                && noteSpr.x == rec.x;

            // Write newY for next iteration
            strumline.fakeOverlapStorage[n.index] = newY;

            if (overlap) {
                // Merge into previous sprite
                noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + (n.missed ? Note.defaultMissAlpha : Note.defaultAlpha), 254);
                noteSpr.notesInOne++;
                prevNote = n;
                continue;
            }

            // Draw new note
            noteSpr = parent.drawNote(pos, n, diff, i);
            prevNote = n;

            // Immediately write back to file so flags persist
            File.setNote(i, n);

			i++;
        }
    }

    /**
     * Culls the top note cull.
     * @param pos The song's position in the note position format.
     */
    function cullTop(pos:Int64) {
        var len = File.getLength();

        while (top < len) {
            var n = File.getNote(top);
            if (n.position - pos >= spawnDist) break;

            // Reset flags for newly spawned note
            n.flag = false;
            n.missed = false;
            n.held = false;
            File.setNote(top, n);

            top++;
        }
    }

    /**
     * Culls the bottom note cull.
     * @param pos The song's position in the note position format.
     */
    function cullBottom(pos:Int64) {
        var len = File.getLength();

        while (bottom < len) {
            var n = File.getNote(bottom);
            var noteEnd = n.position + MetaNote.intToMetaNoteDuration(n.duration);
            if (pos - noteEnd <= despawnDist) break;

            // Reset flags and return note to pool
            n.flag = false;
            n.missed = false;
            n.held = false;
            File.setNote(bottom, n);

            parent.notePool.putNote(n, bottom);
            parent.notePool.putSustain(n);

            bottom++;
        }
    }

    /**
     * Reload the notes.
     * @param songPosition The time from the song.
     */
    function resetNotes(songPosition:Float) {
        var pf = parent.parent;
        if (pf.disposed || pf.died) return;

        var len = File.getLength();
        if (len == 0) return;

        // Reset all flags in one pass
        var i = 0;
		while (i < len) {
            var n = File.getNote(i);
            n.flag = false;
            n.missed = false;
            n.held = false;
            File.setNote(i, n);
			i++;
        }

        // Reset top/bottom pointers
        bottom = 0;
        top = len;

        // Reset strumlines
        parent.resetStrumlines();
    }

    private var zero(default, null):Int64 = 0;
}
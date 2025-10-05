package structures.gameplay;

typedef Receptor = Note;

/**
	The note system.
	This is the main class that handles the notes and sustains in the game.
	It is responsible for spawning, drawing, and updating the notes and sustains.
	It also handles the note hit registration and sustain inputs.
	This class is used in the PlayField class to handle the notes and sustains.
	@since Development
**/
@:publicFields
class NoteSystem {
    static var sustainProg(default, null):Program;
    static var sustainsBuf(default, null):Buffer<Sustain>;

    static var notesProg(default, null):Program;
    static var notesBuf(default, null):Buffer<Note>;

    static var STRUMLINE_X_OFFSET = 50;
    static var STRUMLINE_Y_OFFSET = 50;
    static var STRUMLINE_Y_OFFSET_DOWNSCROLL = 150;

    static function init() {
        if (notesBuf == null) notesBuf = new Buffer<Note>(128, 128, false);
        if (notesProg == null) {
            var tex = TextureSystem.getTexture("noteTex");
            notesProg = new Program(notesBuf);
            Note.init(notesProg, "noteTex", tex);
        }

        if (sustainsBuf == null) sustainsBuf = new Buffer<Sustain>(128, 128, false);
        if (sustainProg == null) {
            var tex2 = TextureSystem.getTexture("sustainTex");
            sustainProg = new Program(sustainsBuf);
            Sustain.init(sustainProg, "sustainTex", tex2);
        }
    }

    var noteSpawner(default, null):NoteSpawner;
    var notePool(default, null):NotePool;
    var strumlines(default, null):Array<Strumline>;

    var noteTypeFunctionality(default, null):Map<Int, Int->Int->Bool->Void>;
    var parent(default, null):PlayField;

    private var _lastPos(default, null):Int64; // for adaptive bot timer

    function new(parent:PlayField) {
        noteTypeFunctionality = new Map<Int, Int->Int->Bool->Void>();
        this.parent = parent;

        var display = parent.display;
        display.addProgram(sustainProg);
        display.addProgram(notesProg);

        var inputSystem = parent.inputSystem;
        notePool = new NotePool(this);
        noteSpawner = new NoteSpawner(this);

        var mania = Chart.header.mania;
        strumlines = [];

        for (i in 0...2) {
            var strumline = new Strumline(
                STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5)),
                parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET,
                Std.int(inputSystem.strumline[0]),
                inputSystem.strumline[1],
                mania,
                this
            );
            strumline.playable = inputSystem.strumlinePlayable[i];
            strumlines.push(strumline);
        }

        setScrollSpeed(Chart.header.speed);
        update(MetaNote.floatToMetaNotePosition(parent.songPosition));
    }

    function update(pos:Int64) {
        notesBuf.clear();
        sustainsBuf.clear();

        for (i in 0...strumlines.length) {
            var strumline = strumlines[i];
            var botTimers = strumline.botTimers;

            for (j in 0...botTimers.length) {
                if (botTimers[j] > 0) {
                    var decrement = pos - _lastPos;
                    botTimers[j] -= MetaNote.metaNotePositionToSongTime(decrement) * 0.001;

                    if (botTimers[j] <= 0 && strumline.botHitsToCheck[j]) {
                        strumline.buffer[j].reset();
                        botTimers[j] = 0;
                        strumline.botHitsToCheck[j] = false;
                    }
                }
            }

            strumline.draw(notesBuf);
        }

        if (noteSpawner != null) noteSpawner.update(pos);

        _lastPos = pos;
    }

    /**
     * Again, do not fuck with this.
     * I put lots of effort into this abomination of a function.
     * This function was ported from the old note system.
     * Note hitreg and sustain inputs are handled here.
     * @param pos The song's position in note position format.
     * @param note The meta note you want to draw the note to.
     * @param diff The time difference between the song time and note time.
     * @param id The index the note belongs to.
    **/
    function drawNote(pos:Int64, note:MetaNote, diff:Float, id:Int64):Note {
        var index = note.index;
        var lane = noteTypeFunctionality.exists(note.type) ? 1 : (note.type % strumlines.length);
        var strumline = strumlines[lane];
        var rec = strumline.buffer[index];
        var noteSpr = notePool.newNote(parent.inputSystem.receptorIds[index], note, id);
        var sustainExists = note.duration != 0;
        var sustainSpr = sustainExists ? notePool.newSustain(parent.inputSystem.receptorIds[index], note) : null;

        var leftover = Std.int(MetaNote.metaNotePositionToSongTime(pos - note.position));
        if (parent.downScroll) diff = -diff;

        noteSpr.x = rec.x;
        noteSpr.y = rec.y + Std.int(diff);
        noteSpr.scale = rec.scale;

        var playable = strumline.playable && !(parent.botplay || RenderingMode.enabled);

        // --- Player side ---
        if (playable) {
            handlePlayerNoteHit(note, noteSpr, strumline, sustainSpr, pos, diff, sustainExists);
        }
        // --- Opponent side ---
        else if (!note.flag && diff < 0) {
            handleOpponentNoteHit(note, noteSpr, strumline, sustainSpr, leftover, sustainExists, rec);
        }

        // --- Sustain handling ---
        if (sustainExists) handleSustain(note, sustainSpr, pos, leftover, strumline, rec, playable);

        if (!note.flag && @:privateAccess noteSpr.bytePos == -1) notesBuf.addElement(noteSpr);

        // Ensure all flag updates are persisted
        File.setNote(id, note);

        return noteSpr;
    }

    private inline function handlePlayerNoteHit(note:MetaNote, noteSpr:Note, strumline:Strumline, sustainSpr:Sustain, pos:Int64, diff:Float, sustainExists:Bool) {
        if (!note.flag) {
            var noteToHit = strumline.notesToHit[note.index];
            var noteToHitExists = noteToHit != null;
            var hitPos = noteToHitExists ? noteToHit.position : 0;

            if ((!note.missed && diff < parent.hitbox && !noteToHitExists) ||
                (noteToHitExists && pos - hitPos > (note.position - hitPos) >> 1)) {
                strumline.notesToHit[note.index] = note;
            }

            if (diff < -parent.hitbox && !note.missed) {
                note.missed = true;
                File.setNote(note.index, note);
                noteSpr.initialAlpha = Note.defaultMissAlpha;

                if (noteTypeFunctionality.exists(note.type)) noteTypeFunctionality[note.type](note.index, note.type, true);
                parent.onNoteMiss.dispatch(note, noteSpr.notesInOne);

                if (sustainExists && !note.held) {
                    sustainSpr.c.aF = Sustain.defaultMissAlpha;
                    sustainSpr.c.luminanceF = Sustain.defaultMissAlpha;
                    note.held = true;
                    File.setNote(note.index, note);
                    parent.onSustainRelease.dispatch(note);
                }

                strumline.notesToHit[note.index] = null;
                var hud = parent.hud;
                if (SaveData.state.preferences.ratingPopup && hud != null) hud.hideRatingPopup();
            }
        }
    }

    private inline function handleOpponentNoteHit(note:MetaNote, noteSpr:Note, strumline:Strumline, sustainSpr:Sustain, leftover:Int, sustainExists:Bool, rec:Receptor) {
        note.flag = true;
        File.setNote(note.index, note);

        if (!rec.confirmed()) rec.confirm();
        strumline.botTimers[note.index] = 0.045;
        strumline.botHitsToCheck[note.index] = note.duration == 0;

        if (sustainExists) {
            sustainSpr.followNote(rec);
            sustainSpr.w = sustainSpr.length - leftover;
            if (sustainSpr.w < 0) sustainSpr.w = 0;
        }

        parent.onNoteHit.dispatch(note, 0, noteSpr.notesInOne);
    }

    private inline function handleSustain(note:MetaNote, sustainSpr:Sustain, pos:Int64, leftover:Int, strumline:Strumline, rec:Receptor, playable:Bool) {
        sustainSpr.changeID(parent.inputSystem.receptorIds[note.index]);
        sustainSpr.parent = sustainSpr.parent; // already set
        sustainSpr.r = parent.downScroll ? -90 : 90;
        sustainSpr.speed = parent.scrollSpeed;
        sustainSpr.scale = rec.scale;
        sustainSpr.length = (note.duration * 4) - 10;

        if (!note.flag) {
            sustainSpr.w = sustainSpr.length;
            sustainSpr.followNote(sustainSpr.parent);
        } else if (sustainSpr.c.aF != 0) {
            if (sustainSpr.w >= 0) {
                sustainSpr.followNote(rec);
                sustainSpr.w = sustainSpr.length - leftover;
                if (sustainSpr.w < 0) sustainSpr.w = 0;
            }

            if (pos > note.position + (MetaNote.floatToMetaNotePosition(sustainSpr.length) - 70) && !note.held) {
                note.held = true;
                File.setNote(note.index, note);

                strumline.sustainsToHold[note.index] = null;
                strumline.botHitsToCheck[note.index] = false;

                if (rec.confirmed()) {
                    if (playable) rec.press();
                    else rec.reset();
                }

                parent.onSustainComplete.dispatch(note);
            }
        }

        if (@:privateAccess sustainSpr.bytePos == -1) sustainsBuf.addElement(sustainSpr);
    }

	/**
	 * Change the scroll speed of this note system.
	**/
	function setScrollSpeed(value:Float) {
		noteSpawner.spawnDist = MetaNote.floatToMetaNotePosition(1600 / value);
		noteSpawner.despawnDist = MetaNote.floatToMetaNotePosition(300 / Math.min(Math.max(value, 0.0001), 1.0));
		parent.hitbox = 200 * value;
		return value;
	}

	/**
	 * Resets the strumlines of this note system.
	**/
	function resetStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			strumline.x = STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5));
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET;
			if (resetAnims) strumline.resetAnimations();
			strumline.resetInputs();
		}
	}

	/**
	 * Resets the strumlines of this note system.
	**/
	function resetPlayerStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			if (!strumline.playable) continue;
			strumline.x = STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5));
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET;
			if (resetAnims) strumline.resetAnimations();
			strumline.resetInputs();
		}
	}

	/**
	 * Resets the notes in this note system.
	 * This is used when downscroll is enabled or when the player wants to reset the notes
	 */
	function resetNotes(songPosition:Float) {
		noteSpawner.resetNotes(songPosition);
	}

	/**
	 * Disposes the note system.
	**/
	function dispose() {
		if (strumlines != null) {
			while (strumlines.length != 0) {
				var strumline = strumlines.pop();
				strumline.dispose();
			}
	
			strumlines = null;
		}

		if (noteSpawner != null) {
			noteSpawner = null;
		}

		if (notePool != null) {
			notePool.dispose();
			notePool = null;
		}

		notesBuf.clear();
		sustainsBuf.clear();

		var display = parent.display;

		display.removeProgram(sustainProg);
		display.removeProgram(notesProg);
	}
}

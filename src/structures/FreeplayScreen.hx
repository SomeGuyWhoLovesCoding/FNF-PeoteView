package structures;

import data.gameplay.ChapterData.ChapterSong;

/**
	The freeplay submenu's screen.
	Coordinates chapter song data, alphabet list rendering, and health icons.
	@since Development
**/
@:publicFields
class FreeplayScreen implements IAlphabetScrollHost {
	private static var display(get, never):CustomDisplay;

	inline private static function get_display() {
		// Add null check and ensure display is initialized
		if (FreeplayMenu.display == null) {
			throw "FreeplayMenu.display not initialized! Call FreeplayMenu.init() first.";
		}
		return FreeplayMenu.display;
	}

	static var songIconsBuf(default, null):Buffer<HealthBarSprite>;

	/** Expose the song-icons buffer so callers can do `freeplayScreen.buffer.update()` directly. **/
	static var buffer(get, never):Buffer<HealthBarSprite>;

	inline static function get_buffer():Buffer<HealthBarSprite> {
		return songIconsBuf;
	}

	static var songIconsProg(default, null):CustomProgram;

	var songsAvailable(default, null):Array<ChapterSong> = [];

	static var songIconGroup(default, null):Array<HealthBarSprite> = [];

	var parent(default, null):FreeplayMenu;

	static var alphabet(default, null):FreeplayAlphabet;

	var disposed(default, null):Bool = true;

	var chapter(default, null):String;

	function new(parent:FreeplayMenu, chapterName:String) {
		this.parent = parent;
		chapter = chapterName;
	}

	function alphabetListLength():Int {
		return songsAvailable.length;
	}

	function alphabetItemTitle(index:Int):String {
		return songsAvailable[index].title;
	}

	function reload(chapterName:String) {
		if (FreeplayMenu.display == null) {
			throw "FreeplayMenu.display not initialized!";
		}

		clearSongIcons();

		// Create once, reuse forever
		if (alphabet == null) {
			alphabet = new FreeplayAlphabet(this, display);
			alphabet.ensurePrograms();
			alphabet.reload();
			alphabet.addPrograms();
		} else {
			// Reset existing alphabet without recreating
			alphabet.unloadChars(); // Clear all characters
			alphabet.host = this; // Update host reference
			alphabet.reload(); // Recreate characters
		}

		if (songIconsBuf == null) {
			songIconsBuf = new Buffer<HealthBarSprite>(8, 8);
			songIconsProg = new CustomProgram(songIconsBuf);
			var tex = TextureSystem.getTexture("hbTex");
			HealthBarSprite.init(songIconsProg, "hbTex", tex);
		} else {
			// Clear existing icons from buffer
			songIconsBuf.clear();
		}

		chapter = chapterName;

		var chapterData:ChapterData = haxe.Json.parse(sys.io.File.getContent(Paths.asset('assets/data/chapters/$chapter/data.json')));
		var songs:Array<ChapterSong> = chapterData.songs;

		songsAvailable = [];
		for (i in 0...songs.length) {
			songsAvailable.push(songs[i]);
		}

		// Create new icons
		songIconGroup = [];
		for (i in 0...7) {
			var icon = new HealthBarSprite();
			icon.type = HEALTH_ICON;
			icon.alpha = 0.0;
			songIconsBuf.addElement(icon);
			songIconGroup.push(icon);
		}

		// Reset state
		alphaLerp = 0.0;
		curSelectedLerp = parent.nav.value();
		curSelectedTarget = parent.nav.value();
		xLerp = 20 - (parent.nav.value() * 20);
		xLerpPrev = xLerp;

		disposed = false;
	}

	/**
		Pre-warm all programs (alphabet + song icons) so the first open()
		adds them with zero stall. Call once after display is initialized.
	**/
	function preWarm() {
		if (display == null)
			return;

		// Do a full reload to create alphabet, song icons buffer/program, and
		// populate icon elements — this is where all the heavy allocation lives.
		reload('chapter1');

		// Pre-warm every first-time addProgram call (shader compilation).
		addPrograms();

		// Immediately remove everything so the screen appears hidden.
		shutDown();

		// Null alphabet so the next reload() takes the fresh-creation path
		// (shutDown leaves it disposed but non-null).
		alphabet = null;

		// Clean instance data but keep static buffers/programs alive.
		songsAvailable = [];
		songIconGroup = [];
		disposed = true;
	}

	function clearSongIcons() {
		// Remove all existing icons from buffer
		for (icon in songIconGroup) {
			if (icon != null) {
				try {
					songIconsBuf.removeElement(icon);
				} catch (e) {}
			}
		}
		songIconGroup.splice(0, songIconGroup.length);
	}

	function unload() {
		if (disposed)
			return;

		// Properly dispose alphabet instance
		if (alphabet != null) {
			alphabet.shutDown();
		}

		songsAvailable.splice(0, songsAvailable.length);

		// Clear song icons
		clearSongIcons();

		disposed = true;
	}

	var alphaLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var xLerp:Float = 0.0;
	var xLerpPrev:Float = 0.0;

	var curSelectedTarget:Float = 0.0;

	// --- Render helpers ---

	inline function calcRatio(deltaTime:Float):Float {
		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1)
			ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;
		return ratio;
	}

	inline function handleShutdown() {
		parent.shutDown();
		curSelectedLerp = parent.nav.value();
		alphaLerp = 0.0;
		xLerp = 20 - (parent.nav.value() * 20);
		xLerpPrev = xLerp;
	}

	inline function updateLerps(ratio:Float) {
		var curSelected = parent.nav.value();
		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		if (!parent.isDragging) {
			curSelectedTarget = curSelected;
		}
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
		xLerp = 20 - (curSelectedLerp * 20);
	}

	inline function calcIncrementBest():Int {
		return songsAvailable.length > 7 ? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), songsAvailable.length - 7)) : 0;
	}

	function updateSongIcon(i:Int, incrementBest:Int, iconX:Float) {
		if (i >= songIconGroup.length)
			return;

		var k = i + incrementBest;
		if (k < 0 || k >= songsAvailable.length) {
			// Hide icon if out of range
			var icon = songIconGroup[i];
			if (icon != null) {
				icon.alpha = 0.0;
			}
			return;
		}

		var kClamped = Math.floor(Math.min(Math.max(k, 0), songsAvailable.length - 1));
		var song = songsAvailable[kClamped];

		var icon = songIconGroup[i];
		if (icon == null)
			return;

		icon.changeID(Tools.fromIconGridXMLCharacter(song.icon)[0]);
		var alpha = alphabet.calcItemAlpha(k) * alphaLerp;
		icon.alpha = alpha;
		icon.x = iconX + ((icon.w * 0.35) + 12);
		icon.y = ((-curSelectedLerp * 156) + (156 * k) + 320) - 30;
		icon.texW = 150;
		icon.texH = 150;
	}

	function render(deltaTime:Float) {
		var ratio = calcRatio(deltaTime);

		if (!parent.opened && alphaLerp < 0.1 / 256) {
			handleShutdown();
			return;
		}

		if (alphabet == null || alphabet.isDisposed)
			return;

		alphabet.setDeltaTime(deltaTime);

		updateLerps(ratio);

		var incrementBest = calcIncrementBest();

		for (i in 0...7) {
			var iconX = alphabet.updateRowText(i, incrementBest);
			updateSongIcon(i, incrementBest, iconX);
		}

		alphabet.buffer.update();
		buffer.update();

		xLerpPrev = xLerp;
	}

	function addPrograms() {
		if (alphabet != null && !alphabet.isDisposed) {
			alphabet.addPrograms();
		}

		if (songIconsProg != null && !songIconsProg.isIn(display)) {
			display.addProgram(songIconsProg);
		}
	}

	function shutDown() {
		if (alphabet != null && !alphabet.isDisposed) {
			alphabet.shutDown();
		}

		if (songIconsProg != null && songIconsProg.isIn(display)) {
			display.removeProgram(songIconsProg);
		}
	}
}

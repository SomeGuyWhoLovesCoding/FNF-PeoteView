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
		return FreeplayMenu.display;
	}

	static var songIconsBuf(default, null):Buffer<HealthBarSprite>;
	static var songIconsProg(default, null):CustomProgram;

	var songsAvailable(default, null):Array<ChapterSong> = [];
	static var songIconGroup(default, null):Array<HealthBarSprite> = [];

	var parent(default, null):FreeplayMenu;
	var alphabet(default, null):FreeplayAlphabet;

	var disposed(default, null):Bool = true;

	var chapter(default, null):String;

	function new(parent:FreeplayMenu, chapterName:String) {
		this.parent = parent;
		chapter = chapterName;
		alphabet = new FreeplayAlphabet(this, display);
	}

	function alphabetListLength():Int {
		return songsAvailable.length;
	}

	function alphabetItemTitle(index:Int):String {
		return songsAvailable[index].title;
	}

	function reload(chapterName:String) {
		alphabet.ensurePrograms();

		if (songIconsBuf == null) {
			songIconsBuf = new Buffer<HealthBarSprite>(8, 8);
			songIconsProg = new CustomProgram(songIconsBuf);

			var tex = TextureSystem.getTexture("hbTex");
			HealthBarSprite.init(songIconsProg, "hbTex", tex);
		}

		if (!disposed) unload();

		chapter = chapterName;

		var chapterData:ChapterData = haxe.Json.parse(sys.io.File.getContent(Paths.asset('assets/data/chapters/$chapter/data.json')));
		var songs:Array<ChapterSong> = chapterData.songs;

		for (i in 0...songs.length) {
			var song = songs[i];
			songsAvailable.push(song);
		}

		alphabet.reload();

		songIconGroup = [
			for (i in 0...7) {
				var icon = new HealthBarSprite();
				icon.type = HEALTH_ICON;
				icon.alpha = 0.0;
				songIconsBuf.addElement(icon);
				icon;
			}
		];

		disposed = false;
	}

	function unload() {
		alphabet.unload();
		songIconsBuf.clear();
		songsAvailable.splice(0, songsAvailable.length);
		songIconGroup.splice(0, songIconGroup.length);
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
		if (ratio == 1) ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;
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
		return songsAvailable.length > 7
			? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), songsAvailable.length - 7))
			: 0;
	}

	function updateSongIcon(i:Int, incrementBest:Int, iconX:Float) {
		var k = i + incrementBest;
		if (k < 0 || k >= songsAvailable.length) return;

		var kClamped = Math.floor(Math.min(Math.max(k, 0), songsAvailable.length - 1));
		var song = songsAvailable[kClamped];

		var icon = songIconGroup[i];
		icon.changeID(Tools.fromIconGridXMLCharacter(song.icon)[0]);
		var alpha = alphabet.calcItemAlpha(k) * alphaLerp;
		icon.alpha = alpha;
		icon.x = iconX + ((icon.w * 0.35) + 12);
		icon.y = ((-curSelectedLerp * 156) + (156 * k) + 320) - 30; // https://github.com/ShadowMario/FNF-PsychEngine/blob/main/source/objects/HealthIcon.hx#L22
		icon.texW = 150;
		icon.texH = 150;
	}

	function render(deltaTime:Float) {
		var ratio = calcRatio(deltaTime);

		if (!parent.opened && alphaLerp < 0.1 / 256) {
			handleShutdown();
			return;
		}

		alphabet.setDeltaTime(deltaTime);

		updateLerps(ratio);

		var incrementBest = calcIncrementBest();

		for (i in 0...7) {
			var iconX = alphabet.updateRowText(i, incrementBest);
			updateSongIcon(i, incrementBest, iconX);
		}

		alphabet.updateBuffer();
		songIconsBuf.update();

		xLerpPrev = xLerp;
	}

	function addPrograms() {
		alphabet.addPrograms();

		if (!songIconsProg.isIn(display)) {
			display.addProgram(songIconsProg);
		}
	}

	function shutDown() {
		alphabet.shutDown();

		if (songIconsProg.isIn(display)) {
			display.removeProgram(songIconsProg);
		}
	}
}

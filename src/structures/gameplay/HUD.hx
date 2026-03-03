package structures.gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/**
	The playfield's HUD.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
	It is used to display the player's health, score, time bar, and rating popup.
	It is responsible for rendering the HUD and updating it based on the player's input and game state.
	@since Development
**/
@:publicFields
class HUD {
	static var uiBuf(default, null):Buffer<UISprite>;
	static var uiProg(default, null):CustomProgram;

	static var scoreTxt(default, null):Text;
	static var watermarkTxt(default, null):Text;
	static var timeBarTxt(default, null):Text;

	var ratingPopup(default, null):UISprite;
	var comboNumbers(default, null):Array<UISprite> = [];

	var healthBar(default, null):HealthBar;

	var timeBarParts(default, null):Array<UISprite> = [];
	var timeBarBG(default, null):UISprite;

	var timeBarWS(default, null):Float;
	var timeBarHS(default, null):Float;
	var timeBarXA(default, null):Float;
	var timeBarYA(default, null):Float;

	var display(default, null):CustomDisplay;
	var parent(default, null):PlayField;

	/**
		Create the playfield UI.
	**/
	function new(display:CustomDisplay, parent:PlayField) {
		this.display = display;
		this.parent = parent;

		display.addProgram(uiProg);

		timeBarWS = UISprite.timeBarProperties[2];
		timeBarHS = UISprite.timeBarProperties[3];

		timeBarXA = UISprite.timeBarProperties[4];
		timeBarYA = UISprite.timeBarProperties[5];

		// HEALTH BAR SETUP

		HealthBar.init(display);
		healthBar = new HealthBar(display, parent);

		// TIME BAR SETUP

		timeBarBG = new UISprite();
		timeBarBG.type = TIME_BAR;
		timeBarBG.changeID(0);
		timeBarBG.x = (Main.INITIAL_WIDTH - timeBarBG.w) * 0.5;
		timeBarBG.y = Main.INITIAL_HEIGHT - 24;

		// TIME BAR PART SETUP

		for (i in 0...2) {
			var part = timeBarParts[i] = new UISprite();
			part.w = timeBarBG.w - (timeBarWS * 2.0);
			part.h = timeBarBG.h - timeBarHS;
			part.x = timeBarBG.x + timeBarXA;
			part.y = timeBarBG.y + timeBarYA;
			part.plainColor = 1.0;
			part.c = i == 0 ? 0x000000FF : 0xFFFFFFFF;

			uiBuf.addElement(part);
		}

		uiBuf.addElement(timeBarBG);

		updateTimeBarParts();

		// TEXT SETUP

		if (watermarkTxt == null) {
			watermarkTxt = new Text("watermarkTxtPF", 0, 0, display, 'FV TEST BUILD');
			watermarkTxt.y = Main.INITIAL_HEIGHT - watermarkTxt.height;
		} else display.addProgram(watermarkTxt.program);

		if (timeBarTxt == null) {
			timeBarTxt = new Text("timeBarTxt", 0, 0, display, Tools.formatTime(Mixer.length - Math.max(parent.songPosition, 0)));
			timeBarTxt.x = (Main.INITIAL_WIDTH - timeBarTxt.width) * 0.5;
			timeBarTxt.y = timeBarBG.y - 2;
			timeBarTxt.scale = 1.15;
			timeBarTxt.outlineColor = 0x000000FF;
			timeBarTxt.outlineSize = 0.12;
		} else display.addProgram(timeBarTxt.program);

		updateTimeBarText();

		if (scoreTxt == null) {
			scoreTxt = new Text("scoreTxt", 0, 0, display);
			scoreTxt.color.aF = 1.0;
			scoreTxt.color.luminanceF = 1.0;
			scoreTxt.outlineColor = 0x000000FF;
			scoreTxt.outlineSize = 0.12;
		}
		else display.addProgram(scoreTxt.program);

		updateScoreText(0.0);

		// RATING AND COMBO NUMBER POPUP SETUP
		ratingPopup = new UISprite();
		ratingPopup.type = RATING_POPUP;
		ratingPopup.changeID(0);
		ratingPopup.x = 500;
		ratingPopup.y = 360;
		ratingPopup.alpha = 0.0;
		uiBuf.addElement(ratingPopup);

		for (i in 0...3) addComboNumber();

		setHUDAlpha(0.0);
	}

	/**
		Initializes the HUD with a static buffer and program.
	**/
	static function init() {
		if (uiBuf == null) {
			uiBuf = new Buffer<UISprite>(4, 4, true);
			uiProg = new CustomProgram(uiBuf);

			var tex = TextureSystem.getTexture("uiTex");
			UISprite.init(uiProg, "uiTex", tex);
		}
	}

	var alphaLerp:Float = .0;

	/**
		Renders the HUD.
	**/
	function render(deltaTime:Float) {
		if (SaveData.state.preferences.ratingPopup) {
			updateRatingPopup(deltaTime);
			updateComboNumbers();
		}
		healthBar.render(deltaTime);
		updateTimeBarParts();
		updateTimeBarText();
		updateScoreText(deltaTime);

		var t = Math.min(deltaTime * 0.015, 1.0);

		if (parent.songStarted && alphaLerp != 1.0) {
			alphaLerp = Tools.lerp(alphaLerp, 1.0, t);
			setHUDAlpha(alphaLerp);
		}
	}

	/**
		Individualized function to make it possible to change the score text even after render has happened.
	**/
	function updateBuffers() {
		HealthBar.hbBuf.update();
		uiBuf.update();
	}

	/**
		Sets the entire hud's alpha. The watermark text won't be affected.
	**/
	function setHUDAlpha(alpha:Float) {
		healthBar.bg.alpha = alpha;

		for (part in healthBar.parts) {
			part.alpha = alpha;
		}

		for (icon in healthBar.healthIcons) {
			icon.alpha = alpha;
		}

		timeBarBG.alpha = alpha;

		for (part in timeBarParts) {
			part.alpha = alpha;
		}

		timeBarTxt.alpha = alpha;
		scoreTxt.alpha = alpha;
	}

	/**
		Updates the rating popup.
	**/
	function updateRatingPopup(deltaTime:Float) {
		if (parent.disposed || parent.died) return;

		if (ratingPopup == null) return;

		ratingPopup.alpha = Tools.fixElementAlphaFromFadingLerp(Tools.lerp(ratingPopup.alpha, 0.0, Math.min(deltaTime * 0.005, 1.0)));
		ratingPopup.y = Tools.lerp(ratingPopup.y, 320, Math.min(deltaTime * 0.0125, 1.0));

		uiBuf.updateElement(ratingPopup);
	}

	/**
		Updates the combo numbers.
	**/
	function updateComboNumbers() {
		if (parent.disposed || parent.died) return;

		var numStr = Int128.toStr(parent.combo);

		var comboNumberStrLen = numStr.length;

		if (comboNumberStrLen <= 3) comboNumberStrLen = 3;

		while (comboNumbers.length < comboNumberStrLen) addComboNumber();

		while (comboNumbers.length > comboNumberStrLen) {
			var comboNumber = comboNumbers.pop();
			uiBuf.removeElement(comboNumber);
		}

		for (i in 0...comboNumbers.length) {
			var comboNumber = comboNumbers[i];

			if (comboNumber == null) continue;

			var digit = numStr.charCodeAt(i <= numStr.length ? (numStr.length - 1) - i : numStr.length - 1) - 48;

			comboNumber.y = ratingPopup.y + (ratingPopup.h + 5);
			comboNumber.alpha = ratingPopup.alpha;

			if (i > 2) {
				if (i >= numStr.length) {
					comboNumber.alpha = 0;
				}
			}

			if (comboNumber.curID != digit) comboNumber.changeID(i >= numStr.length ? 0 : digit);

			uiBuf.updateElement(comboNumber);
		}
	}

	/**
		Adds a new combo number onto the ui buffer.
	**/
	function addComboNumber() {
		// COMBO NUMBERS SETUP
		var comboNumber = new UISprite();
		comboNumber.type = COMBO_NUMBER;
		comboNumber.changeID(0);
		comboNumber.x = ratingPopup.x + 208 - ((comboNumber.w + 2) * comboNumbers.length);
		comboNumber.y = ratingPopup.y + (ratingPopup.h + 5);
		comboNumber.alpha = 0.0;
		comboNumbers.push(comboNumber);
		uiBuf.addElement(comboNumber);
	}

	/**
		Updates the score text.
	**/
	function updateScoreText(deltaTime:Float) {
		var scoreText = 'Score: ${parent.score} | Misses: ${parent.misses} | Accuracy: ${parent.accuracy.toString()}';
		if (scoreTxt.text != scoreText) scoreTxt.text = scoreText;
		scoreTxt.scale = Tools.lerp(scoreTxt.scale, 1.0, Math.min(deltaTime * 0.02, 1.0));
		scoreTxt.x = Math.floor(healthBar.bg.x) + ((healthBar.bg.w - scoreTxt.width) * 0.5);
		scoreTxt.y = Math.floor(healthBar.bg.y) + (healthBar.bg.h + 6);
		/*scoreTxt.color = 0xFFDC8CFF;
		scoreTxt.setMarkerPair('Score: ', Color.WHITE);
		scoreTxt.setMarkerPair(', Misses: ', Color.WHITE);
		scoreTxt.setMarkerPair(', Accuracy: ', Color.WHITE);*/
	}

	/**
		Updates the timebar text.
	**/
	function updateTimeBarParts() {
		if (parent.disposed || parent.died) return;

		var part = timeBarParts[1];

		if (part == null) return;

		part.w = (timeBarBG.w - (timeBarWS * 2.0)) * (parent.songPosition / Mixer.length);
		part.x = timeBarBG.x + timeBarXA;
		part.y = timeBarBG.y + timeBarYA;

		if (part.w < 0) part.w = 0;

		uiBuf.updateElement(part);
	}

	/**
		Updates the timebar text.
	**/
	function updateTimeBarText() {
		timeBarTxt.text = Tools.formatTime(Mixer.length - Math.max(parent.songPosition, 0));
		timeBarTxt.x = (Main.INITIAL_WIDTH - timeBarTxt.width) * 0.5;
		timeBarTxt.y = timeBarBG.y - 2;
	}

	/**
		Hides the rating popup.
	**/
	function hideRatingPopup() {
		if (parent.disposed || parent.died) return;

		ratingPopup.alpha = 0.0;
		uiBuf.updateElement(ratingPopup);
	}

	/**
		Wakes up the rating popup.
	**/
	function respondWithRatingID(id:Int) {
		if (parent.disposed || parent.died) return;

		ratingPopup.alpha = 1.0;
		ratingPopup.y = 300;
		ratingPopup.changeID(id);
		uiBuf.updateElement(ratingPopup);
	}

	/**
		Dispose the hud.
	**/
	function dispose() {
		uiBuf.removeElement(ratingPopup);
		ratingPopup = null;

		while (comboNumbers.length != 0) {
			var comboNumber = comboNumbers.pop();
			uiBuf.removeElement(comboNumber);
		}
		comboNumbers = null;

		if (healthBar != null) {
			healthBar.dispose();
			healthBar = null;
		}

		// reset scoretxt values
		if (scoreTxt != null) {
			scoreTxt.text = "";
			scoreTxt.color = 0xFFFFFFFF;
			scoreTxt.color.aF = 1.0;
			scoreTxt.color.luminanceF = 1.0;
			scoreTxt.outlineColor = 0x000000FF;
			scoreTxt.outlineSize = 0.12;
		}

		// reset timebartxt values
		if (timeBarTxt != null) {
			timeBarTxt.x = (Main.INITIAL_WIDTH - timeBarTxt.width) * 0.5;
			timeBarTxt.y = timeBarBG.y - 2;
			timeBarTxt.scale = 1.15;
			timeBarTxt.outlineColor = 0x000000FF;
			timeBarTxt.outlineSize = 0.12;
		}

		uiBuf.removeElement(timeBarBG);
		timeBarBG = null;

		while (timeBarParts.length != 0) {
			var timeBarPart = timeBarParts.pop();
			uiBuf.removeElement(timeBarPart);
		}
		timeBarParts = null;

		display.removeProgram(watermarkTxt.program);
		display.removeProgram(timeBarTxt.program);
		display.removeProgram(scoreTxt.program);

		display.removeProgram(uiProg);
	}
}

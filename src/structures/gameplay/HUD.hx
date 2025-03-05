package structures.gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/**
	The playfield's HUD.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
**/
@:publicFields
class HUD {
	static var uiBuf(default, null):Buffer<UISprite>;
	static var uiProg(default, null):Program;

	static var scoreTxt(default, null):Text;
	static var watermarkTxt(default, null):Text;
	static var timeBarTxt(default, null):Text;

	var ratingPopup(default, null):UISprite;
	var comboNumbers(default, null):Array<UISprite> = [];

	var healthBarParts(default, null):Array<UISprite> = [];
	var healthBarBG(default, null):UISprite;

	var healthIcons(default, null):Array<UISprite> = [];
	var healthIconIDs(default, null):Array<Array<Int>> = [[0, 1], [2, 3]];
	var healthIconColors:Array<Array<Color>> = [
		[Color.WHITE, Color.BLUE, Color.YELLOW, Color.RED3, Color.GREY2, Color.CYAN],
		[Color.LIME, Color.LIME, Color.LIME, Color.LIME, Color.LIME, Color.LIME]
	];

	var timeBarParts(default, null):Array<UISprite> = [];
	var timeBarBG(default, null):UISprite;

	var healthBarWS(default, null):Float;
	var healthBarHS(default, null):Float;
	var healthBarXA(default, null):Float;
	var healthBarYA(default, null):Float;

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

		healthBarWS = UISprite.healthBarProperties[2];
		healthBarHS = UISprite.healthBarProperties[3];

		healthBarXA = UISprite.healthBarProperties[4];
		healthBarYA = UISprite.healthBarProperties[5];

		timeBarWS = UISprite.timeBarProperties[2];
		timeBarHS = UISprite.timeBarProperties[3];

		timeBarXA = UISprite.timeBarProperties[4];
		timeBarYA = UISprite.timeBarProperties[5];

		// HEALTH BAR SETUP
		healthBarBG = new UISprite();
		healthBarBG.type = HEALTH_BAR;
		healthBarBG.changeID(0);
		healthBarBG.x = 275;
		healthBarBG.y = parent.downScroll ? 90 : Main.INITIAL_HEIGHT - 90;

		var actors = parent.field.actors;

		// HEALTH BAR PART SETUP
		for (i in 0...2) {
			var part = healthBarParts[i] = new UISprite();
			part.h = healthBarBG.h - healthBarHS;
			part.y = healthBarBG.y + healthBarYA;
			part.gradientMode = 1.0;

			part.setAllColors(actors[i].data.colors);

			uiBuf.addElement(part);
		}

		uiBuf.addElement(healthBarBG);

		updateHealthBar();

		// HEALTH ICONS SETUP

		var x = healthBarBG.x + (healthBarBG.w * 0.5);

		for (i in 0...2) {
			var healthIconIndexes = actors[i + 1].data.healthIconIndexes;
			healthIconIDs[i] = [healthIconIndexes[0], healthIconIndexes[1]];
		}

		var oppIcon = healthIcons[0] = new UISprite();
		oppIcon.type = HEALTH_ICON;
		oppIcon.changeID(healthIconIDs[0][0]);

		var plrIcon = healthIcons[1] = new UISprite();
		plrIcon.type = HEALTH_ICON;
		plrIcon.changeID(healthIconIDs[1][0]);

		oppIcon.y = plrIcon.y = healthBarBG.y - 75;
		plrIcon.flip = true;

		uiBuf.addElement(oppIcon);
		uiBuf.addElement(plrIcon);

		updateHealthIcons();

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
			part.gradientMode = 1.0;
			part.setAllColors(new Vector<Color>(6,  i == 0 ? 0x000000FF : 0xFFFFFFFF));

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
			timeBarTxt = new Text("timeBarTxt", 0, 0, display, Tools.formatTime(parent.audioSystem.inst.length - Math.max(parent.songPosition, 0)));
			timeBarTxt.x = (Main.INITIAL_WIDTH - timeBarTxt.width) * 0.5;
			timeBarTxt.y = timeBarBG.y - 2;
			timeBarTxt.scale = 1.15;
			timeBarTxt.outlineColor = 0x000000FF;
		} else display.addProgram(timeBarTxt.program);

		updateTimeBarText();

		if (scoreTxt == null) scoreTxt = new Text("scoreTxt", 0, 0, display);
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
	static function init(display:CustomDisplay) {
		if (uiBuf == null) {
			uiBuf = new Buffer<UISprite>(4, 4, true);
			uiProg = new Program(uiBuf);
			uiProg.blendEnabled = true;

			var tex = TextureSystem.getTexture("uiTex");
			UISprite.init(uiProg, "uiTex", tex);
		}
	}

	var alphaLerp:Float = .0;

	/**
		Updates the HUD.
	**/
	function update(deltaTime:Float) {
		var health = parent.health;
		_smoothHealth = Tools.lerp(_smoothHealth, health, SaveData.state.preferences.smoothHealthbar ? Math.max(Math.min(deltaTime / 60, 1.0), 0.0) : 1.0);

		if (SaveData.state.preferences.ratingPopup) {
			updateRatingPopup(deltaTime);
			updateComboNumbers();
		}
		updateHealthBar();
		updateHealthIcons();
		updateTimeBarParts();
		updateTimeBarText();
		updateScoreText(deltaTime);

		if (parent.songStarted && alphaLerp != 1.0) {
			alphaLerp = Tools.lerp(alphaLerp, 1.0, Math.max(Math.min(deltaTime * 0.015, 1.0), 0.0));
			setHUDAlpha(alphaLerp);
		}
	}

	/**
		Sets the entire hud's alpha. The watermark text won't be affected.
	**/
	function setHUDAlpha(alpha:Float) {
		healthBarBG.alpha = alpha;
		uiBuf.updateElement(healthBarBG);

		for (part in healthBarParts) {
			part.alpha = alpha;
			uiBuf.updateElement(part);
		}

		for (icon in healthIcons) {
			icon.alpha = alpha;
			uiBuf.updateElement(icon);
		}

		timeBarBG.alpha = alpha;
		uiBuf.updateElement(timeBarBG);

		for (part in timeBarParts) {
			part.alpha = alpha;
			uiBuf.updateElement(part);
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

		if (ratingPopup.alpha != 0) {
			ratingPopup.alpha -= ratingPopup.alpha * Math.min((deltaTime * 0.005), 1.0);
		}

		if (ratingPopup.y != 320) {
			ratingPopup.y -= (ratingPopup.y - 320) * Math.min((deltaTime * 0.0125), 1.0);
			uiBuf.updateElement(ratingPopup);
		}
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
					comboNumber.alpha = 0.0;
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

	private var _smoothHealth(default, null):Float;

	/**
		Updates the health bar.
	**/
	function updateHealthBar() {
		if (parent.disposed || parent.died) return;

		healthBarBG.y = parent.downScroll ? 90 : Main.INITIAL_HEIGHT - 90;
		uiBuf.updateElement(healthBarBG);

		var actors = parent.field.actors;

		var part1 = healthBarParts[0];

		if (part1 == null) return;

		var healthIconColor = actors[(parent.flipHealthBar ? 1 : 0) + 1].data.colors;

		part1.setAllColors(healthIconColor);

		part1.w = (healthBarBG.w - Math.floor(healthBarBG.w * (parent.flipHealthBar ? 1 - _smoothHealth : _smoothHealth))) - (healthBarWS * 2.0);
		part1.x = healthBarBG.x + healthBarXA;
		part1.y = healthBarBG.y + healthBarYA;

		if (part1.w < 0) part1.w = 0;

		uiBuf.updateElement(part1);

		var part2 = healthBarParts[1];

		if (part2 == null) return;

		var healthIconColor = actors[(parent.flipHealthBar ? 0 : 1) + 1].data.colors;

		part2.setAllColors(healthIconColor);

		part2.w = (healthBarBG.w - part1.w) - (healthBarWS * 2.0);
		part2.x = (healthBarBG.x + part1.w) + healthBarXA;
		part2.y = healthBarBG.y + healthBarYA;

		if (part2.w < 0) part2.w = 0;

		uiBuf.updateElement(part2);
	}

	/**
		Updates the health icons.
	**/
	function updateHealthIcons() {
		if (parent.disposed || parent.died) return;

		var part1 = healthBarParts[1];

		if (part1 == null) return;

		var health = parent.health;
		var icons = healthIcons;
		var ids = healthIconIDs;

		var oppIcon = icons[0];
		var plrIcon = icons[1];

		var oppIcon = healthIcons[0];
		oppIcon.x = part1.x - 118;

		var plrIcon = healthIcons[1];
		plrIcon.x = part1.x - 18;

		oppIcon.y = plrIcon.y = healthBarBG.y - 75;

		var oppIco = parent.flipHealthBar ? plrIcon : oppIcon;
		var plrIco = parent.flipHealthBar ? oppIcon : plrIcon;

		if (health > 0.75) oppIco.changeID(ids[0][1]);
		else oppIco.changeID(ids[0][0]);

		if (health < 0.25) plrIco.changeID(ids[1][1]);
		else plrIco.changeID(ids[1][0]);

		uiBuf.updateElement(oppIcon);
		uiBuf.updateElement(plrIcon);
	}

	/**
		Updates the score text.
	**/
	function updateScoreText(deltaTime:Float) {
		scoreTxt.text = 'Score: ${parent.score}, Misses: ${parent.misses}, Accuracy: ${parent.accuracy.toString()}';
		scoreTxt.scale = Tools.lerp(scoreTxt.scale, 1.0, Math.min(deltaTime * 0.02, 1.0));
		scoreTxt.x = Math.floor(healthBarBG.x) + ((healthBarBG.w - scoreTxt.width) * 0.5);
		scoreTxt.y = Math.floor(healthBarBG.y) + (healthBarBG.h + 6);
		scoreTxt.color.aF = 1.0;
		scoreTxt.outlineColor.aF = 1.0;
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

		part.w = (timeBarBG.w - (timeBarWS * 2.0)) * (parent.songPosition / parent.audioSystem.inst.length);
		part.x = timeBarBG.x + timeBarXA;
		part.y = timeBarBG.y + timeBarYA;

		if (part.w < 0) part.w = 0;

		uiBuf.updateElement(part);
	}

	/**
		Updates the timebar text.
	**/
	function updateTimeBarText() {
		timeBarTxt.text = Tools.formatTime(parent.audioSystem.inst.length - Math.max(parent.songPosition, 0));
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

		uiBuf.removeElement(healthBarBG);
		healthBarBG = null;

		while (healthBarParts.length != 0) {
			var healthBarPart = healthBarParts.pop();
			uiBuf.removeElement(healthBarPart);
		}
		healthBarParts = null;

		while (healthIcons.length != 0) {
			var healthIcon = healthIcons.pop();
			uiBuf.removeElement(healthIcon);
		}
		healthIcons = null;

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
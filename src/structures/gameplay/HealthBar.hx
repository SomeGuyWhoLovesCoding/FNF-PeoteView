package structures.gameplay;

/**
	The playfield's health bar.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
	It is used to display the health of the player and the opponent, with a bar that tries to mimic rpg fighting games like flixel's `FlxBar` is intended to do.
	This class is responsible for rendering the health bar and updating it based on the player's health.
	It also handles the health icons that are displayed above the health bar, which represent the player's and opponent's health status.
	It is also responsible for updating the health bar's position and size based on the playfield's properties, such as the down scroll and the flip health bar settings.
	@since Development
**/
@:publicFields
class HealthBar {
	static var hbBuf(default, null):Buffer<HealthBarSprite>;
	static var hbProg(default, null):Program;

	var display(default, null):CustomDisplay;
	var parent(default, null):PlayField;

	var parts(default, null):Array<HealthBarSprite> = [];
	var bg(default, null):HealthBarSprite;

	var healthIcons(default, null):Array<HealthBarSprite> = [];
	var healthIconIDs(default, null):Array<Array<Int>> = [[0, 1], [2, 3]];
	var healthIconColors:Array<Array<Color>> = [
		[Color.WHITE, Color.BLUE, Color.YELLOW, Color.RED3, Color.GREY2, Color.CYAN],
		[Color.LIME, Color.LIME, Color.LIME, Color.LIME, Color.LIME, Color.LIME]
	];

	var healthBarWS(default, null):Float;
	var healthBarHS(default, null):Float;
	var healthBarXA(default, null):Float;
	var healthBarYA(default, null):Float;

	var playerOGIcon:Any; // Tracks the player's original icon.

	/**
		Initializes the health bar.
		@param display The display to initialize the health bar on. Should be the playfield's display.
	**/
	static function init(display:CustomDisplay) {
		if (hbBuf == null) {
			hbBuf = new Buffer<HealthBarSprite>(4, 4, true);
			hbProg = new Program(hbBuf);
			hbProg.blendEnabled = true;
			hbProg.blendSrc = hbProg.blendSrcAlpha = BlendFactor.ONE;
			hbProg.blendDst = hbProg.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;
	
			var tex = TextureSystem.getTexture("hbTex");
			HealthBarSprite.init(hbProg, "hbTex", tex);
		}
	}

	/**
		Initializes the health bar.
		@param display The display to initialize the health bar on. Should be the playfield's display.
		@param parent The playfield to initialize the health bar on.
	**/
	function new(display:CustomDisplay, parent:PlayField) {
		this.display = display;
		this.parent = parent;

		display.addProgram(hbProg);

		healthBarWS = HealthBarSprite.healthBarProperties[2];
		healthBarHS = HealthBarSprite.healthBarProperties[3];

		healthBarXA = HealthBarSprite.healthBarProperties[4];
		healthBarYA = HealthBarSprite.healthBarProperties[5];

		// HEALTH BAR SETUP
		bg = new HealthBarSprite();
		bg.type = HEALTH_BAR;
		bg.changeID(0);
		bg.x = 275;
		bg.y = parent.downScroll ? 90 : Main.INITIAL_HEIGHT - 90;

		var actors = parent.field.actors;

		// HEALTH BAR PART SETUP
		for (i in 0...2) {
			var part = parts[i] = new HealthBarSprite();
			part.h = bg.h - healthBarHS;
			part.y = bg.y + healthBarYA;
			part.gradientMode = 1.0;
			part.setAllColors(actors[i].data.colors);

			hbBuf.addElement(part);
		}

		hbBuf.addElement(bg);

		updateBar();

		// HEALTH ICONS SETUP

		var x = bg.x + (bg.w * 0.5);

		for (i in 0...2) {
			var healthIconIndexes = Tools.fromIconGridXMLCharacter(actors[i + 1].data.healthIcon);
			healthIconIDs[i] = healthIconIndexes;
		}

		var iconP2 = healthIcons[0] = new HealthBarSprite();
		iconP2.type = HEALTH_ICON;
		iconP2.changeID(healthIconIDs[0][0]);

		var iconP1 = healthIcons[1] = new HealthBarSprite(); // Made more like FNF, so P1 is da player LOL.
		iconP1.type = HEALTH_ICON;
		iconP1.changeID(healthIconIDs[1][0]);
		playerOGIcon = healthIconIDs[1][0];
		//trace(playerOGIcon + "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"); //alory's done that print lol

		iconP2.y = iconP1.y = bg.y - 75;
		iconP1.flip = true;

		hbBuf.addElement(iconP2);
		hbBuf.addElement(iconP1);

		updateHealthIcons();
	}

	/**
		Updates the health bar.
	**/
	function render(deltaTime:Float) {
		var health = parent.health;
		_smoothHealth = Tools.lerp(_smoothHealth, health, SaveData.state.preferences.smoothHealthbar ? Math.max(Math.min(deltaTime / 60, 1.0), 0.0) : 1.0);

		updateBar();
		updateHealthIcons();
	}

	private var _smoothHealth(default, null):Float;

	/**
		Updates the health bar's body.
	**/
	function updateBar() {
		if (parent.disposed || parent.died) return;

		bg.y = parent.downScroll ? 90 : Main.INITIAL_HEIGHT - 90;

		var actors = parent.field.actors;

		var part1 = parts[0];

		if (part1 == null) return;

		var healthIconColor = actors[(parent.flipHealthBar ? 1 : 0) + 1].data.colors;

		part1.setAllColors(healthIconColor);

		part1.w = (bg.w - Math.floor(bg.w * (parent.flipHealthBar ? 1 - _smoothHealth : _smoothHealth))) - (healthBarWS * 2.0);
		part1.x = bg.x + healthBarXA;
		part1.y = bg.y + healthBarYA;

		if (part1.w < 0) part1.w = 0;

		var part2 = parts[1];

		if (part2 == null) return;

		var healthIconColor = actors[(parent.flipHealthBar ? 0 : 1) + 1].data.colors;

		part2.setAllColors(healthIconColor);

		part2.w = (bg.w - part1.w) - (healthBarWS * 2.0);
		part2.x = (bg.x + part1.w) + healthBarXA;
		part2.y = bg.y + healthBarYA;

		if (part2.w < 0) part2.w = 0;
	}

	/**
		Updates the health icons.
	**/
	function updateHealthIcons() {
		if (parent.disposed || parent.died) return;

		var part1 = parts[1];

		if (part1 == null) return;

		var health = parent.health;
		var icons = healthIcons;
		var ids = healthIconIDs;

		var iconP2 = icons[0];
		var iconP1 = icons[1];

		var iconP2 = healthIcons[0];
		iconP2.x = part1.x - 118;

		var iconP1 = healthIcons[1];
		iconP1.x = part1.x - 18;

		iconP2.y = iconP1.y = bg.y - 75;

		var oppIco = parent.flipHealthBar ? iconP1 : iconP2;
		var plrIco = parent.flipHealthBar ? iconP2 : iconP1;

		if (health > 0.75) oppIco.changeID(ids[0][1]);
		else oppIco.changeID(ids[0][0]);

		if (health < 0.25) plrIco.changeID(ids[1][1]);
		else plrIco.changeID(ids[1][0]);
	}

	/**
		Disposes the health bar.
	**/
	function dispose() {
		hbBuf.removeElement(bg);
		bg = null;

		while (parts.length != 0) {
			var healthBarPart = parts.pop();
			hbBuf.removeElement(healthBarPart);
		}
		parts = null;

		while (healthIcons.length != 0) {
			var healthIcon = healthIcons.pop();
			hbBuf.removeElement(healthIcon);
		}
		healthIcons = null;

		display.removeProgram(hbProg);
	}
}

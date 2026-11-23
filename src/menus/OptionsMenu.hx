package menus;

import underlying.overlay.OptionsDisplay.OptionsCategorySelection;
import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import handler.MenuInput;

/**
        The options submenu.
        This is where you can change the game's settings, such as controls, preferences, and gameplay options.
        It is responsible for rendering the options menu and updating it based on the player's input.

        The only navigation hint left is the tiny "tab" sprite pinned 5 pixels
        in from the top-right corner of the screen — TAB switches categories.
        (It replaces the old bottom navigation-hint text and the top-right
        description text.)
        @since Development
**/
@:publicFields
class OptionsMenu extends MenuInput {
        static var display(default, null):CustomDisplay;
        static var optionsBuf(default, null):Buffer<OptionsSprite>;
        static var optionsProg(default, null):CustomProgram;

        static inline var CATEGORY_COUNT = 4;

        // --- The "tab" hint sprite ---
        // A tiny pixel-art key cap pinned 5 pixels in from the top-right
        // corner of the options screen. It reads "tab", and TAB is the key
        // that switches categories.
        static inline var TAB_HINT_WIDTH = 15;
        static inline var TAB_HINT_HEIGHT = 7;
        static inline var TAB_HINT_MARGIN = 5;
        static inline var TAB_HINT_TEXTURE_NAME:String = "optionsTabHintPixelTex";
        static var tabHintBuf(default, null):Buffer<OptionsTabHintSprite>;
        static var tabHintProg(default, null):CustomProgram;
        static var tabHintSprite(default, null):OptionsTabHintSprite;

        var categoryNav(default, null):Navigation = new Navigation();
        var optionsNav(default, null):Navigation = new Navigation();

        var shiftHeld:Bool = false;
        var ctrlHeld:Bool = false;

        static var optionsDisplay(default, null):OptionsDisplay;

        static function init(disp:CustomDisplay) {
                display = disp;

                if (optionsBuf == null) {
                        optionsBuf = new Buffer<OptionsSprite>(15);
                        optionsProg = new CustomProgram(optionsBuf);

                        display.addProgram(optionsProg);
                        display.removeProgram(optionsProg);
                }

                createTabHint();
        }

        /** Creates a tiny pixel-art "tab" texture in code, like the noteskin grid. */
        static function createTabHint() {
                if (tabHintProg != null)
                        return;
                // Fail soft: the hint is purely cosmetic. If anything in the texture
                // or program setup goes wrong, disable it rather than crash the menu.
                try {
                        createTabHintUnsafe();
                } catch (e:Dynamic) {
                        tabHintProg = null;
                        tabHintBuf = null;
                        tabHintSprite = null;
                        trace('Warning: options tab hint disabled (' + e + ')');
                }
        }

        static function createTabHintUnsafe() {
                var width = TAB_HINT_WIDTH;
                var height = TAB_HINT_HEIGHT;
                var pixels = haxe.io.Bytes.alloc(width * height * 4);
                for (y in 0...height) {
                        for (x in 0...width) {
                                var idx = (y * width + x) * 4;
                                var border = x == 0 || y == 0 || x == width - 1 || y == height - 1;
                                pixels.set(idx, border ? 24 : 8);
                                pixels.set(idx + 1, border ? 24 : 8);
                                pixels.set(idx + 2, border ? 30 : 12);
                                pixels.set(idx + 3, 210);
                        }
                }
                // 3x5 lowercase glyphs: t, a, b. One-pixel spacing between letters.
                var glyphs:Array<Array<Int>> = [[6, 2, 2, 2, 3], [0, 6, 1, 7, 5], [4, 4, 6, 5, 6]];
                var glyphX = [2, 6, 10];
                for (g in 0...glyphs.length) {
                        for (gy in 0...5) {
                                for (gx in 0...3) {
                                        if ((glyphs[g][gy] & (1 << (2 - gx))) == 0)
                                                continue;
                                        var idx = ((gy + 1) * width + glyphX[g] + gx) * 4;
                                        pixels.set(idx, 235);
                                        pixels.set(idx + 1, 235);
                                        pixels.set(idx + 2, 245);
                                        pixels.set(idx + 3, 255);
                                }
                        }
                }
                var textureData = new TextureData(width, height, TextureFormat.RGBA);
                textureData.bytes = pixels;
                // Same manual-texture flow as the noteskin editor's grid texture: a
                // power-of-two texture with no eager GL binding — the texture binds to
                // the GL context lazily when its program is added to the display.
                var texture = new Texture(width, height, null, {
                        format: TextureFormat.RGBA,
                        powerOfTwo: true,
                        smoothExpand: false,
                        smoothShrink: false
                });
                texture.setData(textureData);
                TextureSystem.pool.set(TAB_HINT_TEXTURE_NAME, texture);

                tabHintBuf = new Buffer<OptionsTabHintSprite>(1);
                tabHintProg = new CustomProgram(tabHintBuf);
                OptionsTabHintSprite.init(tabHintProg, TAB_HINT_TEXTURE_NAME, texture);
                tabHintSprite = new OptionsTabHintSprite();
                tabHintSprite.x = Main.INITIAL_WIDTH - TAB_HINT_WIDTH - TAB_HINT_MARGIN;
                tabHintSprite.y = TAB_HINT_MARGIN;
                tabHintBuf.addElement(tabHintSprite);
                tabHintBuf.update();
        }

        function new() {
                if (optionsDisplay == null) {
                        optionsDisplay = new OptionsDisplay(this);
                }
                optionsDisplay.closed = false;
                optionsDisplay.reload(cast optionsNav.value());

                actions = [
                        Controls.Action.UI_LEFT => {action: left},
                        Controls.Action.UI_RIGHT => {action: right},
                        Controls.Action.UI_UP => {action: up},
                        Controls.Action.UI_DOWN => {action: down},
                        Controls.Action.UI_BACK => {action: back},
                        Controls.Action.UI_ACCEPT => {action: enter}
                ];
                mode = ControlsMode.OPTIONS;
        }

        var alphaLerp:Float = 0.0;

        override function update(deltaTime:Float) {
                // alphaLerp decays asymptotically and never reaches an exact 0.0, so shutting
                // down only at `== 0.0` would leave the options overlay rendering for minutes
                // (and thrashes CPU while playing a song). Tear it down once it's invisible.
                if (!opened && alphaLerp <= 0.001) {
                        shutDown();
                        return;
                }

                var ratio = Math.min(deltaTime * 0.015, 1.0);
                if (ratio == 1)
                        ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015; // When loading the options menu the first time it gets stuck at 1.0 for a single frame

                alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, ratio);

                // The "tab" hint fades in/out with the menu. While the controls
                // display is in mania binding mode the whole options display is
                // half-transparent to make room for the mania input readout —
                // the hint dims along with everything else.
                if (tabHintSprite != null && tabHintBuf != null) {
                        var dim = 1.0;
                        var cd = optionsDisplay != null ? optionsDisplay.controlsDisplay : null;
                        if (cd != null && cd.bindingMania)
                                dim = 0.5;
                        tabHintSprite.c.aF = alphaLerp * dim;
                        tabHintSprite.c.luminanceF = alphaLerp * dim;
                        tabHintBuf.updateElement(tabHintSprite);
                        tabHintBuf.update();
                }

                optionsDisplay.update(deltaTime);
        }

        override function open() {
                optionsDisplay.closed = false;
                active = opened = true;
                shiftHeld = false;
                Main.current.popupOptionsMenu();

                alphaLerp = 0.0;

                if (!optionsProg.isIn(display)) {
                        display.addProgram(optionsProg);
                }
                if (tabHintProg != null && !tabHintProg.isIn(display)) {
                        display.addProgram(tabHintProg);
                }

                Main.current.stateMachine.setFocus(this);
        }

        override function close() {
                var mm = Main.current.mainMenu;
                var pf = Main.current.playField;

                optionsDisplay.closed = true;

                if (mm != null) {
                        MainMenu.selectedAlpha = 1.0;
                        Main.current.stateMachine.setFocus(mm);
                } else if (pf != null) {
                        var pauseScreen = pf.pauseScreen;
                        Main.current.stateMachine.setFocus(null);
                        pauseScreen.onOptionsMenuClose();
                }

                opened = false;
        }

        function back(isDown:Bool, param:Int) {
                if (!isDown)
                        return;

                var controlsDisplay = optionsDisplay.controlsDisplay;

                // Make sure to cancel any active binding before closing
                if (controlsDisplay.binding || controlsDisplay.bindingMania) {
                        controlsDisplay.cancelBinding();
                        return;
                }

                close();
                Main.current.playCancelSound();
        }

        function getOptionCountofState() {
                var result = 0;

                switch ((categoryNav.value() : OptionsCategorySelection)) {
                        case CONTROLS:
                                result = ControlsDisplay.controlLabels.length;
                        case PREFERENCES:
                                result = PreferencesDisplay.prefsStr.length;
                        case GAMEPLAY:
                                result = GraphicsDisplay.graphicsStr.length;
                        case AUDIO:
                                result = AudioDisplay.audioStr.length;
                }

                return result;
        }

        inline function isInvalidKeyState() {
                var disp = optionsDisplay.controlsDisplay;
                return optionsDisplay != null && ((disp.binding || disp.bindingMania) && !disp.closed && !optionsDisplay.closed);
        }

        function down(isDown:Bool, param:Int) {
                if (!isDown || isInvalidKeyState())
                        return;
                optionsNav.scroll(1);
                var optionssLen = getOptionCountofState();
                optionsNav.resetIfOver(optionssLen);
                Main.current.playScrollSound();
        }

        function up(isDown:Bool, param:Int) {
                if (!isDown || isInvalidKeyState())
                        return;
                optionsNav.scroll(-1);
                var optionssLen = getOptionCountofState();
                optionsNav.resetIfUnder(optionssLen - 1);
                Main.current.playScrollSound();
        }

        function left(isDown:Bool, param:Int) {
                if (!isDown || isInvalidKeyState())
                        return;
                if (!ctrlHeld)
                        return;
                if (shiftHeld && (cast categoryNav.value() : OptionsCategorySelection) == GAMEPLAY)
                        return;
                switchCategory(-1);
        }

        function right(isDown:Bool, param:Int) {
                if (!isDown || isInvalidKeyState())
                        return;
                if (!ctrlHeld)
                        return;
                if (shiftHeld && (cast categoryNav.value() : OptionsCategorySelection) == GAMEPLAY)
                        return;
                switchCategory(1);
        }

        /**
                Switches to the next (dir = 1) / previous (dir = -1) options
                category and resets the option cursor. Used by TAB (the top-right
                "tab" hint) and the legacy CTRL+LEFT/RIGHT binds.
        **/
        function switchCategory(dir:Int) {
                optionsNav.setTo(0);
                categoryNav.scroll(dir);
                if (dir > 0)
                        categoryNav.resetIfOver(CATEGORY_COUNT);
                else
                        categoryNav.resetIfUnder(3);
                optionsDisplay.reload(cast categoryNav.value());
                Main.current.playScrollSound();
        }

        function enter(isDown:Bool, param:Int) {
                if (!isDown || isInvalidKeyState())
                        return;
                optionsDisplay.enter();
        }

        // --- Routed input (MenuInput) ---

        public override function onKeyDown(keyCode:KeyCode, keyModifier:KeyModifier):Bool {
                if (!active)
                        return false;

                if (keyCode == KeyCode.LEFT_SHIFT || keyCode == KeyCode.RIGHT_SHIFT)
                        shiftHeld = true;

                if (keyCode == KeyCode.LEFT_CTRL || keyCode == KeyCode.RIGHT_CTRL)
                        ctrlHeld = true;

                if (optionsDisplay.closed)
                        return false;

                // TAB switches categories (see the top-right "tab" hint).
                // While a keybinding listen is active on the controls display,
                // TAB stays owned by it (it exits mania binding / is ignored
                // mid-listen).
                if (keyCode == KeyCode.TAB) {
                        var cd = optionsDisplay.controlsDisplay;
                        if (cd == null || cd.closed || (!cd.binding && !cd.bindingMania)) {
                                switchCategory(shiftHeld ? -1 : 1);
                                return true;
                        }
                }

                var disp = optionsDisplay.controlsDisplay;
                if (disp != null && !disp.closed) {
                        disp.onKeyDown(keyCode, keyModifier);
                        return true;
                }

                var gfx = optionsDisplay.graphicsDisplay;
                if (gfx != null && !gfx.closed) {
                        gfx.onKeyDown(keyCode, keyModifier);
                        return true;
                }
                return false;
        }

        public override function onKeyUp(keyCode:KeyCode, keyModifier:KeyModifier):Bool {
                if (!active)
                        return false;
                if (keyCode == KeyCode.LEFT_SHIFT || keyCode == KeyCode.RIGHT_SHIFT)
                        shiftHeld = false;
                if (keyCode == KeyCode.LEFT_CTRL || keyCode == KeyCode.RIGHT_CTRL)
                        ctrlHeld = false;
                return false;
        }

        public override function onMouseDown(x:Float, y:Float, button:MouseButton):Bool {
                if (!active)
                        return false;

                var disp = optionsDisplay.activeDisplay;
                if (disp != null) {
                        if (disp.onMouseDown(x, y, button))
                                return true;

                        // Only the controls category falls back to the global click behavior
                        // (left = enter, right = close); the scrollable lists consume left
                        // clicks for dragging and don't react to right clicks.
                        switch ((categoryNav.value() : OptionsCategorySelection)) {
                                case CONTROLS:
                                        mousePress(x, y, button);
                                default:
                        }
                }
                return false;
        }

        public override function onMouseUp(x:Float, y:Float, button:MouseButton):Bool {
                if (!active)
                        return false;
                var disp = optionsDisplay.activeDisplay;
                if (disp != null) {
                        disp.onMouseUp(x, y, button);
                }
                return false;
        }

        public override function onMouseMove(x:Float, y:Float):Bool {
                if (!active)
                        return false;
                var disp = optionsDisplay.activeDisplay;
                if (disp != null) {
                        disp.onMouseMove(x, y);
                }
                return false;
        }

        public override function onMouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode):Bool {
                if (!active)
                        return false;
                if (Math.floor(deltaY) > 0) left(true, 0);
                else right(true, 0);
                return false;
        }

        function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
                if (isInvalidKeyState())
                        return;
                if (button == LEFT)
                        enter(true, 0);
                if (button != RIGHT)
                        return;
                close();
                Main.current.playScrollSound();
        }

        override function shutDown() {
                if (!optionsProg.isIn(display))
                        return;

                if (tabHintProg != null && tabHintProg.isIn(display))
                        display.removeProgram(tabHintProg);

                display.color = 0x00000000;
                display.removeProgram(optionsProg);

                active = false;
                Main.current.removeOptionsMenu();
        }

        override function dispose() {
                close();
                shutDown();

                optionsDisplay.dispose();

                disposed = true;
        }
}

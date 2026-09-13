package overlay;

import data.AudioOutput;
import data.SaveData;
import lime.ui.MouseButton;
import overlay.OptionsSubDisplay;
import rhythm.AudioSampleUnified;

/**
        Handles the display and interaction for the audio options in the
        options menu: the song mixer's Output mode (Stereo / Surround Sound
        3.1) and the gameplay hitsound toggle.
        The list is rendered through the shared FreeplayAlphabet, so the audio
        options behave exactly like the preferences/graphics lists.
        @since Development
**/
@:publicFields
class AudioDisplay extends OptionsSubDisplay {
        public static var audioStr(default, null):Array<String> = ["output", "hitsound"];

        // Descriptions for each audio option, in the same order.
        static var audioDescriptions:Array<String> = [
                "Chooses how the unified song mixer routes the inst and voices.\n\nStereo keeps the classic 2 channel mix, where every song track\nis folded into the front left/right pair.\n\nSurround Sound 3.1 widens the song into a 3.1 layout: the voices\nplay through the CENTER speaker, the instrumental stays wide on\nthe BACKGROUND front pair and the SUB channel carries the low end\nfor a deeper sounding mix.\n\nMusic and sound effects always remain stereo.",
                "Plays a cached hitsound.wav on every Sick or Good hit.\n\nThe sound is preloaded inside Main alongside the menu sounds,\nso triggering it never causes lagspikes."
        ];

        var parent(default, null):OptionsMenu;
        var options(default, null):Array<OptionsSprite> = [];
        var alphabet(default, null):FreeplayAlphabet; // shared instance
        var infoText(default, null):Text; // shared description text (owned by OptionsDisplay)

        var closed:Bool;

        //////////////////////// SCROLL (LIKE PHONE) ////////////////////////
        var isDragging:Bool = false;
        var dragStartY:Float = 0.0;
        var lastDragY:Float = 0.0;
        var dragAccum:Float = 0.0;
        var dragVelocity:Float = 0.0;
        var lastDragTime:Float = 0.0;

        private static inline var DRAG_THRESHOLD:Float = 1.0;

        // Cached last pushed info string (avoid per-frame Text relayout).
        var _lastInfoText:String = null;

        // Cached rendered list-row titles; rebuilt only when a value changes.
        var _titleCache:Array<String> = [];

        function new(parent:OptionsMenu, alphabet:FreeplayAlphabet, infoText:Text) {
                this.parent = parent;
                this.alphabet = alphabet;
                this.infoText = infoText;
        }

        function reload() {
                destroyOptions();
                alphabet.setHost(this); // set this display as the host
                alphabet.reload();
                closed = false;

                resetHostState();
                resetDragState();
                _lastInfoText = null;
                _titleCache = [];
        }

        function resetHostState() {
                xLerp = 0.0;
                curSelectedLerp = 0.0;
                curSelectedTarget = 0.0;
                alphaLerp = 0.0;
        }

        function resetDragState() {
                isDragging = false;
                dragAccum = 0.0;
                dragVelocity = 0.0;
        }

        override function update(deltaTime:Float) {
                if (alphabet == null || closed)
                        return;

                var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
                if (ratio == 1)
                        ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

                alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);

                if (!isDragging && Math.abs(dragVelocity) > 0.01) {
                        curSelectedTarget += (dragVelocity * deltaTime) / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT));
                        curSelectedTarget = Math.max(0, Math.min(audioStr.length - 1, curSelectedTarget));
                        parent.optionsNav.setTo(Math.round(curSelectedTarget));
                        dragVelocity *= Math.pow(0.92, deltaTime * 0.04);
                        if (Math.abs(dragVelocity) < 0.01)
                                dragVelocity = 0.0;
                }

                if (!isDragging && dragVelocity == 0.0) {
                        curSelectedTarget = parent.optionsNav.value();
                }

                curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
                xLerp = 20 - (curSelectedLerp * 20);

                // Update description text (shared infoText)
                var index = Math.round(curSelectedTarget);
                if (index >= 0 && index < audioStr.length) {
                        var name = getDisplayName(index);
                        var desc = audioDescriptions[index];
                        var value = getValueString(index);
                        var combined = '$name: $desc\nCurrent: $value\nPress ENTER to change.';

                        if (combined != _lastInfoText) {
                                _lastInfoText = combined;
                                infoText.text = combined;
                                // Position at top-right
                                infoText.x = Main.INITIAL_WIDTH - infoText.width - 4;
                                infoText.y = 4;
                        }
                } else {
                        if (_lastInfoText != "") {
                                _lastInfoText = "";
                                infoText.text = "";
                        }
                }

                // Fade text based on menu alpha
                var show = parent.opened && index >= 0 && index < audioStr.length;
                infoText.alpha = Tools.lerp(infoText.alpha, show ? 1.0 : 0.0, ratio);

                alphabet.setDeltaTime(deltaTime);
                var incrementBest = audioStr.length > 7 ? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), audioStr.length - 7)) : 0;

                for (i in 0...7) {
                        alphabet.updateRowText(i, incrementBest);
                }
                alphabet.buffer.update();
        }

        // -------------------- MOUSE HANDLERS (routed by OptionsMenu) --------------------

        public override function onMouseDown(x:Float, y:Float, button:MouseButton):Bool {
                if (closed || alphabet == null)
                        return false;
                switch (button) {
                        case LEFT:
                                isDragging = true;
                                dragStartY = y;
                                lastDragY = y;
                                dragAccum = 0.0;
                                dragVelocity = 0.0;
                                lastDragTime = haxe.Timer.stamp();
                                curSelectedTarget = curSelectedLerp;
                                return true;
                        default:
                }
                return false;
        }

        public override function onMouseUp(x:Float, y:Float, button:MouseButton):Bool {
                if (button != LEFT)
                        return false;
                if (closed || alphabet == null)
                        return false;

                if (isDragging && Math.abs(dragStartY - y) < 4.0) {
                        curSelectedTarget += 0.3;
                        enter();
                        curSelectedTarget -= 0.3;
                } else if (isDragging) {
                        var nearestIndex = Math.round(curSelectedTarget);
                        curSelectedTarget = nearestIndex;
                        parent.optionsNav.setTo(nearestIndex);
                }

                isDragging = false;
                dragAccum = 0.0;
                dragStartY = 0.0;
                lastDragY = 0.0;
                return true;
        }

        public override function onMouseMove(x:Float, y:Float):Bool {
                if (!isDragging || closed || alphabet == null)
                        return false;

                var delta = lastDragY - y;
                lastDragY = y;

                var now = haxe.Timer.stamp();
                var dt = now - lastDragTime;
                lastDragTime = now;

                var _delta = (delta / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT)));
                if (dt > 0)
                        dragVelocity = _delta / 3;

                curSelectedTarget += _delta;
                curSelectedTarget = Math.max(0, Math.min(audioStr.length - 1, curSelectedTarget));
                parent.optionsNav.setTo(Math.round(curSelectedTarget));
                return true;
        }

        // -------------------- END MOUSE HANDLERS --------------------

        function enter() {
                if (closed || alphabet == null)
                        return;

                var index = Math.floor(curSelectedTarget);
                if (index < 0 || index >= audioStr.length)
                        return;

                switch (audioStr[index]) {
                        case "output":
                                // Cycle the Output selector: Stereo <-> Surround Sound 3.1.
                                var next:AudioOutput = SaveData.state.audio.output == AudioOutput.SURROUND31 ? AudioOutput.STEREO : AudioOutput.SURROUND31;
                                AudioSampleUnified.applyOutput(next);
                                Main.current.playScrollSound();
                        case "hitsound":
                                SaveData.state.audio.hitsound = !SaveData.state.audio.hitsound;
                                SaveData.save();
                                Main.current.playCancelSound();
                }

                _lastInfoText = null;
                _titleCache = [];
                if (alphabet != null && !closed) {
                        alphabet.buffer.update();
                }
        }

        // -------------------- AUDIO SETTINGS --------------------

        function getValueString(index:Int):String {
                switch (audioStr[index]) {
                        case "output":
                                return SaveData.state.audio.output == AudioOutput.SURROUND31 ? "Surround Sound 3.1" : "Stereo";
                        case "hitsound":
                                return SaveData.state.audio.hitsound ? "ON" : "OFF";
                }
                return "";
        }

        function destroyOptions() {
                if (closed)
                        return;
                closed = true;

                resetHostState();
                resetDragState();

                // Remove only our own OptionsSprites, not the shared alphabet or infoText.
                while (options.length != 0) {
                        var option = options.pop();
                        try {
                                OptionsMenu.optionsBuf.removeElement(option);
                        } catch (e) {}
                }
        }

        function dispose() {
                destroyOptions();
                // Do not dispose infoText or alphabet – they are shared.
        }

        // AlphabetScrollHost implementation
        public override function alphabetListLength():Int {
                return audioStr.length;
        }

        public override function alphabetItemTitle(index:Int):String {
                if (index < 0 || index >= audioStr.length)
                        return "";
                if (index >= _titleCache.length || _titleCache[index] == null) {
                        var displayText = getDisplayName(index);
                        var str = displayText;
                        for (i in 0...Math.floor((14 - displayText.length) * 1.13))
                                str += " ";
                        str += " ";
                        str += getValueString(index);
                        _titleCache[index] = str;
                }
                return _titleCache[index];
        }

        function getDisplayName(index:Int):String {
                switch (audioStr[index]) {
                        case "output":
                                return "Output";
                        case "hitsound":
                                return "Toggle Hitsound";
                }
                return audioStr[index];
        }
}

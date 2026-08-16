package overlay;

/**
	Scroll state and list labels for menus like the freeplay menu, the credits menu, the options menu controls section, and of course, the mods menu.
	@since 0.94
**/
@:publicFields
class AlphabetScrollHost {
	var xLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var curSelectedTarget:Float = 0.0;
	var alphaLerp:Float = 0.0;

	function alphabetListLength():Int {
		return 0;
	}

	function alphabetItemTitle(index:Int):String {
		return "";
	}

	/**
		Returns true if the item at `index` should be displayed grayed out
		(meaning it's visible but not playable / selectable right now).
	**/
	function alphabetItemDisabled(index:Int):Bool {
		return false;
	}
}
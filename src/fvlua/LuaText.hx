package fvlua;

/**
    An extension to Text that adds control to remove from displays.
	@since Development
**/
@:publicFields
class LuaText extends Text
{
    var visibleToDisplays:Array<CustomDisplay> = [];
}
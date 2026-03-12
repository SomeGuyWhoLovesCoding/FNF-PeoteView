package fvlua;

/**
    An extension to Text that adds control to remove from displays.
**/
@:publicFields
class LuaText extends Text
{
    var visibleToDisplays:Array<CustomDisplay> = [];
}
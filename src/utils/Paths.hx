package utils;

using StringTools;

@:publicFields
class Paths {
	/**
	* Internal custom asset path, for modding.
	**/
	private static var customAssetPath(default, null):String = "";

	inline static function setAssetsFolder(val:String)
		customAssetPath = val.split("/")[0] + "/"; // Prevent multiple slashes

	inline static function asset(str:String) {
		if (customAssetPath != "") {
			var oldPath = str;
			str = str.replace("assets/", customAssetPath);
			if (!sys.FileSystem.exists(str)) str = oldPath; // if file doesn't exist in your modpack's path contents
		}
		return str;
	}
}
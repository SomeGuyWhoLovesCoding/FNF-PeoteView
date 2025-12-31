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

	static function asset(str:String) {
		var isAFontPath = str.contains("assets/fonts/");
		if (customAssetPath != "") {
			var oldPath = str;
			str = str.replace("assets/", customAssetPath);
			if (!sys.FileSystem.exists(str)) {
				str = oldPath; // if file doesn't exist in your modpack's path contents
				return str;
			}
			if (isAFontPath) {
				if (sys.FileSystem.exists(oldPath)) // make sure you automatically copy your custom font back to the main thing so fontbm can do the work there and not your custom folder
					sys.io.File.copy(str, oldPath);
				str = oldPath;
			}
		}
		return str;
	}
}
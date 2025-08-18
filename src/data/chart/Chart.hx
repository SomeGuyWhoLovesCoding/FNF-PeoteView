package data.chart;

import sys.FileSystem;

/**
	The chart.
**/
#if !debug
@:noDebug
#end
@:publicFields
class Chart {
	/**
		The chart's header content.
	**/
	static var header(default, null):Header;

	private static var destroyed(default, null):Bool = false;

	/**
		Constructs a chart from a ".cbin" file.
		@param path The path to the chart folder.
	**/
	static function load(path:String) {
		destroyed = false;
		trace('Parsing chart from folder...');

		if (FileSystem.exists('$path/chart.json')) {
			ChartConverter.baseGame(path);
		}

		header = Tools.parseHeader(path);

		var stamp = haxe.Timer.stamp();
		File.loadChart('$path/chart.cbin');
		trace('Done! Took ${Tools.formatTime((haxe.Timer.stamp() - stamp) * 1000.0, true)} to load.');
	}

	/**
		Destroys an already-existing chart. Self-explanatory.
	**/
	static function destroy() {
		trace('Destroying chart...');

		header = null;

		var stamp = haxe.Timer.stamp();
		File.destroyChart();
		destroyed = true;
		trace('Done! Took ${Tools.formatTime((haxe.Timer.stamp() - stamp) * 1000.0, true)} to destroy.');
	}
}
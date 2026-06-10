package data.chart;

import sys.FileSystem;

/**
	The chart class contains a very intruiging and mind-blowing feature called "Memory Mapping", located just deep into `data.chart.File`'s internal code.
	The new optimization makes it so the chart basically loads instantly instead of waiting a few minutes for eg. a 13.4 gigabyte of a chart to load.
	On top of that, a very special feature is put into place, called "shards", or 1/4 second segments of charts that make it easy to insert/remove notes
	@since Development
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
		Sys.println('  [ Chart System ]  Parsing chart(s) from folder...');

		if (FileSystem.exists('$path/chart.json') && (!FileSystem.exists('$path/chart.cbin')) || FileSystem.exists('$path/charts')) {
			ChartConverter.baseGame(path);
		}

		header = Tools.parseHeader(path);

		var stamp = haxe.Timer.stamp();
		File.loadChart('$path/chart');
		Sys.println('  [ Chart System ]  Done! Took ${Tools.formatTime((haxe.Timer.stamp() - stamp) * 1000.0, true)} to load.');
	}

	/**
		Destroys an already-existing chart. Self-explanatory.
	**/
	static function destroy() {
		Sys.println('  [ Chart System ]  Destroying chart...');

		header = null;

		var stamp = haxe.Timer.stamp();
		File.destroyChart();
		destroyed = true;
		Sys.println('  [ Chart System ]  Done! Took ${Tools.formatTime((haxe.Timer.stamp() - stamp) * 1000.0, true)} to destroy.');
	}
}
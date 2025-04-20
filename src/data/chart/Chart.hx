package data.chart;

import sys.FileSystem;
import haxe.io.Bytes;

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
	var header(default, null):Header;

	/**
		The chart file where every note is read and parsed to a playable song.
	**/
	var file(default, null):File;

	/**
		Constructs a chart.
		@param path The path to the chart folder.
	**/
	function new(path:String) {
		trace('Parsing chart from folder...');

		if (FileSystem.exists('$path/chart.json')) {
			ChartConverter.baseGame(path);
		}

		header = ChartSystem.parseHeader(path);

		var stamp = haxe.Timer.stamp();
		file = new File('$path/chart.cbin');
		trace('Done! Took ${Tools.formatTime((haxe.Timer.stamp() - stamp) * 1000.0, true)} to load.');
	}
}
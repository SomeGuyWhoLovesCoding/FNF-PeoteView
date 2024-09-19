package music.chart;

import sys.io.File;

using StringTools;

/**
	The chart.
**/
#if !debug
@:noDebug
#end
@:publicFields
class Chart {
	/**
		The chart's header.
		This can be generated by the `parseHeader` function.
	**/
	var header(default, null):ChartHeader;

	/**
		The chart's bytes.
	**/
	var bytes(default, null):Array<ChartNote>;

	/**
		Constructs a chart.
		@param path The path to the chart folder.
	**/
	function new(path:String) {
		header = ChartSystem.parseHeader('$path/header.txt');
		trace(header);

		//bytes = ChartSystem._file_contents_chart('$path/chart.bin');
	}
}
package structures.gameplay;

import haxe.Json;
import sys.io.File;
import haxe.ds.ArraySort;
using StringTools;

/**
    A mimimal event system for Funkin' View, only using struct objects.
    @since 0.94
**/
@:publicFields
class EventSystem {
    var parsedObjects(default, null):Array<EventObject>;
    var parent(default, null):PlayField;

    var nextEventTime:Float = Math.POSITIVE_INFINITY;
    var lastTriggeredIndex:Int = -1;

    var eventTimers(default, null):Array<EventTimer>;

    function new(parent:PlayField) {
        this.parent = parent;
        parsedObjects = [];
        eventTimers = [];
        parent.scanForEventFile(this);
    }

    function init() {
        ArraySort.sort(parsedObjects, function(a, b) {
            if (a.evTime < b.evTime) return -1;
            if (a.evTime > b.evTime) return 1;
            return 0;
        });
        
        if (parsedObjects.length > 0) {
            nextEventTime = parsedObjects[0].evTime;
        }
    }

    /**
     * Binary search to find the index of the first event strictly greater than currentTime.
     * All events before this index are <= currentTime and should be triggered.
     */
    inline function binarySearchNext(currentTime:Float):Int {
        var low = 0;
        var high = parsedObjects.length;
        
        while (low < high) {
            var mid = (low + high) >>> 1;
            if (parsedObjects[mid].evTime <= currentTime) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    function update(deltaTime:Float, songTime:Float) {
        if (songTime >= nextEventTime) {
            var cutoffIndex = binarySearchNext(songTime);
            
            for (i in (lastTriggeredIndex + 1)...cutoffIndex) {
                var ev = parsedObjects[i];
                triggerEvent(ev);
            }
            
            lastTriggeredIndex = cutoffIndex - 1;
            
            if (cutoffIndex < parsedObjects.length) {
                nextEventTime = parsedObjects[cutoffIndex].evTime;
            } else {
                nextEventTime = Math.POSITIVE_INFINITY; // No more events left in the song
            }
        }

        for (timer in eventTimers) {
            if (songTime < timer.startTime || songTime > timer.endTime) continue;
            processEventTimer(timer);
        }
    }

    /**
     * If the song time jumps (e.g. seeking in editor, or a massive resync), 
     * use binary search to instantly reset the state without a linear scan.
     */
    function seek(time:Float) {
        lastTriggeredIndex = binarySearchNext(time) - 1;
        
        if (lastTriggeredIndex + 1 < parsedObjects.length) {
            nextEventTime = parsedObjects[lastTriggeredIndex + 1].evTime;
        } else {
            nextEventTime = Math.POSITIVE_INFINITY;
        }
    }

    var persistentShake:Vec2;

    function triggerEvent(ev:EventObject) {
        Sys.println('${ev.evName} triggered [${ev.value1}, ${ev.value2}]');
        var value1 = Std.parseFloat(ev.value1.trim());
        var value2 = Std.parseFloat(ev.value2.trim());

        #if linc_luajit_funkinview
        if (parent.funkinviewlua != null) parent.funkinviewlua.callFunction('preTriggerEvent', ev.evName, ev.value1, ev.value2);
        #end

        if (parent.display == null) return;
        var display = parent.display;
        if (parent.view == null) return;
        var view = parent.view;

        switch(ev.evName) {
            case "Camera Zoom" | "Add Camera Zoom":
                view.fov += Math.isNaN(value1) ? 0.015 : value1;
                display.fov += Math.isNaN(value2) ? 0.003 : value2;

			case 'Change Scroll Speed':
                if (Math.isNaN(value1)) value1 = 1;
                parent.scrollSpeed = value1;

            case "Screen Shake":
                //if (Math.isNaN(value1)) value1 = 0;
                //if (Math.isNaN(value2)) value2 = 0;

                var time = Std.parseFloat(ev.value2.split(',')[0]);
                if (Math.isNaN(time)) time = 0;

                eventTimers.push(new EventTimer(
                    ev.evTime,
                    ev.evTime + (time * 1000.0),
                    ev,
                    (ev) -> {
                        Sys.println('  [ Event System ] Screen shake is done! It lasted about ${Math.round(value2/1000)} seconds.');
                    }
                ));
        }

        #if linc_luajit_funkinview
        if (parent.funkinviewlua == null) return;
        parent.funkinviewlua.callFunction('triggerEvent', ev.evName, ev.value1, ev.value2);
        #end
    }

	// For Screen Shake event
	var additiveDispShake:Point = {x: 0, y: 0, isSmooth: true};
	var additiveViewShake:Point = {x: 0, y: 0, isSmooth: true};

    function processEventTimer(eventTimer:EventTimer) {
        var ev = eventTimer.eventObject;
        var value1 = ev.value1;
        var value2 = ev.value2;
        //trace("Event timer screen shake?");

        switch (ev.evName) {
            case "Screen Shake":
                if (parent.display == null) return;
                var display = parent.display;
                if (parent.view == null) return;
                var view = parent.view;

                var v1split = value1.split(',');
                var v2split = value2.split(',');
                var dispSplit:Float = Std.parseFloat(v1split[1].trim());
                var viewSplit:Float = Std.parseFloat(v2split[1].trim());
                if (Math.isNaN(dispSplit)) dispSplit = 0;
                if (Math.isNaN(viewSplit)) viewSplit = 0;

                var xAxesDisp = v1split.length == 4 ? v1split[2] != null ? -1 : 0 : -1;
                var yAxesDisp = v1split.length == 4 ? v1split[3] != null ? -1 : 0 : -1;
                var xAxesView = v2split.length == 4 ? v2split[2] != null ? -1 : 0 : -1;
                var yAxesView = v2split.length == 4 ? v2split[3] != null ? -1 : 0 : -1;

                // &ing 0 turns every value you and into zero and I think that's sick
                var axesXDisp = (dispSplit / 16) * (display.width & xAxesDisp);
                var axesYDisp = (dispSplit / 16) * (display.height & yAxesDisp);
                var axesXView = (viewSplit / 16) * (view.width & xAxesView);
                var axesYView = (viewSplit / 16) * (view.height & yAxesView);

                parent.additiveDispShake.x += axesXDisp;
                parent.additiveDispShake.y += axesYDisp;
                parent.additiveViewShake.x += axesXView;
                parent.additiveViewShake.y += axesYView;
        }
    }

    function clearEventTimers() {
        while (eventTimers.pop() != null) {}
    }
}

/**
    Small event object made into a struct.
**/
#if cpp
@:unreflective
#end
@:struct
@:publicFields
class EventObject {
    var evName:String;
    var value1:Value1;
    var value2:Value2;
    var evTime:Double;

    function new(v1:String, v2:Value1, v3:Value2, v4:Double) {
        evName = v1;
        value1 = v2;
        value2 = v3;
        evTime = v4;
    }
}

@:publicFields
typedef RawEventObject = {
    var evName:String;
    var value1:Value1;
    @:optional
    var value2:Value2;
    var evTime:Double;
}

typedef Value1 = String;
typedef Value2 = String;
typedef Double = #if cpp cpp.Float64 #else Float #end;
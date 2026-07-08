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

    function new(parent:PlayField) {
        this.parent = parent;
        parsedObjects = [];
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

    function triggerEvent(ev:EventObject) {
        //Sys.println('$evName triggered [$value1, $value2]');
        switch(ev.evName) {
            case "Hey!":
                if (parent.field == null) return;
                var field = parent.field;

                var charsToDoIt:Array<Actor> = [field.player, field.spectator];
                switch(ev.value1.toLowerCase().trim()) {
                    case 'bf' | 'boyfriend' | '0': charsToDoIt.pop();
                    case 'gf' | 'girlfriend' | '1': charsToDoIt.shift();
                }

                var time:Float = Std.parseFloat(ev.value2);
                if(Math.isNaN(time) || time <= 0) time = 0.6;

                parent.eventTimers.push({
                    startTime: ev.evTime,
                    endTime: ev.evTime + time * 1000.0,
                    finishCallback: (ev) -> {
                        for (chars in charsToDoIt) chars.
                    }
                });

            case "Camera Zoom" | "Add Camera Zoom":
                
        }
			
        #if linc_luajit_funkinview
        if (parent.funkinviewlua == null) return;
        parent.funkinviewlua.callFunction('triggerEvent', evName, value1, value2);
        #end
    }

    function processEventTimer(evName:String) {
        
    }
}

/**
    Small event object made into a struct.
**/
@:structInit
@:publicFields
class EventObject {
    var evName:String;
    var value1:Value1;
    var value2:Value2;
    var evTime:Double;
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
package data.chart;

class ChartMetaNote {
    var note:MetaNote;
    var index:Int64;

    public function new(data:MetaNote) {
        note = data;
        index = File.findNoteIndexByTime(note);
    }
}
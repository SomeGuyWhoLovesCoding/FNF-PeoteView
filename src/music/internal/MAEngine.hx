#if !doc_gen
package music.internal;

@:buildXml('<include name="../../../src/music/internal/ma/MiniAudioBuild.xml" />')
@:include("miniaudio.h")
@:unreflective
@:structAccess
@:keep
@:native("ma_engine")
extern class MAEngine {}
#end
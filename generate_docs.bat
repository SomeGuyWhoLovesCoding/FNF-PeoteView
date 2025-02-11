@echo off
echo ONLY USE THIS IF YOU HAVE HAXE INSTALLED ON YOUR SYSTEM!
echo (This also builds the game for you.)
echo.
timeout /t 1 /nobreak >nul
haxelib install dox
haxelib install hxargs
lime build windows -xml -D FV_BIG_BYTES
haxelib run dox -o bin/api -i bin/windows/types.xml -in system -in elements -in utils -in music -in structures -in data
cd ./bin/api
index.html

echo Done!
sudo apt-get install libc6-dev-i386
export LIBRARY_PATH=/usr/lib/$(gcc -print-multiarch)
export C_INCLUDE_PATH=/usr/include/$(gcc -print-multiarch)
export CPLUS_INCLUDE_PATH=/usr/include/$(gcc -print-multiarch)
sudo apt-get install g++-multilib
sudo apt install libx11-dev
sudo apt install libxrandr-dev
sudo apt-get install libxinerama-dev
sudo apt-get install libgl1-mesa-dev
sudo apt-get install libwayland-dev
sudo apt-get install libasound2-dev
haxelib setup ~/haxelib
haxelib install format --quiet
haxelib install hxp --quiet
haxelib install hxcpp > /dev/null --quiet
haxelib git lime https://github.com/SomeGuyWhoLovesCoding/lime.git --quiet
haxelib install peote-view --quiet
haxelib install input2action --quiet
haxelib install customtitlebar --quiet
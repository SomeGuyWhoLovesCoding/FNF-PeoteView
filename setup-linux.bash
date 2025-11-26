# this is needed for installing libdrm-dev to work
sudo sed -i 's/security.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list
sudo apt-get update

sudo apt-get install libc6-dev-i386
export LIBRARY_PATH=/usr/lib/$(gcc -print-multiarch)
export C_INCLUDE_PATH=/usr/include/$(gcc -print-multiarch)
export CPLUS_INCLUDE_PATH=/usr/include/$(gcc -print-multiarch)
sudo apt-get install g++-multilib
sudo apt install libx11-dev
sudo apt install libxrandr-dev
sudo apt-get install libxinerama-dev
sudo apt-get install libgl-dev
sudo apt-get install libgl1-mesa-dev
sudo apt-get install libasound2-dev
sudo apt-get install libdrm2 libdrm-common libdrm-dev

# This shit is fucking important
sudo dpkg --add-architecture i386
sudo apt update
sudo apt-get install libgl-dev:i386
sudo apt-get install libgl1-mesa-dev:i386
sudo apt-get install libglu1-mesa-dev:i386
sudo apt-get install libdrm2:i386 libdrm-common libdrm-dev:i386

# Now onto the shit we actually want to do on our end
haxelib setup ~/haxelib
haxelib install format --quiet
haxelib install hxp --quiet
haxelib install hxcpp --quiet
haxelib git lime https://github.com/SomeGuyWhoLovesCoding/lime.git --quiet
haxelib install peote-view --quiet
haxelib install input2action --quiet
haxelib install customtitlebar --quiet
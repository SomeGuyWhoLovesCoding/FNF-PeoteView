# Fix repositories and update
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list
sudo apt-get update

# Install 64-bit dependencies
sudo apt-get install libc6-dev-i386
export LIBRARY_PATH=/usr/lib/$(gcc -print-multiarch)
export C_INCLUDE_PATH=/usr/include/$(gcc -print-multiarch)
export CPLUS_INCLUDE_PATH=/usr/include/$(gcc -print-multiarch)
sudo apt-get install g++-multilib
sudo apt install libx11-dev libxrandr-dev libxinerama-dev

# Install 64-bit graphics libraries (without version pinning)
sudo apt-get install libgl-dev libgl1-mesa-dev libasound2-dev
sudo apt-get install libdrm-dev libgbm-dev mesa-common-dev libegl1-mesa-dev libgles2-mesa-dev

# Add i386 architecture and install 32-bit libraries
sudo dpkg --add-architecture i386
sudo apt update
sudo apt-get install libgl-dev:i386 libgl1-mesa-dev:i386 libglu1-mesa-dev:i386
sudo apt-get install libdrm-dev:i386 libgbm-dev:i386 mesa-common-dev:i386 libegl1-mesa-dev:i386 libgles2-mesa-dev:i386

# Fix both headers and create symlinks
sudo sed -i 's|<drm_mode.h>|<libdrm/drm_mode.h>|' /usr/include/xf86drmMode.h && \
sudo sed -i 's|<drm.h>|<libdrm/drm.h>|' /usr/include/xf86drm.h && \
sudo ln -sf /usr/include/libdrm/drm_mode.h /usr/include/drm_mode.h && \
sudo ln -sf /usr/include/libdrm/drm.h /usr/include/drm.h

haxelib setup ~/haxelib
haxelib install format --quiet
haxelib install hxp --quiet
haxelib install hxcpp > /dev/null --quiet
haxelib git lime https://github.com/SomeGuyWhoLovesCoding/lime.git --quiet
haxelib install peote-view --quiet
haxelib install input2action --quiet
haxelib git customtitlebar https://github.com/SomeGuyWhoLovesCoding/customtitlebar.git --quiet
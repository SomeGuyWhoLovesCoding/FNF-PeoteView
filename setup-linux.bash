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

# Step 1: Find all relevant files
echo "=== Finding xf86drm.h ==="
find /usr -name "xf86drm.h" 2>/dev/null

echo "=== Finding drm.h ==="
find /usr -name "drm.h" 2>/dev/null

echo "=== Checking libdrm directory ==="
ls -la /usr/include/libdrm/ 2>/dev/null || echo "libdrm directory not found"

# Step 2: Apply the fix based on what we find
if [ -f "/usr/include/xf86drm.h" ]; then
    echo "Fixing /usr/include/xf86drm.h"
    sudo sed -i 's|<drm.h>|<libdrm/drm.h>|' /usr/include/xf86drm.h
elif [ -f "/usr/include/x86_64-linux-gnu/xf86drm.h" ]; then
    echo "Fixing /usr/include/x86_64-linux-gnu/xf86drm.h"
    sudo sed -i 's|<drm.h>|<libdrm/drm.h>|' /usr/include/x86_64-linux-gnu/xf86drm.h
fi

# Step 3: Create symlink if needed
if [ -f "/usr/include/libdrm/drm.h" ] && [ ! -f "/usr/include/drm.h" ]; then
    echo "Creating symlink from /usr/include/libdrm/drm.h to /usr/include/drm.h"
    sudo ln -s /usr/include/libdrm/drm.h /usr/include/drm.h
fi

# Continue with your haxe setup
haxelib setup ~/haxelib
haxelib install format --quiet
haxelib install hxp --quiet
haxelib install hxcpp --quiet
haxelib git lime https://github.com/SomeGuyWhoLovesCoding/lime.git --quiet
haxelib install peote-view --quiet
haxelib install input2action --quiet
haxelib install customtitlebar --quiet
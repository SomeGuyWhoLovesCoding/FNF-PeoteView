#!/bin/bash
# setup-linux.sh - Optimized parallel haxelib installer

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

trap 'log_error "Script failed on line $LINENO. Exit code: $?"' ERR

log_info "Starting Linux setup..."

# Fix repositories
log_info "Fixing repository URLs..."
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list

# Start apt update
log_info "Running apt update..."
sudo apt-get update

# Install dependencies sequentially
log_info "Installing 64-bit dependencies..."
sudo apt-get install -y libc6-dev-i386 g++-multilib
sudo apt install -y libx11-dev libxrandr-dev libxinerama-dev
sudo apt-get install -y libgl-dev libgl1-mesa-dev libasound2-dev
sudo apt-get install -y libdrm-dev libgbm-dev mesa-common-dev libegl1-mesa-dev libgles2-mesa-dev

# Setup i386
log_info "Setting up i386 architecture..."
sudo dpkg --add-architecture i386
sudo apt update

# Install 32-bit dependencies
log_info "Installing 32-bit dependencies..."
sudo apt-get install -y libgl-dev:i386 libgl1-mesa-dev:i386 libglu1-mesa-dev:i386
sudo apt-get install -y libdrm-dev:i386 libgbm-dev:i386 mesa-common-dev:i386 libegl1-mesa-dev:i386 libgles2-mesa-dev:i386

# Fix DRM headers
log_info "Fixing DRM headers..."
sudo sed -i 's|<drm_mode.h>|<libdrm/drm_mode.h>|' /usr/include/xf86drmMode.h || true
sudo sed -i 's|<drm.h>|<libdrm/drm.h>|' /usr/include/xf86drm.h || true
sudo ln -sf /usr/include/libdrm/drm_mode.h /usr/include/drm_mode.h || true
sudo ln -sf /usr/include/libdrm/drm.h /usr/include/drm.h || true

# Setup haxelib
log_info "Setting up haxelib..."
haxelib setup ~/haxelib

# Install haxelib dependencies
log_info "Installing haxelib dependencies..."

# Install hxcpp and lime sequentially (they have dependencies and compilation)
log_info "Installing hxcpp (sequential)..."
haxelib git hxcpp https://github.com/SomeGuyWhoLovesCoding/hxcpp-sgwlfnf.git --quiet

log_info "Installing lime (sequential - depends on hxcpp)..."
haxelib git lime https://github.com/SomeGuyWhoLovesCoding/lime.git --quiet

# Everything else can be parallel (no conflicts with each other)
log_info "Installing remaining haxelibs in parallel..."
haxelib install format --quiet &
PID_FORMAT=$!
haxelib install hxp --quiet &
PID_HXP=$!
haxelib git peote-view_funkinview https://github.com/SomeGuyWhoLovesCoding/peote-view.git --quiet &
PID_PEOTE=$!
haxelib install input2action --quiet &
PID_INPUT2ACTION=$!
haxelib git customtitlebar https://github.com/SomeGuyWhoLovesCoding/customtitlebar.git --quiet &
PID_CUSTOM=$!

# Wait for all parallel installations to complete
wait $PID_FORMAT $PID_HXP $PID_PEOTE $PID_INPUT2ACTION $PID_CUSTOM

log_info "All haxelib installations completed successfully!"
log_info "Linux setup complete! 🎉"
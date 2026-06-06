#!/bin/bash
# setup-linux.sh - Parallel Linux dependency installer

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

# Better error tracing
trap 'log_error "Script failed on line $LINENO. Exit code: $?"' ERR

log_info "Starting Linux setup..."

# Fix repositories
log_info "Fixing repository URLs..."
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list || {
    log_error "Failed to fix repository URLs"
    exit 1
}

# Start apt update
log_info "Running apt update..."
sudo apt-get update || {
    log_error "apt update failed"
    exit 1
}

# Install dependencies sequentially (more reliable than parallel)
log_info "Installing 64-bit dependencies..."
sudo apt-get install -y libc6-dev-i386 g++-multilib || exit 1
sudo apt install -y libx11-dev libxrandr-dev libxinerama-dev || exit 1
sudo apt-get install -y libgl-dev libgl1-mesa-dev libasound2-dev || exit 1
sudo apt-get install -y libdrm-dev libgbm-dev mesa-common-dev libegl1-mesa-dev libgles2-mesa-dev || exit 1

# Setup i386
log_info "Setting up i386 architecture..."
sudo dpkg --add-architecture i386 || exit 1
sudo apt update || exit 1

# Install 32-bit dependencies
log_info "Installing 32-bit dependencies..."
sudo apt-get install -y libgl-dev:i386 libgl1-mesa-dev:i386 libglu1-mesa-dev:i386 || exit 1
sudo apt-get install -y libdrm-dev:i386 libgbm-dev:i386 mesa-common-dev:i386 libegl1-mesa-dev:i386 libgles2-mesa-dev:i386 || exit 1

# Fix DRM headers
log_info "Fixing DRM headers..."
sudo sed -i 's|<drm_mode.h>|<libdrm/drm_mode.h>|' /usr/include/xf86drmMode.h || true
sudo sed -i 's|<drm.h>|<libdrm/drm.h>|' /usr/include/xf86drm.h || true
sudo ln -sf /usr/include/libdrm/drm_mode.h /usr/include/drm_mode.h || true
sudo ln -sf /usr/include/libdrm/drm.h /usr/include/drm.h || true

# Setup haxelib
log_info "Setting up haxelib..."
haxelib setup ~/haxelib || exit 1

# Install haxelib dependencies in parallel
log_info "Installing haxelib dependencies in parallel..."

# Run all haxelib installs in background
haxelib install format --quiet &
PID_FORMAT=$!
log_info "Installing format (PID: $PID_FORMAT)"

haxelib install hxp --quiet &
PID_HXP=$!
log_info "Installing hxp (PID: $PID_HXP)"

haxelib install hxcpp --quiet &
PID_HXCPP=$!
log_info "Installing hxcpp (PID: $PID_HXCPP)"

haxelib git lime https://github.com/SomeGuyWhoLovesCoding/lime.git --quiet &
PID_LIME=$!
log_info "Installing lime from git (PID: $PID_LIME)"

haxelib install peote-view --quiet &
PID_PEOTE=$!
log_info "Installing peote-view (PID: $PID_PEOTE)"

haxelib install input2action --quiet &
PID_INPUT2ACTION=$!
log_info "Installing input2action (PID: $PID_INPUT2ACTION)"

haxelib git customtitlebar https://github.com/SomeGuyWhoLovesCoding/customtitlebar.git --quiet &
PID_CUSTOMTITLEBAR=$!
log_info "Installing customtitlebar from git (PID: $PID_CUSTOMTITLEBAR)"

# Wait for all haxelib installations to complete
log_info "Waiting for all haxelib installations to finish..."
wait $PID_FORMAT $PID_HXP $PID_HXCPP $PID_LIME $PID_PEOTE $PID_INPUT2ACTION $PID_CUSTOMTITLEBAR

log_info "All haxelib installations completed successfully"
log_info "Linux setup complete! 🎉"
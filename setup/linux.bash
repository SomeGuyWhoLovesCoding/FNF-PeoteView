#!/bin/bash
# setup-linux.sh - Parallel Linux dependency installer for FNF Build

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Error handling
trap 'log_error "Script failed on line $LINENO"; exit 1' ERR

log_info "Starting parallel Linux dependency installation..."

# Fix repositories
log_info "Fixing repository URLs..."
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list

# Start parallel processes
log_info "Starting parallel apt installations..."

# Start update in background
sudo apt-get update &
PID_UPDATE=$!
log_info "Started apt update (PID: $PID_UPDATE)"

# Start parallel apt installs immediately (they'll wait for dpkg lock)
sudo apt-get install -y libc6-dev-i386 g++-multilib &
PID_BASE=$!
log_info "Started base deps installation (PID: $PID_BASE)"

sudo apt install -y libx11-dev libxrandr-dev libxinerama-dev &
PID_X11=$!
log_info "Started X11 deps installation (PID: $PID_X11)"

sudo apt-get install -y libgl-dev libgl1-mesa-dev libasound2-dev &
PID_GRAPHICS=$!
log_info "Started graphics deps installation (PID: $PID_GRAPHICS)"

sudo apt-get install -y libdrm-dev libgbm-dev mesa-common-dev libegl1-mesa-dev libgles2-mesa-dev &
PID_DRM=$!
log_info "Started DRM deps installation (PID: $PID_DRM)"

# Wait for update to complete first
log_info "Waiting for apt update to complete..."
wait $PID_UPDATE
log_info "apt update completed successfully"

# Setup i386 architecture
log_info "Adding i386 architecture..."
sudo dpkg --add-architecture i386

# Update for i386 packages
log_info "Updating package list for i386..."
sudo apt update &
PID_UPDATE_I386=$!
log_info "Started i386 apt update (PID: $PID_UPDATE_I386)"

# Start 32-bit installations
sudo apt-get install -y libgl-dev:i386 libgl1-mesa-dev:i386 libglu1-mesa-dev:i386 &
PID_GRAPHICS_32=$!
log_info "Started 32-bit graphics deps installation (PID: $PID_GRAPHICS_32)"

sudo apt-get install -y libdrm-dev:i386 libgbm-dev:i386 mesa-common-dev:i386 libegl1-mesa-dev:i386 libgles2-mesa-dev:i386 &
PID_DRM_32=$!
log_info "Started 32-bit DRM deps installation (PID: $PID_DRM_32)"

# Wait for i386 update
wait $PID_UPDATE_I386
log_info "i386 apt update completed"

# Wait for all apt installations to complete
log_info "Waiting for all apt installations to finish..."
wait $PID_BASE $PID_X11 $PID_GRAPHICS $PID_DRM $PID_GRAPHICS_32 $PID_DRM_32
log_info "All apt installations completed successfully"

# Fix DRM headers
log_info "Fixing DRM headers..."
sudo sed -i 's|<drm_mode.h>|<libdrm/drm_mode.h>|' /usr/include/xf86drmMode.h
sudo sed -i 's|<drm.h>|<libdrm/drm.h>|' /usr/include/xf86drm.h
sudo ln -sf /usr/include/libdrm/drm_mode.h /usr/include/drm_mode.h
sudo ln -sf /usr/include/libdrm/drm.h /usr/include/drm.h
log_info "DRM headers fixed"

# Setup haxelib
log_info "Setting up haxelib..."
haxelib setup ~/haxelib

# Run haxelib installs in parallel
log_info "Starting parallel haxelib installations..."

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
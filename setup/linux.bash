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
sudo apt-get install -y libgbm-dev mesa-common-dev libegl1-mesa-dev libgles2-mesa-dev

# Setup i386
log_info "Setting up i386 architecture..."
sudo dpkg --add-architecture i386
sudo apt update

# Install 32-bit dependencies
log_info "Installing 32-bit dependencies..."
sudo apt-get install -y libgl-dev:i386 libgl1-mesa-dev:i386 libglu1-mesa-dev:i386
sudo apt-get install -y libgbm-dev:i386 mesa-common-dev:i386 libegl1-mesa-dev:i386 libgles2-mesa-dev:i386\

# Setup haxelib
log_info "Setting up haxelib..."
haxelib setup ~/haxelib

# Install haxelib dependencies
log_info "Installing haxelib dependencies..."

# Step 1: Install hxcpp (required by lime)
log_info "Installing hxcpp..."
haxelib git hxcpp https://github.com/SomeGuyWhoLovesCoding/hxcpp-sgwlfnf.git --quiet

# Step 2: Install lime (required by hxp and input2action)
log_info "Installing lime..."
haxelib git lime https://github.com/SomeGuyWhoLovesCoding/lime.git --quiet

# Step 3: Install packages that depend on lime (cannot be parallel with each other)
log_info "Installing hxp (depends on lime)..."
haxelib install hxp --quiet

log_info "Installing input2action (depends on lime)..."
haxelib install input2action --quiet

# Step 4: Everything else can be parallel (no conflicts)
log_info "Installing remaining haxelibs in parallel..."
haxelib install format --quiet &
PID_FORMAT=$!
haxelib git linc_luajit_funkinview https://github.com/SomeGuyWhoLovesCoding/linc_luajit_funkinview.git --quiet --quiet &
PID_LUAJIT=$!
haxelib install peote-view 1.0.8 --quiet &
PID_PEOTE=$!
haxelib git customtitlebar https://github.com/SomeGuyWhoLovesCoding/customtitlebar.git --quiet &
PID_CUSTOM=$!

# Wait for all parallel installations to complete
wait $PID_FORMAT $PID_LUAJIT $PID_PEOTE $PID_CUSTOM

log_info "All haxelib installations completed successfully!"
log_info "Linux setup complete! 🎉"
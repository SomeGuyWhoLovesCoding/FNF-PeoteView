sudo apt install build-essential
sudo apt install libx11-dev
sudo apt install libxinerama-dev
sudo apt install libxrandr-dev
sudo apt install mesa-common-dev
sudo apt install libglu1-mesa-dev
sudo apt install libxi-dev
sudo apt install libasound2-dev
sudo apt install git
cd "/home/$USER/haxe-manager-master"
git clone --recursive https://github.com/kLabz/haxe-manager.git
export PATH "/home/$USER/haxe-manager-master/bin/$PATH"
export HAXE_STD_PATH "/home/$USER/haxe-manager-master/bin/std"
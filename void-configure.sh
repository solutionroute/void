#!/usr/bin/env bash
# script to automate (re)installation on Void Linux
# quit on any error
set -e
INSTALL_TYPE=""
# install script location
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# answer Yes
INSTALLER="xbps-install -y"
TRUSTED_USER=""

main() {
	# Must be root
	if [ "$(id -u)" -ne 0 ]; then
		echo 'ERROR: This script must be run by root, aborting.' >&2
		exit 1
	fi
	usage
	if ask "Abort the installation process?" N; then
		exit
	fi
	if ask "Is this a desktop? (no, for server)" Y; then
		INSTALL_TYPE="desktop"
	else
		INSTALL_TYPE="server"
	fi
	echo "Provide the username of your trusted (sudo) principal user."
	read -p "Username: " TRUSTED_USER

	# first update xbps and installed packages
	initial_update_and_firmware
	# step by step following Void Handbook
	configuration
	# add some tools like neovim
	quality_of_life
	# ensure user(s) added to the right groups
	setup_users
	# connectivity may be lost, so last
	finalize_network_and_reboot
}

usage() {
	cat <<EOF
Void Quick Installer
--------------------

This installer follows the Void Handbook by major section in configuring 
a fresh (or nearly fresh) Void Linux installation. The configuration features:

- updates to the system software
- installation of firmware (microcode and graphics drivers for AMD and Intel)
- basic system setup including ntpd (chrony), logging, dbus, seat management, 
  power management, NetworkManager, pipewire/wireplumber
- Optional installation & configuration for Bluetooth + Flatpak (per user), 
  Gnome, and a window manager (DWM)
- Quality of life improvements including: configuring caps lock as control key 
  for the console; Neovim as EDITOR; git, htop

Before proceeding, ensure root and your trusted "wheel" user has a passwd.
Check the hostname set in /etc/hostname if not already done so.

EOF
}

initial_update_and_firmware() {
	if ! [ -f "$INSTALL_DIR/_sys_updated" ]; then
		echo "First-run initial setup..."
		# update xbps
		xbps-install -Suy xbps
		# Enable non-free for Intel and other drivers
		xbps-install -y void-repo-nonfree
		# update everything
		xbps-install -Suy
		# xtools is a collection of utils for void and xbps
		$INSTALLER xtools
		# firmware
		CPUTYPE=$(lscpu | grep '^Vendor' | awk '{print $NF}')
		if [ "$CPUTYPE" = "GenuineIntel" ]; then
			$INSTALLER intel-ucode
			echo "INTEL"
		fi
		if [ "$CPUTYPE" = "AuthenticAMD" ]; then
			$INSTALLER linux-firmware-amd
			echo "AMD"
		fi

		# KEYBOARD CONFIGURATION - my Varmilo reports as an apple keyboard;
		# the function keys need this patch to respond correctly otherwise
		# they act as media keys (without the Fn button being pressed)
		if ask "Fix Varmilo keyboard (only needed if a desktop with one)?" N; then
			# fix Varmilo keyboard - reports as apple and messes up function keys
			echo 2 >/sys/module/hid_apple/parameters/fnmode
			# make fix permanent; when initramfs rebuilt
			echo options hid_apple fnmode=2 | tee /etc/modprobe.d/00-keyboardfix.conf
		fi
		cd /usr/share/kbd/keymaps/i386/qwerty
		gunzip us.map.gz
		echo "keycode 58 = Control" | tee -a us.map
		gzip us.map
		cd $INSTALL_DIR
		# make wheel group passwordless for sudo
		echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' | tee /etc/sudoers.d/wheel
		# make caps lock a control key in the console (do it again in Gnome or X yourself)
		# read /etc/modprobe.d/* and rebuild
		dracut --force --hostonly
		# don't do any of this again
		touch "$INSTALL_DIR/_sys_updated"
		echo -e '\nThe base system has been updated. Rebooting now is recommended.'
		echo -e '\nPlease run this script again after rebooting.\n'
		if ask "Reboot the system before proceeding?" Y; then
			reboot
		fi
	fi
}

ask() {
	#https://gist.github.com/karancode/f43bc93f9e47f53e71fa29eed638243c#file-ask-sh
	local prompt default reply

	if [[ ${2:-} = 'Y' ]]; then
		prompt='Y/n'
		default='Y'
	elif [[ ${2:-} = 'N' ]]; then
		prompt='y/N'
		default='N'
	else
		prompt='y/n'
		default=''
	fi

	while true; do
		echo -n "$1 [$prompt] "
		read -r reply </dev/tty
		# Default?
		if [[ -z $reply ]]; then
			reply=$default
		fi
		case "$reply" in
		Y* | y*) return 0 ;;
		N* | n*) return 1 ;;
		esac
	done
}

setup_users() {
	echo "User Setup"
	if ask "Setup existing user(s) for Bluetooth and Flatpak?" Y; then
		while true; do
			echo -n "Username (leave empty/press return to quit user setup): "
			read -r USER </dev/tty
			if [[ $USER = "" ]]; then
				break
			fi
			getent passwd $USER >/dev/null
			if [ $? -eq 0 ]; then
				echo "Updating $USER"
				# add any missing standard groups
				usermod -aG audio,video,cdrom,floppy,optical,kvm,xbuilder $USER
				if [[ $INSTALL_TYPE = "desktop" ]]; then
					getent group bluetooth >/dev/null
					if [ $? -eq 0 ]; then
						echo Adding $USER to bluetooth group
						usermod -aG bluetooth $USER
					fi
					getent group _flatpak >/dev/null
					if [ $? -eq 0 ]; then
						echo "Installing flatpak software repository for $USER (see gnome-software)"
						su - $USER -c "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
					fi
				fi
			else
				# try another username
				continue
			fi
		done
	fi
}

configuration() {

	# All of our configs will need dbus, polkit
	# See also: https://docs.voidlinux.org/config/session-management.html
	$INSTALLER dbus, polkit
	ln -svf /etc/sv/dbus /var/service
	if [[ $INSTALL_TYPE = "desktop" ]]; then
		$INSTALLER elogind
	fi

	# logging
	# https://docs.voidlinux.org/config/services/logging.html
	$INSTALLER socklog-void
	ln -svf /etc/sv/socklog-unix /var/service
	ln -svf /etc/sv/nanoklogd /var/service

	# not implementing snooze (cron replacement) by default
	# Solid State Devices
	# no need for fstrim; my systems are ZFS. Check:
	# https://docs.voidlinux.org/config/ssd.html

	# date and time
	$INSTALLER chrony
	ln -svf /etc/sv/chronyd /var/service

	# power management
	# https://docs.voidlinux.org/config/power-management.html
	if [[ $INSTALL_TYPE = "desktop" ]]; then
		$INSTALLER elogind
		rm -f /var/service/acpid
		if ask "Is this a laptop? Y to install and enable $(tlp)" Y; then
			$INSTALLER tlp
			ln -svf /etc/sv/tlp /var/service
		fi
	else
		# ensure acpid in place
		ln -svf /etc/sv/acpid /var/service
	fi

	# Graphics
	if [[ $INSTALL_TYPE = "desktop" ]]; then
		# common
		$INSTALLER mesa-dri vulkan-loader
		GPU=$(lsmod | grep "^video" | cut -c 33-)
		echo "This installer only installs for Intel or AMD GPUs."
		echo "If you have NVIDIA, install manually, later."
		if [ "$GPU" = "i915" ]; then
			echo "i915 Intel graphics detected"
			$INSTALLER intel-video-accel mesa-vulkan-intel
		fi

		if [ "$GPU" = "amdgpu" ]; then
			echo "amdgpu graphics detected"
			$INSTALLER mesa-vulkan-radeon xf86-video-amdgpu mesa-vaapi mesa-vdpau
		fi
	fi

	# XOrg, Wayland, Portals and GNOME
	if [[ $INSTALL_TYPE = "desktop" ]]; then
		$INSTALLER xdg-user-dirs xdg-user-dirs-gtk xdg-utils xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome xdg-desktop-portal-wlr
		# gnome & related
		$INSTALLER gnome-core gnome-terminal gnome-software gnome-tweaks gdm avahi
		ln -svf /etc/sv/avahi-daemon /var/service
		$INSTALLER flatpak
		echo "Gnome installed. "
		if ask "Also add dwm, st, dmenu?" N; then
			$INSTALLER dwm st dmenu xorg-minimal xinit
		fi
	fi

	# multimedia - pipewire
	# https://docs.voidlinux.org/config/media/pipewire.html
	if [[ $INSTALL_TYPE = "desktop" ]]; then
		$INSTALLER pipewire
		mkdir -p /etc/pipewire/pipewire.conf.d
		ln -svf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
		ln -svf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
		# autostart with Gnome (or add an .xprofile in ~/)
		ln -svf /usr/share/applications/pipewire.desktop /etc/xdg/autostart
	fi

	# bluetooth
	# https://docs.voidlinux.org/config/bluetooth.html
	if [[ $INSTALL_TYPE = "desktop" ]]; then
		if ask "Install Bluetooth support?" N; then
			$INSTALLER bluez
			ln -svf /etc/sv/bluetoothd /var/service
		fi
	fi

}

quality_of_life() {
	$INSTALLER neovim htop git wget neofetch
	# make vigr visudo etc use nvim
	echo EDITOR=nvim | tee -a /etc/environment
}

finalize_network_and_reboot() {
	# network LAST because connectivity (wifi) may be lost
	echo "Finalizing network last; connectivity may be lost."
	if [[ $INSTALL_TYPE = "desktop" ]]; then
		$INSTALLER NetworkManager
		rm -f /var/service/dhcpcd
		rm -f /var/service/wpa_supplicant
		ln -svf /etc/sv/NetworkManager /var/service
	else
		rm -f /var/service/wpa_supplicant
	fi
	# last steps
	if [[ $INSTALL_TYPE = "desktop" ]]; then
		ln -svf /etc/sv/gdm /var/service
	fi
	if ask "Reboot now or return to shell?" Y; then
		reboot
	fi
}
# run the script
main
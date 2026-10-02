#!/usr/bin/env bash
#####################################################
# This is the entry point for configuring the system.
# Source https://mailinabox.email/ https://github.com/mail-in-a-box/mailinabox
# Updated by cryptopool.builders for crypto use...
#
# Runs on each remote server (from the private staging directory created by
# the DB server) before any other installer script. Installs the shared
# helper functions and writes /etc/multipool.conf and the server's
# .yiimp.conf.
#####################################################

MP_STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Always install the helper functions copied from the DB server, older
# copies lack functions the remote scripts rely on.
sudo install -m 0644 -o root -g root "$MP_STAGE/functions.sh" /etc/functions.sh
sudo install -m 0755 -o root -g root "$MP_STAGE/editconf.py" /usr/local/bin/editconf.py
source /etc/functions.sh

echo -e " Begin remote server creations, installer may look hung...$COL_RESET"

# Get logged in user name
whoami=$(whoami)
echo -e " Modifying existing user $whoami for multipool support."
if [ "$whoami" != "root" ]; then
	sudo usermod -aG sudo "$whoami"
	if [ ! -f "/etc/sudoers.d/${whoami}" ]; then
		sudoers_tmp=$(mktemp)
		printf '# yiimp\n# It needs passwordless sudo functionality.\n%s ALL=(ALL) NOPASSWD:ALL\n' "$whoami" > "$sudoers_tmp"
		if sudo visudo -cqf "$sudoers_tmp"; then
			sudo install -m 0440 -o root -g root "$sudoers_tmp" "/etc/sudoers.d/${whoami}"
		fi
		rm -f "$sudoers_tmp"
	fi
fi

if [ ! -x /usr/bin/dialog ] || [ ! -x /usr/bin/python3 ] || [ ! -x /usr/bin/setfacl ] || [ ! -x /usr/bin/git ] || [ ! -x /usr/bin/curl ]; then
	hide_output sudo apt-get update
	apt_install dialog python3 python3-pip acl nano git curl
fi

# Check the operating system.
OS_ID=$(. /etc/os-release && echo "${ID:-}")
OS_VERSION_ID=$(. /etc/os-release && echo "${VERSION_ID:-}")
UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")
if [[ "$OS_ID" != "ubuntu" || " ${MULTIPOOL_SUPPORTED_RELEASES} " != *" ${OS_VERSION_ID} "* ]]; then
	if [ -z "${MULTIPOOL_SKIP_OS_CHECK:-}" ]; then
		echo "This server runs ${OS_ID} ${OS_VERSION_ID}; supported Ubuntu releases are: ${MULTIPOOL_SUPPORTED_RELEASES}"
		exit 1
	fi
	echo -e "${YELLOW}WARNING: ${OS_ID} ${OS_VERSION_ID} is not a supported release. Continuing anyway.${COL_RESET}"
fi
DISTRO=${OS_VERSION_ID%%.*}

ARCHITECTURE=$(uname -m)
if [ "$ARCHITECTURE" != "x86_64" ]; then
	echo "Ultimate Crypto-Server Setup Installer only supports x86_64 and will not work on any other architecture, like ARM or 32 bit OS."
	echo "Your architecture is $ARCHITECTURE"
	exit 1
fi

# Check memory. Values from /proc/meminfo are in kB.
TOTAL_PHYSICAL_MEM=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if [ "$TOTAL_PHYSICAL_MEM" -lt 1436000 ]; then
	echo "Your Crypto-Pool Server needs more memory (RAM) to function properly."
	echo "Please provision a machine with at least 2 GB, 6 GB recommended."
	echo "This machine has $((TOTAL_PHYSICAL_MEM / 1024)) MB memory."
	exit 1
fi
if [ "$TOTAL_PHYSICAL_MEM" -lt 4000000 ]; then
	echo "WARNING: Your Crypto-Pool Server has less than 4 GB of memory."
	echo " It might run unreliably when under heavy load."
fi

# Check swap
echo -e " Checking if swap space is needed and if so creating...$COL_RESET"
SWAP_MOUNTED=$(tail -n+2 /proc/swaps)
SWAP_IN_FSTAB=$(grep -E '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab || true)
ROOT_IS_BTRFS=$(grep -E '^[^ ]+ / btrfs ' /proc/mounts || true)
AVAILABLE_DISK_SPACE=$(df / --output=avail | tail -n 1)
if
	[ -z "$SWAP_MOUNTED" ] &&
	[ -z "$SWAP_IN_FSTAB" ] &&
	[ ! -e /swapfile ] &&
	[ -z "$ROOT_IS_BTRFS" ] &&
	[ "$TOTAL_PHYSICAL_MEM" -lt 19000000 ] &&
	[ "$AVAILABLE_DISK_SPACE" -gt 5242880 ]
then
	echo "Adding a swap file to the system..."
	if sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; then
		sudo chmod 600 /swapfile
		hide_output sudo mkswap /swapfile
		sudo swapon /swapfile
	fi
	if swapon --show=NAME --noheadings | grep -qx "/swapfile"; then
		echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
	else
		echo "ERROR: Swap allocation failed"
	fi
fi
echo -e "$GREEN Done...$COL_RESET"

echo -e " Setting up some needed global variables...$COL_RESET"
# Keep the values of a previous multipool setup on this server.
if [ -f /etc/multipool.conf ]; then
	source /etc/multipool.conf
fi
# The storage location and PHP version must match the DB server, so they
# come from the configuration it sent.
conf_storage_user=$(source "$MP_STAGE/.yiimp.conf" && echo "${STORAGE_USER:-}")
conf_storage_root=$(source "$MP_STAGE/.yiimp.conf" && echo "${STORAGE_ROOT:-}")
conf_php_version=$(source "$MP_STAGE/.yiimp.conf" && echo "${PHP_VERSION:-}")
STORAGE_USER=${conf_storage_user:-${STORAGE_USER:-crypto-data}}
STORAGE_ROOT=${conf_storage_root:-${STORAGE_ROOT:-/home/$STORAGE_USER}}
PHP_VERSION=${conf_php_version:-${PHP_VERSION:-$MULTIPOOL_DEFAULT_PHP_VERSION}}

# Setting Public IP for this server both IPv4 and IPv6
if [ -z "${PUBLIC_IP:-}" ] || [ "$PUBLIC_IP" = "auto" ]; then
	PUBLIC_IP=$(get_publicip_from_web_service 4 || get_default_privateip 4)
fi
if [ -z "${PUBLIC_IPV6:-}" ] || [ "$PUBLIC_IPV6" = "auto" ]; then
	PUBLIC_IPV6=$(get_publicip_from_web_service 6 || get_default_privateip 6 || true)
fi
if [ -z "${PRIVATE_IP:-}" ]; then
	PRIVATE_IP=$(get_default_privateip 4 || true)
fi

if ! is_valid_username "$STORAGE_USER"; then
	echo "Invalid storage user name: $STORAGE_USER"
	exit 1
fi

# Create the STORAGE_USER and STORAGE_ROOT directory if they don't already exist.
if ! id -u "$STORAGE_USER" > /dev/null 2>&1; then
	sudo useradd -m "$STORAGE_USER"
fi
if [ ! -d "$STORAGE_ROOT" ]; then
	sudo mkdir -p "$STORAGE_ROOT"
fi

# Save the global options in /etc/multipool.conf so that standalone
# tools know where to look for data.
write_conf_file -m 0644 -o root:root /etc/multipool.conf \
	STORAGE_USER STORAGE_ROOT PUBLIC_IP PUBLIC_IPV6 PRIVATE_IP DISTRO UBUNTU_CODENAME PHP_VERSION

# Install this server's YiiMP configuration. It holds database credentials,
# so only the installing user can read it.
sudo mkdir -p "$STORAGE_ROOT/yiimp"
sudo install -m 0600 -o "$(id -un)" -g "$(id -gn)" "$MP_STAGE/.yiimp.conf" "$STORAGE_ROOT/yiimp/.yiimp.conf"
echo -e "$GREEN Done...$COL_RESET"
exit 0

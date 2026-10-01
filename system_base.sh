#!/usr/bin/env bash
#####################################################
# Source https://mailinabox.email/ https://github.com/mail-in-a-box/mailinabox
# Updated by cryptopool.builders for crypto use...
#
# Base system setup shared by every server role (DB, web, stratum, daemon).
# This file only defines functions. It is sourced on the DB server from the
# repository and on the remote servers from the staging directory.
#####################################################

# Returns success if the answer given to a yes/no question means "yes".
function is_yes {
	[[ "${1,,}" == "y" || "${1,,}" == "yes" ]]
}

# Escape a string for use as the replacement part of a sed s||| command.
function sed_escape {
	printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'
}

# Quote a string as a single-quoted PHP string literal.
function php_quote {
	local s=${1//\\/\\\\}
	s=${s//\'/\\\'}
	printf "'%s'" "$s"
}

# Print the SSH port(s) sshd is listening on (defaults to 22).
function mp_ssh_ports {
	local ports
	ports=$(sudo sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u)
	echo "${ports:-22}"
}

# Update, upgrade and install the packages every server needs, and turn on
# the basic protections (automatic security updates, fail2ban, time sync).
function mp_system_base {
	echo -e " Setting TimeZone to UTC...$COL_RESET"
	if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "Etc/UTC" ]]; then
		hide_output sudo timedatectl set-timezone Etc/UTC
	fi
	echo -e "$GREEN Done...$COL_RESET"

	# Wait for apt/dpkg locks (e.g. unattended-upgrades running right after
	# first boot) instead of failing.
	echo 'DPkg::Lock::Timeout "600";' | sudo tee /etc/apt/apt.conf.d/90multipool-lock-timeout > /dev/null

	echo -e " Updating system packages...$COL_RESET"
	hide_output sudo apt-get update
	if [ ! -x /usr/bin/add-apt-repository ]; then
		apt_install software-properties-common
	fi
	echo -e "$GREEN Done...$COL_RESET"

	echo -e " Upgrading system packages...$COL_RESET"
	apt_get_quiet upgrade
	echo -e "$GREEN Done...$COL_RESET"

	echo -e " Running Dist-Upgrade...$COL_RESET"
	apt_get_quiet dist-upgrade
	echo -e "$GREEN Done...$COL_RESET"

	echo -e " Running Autoremove...$COL_RESET"
	apt_get_quiet autoremove
	echo -e "$GREEN Done...$COL_RESET"

	echo -e " Installing Base system packages...$COL_RESET"
	apt_install python3 python3-dev python3-pip \
		wget curl git sudo coreutils bc unzip acl \
		ca-certificates gnupg lsb-release \
		unattended-upgrades cron fail2ban ufw screen rsyslog
	echo -e "$GREEN Done...$COL_RESET"

	# Time synchronisation: Ubuntu uses systemd-timesyncd by default. Leave
	# chrony alone if the provider installed it instead.
	if ! dpkg -s chrony > /dev/null 2>&1; then
		apt_install systemd-timesyncd
		sudo timedatectl set-ntp true || true
	fi

	echo -e " Enabling automatic security updates...$COL_RESET"
	sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
	echo -e "$GREEN Done...$COL_RESET"

	echo -e " Enabling fail2ban for SSH...$COL_RESET"
	local ssh_ports
	ssh_ports=$(mp_ssh_ports | paste -sd, -)
	printf '[sshd]\nenabled = true\nport = %s\n' "$ssh_ports" \
		| sudo tee /etc/fail2ban/jail.d/multipool-sshd.local > /dev/null
	sudo systemctl enable --now fail2ban > /dev/null 2>&1 || true
	sudo systemctl restart fail2ban || true
	echo -e "$GREEN Done...$COL_RESET"

	if [ -f /usr/sbin/apache2 ]; then
		echo -e " Removing apache...$COL_RESET"
		apt_get_quiet purge apache2 apache2-bin apache2-data apache2-utils
		apt_get_quiet --purge autoremove
		echo -e "$GREEN Done...$COL_RESET"
	fi
}

# Clone the YiiMP source into $STORAGE_ROOT/yiimp/yiimp_setup/yiimp.
# Uses YiiMPRepo/YiiMPBranch from .yiimp.conf (set from the YIIMP_REPO and
# YIIMP_BRANCH environment variables when the questions were answered).
function mp_clone_yiimp {
	local repo=${YiiMPRepo:-${MULTIPOOL_GITHUB:-https://github.com/myGIGlife-claude}/yiimp.git}
	local branch=${YiiMPBranch:-}
	local dest="$STORAGE_ROOT/yiimp/yiimp_setup/yiimp"

	echo -e " Downloading YiiMP Repo...$COL_RESET"
	sudo mkdir -p "$STORAGE_ROOT/yiimp/yiimp_setup"
	sudo rm -rf "$dest"
	if [ -n "$branch" ]; then
		hide_output sudo git clone -q --depth 1 -b "$branch" -- "$repo" "$dest"
	else
		hide_output sudo git clone -q --depth 1 -- "$repo" "$dest"
	fi
	echo -e "$GREEN Done...$COL_RESET"
}

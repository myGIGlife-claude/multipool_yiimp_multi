#!/usr/bin/env bash
#####################################################
# Source https://mailinabox.email/ https://github.com/mail-in-a-box/mailinabox
# Updated by cryptopool.builders for crypto use...
#
# Shared helper functions. This file is installed to /etc/functions.sh and
# sourced by every MultiPool installer (and copied to remote servers by the
# YiiMP multi-server installer), so keep it free of side effects other than
# defining variables and functions.
#####################################################

ESC_SEQ="\x1b["
COL_RESET=$ESC_SEQ"39;49;00m"
RED=$ESC_SEQ"31;01m"
GREEN=$ESC_SEQ"32;01m"
YELLOW=$ESC_SEQ"33;01m"
BLUE=$ESC_SEQ"34;01m"
MAGENTA=$ESC_SEQ"35;01m"
CYAN=$ESC_SEQ"36;01m"

# Ubuntu LTS releases this installer is tested against.
MULTIPOOL_SUPPORTED_RELEASES="22.04 24.04 26.04"

# PHP version installed from ppa:ondrej/php when /etc/multipool.conf doesn't
# specify one. Override at install time with PHP_VERSION=x.y.
MULTIPOOL_DEFAULT_PHP_VERSION="8.3"

# Base URL for the MultiPool GitHub repositories. Override with
# MULTIPOOL_GITHUB=https://github.com/<you> to install from a fork.
MULTIPOOL_GITHUB="${MULTIPOOL_GITHUB:-https://github.com/myGIGlife-claude}"

# Draw a spinner while the process with the given PID is running.
function spinner {
	local pid=$1
	local delay=0.75
	local spinstr='|/-\'
	while kill -0 "$pid" 2>/dev/null; do
		local temp=${spinstr#?}
		printf " [%c]  " "$spinstr"
		spinstr=$temp${spinstr%"$temp"}
		sleep $delay
		printf "\b\b\b\b\b\b"
	done
	printf "    \b\b\b\b"
}

# Run a command, hiding its output unless it fails. On failure the output is
# shown and the calling script exits with the command's exit status.
function hide_output {
	local output pid rc
	output=$(mktemp)
	if [ -t 1 ]; then
		"$@" &> "$output" &
		pid=$!
		spinner "$pid"
		rc=0
		wait "$pid" || rc=$?
	else
		rc=0
		"$@" &> "$output" || rc=$?
	fi
	if [ $rc -ne 0 ]; then
		echo
		echo "FAILED: $*"
		echo -----------------------------------------
		cat "$output"
		echo -----------------------------------------
		rm -f "$output"
		exit $rc
	fi
	rm -f "$output"
}

function apt_get_quiet {
	# Keep existing config files on upgrade (--force-confold) so we never
	# silently overwrite changes an admin has made.
	hide_output sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y \
		-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@"
}

function apt_install {
	apt_get_quiet install "$@"
}

function ufw_allow {
	if [ -z "${DISABLE_FIREWALL:-}" ]; then
		sudo ufw allow "$@" > /dev/null
	fi
}

function restart_service {
	hide_output sudo systemctl restart "$1"
}

# Generate a random alphanumeric string (default 32 characters).
function generate_password {
	local length=${1:-32}
	local pw=""
	while [ ${#pw} -lt "$length" ]; do
		pw+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
	done
	echo "${pw:0:$length}"
}

# Write "NAME=value" lines to a file that will later be sourced by bash,
# quoting each value so that no user input can be executed.
#   write_conf_file [-m MODE] [-o OWNER[:GROUP]] /path/to/file.conf NAME1 NAME2 ...
# The variables are read from the current shell by name. The file is
# (re)written with MODE (default 0600) and owned by OWNER (default: the user
# running the installer, so their scripts and screens can still source it).
function write_conf_file {
	local mode=0600 owner group
	owner=$(id -un)
	group=$(id -gn)
	while [[ "${1:-}" == -* ]]; do
		case "$1" in
			-m) mode=$2; shift 2 ;;
			-o) owner=${2%%:*}; [[ "$2" == *:* ]] && group=${2#*:} || group=$(id -gn "$owner"); shift 2 ;;
			*) echo "write_conf_file: unknown option $1" >&2; return 1 ;;
		esac
	done
	local file=$1
	shift
	local tmp name
	tmp=$(mktemp)
	for name in "$@"; do
		printf '%s=%q\n' "$name" "${!name-}" >> "$tmp"
	done
	sudo install -m "$mode" -o "$owner" -g "$group" "$tmp" "$file"
	rm -f "$tmp"
}

# Returns success if $1 looks like a valid Linux user name.
function is_valid_username {
	[[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

## Dialog Functions ##
function message_box {
	dialog --title "$1" --msgbox "$2" 0 0
}

function input_box {
	# input_box "title" "prompt" "defaultvalue" VARIABLE
	# The user's input will be stored in the variable VARIABLE.
	# The exit code from dialog will be stored in VARIABLE_EXITCODE.
	declare -n result=$4
	declare -n result_code=$4_EXITCODE
	result=$(dialog --stdout --title "$1" --inputbox "$2" 0 0 "$3")
	result_code=$?
}

function input_menu {
	# input_menu "title" "prompt" "tag item tag item" VARIABLE
	# The user's input will be stored in the variable VARIABLE.
	# The exit code from dialog will be stored in VARIABLE_EXITCODE.
	declare -n result=$4
	declare -n result_code=$4_EXITCODE
	local IFS=^$'\n'
	# shellcheck disable=SC2086
	result=$(dialog --stdout --title "$1" --menu "$2" 0 0 0 $3)
	result_code=$?
}

function get_publicip_from_web_service {
	# This seems to be the most reliable way to determine the
	# machine's public IP address: asking a very nice web API
	# for how they see us. Thanks go out to icanhazip.com.
	# See: https://major.io/icanhazip-com-faq/
	#
	# Pass '4' or '6' as an argument to this function to specify
	# what type of address to get (IPv4, IPv6).
	curl -"$1" --fail --silent --max-time 15 https://icanhazip.com 2>/dev/null
}

function get_default_privateip {
	# Return the IP address of the network interface connected
	# to the Internet.
	#
	# Pass '4' or '6' as an argument to this function to specify
	# what type of address to get (IPv4, IPv6).
	#
	# We use `ip route get` which asks the kernel to use the system's
	# routes to select which interface would be used to reach a public
	# address. No connection is actually made.
	#
	# With IPv6, the best route may be via an interface that only has a
	# link-local address (fe80::*). These addresses are only unique to an
	# interface and so need an explicit interface specification in order
	# to use them with bind(). In these cases, we append "%interface" to
	# the address.

	local target=8.8.8.8
	if [ "$1" == "6" ]; then target=2001:4860:4860::8888; fi

	local route address interface
	route=$(ip -"$1" -o route get "$target" 2>/dev/null | grep -v unreachable)
	[ -z "$route" ] && return 1

	# Parse the address out of the route information.
	address=$(echo "$route" | sed "s/.* src \([^ ]*\).*/\1/")

	if [[ "$1" == "6" && $address == fe80:* ]]; then
		interface=$(echo "$route" | sed "s/.* dev \([^ ]*\).*/\1/")
		address=$address%$interface
	fi

	echo "$address"
}

# Clone or update one of the MultiPool installer repositories.
#   multipool_fetch_repo <repo name or full URL> <destination dir> <git ref>
# A bare repo name is resolved against $MULTIPOOL_GITHUB. <git ref> may be a
# branch or a tag.
function multipool_fetch_repo {
	local repo=$1 dest=$2 ref=$3
	[[ "$repo" == https://* ]] || repo="${MULTIPOOL_GITHUB}/${repo}"
	if ! [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$ref" == -* ]]; then
		echo "Error: '$ref' is not a valid git ref name." >&2
		return 1
	fi
	if [ ! -d "$dest/.git" ]; then
		echo "Downloading ${repo} (${ref}) . . ."
		if ! git clone -q -b "$ref" --depth 1 -- "$repo" "$dest" < /dev/null; then
			echo "Error: failed to clone ${repo} at ${ref}." >&2
			return 1
		fi
		echo
	else
		sudo chown -R "$(id -u):$(id -g)" "$dest"
		echo "Updating ${repo} (${ref}) . . ."
		# Older releases cloned from a different location.
		git -C "$dest" remote set-url origin "$repo"
		if ! git -C "$dest" fetch -q --depth 1 --force origin "$ref" \
			|| ! git -C "$dest" checkout -q --force FETCH_HEAD; then
			echo "Update failed. Did you modify something in ${dest}?" >&2
			return 1
		fi
		echo
	fi
}

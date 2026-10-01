#!/usr/bin/env bash
#####################################################
# Created by cryptopool.builders for crypto use...
#
# Helpers for the installer questions. This file only defines functions.
#####################################################

function is_valid_ipv4 {
	local ip=$1 octet
	[[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	for octet in ${ip//./ }; do
		[ "$((10#$octet))" -le 255 ] || return 1
	done
}

function is_valid_hostname {
	[[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# Admin panel location and similar names used in URLs and file names.
function is_valid_name {
	[[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# Database passwords end up in PHP, ini and option files: keep them to
# characters that need no quoting anywhere.
function is_valid_db_password {
	[[ "$1" =~ ^[A-Za-z0-9._+=@%:,~-]{12,}$ ]]
}

# Anything goes, as long as it is not empty.
function is_not_empty {
	[ -n "$1" ]
}

# ask_input "title" "prompt" "default" VARIABLE [validator] [error message]
# Keeps asking until the validator accepts the answer. Exits the installer
# when the user cancels.
function ask_input {
	local title=$1 prompt=$2 default=$3 var=$4 validator=${5:-is_not_empty}
	local error=${6:-"The value you entered is not valid, please try again."}
	local -n answer=$var
	while true; do
		input_box "$title" "$prompt" "$default" "$var"
		local -n answer_code="${var}_EXITCODE"
		if [ "$answer_code" -ne 0 ]; then
			# user hit ESC/cancel
			clear
			echo "User canceled installation"
			exit 0
		fi
		if "$validator" "$answer"; then
			return 0
		fi
		message_box "$title" "$error"
		default=$answer
	done
}

# ask_yesno "title" "question" VARIABLE: sets VARIABLE to yes or no.
function ask_yesno {
	local -n answer=$3
	local response=0
	dialog --title "$1" --yesno "$2" 7 60 || response=$?
	case $response in
		0) answer=yes ;;
		1) answer=no ;;
		*)
			clear
			echo "[ESC] key pressed. User canceled installation"
			exit 0 ;;
	esac
}

# Guess the public IP of the machine the user is connecting from.
function guess_client_ip {
	if [ -n "${SSH_CLIENT:-}" ]; then
		echo "${SSH_CLIENT%% *}"
	else
		echo 192.168.0.1
	fi
}

# Read YIIMP_REPO / YIIMP_BRANCH from the environment to install YiiMP from
# a fork. Unless you do some serious modifications this installer will not
# work with any other repo of yiimp!
function set_yiimp_repo {
	YiiMPRepo=${YIIMP_REPO:-${YiiMPRepo:-${MULTIPOOL_GITHUB:-https://github.com/myGIGlife-claude}/yiimp.git}}
	YiiMPBranch=${YIIMP_BRANCH:-${YiiMPBranch:-}}
}

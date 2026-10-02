#!/usr/bin/env bash
#####################################################
# Created by cryptopool.builders for crypto use...
#
# Helpers used on the DB server to install the other servers over SSH.
# Replaces the old setsid + SSH_ASKPASS script approach:
#  - host keys are verified (StrictHostKeyChecking=accept-new) against a
#    dedicated known_hosts file instead of being ignored;
#  - the SSH password is never written to disk or put on a command line. It
#    is only placed in the environment of the ssh master process, which
#    authenticates once per server; every later command reuses that
#    connection through a control socket in a private (0700) directory;
#  - files are copied into a private (0700) staging directory on the remote
#    server that is deleted when the installation of that server finishes.
# This file only defines functions and variables.
#####################################################

MP_REPO_DIR="${MP_REPO_DIR:-$HOME/multipool/yiimp_multi}"
MP_KNOWN_HOSTS="$HOME/.ssh/multipool_known_hosts"

# Configuration keys each remote server role receives in its copy of
# .yiimp.conf. Server passwords and the DB root password are never sent.
MP_WEB_KEYS=(STORAGE_USER STORAGE_ROOT PRIMARY_HOSTNAME DomainName UsingSubDomain StratumURL
	InstallSSL SupportEmail AdminPanel PublicIP CoinPort AutoExchange
	DBInternalIP WebInternalIP StratumInternalIP DaemonInternalIP
	YiiMPDBName YiiMPPanelName PanelUserDBPassword wireguard YiiMPRepo YiiMPBranch PHP_VERSION)
MP_STRATUM_KEYS=(STORAGE_USER STORAGE_ROOT DomainName StratumURL AutoExchange CoinPort
	DBInternalIP WebInternalIP StratumInternalIP DaemonInternalIP
	YiiMPDBName StratumDBUser StratumUserDBPassword blckntifypass wireguard YiiMPRepo YiiMPBranch PHP_VERSION)
MP_DAEMON_KEYS=(STORAGE_USER STORAGE_ROOT DBInternalIP WebInternalIP StratumInternalIP DaemonInternalIP
	blckntifypass wireguard YiiMPRepo PHP_VERSION)

# Create the private working directory and the askpass helper.
function mp_ssh_init {
	if [ -n "${MP_SSH_DIR:-}" ] && [ -d "$MP_SSH_DIR" ]; then
		return 0
	fi
	MP_SSH_DIR=$(mktemp -d /tmp/multipool-ssh.XXXXXXXX) || return 1
	# The helper prints the password from its own environment, which it
	# inherits from the ssh process that runs it.
	# shellcheck disable=SC2016
	printf '#!/bin/sh\nprintf "%%s\\n" "$MP_SSH_PASS"\n' > "$MP_SSH_DIR/askpass"
	chmod 700 "$MP_SSH_DIR/askpass"
	trap mp_ssh_cleanup EXIT

	mkdir -p "$HOME/.ssh"
	chmod 700 "$HOME/.ssh"
	touch "$MP_KNOWN_HOSTS"
	chmod 600 "$MP_KNOWN_HOSTS"

	MP_SSH_OPTS=(-o LogLevel=error
		-o StrictHostKeyChecking=accept-new
		-o UserKnownHostsFile="$MP_KNOWN_HOSTS"
		-o ControlPath="$MP_SSH_DIR/%C"
		-o ConnectTimeout=20
		-o ServerAliveInterval=30
		-o ServerAliveCountMax=10)
}

# Close all SSH connections and remove the private working directory.
function mp_ssh_cleanup {
	local sock
	if [ -n "${MP_SSH_DIR:-}" ] && [ -d "$MP_SSH_DIR" ]; then
		for sock in "$MP_SSH_DIR"/*; do
			[ -S "$sock" ] && ssh -o ControlPath="$sock" -O exit dummy > /dev/null 2>&1
		done
		rm -rf "$MP_SSH_DIR"
	fi
	MP_SSH_DIR=
}

function mp_abort {
	echo -e "$RED $*$COL_RESET" >&2
	exit 1
}

# mp_ssh_connect user@host [password]
# Open the shared connection to a server. Without a password (or when key
# authentication works) no password is used; with no password and no key the
# user is prompted by ssh.
function mp_ssh_connect {
	local target=$1 pass=${2:-}
	mp_ssh_init || return 1
	if ssh "${MP_SSH_OPTS[@]}" -O check "$target" > /dev/null 2>&1; then
		return 0
	fi
	echo -e " Connecting to ${target}...$COL_RESET"
	if [ -n "$pass" ]; then
		MP_SSH_PASS=$pass SSH_ASKPASS="$MP_SSH_DIR/askpass" SSH_ASKPASS_REQUIRE=force \
			ssh "${MP_SSH_OPTS[@]}" -o ControlMaster=yes -o ControlPersist=yes \
			-o NumberOfPasswordPrompts=1 -fN "$target" < /dev/null
	else
		ssh "${MP_SSH_OPTS[@]}" -o ControlMaster=yes -o ControlPersist=yes -fN "$target"
	fi
	if ! ssh "${MP_SSH_OPTS[@]}" -O check "$target" > /dev/null 2>&1; then
		echo -e "$RED Could not log in to ${target}. Check the IP address, user name and password,$COL_RESET" >&2
		echo -e "$RED and that the host key in ${MP_KNOWN_HOSTS} has not changed.$COL_RESET" >&2
		return 1
	fi
}

# mp_ssh user@host command
# Run a command on a connected server. The command string is interpreted by
# the remote shell, so quote any variable parts with printf %q.
function mp_ssh {
	local target=$1
	shift
	ssh "${MP_SSH_OPTS[@]}" -o ControlMaster=no -o BatchMode=yes "$target" "$@"
}

# mp_remote_sudo_setup user@host [password]
# The installer needs password-less sudo on the remote server (the
# multipool user setup normally configures this). If it is missing, add it
# once, passing the password to sudo on stdin.
function mp_remote_sudo_setup {
	local target=$1 pass=${2:-}
	if mp_ssh "$target" 'sudo -n true' > /dev/null 2>&1; then
		return 0
	fi
	if [ -z "$pass" ]; then
		echo -e "$RED ${target}: the user needs password-less sudo. Run the multipool user setup on that server first.$COL_RESET" >&2
		return 1
	fi
	echo -e " Enabling password-less sudo for ${target%%@*} on ${target#*@}...$COL_RESET"
	# shellcheck disable=SC2016
	local script='set -e
u=$(id -un)
tmp=$(mktemp)
trap "rm -f \"$tmp\"" EXIT
printf "# yiimp\n# It needs passwordless sudo functionality.\n%s ALL=(ALL) NOPASSWD:ALL\n" "$u" > "$tmp"
sudo -S -p "" sh -c "visudo -cqf \"\$1\" && install -m 0440 -o root -g root \"\$1\" \"/etc/sudoers.d/\$2\"" sh "$tmp" "$u"'
	printf '%s\n' "$pass" | mp_ssh "$target" "bash -c $(printf '%q' "$script")"
	mp_ssh "$target" 'sudo -n true' > /dev/null 2>&1
}

# mp_stage_create user@host
# Create a private staging directory on the server; sets MP_STAGE_REMOTE.
function mp_stage_create {
	MP_STAGE_REMOTE=$(mp_ssh "$1" 'umask 077; mktemp -d /tmp/multipool.XXXXXXXX') || return 1
	[ -n "$MP_STAGE_REMOTE" ]
}

# mp_stage_put user@host local_file [remote_name]
function mp_stage_put {
	local target=$1 file=$2 name=${3:-$(basename "$2")}
	if [ ! -f "$file" ]; then
		echo "Missing file: $file" >&2
		return 1
	fi
	mp_ssh "$target" "umask 077; cat > $(printf '%q' "$MP_STAGE_REMOTE/$name")" < "$file"
}

# mp_stage_put_conf user@host remote_name KEY...
# Write the named variables of the current shell to a private temporary
# file and copy it to the staging directory.
function mp_stage_put_conf {
	local target=$1 name=$2 tmp rc=0
	shift 2
	tmp=$(mktemp)
	write_conf_file -m 600 "$tmp" "$@" && mp_stage_put "$target" "$tmp" "$name" || rc=$?
	rm -f "$tmp"
	return $rc
}

# mp_stage_run user@host script [args...]
# Run a staged script with bash on the server, from the staging directory.
function mp_stage_run {
	local target=$1 script=$2
	shift 2
	local cmd
	cmd="cd $(printf '%q' "$MP_STAGE_REMOTE") && bash ./$(printf '%q' "$script")"
	if [ $# -gt 0 ]; then
		cmd+=" $(printf '%q ' "$@")"
	fi
	mp_ssh "$target" "$cmd"
}

# mp_stage_remove user@host
function mp_stage_remove {
	if [ -n "${MP_STAGE_REMOTE:-}" ]; then
		mp_ssh "$1" "rm -rf $(printf '%q' "$MP_STAGE_REMOTE")" || true
	fi
	MP_STAGE_REMOTE=
}

# mp_remote_reboot user@host
# Schedule a reboot a few seconds from now so the SSH session can end cleanly.
function mp_remote_reboot {
	mp_ssh "$1" 'sudo systemd-run --quiet --on-active=10 /bin/systemctl reboot' || true
	ssh "${MP_SSH_OPTS[@]}" -O exit "$1" > /dev/null 2>&1 || true
}

# mp_remote_install_server ROLE user@host password conf_keys_var files_var scripts_var
# Copy the common files, the role configuration and the given files, then run
# the given scripts in order (each entry is "script [args...]"). Stops at the
# first failing script.
function mp_remote_install_server {
	local role=$1 target=$2 pass=$3
	local -n keys_ref=$4 files_ref=$5 scripts_ref=$6
	local f entry
	local -a words

	echo -e "$YELLOW Installing the ${role} server ${target#*@}...$COL_RESET"
	mp_ssh_connect "$target" "$pass" || mp_abort "Unable to connect to the ${role} server."
	mp_remote_sudo_setup "$target" "$pass" || mp_abort "Unable to configure sudo on the ${role} server."
	mp_stage_create "$target" || mp_abort "Unable to create a staging directory on the ${role} server."

	# The helpers multipool_setup installed on this server, so every server runs the same copy.
	for f in /etc/functions.sh /usr/local/bin/editconf.py \
		"$MP_REPO_DIR/system_base.sh" \
		"$MP_REPO_DIR/create_user_remote.sh" \
		"${files_ref[@]}"; do
		mp_stage_put "$target" "$f" || mp_abort "Unable to copy $(basename "$f") to the ${role} server."
	done
	mp_stage_put_conf "$target" .yiimp.conf "${keys_ref[@]}" \
		|| mp_abort "Unable to copy the configuration to the ${role} server."

	mp_stage_run "$target" create_user_remote.sh || mp_abort "Preparing the ${role} server failed."
	for entry in "${scripts_ref[@]}"; do
		read -r -a words <<< "$entry"
		mp_stage_run "$target" "${words[@]}" || mp_abort "${words[0]} failed on the ${role} server."
	done
	mp_stage_remove "$target"
	echo -e "$GREEN ${role^} server installation completed, rebooting it...$COL_RESET"
	mp_remote_reboot "$target"
}

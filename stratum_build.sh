#!/usr/bin/env bash
#####################################################
# Created by cryptopool.builders for crypto use...
#
# Builds blocknotify and the stratum from the YiiMP source in
# $STORAGE_ROOT/yiimp/yiimp_setup/yiimp and installs them in
# $STORAGE_ROOT/yiimp/site/stratum. This file only defines functions; it is
# used on the DB server (DB + stratum setup) and on the stratum servers.
#
# Needs from .yiimp.conf: StratumURL, YiiMPDBName, StratumDBUser,
# StratumUserDBPassword, blckntifypass and AutoExchange.
#####################################################

# Packages needed to compile blocknotify and the stratum.
function mp_install_stratum_build_deps {
	echo -e " Installing YiiMP Required system packages...$COL_RESET"
	apt_install build-essential libtool autotools-dev automake pkg-config bsdmainutils \
		libgmp-dev libmysqlclient-dev libcurl4-gnutls-dev libssl-dev libevent-dev libsodium-dev \
		libkrb5-dev libldap-dev libidn-dev libidn2-dev libgnutls28-dev librtmp-dev \
		libnghttp2-dev libssh-dev libssh2-1-dev libpsl-dev libzstd-dev libbrotli-dev zlib1g-dev \
		pwgen mariadb-client
	echo -e "$GREEN Done...$COL_RESET"
}

# mp_build_stratum <database host>
function mp_build_stratum {
	local db_host=$1
	local src="$STORAGE_ROOT/yiimp/yiimp_setup/yiimp"
	local site="$STORAGE_ROOT/yiimp/site/stratum"

	if [ -z "${blckntifypass:-}" ]; then
		blckntifypass=$(generate_password 32)
	fi

	sudo mkdir -p "$site" "$STORAGE_ROOT/yiimp/starts"

	echo -e " Building blocknotify and stratum...$COL_RESET"
	sudo sed -i "s|tu8tu5|$(sed_escape "$blckntifypass")|" "$src/blocknotify/blocknotify.cpp"
	hide_output sudo make -C "$src/blocknotify"
	hide_output sudo make -C "$src/stratum/iniparser"
	if is_yes "${AutoExchange:-no}"; then
		sudo sed -i 's/^CFLAGS += -DNO_EXCHANGE/#CFLAGS += -DNO_EXCHANGE/' "$src/stratum/Makefile"
	fi
	hide_output sudo make -C "$src/stratum"
	echo -e "$GREEN Done...$COL_RESET"

	echo -e " Building stratum folder structure and copying files...$COL_RESET"
	sudo mkdir -p "$site/config"
	sudo cp -a "$src/stratum/config.sample/." "$site/config"
	sudo cp "$src/stratum/stratum" "$site"
	# Generator for the Vertcoin verthash.dat the verthash stratum needs (1.2 GB,
	# only created when you want to mine Vertcoin): cd $site && ./verthash_gen verthash.dat
	hide_output sudo make -C "$src/stratum" verthash_gen
	sudo cp "$src/stratum/verthash_gen" "$site"
	sudo sed -i "s|^verthash_datafile = .*|verthash_datafile = $(sed_escape "$site/verthash.dat")|" "$site/config/verthash.conf"
	sudo cp "$src/blocknotify/blocknotify" "$site"
	sudo install -m 0755 "$src/blocknotify/blocknotify" /usr/bin/blocknotify

	# Create run files
	local qsite
	qsite=$(printf '%q' "$site")
	sudo rm -f "$site/config/run.sh" "$site/run.sh"
	sudo tee "$site/config/run.sh" > /dev/null <<EOF
#!/usr/bin/env bash
ulimit -n 10240
ulimit -u 10240
cd ${qsite} || exit 1
while true; do
	./stratum "config/\$1"
	sleep 2
done
EOF
	sudo tee "$site/run.sh" > /dev/null <<EOF
#!/usr/bin/env bash
cd ${qsite}/config || exit 1
exec ./run.sh "\$@"
EOF
	sudo chmod 0755 "$site/config/run.sh" "$site/run.sh"
	echo -e "$GREEN Done...$COL_RESET"

	# Update the stratum config files with the needed information
	echo -e " Updating stratum config files with database connection info...$COL_RESET"
	sudo find "$site/config" -maxdepth 1 -name '*.conf' -exec sed -i \
		-e "s|^password = tu8tu5|password = $(sed_escape "$blckntifypass")|" \
		-e "s|^server = yaamp.com|server = $(sed_escape "$StratumURL")|" \
		-e "s|^host = yaampdb|host = $(sed_escape "$db_host")|" \
		-e "s|^database = yaamp|database = $(sed_escape "$YiiMPDBName")|" \
		-e "s|^username = root|username = $(sed_escape "$StratumDBUser")|" \
		-e "s|^password = patofpaq|password = $(sed_escape "$StratumUserDBPassword")|" \
		{} +

	# The config files contain the database password: readable by the
	# installing user (who runs the stratum screens) and root only.
	sudo chown -R "$(id -un):$(id -gn)" "$site"
	sudo chmod 0750 "$site" "$site/config"
	sudo find "$site/config" -maxdepth 1 -name '*.conf' -exec chmod 0640 {} +
	echo -e "$GREEN Done...$COL_RESET"
}

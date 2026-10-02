#!/usr/bin/env bash
#####################################################
# Source https://mailinabox.email/ https://github.com/mail-in-a-box/mailinabox
# Updated by cryptopool.builders for crypto use...
#####################################################

MP_STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source /etc/functions.sh
source /etc/multipool.conf
source "$STORAGE_ROOT/yiimp/.yiimp.conf"
source "$MP_STAGE/system_base.sh"
source "$MP_STAGE/nginx_site.sh"
PHP_VERSION="${PHP_VERSION:-$MULTIPOOL_DEFAULT_PHP_VERSION}"

echo -e " Building web file structure and copying files...$COL_RESET"

site="$STORAGE_ROOT/yiimp/site"
src="$STORAGE_ROOT/yiimp/yiimp_setup/yiimp"
sudo mkdir -p "$site/web" "$site/configuration" "$site/crons" "$site/log" "$site/backup" \
	"$STORAGE_ROOT/yiimp/starts" "/var/www/${DomainName}/html" /etc/yiimp

sudo sed -i "s|AdminRights|$(sed_escape "$AdminPanel")|" "$src/web/yaamp/modules/site/SiteController.php"
sudo cp -r "$src/web" "$site/"
sudo cp -r "$src/bin/." /bin/
sudo sed -i "s|ROOTDIR=/data/yiimp|ROOTDIR=$(sed_escape "${STORAGE_ROOT}/yiimp/site")|g" /bin/yiimp
echo -e "$GREEN Done...$COL_RESET"

echo -e " Creating nginx web configuration files...$COL_RESET"
mp_nginx_site self || exit 1
if is_yes "$InstallSSL"; then
	if mp_certbot; then
		mp_nginx_site letsencrypt || exit 1
	fi
fi
echo -e "$GREEN Done...$COL_RESET"

echo -e " Creating YiiMP configuration files...$COL_RESET"
source "$MP_STAGE/keys.sh"
source "$MP_STAGE/yiimpserverconfig.sh"
source "$MP_STAGE/main.sh"
source "$MP_STAGE/loop2.sh"
source "$MP_STAGE/blocks.sh"
echo -e "$GREEN Done...$COL_RESET"

echo -e " Setting correct folder permissions...$COL_RESET"
whoami=$(whoami)
sudo usermod -aG www-data "$whoami"
sudo usermod -aG "$STORAGE_USER" "$whoami"
sudo usermod -aG "$STORAGE_USER" www-data
# The web tree is shared by the installing user (cron screens) and php-fpm
# (www-data); files are not writable by anybody else.
sudo chgrp -R www-data "$site"
sudo find "$site" -type d -exec chmod 2775 {} +
sudo find "$site" -type f -exec chmod 664 {} +
sudo chmod +x "$site"/crons/*.sh
# The log directory must stay writable for both no matter the umask.
sudo setfacl -R -m g:www-data:rwX -m d:g:www-data:rwX "$site/log"
# Secrets: serverconfig.php is readable by root and www-data only.
sudo chown root:www-data "$site/configuration/serverconfig.php"
sudo chmod 0640 "$site/configuration/serverconfig.php"
echo -e "$GREEN Done...$COL_RESET"

# Updating YiiMP files for cryptopool.builders build
# Allow coin daemon RPC from the /26 network the web server is in.
last_octet=${WebInternalIP##*.}
internalrpcip="${WebInternalIP%.*}.$((last_octet & 192))/26"

echo -e " Adding the cryptopool.builders flare to YiiMP...$COL_RESET"
domain_sed=$(sed_escape "$DomainName")
sudo sed -i "s|domain|${domain_sed}|g" "$site/web/yaamp/modules/site/index.php"
serverconfig_sed=$(sed_escape "${site}/configuration/serverconfig.php")
for f in web/index.php web/runconsole.php web/run.php web/yaamp/yiic.php web/yaamp/modules/thread/CronjobController.php; do
	sudo sed -i "s|serverconfig.php|${serverconfig_sed}|g" "$site/$f"
done

sudo sed -i "/# onlynet=ipv4/i\\    echo \"rpcallowip=${internalrpcip}\\\\n\";\\n" "$site/web/yaamp/modules/site/coin_form.php"
sudo sed -i "s|internalipsed|$(sed_escape "$DaemonInternalIP")|g" "$site/web/yaamp/modules/site/coin_form.php"

sudo sed -i "s|/root/backup|$(sed_escape "$site/backup")|g" "$site/web/yaamp/core/backend/system.php"
# shellcheck disable=SC2016
sudo sed -i 's/service $webserver start/sudo service $webserver start/g' "$site/web/yaamp/modules/thread/CronjobController.php"
sudo sed -i 's/service nginx stop/sudo service nginx stop/g' "$site/web/yaamp/modules/thread/CronjobController.php"

echo -e "$GREEN Web structure completed...$COL_RESET"
exit 0

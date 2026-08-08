#!/bin/sh
# rss.sh - add a private, Tailscale-only FreshRSS reader to a
# self-managed OpenBSD server with a working web server and TLS
# by Stathis, https://nevrast.xyz
# INSTALL: cd /root ; ftp https://nevrast.xyz/rss.sh ; sh rss.sh
# README:  https://nevrast.xyz/rss-tutorial.html

if [[ $(id -u) -ne 0 || $(uname) != "OpenBSD" ]]; then
	echo "must be run as root on OpenBSD, with a domain, SSH access, and a working web server already set up"
	exit 1
fi

mkdir -p /root/my
function my {
	echo "/root/my/rss_$1"
}

# SUBDOMAIN?
if [ -f $(my domain) ]; then
	domain=$(cat $(my domain))
else
	printf "What subdomain do you want for the RSS reader? (e.g. rss.yourdomain.com) "
	read ui
	domain=$(echo "$ui" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
	echo $domain > $(my domain)
fi
echo "Using $domain"

# LOCAL PORT?
if [ -f $(my port) ]; then
	port=$(cat $(my port))
else
	port=8090
	echo $port > $(my port)
fi

# INSTALL PHP
if [ ! -f $(my phpok) ]; then
	printf "\n\n#############################\n"
	echo "Installing PHP. When it asks which version, pick the highest one offered."
	pkg_add php
	touch $(my phpok)
fi

# DETECT PHP VERSION (e.g. "8.2")
phpver=$(ls /etc/php-*.ini 2>/dev/null | head -1 | sed 's#.*/php-##; s#\.ini##')
if [ -z "$phpver" ]; then
	echo "Could not detect installed PHP version. Something went wrong above."
	exit 1
fi
phpsvc="php$(echo $phpver | tr -d '.')_fpm"
echo "Detected PHP $phpver ($phpsvc)"

# INSTALL EXTENSIONS
if [ ! -f $(my extok) ]; then
	printf "\n\n#############################\n"
	echo "Installing PHP extensions. Match the version you picked above for each prompt."
	pkg_add php-curl php-gd php-intl php-mbstring php-pdo_sqlite php-sqlite3 php-zip
	# activate every extension installed (OpenBSD ships them disabled)
	for x in /etc/php-$phpver.sample/*; do
		ln -sf "$x" /etc/php-$phpver/
	done
	touch $(my extok)
fi

# FIX OUTBOUND HTTPS (curl/openssl need to be told where the CA bundle is)
if [ ! -f $(my sslok) ]; then
	echo 'curl.cainfo = "/etc/ssl/cert.pem"' > /etc/php-$phpver/zzz-cainfo.ini
	echo 'openssl.cafile = "/etc/ssl/cert.pem"' >> /etc/php-$phpver/zzz-cainfo.ini
	touch $(my sslok)
fi

# CHROOT: httpd/php-fpm run chrooted to /var/www, so the cainfo path above
# points nowhere until /etc/resolv.conf and /etc/ssl/cert.pem are also
# copied inside the chroot. Without this, outbound HTTPS from PHP still
# fails even though cainfo is set correctly.
if [ ! -f $(my chrootok) ]; then
	mkdir -p /var/www/etc/ssl
	cp /etc/resolv.conf /var/www/etc/resolv.conf
	cp /etc/ssl/cert.pem /var/www/etc/ssl/cert.pem
	touch $(my chrootok)
fi

rcctl enable $phpsvc
rcctl restart $phpsvc

# DOWNLOAD FRESHRSS
if [ ! -d /var/www/freshrss ]; then
	printf "\n\n#############################\n"
	echo "Downloading the latest FreshRSS release..."
	tag=$(ftp -o - https://api.github.com/repos/FreshRSS/FreshRSS/releases/latest 2>/dev/null \
		| grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
	if [ -z "$tag" ]; then
		echo "Could not detect latest FreshRSS version automatically."
		printf "Enter a version tag manually (check https://github.com/FreshRSS/FreshRSS/releases): "
		read tag
	fi
	echo "Using FreshRSS $tag"
	cd /var/www
	ftp "https://github.com/FreshRSS/FreshRSS/archive/refs/tags/$tag.tar.gz"
	tar -xzf "$tag.tar.gz"
	mv "FreshRSS-$tag" freshrss
	rm "$tag.tar.gz"
	chown -R www:www /var/www/freshrss
fi

# CONFIGURE HTTPD
if ! grep -q "server \"$domain\"" /etc/httpd.conf 2>/dev/null; then
	printf "\n\n#############################\n"
	echo "Adding $domain to /etc/httpd.conf on port $port."
	echo "(Uses plain glob location patterns, not 'location match' -- FreshRSS's own"
	echo "docs show a regex example that does not work on OpenBSD's httpd.)"
	cat >> /etc/httpd.conf <<HTTPDEOF

server "$domain" {
	listen on 127.0.0.1 port $port
	root "/freshrss/p"
	directory index "index.php"
	location "/*.php" {
		fastcgi socket "/run/php-fpm.sock"
	}
	location "/*.php[/?]*" {
		fastcgi socket "/run/php-fpm.sock"
	}
}
HTTPDEOF
	if httpd -n; then
		rcctl reload httpd
	else
		echo "httpd config check failed -- fix /etc/httpd.conf by hand before continuing."
		exit 1
	fi
fi

# COMPLETE THE WEB SETUP WIZARD
if [ ! -f $(my wizardok) ]; then
	printf "\n\n#############################\n"
	echo "YOU NEED TO DO THIS NOW:"
	echo "1. On your computer, go to: http://127.0.0.1:$port/  (or set up access below first,"
	echo "   then use https://$domain/ once it's reachable)"
	echo "2. Finish the FreshRSS setup wizard. Choose SQLite for the database."
	echo "3. Log in, then go to the gear icon -> Authentication, and check"
	echo "   'Allow API access (required for mobile apps)'."
	echo "4. Go to the gear icon -> your profile, and set an API password"
	echo "   (a separate one from your login password -- mobile apps use this one)."
	printf "Hit [enter] once you've done all of that."
	read ui
	touch $(my wizardok)
fi

# INSTALL TAILSCALE
if [ ! -f $(my tsinstalled) ]; then
	pkg_add tailscale
	rcctl enable tailscaled
	rcctl start tailscaled
	touch $(my tsinstalled)
fi

if ! tailscale status >/dev/null 2>&1; then
	printf "\n\n#############################\n"
	echo "Log this server into your tailnet now."
	tailscale up
fi

# PUBLISH PRIVATELY OVER TAILSCALE
printf "\n\n#############################\n"
echo "Publishing the reader privately over Tailscale (not on the public internet at all)."
tailscale serve --bg --https=443 "http://127.0.0.1:$port"

echo ""
echo "If that said 'Serve is not enabled on your tailnet', open the URL it gave you,"
echo "enable Serve for your tailnet there, then run this script again."
echo ""
echo "If you use a filtering DNS provider (like NextDNS) on your own devices, also go to"
echo "https://login.tailscale.com/admin/dns and: confirm MagicDNS is on, add your provider"
echo "as a 'global nameserver', and turn on 'Override DNS servers'. Otherwise any device"
echo "that adopts Tailscale's DNS will lose the ability to resolve normal websites."

# AUTOMATE REFRESHING
if [ ! -f $(my cronok) ]; then
	phpbin=$(which php-$phpver 2>/dev/null)
	if [ -z "$phpbin" ]; then
		phpbin="/usr/local/bin/php-$phpver"
	fi
	# full path matters: cron's PATH does not include /usr/local/bin
	(crontab -l 2>/dev/null; echo "*/15 * * * * $phpbin -f /var/www/freshrss/app/actualize_script.php > /dev/null 2>&1") | crontab -
	touch $(my cronok)
	echo "Feeds will now refresh automatically every 15 minutes."
fi

# KEEP THE CHROOT COPIES FRESH (resolv.conf and cert.pem can go stale)
if [ ! -f $(my chrootcronok) ]; then
	(crontab -l 2>/dev/null; echo "0 3 * * * cp /etc/resolv.conf /var/www/etc/resolv.conf; cp /etc/ssl/cert.pem /var/www/etc/ssl/cert.pem") | crontab -
	touch $(my chrootcronok)
	echo "resolv.conf and cert.pem inside the chroot will now refresh daily at 3am."
fi

printf "\n\n#############################\n"
echo "Done. Your reader is private to your tailnet only, reachable at the address"
echo "'tailscale serve status' shows below."
tailscale serve status
echo ""
echo "On your phone: install Tailscale, sign in with the same account, then install"
echo "an RSS app that speaks FreshRSS's Google Reader API (Capy Reader is a clean,"
echo "ad-free option). Server = the address above, username = your FreshRSS username,"
echo "password = the API password you set during the wizard step."
echo ""
echo "Questions? https://nevrast.xyz/contact -- or just email stathis@nevrast.xyz"

#!/bin/sh
# ntfy.sh - add a private, Tailscale-only ntfy push notification server to a
# self-managed OpenBSD server with a working web server and TLS
# by Stathis, https://nevrast.xyz
# INSTALL: cd /root ; ftp https://nevrast.xyz/ntfy.sh ; sh ntfy.sh
# README:  https://nevrast.xyz/ntfy-tutorial.html

if [[ $(id -u) -ne 0 || $(uname) != "OpenBSD" ]]; then
	echo "must be run as root on OpenBSD, with a domain, SSH access, and a working web server already set up"
	exit 1
fi

mkdir -p /root/my
function my {
	echo "/root/my/ntfy_$1"
}

# LOCAL PORT?
if [ -f $(my port) ]; then
	port=$(cat $(my port))
else
	port=8091
	echo $port > $(my port)
fi

# TAILNET PUBLISH PORT?
if [ -f $(my tsport) ]; then
	tsport=$(cat $(my tsport))
else
	printf "What HTTPS port should ntfy be published on within your tailnet? (e.g. 8443 -- pick something other than 443 if that's already taken by another private service) "
	read ui
	tsport=$(echo "$ui" | tr -d '[:space:]')
	echo $tsport > $(my tsport)
fi
echo "Using local port $port, published on tailnet port $tsport"

# INSTALL BUILD DEPENDENCIES
if [ ! -f $(my depsok) ]; then
	printf "\n\n#############################\n"
	echo "Installing Go, git, and sqlite3 to build ntfy from source (no OpenBSD package exists)."
	pkg_add go git sqlite3
	touch $(my depsok)
fi

# BUILD NTFY
if [ ! -x /usr/local/bin/ntfy ]; then
	printf "\n\n#############################\n"
	echo "Building ntfy from source. This takes several minutes on a small instance -- that's normal."
	cd /root
	if [ ! -d /root/ntfy ]; then
		git clone https://github.com/binwiederhier/ntfy.git
	fi
	cd /root/ntfy
	mkdir -p dist/ntfy_openbsd_amd64 server/docs server/site
	touch server/docs/index.html server/site/app.html
	CGO_ENABLED=1 go build -o dist/ntfy_openbsd_amd64/ntfy \
		-tags sqlite_omit_load_extension,osusergo,netgo \
		-ldflags "-linkmode=external -extldflags=-static -s -w -X main.version=$(git describe --tag 2>/dev/null || echo dev) -X main.commit=$(git rev-parse --short HEAD) -X main.date=$(date +%s)"
	if [ ! -f dist/ntfy_openbsd_amd64/ntfy ]; then
		echo "Build failed -- no binary produced. Check the output above for the error."
		exit 1
	fi
	mv dist/ntfy_openbsd_amd64/ntfy /usr/local/bin
	chown root:bin /usr/local/bin/ntfy
	chmod 755 /usr/local/bin/ntfy
fi

# SERVICE USER + DIRECTORIES
if ! id _ntfy >/dev/null 2>&1; then
	useradd -c 'ntfy server' -d /var/empty -s /sbin/nologin _ntfy
fi
mkdir -p /etc/ntfy /var/cache/ntfy/attachments /var/db/ntfy
chown -R _ntfy /var/cache/ntfy /var/db/ntfy
chmod 750 /var/cache/ntfy /var/cache/ntfy/attachments /var/db/ntfy
# the directory itself must stay traversable, even though the files inside are locked down
chmod 755 /etc/ntfy

# CONFIGURE NTFY
if [ ! -f /etc/ntfy/server.yml ]; then
	cat > /etc/ntfy/server.yml <<CONFEOF
listen-http: "127.0.0.1:$port"
cache-file: "/var/cache/ntfy/cache.db"
attachment-cache-dir: "/var/cache/ntfy/attachments"
CONFEOF
	chown _ntfy /etc/ntfy/server.yml
	chmod 600 /etc/ntfy/server.yml
fi

# RC.D SERVICE
if [ ! -f /etc/rc.d/ntfy ]; then
	cat > /etc/rc.d/ntfy <<RCEOF
#!/bin/ksh
daemon="/usr/local/bin/ntfy"
daemon_flags="serve --config /etc/ntfy/server.yml"
daemon_user="_ntfy"
daemon_logger="daemon.info"

. /etc/rc.d/rc.subr

rc_bg="YES"
rc_cmd \$1
RCEOF
	chmod +x /etc/rc.d/ntfy
fi

rcctl enable ntfy
rcctl restart ntfy

if ! rcctl check ntfy >/dev/null 2>&1; then
	printf "\n\n#############################\n"
	echo "ntfy did not start. Check 'tail -30 /var/log/daemon' for the error, or run"
	echo "'/usr/local/bin/ntfy serve --config /etc/ntfy/server.yml' directly to see it live."
	exit 1
fi

# INSTALL TAILSCALE (skip if it's already set up, e.g. from the RSS reader script)
if ! command -v tailscale >/dev/null 2>&1; then
	pkg_add tailscale
	rcctl enable tailscaled
	rcctl start tailscaled
fi

if ! tailscale status >/dev/null 2>&1; then
	printf "\n\n#############################\n"
	echo "Log this server into your tailnet now."
	tailscale up
fi

# PUBLISH PRIVATELY OVER TAILSCALE
printf "\n\n#############################\n"
echo "Publishing ntfy privately over Tailscale (not on the public internet at all)."
tailscale serve --bg --https=$tsport "http://127.0.0.1:$port"

printf "\n\n#############################\n"
echo "Done. ntfy is private to your tailnet only, reachable at the address"
echo "'tailscale serve status' shows below."
tailscale serve status
echo ""
echo "On your phone: install the ntfy app, add a server using that address, and"
echo "subscribe to any topic name -- treat the topic name as a secret, not a label."
echo "Generate one with: openssl rand -hex 16"
echo ""
echo "Test from the server with:"
echo "  curl -d \"test message\" http://127.0.0.1:$port/yourtopic"
echo ""
echo "Questions? https://nevrast.xyz/contact -- or just email stathis@nevrast.xyz"

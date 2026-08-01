#!/bin/sh
# mail.sh - add self-hosted IMAP (dovecot) and outbound relay (opensmtpd + Postmark)
# to a self-managed OpenBSD server with a working web server, TLS, and inbound
# mail delivery already set up
# by Stathis, https://nevrast.xyz
# INSTALL: cd /root ; ftp https://nevrast.xyz/mail.sh ; sh mail.sh
# README:  https://nevrast.xyz/mail-tutorial.html

if [[ $(id -u) -ne 0 || $(uname) != "OpenBSD" ]]; then
	echo "must be run as root on OpenBSD, with a domain, SSH access, TLS, and opensmtpd already receiving mail for the domain"
	exit 1
fi

mkdir -p /root/my
function my {
	echo "/root/my/mail_$1"
}

# DOMAIN?
if [ -f $(my domain) ]; then
	domain=$(cat $(my domain))
else
	printf "What domain is your mail on? (e.g. yourdomain.com -- must match your existing TLS cert) "
	read ui
	domain=$(echo "$ui" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
	echo $domain > $(my domain)
fi
echo "Using $domain"

# MAIL USER?
if [ -f $(my mailuser) ]; then
	mailuser=$(cat $(my mailuser))
else
	printf "What system username should receive mail? (e.g. stathis) "
	read ui
	mailuser=$(echo "$ui" | tr -d '[:space:]')
	echo $mailuser > $(my mailuser)
fi
echo "Mailbox user: $mailuser"

certfile="/etc/ssl/$domain:443.crt"
keyfile="/etc/ssl/private/$domain:443.key"
if [ ! -f "$certfile" ] || [ ! -f "$keyfile" ]; then
	echo "Could not find $certfile / $keyfile."
	echo "This reuses the same certificate your web server already has for $domain -- set that up first."
	exit 1
fi

# INSTALL DOVECOT
if [ ! -x /usr/local/sbin/dovecot ]; then
	printf "\n\n#############################\n"
	echo "Installing dovecot."
	pkg_add dovecot
fi

# dovecot ships its config as examples only -- nothing is active until you copy it in
if [ ! -f /etc/dovecot/dovecot.conf ]; then
	printf "\n\n#############################\n"
	echo "Copying dovecot's example config into place (it ships inactive, same idea as"
	echo "OpenBSD's disabled-by-default PHP extensions)."
	cp -r /etc/dovecot/example-config/* /etc/dovecot/
fi

# CONFIGURE DOVECOT
if [ ! -f /etc/dovecot/local.conf ]; then
	printf "\n\n#############################\n"
	echo "Writing /etc/dovecot/local.conf"
	cat > /etc/dovecot/local.conf <<DOVEEOF
protocols = imap
listen = *, ::

ssl = required
ssl_cert = <$certfile
ssl_key = <$keyfile
disable_plaintext_auth = yes

mail_location = maildir:~/Maildir

# authenticate against the same system password database as SSH login users --
# NOT the same secret as an SSH key. If IMAP login fails with a correct-looking
# password, the account likely has no system password set: run 'passwd $mailuser'.
passdb {
	driver = bsdauth
}
userdb {
	driver = passwd
}
DOVEEOF
fi

if ! grep -q "local.conf" /etc/dovecot/dovecot.conf 2>/dev/null; then
	echo "!include local.conf" >> /etc/dovecot/dovecot.conf
fi

rcctl enable dovecot
rcctl restart dovecot

if ! rcctl check dovecot >/dev/null 2>&1; then
	printf "\n\n#############################\n"
	echo "dovecot did not start. Check 'tail -30 /var/log/maillog' for the error."
	exit 1
fi

# CONFIGURE OPENSMTPD: SUBMISSION + AUTH
if ! grep -q "port submission" /etc/mail/smtpd.conf 2>/dev/null; then
	printf "\n\n#############################\n"
	echo "Adding an authenticated submission listener (port 587) to /etc/mail/smtpd.conf."
	if ! grep -q "pki $domain" /etc/mail/smtpd.conf 2>/dev/null; then
		cat >> /etc/mail/smtpd.conf <<PKIEOF

pki $domain cert "$certfile"
pki $domain key "$keyfile"
PKIEOF
	fi
	cat >> /etc/mail/smtpd.conf <<SUBEOF
listen on all port submission tls-require pki "$domain" auth
SUBEOF
fi

# CONFIGURE OPENSMTPD: OUTBOUND RELAY VIA POSTMARK
if ! grep -q "table secrets" /etc/mail/smtpd.conf 2>/dev/null; then
	printf "\n\n#############################\n"
	echo "Outbound mail will relay through Postmark instead of being delivered directly --"
	echo "residential/cloud IPs get blocked by most inboxes without years of sending reputation."
	printf "Postmark server API token (used as both username and password): "
	stty -echo
	read token
	stty echo
	echo ""
	echo "postmark $token $token" > /etc/mail/secrets
	chown root:_smtpd /etc/mail/secrets 2>/dev/null
	chmod 640 /etc/mail/secrets

	cat >> /etc/mail/smtpd.conf <<RELAYEOF
table secrets file:/etc/mail/secrets
action outbound relay host smtp+tls://postmark@smtp.postmarkapp.com:587 auth <secrets>
match from any auth for any action outbound
match from local for any action outbound
RELAYEOF
fi

if smtpd -n; then
	rcctl reload smtpd
else
	echo "smtpd config check failed -- fix /etc/mail/smtpd.conf by hand before continuing."
	exit 1
fi

# PF: ALLOW IMAP + SUBMISSION
if ! grep -qE "port \{[^}]*\b(587|993)\b" /etc/pf.conf 2>/dev/null; then
	printf "\n\n#############################\n"
	echo "Adding a pf rule for ports 587 and 993 (pf evaluates 'quick' rules in order,"
	echo "so an extra overlapping rule here is harmless even if one already covers these)."
	cat >> /etc/pf.conf <<PFEOF
pass quick proto tcp from any to \$if port { 587, 993 } flags S/SA keep state
PFEOF
	pfctl -nf /etc/pf.conf && pfctl -f /etc/pf.conf
fi

# SET THE MAIL PASSWORD
if [ ! -f $(my pwok) ]; then
	printf "\n\n#############################\n"
	echo "Set the IMAP/SMTP login password for $mailuser now. This is separate from SSH"
	echo "key auth -- if you only ever log in over SSH with a key, this account may have"
	echo "no system password at all yet, and IMAP login will fail until you set one."
	passwd $mailuser
	touch $(my pwok)
fi

printf "\n\n#############################\n"
echo "Done. Mail client settings:"
echo "  Incoming (IMAP): $domain, port 993, SSL/TLS, username $mailuser"
echo "  Outgoing (SMTP): $domain, port 587, STARTTLS, username $mailuser"
echo "  Password: whatever you just set with 'passwd $mailuser'"
echo ""
echo "In Thunderbird specifically: the 'Re-test' button during account setup runs its"
echo "own autoconfiguration probe, not a real test of the fields you typed -- it will"
echo "often fail (or log a 'Pipelining not supported' / no-auth-attempt line on the"
echo "server) even when the settings are correct. Fill in the fields manually, click"
echo "Done, and test by actually sending/receiving a message instead of trusting Re-test."
echo ""
echo "Questions? https://nevrast.xyz/contact -- or just email stathis@nevrast.xyz"

# nevrast scripts

Two idempotent shell scripts for a self-managed OpenBSD server, written while building [nevrast.xyz](https://nevrast.xyz).

- **rss.sh** — adds a private, Tailscale-only FreshRSS reader. [Full write-up](https://nevrast.xyz/rss-tutorial.html).
- **ntfy.sh** — builds and runs a private, Tailscale-only [ntfy](https://ntfy.sh) push notification server from source, since no OpenBSD package exists for it. [Full write-up](https://nevrast.xyz/ntfy-tutorial.html).
- **mail.sh** — adds self-hosted IMAP (dovecot) and an authenticated Postmark relay for outbound mail, publicly reachable (not Tailscale-only, since phones need mail without a VPN running). [Full write-up](https://nevrast.xyz/mail-tutorial.html).

Both assume SSH access to an OpenBSD server that's already reachable over the network. Read a script before running it, the same as anything else you pipe into a shell.

by Stathis — https://nevrast.xyz

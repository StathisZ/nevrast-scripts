# nevrast scripts

Idempotent shell scripts for a self-managed OpenBSD server, written while building [nevrast.xyz](https://nevrast.xyz).

- **rss.sh** — adds a private, Tailscale-only FreshRSS reader. [Full write-up](https://nevrast.xyz/rss-tutorial.html).
- **ntfy.sh** — builds and runs a private, Tailscale-only [ntfy](https://ntfy.sh) push notification server from source, since no OpenBSD package exists for it. [Full write-up](https://nevrast.xyz/ntfy-tutorial.html).
- **mail.sh** — adds self-hosted IMAP (dovecot) and an authenticated Postmark relay for outbound mail, publicly reachable (not Tailscale-only, since phones need mail without a VPN running). [Full write-up](https://nevrast.xyz/mail-tutorial.html).
- **ntfy-update** — companion to `ntfy.sh`, not a standalone install: rebuilds and reinstalls `ntfy` from the latest tagged upstream release, on demand. Verifies the new binary before installing it, and automatically rolls back to the previous binary if it fails to start — a failed update can't leave the notification system itself silently dead. Reads its ntfy topic from `/etc/ntfy/notify.env` rather than hardcoding one (see the script's own header comment); the other three scripts prompt for their config interactively instead, since they're one-shot installers and this one is meant to be re-run.

All four assume SSH access to an OpenBSD server that's already reachable over the network. Read a script before running it, the same as anything else you pipe into a shell.

by Stathis — https://nevrast.xyz

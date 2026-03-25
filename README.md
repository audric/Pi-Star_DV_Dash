# Pi-Star DV Dashboard — SVXLink Fork

Fork of the [Pi-Star Digital Voice Dashboard](https://github.com/AndyTaylorTweet/Pi-Star_DV_Dash) with **SVXLink support for FM mode**.

This adds [SVXLink](https://github.com/sm0svx/svxlink) as a network gateway for FM, allowing FM repeaters to connect to SVXReflectors — the same way YSFGateway, P25Gateway, or M17Gateway handle their respective digital modes.

Audio flows via UDP between MMDVMHost and SVXLink — no sound card needed:

```
Radio RF <-> MMDVM modem <-> MMDVMHost [FM Network] <-> UDP (3810/4810) <-> SVXLink <-> SVXReflector
```

## What's Added

**Dashboard integration:**
- FM Network status indicator in the network status table
- SVXLink info panel in the sidebar (reflector host, callsign, process status)
- SVXLink config editor at `/admin/expert/edit_svxlink.php`

**Deployment tooling** (`deploy/`):
- `pistar-svxlink-installer.sh` — installs everything on an existing Pi-Star
- `svxlink_ctrl` — helper script for reflector connect/disconnect

## Installation on Pi-Star

SSH into your Pi-Star and run:

```bash
rpi-rw
cd /tmp
git clone https://github.com/audric/Pi-Star_DV_Dash.git
cd Pi-Star_DV_Dash/deploy
sudo ./pistar-svxlink-installer.sh --dashboard-repo https://github.com/audric/Pi-Star_DV_Dash
```

The installer will:
1. Install the `svxlink-server` package
2. Update the dashboard to this fork (future updates via `/admin/update.php`)
3. Deploy `svxlink_ctrl` to `/usr/local/sbin/`
4. Create a default SVXLink config at `/etc/svxlink/svxlink.conf` with UDP audio (auto-reads callsign from MMDVMHost)
5. Enable `[FM]` and `[FM Network]` in `/etc/mmdvmhost`
6. Configure sudoers for web-based control
7. Restart MMDVMHost and start SVXLink

### Post-install

1. Open `/admin/expert/edit_svxlink.php` in your browser
2. Set `AUTH_KEY` and reflector `HOST` in the `[ReflectorLogic]` section

### Uninstall

```bash
sudo /tmp/Pi-Star_DV_Dash/deploy/pistar-svxlink-installer.sh --uninstall
```

This restores the original upstream dashboard and removes the helper scripts.

## Upstream

Based on Pi-Star DV Dashboard by Andy Taylor (MW0MWZ), Hans-J. Barthen (DL5DI), and Kim Huebel (DG9VH).

- Upstream repo: https://github.com/AndyTaylorTweet/Pi-Star_DV_Dash
- Pi-Star project: https://www.pistar.uk
- SVXLink project: https://github.com/sm0svx/svxlink

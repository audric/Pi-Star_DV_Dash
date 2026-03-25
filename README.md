# Pi-Star DV Dashboard — SVXLink Fork

Fork of the [Pi-Star Digital Voice Dashboard](https://github.com/AndyTaylorTweet/Pi-Star_DV_Dash) with **SVXLink support for FM mode**.

This adds [SVXLink](https://github.com/sm0svx/svxlink) as a network gateway for FM, allowing FM repeaters to connect to SVXReflectors — the same way YSFGateway, P25Gateway, or M17Gateway handle their respective digital modes.

## What's Added

**Dashboard integration:**
- FM Network status indicator in the network status table
- SVXLink info panel in the sidebar (reflector host, talk group, callsign, process status)
- SVXLink Manager UI on the admin page (link/unlink reflectors, select talk group)

**Deployment tooling** (`deploy/`):
- `pistar-svxlink-installer.sh` — installs everything on an existing Pi-Star
- `svxlink_ctrl` — helper script for reflector connect/disconnect
- `SVXLinkHosts.txt` — default reflector host list

## Installation on Pi-Star

SSH into your Pi-Star and run:

```bash
cd /tmp
git clone https://github.com/audric/Pi-Star_DV_Dash.git
cd Pi-Star_DV_Dash/deploy
sudo ./pistar-svxlink-installer.sh --dashboard-repo https://github.com/audric/Pi-Star_DV_Dash
```

The installer will:
1. Install the `svxlink-server` package
2. Update the dashboard to this fork
3. Deploy `svxlink_ctrl` to `/usr/local/sbin/`
4. Install the reflector hosts file to `/usr/local/etc/SVXLinkHosts.txt`
5. Create a default SVXLink config at `/etc/svxlink/svxlink.conf` (auto-reads callsign from MMDVMHost)
6. Configure sudoers for web-based control

### Post-install

1. Edit `/etc/svxlink/svxlink.conf` to configure your audio devices and reflector auth key
2. Enable FM mode in MMDVMHost via the Pi-Star configuration page
3. Start SVXLink: `sudo systemctl start svxlink`
4. Use the SVXLink Manager in the admin dashboard to connect to a reflector

### Uninstall

```bash
sudo /tmp/Pi-Star_DV_Dash/deploy/pistar-svxlink-installer.sh --uninstall
```

This restores the original upstream dashboard and removes the helper scripts.

## Adding Custom Reflectors

Add reflectors to `/usr/local/etc/SVXLinkHosts.txt` or create `/root/SVXLinkHosts.txt` for user-specific entries. Format:

```
# Name          Host
MyReflector     reflector.example.com
```

## Upstream

Based on Pi-Star DV Dashboard by Andy Taylor (MW0MWZ), Hans-J. Barthen (DL5DI), and Kim Huebel (DG9VH).

- Upstream repo: https://github.com/AndyTaylorTweet/Pi-Star_DV_Dash
- Pi-Star project: https://www.pistar.uk
- SVXLink project: https://github.com/sm0svx/svxlink

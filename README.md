# kali-clean

Minimal i3 workstation for Kali Linux, built for Hack The Box, HackSmarter, CPTS-style labs, and other authorized practice environments. Flat near-black palette, Geist Mono, 1px borders, no shadows/transparency, and a compact Pebl3-inspired top bar.

![contour](.wallpaper/default.png)

## ⚠️ Warning

This project was developed with help from OpenAI's GPT-5.6 Sol. **Do not run `install.sh` blindly.** Review the installer and dotfiles yourself first. It invokes `sudo` for Kali packages/system changes and installs offensive-security tooling intended only for systems you own or are explicitly authorized to test.

## Install

Run as your normal Kali user, **not root**:

```bash
git clone https://github.com/USER/kali-clean
cd kali-clean
./install.sh
```

The only installation choice is the wallpaper. The installer then sets up the complete desktop/toolset, backs up managed dotfiles, verifies the resulting configuration, and prints a success message. Reboot afterwards and select **i3** from the login screen.

## QoL

- i3 + Alacritty + Rofi + Picom + Dunst; Zsh is the default shell.
- Top bar: CPU, RAM, disk, VPN IPv4, date/time. Left-click the VPN block to copy the IP.
- `Mod+Return` terminal, `Mod+d` launcher, `Mod+Shift+B` wallpaper picker, `Print` screenshot.
- Native tmux controls remain intact (`Ctrl-b %`, `Ctrl-b "`, `Ctrl-b c`, arrows, etc.) with a minimal monochrome theme.
- `export ip=...`, `ip2=...`, `domain=...`, or other exported lab variables persist across Zsh/tmux sessions until changed/unset.
- HTB/HackSmarter paths under `~`: `~/vpn`, `~/htb`, `~/hacksmarter`, `~/tools`, `~/labs`, `~/wordlists`.
- CPTS/AD tooling including SecLists, BloodHound CE/CLI, Impacket, NetExec, Certipy, Evil-WinRM-Py, Penelope, Ligolo-ng, Chisel, Kerberos prerequisites, and more.
- Impacket shortcuts such as `wmiexec`, `smbexec`, `psexec`, `secretsdump`, and `GetUserSPNs` work from any directory.

## Credits

Forked from [xct/kali-clean](https://github.com/xct/kali-clean) and heavily inspired by [Pebl3/kali-clean](https://github.com/Pebl3/kali-clean).

# kali-clean

Minimal i3 workstation for Kali, tailored for HTB / HackSmarter / CPTS-style labs. Flat, fast, dark, and intentionally compositor-free for reliable VMware use.

## ⚠️ Warning

Built with help from OpenAI's GPT-5.6 Sol. **Review `install.sh` and the dotfiles yourself before running them.** The installer uses `sudo` for Kali packages/system changes and installs offensive-security tooling intended only for systems and labs you are authorized to test.

## Install

Run as your normal user, **not root**:

```bash
git clone https://github.com/flarycen/kali-clean
cd kali-clean
./install.sh
```

Choose a wallpaper, wait for the success message, reboot, then select **i3** from the login screen.

## QoL

- `Mod+Enter` — terminal in the focused window's cwd
- `Mod+d` — Rofi
- `Mod+Shift+B` — wallpaper picker + optional curated Unsplash pack
- `Mod+Shift+T` — live theme picker: **Obsidian** or **Neon**
- `Mod+Shift+F` — Firefox
- `Mod+Shift+N` — Thunar
- top bar — CPU, RAM, disk, VPN IP, clock; click VPN IP to copy
- tmux keeps normal `Ctrl-b` bindings and has a clearly highlighted active pane
- `export ip=...`, `ip2=...`, `domain=...`, etc. persist across zsh/tmux sessions until changed or unset
- Impacket shortcuts work globally: `wmiexec`, `smbexec`, `psexec`, `secretsdump`, `GetUserSPNs`, etc.
- `~/htb`, `~/hacksmarter`, `~/vpn`, `~/tools`, `~/wordlists` are created automatically
- Picom is **not started**: this avoids the Thunar/GTK repaint bug confirmed under VMware
- VMware's user agent is started by i3 so host/guest clipboard and drag/drop work

The toolset includes the Kali-default stack plus CPTS/HTB essentials such as SecLists, BloodHound CE tooling, NetExec, Certipy, Evil-WinRM / evil-winrm-py, Impacket, Penelope, Ligolo-ng, Chisel, Kerberos prerequisites, web tooling, wordlists and common service clients.

## Themes

**Obsidian** is the default: monochrome, square, quiet, Pebl3-inspired. **Neon** keeps the same layout and reliability but adds controlled cyan/violet accents across i3, tmux, Alacritty, Rofi, Dunst, the shell prompt and Firefox chrome.

No compositor is required by either theme.

## Credits

Fork/update inspired by [xct/kali-clean](https://github.com/xct/kali-clean) and [Pebl3/kali-clean](https://github.com/Pebl3/kali-clean).

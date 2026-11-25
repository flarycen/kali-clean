~/tools — kali-clean layout
===========================

Every attacker-side tool runs by name from any directory, including the
spellings used in HTB Academy (secretsdump.py, GetUserSPNs.py, ssh2john.py,
gettgtpkinit.py, targetedKerberoast.py, Responder.py ...). `sudo NAME` works too.

Transfer a file to a target:   serve ~/tools/windows/potatoes 8000
(prints wget / iwr commands for your VPN IP, then starts an HTTP server)

windows/   binaries and scripts you upload to Windows targets
  SharpCollection/       nightly .NET builds: Seatbelt, SharpUp, Rubeus, Certify, Snaffler,
                         Inveigh, SharpView, SharpHound, Whisker, SweetPotato, Watson, ...
                         (use NetFramework_4.7_x64 first)
  potatoes/              GodPotato, PrintSpoofer, JuicyPotato, JuicyPotatoNG, RoguePotato
  RunasCs/ LaZagne/ PrivescCheck/ PingCastle/ Sysinternals/ kerbrute/
  winpeas/               winPEAS exe/bat/ps1                    (Kali: peass)
  sharphound/            SharpHound for BloodHound CE           (Kali: sharphound)
  mimikatz/ rubeus/ PowerSploit/ powercat/ nishang/ binaries/ (nc.exe, plink.exe, wget.exe)
  nc/                    nc.exe, nc64.exe
  Inveigh/ DomainPasswordSpray/ LAPSToolkit/ PowerUpSQL/ Invoke-TheHash/
  JAWS/ SessionGopher/ ADRecon/ Invoke-DOSfuscation/

linux/     scripts and binaries you upload to Linux targets
  linpeas.sh  pspy/  LinEnum/  linux-smart-enumeration/ (lse.sh)
  linux-exploit-suggester/ (les.sh)  static-binaries/ (static nmap, socat, ncat ...)

pivot/     chisel/ (all OS builds)  ligolo-ng/ (agents + proxy)  SocksOverRDP/
           rpivot/ (needs Python 2 on both ends)  ptunnel-ng/ (source)  dnscat2-powershell/

ad/        attacker-side AD scripts behind the commands targetedKerberoast.py,
           gettgtpkinit.py, getnthash.py, gets4uticket.py, gMSADumper.py,
           PetitPotam.py, noPac.py, noPac-scanner.py, CVE-2021-1675.py, windapsearch.py

passwords/ username-anarchy, firefox_decrypt, mimipenguin
web/       XXEinjector, webshells, laudanum

Wordlists: ~/wordlists (rockyou.txt, SecLists, PayloadsAllTheThings, kali)
Re-run ./install.sh from the kali-clean folder at any time to add anything missing.

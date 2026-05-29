#!/usr/bin/env python3
# Utility: Fetch Windows PDB symbols for DRAKVUF
# Typically run after a Windows Update to fetch updated PDBs
import sys
import os
import json
import urllib.request
import struct
import hashlib

GUEST = sys.argv[1] if len(sys.argv) > 1 else sys.exit("Usage: fetch-windows-symbols.py <guest-name> [pdb-guid]")
PDB_GUID = sys.argv[2] if len(sys.argv) > 2 else None

SYMBOL_DIR = f"/var/lib/drakvuf/symbols/{GUEST}"
os.makedirs(SYMBOL_DIR, exist_ok=True)

# Microsoft Symbol Server URL patterns
SYMSRV_URL = "https://msdl.microsoft.com/download/symbols/ntoskrnl.pdb/{guid}/ntoskrnl.pdb"

def fetch_pdb(guid: str) -> bool:
    """Download PDB from Microsoft Symbol Server"""
    url = SYMSRV_URL.format(guid=guid)
    dest = os.path.join(SYMBOL_DIR, "ntoskrnl.pdb")
    
    print(f"[*] Downloading PDB from {url}")
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Microsoft-Symbol-Server/6.11.0001.402"
        })
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = resp.read()
            with open(dest, "wb") as f:
                f.write(data)
            print(f"[+] PDB downloaded: {len(data)} bytes")
            return True
    except Exception as e:
        print(f"[!] Download failed: {e}")
        return False


def extract_guid_from_guest() -> str:
    """Extract PE GUID from guest's ntoskrnl.exe via qemu-agent"""
    # This requires qemu-guest-agent running in Windows guest
    # Returns a GUID string like "ABCDEF01234567890ABCDEF0123456781"
    try:
        # Check if dumpbin or similar tool is available in guest
        result = os.popen(f"virsh qemu-agent-command {GUEST} "
            "'{\"execute\":\"guest-exec\",\"arguments\":"
            "{\"path\":\"C:\\\\Windows\\\\System32\\\\ntoskrnl.exe\","
            "\"capture-output\":false}}' 2>/dev/null").read()
        
        # For now, instruct user to get GUID manually
        print("[!] Automatic GUID extraction requires guest tools")
        print("    Run in Windows guest:")
        print("    sigcheck64.exe -n -h C:\\Windows\\System32\\ntoskrnl.exe")
        return None
    except Exception as e:
        print(f"[!] Error: {e}")
        return None


def main():
    guid = PDB_GUID or extract_guid_from_guest()
    
    if not guid:
        print("""
[!] No PDB GUID provided. Manual steps:
  1. In Windows guest, run as admin:
     sigcheck64.exe -n -h C:\\Windows\\System32\\ntoskrnl.exe
  2. Copy the GUID/date string
  3. Run: fetch-windows-symbols.py <guest> <guid>
  
  Or use DRAKVUF's built-in PDB downloader:
  drakvuf --pdb-download --profile-dir {SYMBOL_DIR}
""")
        sys.exit(1)
    
    if fetch_pdb(guid):
        print(f"[+] PDB saved to {SYMBOL_DIR}/ntoskrnl.pdb")
        print("    Verify: drakvuf --check-symbols {SYMBOL_DIR}")
    else:
        print("[!] Failed to fetch PDB")
        sys.exit(1)


if __name__ == "__main__":
    main()

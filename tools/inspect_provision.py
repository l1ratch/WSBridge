import re, sys

path = r"C:\Users\sm171\.dsh\attachments\v1\files\e6\e64f134917f85d5e1a82b9083dd0c1f48cdd2c5bc367c635878b999972ac17d3\EYD9KX.mobileprovision"
data = open(path, "rb").read()

# mobileprovision is a CMS (PKCS#7) signed plist. Extract the embedded plist.
# The plist is between <?xml and </plist>
m = re.search(rb"<\?xml.*?</plist>", data, re.DOTALL)
if not m:
    print("No plist found")
    sys.exit(1)

plist = m.group(0).decode("utf-8", errors="replace")

# Extract entitlements section
ent_match = re.search(r"<key>Entitlements</key>\s*<dict>(.*?)</dict>", plist, re.DOTALL)
if ent_match:
    print("=== Entitlements ===")
    print(ent_match.group(1).strip()[:3000])
else:
    print("No Entitlements key found")

# Extract key identifiers
for key in ["application-identifier", "TeamIdentifier", "AppIDName", "UUID", "Name"]:
    m2 = re.search(rf"<key>{key}</key>\s*(?:<string>(.*?)</string>|<array>(.*?)</array>)", plist, re.DOTALL)
    if m2:
        val = m2.group(1) or m2.group(2)
        print(f"\n{key}: {val.strip()[:200]}")

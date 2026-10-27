#!/bin/bash
# Reseals a SOPS-encrypted k0s-cluster.yml after a hand edit of its plain parts.
#
# SOPS signs the whole file (the MAC covers every value, encrypted or not): changing a plain line by hand, a path or an option,
# makes `sops -d` fail with "MAC mismatch" (it happened with the audit flags, issue #203's follow-up). `sops -e` signs it again
# but rewrites the whole file with 2-space indents under lists, which the linter (.yamllint.yml) refuses. This keeps the layout
# of the committed file and carries over only what SOPS changes: the encrypted values (authPass) and the `sops:` block.
#
#   clusters/sops-reseal.sh clusters/svc/setup/k0s-cluster.yml [...]
#
# Needs SOPS_AGE_KEY_FILE (see .env). Nothing in clear is written outside a 0600 temporary file that is removed at the end.
set -euo pipefail
[ $# -ge 1 ] || { sed -n '2,13p' "$0"; exit 1; }
cd "$(dirname "$0")/.."
umask 077
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

for f in "$@"; do
  echo "$f"
  sops -d --ignore-mac "$f" > "$tmp/plain.yml"                       # the plaintext, whatever the MAC says
  ! grep -q "ENC\[" "$tmp/plain.yml" || { echo "  the plaintext still has ENC values: stop"; exit 1; }
  sops -e --filename-override "$f" "$tmp/plain.yml" > "$tmp/new.yml"  # signed again, but laid out the SOPS way
  python3 - "$f" "$tmp/new.yml" <<'PY'
import re, sys, yaml
path, new_path = sys.argv[1], sys.argv[2]
old = open(path).read()
new_text = open(new_path).read()
s_new = yaml.safe_load(new_text)["sops"]
# the encrypted values, in the order of the file
new_enc = [l.split(":", 1)[1].strip() for l in new_text.splitlines() if re.match(r"\s*\w+: ENC\[", l) and not l.lstrip().startswith("mac:")]
old_lines = old.split("\n"); k = 0
for i, l in enumerate(old_lines):
    if re.match(r"\s*\w+: ENC\[", l) and not l.lstrip().startswith("mac:"):
        ind = l[:len(l) - len(l.lstrip())]; key = l.strip().split(":", 1)[0]
        old_lines[i] = "%s%s: %s" % (ind, key, new_enc[k]); k += 1
assert k == len(new_enc), "different number of encrypted values"
head, block = "\n".join(old_lines).split("\nsops:\n", 1)
enc = s_new["age"][0]["enc"].rstrip("\n").split("\n")
m = re.search(r"(\n( *)enc: \|\n)((?:\2 +.*\n)+)", block)
assert m, "age block not found"
indent = re.match(r" *", m.group(3).split("\n")[0]).group(0)
block = block[:m.start(3)] + "".join(indent + e + "\n" for e in enc) + block[m.end(3):]
block = re.sub(r'(lastmodified: )"?[^\n"]+"?', r'\1"%s"' % s_new["lastmodified"], block, count=1)
block = re.sub(r"(mac: )ENC\[[^\n]+", lambda mo: mo.group(1) + s_new["mac"], block, count=1)
block = re.sub(r"(version: )[^\n]+", lambda mo: mo.group(1) + str(s_new["version"]), block, count=1)
open(path, "w").write(head + "\nsops:\n" + block)
PY
  sops -d "$f" | diff -q - "$tmp/plain.yml" >/dev/null && echo "  resealed: decrypts with a valid MAC, same plaintext" || { echo "  DIFFERENT after the round trip: git checkout -- $f"; exit 1; }
done

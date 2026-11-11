# The size of an instance: a profile of the tenant (s, m, l), or custom values. A tenant is its project and these three
# profiles, so this is what a user has at hand before they make their own.

# root_size <project> <instance>: the size of the root disk the instance ends up with, profiles included.
root_size() { INCUS config show "$2" --project "$1" --expanded | awk '/^  root:/{f=1} f && /size:/{print $2; exit}'; }

group_sizes() {
  section "sizes: an instance from a profile"
  ensure_tenant "$TA" owner-a@example.org || return
  local a="t-$TA"
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  ensure_instance "$TA" psmall deb "  profile: s
  running: false" || return
  eq "the VM uses the profile s" s "$(INCUS list psmall --project "$a" -f csv -c P)"
  eq "the profile gives it 1 vCPU" 1 "$(INCUS config get psmall limits.cpu --project "$a" --expanded)"
  eq "and 2 GiB of memory" 2GiB "$(INCUS config get psmall limits.memory --project "$a" --expanded)"
  eq "and a 64 GiB root disk" 64GiB "$(root_size "$a" psmall)"
  eq "nothing of that is set on the instance itself" "" "$(INCUS config get psmall limits.cpu --project "$a")$(INCUS config get psmall limits.memory --project "$a")"
  eq "its only device of its own is eth0" eth0 "$(INCUS config device list psmall --project "$a")"
  eq "the instance says Ready" True "$(cond instances.phorge.fr psmall "$a" Ready)"
  local out; out=$(K -n "$a" patch instances.phorge.fr psmall --type merge -p '{"spec":{"cpu":2}}' --dry-run=server 2>&1)
  match "giving a cpu to an instance that has a profile is refused" 'not both' "$out"
  out=$(K -n "$a" patch instances.phorge.fr psmall --type merge -p '{"spec":{"profile":null}}' --dry-run=server 2>&1)
  match "and so is removing the profile without giving a size" 'cpu, memoryMiB and diskGiB are all required' "$out"

  section "sizes: the profile is what the guest gets"
  K -n "$a" patch instances.phorge.fr psmall --type merge -p '{"spec":{"running":true}}' >/dev/null
  if wait_until 240 "incus agent" vm_up "$a" psmall; then
    pass "the VM from the profile s boots"
    eq "guest has 1 CPU" 1 "$(vm_sh "$a" psmall 'nproc')"
    match "guest memory is about 2 GiB" '^(1[89][0-9]{5}|20[0-9]{5})$' "$(vm_sh "$a" psmall "awk '/MemTotal/{print \$2}' /proc/meminfo")"
    match "root filesystem was grown to about 64 GiB" '^6[0-4]\.[0-9]G' "$(vm_sh "$a" psmall "lsblk -bdno SIZE \$(findmnt -no SOURCE / | sed 's/p\\?[0-9]*\$//') | awk '{printf \"%.1fG\\n\", \$1/1073741824}'")"
  else fail "the VM from the profile s boots" "no answer after 240 s"; fi
  K -n "$a" delete instances.phorge.fr psmall --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
  check "it is deleted in the foreground" gone instances.phorge.fr psmall "$a"

  section "sizes: a profile that does not fit the limits, a profile that does not exist"
  # A profile of the user that is above the limits of the tenant (4 vCPU, 16 GiB of memory and 300 GiB of disk against 2, 4 and 128): Incus
  # refuses the VM, the limits decide. The profile l (4 vCPU, 8 GiB, 256 GiB) is above them too, and the tenant keeps it, untouched.
  ensure_profile "$TA" huge 4 16384 300 || return
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: toobig, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: deb}, network: net, profile: huge, running: false}
YAML
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: noprof, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: deb}, network: net, profile: does-not-exist, running: false}
YAML
  sleep 60
  eq "an instance whose profile is above the limits is never Ready" "" "$(cond instances.phorge.fr toobig "$a" Ready | grep -x True)"
  match "and it is a limit of the tenant that refuses it" 'limits' "$(mr_msgs "$a" toobig)"
  note "a profile above the limits of the tenant: $(mr_msgs "$a" toobig | cut -c1-240)"
  eq "an instance whose profile does not exist is never Ready" "" "$(cond instances.phorge.fr noprof "$a" Ready | grep -x True)"
  eq "and no VM is created in Incus for either" "" "$(INCUS list --project "$a" -f csv -c n | grep -xE 'toobig|noprof')"
  K -n "$a" delete instances.phorge.fr toobig noprof --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  check "both can be deleted" gone instances.phorge.fr toobig "$a"
  # the refusal of the Usage lasts a few seconds after the instances are gone, and Crossplane replays the deletion by itself
  K -n "$a" delete profiles.phorge.fr huge --wait=false >/dev/null 2>&1
  wait_until 180 "profile gone" gone profiles.phorge.fr huge "$a" && pass "and so can the profile" || fail "and so can the profile" "still there after 180 s"

  section "sizes: from custom values to a profile"
  ensure_instance "$TA" sw deb "  running: false" || return
  eq "the custom VM has its own limits" 1 "$(INCUS config get sw limits.cpu --project "$a")"
  K -n "$a" patch instances.phorge.fr sw --type merge -p '{"spec":{"profile":"s","cpu":null,"memoryMiB":null,"diskGiB":null}}' >/dev/null
  if wait_until 180 "profile s" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus list sw --project $a -f csv -c P') == s ]]"; then
    pass "the VM moves to the profile s in place"
    eq "its own limits are gone, the profile decides" "" "$(INCUS config get sw limits.cpu --project "$a")$(INCUS config get sw limits.memory --project "$a")"
    eq "the root disk is the profile's" 64GiB "$(root_size "$a" sw)"
    eq "the instance stays Ready" True "$(cond instances.phorge.fr sw "$a" Ready)"
  else fail "the VM moves to the profile s in place" "$(mr_msgs "$a" sw)"; fi
  K -n "$a" delete instances.phorge.fr sw --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
}

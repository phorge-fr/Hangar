# Instance: a VM in the tenant's project, from a managed Image.

group_instance() {
  section "instance: a running VM"
  ensure_tenant "$TA" medium owner-a@example.org || return
  local a="t-$TA"
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  # a throw-away key pair, so the key injected through cloud-init can really be checked
  local key; key=$(ssh-keygen -q -t ed25519 -N '' -C e2e -f "$(mktemp -u)" -P '' 2>/dev/null; true)
  local kf; kf=$(mktemp -u); ssh-keygen -q -t ed25519 -N '' -C "e2e-$RUN_ID" -f "$kf"; key=$(cut -d' ' -f1,2 "$kf.pub"); rm -f "$kf" "$kf.pub"
  E2E_KEY=$key
  ensure_instance "$TA" vm1 deb "  cpu: 2
  memoryMiB: 1536
  diskGiB: 12
  sshPublicKeys: ['$key']" || return

  eq "Synced=True" True "$(cond instances.phorge.fr vm1 "$a" Synced)"
  wait_until 180 "state Running" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr vm1 -o jsonpath='{.status.state}') == Running ]]"
  eq "status.state" Running "$(sget instances.phorge.fr "$a" vm1 '{.status.state}')"
  wait_until 240 "status.ipv4" bash -c "[[ -n \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr vm1 -o jsonpath='{.status.ipv4}') ]]"
  local ip; ip=$(sget instances.phorge.fr "$a" vm1 '{.status.ipv4}')
  local pa; pa=$(net_prefix "$TA")
  match "status.ipv4 is in the tenant's subnet $pa.0/24" "^${pa//./\\.}\\.[0-9]+" "$ip"
  eq "and matches what Incus reports" "$(vm_ip "$a" vm1)" "${ip%% *}"

  section "instance: what reaches Incus"
  eq "type" virtual-machine "$(INCUS list --project "$a" -f csv -c n,t | grep '^vm1,' | cut -d, -f2 | tr 'A-Z' 'a-z' | sed 's/virtual-machine/virtual-machine/')"
  eq "limits.cpu" 2 "$(INCUS config get vm1 limits.cpu --project "$a")"
  eq "limits.memory" 1536MiB "$(INCUS config get vm1 limits.memory --project "$a")"
  eq "security.nesting off by default" false "$(INCUS config get vm1 security.nesting --project "$a")"
  eq "root disk size" 12GiB "$(INCUS config device get vm1 root size --project "$a")"
  eq "root disk pool" remote "$(INCUS config device get vm1 root pool --project "$a")"
  eq "it uses the tenant profile" phorge "$(INCUS list vm1 --project "$a" -f csv -c P)"
  has "the key goes into the cloud-init user data" "$key" "$(INCUS config get vm1 cloud-init.user-data --project "$a")"
  match "which is a #cloud-config document" '^#cloud-config' "$(INCUS config get vm1 cloud-init.user-data --project "$a")"
  eq "the VM is placed on one of the compute nodes" 1 "$(INCUS list --project "$a" -f csv -c n,L | grep -cE '^vm1,comp-opti-0[123]')"

  section "instance: inside the guest"
  if wait_until 240 "incus agent" vm_up "$a" vm1; then
    pass "the incus agent answers (guest booted)"
    eq "guest has 2 CPUs" 2 "$(vm_sh "$a" vm1 'nproc')"
    match "guest memory is about 1.5 GiB" '^(1[3-5][0-9]{5}|1[0-9]{6})$' "$(vm_sh "$a" vm1 "awk '/MemTotal/{print \$2}' /proc/meminfo")"
    wait_until 120 "cloud-init done" bash -c "ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus exec vm1 --project $a -- cloud-init status' | grep -q done"
    has "the injected ssh key is in an authorized_keys file" "${key#* }" "$(vm_sh "$a" vm1 'cat /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys 2>/dev/null')"
    match "root filesystem was grown to about 12 GiB" '^(1[0-2]|9)\.[0-9]G|^1[0-2]G|^11\.' "$(vm_sh "$a" vm1 "lsblk -bdno SIZE \$(findmnt -no SOURCE / | sed 's/p\\?[0-9]*\$//') | awk '{printf \"%.1fG\\n\", \$1/1073741824}'")"
  else fail "the incus agent answers (guest booted)" "no answer after 240 s"; fi

  section "instance: stopped, nested, and the limits of the plan"
  ensure_instance "$TA" vm2 deb "  running: false
  nesting: true" || return
  eq "running: false leaves the VM Stopped" STOPPED "$(INCUS list --project "$a" -f csv -c n,s | grep '^vm2,' | cut -d, -f2)"
  wait_until 60 "state" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr vm2 -o jsonpath='{.status.state}') == Stopped ]]"
  eq "status.state reports Stopped" Stopped "$(sget instances.phorge.fr "$a" vm2 '{.status.state}')"
  eq "nesting: true sets security.nesting" true "$(INCUS config get vm2 security.nesting --project "$a")"
  ensure_instance "$TA" vm3 deb "  running: false" || return
  # medium allows 3 VMs: the 4th must be refused by Incus, and say why
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: vm4, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: deb}, running: false}
YAML
  wait_until 120 "vm4 synced=False" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr vm4 -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].status}') == False ]]"
  match "the 4th VM on a medium plan is refused with Incus's message" 'Reached maximum number of instances' "$(mr_msgs "$a" vm4)"
  eq "and it did not get created in Incus" 3 "$(INCUS list --project "$a" -f csv -c n | grep -c .)"
  K -n "$a" delete instances.phorge.fr vm4 --wait=true --timeout=120s >/dev/null 2>&1

  # free a slot first: with 3 VMs the instance-count limit would refuse bigdisk before the disk limit is reached
  K -n "$a" delete instances.phorge.fr vm3 --wait=true --timeout=200s >/dev/null 2>&1
  wait_until 120 "vm3 gone" bash -c "! ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus list --project $a -f csv -c n' | grep -qx vm3"
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: bigdisk, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: deb}, running: false, diskGiB: 500}
YAML
  sleep 45
  eq "a disk above the plan's total is never Ready" "" "$(cond instances.phorge.fr bigdisk "$a" Ready | grep -x True)"
  match "and it is the disk limit that refuses it, not the instance count" 'limits.disk|disk' "$(mr_msgs "$a" bigdisk)"
  nomatch "(not 'Reached maximum number of instances')" 'maximum number of instances' "$(mr_msgs "$a" bigdisk)"
  note "500 GiB on a 100 GiB plan: $(mr_msgs "$a" bigdisk | cut -c1-300)"
  K -n "$a" delete instances.phorge.fr bigdisk --wait=true --timeout=120s >/dev/null 2>&1

  section "instance: an image that is not there"
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: noimg, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: does-not-exist}, running: false}
YAML
  sleep 45
  eq "an Instance whose Image does not exist is never Ready" "" "$(cond instances.phorge.fr noimg "$a" Ready | grep -x True)"
  eq "and nothing is created in Incus for it" "" "$(INCUS list --project "$a" -f csv -c n | grep -x noimg)"
  K -n "$a" delete instances.phorge.fr noimg --wait=true --timeout=120s >/dev/null 2>&1
  check "it can be deleted" gone instances.phorge.fr noimg "$a"

  # free the quota for the other groups: only vm1 stays, it is the one they use
  K -n "$a" delete instances.phorge.fr vm2 --wait=true --timeout=200s >/dev/null 2>&1
}

# Instance: a VM in the tenant's project, from a managed Image.

group_instance() {
  section "instance: a running VM"
  ensure_tenant "$TA" owner-a@example.org || return
  local a="t-$TA"
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  # a throw-away key pair, so the key injected through cloud-init can really be checked
  local key; key=$(ssh-keygen -q -t ed25519 -N '' -C e2e -f "$(mktemp -u)" -P '' 2>/dev/null; true)
  local kf; kf=$(mktemp -u); ssh-keygen -q -t ed25519 -N '' -C "e2e-$RUN_ID" -f "$kf"; key=$(cut -d' ' -f1,2 "$kf.pub"); rm -f "$kf" "$kf.pub"
  E2E_KEY=$key
  # 1 vCPU: a tenant has 2 in all, 2 VMs, 4 GiB and 129 GiB of disk (state included), shared by every group
  ensure_instance "$TA" vm1 deb "  cpu: 1
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
  eq "limits.cpu" 1 "$(INCUS config get vm1 limits.cpu --project "$a")"
  eq "limits.memory" 1536MiB "$(INCUS config get vm1 limits.memory --project "$a")"
  eq "security.nesting off by default" false "$(INCUS config get vm1 security.nesting --project "$a")"
  eq "security.secureboot on by default" true "$(INCUS config get vm1 security.secureboot --project "$a")"
  eq "status.nesting and status.secureBoot say what is in force when the instance did not say" "false true" "$(sget instances.phorge.fr "$a" vm1 '{.status.nesting} {.status.secureBoot}')"
  eq "root disk size" 12GiB "$(INCUS config device get vm1 root size --project "$a")"
  eq "root disk pool" remote "$(INCUS config device get vm1 root pool --project "$a")"
  eq "a custom instance uses the project's empty default profile" default "$(INCUS list vm1 --project "$a" -f csv -c P)"
  eq "its only network device is eth0 on the network it asked for" "eth0 net" "$(INCUS config device list vm1 --project "$a" | grep -v '^root$' | tr '\n' ' ' | sed 's/ $//') $(INCUS config device get vm1 eth0 network --project "$a")" 
  has "the key goes into the cloud-init user data" "$key" "$(INCUS config get vm1 cloud-init.user-data --project "$a")"
  match "which is a #cloud-config document" '^#cloud-config' "$(INCUS config get vm1 cloud-init.user-data --project "$a")"
  eq "the VM is placed on one of the compute nodes" 1 "$(INCUS list --project "$a" -f csv -c n,L | grep -cE '^vm1,comp-opti-0[123]')"

  section "instance: inside the guest"
  if wait_until 240 "incus agent" vm_up "$a" vm1; then
    pass "the incus agent answers (guest booted)"
    eq "guest has 1 CPU" 1 "$(vm_sh "$a" vm1 'nproc')"
    match "guest memory is about 1.5 GiB" '^(1[3-5][0-9]{5}|1[0-9]{6})$' "$(vm_sh "$a" vm1 "awk '/MemTotal/{print \$2}' /proc/meminfo")"
    wait_until 120 "cloud-init done" bash -c "ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus exec vm1 --project $a -- cloud-init status' | grep -q done"
    has "the injected ssh key is in an authorized_keys file" "${key#* }" "$(vm_sh "$a" vm1 'cat /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys 2>/dev/null')"
    match "root filesystem was grown to about 12 GiB" '^(1[0-2]|9)\.[0-9]G|^1[0-2]G|^11\.' "$(vm_sh "$a" vm1 "lsblk -bdno SIZE \$(findmnt -no SOURCE / | sed 's/p\\?[0-9]*\$//') | awk '{printf \"%.1fG\\n\", \$1/1073741824}'")"
  else fail "the incus agent answers (guest booted)" "no answer after 240 s"; fi

  section "instance: stopped, nested, and the limits of the tenant"
  ensure_instance "$TA" vm2 deb "  running: false
  nesting: true" || return
  eq "running: false leaves the VM Stopped" STOPPED "$(INCUS list --project "$a" -f csv -c n,s | grep '^vm2,' | cut -d, -f2)"
  wait_until 60 "state" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr vm2 -o jsonpath='{.status.state}') == Stopped ]]"
  eq "status.state reports Stopped" Stopped "$(sget instances.phorge.fr "$a" vm2 '{.status.state}')"
  eq "nesting: true sets security.nesting" true "$(INCUS config get vm2 security.nesting --project "$a")"
  # The count of instances (2) is checked on the project in the tenant group and by the API's own tests: vm1 and vm2 fill it, and
  # the CPU (2 in all, 1 for each) too, so a third VM is never tried here.
  # free the nested VM first: its disk and CPU would be counted next to the 500 GiB that must be refused for the disk
  K -n "$a" delete instances.phorge.fr vm2 --wait=true --timeout=200s >/dev/null 2>&1
  wait_until 120 "vm2 gone" bash -c "! ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus list --project $a -f csv -c n' | grep -qx vm2"
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: bigdisk, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: deb}, network: net, cpu: 1, memoryMiB: 1024, diskGiB: 500, running: false}
YAML
  sleep 45
  eq "a disk above the limit of the tenant is never Ready" "" "$(cond instances.phorge.fr bigdisk "$a" Ready | grep -x True)"
  match "and it is the disk limit that refuses it, not the instance count" 'limits.disk|disk' "$(mr_msgs "$a" bigdisk)"
  nomatch "(not 'Reached maximum number of instances')" 'maximum number of instances' "$(mr_msgs "$a" bigdisk)"
  note "500 GiB on a 128 GiB limit: $(mr_msgs "$a" bigdisk | cut -c1-300)"
  K -n "$a" delete instances.phorge.fr bigdisk --wait=true --timeout=120s >/dev/null 2>&1

  section "instance: an image that is not there"
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: noimg, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: does-not-exist}, network: net, profile: s, running: false}
YAML
  sleep 45
  eq "an Instance whose Image does not exist is never Ready" "" "$(cond instances.phorge.fr noimg "$a" Ready | grep -x True)"
  eq "and nothing is created in Incus for it" "" "$(INCUS list --project "$a" -f csv -c n | grep -x noimg)"
  K -n "$a" delete instances.phorge.fr noimg --wait=true --timeout=120s >/dev/null 2>&1
  check "it can be deleted" gone instances.phorge.fr noimg "$a"


  section "instance: an image that does not boot with secure boot"
  # alpine/3.22/cloud is refused by Incus with secure boot on ("incompatible with secureboot"): the Instance
  # kind has spec.secureBoot for that, and the VM must then come up like any other.
  ensure_image "$TA" alp "$IMG_ALPINE" e2e-alp || return
  ensure_instance "$TA" alpvm alp "  secureBoot: false" || return
  eq "secureBoot: false reaches Incus" false "$(INCUS config get alpvm security.secureboot --project "$a")"
  wait_until 180 "alpine running" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr alpvm -o jsonpath='{.status.state}') == Running ]]"
  eq "the Alpine VM runs" Running "$(sget instances.phorge.fr "$a" alpvm '{.status.state}')"
  eq "the Alpine VM has no problems to report" "" "$(sget instances.phorge.fr "$a" alpvm '{.status.problems}')"
  K -n "$a" delete instances.phorge.fr alpvm --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
  check "and it deletes in the foreground" gone instances.phorge.fr alpvm "$a"

  # free the quota for the other groups: only vm1 stays, it is the one they use
  K -n "$a" delete instances.phorge.fr vm2 --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
}

# The Network kind: a tenant comes without a network, the user deploys the ones they need.

group_networks() {
  section "networks: a network deployed by the user"
  ensure_tenant "$TA" medium owner-a@example.org || return
  local a="t-$TA"
  ensure_network "$TA" net || return
  eq "Synced=True" True "$(cond networks.phorge.fr net "$a" Synced)"
  eq "status.problems is empty" "" "$(sget networks.phorge.fr "$a" net '{.status.problems}')"
  eq "it is an OVN network of the tenant's project" "net,ovn" "$(INCUS network list --project "$a" -f csv -c n,t | grep '^net,')"
  eq "on the UPLINK" UPLINK "$(INCUS network get net network --project "$a")"
  eq "NATed by default" true "$(INCUS network get net ipv4.nat --project "$a")"
  has "the description reaches Incus" "e2e network" "$(INCUS network show net --project "$a")"
  eq "the Network resource is Ready next to its Usage" "True True" "$(cond network.network.incus.m.crossplane.io net "$a" Ready) $(cond usages.protection.crossplane.io network-net-keeps-namespace "$a" Ready)"
  local cidr; cidr=$(tenant_net "$TA" net)
  match "ipv4.address is a /24 chosen by Incus" '^[0-9]+\.[0-9]+\.[0-9]+\.1/24$' "$cidr"
  if in_phorge_range "$cidr"; then fail "the subnet $cidr is outside the router's VLANs and the LAN/containers ranges"; else pass "the subnet $cidr is outside the router's VLANs and the LAN/containers ranges"; fi
  eq "no other Incus network uses the same subnet" 1 "$(INCUS network list --all-projects -f csv -c e,n,4 | grep -c ",${cidr}\$\|,${cidr%/*}/")"
  local ext; ext=$(INCUS network get net volatile.network.ipv4.address --project "$a")
  match "its OVN router took an external address in 10.11.0.10-250" '^10\.11\.0\.([1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|250)$' "$ext"

  section "networks: changed in place, and the plan's limit"
  K -n "$a" patch networks.phorge.fr net --type merge -p '{"spec":{"description":"e2e renamed"}}' >/dev/null
  wait_until 150 "description" bash -c "ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus network show net --project $a' | grep -q 'e2e renamed'"
  has "a new description is applied in place" "e2e renamed" "$(INCUS network show net --project "$a")"
  eq "and the network stays Ready" True "$(cond networks.phorge.fr net "$a" Ready)"
  ensure_network "$TA" second "  ipv4: 10.77.1.1/24" || return
  eq "the address the user chose is the one Incus has" 10.77.1.1/24 "$(INCUS network get second ipv4.address --project "$a")"
  eq "and the status says it" 10.77.1.1/24 "$(sget networks.phorge.fr "$a" second '{.status.ipv4}')"
  eq "a network the user gave no address says none, Incus chose one" "" "$(sget networks.phorge.fr "$a" net '{.status.ipv4}')"
  eq "a network is NATed, there is no way to turn it off" true "$(INCUS network get second ipv4.nat --project "$a")"
  eq "and Incus made it in the Created state" CREATED "$(INCUS network list --project "$a" -f csv -c n,s | grep '^second,' | cut -d, -f2)"
  # the medium plan allows 2 networks: the 3rd is refused by Incus and says why
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Network
metadata: {name: third, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {description: over the plan}
YAML
  wait_until 120 "third synced=False" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get networks.phorge.fr third -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].status}') == False ]]"
  eq "the 3rd network of a medium plan is never Ready" "" "$(cond networks.phorge.fr third "$a" Ready | grep -x True)"
  match "and Incus says the networks limit is reached" 'Networks limit has been reached' "$(mr_msgs "$a" third)"
  eq "nothing was created in Incus for it" "" "$(INCUS network list --project "$a" -f csv -c n | grep -x third)"
  K -n "$a" delete networks.phorge.fr third --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  check "it can be deleted" gone networks.phorge.fr third "$a"
  K -n "$a" delete networks.phorge.fr second --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  check "a network is deleted in the foreground" gone networks.phorge.fr second "$a"
  eq "and it is gone from Incus once the Network is gone (the foreground delete waits for it)" "" "$(INCUS network list --project "$a" -f csv -c n | grep -x second)"

  section "networks: a network and an image of the same name live together"
  # Every kind keeps the namespace with a Usage of its own: named after the name alone, the Usage of a network and the one of an
  # image of the same name would be the same object, and the second would be refused (phorge-fr/Hangar#396).
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  ensure_network "$TA" deb || return
  eq "the network named like the image is Ready, as the image is" "True True" "$(cond networks.phorge.fr deb "$a" Ready) $(cond images.phorge.fr deb "$a" Ready)"
  eq "each has its own Usage on the namespace" "network-deb-keeps-namespace image-deb-keeps-namespace" "$(K -n "$a" get usages.protection.crossplane.io network-deb-keeps-namespace image-deb-keeps-namespace -o name 2>/dev/null | sed 's#.*/##' | tr '\n' ' ' | sed 's/ $//')"
  K -n "$a" delete networks.phorge.fr deb --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  check "and the network is deleted without the image" gone networks.phorge.fr deb "$a"

  section "networks: subnets chosen by Incus, across tenants"
  ensure_tenant "$TB" small owner-b@example.org || return
  ensure_tenant "$TN" small n@example.org || return
  ensure_network "$TB" net || return
  ensure_network "$TN" net || return
  local t seen="" dup=0 bad=0 c
  for t in "$TA" "$TB" "$TN"; do
    c=$(tenant_net "$t" net); [[ -z $c ]] && continue
    note "network of ${t#e2e-$RUN_ID-}: $c"
    [[ " $seen " == *" ${c%.*} "* ]] && dup=1; seen="$seen ${c%.*}"
    in_phorge_range "$c" && bad=1
  done
  eq "the networks of the e2e tenants are pairwise distinct" 0 "$dup"
  eq "none of them is in a router VLAN or the LAN/containers ranges" 0 "$bad"
  nomatch "tenant B sees none of A's networks (separate projects)" "$(net_prefix "$TA" net)" "$(INCUS network list --project "t-$TB" -f csv -c n,4)"
  eq "a network of the same name in two tenants is two Incus networks" 2 "$(INCUS network list --all-projects -f csv -c e,n | grep -cE "^t-($TA|$TB),net$")"
  eq "a small plan holds one network: the one just made" 1 "$(INCUS network list --project "t-$TB" -f csv -c n | grep -c .)"

  section "networks: an instance that uses it"
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  ensure_instance "$TA" netvm deb "  running: false" || return
  eq "the VM is on the network it asked for" net "$(INCUS config device get netvm eth0 network --project "$a")"
  # a CPU or memory added to a running VM must come online by itself: the rule is written at the first boot (Hangar#435)
  match "the VM carries the udev rule that onlines a hot-added CPU and memory" '40-vm-hotadd.rules' "$(INCUS config get netvm cloud-init.user-data --project "$a")"
  local out; out=$(K -n "$a" delete networks.phorge.fr net --wait=false 2>&1)
  match "deleting a network that a VM uses is refused, and names the VM" 'in-use by.*Instance/netvm' "$out"
  eq "the network is still there" net "$(sget networks.phorge.fr "$a" net '{.metadata.name}')"
  eq "and so is the VM, still attached" net "$(INCUS config device get netvm eth0 network --project "$a")"
  K -n "$a" delete instances.phorge.fr netvm --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
  check "the VM is deleted in the foreground" gone instances.phorge.fr netvm "$a"
  if wait_until 180 "network gone" gone networks.phorge.fr net "$a"; then pass "the refused deletion is replayed: the network is gone once the VM is gone"
  else fail "the refused deletion is replayed once the VM is gone" "still there after 180 s: $(K -n "$a" get usages.protection.crossplane.io -o name | tr '\n' ' ')"; fi
  # the refused deletion was a background one: the Network is gone from Kubernetes while Incus is still deleting it
  wait_until 120 "network gone from Incus" bash -c "! ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus network list --project $a -f csv -c n' | grep -qx net"
  eq "and it goes from Incus too" "" "$(INCUS network list --project "$a" -f csv -c n | grep -x net)"
  ensure_network "$TA" net || return

  section "networks: an instance on a network that does not exist"
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: nonet, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: deb}, network: does-not-exist, profile: s, running: false}
YAML
  sleep 45
  eq "an Instance on a missing network is never Ready" "" "$(cond instances.phorge.fr nonet "$a" Ready | grep -x True)"
  eq "and no VM is created in Incus for it" "" "$(INCUS list --project "$a" -f csv -c n | grep -x nonet)"
  K -n "$a" delete instances.phorge.fr nonet --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  check "it can be deleted" gone instances.phorge.fr nonet "$a"
}

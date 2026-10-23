# What a VM can and cannot reach, from inside the guest. Needs the incus agent, so VMs with a
# cloud image. Relies on the router's rules (Network repo): VLAN to VLAN is dropped, the Internet
# is reachable, and the tenant network is NATed by its OVN router.

# can_connect <project> <vm> <host> <port>: a TCP connect from the guest, 6 s at most.
can_connect() { vm_sh "$1" "$2" "timeout 6 bash -c '</dev/tcp/$3/$4'" >/dev/null 2>&1; }

group_network() {
  ensure_tenant "$TA" medium owner-a@example.org || return
  ensure_tenant "$TB" small owner-b@example.org || return
  local a="t-$TA" b="t-$TB"
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  ensure_image "$TB" deb "$IMG_DEBIAN" || return
  ensure_instance "$TA" vm1 deb "  cpu: 2
  memoryMiB: 1536" || return
  ensure_instance "$TB" b1 deb || return
  wait_until 300 "vm1 agent" vm_up "$a" vm1 || { fail "VM in A answers over the incus agent"; return; }
  wait_until 300 "b1 agent" vm_up "$b" b1 || { fail "VM in B answers over the incus agent"; return; }
  wait_until 120 "ips" bash -c "[[ -n \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus list vm1 --project $a -f csv -c 4') ]]"
  local ipa ipb; ipa=$(vm_ip "$a" vm1); ipb=$(vm_ip "$b" b1)

  section "network: addressing and routing"
  local pa pb; pa=$(net_prefix "$TA"); pb=$(net_prefix "$TB")
  match "VM in A has an address in its tenant's subnet $pa.0/24" "^${pa//./\\.}\\." "$ipa"
  match "VM in B has an address in its tenant's subnet $pb.0/24" "^${pb//./\\.}\\." "$ipb"
  match "default route goes through the tenant's OVN router (.1)" "default via ${pa//./\\.}\\.1" "$(vm_sh "$a" vm1 'ip -4 route show default')"
  check "the gateway answers" vm_sh "$a" vm1 "timeout 8 ping -c2 -W2 $pa.1"
  match "DNS resolves a public name to an IPv4 address" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ' "$(vm_sh "$a" vm1 'getent ahostsv4 images.linuxcontainers.org | head -1')"
  match "the resolver is the router's, on comp-ns" '10\.11\.0\.254' "$(vm_sh "$a" vm1 'cat /etc/resolv.conf; resolvectl status 2>/dev/null')"

  section "network: Internet access (NAT through comp-ns)"
  check "TCP 443 to a public address" can_connect "$a" vm1 1.1.1.1 443
  check "TCP 443 to a public name" can_connect "$a" vm1 images.linuxcontainers.org 443
  if vm_sh "$a" vm1 'command -v curl' >/dev/null 2>&1; then
    match "an HTTPS request completes" '^HTTP/' "$(vm_sh "$a" vm1 'curl -sSI -m 15 https://images.linuxcontainers.org | head -1')"
  else skip "HTTPS request (no curl in the image)"; fi
  if vm_sh "$a" vm1 'command -v ping' >/dev/null 2>&1; then
    check "ICMP to a public address" vm_sh "$a" vm1 'ping -c2 -W3 9.9.9.9'
    check "a 1500-byte packet (DF set) crosses to the Internet: the path MTU is clean (Network#12)" vm_sh "$a" vm1 'ping -c2 -W3 -M do -s 1472 9.9.9.9'
  else skip "ICMP checks (no ping in the image)"; fi
  eq "guest interface MTU" 1500 "$(vm_sh "$a" vm1 'cat /sys/class/net/e*/mtu | head -1')"

  section "network: what a tenant must not reach"
  local t; for t in "10.2.0.10 443 core ingress" "10.1.0.1 6443 control API server" "10.4.0.1 2049 NFS on stor" "10.10.0.1 22 Incus node on comp-ew" "192.168.2.254 443 router management"; do
    set -- $t
    if can_connect "$a" vm1 "$1" "$2"; then fail "tenant VM cannot reach $3 ($1:$2)" "the connection succeeded"; else pass "tenant VM cannot reach $3 ($1:$2)"; fi
  done

  section "network: tenants are isolated from each other"
  if can_connect "$a" vm1 "$ipb" 22; then fail "A cannot reach B's VM ($ipb)"; else pass "A cannot reach B's VM ($ipb)"; fi
  if can_connect "$b" b1 "$ipa" 22; then fail "B cannot reach A's VM ($ipa)"; else pass "B cannot reach A's VM ($ipa)"; fi
  if vm_sh "$a" vm1 "timeout 6 ping -c1 -W3 $ipb" >/dev/null 2>&1; then fail "A cannot ping B's VM"; else pass "A cannot ping B's VM"; fi

  section "network: nothing is exposed"
  if timeout 5 ping -c1 -W2 "$ipa" >/dev/null 2>&1; then fail "the VM is not reachable from this machine ($ipa)" "ping answered"; else pass "the VM is not reachable from this machine ($ipa)"; fi
  if timeout 6 bash -c "</dev/tcp/$ipa/22" 2>/dev/null; then fail "its port 22 is closed from here" "connected"; else pass "its port 22 is closed from here"; fi
}

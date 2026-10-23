# Deleting things: order, orphans, and what happens to objects removed behind Crossplane's back.
# Tracks the behaviour discussed in the "Delete a Tenant's children before the tenant itself" issue.

now() { date +%s; }

# delete_timeline <tenant> [extra kubectl delete args]: deletes the Tenant and samples Kubernetes and
# Incus every 4 s until everything is gone. Sets T_VM T_IMG T_NET T_PROJ T_MR T_K8S (seconds after the
# delete), ORPHAN=1 if the Tenant object was gone while the managed resources or Incus still held
# something, PROJ_BEFORE_VM=1 if the project vanished while the VM still existed.
delete_timeline() {
  local t=$1; shift; local d="t-$t" t0 deadline snap hp hv hi hn kt km
  T_VM=; T_IMG=; T_NET=; T_PROJ=; T_MR=; T_K8S=; ORPHAN=0; PROJ_BEFORE_VM=0
  t0=$(now); deadline=$((t0+900))
  K -n phorge-system delete tenants.phorge.fr "$t" --wait=false "$@" >/dev/null
  while (( $(now) < deadline )); do
    snap=$(ssh -o BatchMode=yes root@$INCUS_HOST "LC_ALL=C; p=$d
      incus project list -f csv -c n | grep -qx \$p && echo proj=1 || echo proj=0
      incus list --project \$p -f csv -c n 2>/dev/null | grep -q . && echo vm=1 || echo vm=0
      incus image list --project \$p -f csv -c F 2>/dev/null | grep -q . && echo img=1 || echo img=0
      incus network list --project \$p -f csv -c n 2>/dev/null | grep -qx default && echo net=1 || echo net=0" 2>/dev/null)
    hp=$(grep -o 'proj=.' <<<"$snap" | cut -d= -f2); hv=$(grep -o 'vm=.' <<<"$snap" | cut -d= -f2)
    hi=$(grep -o 'img=.' <<<"$snap" | cut -d= -f2); hn=$(grep -o 'net=.' <<<"$snap" | cut -d= -f2)
    K -n phorge-system get tenants.phorge.fr "$t" >/dev/null 2>&1 && kt=1 || kt=0
    [[ -n $(K get managed -A -o name 2>/dev/null | grep "$t") ]] && km=1 || km=0
    local el=$(( $(now)-t0 ))
    [[ $hv == 0 && -z $T_VM ]] && T_VM=$el
    [[ $hi == 0 && -z $T_IMG ]] && T_IMG=$el
    [[ $hn == 0 && -z $T_NET ]] && T_NET=$el
    [[ $hp == 0 && -z $T_PROJ ]] && T_PROJ=$el
    [[ $km == 0 && -z $T_MR ]] && T_MR=$el
    [[ $kt == 0 && -z $T_K8S ]] && T_K8S=$el
    [[ $hp == 0 && $hv == 1 ]] && PROJ_BEFORE_VM=1
    [[ $kt == 0 && ( $km == 1 || $hp == 1 || $hv == 1 || $hn == 1 ) ]] && ORPHAN=1
    [[ $hp == 0 && $kt == 0 && $km == 0 ]] && break
    sleep 4
  done
}
timeline_note() { note "$1 (seconds after the delete): VM gone ${T_VM:-never}, image ${T_IMG:-never}, network ${T_NET:-never}, Incus project ${T_PROJ:-never}, managed resources ${T_MR:-never}, Tenant object ${T_K8S:-never}"; }
no_leftovers() { # <tenant>
  local d="t-$1"
  eq "$1: no namespace left" "" "$(K get ns "$d" -o name 2>/dev/null)"
  eq "$1: no managed resource left" 0 "$(K get managed -A -o name 2>/dev/null | grep -c "$1")"
  eq "$1: no Incus project left" "" "$(INCUS project list -f csv -c n | grep -x "$d")"
  eq "$1: no Incus network left" "" "$(INCUS network list --all-projects -f csv -c e,n | grep "^$d,")"
}

group_deletion() {
  section "deletion: a tenant that holds an image and a running VM, deleted in the foreground"
  ensure_tenant "$TD" small owner-d@example.org || return
  local d="t-$TD"
  # Debian, not Alpine: alpine/3.22/cloud is not secure-boot compatible, Incus refuses to start it
  # ("incompatible with secureboot") and the Instance kind has no way to turn secureboot off.
  ensure_image "$TD" alp "$IMG_DEBIAN" || return
  ensure_instance "$TD" run1 alp || return
  wait_until 120 "VM running" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $d get instances.phorge.fr run1 -o jsonpath='{.status.state}') == Running ]]"
  eq "the VM is running before the delete" Running "$(sget instances.phorge.fr "$d" run1 '{.status.state}')"
  eq "the project holds the VM" 1 "$(INCUS list --project "$d" -f csv -c n | grep -c .)"

  delete_timeline "$TD" --cascade=foreground
  timeline_note "foreground delete"
  eq "the Incus project was never gone while the VM still existed" 0 "$PROJ_BEFORE_VM"
  eq "everything converged within 15 minutes" yes "$([[ -n $T_PROJ && -n $T_K8S && -n $T_MR ]] && echo yes || echo no)"
  eq "with a foreground delete the Tenant object stays until its resources and Incus are gone (usable as a completion signal)" 0 "$ORPHAN"
  no_leftovers "$TD"

  section "deletion: the same, in the default (background) mode"
  ensure_tenant "$TX" small x@example.org || return
  delete_timeline "$TX"
  timeline_note "background delete"
  if (( ORPHAN )); then note "background delete: the Tenant object is gone ${T_K8S}s after the command while its resources lasted ${T_MR}s and the Incus project ${T_PROJ}s: absence of the Tenant does NOT mean it is deleted"
  else note "background delete: the Tenant object stayed until everything was gone"; fi
  no_leftovers "$TX"

  section "deletion: an object removed behind Crossplane's back"
  ensure_tenant "$TA" medium owner-a@example.org || return
  local a="t-$TA"
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  ensure_instance "$TA" oob deb "  running: false" || return
  INCUS delete oob --project "$a" >/dev/null
  eq "the VM was deleted directly in Incus" "" "$(INCUS list --project "$a" -f csv -c n | grep -x oob)"
  if wait_until 360 "recreated" bash -c "ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus list --project $a -f csv -c n' | grep -qx oob"; then
    note "a VM deleted in Incus is RECREATED by Crossplane (blank, from the image): data in it is lost, the XR does not mean 'this VM'"
  else
    note "a VM deleted in Incus is not recreated within 6 minutes; the Instance says Ready=$(cond instances.phorge.fr oob "$a" Ready) Synced=$(cond instances.phorge.fr oob "$a" Synced)"
  fi
  K -n "$a" delete instances.phorge.fr oob --wait=true --timeout=200s >/dev/null 2>&1
  check "the Instance can still be deleted afterwards" gone instances.phorge.fr oob "$a"

  section "deletion: an Image that an Instance still uses"
  ensure_instance "$TA" vm1 deb || return
  K -n "$a" delete images.phorge.fr deb --wait=true --timeout=200s >/dev/null 2>&1
  if gone images.phorge.fr deb "$a"; then
    note "the Image was deleted although vm1 was created from it: Incus does not refuse, the Instance is $(cond instances.phorge.fr vm1 "$a" Ready | sed 's/True/still Ready/;s/False/not Ready/')"
  else
    note "deleting an Image that vm1 uses is held back: $(cond_msg images.phorge.fr deb "$a" Synced | cut -c1-160)"
  fi
  eq "in both cases the VM keeps running" "RUNNING" "$(INCUS list vm1 --project "$a" -f csv -c s)"
}

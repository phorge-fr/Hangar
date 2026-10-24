# Image: pulled by Incus into the tenant's own project (features.images=true).

img_fp() { INCUS image list --project "$1" -f csv -c l,F | grep -F "$2," | cut -d, -f2; }

group_image() {
  section "image: pull, fingerprint, aliases"
  ensure_tenant "$TA" medium owner-a@example.org || return
  ensure_tenant "$TB" small owner-b@example.org || return
  local a="t-$TA" b="t-$TB"
  eq "tenant B has no image before it asks for one" 0 "$(INCUS image list --project "$b" -f csv -c F | grep -c .)"

  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  local fp; fp=$(sget images.phorge.fr "$a" deb '{.status.fingerprint}')
  match "status.fingerprint is a SHA-256" '^[a-f0-9]{64}$' "$fp"
  eq "the image is in the tenant's project, under its alias" "$fp" "$(img_fp "$a" e2e-deb)"
  eq "architecture is x86_64 (the compute nodes')" x86_64 "$(INCUS image list --project "$a" -f csv -c F,a | grep "^$fp," | cut -d, -f2)"
  eq "it is a virtual machine image" virtual-machine "$(INCUS image list --project "$a" -f csv -c F,t | grep "^$fp," | cut -d, -f2 | tr -d ' ' | sed 's/VIRTUAL-MACHINE/virtual-machine/')"
  eq "tenant B still sees nothing (images are per project)" 0 "$(INCUS image list --project "$b" -f csv -c F | grep -c .)"
  eq "and the default project did not receive it" 0 "$(INCUS image list --project default -f csv -c F | grep -c "$fp")"

  section "image: another tenant pulls the same image on its own"
  ensure_image "$TB" deb "$IMG_DEBIAN" || return
  eq "same name in two tenants does not clash; same content, same fingerprint" "$fp" "$(sget images.phorge.fr "$b" deb '{.status.fingerprint}')"

  section "image: a second image in the same tenant, and its deletion"
  # a second, small image: only pulled and deleted here, never started (alpine does not boot with secureboot)
  ensure_image "$TA" alp "$IMG_ALPINE" e2e-alp || return
  local fp2; fp2=$(sget images.phorge.fr "$a" alp '{.status.fingerprint}')
  eq "two images, two distinct fingerprints" 1 "$([[ $fp != "$fp2" && -n $fp2 ]] && echo 1 || echo 0)"
  K -n "$a" delete images.phorge.fr alp --wait=true --timeout=180s >/dev/null 2>&1
  wait_until 90 "managed image gone" bash -c "! kubectl --context $E2E_CONTEXT -n $a get managed -o name | grep -q image.incus"
  K -n "$a" get managed -o name 2>/dev/null | grep -q '/alp' && fail "deleting the Image removes the managed resource" "still there after 90 s: $(K -n "$a" get managed -o name | tr '\n' ' ')" || pass "deleting the Image removes the managed resource"
  wait_until 120 "image gone from Incus" bash -c "[[ -z \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus image list --project $a -f csv -c l' | grep e2e-alp) ]]"
  eq "and the Incus image is gone" "" "$(INCUS image list --project "$a" -f csv -c l | grep e2e-alp)"
  eq "the first image is untouched" "$fp" "$(img_fp "$a" e2e-deb)"

  section "image: a source that does not exist"
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Image
metadata: {name: nope, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec:
  source: {name: does-not/exist/at-all}
YAML
  sleep 60
  eq "an unknown image name never becomes Ready" "" "$(cond images.phorge.fr nope "$a" Ready | grep -x True)"
  eq "and leaves nothing in the project" "" "$(INCUS image list --project "$a" -f csv -c l | grep -i nope)"
  note "unknown image reports: $(mr_msgs "$a" nope | cut -c1-300)"
  match "status.problems on the Image says why (the Incus error, not just 'Unready resources')" "doesn't exist" "$(sget images.phorge.fr "$a" nope '{.status.problems}')"
  K -n "$a" delete images.phorge.fr nope --wait=true --timeout=120s >/dev/null 2>&1
  check "a failed Image can be deleted" gone images.phorge.fr nope "$a"
}

# The namespace guards of the compositions. The namespace of an XR is used as the Incus project name,
# so an Instance in `default` must never reach the real `default` project. These need the controllers
# but no tenant: nothing is created in Incus.

_guard() { # <kind> <spec yaml> <ns> <name>
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: %s\nmetadata: {name: %s, namespace: %s, labels: {%s: "%s"}}\nspec:\n%s\n' "$1" "$4" "$3" "$LABEL" "$RUN_ID" "$2" | K apply -f - >/dev/null
  TRACK_XR+=("${1,,}s $3 $4")
}

group_guards() {
  section "guards: XRs in the wrong namespace"
  local hash; hash=$(printf 'b%.0s' {1..64})
  _guard Tenant "  {owner: g@example.org}" default "e2e-$RUN_ID-g"
  _guard Image "  source: {name: $IMG_ALPINE}" default "e2e-$RUN_ID-g"
  _guard Instance "  imageRef: {name: nope}" default "e2e-$RUN_ID-g"
  _guard Membership "  {subject: {kind: User, name: g@example.org}, role: admin}" default "e2e-$RUN_ID-g"
  _guard ApiKey "  {hash: $hash, scopes: [tenant:read]}" default "e2e-$RUN_ID-g"
  local kind rx
  declare -A WANT=([tenants]='belongs in phorge-system' [images]='belongs in a tenant namespace' [instances]='belongs in a tenant namespace' [memberships]='belongs in a tenant namespace' [apikeys]='belongs in a tenant namespace')
  for kind in tenants images instances memberships apikeys; do
    wait_until 90 "$kind synced condition" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n default get $kind.phorge.fr e2e-$RUN_ID-g -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].status}') == False ]]"
    match "$kind in default is refused with an explicit message" "${WANT[$kind]}" "$(cond_msg $kind.phorge.fr "e2e-$RUN_ID-g" default Synced)"
    eq "$kind in default is never Ready" "" "$(cond $kind.phorge.fr "e2e-$RUN_ID-g" default Ready | grep -x True)"
  done
  eq "nothing composed for them (no managed resource carries their name)" "0" \
     "$(K get managed -A -o name 2>/dev/null | grep -c "e2e-$RUN_ID-g")"
  nomatch "no Incus instance, image or project was created in the default project" "e2e-$RUN_ID" \
     "$(INCUS list --project default -f csv -c n; INCUS image list --project default -f csv -c l; INCUS project list -f csv -c n)"

  section "guards: a t-* namespace without a tenant"
  local ns="t-e2e-$RUN_ID-ghost"
  K create ns "$ns" >/dev/null && K label ns "$ns" "$LABEL=$RUN_ID" >/dev/null && TRACK_NS+=("$ns")
  _guard Image "  source: {name: $IMG_ALPINE}" "$ns" ghost
  _guard Membership "  {subject: {kind: User, name: g@example.org}, role: viewer}" "$ns" ghost
  sleep 45
  note "Image in a namespace without tenant: Ready=$(cond images.phorge.fr ghost "$ns" Ready) Synced=$(cond images.phorge.fr ghost "$ns" Synced), Incus says: $(K -n "$ns" get images.phorge.fr ghost -o json | jq -r '[.status.conditions[]? | select(.status!="True") | .message] | first // "-"' | cut -c1-160)"
  eq "an Image in a namespace without tenant is not Ready" "" "$(cond images.phorge.fr ghost "$ns" Ready | grep -x True)"
  eq "and creates no Incus project" "" "$(INCUS project list -f csv -c n | grep -x "$ns")"
  if [[ $(cond memberships.phorge.fr ghost "$ns" Ready) == True ]]; then
    note "Membership in a namespace without tenant is Ready: it writes a tuple for project:$ns, which does not exist (nothing checks that a Tenant owns the namespace)"
  else note "Membership in a namespace without tenant is not Ready: $(cond_msg memberships.phorge.fr ghost "$ns" Ready)"; fi
}

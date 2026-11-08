#!/usr/bin/env bash
# End-to-end tests of the phorge.fr API kinds, against the real control cluster and Incus cluster.
# See README.md. Usage: ./run.sh [--sweep] [--keep] [--list] [tier|group...]    (no group = the smoke tier)
cd "$(dirname "$0")" || exit 1
source ./lib.sh

GROUPS_ALL=(admission guards tenant image instance sizes profiles access networks network update deletion)
for g in "${GROUPS_ALL[@]}"; do source "./groups/$g.sh"; done

SELECTED=()
for a in "$@"; do
  case $a in
    --list)  printf '%s\n' "${GROUPS_ALL[@]}"; exit 0 ;;
    --sweep) SWEEP=1 ;;
    --keep)  export E2E_KEEP=1 ;;
    fast)    SELECTED+=(admission guards) ;;
    # The tiers, from the cheapest: smoke needs no image and no VM, standard adds the groups that use stopped VMs and one image
    # pull, full is everything (about an hour). See README.md.
    smoke)    SELECTED+=(admission guards tenant) ;;
    standard) SELECTED+=(admission guards tenant networks profiles) ;;
    full)     SELECTED+=("${GROUPS_ALL[@]}") ;;
    *)       [[ " ${GROUPS_ALL[*]} " == *" $a "* ]] || { echo "unknown group: $a"; exit 2; }; SELECTED+=("$a") ;;
  esac
done
(( ${#SELECTED[@]} )) || SELECTED=(admission guards tenant)
# a tier and a group of the same name give the group once
mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | awk '!seen[$0]++')

exec 9>/tmp/phorge-e2e.lock
flock -n 9 || { echo "another e2e run is in progress"; exit 2; }
[[ ${SWEEP:-0} == 1 ]] && sweep
preflight || exit 2
trap 'cleanup; summary; exit $?' EXIT
trap 'exit 130' INT TERM

echo "run $RUN_ID on context $E2E_CONTEXT, Incus via root@$INCUS_HOST, groups: ${SELECTED[*]}"
for g in "${SELECTED[@]}"; do
  t0=$SECONDS; "group_$g"
  TIMES+=("$g $((SECONDS - t0))")
done

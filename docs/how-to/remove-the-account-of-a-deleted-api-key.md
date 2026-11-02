---
type: how-to
audience: administrator cleaning up the accounts that old API keys left
verified: 2026-11-02
---

# Remove the account of a deleted API key

Deleting an `ApiKey` deletes its service account in Authentik with its token (the identity of Crossplane may delete the accounts it created, see [the reference](../reference/phorge-api-kinds.md#apikey)), so there is normally nothing to clean. The keys made before that change, and a key whose creation failed half way, left an account `apikey-<name>` without any credential in Authentik. It does no harm, and an administrator removes it when it is worth the clean-up.

The commands run inside the authentik server of `core` (`ak shell`, no token of administration) and print only their result lines: the rest of the output is authentik's start-up log.

## List the leftovers

To see them first: the accounts of the keys, with the number of tokens each one holds. An account with `tokens=0` is a leftover, unless its `ApiKey` still exists.

```bash
kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c '
from authentik.core.models import User, Token
for u in User.objects.filter(username__startswith="apikey-").order_by("username"):
    print("RESULT", u.username, u.type, "tokens=%d" % Token.objects.filter(user=u).count())
' 2>&1 | grep '^RESULT'
```

## Remove every leftover

One command. It deletes each service account `apikey-*` that holds no token and whose `ApiKey` no longer exists, and it prints the accounts it deleted. An account with a token, or whose `ApiKey` exists, is never touched. It stops before deleting anything if `control` cannot be read.

```bash
KEEP=$(kubectl --context control -n phorge-keys get apikeys.phorge.fr -o jsonpath='{.items[*].metadata.name}') && \
kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c "
from authentik.core.models import User, Token
keep = set('$KEEP'.split())
n = 0
for u in User.objects.filter(username__startswith='apikey-', type='service_account'):
    if u.username[len('apikey-'):] in keep or Token.objects.filter(user=u).exists():
        continue
    print('RESULT deleted', u.username); u.delete(); n += 1
print('RESULT', n, 'account(s) deleted')
" 2>&1 | grep '^RESULT'
```

An `ApiKey` created with the name of a leftover account would be refused by Authentik, and stays `Ready=False`. Remove the account first, or pick another name.

---
type: how-to
audience: administrator cleaning up after deleted API keys
verified: 2026-11-02
---

# Remove the account of a deleted API key

Deleting an `ApiKey` removes its token, its Secret and its tuples, but the service account `apikey-<name>` stays in Authentik without any credential: the identity that Crossplane uses cannot delete users (see [the reference](../reference/phorge-api-kinds.md#apikey)). It does no harm, and an administrator removes it when it is worth the clean-up.

The commands run inside the authentik server of `core` (`ak shell`, no token of administration) and print only their result lines: the rest of the output is authentik's start-up log.

## List the leftovers

The accounts of the keys, with the number of tokens each one holds. An account with `tokens=0` is a leftover, unless its `ApiKey` still exists.

```bash
kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c '
from authentik.core.models import User, Token
for u in User.objects.filter(username__startswith="apikey-").order_by("username"):
    print("RESULT", u.username, u.type, "tokens=%d" % Token.objects.filter(user=u).count())
' 2>&1 | grep '^RESULT'
```

## Remove one

1. Set the name of the key, without the `apikey-` prefix (`apikey-e2e-313` is the key `e2e-313`), and check that the key is really gone: the command must answer `NotFound`.

   ```bash
   NAME=e2e-313
   kubectl --context control -n phorge-keys get apikeys.phorge.fr "$NAME"
   ```

2. Delete the account. It refuses an account that still has a token, and it only touches a service account whose name starts with `apikey-`.

   ```bash
   kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c "
   from authentik.core.models import User, Token
   u = User.objects.filter(username='apikey-$NAME', type='service_account').first()
   if u is None:
       print('RESULT no such service account: apikey-$NAME')
   elif Token.objects.filter(user=u).exists():
       print('RESULT refused, the account still has a token')
   else:
       u.delete()
       print('RESULT deleted apikey-$NAME')
   " 2>&1 | grep '^RESULT'
   ```

An `ApiKey` created later with the same name would be refused by Authentik while the account exists, and stays `Ready=False`. Remove the account first, or pick another name.

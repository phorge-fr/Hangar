---
status: accepted
date: 2026-10-31
decision-makers: l-nmch
---

# Build the frontend with SvelteKit, UnoCSS and pnpm

## Context and problem statement

The showcase site and the console of Phorge share one repository, `phorge-console`, hosted on the `svc` cluster ([0008](0008-keep-svc-and-host-the-frontend-on-it.md)). Which framework and build tool do they use, and at which host name is the showcase site served ([phorge-fr/.github#49](https://github.com/phorge-fr/.github/issues/49))?

## Decision drivers

* Open source, light on resources, fast first load.
* Optimized CSS.
* SEO and GEO for the showcase site: the content is in the first HTML response, not built by the browser.
* One stack for the showcase site and the console.
* A stack that lasts.
* The tools are pnpm and Node.

## Considered options

* Go with `templ`, HTMX and UnoCSS, in one binary.
* Astro in server mode, with UnoCSS.
* SvelteKit with UnoCSS.
* A single-page application (rejected at the outset: bad for SEO, tokens in the browser).

## Decision outcome

Chosen option: "SvelteKit with UnoCSS", with pnpm, deployed with `adapter-node`. The showcase site is served at `phorge.fr`, and `www.phorge.fr` redirects to it. The console is served at `console.phorge.fr`.

* The pages of the showcase site are prerendered to static HTML.
* The console is rendered on the server. Its session lives on the Node server, so the tokens stay out of the browser; it uses a confidential OIDC client in Authentik, defined by blueprint, instead of the public client shared with the CLI.
* Interactive views of the console, such as the Incus terminal sessions, are Svelte components.

### Consequences

* Good, because the showcase site is static HTML at the first response, which suits SEO and GEO, and the console and the showcase site share one toolchain.
* Good, because UnoCSS only generates the classes the pages use, through its Vite plugin.
* Bad, because a Node server uses more memory than a Go binary, on `svc` nodes that already use 58 % to 71 % of theirs ([0008](0008-keep-svc-and-host-the-frontend-on-it.md)).
* Bad, because a pnpm dependency tree is a supply-chain surface: commit `pnpm-lock.yaml`, run `pnpm audit` in the CI and let Renovate keep it current, as `phorge-api` does for Go.
* Neutral: the SEO and GEO work is still to do on the showcase site (structured data, sitemap, `hreflang`, `noindex` on the console). An `llms.txt` file has no proven effect.

### Confirmation

Measure the memory of the `svc` nodes before and after the first deployment, and revisit if a node stays above 80 %. Check the Core Web Vitals of the showcase site once it is online.

## Pros and cons of the options

### Go with `templ`, HTMX and UnoCSS

* Good, because it is one small binary, with no JavaScript runtime.
* Bad, because HTMX swaps HTML, so the console needs a server that renders it, and the maintainer already uses Node and pnpm: it would add a second toolchain for no gain.

### Astro in server mode, with UnoCSS

* Good, because it is the best fit for a content-heavy showcase site.
* Bad, because the interactivity of an application-like console is split into separate islands.

### SvelteKit with UnoCSS

* Good, because it prerenders the showcase site, renders the console on the server, and keeps the interactive views as small components.
* Bad, because of the Node server memory above.

## More information

* [phorge-fr/.github#49](https://github.com/phorge-fr/.github/issues/49), [phorge-fr/.github#11](https://github.com/phorge-fr/.github/issues/11), [phorge-fr/.github#12](https://github.com/phorge-fr/.github/issues/12).
* The edge routes of the showcase hosts are in [phorge-fr/Network#32](https://github.com/phorge-fr/Network/issues/32), the one of the console in [phorge-fr/Network#30](https://github.com/phorge-fr/Network/issues/30).
* I did not check the current versions of SvelteKit, UnoCSS or Node, nor measured the memory of a SvelteKit server.

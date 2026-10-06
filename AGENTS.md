# AGENTS.md

Notes for AI agents and new contributors working in this repository. README.md
explains what galenaDNS is and how it fits together; docs/PRIVACY.md is the
source of truth for what is and is not retained. This file covers the decisions
that look like oversights and are not.

## The one rule

Most of this repository exists to support a single claim: **nothing about a query
is retained on these nodes**, and `make audit` proves it on the running server
rather than asking anyone to trust the config.

The likeliest way an agent damages this project is not a bug. It is helpfully
adding logging, enabling statistics, or widening a bind address while debugging
something unrelated. If a change would record a query name, a client address, or
the two together, it is out of scope here no matter how useful it would be —
raise it instead of doing it.

## Invariants, and why they look wrong

Each of these is deliberate. Several look like disabled features or missing
configuration.

| Looks like | Actually |
|---|---|
| unbound bound to `127.0.0.1` / `::1` only | "Port 53 is closed" is then true by construction, not by firewall rule |
| `log-queries: no`, `log-replies: no`, `verbosity: 0`, `use-syslog: no`, `statistics-interval: 0`, `extended-statistics: no` | The retention claim, enforced in config and asserted by the audit |
| `dynblock_ring_entries = 0` by default | A ring buffer would pair a client address with a query name. The inline per-IP limiter needs no ring, so the ring stays off |
| Tunnelling rules answer REFUSED, not Drop | A Drop on DoT closes the client's connection; a false positive should cost one lookup |
| Credentials are not Terraform variables | A sensitive tfvar is still written to tfstate in plaintext, and `user_data` stays readable from the provider API for the life of the server |
| `forward-first: no` | Without it, an unreachable upstream silently falls back to **cleartext** recursion. `bootstrap.sh` asserts this line and refuses to finish without it |
| DNSSEC validated locally even when forwarding | The upstream is trusted to relay, never to tell the truth |

Per-rule hit counts come from `showRules()`, which keeps a number per named rule
and nothing about any query. That is the supported way to watch for false
positives — in particular whether the query-name length limit is catching
legitimate traffic — without logging names.

## Verifying a change

- `make check` — static checks, including shellcheck.
- `make test` — exercises the deployed configuration.
- `make audit` — runs the privacy audit on **every** node. It asserts against the
  running server, including an empirical test that a probe query name reaches
  neither disk nor journal. It is read-only.

The audit is the acceptance test for anything touching logging, binds, rules or
the resolver posture. A change that cannot pass it is not ready, and weakening a
check to make it pass defeats the point of having it.

The external prober under `monitor/` stores nothing by design — it alerts on
change and publishes a heartbeat. `--dry-run` exits 1 when any check FAILs; that
is information, not an error, so callers accept both 0 and 1.

## Conventions

Comments here explain **why**, often at length, because the reasoning is the part
that cannot be recovered from the code. Several carry measurements or dates. Keep
that style: a change that alters behaviour should update the comment that
justified the old behaviour, and commit messages follow the same habit of
separating what was verified from what was assumed.

docs/PRIVACY.md, docs/TERMS.md and docs/ABUSE.md make promises to users. A code
change that alters what is retained, how long a shutdown notice runs, or what an
abuse report can obtain is incomplete until the matching document changes with it.

Deployment specifics — addresses, emails, profile names — are never committed.
`.gitignore` keeps `*.tfvars` and `*.tfstate` out, and `terraform.tfvars.example`
is the tracked template. This is a public repository: operational access details
belong in the operator's own notes, not here.

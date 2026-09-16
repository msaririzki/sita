# WIF Connectivity Proof Runbook

## Objective

Prove the smallest end-to-end path before building the Observatory dashboard:

```text
GitHub Actions OIDC
        -> Tailscale WIF
        -> ephemeral tag:ci-wif-basic node
        -> Tailscale network policy
        -> Tailscale SSH
        -> ServerDeploy@sita-docker
```

The proof does not deploy SITA and does not modify application data. It reads
the target hostname, remote user, and Docker version, then stores sanitized
evidence as a GitHub Actions Artifact.

## Verified Laboratory State

| Item              | Observed value                   |
| ----------------- | -------------------------------- |
| Target host       | `sita-docker`                    |
| Tailscale DNS     | `sita-docker.nyala-betta.ts.net` |
| Tailscale IP      | `100.103.192.95`                 |
| Tailscale version | `1.102.3`                        |
| Docker version    | `29.8.0`                         |
| SSH service       | Active                           |
| Remote user       | `ServerDeploy`                   |
| Target tag        | `tag:sita-target`                |
| Tailscale SSH     | Enabled                          |

The target was changed from a user-owned device to the dedicated
`tag:sita-target` identity. A tagged GitHub Actions node cannot use Tailscale SSH
to a user-owned destination, so this identity is required for the SSH proof.

## One-Time Tailscale Configuration

Create two tags:

```text
tag:ci-wif-basic
tag:sita-target
```

Assign `tag:sita-target` to the Docker laboratory VM. Enable Tailscale SSH on
the target:

```bash
sudo tailscale set --ssh
```

Add narrowly scoped network and SSH rules. The exact HuJSON must be merged with
the existing tailnet policy rather than replacing unrelated rules:

```jsonc
{
    "tagOwners": {
        "tag:ci-wif-basic": ["autogroup:admin"],
        "tag:sita-target": ["autogroup:admin"],
    },
    "grants": [
        {
            "src": ["tag:ci-wif-basic"],
            "dst": ["tag:sita-target"],
            "ip": ["tcp:22"],
        },
    ],
    "ssh": [
        {
            "action": "accept",
            "src": ["tag:ci-wif-basic"],
            "dst": ["tag:sita-target"],
            "users": ["ServerDeploy"],
        },
    ],
}
```

The laboratory tailnet still contains a pre-existing `*` to `*` network grant
used by other infrastructure. Therefore, this POC proves identity federation and
Tailscale SSH authorization, but it does not claim network-level least privilege.
A separate tailnet or a planned policy migration is required before measuring
network-policy denial scenarios.

Tagged devices cannot use SSH check mode as a source. The action must be
`accept`, with the source, destination, port, and operating-system user
restricted explicitly.

## One-Time WIF Credential

Create a Tailscale federated identity with:

| Setting  | Value                                                                       |
| -------- | --------------------------------------------------------------------------- |
| Provider | GitHub Actions                                                              |
| Issuer   | `https://token.actions.githubusercontent.com`                               |
| Subject  | `repo:msaririzki@108948357/sita@1363462850:ref:refs/heads/codex/wif-poc`       |
| Scope    | `auth_keys` write only                                                      |
| Tag      | `tag:ci-wif-basic`                                                          |

The basic profile should accept the POC branch. The final multi-claim profile
will later restrict repository ID, owner ID, branch, and workflow.

The GitHub issuer returned the ID-bound subject above. The initial human-readable
pattern `repo:msaririzki/sita:*` was rejected with HTTP 403, which confirms that
the trust credential compares the received subject and does not infer repository
identity from its display name.

## GitHub Repository Variables

Configure non-secret repository variables:

| Variable              | Value                            |
| --------------------- | -------------------------------- |
| `TS_WIF_CLIENT_ID`    | Federated identity client ID     |
| `TS_WIF_AUDIENCE`     | Generated Tailscale audience     |
| `SITA_TARGET_TS_HOST` | `sita-docker.nyala-betta.ts.net` |
| `SITA_TARGET_USER`    | `ServerDeploy`                   |

The WIF Client ID and audience are configuration values, not confidential
secrets. The workflow must not contain an OAuth Client Secret or an SSH private
key.

## Pass Criteria

The proof passes only when:

1. GitHub issues an OIDC token to the job.
2. Tailscale accepts the federated identity.
3. The ephemeral runner joins with `tag:ci-wif-basic`.
4. The runner reaches the target through Tailscale.
5. Tailscale SSH runs as `ServerDeploy` without an SSH private key.
6. The target returns its hostname and Docker version.
7. The workflow uploads complete evidence and SHA-256 manifest.
8. The ephemeral runner is removed after the job.

The reachability probe accepts a direct connection or a DERP relay. GitHub-hosted
runners are ephemeral and can be behind NAT, so requiring a direct path would
misclassify a working encrypted Tailscale route as a deployment failure. The
evidence still records the selected path and latency for later analysis.

## Failure Interpretation

| Failed stage    | Primary interpretation                                         |
| --------------- | -------------------------------------------------------------- |
| Preflight       | Required GitHub variable is missing                            |
| WIF action      | Issuer, audience, subject, scope, or tag does not match        |
| Tailscale state | Runner did not join the tailnet correctly                      |
| Ping            | Network policy or target reachability failed                   |
| Tailscale SSH   | Target tag, SSH enablement, SSH policy, or user mapping failed |
| Artifact upload | Evidence pipeline failed independently of authentication       |

## Validated Proof

GitHub Actions run
[`35099221776`](https://github.com/msaririzki/sita/actions/runs/35099221776)
completed successfully on commit `0c3675710d9aaec70376770aaa13e2272b150602`.

| Observation          | Verified result                                      |
| -------------------- | ---------------------------------------------------- |
| OIDC-WIF exchange    | Passed on the first exchange attempt                  |
| Ephemeral source tag | `tag:ci-wif-basic`                                    |
| Target               | `sita-docker.nyala-betta.ts.net` / `tag:sita-target` |
| Network path         | DERP Singapore                                        |
| Ping samples         | 662 ms, 244 ms, 244 ms                                |
| Tailscale SSH        | Passed in 2589.033 ms                                 |
| Remote identity      | `ServerDeploy@sita-docker`                            |
| Docker response      | Server version `29.8.0`                               |
| Evidence integrity   | Zero SHA-256 manifest mismatches                      |
| Ephemeral cleanup    | Runner absent; machine count returned to 28           |

This proof reads only the hostname, operating-system user, and Docker server
version. It does not deploy SITA, write application data, or require an OAuth
client secret or SSH private key.

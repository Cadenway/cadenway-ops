# Security policy

## Reporting a vulnerability

**Do not open a public issue, discussion or pull request for a security problem.**

Report it privately through GitHub: on this repository, open the **Security** tab and choose **Report a
vulnerability**. If the problem lies in another Cadenway repository, report it there; if you cannot
tell, report it here and we will move it.

Please include:

- the affected component and version (or commit);
- what an attacker can do, and the conditions needed;
- steps to reproduce, or a proof of concept;
- any idea you have of a fix or a mitigation.

## What to expect

| Step                                             | Target                                    |
| ------------------------------------------------ | ----------------------------------------- |
| Acknowledgement of your report                   | 3 working days                            |
| First assessment (confirmed or not, severity)    | 10 working days                           |
| Fix or mitigation for a confirmed critical issue | as fast as possible, with regular updates |

We keep you informed of progress and credit you in the advisory unless you prefer otherwise.

## Scope

In scope: cadenway-ops and the infrastructure it describes.

Particularly sensitive in Cadenway:

- authentication, sessions, MFA, SSO and API tokens;
- isolation between organizations: one organization never sees another's data;
- access to private spaces;
- secrets, deployment and infrastructure;
- uploaded files and rendered Markdown (descriptions, comments, documents).

Out of scope: findings that need physical access to a user's device, social engineering, denial of
service by volume, and reports from automated scanners without a demonstrated impact.

## Supported versions

Only the current state of `main` is supported.

## Rules for contributors

- Never commit a secret, a token, a password or a private key. Production secrets are encrypted with
  SOPS in `cadenway-ops`.
- A credential committed by mistake is considered leaked: rotate it immediately, then remove it.
- Dependencies are kept up to date by Renovate; security updates are reviewed first.

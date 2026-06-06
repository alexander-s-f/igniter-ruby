# igniter-hub

Local capsule catalog discovery for Igniter.

Status: first POC slice, not stable API.

## Owns

- local capsule catalog loading
- bundle metadata for install candidates
- capability summaries for applications
- enough metadata for an app UI to present installable capsules

## Does Not Own

- remote download
- trust/signatures
- applying bundles
- running installed capsules

Applications should use `igniter-application` transfer verification, intake,
apply, and receipt APIs to install a selected bundle.

Companion uses this split as the first proof: `igniter-hub` lists a local
horoscope capsule, while the app installs it through the transfer pipeline.

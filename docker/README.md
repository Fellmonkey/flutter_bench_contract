# bench-contract runner image

One container with everything a contract run needs — Flutter SDK (pinned),
Android SDK with a pre-loaded system image and a precreated AVD (built once,
not per run). The consumer repo is mounted at `/workspace`; the entrypoint
(`entrypoint.sh`) boots the AVD headless and drives the contract CLI —
resolved from pub.dev through the consumer's own pubspec, so the package is
never baked into the image.

## Use

```bash
docker run --rm --device /dev/kvm \
  -v "$PWD":/workspace -w /workspace \
  ghcr.io/fellmonkey/bench-contract-runner:3.47@sha256:<digest> \
  check --ref android     # or record
```

The entrypoint runs the manifest's scenarios on the emulator in check or
record mode (`contract run` — the S7 size legs are host builds inside the
same invocation; `--legs` selects native|web|both, default native so the
web leg stays in plain CI). In record mode it then renders `card` and
`readme` when the manifest declares them (a check run stays read-only:
renders write the card PNG / README into the mounted repo). It exits with
the CLI's code: 0 ok / 1 regression or failed run / 2 usage. `/dev/kvm`
comes from the host — Windows/macOS Docker cannot pass it through, so the
emulator needs a Linux host with nested virtualization (GitHub ubuntu
runners have it).

## Build

`.github/workflows/build-runner.yml` builds and pushes the image (manual
dispatch or a `runner-v*` tag push), tagged by Flutter major.minor. Make
the GHCR package **public** — a workflow in another repo cannot pull a
private package. After a rebuild, paste the digest printed in the run
summary into the tag→digest maps in `action/action.yml` and in any workflow
that pulls the image inline — the tag is moving, the digest is not.

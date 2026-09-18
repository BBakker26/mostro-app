# Releasing

A release is cut by **pushing a tag** `vMAJOR.MINOR.PATCH`. `.github/workflows/release.yml`
does the rest: it builds and signs the Android APKs, writes the release notes, publishes the
GitHub release and opens a PR that records it in `CHANGELOG.md`.

Versions start at **2.0.0** (v1 was the pure-Flutter `MostroP2P/mobile`) and follow
[Semantic Versioning](https://semver.org/): patch for fixes, minor for features.

## Cutting a release

```bash
# 1. Only when the version changes (2.0.0 is already in the tree): bump it through a PR.
./scripts/bump-version.sh 2.0.1        # pubspec.yaml, rust/Cargo.toml, rust/Cargo.lock
#    → commit as `chore(release): v2.0.1`, open the PR, merge it.

# 2. Tag the commit on main you want to ship, and push the tag.
git checkout main && git pull
git tag -a v2.0.1 -m "Mostro v2.0.1"
git push origin v2.0.1

# 3. When the run finishes: review and merge the `chore(release): changelog for v2.0.1` PR.
```

The workflow refuses the tag — before building anything — when:

- it is not `vX.Y.Z` (no `-rc1`, no `+build`);
- the tagged commit is **not on `main`**;
- `pubspec.yaml` or `rust/Cargo.toml` does not already say `X.Y.Z`. The About screen reports
  `CARGO_PKG_VERSION`, so a tag the source disagrees with would ship an app that lies about
  its version. `test/ci/release_workflow_test.dart` keeps the two files equal;
- `MINOR` or `PATCH` is above 99 (see *Android version codes*).

## One-time setup

### Signing key (required)

Android only installs an update signed with the **same certificate** as the installed app.
The key below is therefore the identity of the app for its whole life: **lose it and no
existing user can ever update; leak it and anyone can ship an "update"**. Generate it once,
keep an offline backup, and never commit it (`android/.gitignore` excludes it).

```bash
keytool -genkeypair -v -keystore mostro-release.jks -alias mostro \
  -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 mostro-release.jks        # value of ANDROID_KEYSTORE_FILE
```

Repository secrets (Settings → Secrets and variables → Actions), same names as v1's workflow:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_FILE` | the keystore, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_PASSWORD` | key password |
| `ANDROID_KEY_ALIAS` | key alias (`mostro` above) |

With a secret missing the run fails at "Check signing secrets". There is deliberately no
fallback to the debug key, and the job re-checks the certificate of each finished APK.

To sign a build locally, create `android/key.properties` (`storeFile`, `storePassword`,
`keyPassword`, `keyAlias`); without it a release build uses the debug key, which is fine for
`flutter run --release` and must never be distributed.

### Repository settings

- **Settings → Actions → General → "Allow GitHub Actions to create and approve pull
  requests"** — for the changelog PR. Without it the release is still published and the
  `changelog` job fails with the branch name to open the PR from by hand.
- **Restrict who can release.** Anyone with write access can push a tag, and a `vX.Y.Z` tag on
  `main` is all the workflow asks for. Do both:
  - a **tag ruleset** (Settings → Rules → Rulesets) limiting creation of `v*` to admins;
  - **required reviewers on the `release` environment** (Settings → Environments). The
    `android` job — the only one that sees the signing key — runs in it, so the run then
    waits for an admin's approval before anything is signed. Moving the four secrets from
    repository to environment scope keeps them out of reach of every other workflow.

## What a release contains

| Asset | |
| --- | --- |
| `mostro-vX.Y.Z-arm64-v8a.apk` | 64-bit ARMv8-A — modern phones |
| `mostro-vX.Y.Z-armeabi-v7a.apk` | 32-bit ARMv7-A — old / entry-level phones on a 32-bit Android |
| `SHA256SUMS.txt` | checksums of the above |

`x86_64` is not shipped (an emulator ABI). Desktop (Linux, Windows, macOS) and iOS artifacts
are not built yet — they are the next phase of this workflow.

### Release notes and CHANGELOG.md

Both are printed by `tool/release_notes.dart` from the same data, so they cannot disagree:

- **One entry per merged PR**, from the first-parent history of `previous tag..tag`. `main`
  only moves by merge commit, so this lists PRs by their title and author and leaves out the
  "review round N" commits inside them. A commit pushed straight to `main` is listed by sha.
- Entries are grouped by the **conventional-commit type of the PR title** (`feat`, `fix`,
  `perf`, `refactor`, `docs`, `test`, `build`/`ci`, `chore`, `revert`; `type!:` goes under
  *Breaking Changes*; anything else under *Other Changes*). **A good PR title is the
  changelog line** — fix the title before merging, not the changelog after.
- *Contributors* are the authors of those PRs (bots excluded); *New Contributors* are those
  with no PR merged before this release.
- `chore(release): …` PRs (version bumps, the changelog PR itself) are left out.

`CHANGELOG.md` is generated: fix a wrong entry by re-running the release (below), not by hand.

### Android version codes

`versionCode = MAJOR·10000 + MINOR·100 + PATCH`, to which Flutter's `--split-per-abi` adds
`1000` (v7) or `2000` (v8): `v2.0.1` ships as 21001 and 22001. It is derived from the tag
alone, so it is ordered like the versions whatever branch or rebuild produced it — hence the
limit of 99 on `MINOR` and `PATCH`.

## When a run fails

Nothing is published until the `publish` job, so a failure before it leaves no trace: fix the
cause on `main` and **re-run the workflow** from the Actions tab (same tag, same commit). If
the fix needs a new commit, delete the tag (`git push origin :v2.0.1`), tag the new commit and
push again. Re-running after a release exists updates its notes and replaces its assets in
place, and the changelog job rewrites that version's section instead of adding a second one.

A PR opened by `GITHUB_TOKEN` does not trigger workflows: **close and reopen** the changelog
PR to start CI on it.

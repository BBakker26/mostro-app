#!/usr/bin/env bash
# Cut a release: run it twice with the same version (docs/RELEASING.md).
#
# Each run looks at where the release stands and takes the next step:
#   1. origin/main does not carry X.Y.Z yet → branch chore/release-vX.Y.Z off origin/main,
#      run bump-version.sh, commit, push and open the PR. Merge it, then run this again.
#   2. that PR is still open               → print its link and stop.
#   3. origin/main carries X.Y.Z           → tag origin/main as vX.Y.Z and push the tag,
#      which starts .github/workflows/release.yml.
#
# It never deletes a tag and never merges a PR: both stay the maintainer's call.
#
# Usage:
#   ./scripts/release.sh 2.0.1
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 MAJOR.MINOR.PATCH   (got '${version}')" >&2
  exit 64
fi
tag="v${version}"
branch="chore/release-${tag}"

die() {
  echo "$*" >&2
  exit 1
}

# 0 when $1 > $2, both MAJOR.MINOR.PATCH. Plain arithmetic: `sort -V` is not in every
# macOS sort, and maintainers release from both.
version_gt() {
  local -a a b
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    ((10#${a[i]} > 10#${b[i]})) && return 0
    ((10#${a[i]} < 10#${b[i]})) && return 1
  done
  return 1
}

if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null; then
  die "${tag} already exists on origin. If its release run failed and you mean to retag:
  git push origin :${tag} && git tag -d ${tag}
then run this again."
fi

git fetch --quiet origin main
main_cargo="$(git show origin/main:rust/Cargo.toml | sed -n 's/^version = "\(.*\)"$/\1/p' | head -n1)"
main_pubspec="$(git show origin/main:pubspec.yaml | sed -n 's/^version: \([^+]*\).*$/\1/p' | head -n1)"

# ── Step 3: main carries the version → tag it ────────────────────────────────
if [ "$main_cargo" = "$version" ] || [ "$main_pubspec" = "$version" ]; then
  [ "$main_cargo" = "$main_pubspec" ] \
    || die "origin/main disagrees with itself: rust/Cargo.toml says '${main_cargo}', pubspec.yaml '${main_pubspec}'."
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    die "A local ${tag} exists but origin has none. Drop it first: git tag -d ${tag}"
  fi
  git tag -a "$tag" -m "Mostro ${tag}" origin/main
  git push --quiet origin "$tag"
  echo "Tagged $(git rev-parse --short origin/main) as ${tag} and pushed it: the release workflow is running."
  echo "  Follow it:  gh run watch \$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
  echo "  When it finishes, review and merge the 'chore(release): changelog for ${tag}' PR"
  echo "  (close and reopen it first so CI runs on it)."
  exit 0
fi

# ── Step 2: the bump PR is open → wait for its merge ─────────────────────────
open_pr="$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty')"
if [ -n "$open_pr" ]; then
  echo "The version bump is waiting for its merge: ${open_pr}"
  echo "Merge it, then run: $0 ${version}"
  exit 0
fi

# ── Step 1: open the bump PR ─────────────────────────────────────────────────
version_gt "$version" "$main_cargo" \
  || die "${version} does not move past ${main_cargo}, the version on origin/main."
[ -z "$(git status --porcelain)" ] \
  || die "The working tree has uncommitted changes; commit or stash them first."
if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
  die "origin already has ${branch} but no open PR from it. Reopen that PR, or delete the branch:
  git push origin :${branch}"
fi
git rev-parse -q --verify "refs/heads/${branch}" >/dev/null \
  && die "A local ${branch} exists. Delete it first: git branch -D ${branch}"

start="$(git rev-parse --abbrev-ref HEAD)"
git switch --quiet -c "$branch" origin/main
./scripts/bump-version.sh "$version"
git commit --quiet -m "chore(release): ${tag}" -- pubspec.yaml rust/Cargo.toml rust/Cargo.lock
git push --quiet -u origin "$branch"
pr_url="$(gh pr create --base main --head "$branch" --title "chore(release): ${tag}" \
  --body "Sets the version to ${version} in \`pubspec.yaml\`, \`rust/Cargo.toml\` and \`rust/Cargo.lock\` (\`scripts/bump-version.sh\`). Once merged, \`./scripts/release.sh ${version}\` tags the merge and starts the release.")"
[ "$start" = "HEAD" ] || git switch --quiet "$start"

echo "Opened ${pr_url}"
echo "Merge it, then run: $0 ${version}"

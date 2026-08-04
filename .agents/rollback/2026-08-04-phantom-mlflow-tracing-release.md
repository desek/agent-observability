# Rollback log: remove the half-finished pi-mlflow-tracing 0.1.0 release

Date: 2026-08-04
Change owner: daniel@grenemark.se
Governing change: CR-0009, phase 6, the release rehearsal

## What happened

Merging the release pull request created the tag `pi-mlflow-tracing-v0.1.0`
and the GitHub release, then the publish job failed before reaching npm. A
test asserted that the newest changelog heading equals the manifest version,
and the automation writes that heading as a Markdown link, which the pattern
does not match.

The result is a release that exists in git and on GitHub but not on the
registry. npm holds only 0.0.1.

## The destructive steps

1. Delete the remote tag `pi-mlflow-tracing-v0.1.0`.
2. Delete the local tag of the same name.
3. Delete the GitHub release `pi-mlflow-tracing-v0.1.0`.
4. Reset `.release-please-manifest.json` and the package manifest to 0.0.1.

Nothing consumes any of these. The registry has no 0.1.0, so no installed
package can reference the deleted tag or release.

## Rollback procedure

The tag pointed at commit `4e6ed77ad49f35e93b48f2028176ad522e914957`. To
restore:

    git tag pi-mlflow-tracing-v0.1.0 4e6ed77ad49f35e93b48f2028176ad522e914957
    git push origin pi-mlflow-tracing-v0.1.0
    gh release create pi-mlflow-tracing-v0.1.0 --title "pi-mlflow-tracing: v0.1.0" --notes-from-tag

Then restore both version fields to 0.1.0.

## Verification after a successful rollback

- `git ls-remote --tags origin` lists `pi-mlflow-tracing-v0.1.0`.
- `gh release view pi-mlflow-tracing-v0.1.0` returns the release.
- `.release-please-manifest.json` reads 0.1.0 for that package.

## Verification after the intended forward path

- `npm view @desek/pi-mlflow-tracing versions` lists 0.0.1 and 0.1.0.
- `scripts/release.verify.sh @desek/pi-mlflow-tracing 0.1.0` exits 0,
  asserting the tag, the release, the registry version, and provenance.

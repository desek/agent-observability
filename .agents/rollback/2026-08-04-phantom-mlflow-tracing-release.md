# Rollback log: remove the half-finished pi-mlflow-tracing 0.1.0 release

Date: 2026-08-04
Change owner: daniel@grenemark.se
Governing change: the release rehearsal, phase 6 of the release management
change request (named in the commit message, not here, because a tracked file
outside docs must carry no governance identifier)

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

## Second occurrence, same day

The redo produced the same half-finished state, for a different reason. The
unit tests passed, and the run then failed on the guard that compares the
released version against the package manifest.

Cause: the release job declared only `releases_created` and `paths_released`
as job outputs. A job outputs map is static, so the per-path output the action
emits for each released package, `packages/pi-mlflow-tracing--version`, was
never forwarded. The guard therefore compared an empty string against 0.1.0
and failed. The action does emit that output; it was read from the action
source rather than inferred from a run log, which does not echo every output.

Recovery was identical: tag and release deleted, both version fields reset to
0.0.1. The tag pointed at commit e507bb4e6a0e04367421381c7798e2ce5b9ff17e, and
the rollback procedure above applies unchanged with that SHA.

The fix forwards the whole output object as JSON, so the publish job can index
it by matrix path without any package being named in the workflow.

## Lesson

Two releases were lost to guards that could only fail after a real release. The
release job is not exercised by any pull request, because the release branch is
created by the default token and starts no workflow run. Every guard inside it
is therefore first executed in production. Anything added to that job needs a
way to be tested before a release depends on it.

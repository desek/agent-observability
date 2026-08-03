<!-- Purpose: the maintainer runbook for releasing a package from this repository.
     It states the whole loop as numbered steps from the Conventional Commit
     subject to the confirmed published artifact, names what each wait waits for
     and where it is seen, and states the one-time human act a first publish of a
     new package needs. The release automation is release-please in manifest mode;
     this document is how a person drives it.
     @agents-index: Release runbook: the numbered loop from the Conventional Commit subject through the release pull request to the published artifact, every wait point named, plus the one-time registry setup a new package's first publish needs. -->

# Release runbook

[Back to the front page](../README.md)

This repository releases its packages with release-please in manifest mode. You
do not type a version number and you do not write a changelog entry. You write a
Conventional Commit subject, merge two pull requests, and wait at two named
points. The automation computes the version, writes the changelog, cuts the
component tag, creates the release, and publishes the package in the same
workflow run.

Read [Contributing](contributing.md) first for what a contributor does; this
runbook is the maintainer's view of the same loop, with the wait points named.

## What controls a release

Every squash-merge subject on the default branch is a Conventional Commit, and
that subject is the whole input to the automation. A `feat:` subject proposes a
minor release, a `fix:` subject a patch, and a subject with a breaking-change
marker a major. A subject that is not a Conventional Commit proposes nothing, so
the release that never appears is the visible symptom of a subject the automation
could not read.

Tags carry the package component, in the form `<component>-v<version>`, where the
component is the package name with its scope removed, so `@desek/pi-opentelemetry`
at `0.1.1` is tagged `pi-opentelemetry-v0.1.1`. The bare `v<version>` form is
retired: it could not say which package it released.

## The loop, step by step

1. **Write the Conventional Commit subject.** When you open the pull request that
   changes a package, give it a Conventional Commit title. The squash merge
   writes that title onto the default branch as the commit subject, and that
   subject is what the automation reads to compute the version and write the
   changelog. Nothing else you do controls the release.

2. **Squash-merge the pull request.** Merge with squash, so exactly the
   Conventional Commit subject lands on the default branch. The checkpoint commits
   inside the branch are removed by the squash and never reach the automation.

3. **Wait for the automation to open the release pull request.**
   *Wait for:* release-please to run on the push to the default branch and open,
   or update, a release pull request for the package your commit touched. Each
   package gets its own release pull request; a commit that touched only one
   package does not open one for the other.
   *Where you see it:* the `release` workflow run under the repository's Actions
   tab, and then the release pull request itself in the Pull requests tab,
   labelled by release-please and titled with the package and its proposed
   version. If no release pull request appears, the merged subject was not a
   Conventional Commit the automation could read; fix it with a follow-up
   Conventional Commit rather than by editing any version file.

4. **Review the release pull request.** Read the proposed version and the
   generated changelog entry. Both are derived from the commits since the last
   release of that package, so this is where you confirm the history says what
   you expect before it becomes a release. Do not edit the version or the
   changelog by hand; if they are wrong, the commit subjects were wrong, and the
   fix is a new Conventional Commit.

5. **Merge the release pull request.** Merging it is the release decision.
   Nothing publishes until this merge.

6. **Wait for the tag and the release.**
   *Wait for:* the same `release` workflow to run again on the merge, and its
   release-please job to create the component tag `<component>-v<version>` and the
   GitHub release for it.
   *Where you see it:* the `release` workflow run under the Actions tab, the tag
   under the repository's Tags, and the release under Releases. The tag and the
   release are created together in that run.

7. **Wait for the publish, in that same run.**
   *Wait for:* the `publish` job of the same `release` workflow run to publish the
   released package to the npm registry over trusted publishing. Publication is
   part of this run on purpose: a tag or a release the automation creates starts
   no other workflow run, so there is no separate publish workflow to wait on. The
   publish job runs only for the paths the automation reports as released, so it
   publishes exactly what this release contained and nothing else.
   *Where you see it:* the `publish` job in the same `release` workflow run under
   the Actions tab. A skipped `publish` job means the run released nothing.

8. **Confirm the published artifact.** Verify the release from the outside: the
   tag exists, the release exists, the version is on the registry, and the
   artifact carries provenance. The verification script asserts all four and
   exits non-zero if any is missing, so a half-completed release is caught rather
   than assumed done.

   ```console
   $ scripts/release.verify.sh @desek/pi-opentelemetry 0.1.1
   ```

## The one-time human act a new package's first publish needs

The steps above assume the package already exists on the registry with a
trusted-publishing relationship. A package publishing for the very first time
does not, and that setup is an interactive act a person performs once on the
registry; it cannot be automated from here.

Before the first release of a package that has never been published:

1. Create the package on the npm registry under its scope, so the name exists and
   you own it.
2. Configure its trusted-publishing relationship to name this repository and the
   workflow file that publishes, which is `.github/workflows/release.yml`. This is
   the file publication now runs from; the retired `publish.yml` is gone, so a
   relationship still naming it would reject the publish.

Trusted publishing requires the package and this relationship to exist before a
workflow can publish, so a first release without this step fails at the publish
job with an identity error rather than a missing-version error. Do it once, then
the ordinary loop above publishes every version, including that first one.

## When a step does not happen

* **No release pull request appeared after step 2.** The merged subject was not a
  Conventional Commit the automation could read. Land a follow-up Conventional
  Commit; do not edit a version file to force it.
* **The publish job was skipped after step 5.** The run released nothing, which
  means no release pull request was actually merged in that push. Confirm you
  merged the release pull request, not the feature pull request again.
* **The publish job failed with an identity or trust error.** The
  trusted-publishing relationship is missing or names the wrong workflow file. See
  the one-time human act above and confirm the relationship names
  `.github/workflows/release.yml`.
* **`scripts/release.verify.sh` reports no provenance.** The version reached the
  registry by a path other than trusted publishing. Provenance cannot be added
  retroactively; publish a new patch through the release workflow.

## Next

* [Contributing](contributing.md), what a change carries and what `make ci` checks.
* [How it fits together](architecture.md), what a change has to keep true.

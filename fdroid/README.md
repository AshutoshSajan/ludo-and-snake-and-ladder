# F-Droid metadata

`com.gameclub.game_club.yml` is this app's working copy of the recipe that
belongs in the [fdroiddata](https://gitlab.com/fdroid/fdroiddata) repository.
It is kept here so the build rules, the store listing and the source they
describe move together.

## Submitting

1. Fork `fdroid/fdroiddata`.
2. Copy `com.gameclub.game_club.yml` to `metadata/com.gameclub.game_club.yml`
   in the fork.
3. Open a merge request titled `New App: Game Club`.
4. Keep the `commit:` field on the exact app commit being submitted. When the
   app changes, update the commit, `versionName`, `versionCode` fields and
   `CurrentVersion*` together.

The fastlane listing F-Droid reads from that commit is in
`fastlane/metadata/android/en-US/`.

## Why the build commands look like this

Flutter adds an ABI offset to `versionCode` when `--split-per-abi` is used
(1000 for armeabi-v7a, 2000 for arm64-v8a, 4000 for x86_64). F-Droid's
`versionCode` must be the code actually inside the APK, so each build passes
`--build-number $$VERCODE$$` and
`--android-project-arg=force-version-code-ignoring-abi=true`. That keeps the
three APKs at 11, 12 and 13 instead of 1011, 2012 and 4013.

`VercodeOperation` maps the upstream pubspec build suffix (`+1`) to those three
codes: `%c * 10 + 1`, `+ 2`, `+ 3`. The next upstream build (`+2`) therefore
becomes 21/22/23, and F-Droid sees a newer code for every release.

Every build pins `ndk: 28.2.13676358` — the NDK that Flutter 3.47.2 selects by
default — so the buildserver does not have to guess which one to install.

The recipe was checked with `fdroid lint` against fdroiddata's current
`config/categories.yml` and `config/antiFeatures.yml`.

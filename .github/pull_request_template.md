## Summary

<!-- What changes and why. Link the issue or milestone if there is one. -->

## Verification

<!-- Paste the commands you ran and their results. Say what was NOT verified. -->

- [ ] `ci-gate` passes (public, ROM-free)
- [ ] Local full gate `bash re_workspace/tools/verify_all.sh` — result: <!-- ALL GATES PASS / not run (why) -->
- [ ] New tests cover the change; ROM-only tests are listed in `scripts/ci/expected_skips.txt`

## Publication safety

- [ ] No ROM, IPL image, extracted asset, game text, test corpus, build product or local path is added
- [ ] Third-party code or data has its license recorded in `macos_studio/ThirdParty/`

# VideoSubscriberAccount exception compatibility

## Failure and reveal

On iOS 26.6.2 (23G90), an affected third-party app terminates with SIGABRT.
Its exception stack places `+[NSException raise:format:]` above
`-[VSSubscriptionRegistrationCenter registerSubscription:] + 420`, called by
`setCurrentSubscription: + 320`.

Resolve the registration method with `class_getInstanceMethod` and inspect its
IMP after stripping pointer authentication. It calls
`_shouldRaiseExceptionsForMisuse`, then `_shouldAllowAccessToSubscription:`.
Denied access selects either an exception or a log-and-return path according
to that policy. The throwing call at method +0x1a0 returns to +0x1a4 (420),
matching the crash stack. Direct registration of a real, newly allocated
`VSSubscription` in an isolated process raises NSInvalidArgumentException:
“Registering this subscription (…) requires an entitlement.”

The policy method calls `linkedOnOrAfterChecker`, then `shouldPerformBehavior:0`.
Its entry is `pacibsp; stp x20,x19,[sp,#-32]!`. This identifies the SDK-linked
misuse policy; the exact missing entitlement and why the app fails that check
have not been established.

## Patch contract

`dyld-cfw-video_subscriber_account` returns NO from
`-[VSSubscriptionRegistrationCenter _shouldRaiseExceptionsForMisuse]`, using
`ARM64Encoder` and `ARM64.ret`. It selects the framework's existing legacy
log-and-reject policy, including other misuse validation sites. It grants no
entitlement and does not make `_shouldAllowAccessToSubscription:` succeed.
The setter's rejected-access path also becomes non-throwing. A returned call
therefore does not prove that a subscription was registered.

The patch resolves the method within VideoSubscriberAccount using the cache's
local symbols, refuses unknown prologues and accepts its existing replacement.
Writes use the cache chunk writer, page re-attestation and read-back verification.
The installer captures the original bytes in its undo log and reverts a disabled
patch through its existing cache reversal path. Standard and experimental
presets already select the guest-system set. Applicability is limited to iOS
26.5 and 26.6, the inspected families; inspect other binaries before widening it.

## Validation

An isolated real-framework experiment replaced only that process's policy IMP
with a NO-returning function, then restored it. Registration threw before,
logged without throwing afterward, and threw again after restoration.

The installed-cache test on the research guest resolved the method at 0x2415d058c and
changed `7f2303d5f44fbea9` to `00008052c0035fd6`. Re-attestation updated slot
6819 in `dyld_shared_cache_arm64e.50`: one page, zero skipped. A second dry run
read the replacement back. The stopped disk clone replaced the original only
after successful patching, read-back, unmount and eject. Only this identifier
was added to the Guest receipt, which reports applied=true and pending=false.

After reboot, a fresh script session without runtime hooks reported
`raiseMisuse=false` and registration returned without exception. The affected
app survived two cold launches, remained foreground and produced no new crash
reports. Its crash count stayed at six beyond the previous approximately
three-second failure window. This verifies startup survivability; TV-provider
login, successful registration and playback remain untested. A real-cache undo
round-trip also remains untested.

The three new tests cover the observed method entry and frozen replacement,
idempotence, unknown-code refusal, and version/selection blocking. Existing
Version requirements, Patch selection, Patch declarations, Plan resolution,
Patch gate and Bundled patch set catalogue suites supplement them. The original
implementation passed focused tests, VPhoneCommand build, finished VPhone bundle
build and bundle admission. Live qualification used that implementation on
ce55dc8441fd7b01bb0a8dd9ebeb7dc16022e5cb; rebasing it onto newer main is a separate
host build/test validation, not a repeat of the guest qualification.

On the branch based on wdahlenburg/main at
39324ee7fcbb1d909bfa293f6188a8ef752ba734, all 59 focused tests in those seven
suites passed and VPhoneCommand built successfully. The finished bundle and
live guest were not requalified against this newer base.

## Additional firmware validation

The same semantic method resolves in three inspected firmware builds. Its first
instructions are identical in all three: `pacibsp; stp x20,x19,[sp,#-32]!`.
Selection admits iOS 26.5 and 26.6, including patch releases, and rejects other
minor releases. Both the declaration and legacy no-plan installer use that gate.
No device name is part of the matcher, selection or tests.

| iOS | Build | Policy address | Evidence |
| --- | --- | --- | --- |
| 26.5 | 23F77 | 0x240c6b58c | Stock cache patch, repeat and undo |
| 26.6.1 | 23G83 | 0x2415d058c | Stock cache patch, repeat and undo |
| 26.6.2 | 23G90 | 0x2415d058c | Installed cache and live startup checks above |

For 26.5 and 26.6.1, read-only SystemOS images came from cached restore IPSWs.
The command patched writable cache copies with undo capture, re-attested one
page with zero skipped pages, accepted a repeat without changing the page hash,
and reverted through `patch-dsc-revert`. SHA-256 comparisons of every cache file
before patching and after reversal matched. These are host-side binary and
rollback checks; neither additional release was boot-qualified. The addresses
above are research observations, never patch-site constants.

## TV-provider sign-in and playback

The public registration API reports a user's subscription information to the
Apple TV app; see Apple's [VSSubscriptionRegistrationCenter documentation](https://developer.apple.com/documentation/videosubscriberaccount/vssubscriptionregistrationcenter).
Changing exception policy does not authenticate a provider account or establish
playback rights. Valid provider sign-in and playback need separate qualification
with the target app/provider and an authorized subscription. Inspect the actual
account-manager or service errors before deciding whether another guest-side
compatibility patch is needed. No provider sign-in or playback flow has been
qualified by this patch.

After widening the gate, all 59 focused tests passed again and VPhoneCommand
built successfully. The version-selection test admits the inspected releases,
rejects neighboring uninspected minor releases and verifies explicit blocking.

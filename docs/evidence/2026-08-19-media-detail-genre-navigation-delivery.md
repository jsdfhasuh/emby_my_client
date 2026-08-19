# Media Detail Genre Navigation Delivery Evidence

## Scope

- Branch: `agent/media-detail-genre-navigation`
- Baseline main: `69128cf3c8100a51741c187d28cbb622e008ccb0`
- Remediation start: `0863479f4d529a91d3773075df9b7a572fe7d660`
- Plan commit: `91c96dbecb15bed546ef67eaa6be0282f2cb144e`

## Remediation Evidence

### Async navigation race

- `ItemDetailScreen` binds each genre request to its source route and a generation token.
- Pushes to the player, person detail, offline player, route coverage, dispose, and a second genre request invalidate the old token.
- `HomeShell` revalidates the original route and request after root resolution, genre resolution, before push, and before showing an error.
- `test/library_genre_navigation_integration_test.dart` covers a pending request followed by the real `PlayerScreen`; it asserts no facet route and no stale `SnackBar`.

### Genre pagination

- `LibraryGenreResolver.maxGenrePages` is `128`.
- `LibraryGenreResolver.maxGenreTerms` is `10000`.
- Pages are fingerprinted using raw count, normalized IDs, and normalized names.
- Duplicate pages and full pages with no new IDs fail closed as `paginationStalled`.
- The first reported total is retained when later pages omit the total.
- Resolver tests cover duplicate full pages, reordered duplicate pages, known totals, and the hard page limit.

### Cache invalidation

- Both resolvers expose `clear()` and use a cache generation to prevent old in-flight requests from repopulating cleared state.
- Root cache entries retain the observed direct `ParentId`; a changed `ParentId` forces a fresh ancestor resolution.
- `HomeShell` listens to `EmbyLibraryChanged` through the existing realtime binding and clears both resolvers.
- The integration fixture rotates from `library-1`/`genre-1` to `library-2`/`genre-2` after a realtime event and asserts the next navigation uses the new `ParentId` and `GenreIds`.

### Playback return

- The integration suite includes real `PlayerScreen` route tests for detail playback and facet play-all playback.
- Both tests assert the facet route remains in the stack, requests remain `[0, 60]`, the genre query remains attached, the second-page item remains, and scroll position is preserved.
- Windows skips these real-player widget tests because the environment lacks `libmpv-2.dll`; the pending-player race test still uses the real route on supported hosts.

## Verification

The final values below reflect the local gates completed on 2026-08-19.

```text
STATUS=FINAL_REMEDIATION_COMPLETE
REMEDIATION_STATUS=ACCEPTED
IMPLEMENTATION_HEAD_BEFORE_FINAL_EVIDENCE=1a20d14fa948539281e7a9330d21639ae325abc0
FORMAT=PASS
ANALYZE=PASS
TESTS=963 passed / 0 failed / 3 skipped on Windows
ANDROID_DEBUG_APKS=PASS
IOS_DEBUG=NOT_RUN (Windows host)
MAIN_UNCHANGED=true
WORKTREE=CLEAN after evidence commit
PUSHED=true after verification
```

## Commits

- `182dcb6` `fix: cancel stale genre navigation requests`
- `901e37e` `fix: bound and validate genre index pagination`
- `239daa4` `fix: invalidate genre navigation caches safely`
- `1a20d14` `test: preserve facet state across real playback`
- Evidence document commit follows these implementation commits.

## Known Limits

- The Windows host does not provide `libmpv-2.dll`, so the three real-player widget tests are skipped here.
- iOS Debug was not run because this host is Windows.

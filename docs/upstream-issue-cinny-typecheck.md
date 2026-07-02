# cinnyapp/cinny への typecheck 崩壊報告 (手動投稿専用ドラフト)

> **⚠️ このドラフトは人間が手動で投稿するためのものです。**
> Claude やその他の自動化による投稿は禁止 (プロジェクト設定 `.claude/settings.json` の deny ルールでも `gh issue create` 等をブロック済み)。
>
> **投稿手順 (手動):**
> 1. 投稿前に再現が現状でも有効か確認: `cd cinny && git log --oneline -1` で dev の HEAD を控え、`npm run typecheck` でエラーが出ることを確認 (upstream が既に typescript を上げていたら本文の該当箇所を更新)
> 2. https://github.com/cinnyapp/cinny/issues/new を開く
> 3. 下の「Title」をタイトル欄に、「Body」以下をそのまま本文にコピー&ペースト
> 4. 本文中のコミット SHA (`5e00d51`) が投稿時点の dev HEAD と違う場合は差し替える

---

## Title

```
`npm run typecheck` fails with 792 errors on dev — matrix-js-sdk type declarations require TypeScript >= 5.x
```

## Body

### Description

`npm run typecheck` (`tsc --noEmit`) fails with **792 errors** on the current `dev` branch (5e00d51). The vast majority follow this pattern:

```
src/app/components/AccountDataEditor.tsx(17,10): error TS2614: Module '"matrix-js-sdk"' has no exported member 'MatrixError'. Did you mean to use 'import MatrixError from "matrix-js-sdk"' instead?
```

Error code breakdown: TS2614 ×454 (missing named exports from `matrix-js-sdk`), plus TS7006/TS2786/TS2347/TS2305 and others that are mostly cascading effects of the same problem.

This appears to have gone unnoticed because none of the GitHub Actions workflows run `npm run typecheck` (or `npm run lint`) — CI only runs `npm run build` (Vite/esbuild, which does no type checking) and CodeQL.

### Steps to reproduce

```sh
git clone https://github.com/cinnyapp/cinny -b dev
cd cinny
npm ci
npm run typecheck
```

Reproduced on Windows 11 / Node v24.18.0 / npm 11.16.0, but the cause is platform-independent.

### Root cause

matrix-js-sdk's published type declarations use `.ts`-extension relative imports. `node_modules/matrix-js-sdk/lib/index.d.ts` (v41.7.0) is literally:

```ts
import * as matrixcs from "./matrix.ts";
export * from "./matrix.ts";
export default matrixcs;
```

(The SDK is built with `moduleResolution: "bundler"` + `allowImportingTsExtensions: true`; this pattern is present in its dist output since around v34.5.0.)

cinny pins `typescript@4.9.4` and uses `moduleResolution: "Node"` (classic). TS 4.9's resolver treats `./matrix.ts` as an opaque specifier and appends extensions to it, as `--traceResolution` shows:

```
======== Resolving module './matrix.ts' from '.../node_modules/matrix-js-sdk/lib/index.d.ts'. ========
File '.../lib/matrix.ts.ts' does not exist.
File '.../lib/matrix.ts.d.ts' does not exist.
...
======== Module name './matrix.ts' was not resolved. ========
```

It never tries the actual `lib/matrix.d.ts`, so `export * from "./matrix.ts"` re-exports nothing and the entire type surface of `matrix-js-sdk` becomes invisible — hence TS2614 everywhere. TypeScript 5.x resolves `.ts` specifiers in declaration files to their `.d.ts` counterparts, which fixes this.

### Suggested fix (verified locally)

1. **Bump `typescript` from `4.9.4` to `5.9.3`** (devDependencies). No `tsconfig.json` changes needed. This alone reduces 792 errors to 12.
   - Note: TypeScript **6.x does not work** with the current tsconfig — `moduleResolution: "Node"` is a hard deprecation error (TS5107) there, and even with `--ignoreDeprecations 6.0` the lib resolution changes introduce ~111 new errors. Moving to `moduleResolution: "bundler"` + TS 6 could be a separate, later migration; 5.9.x is the minimal-churn step.
2. **Fix the 12 remaining errors** (all TS2345). These are pre-existing, genuine type mismatches that were hidden by the broken resolution — cinny-specific event types passed to SDK methods typed against `StateEvents`/`AccountDataEvents`:
   - 7 of them can be fixed with a single module augmentation file (the SDK's intended extension mechanism for custom event types):

     ```ts
     // src/types/matrix/sdk-augmentation.d.ts
     import { PackContent, EmoteRoomsContent } from '../../app/plugins/custom-emoji/types';
     import { InCinnySpacesContent } from '../../app/hooks/useSidebarItems';
     import { IRecentEmojiContent } from '../../app/plugins/recent-emoji';

     declare module 'matrix-js-sdk' {
       interface StateEvents {
         'im.ponies.room_emotes': PackContent;
       }

       interface AccountDataEvents {
         'im.ponies.user_emotes': PackContent;
         'im.ponies.emote_rooms': EmoteRoomsContent;
         'in.cinny.spaces': InCinnySpacesContent;
         'io.element.recent_emoji': IRecentEmojiContent;
       }
     }
     ```

     This would also allow removing some existing `as any` casts (e.g. `RoomPacks.tsx`, `Lobby.tsx`).
   - The remaining 5 call sites handle dynamic event-type strings (developer tools, `useAccountData`) or a loose `IContent` (`MessageEditor.tsx`) and need small local casts, following the same patterns already used in `CallWidgetDriver.ts` and `RoomInput.tsx`.

With these changes: `npm run typecheck` exits 0, `npm run check:eslint` output is unchanged, and `npm run build` succeeds.

3. Optionally, **add `npm run typecheck` to CI** (e.g. `build-pull-request.yml`) so this can't regress silently again.

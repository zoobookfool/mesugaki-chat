# Cinny typecheck 修復記録 (2026-07-02)

Phase 2b のクライアント作業環境 (DiscordSub ワークスペースの cinny クローン) で `npm run typecheck` が 792 エラーで全面的に壊れていた問題の調査結果と修正。upstream (cinnyapp/cinny dev ブランチ) 自体が同じ状態であり、fork 作業のベースラインとして必ず適用する。

## 症状

- `npm run typecheck` (`tsc --noEmit`) が 792 エラー。うち 454 件が `error TS2614: Module '"matrix-js-sdk"' has no exported member 'MatrixClient'` のようなパターン
- `npm run build` (vite) は通るため実行時には気づけない

## 根本原因

- matrix-js-sdk ≥34.5.0 の配布型定義は `.ts` 拡張子付き相対 import を含む (`lib/index.d.ts` が `export * from "./matrix.ts"`)
- cinny が pin する `typescript@4.9.4` + `moduleResolution: "Node"` ではこの指定子を解決できず、SDK の named export が全て不可視になる
- upstream の GitHub Actions は typecheck/lint を一切実行していない (vite build + CodeQL のみ) ため、2024 年 9 月の matrix-js-sdk 34.5.0 バンプ以降ずっと未検知

## 修正内容

1. `typescript` を **4.9.4 → 5.9.3** (exact pin)。tsconfig.json は無変更。これだけで 792 → 12 エラー
2. 残り 12 件 (壊れていた間に紛れ込んでいた本来的な型不整合) をコード側で解消:
   - 新規 `src/types/matrix/sdk-augmentation.d.ts` — cinny 独自イベント型 (`im.ponies.*`, `in.cinny.spaces`, `io.element.recent_emoji`) を SDK の `StateEvents`/`AccountDataEvents` へ module augmentation (7 件解消)
   - `useAccountData.ts`・settings / common-settings の `DevelopTools.tsx`・`MessageEditor.tsx` に局所キャスト (既存の `CallWidgetDriver.ts` / `RoomInput.tsx` のパターン踏襲、5 件解消)

## 適用手順 (cinny クローンへ)

```sh
cd cinny   # cinnyapp/cinny の dev ブランチ (5e00d51 時点で検証)
git apply <mesugaki-chat>/docs/patches/cinny-typecheck-fix.patch
npm install          # package-lock.json を typescript 5.9.3 に同期
npm run typecheck    # → エラー 0 件
```

## 検証結果 (2026-07-02, Node v24.18.0 / npm 11.16.0 / Windows 11)

- `npm run typecheck`: exit 0、エラー 0 件
- `npm run check:eslint`: 修正前後で結果が完全一致 (既存の `src/index.css` パースエラー 1 件 + 既存警告 3 件のみ)
- `npm run build`: 成功

## 注意事項

- **TypeScript 6 系には上げない。** `moduleResolution: "Node"` が TS5107 (廃止) エラーで即停止し、`--ignoreDeprecations 6.0` で回避しても lib 解決の変更で 111 エラーに悪化する (実測)。6 系へ行くなら `moduleResolution: "bundler"` 化とセットで別途検証すること
- upstream の dev を merge した際はこの修正 (特に typescript のバージョンと sdk-augmentation.d.ts) を保持すること。upstream が独自に typescript を上げた場合はそちらへ寄せる
- Windows では `npm run check:eslint` (`eslint src/*`) が glob 展開の差で一部ファイルしか検査しないことがある。変更ファイルは `npx eslint <file>` で個別確認が確実
- upstream への報告ドラフトは [upstream-issue-cinny-typecheck.md](upstream-issue-cinny-typecheck.md)。**投稿は必ず人間が手動で行う** (Claude 等の自動化からの投稿は行わない方針)

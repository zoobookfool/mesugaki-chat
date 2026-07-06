# Phase 2a Client Spike 記録 (2026-07-02)

検証環境: element-call dev backend (WSL, docker compose) + cinny upstream dev サーバー。
テストユーザー: alice/bob/carol@synapse.m.localhost, dave@synapse.othersite.m.localhost。

## 項目1: 複数人同時画面共有 — 合格

- **結果**: 3ユーザー同時共有OK。タイルの注視(拡大)切り替えも即時。
- **気づき**: 注視していない共有をミニタイルで常時表示し続けるモードがない。fork 要件候補
  (Discord の分割ビューに近いイメージ)。実装前にイメージのすり合わせが必要。

## 項目2: メディアパラメータの上書き到達性(最重要) — 差し込み点特定済み、実測待ち

- **構造**: Cinny は livekit-client を直接持たず、`@element-hq/element-call-embedded`
  (Element Call のビルド済み dist、npm devDependency) を `public/element-call/` に静的コピーし、
  iframe widget として起動する (`cinny/src/app/plugins/call/CallEmbed.ts:115` で URL 構築、
  `vite.config.js:17` で static copy)。widget URL・メディア設定とも cinny の config.json では変更不可。
  EC 側の config.json (dist同梱) にもメディア系キーは無い → **改変には EC の fork ビルドが必須**。
- **差し込み点 (element-call 側)**:
  - `src/livekit/options.ts` — `screenShareEncoding`(既定 h1080fps30 ≈3Mbps/30fps)、
    `audioPreset`(既定 music)、カメラ `videoEncoding`(h720)、simulcast レイヤー。**ここが本丸**。
  - `src/state/CallViewModel/localMember/LocalMember.ts:708` — 画面共有キャプチャ側の
    `ScreenShareCaptureOptions`(解像度・キャプチャfps制約を足すならここ)。
- **実施した変更** (EC v0.20.1、ローカル clone の element-call):
  - `screenShareEncoding: { maxBitrate: 800_000, maxFramerate: 5 }`(既定 3Mbps/30fps から変更)
  - `audioPreset: { maxBitrate: 128_000 }`(既定 music から変更)
- **組み込み手順** (fork 時の再現手順):
  1. `git clone element-call && git checkout v0.20.1`
  2. `src/livekit/options.ts` を変更
  3. `pnpm install && pnpm exec vite build --config vite-embedded.config.js`
  4. `cp -r dist embedded/web/dist`
  5. cinny 側: `npm install --save-dev "file:../element-call/embedded/web"`
  6. dev サーバー再起動 → 配信 JS に `maxBitrate:8e5,maxFramerate:5` を確認済み
- **実測**: chrome://webrtc-internals ダンプ解析(2026-07-02 16:44)で確認 → **合格**
  - 音声: 全4ユーザーの outbound targetBitrate = 128,000(パッチ値。既定 48k から変化)
  - 画面共有: framesPerSecond = 5〜6(パッチの maxFramerate:5。既定 30 から変化)、
    送信レイヤー 960x540 / targetBitrate 200k(1080p キャプチャの 1/4 simulcast 層。
    800k 上限の層別配分として整合。フル層は dynacast により未送信 = LiveKit の想定動作)
  - 目視でも共有映像が明確に 5fps 相当のカクつきになることを確認
- **気づき**: 差分は1ファイルで済む。ただし fork 対象が cinny と element-call の2リポジトリになり、
  upstream 追従コストは2倍になる。EC の embedded パッケージはバージョン固定 (0.20.1) なので
  cinny 側のバージョンアップに EC fork の追従を合わせる運用が必要。

## 項目3: federated アカウントの通話参加 — 概ね想定どおり(限定付き)

- **結果**: dave(othersite)は alice の通話ルームに参加可、画面共有は双方向成立。
  dave からの通話開始は不可を確認 — requirements.md §5 の当時の想定(参加のみ許容)と整合。
  (【追記 2026-07-06】この観測はのちの検証で訂正 — SFU 選択は「早い者勝ち」で、federated ユーザーも最初の参加者になれる。当時の「不可」は UI 導線の観測に過ぎなかった。現行の正は requirements.md §5)
- **限定**: 本検証環境は othersite 側にも SFU があり well-known で foci を広告しているため、
  「SFU を持たない federated ユーザー」の厳密な再現にはなっていない。厳密にやるなら
  foci 無しの第3ホームサーバーが必要。
- **未確認**: 双方向音声(単一PC・複数プロファイルではマイク/エコーの制約で判定しづらい)。

## 項目4: ボイスチャンネル運用の UX — 合格

- **結果**: 入退室・再入室・ミュート・共有切り替えは素直。画面下部のステータス表示は良い。
- **気づき**:
  - UI は英語のみ。Cinny upstream には翻訳基盤自体が無く、日本語化は fork 作業になる
    (fork-strategy.md の文言調整と同じ箇所)。Element Web は日本語対応済み — 比較時の材料。
  - 検証中の通話切断はローカル環境(WSL のアイドル停止)起因であり Cinny の品質とは無関係。

## 判定

項目1・2・4 合格、項目3 概ね想定どおり(SFU無しユーザーの厳密再現のみ未実施)。
→ **4項目クリア。Cinny fork 続行 (Phase 2b) の条件成立。**

考慮点: fork は cinny + element-call の2リポジトリ体制になり upstream 追従コストが増える。
日本語化は翻訳基盤の整備から必要(Element Web 比較時の判断材料でもある)。

検証後の後片付け: パッチ版 EC は upstream 0.20.1 に戻した(再適用は
`npm install --save-dev "file:../element-call/embedded/web"` + dev 再起動のみ)。
ローカル CA (Element Call Dev CA) は検証環境撤収時に certmgr.msc から削除すること。

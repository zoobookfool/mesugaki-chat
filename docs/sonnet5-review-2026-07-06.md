# Sonnet 5 のレビュー (2026-07-06)

**このドキュメントは AI (Claude Sonnet 5) による自動レビューの記録です。** 人間によるレビューの代替ではなく、指摘の中には誤読・優先度の見誤りが含まれる可能性があります。`bug` 判定の 5 件は別の Sonnet 5 エージェントによるアドバーサリアル検証 (反証を試みる) を経て「反証されなかった」ものですが、それでも鵜呑みにせず着手前に自分の目で確認してください。

## 対象と方法

- **対象**: cinny fork (`selfmatrix-cinny`, `product/discord-style-shell`)、element-call fork (`selfmatrix-element-call`, `product/discord-style-shell`)、スターター (`selfmatrix`)
- **方法**: 5 系統の並列レビュー (i18n 完全性スイープ / cinny のテーマ・通知・登録導線 / EC の独自機能と本セッションで確定した設計意図の突き合わせ / EC のメディア・トランスポート層 / スターター追加分の再レビュー+運用衛生) → 収集した 38 件のうち `bug`/`security` 判定 5 件を独立エージェントがアドバーサリアル検証 (5 件とも反証されず「確定」扱い) → 本ドキュメントに統合
- **severity の意味**: `bug` (動作が壊れる/仕様矛盾で実害あり、検証済み) / `security` (セキュリティ上の懸念、該当ゼロ件) / `design-mismatch` (本セッションで確定した設計意図とズレている実装) / `ux` (動作は正しいが体験が悪い) / `minor` (軽微、または「問題なし」の確認結果)

| severity | 件数 |
|---|---|
| bug (検証済み) | 5 |
| security | 0 |
| design-mismatch | 6 |
| ux | 15 |
| minor | 12 |

セキュリティ懸念は 0 件でした (widget の state event 受信範囲を含め、確認した箇所はいずれも upstream 標準の許可範囲内)。

---

## 最重要の発見: SFU 早い者勝ち問題は fork 改造なしで緩和できる

以前 (2026-07-06 早い時間帯) 「通話開始した人のホームサーバーの SFU が使われる早い者勝ち」問題への対処として、「常に自社 SFU を強制する fork 改造」を検討しましたが、「GitHub に上げれない変更はやめとこう、運用で Bot 常駐させる」という判断をしました。

**今回のレビューで、fork 改造なしで対処できる upstream 標準機能が見つかりました。**

- `element-call/src/settings/settings.ts` の `matrixRTCMode` は既定で `Legacy` (`oldest_membership` = 最初に参加した人の SFU に全員が収束する、今困っている挙動そのもの) になっている
- `matrixRTCMode` を `Compatibility` または `Matrix_2_0` (`multi_sfu`) に変えると、**各クライアントが自分自身のホームサーバーの SFU に接続する**設計に切り替わり、federated ユーザーが先に参加してもうちのアカウントは自社の LiveKit に繋がり続ける
- これは fork のコード変更ではなく、設定を変えるだけ (現状は `DeveloperSettingsTab` 配下の隠し設定)
- ただしトレードオフあり: `multi_sfu` は複数 SFU 間でメディアをリレーする設計のため帯域/レイテンシコストが増える。相手クライアントも `multi_sfu` 対応が必要な可能性がある (matrix.org 側が対応しているかは未検証)

**推奨**: Bot 常駐案を実装する前に、まず `matrixRTCMode: Compatibility` を試して federation テストで帯域・遅延・相互接続性を確認する価値があります (詳細は本文 finding #23)。

---

## bug (検証済み、優先度: 高)

### 1. element-call: 致命的通話エラーの説明文が ja.json に丸ごと欠落

`element-call/src/utils/errors.ts` で発生する接続断・E2EE非対応・容量超過・ルーム作成制限などの**通話利用中に実際に遭遇する最重要エラー**が `error.*` 名前空間ごと ja.json から欠落しており、日本語 UI でも英語表示になります。`GroupCallErrorBoundary.tsx`・`RichError.tsx` の関連キーも同様。

**対応**: `ja/app.json` に `error.*` を一括追加。優先度は高 (通話が使えない/切れた時に最初に読む文言)。

### 2. element-call: 通話中 UI (video_tile/handset/lobby/group_call_loader) の文言が大量欠落

ビデオタイルのステータス文言 (`video_tile.calling`/`call_ended`/`waiting_for_media` 等)、モバイル受話器モード (`handset.*`)、参加待機画面 (`lobby.*`)、Ban/通話終了/参加拒否画面 (`group_call_loader.*`) が ja.json から欠落。通話の開始から終了まで通しで遭遇する UI で影響大。

**対応**: 件数が多いため機械翻訳→レビューの2段階が現実的。

### 3. element-call: 設定モーダル (デバイス選択/音声/背景ぼかし) の文言が欠落

マイク/カメラ/スピーカー切替 (`settings.devices.*`)、音量エフェクト、背景ぼかし関連の文言が ja.json に無い。通話中に頻用する操作。

### 4. cinny: 通知の highlight 差分判定が誤爆する (design-mismatch 由来の実害あり)

`ClientNonUIFeatures.tsx` の通知ゲート (本セッションで実装した「通常メッセージはバッジのみ、メンション/DMのみ通知」機能) に 2 つの誤爆パターンが実際に成立します:

- **誤って鳴る**: アプリ起動時に未読メンション (`highlight>0`) があるルームに通常メッセージが来ると、キャッシュ未登録のため誤ってメンション扱いされる
- **鳴るべきなのに鳴らない**: 他デバイスで既読にした後 (highlight リセット)、本コンポーネントのキャッシュはそれを検知しないため、古い highlight 値と比較して本物のメンションが抑制される

**原因**: `unreadCacheRef` がマウント時に空で初期化され、`roomToUnreadAtom`/`RoomEvent.Receipt` と同期していない。

**対応**: `unreadCacheRef` を `roomToUnreadAtom` の値でプレフィルし、`RoomEvent.Receipt` (または `roomToUnreadAtom` の変化) も監視する。

### 5. cinny: shellLayout のサイドバー/ナビ位置を連続変更すると片方が消える

`General.tsx` の `handleSidebarPositionChange`/`handleNavPositionChange` が `mx.setAccountData()` の Promise を await せず fire-and-forget で呼んでいる。matrix-js-sdk の `setAccountData` はサーバー PUT 後、`/sync` エコー到達まで解決しない設計のため、短時間 (1 回目のエコー到達前) に 2 つの設定を連続変更すると、2 回目の書き込みが 1 回目の変更を含まない古いベースから作られ、上書き消失する。

**再現条件**: 設定画面でサイドバー位置とナビ位置を素早く切り替える、という自然な操作で発生しうる。

**対応**: `makeShellLayoutContent` のベースを `mx.getAccountData()` ではなく直前の `shellLayoutAtom` の現在値から取るか、書き込みを直列化する。

---

## design-mismatch (本セッションで確定した意図とのズレ)

### ①ポップアウトは視聴専用のまま — 操作 UI が無い

`usePopoutScreenShare.ts` は黒背景+`<video>`のみを別ウィンドウに開く設計で、チャット送信・ミュート等の操作が一切できない。

**現実的な選択肢**: (A) ポップアウトウィンドウ自体に最小限のコントロールを足す (別ドキュメントに素の DOM で組む必要があり複雑) / (B) メインウィンドウとの合わせ技 — ポップアウト中はメインウィンドウ側をチャット/操作パネル中心のレイアウトに切り替える (`popoutActive` フラグを購読してレイアウト分岐、実装労力が低い)。**(B) を推奨。**

### ②ミニタイルにユーザー名が表示される — 「配信専用」の意図とズレ

`CallViewModel.ts` の `showNameTags$` が spotlight-landscape/portrait (まさにミニタイル strip が出る場面) でも常に `true` を返しており、スポットライト本体とミニタイル strip の両方に同じ値が配られている。

**対応**: `showGridNameTags$` を新設してミニタイル (strip 側) だけ名前表示を抑制する。スポットライト本体 (喋っている本人) は名前表示を維持。

### ③画面共有が1つでもあれば自動でスポットライトに切り替わる — グリッド優先の意図と逆

`LayoutSwitch.ts` の `naturalGridMode$` が「リモート画面共有が1つでもあれば常に spotlight」というロジックで、ユーザーが grid を選んでも `skipWhile` により自動的に spotlight に引き戻される。

**対応**: `naturalGridMode$` から画面共有起因の自動昇格を外し (`windowMode === "flat"` 判定のみ残す)、代わりに「画面共有が始まった」ことを知らせるボタン/トーストを出してユーザーが明示的に spotlight へ切り替える形にする。

### ④複数強調 (spotlightExpanded/split view) はユーザー操作起点 — **これは意図通り、問題なし**

ピン留め・`spotlightExpanded`・split view はいずれも自動発火せず、ボタン操作でのみ真になることを確認。真の問題は③ (grid⇔spotlight のモード切替そのもの) にある。

### ⑤SFU 早い者勝ち問題 — 冒頭参照 (fork 改造なしで緩和可能)

### ⑥システムテーマ ON 後、ライトモードでは selfmatrix ブランドが失われる

初回起動ユーザーの `initialSettings` は `themeId`/`darkThemeId` を `selfmatrix-dark-theme` にしているが `lightThemeId` は未設定のまま。システムテーマに合わせる設定で OS がライトモードの場合、標準の `LightTheme` にフォールバックし selfmatrix ブランドが失われる。

**対応**: `initialSettings` に `lightThemeId` も明示的に設定する (専用ライトテーマがあれば理想)。

---

## ux (体験の粗、動作は正しい)

### i18n 完全性スイープで新たに見つかった未翻訳箇所 (cinny)

このセッション中に見つけた `DeviceVerificationSetup.tsx`・`image-pack-view/` 以外にも、以下がまとまって未翻訳 (`useTranslation` 未 import の生の英語ハードコード):

- **デバイス検証/鍵バックアップ関連一式**: `DeviceVerification.tsx`・`ManualVerification.tsx`・`SecretStorage.tsx`・`BackupRestore.tsx` — 新規デバイスログイン時・E2EE 鍵復旧時に必ず通る導線
- **メッセージ本文レンダリング全体**: `FallbackContent.tsx`・`FileContent.tsx`・`ImageContent.tsx`・`VideoContent.tsx`・`MsgTypeRenderers.tsx`・`Reply.tsx` — 「メッセージが削除されました」「復号できません」等、表示頻度が最も高い部類
- **UIA (認証) フロー一式**: `EmailStage.tsx`・`PasswordStage.tsx`・`ReCaptchaStage.tsx`・`SSOStage.tsx`・`RegistrationTokenStage.tsx`・`UIAFlowOverlay.tsx` — アカウント削除・パスワード変更・クロス署名リセット等で発生
- **添付ファイル/PDF/画像ビューア**: `PdfViewer.tsx`・`ImageViewer.tsx`・`UploadBoard.tsx`・`UploadCardRenderer.tsx`・`TextViewer.tsx`・`AccountDataEditor.tsx`
- 軽微: オートコンプリート見出し (`Emojis`/`Rooms`/`Mentions`)、ルーム/スペース退出ダイアログのボタン・エラー文言、ルーム参加カードのエラーダイアログ、日時ピッカーの列見出し

**特に登録トークンのエラーダイアログ (`RegistrationTokenStage.tsx:92-101`) は severity 高め**: サーバーの生 errcode をそのままタイトル表示し、無効/期限切れ/使用済みを区別できないまま英語で出る。招待コード制の自己登録という Phase 7 の目玉機能の失敗時体験が悪い。

### i18n 完全性スイープで新たに見つかった未翻訳箇所 (element-call)

`t()` は使っているが ja キーが欠落しているパターン: リアクション/挙手ボタン (`action.raise_hand` 等)、アバター編集ボタン、ログイン/ゲスト参加/reCAPTCHA 周辺の SSLA キャプション、開発者向け設定タブ (優先度低)。

### 公開ルーム作成時、暗号化スイッチが「消える」だけで理由が分からない

`CreateRoom.tsx` は `access === Public` のとき暗号化トグルの `SettingTile` ブロックごとレンダリングしない。ユーザーは「公開ルームは暗号化できない」ことを能動的に知る手段がない。

**対応**: Public でもトグルを disabled 表示のまま残し、説明文に「公開ルームは暗号化できません」を追記する。

### カメラ機能の露出範囲: フッターは隠れているが設定モーダルのビデオタブは残存

`hideVideoButton` はフッターのボタンには効いているが、設定モーダルの「ビデオ」タブ (カメラ選択・背景ぼかし) には連動していない。優先度は低 (severity: minor)。

### ALLOW_CUSTOM_HOMESERVERS 環境で federated アカウントを deactivate できない (運用ドキュメント未反映)

`operations.md` の無効化手順は自ホームサーバー限定の admin API のみを解説しており、外部ホームサーバーのユーザーには効かない。締め出しはルーム ban/kick かルーム block のみが手段になる。

**対応**: `operations.md` にこの制約を一言注記する。

### 画面共有/カメラの画質・FPS を選べる UI が無い (ユーザー報告の裏付け)

`options.ts`/`LocalMember.ts` を確認したところ、720p カメラ・4K60/384kbps 画面共有ともに設定 UI が一切存在しないことをコードレベルで確認。simulcast/adaptiveStream は有効なので即座に破綻はしないが、低スペック環境での初期輻輳・CPU 負荷は懸念材料。

---

## minor / 確認結果 (「問題なし」の記録も含む)

- E2EE のフレーム暗号化は専用 Web Worker + 非同期 WebCrypto で実装されており、メインスレッドをブロックする懸念は無い (確認結果、対応不要)
- マイクの `echoCancellation`/`noiseSuppression` は既定で有効になっており設計上の欠陥は無い (確認結果)。将来 Krisp 相当を追加する場合の配線ポイントは `ConnectionFactory.ts` の `audioCaptureDefaults` 付近
- `scripts/invite-token.sh`/`scripts/generate-synapse-admin-config.sh` は前回レビュー以降変更なし、新規懸念なし
- CI の `env-example-check` の必須キー配列は `.env.example`/`rtc/.env.example` と過不足なく一致 (漏れなし)
- docs 間の矛盾は無いが、`ALLOW_CUSTOM_HOMESERVERS` が `roadmap.md` の Phase 7 記録に反映されていない (軽微、あると経緯が追いやすい)
- ja.json に未使用の孤立キー `video_tile.change_fit_contain` が残存 (実害なし)
- widget の state event 受信範囲 (`RoomMember`/`RoomName`/`RoomCreate` 等) は upstream 標準の許可範囲内で、フィルタも機能している (セキュリティ上の懸念なし)
- **運用衛生**: このセッション中に本番へ作った検証用アーティファクト (`Federation Test`/`Federation Voice Test`/「うううう」/「デフォルトテスト」ルーム、検証用招待トークン、`zoo` ユーザー) が残存している。片付け手順は `docs/operations.md` の該当節を参照 (ルーム purge / トークン失効 / アカウント deactivate)。今後も使う予定がなければ整理を推奨

---

## 優先度についての所感 (Sonnet 5 の意見、判断は運用者に委ねる)

1. **bug 5 件**は実装が明確に間違っているので優先度は高いが、緊急度は「通知の誤爆/データ消失」(#4,#5) > 「i18n 欠落」(#1,#2,#3、実害はないが体験を損なう)
2. **SFU 早い者勝ち問題への `matrixRTCMode` 対応**は、以前「fork 改造は避けたい」という判断をした経緯を覆せる新情報なので、Bot 常駐運用より先に検証する価値がある
3. **design-mismatch の①②③**はまとめて着手すると効率が良い (いずれも通話 UI の同じ層に触るため)
4. i18n の残り (デバイス検証/メッセージ本文/UIA/添付ファイル) は分量が多いので、優先度は「実際に踏む頻度が高い順」(メッセージ本文 > デバイス検証 > UIA > 添付ファイル) が妥当

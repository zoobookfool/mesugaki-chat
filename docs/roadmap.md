# Roadmap

2026-07 改訂。通話・配信(requirements.md §3)を計画の中心に据え、クライアント選定に判断ゲートを設けた版です。

## Phase 0: Name, domain, and infrastructure decisions

- サービス名を決める
- `SERVER_NAME` を決める(実質恒久ID)
- `matrix.*` / `chat.*` に加えて RTC 用ホスト(例: `rtc.*`、Cloudflare DNS-only)を決める
- VPS を選定する(国内リージョン推奨。回線帯域は当面不問)
- Cloudflare / VPS / Tailscale の経路方針を確定する
- デプロイ形態を決める(自宅 + VPS / VPS 単独。architecture.md の Deployment topologies 参照)

**進捗 (2026-07-03):**

- サービス名: **SelfMatrix** に決定 (リポジトリ名も selfmatrix / selfmatrix-cinny / selfmatrix-element-call に統一済み)
- デプロイ形態: 運用者自身の環境は **A: 自宅 + VPS** に決定 (ポート開放不可の回線のため)。
  スターターとしては「自宅オンリー / VPS 単独 / 自宅 + VPS」をサポート対象とする (Phase 4 の profile 整備に反映)
- VPS: **さくらのVPS** を採用予定 (適合確認と各社の帯域比較は docs/bandwidth-comparison.md 参照)
- 経路方針: 経路 A (Cloudflare → VPS → Tailscale → 自宅) で確定。ドメインは Cloudflare DNS 管理下の手持ちドメインを充当
- `SERVER_NAME`: 手持ちドメインのサブドメイン(ラベル `selfmatrix`)に決定 (2026-07-03)。
  サブドメイン方式の注意は home-server-network.md の「サブドメインを SERVER_NAME にする場合」参照

**Phase 0 完了 (2026-07-03)。** 決定事項はすべて確定(具体的なドメイン名は運用者の `.env` で扱い、本リポジトリには記載しない)。

Exit criteria:

- `@user:domain` の形式に納得している
- デプロイ形態(自宅 + VPS / VPS 単独)が決まっている
- 「UDP は Cloudflare を通らない」を前提にした DNS 設計ができている

## Phase 1: Vanilla text deploy

**進捗 (2026-07-05): 完了。** 経路A (Cloudflare → VPS edge → Tailscale → 自宅) で稼働。
実環境では VPS に既存の edge nginx があったため、edge は Caddy ではなく既存 nginx の
vhost 追加で構成した (自宅側も既存サービスと同居のため、compose override で caddy を
無効化して synapse/cinny を tailnet に直接公開する形)。クライアントは fork イメージ
(ghcr.io/zoobookfool/selfmatrix-cinny) を使用。E2EE 双方向会話と federation tester を
確認済み。**外部ユーザー招待の実地確認も完了 (2026-07-06)**: matrix.org のアカウント 2 つが
招待を受けて実ルームに join していることを admin API で確認 — exit criteria 3 点すべて達成。

- Synapse + PostgreSQL を自宅で起動
- Cloudflare → VPS(edge Caddy)→ Tailscale → 自宅 Caddy の HTTP 経路を通す
- well-known と HTTPS を提供
- Cinny 公式イメージを自分の homeserver 固定で公開
- admin user を作成し、テストユーザー2名で暗号化ルームを作る
- Federation tester で到達性を確認
- `max_upload_size` を Cloudflare の上限内に設定(または media パスの迂回を決める)

Exit criteria:

- `chat.example.com` からログインできる
- `@alice:example.com` として E2EE ルームで会話できる
- 外部 Matrix ユーザーを招待できる

## Phase 2a: Client spike(判断ゲート、目安1週間)

第一候補 Cinny fork の採用可否を、改修着手前に検証します。検証環境と詳細手順は docs/client-spike.md を参照してください。

- Cinny の Voice/Video Room で複数人同時画面共有が表示できるか
- 埋め込み Element Call 層でエンコードパラメータ(解像度プリセット、Opus ビットレート)を上書きできるか
- federated アカウント(他 homeserver のテストユーザー)が通話に参加できるか
- ビデオルームの UX が「ボイスチャンネル」運用に足りるか(DM 通話非対応は許容済み)

Exit criteria:

- 4項目の検証結果が記録され、Cinny 続行 / Element Web fork 切替のどちらかが確定している
- 切替の場合、fork-strategy.md を対象クライアントで書き直す

**結果 (2026-07-02): 完了・合格。** 4項目クリアで **Cinny fork 続行が確定**。
記録は docs/client-spike-results.md 参照。

## Phase 2b: Client fork

UI の合意事項は docs/ui-design-notes.md (v1.2) を正とします。
リスク扱いだったポップアウトは技術検証済み (docs/popout-spike.md):
配信ストリーム単位のポップアウト (再接続なし) を主機能として EC fork のタイル UI に実装します。

**進捗 (2026-07-03): fork リポジトリ作成済み**(selfmatrix-cinny / selfmatrix-element-call、
ブランチ構成は docs/fork-strategy.md 参照)。typecheck 修正とスパイク成果はコミット済み。

- fork repository を作り、upstream 追従用ブランチを作る
- AGPL notice と source link を UI に残す
- homeserver 固定、featured communities 非表示、文言差し替え
- Space/Room の見え方を「サーバー/チャンネル」寄りに調整
- 初回ログイン後に key backup と device verification を促す
- fork のビルドは fork 側 CI で GHCR にイメージ publish し、本リポジトリは `CINNY_IMAGE`(タグ変数)を差し替えるだけにする

Exit criteria:

- upstream rebase が現実的な差分量に収まっている
- ユーザーが Matrix 用語を知らなくても使い始められる

## Phase 3: MatrixRTC backend(通話MVP)

**進捗 (2026-07-05): 通話 MVP 完了、負荷試験のみ保留。**
LiveKit + lk-jwt をスターター同梱の `rtc/` compose で VPS に配置し、well-known の
`rtc_foci`・Synapse の MatrixRTC 設定(MSC3266/4222/4354 + delayed events)・
ファイアウォール開放(7881/tcp + UDP レンジ)まで完了。E2EE 有効ルームでの 2 者通話を
本番経路で検証済み(per-participant E2EE、メディアは node_ip 直の UDP を SFU ログで確認)。
クライアント fork はルーム作成時の E2EE トグルを既定 ON に変更済み。
残: ①負荷試験(単一マシンからの連続ログインが homeserver のレート制限に当たるため、
テスト時の rc 緩和 + 参加者分散の再設計が必要)②RTC ホストの DNS-only 化(現在は暫定で
CDN proxy 経由。シグナリングは HTTP 系なので動作し、メディアは IP 直のため影響なし)
③VPS 増強(現行 1GB RAM は通話常用には非力、2GB 以上を推奨 → Phase 4 で判断)。

- VPS に LiveKit SFU と lk-jwt-service を配置(compose 化)
- MatrixRTC backend をスターターに同梱し、友人の自前運用でも同一手順で SFU を建てられるようにする
- LiveKit の `auto_create: false`、webhook 連携、公開 IP 告知(node_ip)を設定
- `.well-known/matrix/client` に `org.matrix.msc4143.rtc_foci` を追記(CORS/MIME 確認)
- ルーターと VPS のファイアウォールに 7881/tcp と UDP レンジを開放(RTC ホストのみ)
- 通話 E2EE を既定で有効化
- 開始権限の既定を確認(自ホームサーバー = full-access、federated = 参加のみ。requirements.md §5)
- 10 人・画面共有 3 本(既定画質)の負荷試験を行い、帯域の実測値を記録

Exit criteria:

- 自アカウント + federated アカウント混在で 10 人通話が安定する
- 画面共有 3 本同時で映像が破綻しない
- 負荷試験の帯域実測が試算と大きく乖離していない

## Phase 4: Operations hardening & distribution readiness

**進捗 (2026-07-05): 完了 (v0.1.0 タグ)。** バックアップ体制 (pg_dump + 署名鍵 + メディア、
`restore.sh --drill` によるリストア訓練を本番で実証、systemd timer で毎日自動)、
homeserver.yaml の生成自動化 (手動編集ゼロ)、CI (shellcheck + compose 検証 + env 完全性)、
運用 runbook (docs/operations.md、荒らし対応・権限・admin API 遮断・外部バックアップ)、
イメージタグ固定 + Renovate 設定、VPS 再構築スクリプト (provision-rtc-vps.sh、dry-run 付き)、
3 デプロイ形態の切替 (compose profile ではなく override 雛形方式で実現)、
`/_synapse/admin` の遮断 (同梱 Caddyfile + 実環境の edge の両方)。exit criteria 3 点達成。
残: Renovate GitHub App のインストール (リポジトリオーナーの 1 クリック作業)。
負荷試験由来の VPS 増強判断 (RAM 2GB 推奨) は運用データを見て実施。

友人が同じスターターを建てる前に、配布に耐える状態へ引き上げます。

- セットアップの編集ゼロ化(homeserver.yaml の自動パッチスクリプト)
- イメージタグ固定 + Renovate による更新 PR 運用
- CI: shellcheck、`docker compose config -q`、`caddy validate`
- PostgreSQL dump の自動化、media / signing key のバックアップ、restore drill
- VPS 再構築スクリプト(ステートレス前提の担保)
- 自宅 + VPS / VPS 単独 / 自宅直公開の 3 トポロジを compose profile で切り替え可能にする
  (Discord のセルフホスト代替という目的上、自宅オンリー運用も一級サポートにする — 2026-07-03 決定)
- VPS 単独形態向けの外部バックアップ手順(ログ保全の条件)
- `/_synapse/admin` の遮断、`x_forwarded: true` 等のリバースプロキシ整合
- rate limit / abuse 対応、admin/moderator 手順、uptime monitoring
- release タグ運用(`release/*`)を開始し、友人デプロイのバージョンずれに備える

Exit criteria:

- DB 消失シナリオから復元できる
- 第三者(友人)が README だけで一式を建てられる
- 荒らし対応の権限と手順が明文化されている

## Phase 5: Media quality tuning

**進捗 (2026-07-05): 完了 (スケール検証のみ保留)。** fork 側 (selfmatrix-element-call) で
①画面共有 4K60 プリセット (25Mbps エンコード + キャプチャ解像度 3840×2160@60 指定)、
②Opus 384kbps ステレオ (forceStereo、DTX 無効)、③simulcast ポリシー (ピン留め = 注視タイルは
HIGH レイヤー、非注視は 720p15/1.5Mbps の低レイヤーへ降格。購読側 setVideoQuality 連動) を実装。
dev 環境で SDP / webrtc-internals による実測 (audio maxBitrate 384k + stereo=1、simulcast 2 層、
キャプチャ 4K60) と unit test を確認し、cinny 同梱ビルドとして本番反映済み。本番経路の
E2EE 通話スモーク (2 者・perParticipantE2EE・60 秒安定) も PASS。
残: 4K60 × 3 本 + 10 人での品質検証 — 負荷試験 (Phase 3) と同じくレート制限緩和と参加者分散の
再設計が必要なため保留。実運用で怪しくなったら Grafana ダッシュボードと併せて実測する。

- 画面共有の 4K 60fps プリセット追加(fork 側)
- Opus 384kbps ステレオ対応(fork 側)
- simulcast ポリシー調整(注視タイル高画質、他は降格)
- 4K60 × 3 本 + 10 人での品質検証

Exit criteria:

- 4K 60fps 画面共有 3 本が 10 人通話内で実用になる
- 送信 384kbps 設定が全参加者(改修版クライアント統一)で有効になっている

## Phase 6: Hi-res audio subsystem

**進捗 (2026-07-05): スパイク完了 — JackTrip (hub mode) の採用 (「買う」) を推奨。** 記録は
docs/hires-spike.md。机上調査で SonoBus は star 型中継が構造的に不可 (音声は常に P2P) かつ保守停滞、
Jamulus は 48kHz 固定のため除外。実機検証で VPS 上のヘッドレス hub による 192kHz/24bit ステレオ
中継が成立 (クライアント 1 台 ≈9.8Mbps/方向、2 台同時で線形スケールを実測。レイテンシは要件に対し
桁で余裕)。残条件: JackTrip は非圧縮 PCM 固定のため可逆圧縮 SHOULD は未達 — 10 人ステレオ
≈195Mbps は現行 100Mbps 回線で不足し、人数制限で開始してフル規模時に回線増強か圧縮レイヤー
自作を再判断。本実装 (Opus フォールバック・ミュート制御・fork 起動導線) と運用者の聴感確認は未着手。

**方針変更 (2026-07-05): ハイレゾは本体から分離した「拡張オプション」として実装する** (運用者判断)。
クライアント fork への起動導線・自動ミュート制御は実装しない (fork の upstream 追従リスクをゼロに保つ)。
提供形態はオプションモジュール: JackTrip hub の provision スクリプト (認証付き・人数上限
つき・systemd オンデマンド起動) + 参加者向け利用ガイド (クライアント導入手順・ヘッドセット必須・
二重再生防止の運用ルール)。下記スコープのうち「フォールバックとミュート制御」「fork への起動導線」は
運用ルールとガイドで代替し、requirements.md §4/§7/§9 も同日再スコープ済み。

**実装完了 + 別リポジトリ化 (2026-07-05)**: モジュール一式は独立リポジトリ
**selfmatrix-hires** に分離 (provision.sh + README ガイド + shellcheck CI。スターター側で
実装・2 系統レビュー・CI 通過済みのものを移植)。本リポジトリには方針記録とスパイク記録
(docs/hires-spike.md) のみ残す。残: 本番 VPS への配備と聴感・実接続の検証 (運用者が実施。
exit criteria の充足判定はその結果を待つ)。

- スパイク: SonoBus / JackTrip(hub)を 192kHz/24bit・10 人・片道 150ms 以内で検証し、買う/作るを判断
- 自作の場合: ネイティブ送受信アプリ + VPS 中継、可逆圧縮を既定
- Opus 系統とのフォールバックとミュート制御(二重再生防止)
- ヘッドセット必須の運用ルールをオンボーディングに明記
- クライアント fork にハイレゾアプリの起動導線を追加

Exit criteria:

- ハイレゾ対応者同士の通話が 192kHz/24bit・片道 150ms 以内で成立する
- 非対応者が混在しても会話が破綻しない(フォールバック動作)

## Phase 7: Product polish

**スコープ確定 (2026-07-05、4 方向 recon + 運用者承認)。** exit criteria への効き方で優先順位を決定:
①**Discord 風独自テーマ** (fork 側、新テーマ追加 + 既定化) ②**notification tuning** (新規ルーム既定の
Discord 寄せ。既定挙動の実機確認から) ③**moderation = synapse-admin 導入** (Web ダッシュボード、
自宅サーバー側に配置。bot 型の Draupnir は荒らしが実際に問題になるまで保留 — 従来方針どおり)
④**SSO/OIDC は保留** (IdP 常駐は「手作業なしで回る」に逆行、MAS 移行は不可逆で時期尚早) — 代替として
`registration_requires_token` による招待コード制を検証・導入 ⑤**custom emoji/sticker は実装不要**
(cinny が MSC2545 実装済み、MSC2545 自体 2026-07 に正式 spec 化) — パック運用ガイドのみ
⑥**bridge/bot は保留** (mautrix 系は API 追従の定期メンテが前提で「手作業なしで回る」に逆行。
必要時に override で追加できる形だけ担保)。
併走する積み残し: 外部ユーザー招待の実地確認 (Phase 1 残)、Renovate App インストール (Phase 4 残)。
VPS 2GB 判断は Phase 7 では不要 (追加サービスは自宅側配置のため)。

**進捗 (2026-07-05): ①② 完了・本番反映済み** (cinny fork c0cec72)。①SelfMatrix Dark テーマ =
Discord 風 3 階調 + blurple を darkThemeData 派生で追加し、初回起動ユーザーのみ既定化
(既存ユーザーの選択には影響しない initialSettings 分離方式。全上書きトークンで WCAG 4.5:1 以上を確認)。
②通知 = 分析の結果 Matrix 既定 push rules はほぼ Discord 的 (全メッセージ = バッジ、メンション =
音+強調、DM = 音) で push rule 変更は不要と確定。唯一の差分「通常メッセージでもトースト+音が出る」を
クライアント側でゲート (トースト/音はメンションと DM に限定)。dev 実機で通常 = トースト 0 /
メンション = 1 を Playwright 検証済み。

**進捗 (2026-07-05): ③④ も完了・本番反映済み。** ③moderation dashboard = synapse-admin 0.11.4 を
`profiles: ["admin"]` で同梱 (既定停止・127.0.0.1 バインド既定・restrictBaseUrl 生成スクリプト付き)。
経路 A では edge が `/_synapse/admin` を遮断するため restrictBaseUrl を内部経路の URL に向ける
必要がある (operations.md §2.5 に記録)。④招待コード登録 = `ENABLE_INVITE_REGISTRATION` opt-in
(enable_registration + registration_requires_token) + `scripts/invite-token.sh` (create/list/delete)。
本番で有効化し、register の UIA flows に `m.login.registration_token` を確認、トークンの
発行→一覧→削除の一連を実証。cinny は registration token stage 対応済みで、`?token=` 付き URL に
よる招待リンクも可能。付随して .env の CRLF 混入バグを修正 (生成スクリプト 3 本)。
残: ⑤custom emoji/sticker の運用ガイド化 (実装は不要と確定済み)。⑥bridge/bot は保留のまま。

**Phase 7 完了 (2026-07-05)。** ⑤ = docs/emoji-stickers.md (方針: upstream の MSC2545 実装をそのまま
採用。サーバー共通絵文字は「絵文字倉庫」チャンネルのルームパック + 各自お気に入り登録という運用の型。
パック編集画面が未 i18n である事実も記録し fork の i18n 残課題に追加)。⑥bridge/bot は意図的な保留の
ままスコープ外へ (mautrix 系の定期メンテ負荷が exit criteria 2 に逆行するため。必要になった時に
override 方式で追加)。exit criteria 評価: 「招待した人が説明なしで日常利用できる」= 招待リンク
(トークン付き URL) で自己登録 → Discord 風テーマ・用語・通知既定 → 絵文字/通話まで一通り成立。
「運用者が毎日手作業で面倒を見なくても回る」= 自動バックアップ (systemd timer) + 監視 (Grafana) +
モデレーション GUI (synapse-admin) + アカウント発行の自己登録化で、日常の手作業は解消。
実運用で残るのは招待トークン発行と月次程度の update 追従のみ。

**追記 (2026-07-06、e5fd695)**: `ALLOW_CUSTOM_HOMESERVERS` を追加 (`.env` opt-in、既定 false)。
true にすると cinny のログイン/登録画面に「カスタムホームサーバー」選択肢が増え、matrix.org 等
既存アカウントを持つ相手がこのサーバーにアカウントを作らずログインできる。ただし federation の
制約は変わらない (通話 SFU の早い者勝ち・deactivate が自サーバーアカウントにしか効かない等。
詳細は docs/operations.md §2.1 の注意書きと docs/requirements.md §5 を参照)。

- 独自テーマ、custom emoji/sticker 方針
- notification tuning
- SSO/OIDC、moderation dashboard、bridge/bot integrations

Exit criteria:

- 招待した人が説明なしで日常利用できる
- 運用者が毎日手作業で面倒を見なくても回る

## Phase 8: Dogfooding と Discord パリティ(随時)

Phase 0〜7 完走後の運用フェーズ。実利用で見つかった改善点と「Discord にある機能は基本対応する」
方針 (requirements.md §9、2026-07-06 決定) のバックログをここで管理する。

- **ノイズ抑制 (Krisp 相当) のスパイク** — 方式選定 (LiveKit Krisp SDK / RNNoise WASM 等)。
  requirements.md §3 に SHOULD として追加済み。配線ポイントは EC の ConnectionFactory
  (audioCaptureDefaults) 付近と調査済み
- **SFU 切断時の自動再参加** — 2026-07-06 の実測 (検証 V4) で、SFU 再起動時に通話が自動復帰しない
  ことを確認 (LiveKit ルームはインメモリで消え、クライアントは数秒で再接続を断念して
  「Reconnecting...」のまま)。当面は運用ルール (operations.md §2.6) で回避し、恒久対応は
  クライアント側の join フロー再実行 (fork or upstream 提案) を検討
- ~~EC レビュー指摘の design-mismatch ①②③ と i18n 残り一括~~ → **Wave C/D として完了 (2026-07-06)**。
  C = EC の ja 欠落 120 キー + cinny 生英語 37 ファイルの t() 化 (en/ja 1538 キー一致、絵文字パック
  編集画面も日本語化)。D = ①ポップアウト中の元タイルにプレースホルダ (B 案は再評価の結果不採用 —
  メイン窓で操作が完結するため) ②ミニタイル strip の名前非表示 (showGridNameTags$) ③画面共有の
  自動スポットライト化廃止 + リモート共有時のみトースト通知 (自分の共有では出ない)。dev 統合検証
  6 項目 PASS
- **EC fork のセキュリティパッチ棚卸し** — 初回実施済み (2026-07-06、Wave D):
  pnpm audit の critical 1 + high 9 をゼロ化 (vite 8.0.16 / vitest 4.1.8 / undici / ws / protobufjs を
  overrides 固定)。以後は upstream の SECURITY コミット確認と audit を四半期毎に (レビュー H1)
- **検証記録 (2026-07-06)**: バックアップの E2EE 忠実性は実証済み (cross-signing 鍵・デバイス鍵・
  署名鍵すべてハッシュ一致で復元)。ただしオンライン鍵バックアップ (e2e_room_keys) は設定者ゼロで
  「器」の検証に留まる — 運用者アカウントでの鍵バックアップ設定を推奨。SFU 早い者勝ち問題への
  multi_sfu (matrixRTCMode) は **Compatibility モードで解決が実測確定 (2026-07-06)**: dev の連合
  2 ホームサーバー構成で、SFU が分かれたまま音声トラックが相互に届き 60 秒安定 (サーバー間リレー
  不要の client multi-homing 方式。Matrix_2_0 モードは Synapse 側の MSC4407 capability が必要で
  現行では不可)。本番採用の残条件 = ①E2EE ON での動作確認 (本番は E2EE 既定 ON) ②多人数・複数
  ドメインのスケール (クライアント多重接続のコスト増) ③WAN/NAT 実環境。有効化は現状 localStorage
  の開発者設定のみのため、採用時は **fork で matrixRTCMode の既定を Compatibility に変える 1 行
  改修**が導線 (①〜③の確認が前提)

## 明示的に後回し・対象外(requirements.md 参照)

- モバイル対応(`OUT` 当面)
- TURN / UDP 不通ネットワーク対応(`OUT` 当面)
- 映像とハイレゾ音声のリップシンク(`OUT` 当面)
- 384kHz/32bit、AEC 自前実装、非圧縮 PCM 伝送(`LATER`)

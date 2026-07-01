# Roadmap

2026-07 改訂。通話・配信(requirements.md §3)を計画の中心に据え、クライアント選定に判断ゲートを設けた版です。

## Phase 0: Name, domain, and infrastructure decisions

- サービス名を決める
- `SERVER_NAME` を決める(実質恒久ID)
- `matrix.*` / `chat.*` に加えて RTC 用ホスト(例: `rtc.*`、Cloudflare DNS-only)を決める
- VPS を選定する(国内リージョン推奨。回線帯域は当面不問)
- Cloudflare / VPS / Tailscale の経路方針を確定する
- デプロイ形態を決める(自宅 + VPS / VPS 単独。architecture.md の Deployment topologies 参照)

Exit criteria:

- `@user:domain` の形式に納得している
- デプロイ形態(自宅 + VPS / VPS 単独)が決まっている
- 「UDP は Cloudflare を通らない」を前提にした DNS 設計ができている

## Phase 1: Vanilla text deploy

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

## Phase 2b: Client fork

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

友人が同じスターターを建てる前に、配布に耐える状態へ引き上げます。

- セットアップの編集ゼロ化(homeserver.yaml の自動パッチスクリプト)
- イメージタグ固定 + Renovate による更新 PR 運用
- CI: shellcheck、`docker compose config -q`、`caddy validate`
- PostgreSQL dump の自動化、media / signing key のバックアップ、restore drill
- VPS 再構築スクリプト(ステートレス前提の担保)
- 自宅 + VPS / VPS 単独の 2 トポロジを compose profile で切り替え可能にする
- VPS 単独形態向けの外部バックアップ手順(ログ保全の条件)
- `/_synapse/admin` の遮断、`x_forwarded: true` 等のリバースプロキシ整合
- rate limit / abuse 対応、admin/moderator 手順、uptime monitoring
- release タグ運用(`release/*`)を開始し、友人デプロイのバージョンずれに備える

Exit criteria:

- DB 消失シナリオから復元できる
- 第三者(友人)が README だけで一式を建てられる
- 荒らし対応の権限と手順が明文化されている

## Phase 5: Media quality tuning

- 画面共有の 4K 60fps プリセット追加(fork 側)
- Opus 384kbps ステレオ対応(fork 側)
- simulcast ポリシー調整(注視タイル高画質、他は降格)
- 4K60 × 3 本 + 10 人での品質検証

Exit criteria:

- 4K 60fps 画面共有 3 本が 10 人通話内で実用になる
- 送信 384kbps 設定が全参加者(改修版クライアント統一)で有効になっている

## Phase 6: Hi-res audio subsystem

- スパイク: SonoBus / JackTrip(hub)を 192kHz/24bit・10 人・片道 150ms 以内で検証し、買う/作るを判断
- 自作の場合: ネイティブ送受信アプリ + VPS 中継、可逆圧縮を既定
- Opus 系統とのフォールバックとミュート制御(二重再生防止)
- ヘッドセット必須の運用ルールをオンボーディングに明記
- クライアント fork にハイレゾアプリの起動導線を追加

Exit criteria:

- ハイレゾ対応者同士の通話が 192kHz/24bit・片道 150ms 以内で成立する
- 非対応者が混在しても会話が破綻しない(フォールバック動作)

## Phase 7: Product polish

- 独自テーマ、custom emoji/sticker 方針
- notification tuning
- SSO/OIDC、moderation dashboard、bridge/bot integrations

Exit criteria:

- 招待した人が説明なしで日常利用できる
- 運用者が毎日手作業で面倒を見なくても回る

## 明示的に後回し・対象外(requirements.md 参照)

- モバイル対応(`OUT` 当面)
- TURN / UDP 不通ネットワーク対応(`OUT` 当面)
- 映像とハイレゾ音声のリップシンク(`OUT` 当面)
- 384kHz/32bit、AEC 自前実装、非圧縮 PCM 伝送(`LATER`)

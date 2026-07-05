# 運用 runbook

roadmap Phase 4 の exit criteria「荒らし対応の権限と手順が明文化されている」を満たすための運用手順書です。実際のドメイン・IP・パスワードはここには書かず、`example.com` / `<SERVER_NAME>` のようなプレースホルダで統一しています。

## 1. 管理者/モデレーターの権限

Matrix には 2 種類の「権限」があります。混同しないでください。

- **サーバー管理者(admin user)** — Synapse インスタンス全体に対する権限です。ユーザーの無効化、ルームの強制削除など、ルームの外側から効く操作ができます。`scripts/create-admin.sh` (`register_new_matrix_user`) で作成したユーザーがこれにあたります。
- **ルームの power level** — ルームごとに設定される権限で、Matrix の room state イベント (`m.room.power_levels`) で管理されます。目安は次のとおりです。

  | power level | 役割 | できること |
  | --- | --- | --- |
  | 100 | 管理者 | 全操作(power level 自体の変更、ルーム設定変更、BAN/kick、メッセージ削除 等) |
  | 50 | モデレーター | BAN/kick、メッセージ削除、一部のルーム設定変更(既定値) |
  | 0 | メンバー | 発言・既定の閲覧のみ |

サーバー管理者だからといって、自動的に個々のルームで power level 100 を持つわけではありません(自分が作成したルームではデフォルトで 100 を持ちますが、それ以外のルームでは通常のメンバーと同じ扱いです)。逆に、ルームのモデレーターだからといって Synapse の admin API は叩けません。荒らし対応では「ルーム内で収まる話か」「サーバー全体・アカウント自体の話か」で、この 2 つのどちらを使うか判断してください。

### SelfMatrix クライアント(Cinny fork)での power level 変更

1. 対象ルームを開く
2. ルーム名 → **Room Settings** → **Permissions** タブを開く
3. メンバー一覧から対象ユーザーを選び、Moderator / Admin / Custom を設定する

power level 100 を持つユーザーのみがこの画面で他人の power level を変更できます。

## 2. 荒らし・不正利用への対応

### 2.1 ユーザーの無効化(deactivate)

`docker compose exec synapse register_new_matrix_user` は**ユーザー作成専用**のコマンドで、deactivate(無効化)はできません。無効化には Synapse Admin API を使います。

1. admin アクセストークンを用意する。admin user でクライアント(SelfMatrix / Element 等)にログインし、設定画面の "Access Token" 表示、または `POST /_login` のレスポンスから取得します。
2. 対象ユーザーを無効化します。

```
curl -X POST \
  -H "Authorization: Bearer <ADMIN_ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"erase": true}' \
  "https://matrix.example.com/_synapse/admin/v1/deactivate/@troll:example.com"
```

`erase: true` にすると、投稿済みメッセージの内容も可能な範囲でサーバー上から消去されます(federation 先には残り得る点は README の「重要な注意」を参照)。単にログインだけ止めたい場合は `erase` を省略(false 相当)しても構いません。

### 2.2 ルームの削除/ブロック

荒らしがルームそのものを使って迷惑行為をしている場合(スパムルームの作成、federation 経由の攻撃的なルームなど)は、ルームごと止めます。

```
curl -X DELETE \
  -H "Authorization: Bearer <ADMIN_ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"block": true, "purge": true}' \
  "https://matrix.example.com/_synapse/admin/v2/rooms/!roomid:example.com"
```

- `block: true` — 以降、このルーム ID への join を一切禁止します(再作成・再参加による荒らしの再発を防ぎます)。
- `purge: true` — サーバー上のルームデータ(state、メッセージ、メディア参照)を削除します。

この API は非同期実行で、進捗確認用の `delete_id` が返ります。詳細は Synapse Admin API のドキュメント (`Delete Room API`) を参照してください。

### 2.3 ルーム内の BAN / kick

通常の荒らし対応(暴言、スパム投稿など、アカウント自体は残してよいレベル)は、サーバー管理者を呼ぶ必要はありません。該当ルームのモデレーター(power level 50 以上)が SelfMatrix クライアントの UI から直接対応します。

1. 対象ユーザーのプロフィールを開く(メンバー一覧またはメッセージから)
2. **Kick**(一時退出)または **Ban**(再参加不可の追放)を選択

Ban はルームからの追放にとどまり、アカウント自体やサーバーへのログインには影響しません。アカウントごと止めたい場合は 2.1 の deactivate を使ってください。

### 2.4 スパム招待対策

不特定多数からのルーム招待やDMを使ったスパムは、SelfMatrix クライアントの受信箱(invite 一覧)側にスパムフィルタ機能があります。心当たりのない招待は無視・拒否し、繰り返し送ってくるアカウントは 2.1 の deactivate を検討してください。

### 2.5 モデレーションダッシュボード(synapse-admin)

2.1〜2.2 の操作は curl で叩く代わりに、Web GUI の [synapse-admin](https://github.com/etkecc/synapse-admin)(`awesometechnologies/synapse-admin` イメージ)からも行えます。ユーザー一覧・deactivate・ルーム一覧・削除などをブラウザから操作できます。curl runbook(2.1〜2.2)は自動化やダッシュボードが使えない場面向けに残してあります。

**既定では起動しません。** 常時起動が必要な機能ではなく、公開面を増やさないためです。使うときは、まず接続先ホームサーバーを固定する設定を生成してから起動します(誤って別サーバーを操作する事故を防ぎ、bind mount 先のファイルが確実に存在する状態にします)。

```
bash scripts/generate-synapse-admin-config.sh
docker compose --profile admin up -d synapse-admin
```

`.env` の `MATRIX_HOST` から `synapse-admin/config.json` の `restrictBaseUrl` を生成します。`SYNAPSE_ADMIN_BIND`(既定 `127.0.0.1:8083`)でホスト側のバインド先を指定します(**必ず `IP:PORT` 形式で書いてください** — ポート単体だと全インターフェースに公開されます)。**このポートをインターネットに公開しないでください。** synapse-admin は react-admin 製の静的 SPA で、ダッシュボードを開いたブラウザ自身が Synapse の `/_matrix` と `/_synapse/admin` に直接 fetch します(README 記載: "You have no need to expose these endpoints to the internet but to your network")。同梱の Caddyfile は `/_synapse/admin` を edge で 403 遮断しているため(4節)、ダッシュボードを開く端末は次のいずれかで Synapse に到達できる経路が必要です。

- 自宅ネットワーク内から直接アクセスする(自宅サーバー配置の場合)
- Tailscale などの private network 経由でアクセスする
- SSH ポートフォワーディングでトンネルする(例: `ssh -L 8083:localhost:8083 <自宅サーバー>`)

ブラウザで `http://<バインド先>:8083`(または SSH トンネル先)を開き、admin user でログインしてください(ログイン情報は 2.1 の admin アクセストークン取得と同じ admin user を使います)。

停止する場合:

```
docker compose --profile admin stop synapse-admin
```

## 3. レート制限

`scripts/generate-synapse-config.sh` が `homeserver.yaml` に自動で入れる `rc_message` / `rc_delayed_event_mgmt` は、MatrixRTC(通話の delayed event 処理など)向けのチューニングであり、一般的な荒らし対策の設定ではありません。

ログイン・登録は Synapse の既定のレート制限(`rc_login`)がそのまま効いています。通常運用では変更不要ですが、次のような兆候が出た場合は締めることを検討してください。

- 特定 IP / アカウントからの大量ログイン試行(総当たり攻撃の疑い)
- registration が有効な期間に大量アカウント作成が続く(SelfMatrix の既定は `enable_registration: false` のため通常は発生しません)

締める場合は `homeserver.yaml` に `rc_login` ブロックを追加し、`per_second` / `burst_count` を既定よりも小さい値に設定します。具体的な数値は Synapse のドキュメント (`Rate limiting` セクション) を参照し、正規ユーザーの体感に影響が出ないか確認してから本番に反映してください。

## 4. `/_synapse/admin` の保護

Synapse Admin API は deactivate やルーム削除など強力な操作ができるため、**外部からアクセスできる状態で放置しないでください**。

方針:

- edge のリバースプロキシで `/_synapse/admin` へのパスを公開側から遮断する(`location = /_synapse/admin` および配下を deny する)
- admin API を叩く必要があるときは、自宅ネットワークまたは Tailscale(tailnet)など、信頼できる内部経路からのみアクセスする
- 具体的な nginx/Caddy の設定例は VPS/自宅の edge 構成に依存するため、各自の環境のリバースプロキシ設定に「`/_synapse/admin` は内部ネットワークのみ許可」というルールを追加してください

同梱の Caddyfile は既定で遮断済みです。edge を自前 nginx にしている場合は、matrix ホストの server block に次を追加してください。

```
location ^~ /_synapse/admin {
    return 403;
}
```

## 5. 監視の見方

Grafana に「SelfMatrix ボトルネック診断」ダッシュボードを構築する前提です(構築手順は別ドキュメント)。日常の見方の指針は次のとおりです。

- 通話が重い・音声/映像が乱れるという報告があったら、まず VPS の回線パネル(帯域使用量・パケットロス)を確認する。VPS 側の帯域が頭打ちになっていないかをまず疑います。
- 次に Synapse のリクエストレイテンシ・エラー率パネルを見て、通話ではなくテキスト API 側の問題でないかを切り分けます。
- LiveKit(SFU)側のパネルで participant 数・track 数が想定と合っているかを確認し、想定外に多い場合は不正利用(意図しないルームでの通話張り付き等)を疑います。

構成としては、Prometheus が Synapse / node-exporter / LiveKit の各メトリクスエンドポイントをスクレイプし、Grafana がそれを可視化する形を取ります。詳細なダッシュボード定義は別途構築するため、本ドキュメントでは前提の記載にとどめます。

## 6. バックアップ/復元

荒らし対応の一環として「壊れたルームを復元する」「誤って purge したデータを復旧する」といった場面でもバックアップが最後の砦になります。手順の詳細は README の「バックアップと復元」セクションを参照してください。

- 取得: `scripts/backup.sh`
- 復元(訓練・本番に触れない): `scripts/restore.sh backups/<timestamp> --drill`
- 復元(本番反映): `scripts/restore.sh backups/<timestamp>`

`--drill` は定期的に実行し、「バックアップから実際に復元できる」ことを継続的に確認してください。

## 7. 外部バックアップ(VPS 単独形態)

データが VPS 1 台に載る形態では、その VPS 自体の障害・誤操作・侵害でバックアップごと失われ得るため、ログ保全の観点から VPS 外への定期コピーが必須です。

- `rclone` で `backups/` をオブジェクトストレージ(S3 互換など)へ同期します。

  ```
  rclone sync backups/ remote:selfmatrix-backups
  ```

- `remote` は事前に `rclone config` でオブジェクトストレージの認証情報を登録して作成してください。
- cron または systemd timer で定期実行します(`scripts/backup.sh` の直後に実行し、取得済みバックアップを都度クラウド側へ送る想定)。
- リストア時は同期方向を逆にし、`rclone sync remote:selfmatrix-backups backups/` でオブジェクトストレージから VPS 側へ取り戻してから `scripts/restore.sh` を使います。

## 8. ハイレゾ音声(JackTrip hub)の運用

本体と結合しない拡張オプションで、**別リポジトリ [zoobookfool/selfmatrix-hires](https://github.com/zoobookfool/selfmatrix-hires) として提供しています**。構築 (provision)・参加者の追加/削除・起動/停止 (オンデマンド運用)・運用ルール・トラブルシュートはすべてそちらの README を参照してください。

本体側の運用に関わる要点だけ挙げます:

- **帯域監視は本体側の Grafana** (VPS 回線パネル) で行います。ハイレゾは 1 人あたり上下 ≈10Mbps を消費するため、逼迫時は同時参加人数を減らします(既定上限 6 人)。
- **RAM**: hub のオーディオスタックは接続人数に応じて増えます (実測: 2 クライアントで ≈400MB、docs/hires-spike.md)。1GB クラスの VPS では使うときだけ起動し、常用するなら 2GB クラスへの増強を前提にしてください。

## 9. 招待トークンでの登録

既定ではこのスターターは `enable_registration: false` で、誰も自己登録できません(新規ユーザーは 2.1 と同じ admin 経由の `register_new_matrix_user` でのみ作成されます)。SSO/OIDC を導入する代わりの選択肢として、Synapse の `registration_requires_token` を使った「招待コード制」の自己登録を用意しています。

`registration_requires_token: true` を `enable_registration: true` と併用すると、トークンを持たない相手は登録できません(オープン登録にはなりません)。招待したい相手にだけトークンを渡す運用です。

### 9.1 有効化

1. `.env` に `ENABLE_INVITE_REGISTRATION=true` を設定します。
2. `homeserver.yaml` を再生成します(`enable_registration: true` + `registration_requires_token: true` が追記されます)。

```
bash scripts/generate-synapse-config.sh --force
```

3. Synapse を再起動します。

```
docker compose up -d synapse
```

無効化したい場合は `ENABLE_INVITE_REGISTRATION=false`(または未設定)に戻して同じ手順を繰り返します。

### 9.2 トークンの発行/一覧/失効

`scripts/invite-token.sh` が Synapse の registration tokens admin API のラッパーです。admin アクセストークンが必要です(取得方法は 2.1 参照)。

```
# 1 回だけ使える招待コードを発行(7日で失効)
ADMIN_ACCESS_TOKEN=<ADMIN_ACCESS_TOKEN> bash scripts/invite-token.sh create --uses 1 --expiry-days 7

# 発行済みトークンの一覧
ADMIN_ACCESS_TOKEN=<ADMIN_ACCESS_TOKEN> bash scripts/invite-token.sh list

# 特定トークンを失効(削除)
ADMIN_ACCESS_TOKEN=<ADMIN_ACCESS_TOKEN> bash scripts/invite-token.sh delete <token>
```

既定では `http://localhost:8008` の Synapse を叩きます(Synapse と同じホストで実行する前提)。別ホストから叩く場合は `--url` オプションで上書きしてください。`--help` で全オプションを確認できます。

### 9.3 招待の流れ

1. 上記でトークンを発行する(用途に応じて `--uses` で人数、`--expiry-days` で期限を絞る)。
2. 招待したい相手に、トークン文字列と `https://<CHAT_HOST>` を伝える(招待コードは秘密情報として扱ってください — 知っていれば誰でも登録に使えます)。
3. 相手は SelfMatrix クライアントの新規登録画面から、通常のユーザー名/パスワード登録に加えてトークンを入力して登録します。
4. トークンの `uses_allowed` に達すると自動的に使えなくなります。手動で早めに止めたい場合は 9.2 の `delete` を使います。

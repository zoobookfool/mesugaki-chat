# Network Notes

デプロイ形態(docs/architecture.md の Deployment topologies)ごとのネットワーク要点です。

- 経路A(既定): 外部 → Cloudflare → VPS → Tailscale → 自宅サーバー。メディア(UDP)は Cloudflare を迂回して VPS 直終端
- 経路B: VPS 単独。自宅サーバーは関与しない
- 代替案: 自宅直公開。従来の 80/443 転送パターン(帯域コスト優先時の選択肢)

## 経路A: Cloudflare + VPS + Tailscale(既定)

### 自宅側

**ルーターのポート開放は一切不要です。** 自宅サーバーは Tailscale で VPS へアウトバウンド接続するだけなので、CGNAT や MAP-E / DS-Lite(v6プラス等)配下の回線でも問題なく動きます。従来パターンの主要な障害(固定IP、ポート制限、hairpin NAT)がすべて消えるのが、この経路の最大の利点です。

- 自宅サーバーに静的な DHCP リースを与える
- Tailscale をインストールし、VPS と同一 tailnet に参加させる
- OS の自動セキュリティ更新を有効にする

### DNS(Cloudflare)

| ホスト | Cloudflare proxy | 向き先 | 用途 |
| --- | --- | --- | --- |
| `example.com` | proxied | VPS | well-known 配信 |
| `matrix.example.com` | proxied | VPS | Synapse API(client + federation) |
| `chat.example.com` | proxied | VPS | クライアント配信 |
| `rtc.example.com` | **DNS only** | VPS | LiveKit / lk-jwt / ハイレゾ音声(Phase 3 以降) |

Cloudflare の proxy は HTTP(S)/WebSocket しか通せないため、`rtc.*` は必ず DNS only(グレー雲)にして VPS の IP へ直接届くようにします。逆に言うと **VPS の IP は `rtc.*` から判明します**。VPS は隠す対象ではなく、公開終端として扱ってください(自宅 IP は隠れたままです)。

### サブドメインを SERVER_NAME にする場合

apex(`example.com`)を他用途に空けたまま、サブドメイン(例: `m.example.com`)を
SERVER_NAME にできます。その場合の注意:

- well-known(`/.well-known/matrix/server` と `client`)は **SERVER_NAME のホスト**
  (`m.example.com`)で配信します。apex には何も置きません
- **Cloudflare 無料プランの Universal SSL は 1 階層(`*.example.com`)しかカバーしません。**
  `chat.m.example.com` のような 2 階層を proxied にすると証明書エラーになります(Advanced
  Certificate Manager が必要)。proxy 対象ホストはすべて 1 階層に並べてください:
  SERVER_NAME `m.example.com` / API `matrix.example.com` / クライアント `chat.example.com` /
  RTC `rtc.example.com`。well-known の委譲先は SERVER_NAME と同じ階層である必要はありません

### VPS 側ファイアウォール

- `80/tcp`, `443/tcp`: edge Caddy(HTTP系)
- `7881/tcp` と UDP レンジ(例: `50100-50200`): LiveKit のメディア(Phase 3 以降)
- ハイレゾ音声サーバーの待受ポート(Phase 6 で確定)
- Tailscale はアウトバウンドで確立するため受信開放は不要

### Tailscale の注意

- VPS ⇄ 自宅が direct 接続になっていることを `tailscale status` で確認する(DERP リレー経由だと HTTP 系の体感が落ちる)
- この区間を通るのは HTTP 系のみ。メディアは通さない設計なので、トンネルの MTU(既定 1280)がメディア品質に影響することはない

### Cloudflare の注意

- 無料プランはアップロード上限 100MB。Synapse の `max_upload_size` を上限内に収めるか、メディアリポジトリのパスのみ proxy を外す
- `/.well-known/matrix/*` は `application/json` と CORS ヘッダを維持する(キャッシュ設定に注意)

## 経路B: VPS 単独

全コンポーネントを 1 台の VPS に集約する形態です。DNS とファイアウォールは経路A の VPS 側と同じで、Tailscale と自宅側の設定が不要になります。

**データが VPS に載るため、ログ保全(workspace requirements.md §1)の条件として VPS 外(自宅や別ストレージ)への定期バックアップが必須です。** バックアップ手順は 整備済みです (README のバックアップ節参照)。

## 代替案: 自宅直公開

VPS の帯域コストが問題になった場合などに、自宅サーバーを直接公開する従来パターンです。自宅の WAN IP が公開される点と、以下の回線条件を満たす必要がある点を許容できる場合のみ選びます。

ルーター転送:

- WAN `80/tcp` -> 自宅サーバー `:80`
- WAN `443/tcp` -> 自宅サーバー `:443`
- 通話も自宅で受ける場合はさらに `7881/tcp` と UDP レンジ

`/.well-known/matrix/server` で `matrix.example.com:443` に委譲するため、通常は `8448/tcp` を開けずに Federation できます。開けない場合、他の Matrix サーバーは `example.com:8448` を試しに行くことに注意してください。

### この形態でだけ問題になる回線条件

- **CGNAT / MAP-E / DS-Lite**: WAN アドレスが `100.64.0.0/10` / `10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16` の場合や、v6プラス等で使えるポートが制限される回線では、外部からのポート転送が成立しないか大きく制約されます。ISP に公開 IPv4 を依頼するか、経路A に切り替えるのが解決策です
- **動的 IP**: DDNS か DNS プロバイダの API 更新が必要です
- **hairpin NAT**: 外からは繋がるのに LAN 内から自ドメインへ繋がらない場合はこれです。ルーターの NAT ループバック有効化か、LAN 内 DNS 上書きで解決します
- **ISP のポートブロック**: 一部の住宅向け回線は inbound `80/443` を塞いでいます

## 外部からの疎通確認

外部ネットワーク(スマホのテザリング等)から:

```sh
curl -I https://chat.example.com
curl https://example.com/.well-known/matrix/server
curl https://matrix.example.com/_matrix/client/versions
```

Federation の well-known の期待値:

```json
{"m.server":"matrix.example.com:443"}
```

通話導入後(Phase 3)は、`rtc.example.com` が Cloudflare を経由していないこと(応答ヘッダに `cf-ray` が無いこと)もあわせて確認してください。

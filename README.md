# LifeLog

iPhone で会話を録音し、端末内で日本語に文字起こしして、Google ドライブの「LifeLog」フォルダにある日付ごとの Google ドキュメントへ自動で追記するアプリ。ChatGPT や Claude の Google ドライブ連携から検索して使う。

- 録音: 5分ごとに区切る（AAC 16kHz モノラル）。ほぼ無音の区切りは捨てる。
- 文字起こし: iOS 26 の SpeechAnalyzer（端末内、無料）。
- 保存: Google Docs API で `HH:mm:ss  発言` の形で追記。追記に成功したら音声を消す。
- Mac なしで開発する: GitHub Actions の macOS でビルドし、TestFlight に配る。

## 無料で入れる（Apple Developer Program なし）

Windows の [Sideloadly](https://sideloadly.io/) を使い、無料の Apple ID で署名して iPhone に入れる。

1. GitHub の Actions →「TestFlight」の最新の実行 → Artifacts から `LifeLog-unsigned-ipa` をダウンロードして展開する。
2. Windows に Sideloadly と iTunes（Apple 公式サイト版）を入れ、iPhone を USB でつなぐ。
3. Sideloadly に IPA をドラッグし、Apple ID を入力して Start を押す（捨てアカウントの Apple ID がおすすめ）。
4. iPhone の「設定」→「プライバシーとセキュリティ」→「デベロッパモード」をオンにし、「一般」→「VPN とデバイス管理」で自分の Apple ID を信頼する。

制限:
- **7日で起動しなくなる。** 週1回、同じ手順で入れ直す（データは残る）。Sideloadly の自動更新を使うと、PC と iPhone が同じ Wi-Fi にあれば自動で入れ直せる。
- 無料の Apple ID で入れられるアプリは同時に3つまで。
- Apple Watch アプリは、無料の署名でうまく入らないことがある（未確認）。
- バンドル ID が `com.off53jub.lifelog` から変わった場合は、Google の OAuth クライアントもその ID で作り直す。

この方法では、Google の準備（下の2）と、GitHub の Secrets の `GOOGLE_CLIENT_ID` と `GOOGLE_REVERSED_CLIENT_ID` だけが必要。

## 最初の準備（一度だけ）

### 1. Apple
1. [Apple Developer Program](https://developer.apple.com/programs/) に登録する。
2. [App Store Connect](https://appstoreconnect.apple.com/) で「マイ App」→「＋」→「新規 App」。バンドル ID は `com.off53jub.lifelog`（一覧に無ければ、[Identifiers](https://developer.apple.com/account/resources/identifiers/list) で先に登録する）。
3. 「ユーザとアクセス」→「統合」→「App Store Connect API」で、**Admin** 権限のキーを作る。`.p8` ファイル、キー ID、Issuer ID を控える。
4. チーム ID を [Membership](https://developer.apple.com/account#MembershipDetailsCard) で確認する。

### 2. Google
1. [Google Cloud Console](https://console.cloud.google.com/) でプロジェクトを作り、**Google Drive API** と **Google Docs API** を有効にする。
2. 「OAuth 同意画面」を「外部」で作り、テストユーザーに自分のアカウントを追加する。
3. 「認証情報」→「OAuth クライアント ID」→ 種類「iOS」、バンドル ID `com.off53jub.lifelog`。クライアント ID（`xxxx.apps.googleusercontent.com`）を控える。

### 3. GitHub の Secrets
リポジトリの Settings → Secrets and variables → Actions に追加する。

| 名前 | 中身 |
|---|---|
| `APPLE_TEAM_ID` | チーム ID |
| `ASC_KEY_ID` | API キー ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | `.p8` ファイルの中身をそのまま |
| `GOOGLE_CLIENT_ID` | `xxxx.apps.googleusercontent.com` |
| `GOOGLE_REVERSED_CLIENT_ID` | `com.googleusercontent.apps.xxxx`（上を逆にしたもの） |

## ビルドと配信
`main` に push するか、Actions の「TestFlight」を手動で実行する。10〜20分ほどで App Store Connect に届き、TestFlight アプリから iPhone に入れられる（内部テスターに自分を追加しておく）。

## 使い方
1. 「Google でログイン」。
2. 「録音を始める」。画面を消しても録音は続く。電話などで止まったら、アプリを開いて再開する。
3. ドライブの `LifeLog/2026-10-16` などのドキュメントに、時刻つきで追記されていく。

## 今後
- Apple Watch アプリ（時計で録音して iPhone に転送）
- 会議だけ話者分離（OpenAI gpt-4o-transcribe-diarize）
- 1日の要約をドキュメントの先頭に付ける
- Limitless の過去データの取り込み

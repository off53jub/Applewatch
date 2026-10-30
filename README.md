# LifeLog

iPhone で会話を録音し、日本語に文字起こしして、Google ドライブの「LifeLog」フォルダにある日付ごとの Google ドキュメントへ自動で追記するアプリ。ChatGPT や Claude の Google ドライブ連携から検索して使う。

- 録音: 5分ごとに区切る（AAC 16kHz モノラル）。ほぼ無音の区切りは捨てる。
- 文字起こし: ふだんは iOS 26 の SpeechAnalyzer（端末内、無料）。API キーを入れると Groq の Whisper large-v3（無料枠あり）か OpenAI の gpt-transcribe（有料）に切り替えられる。
- 保存: Google Docs API で `HH:mm:ss  発言` の形で追記。追記に成功したら音声を消す。
- Mac なしで開発する: GitHub Actions の macOS でビルドし、TestFlight に配る。

## 無料で入れる（Apple Developer Program なし）

Windows の [Sideloadly](https://sideloadly.io/) を使い、無料の Apple ID で署名して iPhone に入れる。

1. GitHub の Actions →「TestFlight」の最新の実行 → Artifacts から `LifeLog-unsigned-ipa` をダウンロードして展開する。
2. Windows に Sideloadly と iTunes（Apple 公式サイト版）を入れ、iPhone を USB でつなぐ。
3. Sideloadly に IPA をドラッグし、Apple ID を入力して Start を押す（捨てアカウントの Apple ID がおすすめ）。
4. iPhone の「設定」→「プライバシーとセキュリティ」→「デベロッパモード」をオンにし、「一般」→「VPN とデバイス管理」で自分の Apple ID を信頼する。

Actions のビルドに「Google の ID が未設定」という警告が出ていたら、Secrets がまだ読めていない。Secrets は入れる前に始まったビルドには反映されないので、入れたあとのビルドで確かめる。

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

## 高精度の文字起こし（クラウド）
アプリの「サービスと API キーの設定」で、使うサービスを選んでキーを貼り、「高精度で文字起こし」をオンにする。

- **Groq（無料）**: Whisper large-v3。[console.groq.com](https://console.groq.com/keys) でアカウントを作り、API キー（`gsk_` で始まる）を作る。カード登録は要らない。無料枠は1日 28,800 秒（8時間）分まで。使い切ったら、枠が別にある次点の whisper-large-v3-turbo（こちらも8時間）に切り替え、それも使い切ったら端末内の文字起こしで済ませる。画面の「直近の文字起こし」に、どれを使ったかが出る。区間ごとの時刻も付く。
- **OpenAI（有料）**: gpt-transcribe（1分 $0.0045）。[platform.openai.com](https://platform.openai.com/) の Billing でクレジットを入れてからキーを作る（ChatGPT の有料プランとは別会計）。文ごとの時刻は返らないので、5分の区切りごとの開始時刻だけが付く。アプリの「月の上限」を超えたら、月が変わるまで端末内に戻る。

共通:
- 先に端末内で文字起こしし、何も聞き取れなかった区切りはクラウドに送らない。
- 「聞き取ってほしい言葉」に人名や社名を1行ずつ書くと、その表記で書き起こされやすくなる。
- キーが無効・残高切れのときは高精度を自動でオフにし、端末内の結果で続ける。通信できないときは音声を残してあとでやり直す。

## 話者の聞き分け（端末内・無料）
「話している人を聞き分ける」をオンにすると、[FluidAudio](https://github.com/FluidInference/FluidAudio) の話者分離モデル（初回に数十 MB をダウンロード）で、区切りごとに「いつ誰が話したか」を調べ、文字起こしの行に `[自分]` `[人物1]` などを付ける。

- 「自分の声」で20秒ほど自分の声を録って登録すると、自分の発言に `[自分]` が付く。
- 一度聞いた声は覚えておき、次の区切りでも同じ人として扱う。「話した相手」で名前を付けると、次からその名前で出る。
- 名前を付けていない声は、2週間聞かなければ忘れる。
- 保存するのは声の特徴（数値）だけで、この iPhone から外には出ない。他の人の名前を付けるときは、その人の了解を取っておく。

## 会話の見出しと1日のまとめ
話が3分途切れるごとに1つの「会話」とみなし、ドキュメントの会話の頭に見出しを差し込む。

```
14:05〜14:40　会社　田中さんと　来週の提案資料の打ち合わせ   ← 見出し2
・提案は A 案で進める
・資料は木曜までに自分が作る
14:05:12  [田中さん] じゃあ来週の…
```

- 内容の見出しと要点（最大3つ）は、Groq の無料枠の言語モデル（`openai/gpt-oss-120b`、長い会話は `openai/gpt-oss-20b` で区切ってから）で作る。Groq の API キーが無いときは、時刻・場所・相手だけの見出しになる。
- 日が変わると、前の日のドキュメントの先頭に「1日のまとめ」（会った人・決まったこと・やること・話題）を差し込む。
- 80文字に満たない短い会話（テレビの音や独り言など）には見出しを付けない。
- 見出しは、次の区切りが届いたときかアプリを開いたときに付く。録音が止まっていると、最後の会話の見出しは次に開くまで付かない。

## 人物ノート
名前を付けた相手ごとに、ドライブの「LifeLog」フォルダに「人物ノート - 名前」というドキュメントを作り、その人と話した会話を新しい順に書き足す。

```
10/30(木) 14:05〜14:40　会社　来週の提案資料の打ち合わせ   ← 見出し3
一緒にいた人: 佐藤さん
・提案は A 案で進める
・資料は木曜までに自分が作る
（2026-10-30 のドキュメント）
```

- 要点は会話の見出しと同じもの。要約が無いときは、その人の発言を3つまで載せる。
- 「人物3」のように名前を付けていない人は書かない。名前を付けたあとに話した会話から書き足される。

## 場所
「場所を記録する」をオンにすると、大きく移動したとき（数百 m）だけ位置を記録し、見出しに場所を添える。

- 「登録した場所」で今いる場所に名前（自宅・会社など）を付けると、その300 m 以内はその名前で出る。
- それ以外は、近くの駅があれば「〇〇駅近く」、無ければ「〇〇付近」。
- 画面を閉じているあいだも記録するには、位置情報の許可を「常に」にする。位置はこの iPhone の中だけに置く（地名を調べるときだけ Apple に問い合わせる）。

## これから
- 会議だけ話者分離（OpenAI gpt-4o-transcribe-diarize）
- Limitless の過去データの取り込み

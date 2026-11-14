LifeLog PC — 家の PC で3つの音声モデルを動かして、iPhone の録音を多数決で文字にする
=====================================================================

Haas-ja・ReazonSpeech・Whisper large-v3 の3つで同じ声の区間を文字にし、読みがいちばん合う文を選びます。
NVIDIA の GPU があれば、Whisper は GPU で動きます（無ければ CPU で large-v3-turbo を使います）。

■ はじめて使うとき
1. このフォルダごと、好きな場所（例: ドキュメント\LifeLogPC）に置きます。
2. LifeLogPC.exe をダブルクリックします。
   - 初回だけ、モデルをダウンロードします（Haas-ja 約2.4GB・ReazonSpeech 約600MB・Whisper 1.5〜3GB、
     GPU があれば GPU の部品 約1.3GB も）。合わせて 5〜7GB ほどの空きが要ります。時間がかかるので、そのまま待ちます。
   - 起動のたびに3つのモデルを読み込むので、使えるようになるまで1〜2分かかります。
   - 「Windows セキュリティの重要な警告」が出たら「アクセスを許可する」を押します。
   - 最後に「宛先」と「合言葉」が表示されます。
3. iPhone の LifeLog → 設定 → 家の PC に、宛先と合言葉を入れて「つながるか試す」を押します。
4. 黒い画面は閉じずに置いておきます（最小化はかまいません）。閉じると受け付けが止まります。

■ 外にいるときも使う（Tailscale）
家の外（モバイル通信）から PC につなぐには、無料の Tailscale を使います。
1. PC に Tailscale を入れてログインします: https://tailscale.com/download/windows
2. iPhone にも App Store から Tailscale を入れて、同じアカウントでログインし、接続をオンにします。
3. LifeLogPC.exe を起動し直すと、「〜.ts.net:47615」の形の宛先が表示されます。iPhone にはその宛先を入れます。
   この宛先なら、家の Wi-Fi でもモバイル通信でも同じようにつながります。
   （番号だけの宛先 100.xx.xx.xx は、iPhone の決まりで http では送れないので使いません）
   名前が出ないときは、Tailscale の管理画面 https://login.tailscale.com/admin/dns で MagicDNS をオンにします。
※ 職場の Wi-Fi につないだ iPhone から Tailscale を使うと、職場のルールに触れることがあります。
  職場ではモバイル通信を使うか、職場のルールを確かめてください。

■ 時計から直接送る（家の Wi-Fi にいるとき。2026-11-07）
時計で録った区切りを、iPhone を待たずに PC にも送って早く文字にしてもらえます。時計には Tailscale が無いので、家の中の住所を使います。
1. LifeLogPC.exe を起動したときの画面の「時計から直接送るとき…」の行に出る番号（192.168.… など）を見ます。
2. iPhone の LifeLog → 設定 → 家の PC →「時計から直接」の「家の中の住所」に、その番号を入れます。
   （PC の家の中の住所は、ルーターが変えることがあります。届かなくなったら、もう一度見て入れ直します）
PC は同じ区切りを二重には文字にしません（時計と iPhone の両方から届いても1回だけ）。

■ つながらないとき
・Windows のファイアウォールが止めていることがあります。スタートボタンを右クリック →「ターミナル（管理者）」で次の1行を実行します
  （通すのは Tailscale と家の中の機器からだけです）。
    New-NetFirewallRule -DisplayName "LifeLog PC" -Direction Inbound -Protocol TCP -LocalPort 47615 -RemoteAddress 100.64.0.0/10,LocalSubnet -Action Allow
・iPhone の Safari で http://宛先/hello を開くと「合言葉が違います」と出れば、PC までは届いています。
・番号 47615 をほかのソフトが使っているときは、LifeLogPC.exe --port 47616 のように別の番号で起動し、
  iPhone の宛先も「〜.ts.net:47616」のように番号付きで入れます。

■ Windows の起動時に自動で始める
コマンドプロンプトでこのフォルダに移り、次を実行します。
    LifeLogPC.exe --startup
やめるときは
    LifeLogPC.exe --no-startup

■ 試す
    LifeLogPC.exe --test 音声ファイル
音声を文字にして、モデルごとの文と、選んだ文と、かかった時間を表示します。
「使ったモデル」の最後に（cuda）と出ていれば GPU で動いています。

■ モデルを減らす・選ぶ
    LifeLogPC.exe --engines haas,reazon        Whisper を使わない
    LifeLogPC.exe --whisper large-v3-turbo     Whisper を軽いものにする（GPU のメモリが足りないときなど）
    LifeLogPC.exe --engines haas,reazon,whisper  4票目の kotoba-whisper（とあなた向け Whisper）を使わない

NVIDIA の GPU があると、日本語の話し言葉で学び直した kotoba-whisper（kotoba-tech/kotoba-whisper-v2.0-faster、MIT、約1.5GB）も
4票目として動かします（GPU が無いときは遅すぎるので使いません）。
    LifeLogPC.exe --no-clean                   聞く前の音そろえ（80Hz より下を削る・小さい声を最大 +18dB 持ち上げる）をしない
    LifeLogPC.exe --no-hotwords                Haas-ja・ReazonSpeech に登録語を効かせない（前の速い聞き方に戻す）

iPhone から届いた「聞き取ってほしい言葉」（名前・言葉の登録・話題の言葉）は、Whisper のヒントに加えて、
Haas-ja と ReazonSpeech にも「ホットワード」として効かせます（モデルが知っている文字だけでできた、2〜15文字の言葉を60個まで）。
    LifeLogPC.exe --device cpu                 GPU を使わない
読み込めなかったモデルは飛ばして、残りで動きます（ログに理由が出ます）。

■ おまけの機能（版 3 から）
新しい iPhone のアプリが使います。古いアプリはこれまでどおり動きます。
・聞き逃した声を探す: iPhone が声と気づかなかった所も、PC が音の大きさで探して一緒に文字にします（新しいモデルは使いません）。
・話し手の声の特徴: 区間ごとに、誰の声かを見分けるための数の並びを返します。
  版 5 からは 3D-Speaker の CAM++（いろいろな国の人の声 VoxCeleb で学んだもの、Apache License 2.0、約30MB）を使います。
・周りの音: 区間ごとに、話し声・音楽・車などの音の名前を上位 5 つ返します。
  sherpa-onnx の Zipformer の音の聞き分けモデル（AudioSet、Apache License 2.0、約110MB）を使います。
話し手と周りの音のモデルは、初めて頼まれたときに取ってきます（その1回だけ時間がかかります）。
うまく動かなくても、文字にする処理には響きません。試すときは
    LifeLogPC.exe --check-extras 音声ファイル

■ 版 4 で足したもの
新しい iPhone のアプリが使います。古いアプリはこれまでどおり動きます。どれも、うまく動かなければ前と同じに動きます。
・言葉ごとの時刻: 文字にした行に、言葉ごとの始まりと終わりの秒を付けます（再生しながら今の言葉を示すのに使います）。
  選んだ文を書いたモデルが時刻を出せるときだけ付けます。ほかのモデルの文で一部を直した行には付けません。
  要らないときは LifeLogPC.exe --no-words（Whisper が少し速くなります）。
・雑音を除いてもう一度聞く: iPhone が頼んだときだけ、雑音を除いた音を Haas-ja と ReazonSpeech にもう一度聞かせて、
  多数決の票を増やします。雑音を除くのは GTCRN（とても小さいモデル、約0.5MB、起動したときに取ってきます）。
  試すときは  LifeLogPC.exe --test 音声ファイル --enhance
・あなた向けのモデルの材料: iPhone で直した文と、その所の声を、PC の中（下の personal\data）に貯めます。
  同じものは2回貯めません。5000 個までです（それより多くは貯めません。古いものを勝手に消すこともしません）。
・あなた向けのモデル: 下の「あなた向けのモデルを作る」で作ると、次に起動したときから
  「あなた向け Whisper」も票を入れます（NVIDIA の GPU があるときだけ）。
録音も文も、PC の外には送りません。

■ 版 5 で足したもの
新しい iPhone のアプリが使います。古いアプリはこれまでどおり動きます。どれも、うまく動かなければ前と同じに動きます。
・言いよどみを食い違いに数えない: 多数決でモデルどうしの文を比べるとき、「えーと」「えっと」「あのー」「うーん」「んー」、
  文の頭の「えー」「そのー」、句読点にはさまれた「まあ」「あー」を除いてから比べます。
  「3時」と「三時」、「1人」と「一人」のような数字の書き方の違いもそろえます。
  「あの人」の「あの」、「その件」、「うん」「ええ」（はい）、「ううん」（いいえ）、「なんか」は、中身のある言葉のことが多いので除きません。
  除くのは比べるときだけで、iPhone に返す文はモデルが書いたままです。
・合言葉が違うとき: 送られてきた音声を（200MB まで）読み捨ててから「合言葉が違います」と答えます。
  前の版は読む前に断っていたので、iPhone には「接続が切れました」と見えていました。
・話し手の声の特徴のモデルを、中国語の声だけで学んだ ERes2Net から、いろいろな国の人の声で学んだ CAM++
  （3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx、512 次元）に替えました。
  モデルが替わると声の特徴の数の並びも変わるので、iPhone はつながったときにモデルの名前を見て、登録した声を測り直します。
  前のモデルに戻すときは、環境変数 LIFELOG_SPEAKER_MODEL に 3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx を入れて起動します。
・聞き逃した声を探す（vad=union）のに、声らしさを聞き分ける Silero VAD（MIT License、約0.6MB）を使います。
  起動したときに取ってきます。取ってこられないときは、前と同じ音の大きさで探します。
・Qwen3-ASR の票（使う設定にしたときだけ）: 下の「Qwen3-ASR も使う」を見てください。
・この PC の言語モデル（使う設定にしたときだけ）: 下の「この PC の言語モデル（Ollama）」を見てください。

■ 版 6 で足したもの
新しい iPhone のアプリが使います。古いアプリはこれまでどおり動きます。どれも、うまく動かなければ前と同じに動きます。
・後で受け取る文字起こし: iPhone は録音の区切りを1つずつ裏で PC に預け、PC が文字にし終えたころに答えを受け取ります。
  PC が声のある所を自分で探し（Silero VAD、使えなければ音の大きさ）、今までと同じ多数決で文字にします。
  1つずつ文字にします（版 8 からは、待っているものが2つ以上あれば、新しく受けたものから）。
  PC を起動し直しても、預かったものは続きから文字にします。
  預かった音声は、文字にし終えたら（うまくいかなくても）すぐ消します。答えは 7 日たったら消します。
  （版 7 からは、音声は iPhone が答えを受け取って消すまで残し、消したら下の「音声を残す」に移します）
  置き場所は %LOCALAPPDATA%\LifeLogPC\jobs です。録音も文も PC の外には送りません。
・見守りの画面: iPhone の Safari で次を開くと、PC の様子が見られます。
    http://<PC の Tailscale 名>:47615/dash
  （<PC の Tailscale 名> は、起動したときに「宛先」に出る 〜.ts.net の名前です）
  ユーザー名とパスワードを聞かれたら、ユーザー名は何でもよく、パスワードに合言葉を入れます。
  または一度だけ  http://<PC の Tailscale 名>:47615/dash?key=合言葉  で開くと、次からはそのまま開けます。
  版と作った回の番号、モデルが CPU と GPU のどちらで動いているか（GPU の最後の失敗も）、Ollama とモデル、
  預かった区切りの数と直近 20 個（音声の長さ・かかった時間・速さ）、/transcribe の速さ（直近 20 回の中央値）、
  モデルの組ごとの読みの近さ（直近 100 回）、記録の中の失敗・注意（直近 15 行）、ディスクの空き、動いている時間が出ます。
  文字起こしの文の中身は出しません。
  「再起動」: LifeLog PC を終えて、タスク スケジューラの Lifelog-HomePC-Autostart で起動し直します
  （そのタスクが無ければ、同じ引数で起動し直します）。
  「更新を確かめる」: 下の「自分で新しい版に入れ替える」を、今すぐ行います（自動の更新をオフにしていても行います）。
・自分で新しい版に入れ替える: 起動して 10 分後と、そのあと 6 時間ごとに、GitHub（off53jub/Applewatch）のリリースの
  「pc-v6-番号」を見て、今より新しい版があれば取ってきて（数百 MB）、ハッシュ（SHA-256）を確かめてから入れ替えます。
  入れ替えるのは、文字にしている最中のものが無いときだけです。入れ替えの手順:
    1. 新しい版を、LifeLog PC のフォルダの隣の「<フォルダの名前> 新しい版」に展開します
    2. LifeLog PC を終え、今のフォルダの名前を「<フォルダの名前> 前の版」に変えます（前からある「前の版」は消します）
    3. 新しい版のフォルダを、もとの名前にします
    4. タスク スケジューラの Lifelog-HomePC-Autostart で起動し直します（無ければ同じ引数で起動します）
  うまくいかなかったときは、前の版のまま起動します。新しい版がおかしいときは、LifeLog PC を止めてから、
  「前の版」のフォルダをもとの名前に戻すと、前の版に戻せます。
  取ってきたものは %LOCALAPPDATA%\LifeLogPC\update に置きます。Python のまま動かしているときは入れ替えません。
  自動の更新をやめるときは、config.json に "auto_update": false を足すか、LifeLogPC.exe --no-auto-update で起動します。
  ※ 版 5 から版 6 へは自動では替わりません。一度だけ、GitHub の Actions の成果物か、リリースの LifeLogPC.zip を手で展開して
    入れ替えてください。
・意味で探す: iPhone から送られた文字起こしの行を、この PC の Ollama の埋め込みのモデル bge-m3（約1.2GB、MIT License）で
  数の並びにして、%LOCALAPPDATA%\LifeLogPC\semantic.db に置きます。言葉が同じでなくても、意味の近い行を探せます。
  Ollama が動いていて bge-m3 が無ければ、起動したときに Ollama に取ってきてもらいます（1回だけ）。
  Ollama はこの PC の中（http://127.0.0.1:11434）だけを使い、文はこの PC の外には送りません。
  使わないときは  LifeLogPC.exe --no-semantic（config.json の "semantic": false でも同じ）。
  試すときは  LifeLogPC.exe --check-semantic（一時のフォルダで、本物の bge-m3 に日本語の文を置いて探します）

■ 版 7 で足したもの（記録を PC の大きい画面で読む・直す）
新しい iPhone のアプリが使います。古いアプリはこれまでどおり動きます。
・記録を受け取る: iPhone は PC とつながったときに（多くても 10 分に 1 回）、前に送ってから変わった日の記録
  （閉じた会話。iPhone どうしの同期と同じ中身）を送ってきます。初めは 60 日分を少しずつ送ります。
  職場の会話も送ります（家の PC の中だけで、外には出しません）。
  PC は %LOCALAPPDATA%\LifeLogPC\records\<日>.json に置き、中身が変わったときは 1 つ前を <日>.prev.json に残します。
・記録の画面: 見守りの画面の「記録を読む・探す・直す」から開きます（合言葉は見守りの画面と同じです）。
    http://<PC の Tailscale 名>:47615/dash/records
  スマホでも PC のブラウザでも読めます。
  - 日の一覧 → 1 日の会話（時刻・見出し・要点・相手・場所・場面、行ごとに時刻・話し手・文・★の印・確からしさ）。
    確からしさ（0〜1）が 0.45 より低い行は「不確か」と出します。
  - ▶ 再生: その行の所から音声を聞けます（下の「音声を残す」の音声があるときだけ。無ければ「PC に音声がありません」）。
  - 文字で探す: 全部の日から探します（空白で区切ると、全部の言葉を含む行。話し手の名前でも当たります）。
  - 意味で探す: 版 6 の「意味で探す」を使います（言葉が同じでなくても意味の近い行。職場の会話も含みます）。
  - 直す: 行の「直す」から、行の文を直す・行の話し手を変える、ができます。
    話し手は、記録に出てくる名前と「自分」から選ぶだけです。PC から新しい名前は作りません
    （名前のある人をまとめたり、名前を変えたりもしません。名前の無い「人物N」も作りません）。
  - 直した分は、iPhone が次に PC につながったときに受け取り、iPhone の記録に当てます。行の下に
    「iPhone に送る前」「iPhone で直しました」「iPhone で直せませんでした（理由）」と出ます。
    iPhone の記録がそのあいだに変わっていたら、iPhone は直さずに知らせてきます（iPhone の新しい中身を上書きしないため）。
  - iPhone が受け取る前に、同じ行の文（または話し手）を 2 回直したら、新しいほうだけを渡します。
    iPhone が受け取ったあとに直したときは、受け取った直しのあとに続けて渡します。
  直しは %LOCALAPPDATA%\LifeLogPC\edits.db に置きます。
・音声を残す: iPhone が「後で受け取る文字起こし」の答えを受け取って消したとき、音声は消さずに
  %LOCALAPPDATA%\LifeLogPC\audio\<日>\<名前> に移します。PC が受けてから 30 日たったものと、
  合わせて 30GB を超えた分は、古いものから消します。変えるときは config.json に
  "audio_keep_days": 日数、"audio_keep_gb": GB を足します（"audio_keep_days": 0 なら残しません）。
  /transcribe だけで文字にした区切りや、版 7 より前の録音の音声は PC にありません。
・確かめるとき:  LifeLogPC.exe --check-v7-records（一時のフォルダと作り物の記録で、受け取り・画面・直し・音声を確かめます）
  画面だけ試すとき:  python lifelog_pc.py --try-records --port 47690
  （モデルを読み込まずに、一時のフォルダと作り物の記録で起動します。この PC の中の http://127.0.0.1:47690 だけで受け、
   ふだんの番号 47615 とふだんの置き場所は使いません。文字起こしはできません）
記録・音声・直しは、PC の外には送りません。PC の記録（log.txt）には、会話の文や人の名前を書きません。
■ 版 7 で足したもの（実機の様子・TestFlight の報告・見えない通知・学び直しの自動化と GPU の時間割）
新しい iPhone のアプリが使います。古いアプリはこれまでどおり動きます。どれも、うまく動かなければ前と同じに動きます。
・実機の様子: iPhone の LifeLog が、1時間に1回ほど・アプリを開いたとき・見えない通知で起きたときに、PC に様子を送ってきます
  （自己点検の行・落ちた記録・MetricKit の診断・録音や待ちの様子・通知の登録。会話の中身や人の名前は入りません）。
  PC は端末ごとに %LOCALAPPDATA%\LifeLogPC\diag\<端末の ID> に置きます（latest.json・日ごとの .jsonl は 60 日分・metrickit）。
  %LOCALAPPDATA%\LifeLogPC\diag\summary.md に、今の様子と気になる所を書き直します（この PC で動く Claude が読むためのものです）。
  気になる所: 3時間様子が来ない／24時間以内に落ちた・固まった／自己点検で ok でない行／時計が録音中なのに、時計からの便りが
  30分より前／録音中なのに、録音の区切りが60分より前。見守りの画面の「実機の様子」にも出ます。
・TestFlight の報告: App Store Connect の API キーを入れると、1日に4回（起動して5分後と、そのあと6時間ごと）、TestFlight の
  スクショつきの報告と落ちた報告を読んで、%LOCALAPPDATA%\LifeLogPC\feedback に置きます（スクショ・落ちた記録も）。
  見守りの画面の「TestFlight の報告」に出ます（「詳しく」でコメント・スクショ・落ちた記録）。「今すぐ読む」でもすぐ読みます。
  キーが無いときは何もしません。テスターのメールアドレスは置きません。
  キーの入れ方: App Store Connect の「ユーザとアクセス」→「統合」→「App Store Connect API」で、役割が Developer 以上のキーを作り、
  .p8 のファイルを保存します。見守りの画面の「キーを入れる画面を開く」で .p8 を選び、issuer ID（同じ画面の上にあります）を
  入れて「App Store Connect のキーを入れる」を押します。キーは %LOCALAPPDATA%\LifeLogPC\asc に置きます
  （手で置くときは AuthKey_<キーの ID>.p8 と、config.json に {"key_id": "…", "issuer_id": "…"}）。
  キーも報告も、GitHub など PC の外には置きません（リポジトリは公開なので）。
・見えない通知（家の PC から iPhone を起こす）: 文字にし終えたとき・録音中なのに30分なにも来ないとき・3時間様子が来ないとき・
  毎日 3:30 に、iPhone に見えない通知（APNs）を送って、取り込み・送り出し・夜の処理を進めてもらいます。
  回数の上限: 文字にし終えた知らせは同じ端末へ10分に1回、起こすのは1時間に2回・1日12回、様子を頼むのは1日4回、夜の処理は1日1回。
  APNs が「このトークンはもう使えない」（410）と答えたら、そのトークンには送りません（iPhone から新しいトークンが届けば、また送ります）。
  鍵の入れ方: Apple Developer の「Certificates, Identifiers & Profiles」→「Keys」で、Apple Push Notifications service（APNs）に
  チェックを入れて鍵を作り、.p8 を保存します。見守りの画面の「鍵を入れる画面を開く」で .p8 を選んで「通知の鍵を入れる」を押します。
  鍵は %LOCALAPPDATA%\LifeLogPC\apns\AuthKey_<鍵の ID>.p8 に置きます（手で置いてもかまいません）。チームの ID は iPhone が
  知らせてきます（鍵を入れる画面で入れることもできます）。鍵かチームの ID が無いときは、何もしません。
  見守りの画面の「テスト通知を送る」で、iPhone に目に見えるテストの通知が届くか確かめられます。
  通知を使わないときは config.json に "push": false を足します。
・自動の学び直し: 材料が 300 個以上たまり、前に学び直してから 50 個以上増えていたら、週に1回（初めは日曜の 2:00〜6:00）、
  仕事が無いときに、このフォルダの train_personal.py を自分で動かします。良くなったときだけあなた向けのモデルを入れ替え、
  起動し直さなくても、すぐに使い始めます。
  学び直しの部品（Python 3.12 と torch など、合わせて 5GB ほど）は、初めて要るとき（材料がそろった夜）に
  %LOCALAPPDATA%\LifeLogPC\train に用意します。取ってきたものは、train-requirements.txt などに決めておいたハッシュ（SHA-256）と
  合うものだけを使います。学び直しのあいだは、GPU の文字起こしのモデル（Whisper・kotoba-whisper・あなた向け Whisper）と、
  この PC の Ollama のモデルを下ろし、Haas-ja と ReazonSpeech だけで受けます。終わったら戻します。
  6 時間を超えたら止めて、次の週にやり直します。GPU のメモリが足りないと言われたら、次は小さく（--batch 2）学びます。
  学び直しの出力は %LOCALAPPDATA%\LifeLogPC\personal\train-log.txt に、様子は見守りの画面の「学び直しと GPU の時間割」と
  /train-status の "auto" に出ます。時間帯を変える・やめるときは config.json に（例）
    "autotrain": {"days": ["sun"], "start": "02:00", "end": "06:00"}　　やめるときは "autotrain": false
・GPU の時間割: 夜（1:00〜6:00）に30分仕事が無ければ、GPU の文字起こしのモデルを下ろして、Ollama と学び直しに GPU を空けます。
  仕事が来たら戻します（戻るまでの1分ほどは Haas-ja と ReazonSpeech だけで受けます）。GPU の空きが足りないときは5分おいて
  やり直します。変える・やめるときは config.json に（例）
    "gpu_night": {"start": "01:00", "end": "06:00", "idle_minutes": 30}　　やめるときは "gpu_night": false
・試す:
    LifeLogPC.exe --check-v7-ops       一時フォルダと作り物の相手で、ネットも GPU も使わずに確かめます
    python lifelog_pc.py --fake-models --port 47715   モデルを読み込まずに起動して、受け口と見守りの画面を試すとき用
                                       （文字起こしの答えは作り物です。ふだんは使いません）

■ 版 8 で足したもの（文字になって iPhone に入るまでを短くする）
新しい iPhone のアプリが使います（/hello の features に jobwait・draft・timing があるときだけ）。古いアプリはこれまでどおり動きます。
・待ち合わせ: iPhone が区切りを預けるとき（POST /jobs?wait=1）、PC は文字にし終えるまで答えを待たせ、でき上がったら
  その答えをそのまま返します（iPhone が答えを取りに来るのを待たなくてよくなります）。待っているあいだは、つながりが
  切れないよう 15 秒ごとに空白を 1 文字送ります。25 分たってもできないとき・PC を起動し直す・閉じるときは
  「まだです」（pending）と返して閉じます（文字にするのは続けます）。
・「できた」の見えない通知は、待ち合わせで答えを渡せなかった仕事（途中で切れた・待ち合わせでなかった・答えを書いたあと
  10 秒のうちに iPhone が読み終えて閉じたと分からなかった）にだけ送ります。回数の上限は今までと同じです。
・下書き: 文字にするとき、先に速いモデル（Haas-ja・ReazonSpeech）だけで文字にして「下書き」として残し、そのあと今までどおり
  全部のモデルで多数決をします。Haas-ja・ReazonSpeech の文は多数決でもそのまま使うので、同じ音声を 2 回読みません。
  まだのときに GET /jobs/<名前> を見ると、下書きが返ります（iPhone は画面を見ているときだけ「仮」として出します。
  下書きは記録には残しません）。下書きを作れなくても、多数決は続けます。でき上がったら下書きは消します。
・時間: 区切りごとに、受け取った時刻・文字にし始めた時刻・下書きができた時刻・でき上がった時刻を残し、iPhone の時刻
  （録音の始まりと終わり・iPhone に届いた・送り始めた）と合わせて答えの "timing" に入れます。
  見守りの画面の「後で受け取る文字起こし」に、直近 50 件の PC の待ち・作業・下書きまでの時間（中央値・いちばん長い）と、
  区切りごとの待ち・下書きまでの時間、待ち合わせで渡したかが出ます。iPhone で測った区間ごとの時間（時計→iPhone・
  iPhone→PC・PC の待ち・PC の作業・PC→記録・合計の中央値）は「実機の様子」と summary.md に出ます。
・確かめるとき:  LifeLogPC.exe --check-v8（一時のフォルダと作り物のモデルで、待ち合わせ・通知・下書き・時間・新しい順を確かめます）
  起動して試すときは、作り物のモデルで（例）
    python lifelog_pc.py --fake-models --port 47716 --no-auto-update --no-semantic --no-llm
  環境変数 LIFELOG_JOBWAIT_PING（空白を送る間の秒）・LIFELOG_JOBWAIT_LIMIT（待つ長さの上限の秒）で短くでき、
  LIFELOG_FAKE_SECONDS（秒）で作り物の Whisper を遅くできます（下書きが先に出るのを見るため）。
  試すときは、環境変数 LOCALAPPDATA を一時のフォルダにして、ふだんの置き場所と番号 47615 を使わないでください。
  --check-vote・--check-v7-ops・--check-v7-records・--check-v8・--check-v9・--check-v10 は、LOCALAPPDATA を替えなくても、自分で一時のフォルダを
  使います（ふだんの置き場所の記録 log.txt やデータには書きません）。

■ 版 9 で足したもの（職場の会話の印・聞いて直す・この PC の Claude から記録を読む）
PC の版の番号は 8 のままです。古い iPhone のアプリも、これまでどおり動きます。
・職場の会話の印: 新しい iPhone のアプリは、記録（POST /records/<日>）に、職場の会話の始まりの時刻の並び
  （"work"）を足して送ってきます。PC は日ごとに残し、会話を「職場」「職場ではない」「分からない」に分けます。
  古い iPhone から届いた日（"work" が無い日）は「分からない」です。記録の画面の会話の所に「職場」
  「職場かどうか分からない」と出ます（PC の画面では、どれも読めます）。
・聞いて直す: 記録の画面の「聞いて直す」から開きます（見守りの画面の学び直しの所からも入れます）。
    http://<PC の Tailscale 名>:47615/dash/records/review
  自信の低い行（確からしさが 0.45 より低い・モデルの票が食い違う・話し手に「？」）で、PC に音声がある行を、
  新しい日から並べます。▶ で聞いて、違っていれば「文を直す」、そのままで正しければ「合っている」を押します。
  答えると次の行に進み、自動で流します。話し手は「話し手を変える」で、記録に出てくる名前と「自分」から選びます
  （新しい名前は作りません）。文と話し手の直しは、ほかの直しと同じく iPhone に渡します。「合っている」は iPhone には送りません。
  文を直した行と「合っている」行は、PC にある音声から、その行の所（iPhone が材料を作るときと同じ区間）を切り出して、
  学び直しの材料（personal\data）に足します。iPhone があとで同じ行を材料として送ってきても、2 重には入れません
  （文が同じで、長さがほぼ同じなら同じ行とみなします。iPhone が /train-sample に audio（行の音声の名前）と
  offset（行の位置の秒）を付けてくれば、それでも見分けます）。話し手だけを変えた行は、材料にしません。
  見守りの画面の学び直しの所に、材料の数と、あと何個で学び直せるか（300 個から）が出ます。
・この PC の Claude Code から記録を読む（MCP サーバー）: 下の「この PC の Claude から記録に聞く」を見てください。
・確かめるとき:  LifeLogPC.exe --check-v9（一時のフォルダと作り物の記録で、職場の印・聞いて直す・材料を 2 重にしない・
  --exclude-work のときに MCP サーバーから職場の会話が出ないこと・既定では全部返すことを確かめます）

■ 版 10 で足したもの（時計の外の道。決まりは docs/v10-watch-route.md）
PC の版の番号は 10 です。古い iPhone のアプリも、これまでどおり動きます。
・時計の区切りは iPhone を通ると何時間も遅れることがあるので、家の Wi-Fi の外にいる時計も、区切りを PC に直接
  預けられるようにしました。Tailscale Funnel（https://<PC の Tailscale 名> → この PC の中の 127.0.0.1:47617）を通って届きます。
・この受け口は「預けるだけ」です。GET /w/ping と POST /w/jobs だけを受け、見守りの画面・記録・ほかの受け口は全部 404 です。
  この PC の中（127.0.0.1）だけで待つので、家の中の番号や Tailscale の番号から直接は届きません（Funnel を通ってだけ）。
・合言葉は、ふだんの合言葉とは別の「時計の合言葉」です（%LOCALAPPDATA%\LifeLogPC\watch-token.txt。初めて起動したときに作ります）。
  画面にも記録にも出しません。iPhone が GET /watch-route（ふだんの合言葉）で受け取って、時計に渡します。
  作り直すときは、LifeLog PC を止めて watch-token.txt を消してから起動し直し、iPhone で家の PC の設定を開き直します。
・時計の合言葉が 10 分に 10 回違うと、10 分のあいだ、この受け口はだれにも 429 を返します（記録に 1 回書きます）。
・番号は --watch-port で変えられます（0 で使いません）。番号がほかのソフトに使われていれば、時計の外の道は無しで続けます。
・Tailscale Funnel の設定は LifeLog PC は変えません（様子を読むだけ）。持ち主が 1 回だけ、手で次のように打ちます:
    tailscale funnel --bg 47617
  見守りの画面の「時計の外の道」に、受け口・Funnel がオンか・今日預かった区切りの数・断っているかが出ます。
・確かめるとき:  LifeLogPC.exe --check-v10（一時のフォルダと作り物のモデル・作り物の Tailscale の答えで確かめます）

■ この PC の Claude から記録に聞く（MCP サーバー。2026-11-07 本人の了承で登録）
この PC の Claude Code に「先週、母と何を話した？」のように聞けるようにする道具です。読むだけで、記録は変えられません。
音声は返しません。
・2026-11-07 の本人の決定（「情報は全部わたしてよい・どこにも全部よい」）で、職場の会話も含めて全部返します。
  会話の文・見出し・相手の名前は Claude（外のクラウド）に渡ります。
・前のとおり職場の会話を外すときは、--exclude-work を付けて起動します（職場の印が付いた会話と、印が分からない会話を
  返す前に外し、外した数だけを返します。1 日のまとめは、その日に職場の会話も分からない会話も無いときだけ返します）。
・出す道具: list_conversations（日付で会話の一覧）・search_text（言葉で探す）・search_meaning（意味で探す。この PC の
  Ollama の bge-m3 を使い、semantic.db を読むだけ）・conversations_with（人の名前で、その人との会話）・
  get_conversation（1 つの会話の中身）。
・仕事のまとめ（2026-11-10）: search_digest（仕事のまとめの行を言葉で探す）・get_digest（1 日分を見出しごとに読む）。
  search_text・search_meaning も、答えの digest_hits に仕事のまとめの行を別に付けます（include_digest を false にすると付けません。
  hits の形は変わりません）。ドライブの「LifeLog/同期/仕事のまとめ.json」を読むだけで、書きません（場所は config.json の
  "work_digest_file" でも決められます）。職場の話なので --exclude-work のときは出しません。意味で探す（POST /search）は
  "include_digest": true のときだけ、仕事のまとめの行（kind は work-digest・日と見出し・時刻なし）も返します。
・%LOCALAPPDATA%\LifeLogPC には何も書きません。LifeLog PC が動いていても、止まっていても使えます
  （意味で探すだけは、この PC の Ollama が動いているときだけ）。
・登録のしかた（Claude Code。コマンドプロンプトで1行。exe の場所は自分の置いた所に替えます）:
    claude mcp add --scope user lifelog -- "C:\Users\<名前>\Documents\LifeLogPC\LifeLogPC.exe" --mcp
  Python で動かすとき（numpy が要ります）:
    claude mcp add --scope user lifelog -- py -3.12 "<このリポジトリ>\pc\lifelog_mcp.py"
  設定ファイルに書くときは、mcpServers に次を足します（~/.claude.json か、プロジェクトの .mcp.json）:
    "lifelog": {"type": "stdio", "command": "C:\\Users\\<名前>\\Documents\\LifeLogPC\\LifeLogPC.exe", "args": ["--mcp"]}
  ほかに付けられるもの: --home <フォルダ>（記録の置き場所。既定 %LOCALAPPDATA%\LifeLogPC）・
  --ollama-url http://127.0.0.1:11434（この PC の中の Ollama だけ）。
  登録できたかは  claude mcp list  で確かめます。やめるときは  claude mcp remove --scope user lifelog

■ GPU について（NVIDIA のドライバー）
Whisper・kotoba-whisper・Qwen3-ASR を GPU で動かすには、NVIDIA のドライバー 528 以上が要ります。
nvidia-smi で版を見られます。古いと記録（log.txt）に「CUDA driver version is insufficient」と出て、
Whisper と kotoba-whisper は CPU で動きます（遅くなります。Qwen3-ASR は使いません）。
ドライバーは NVIDIA のサイト（https://www.nvidia.com/ja-jp/drivers/）から、自分の GPU に合うものを入れます。

GPU で落ちたときの守り（2026-11-07 に ctranslate2.dll の中で 0xc0000005 で何度も落ちたため）:
・GPU のモデル（Whisper・kotoba-whisper・あなた向け・Qwen3-ASR）は、1度に1つだけ動かします（区間ごとに順番。
  読み込む・下ろすときも）。CPU のモデル（Haas-ja・ReazonSpeech）は待ちません。whisper と kotoba が同時に動かない分、
  1つの区切りにかかる時間は、2つの時間を足したくらいになります。
・後で受け取る文字起こしで、同じ区切りを文字にしている最中に 2 回止まったら、その区切りは GPU のモデルを使わずに
  CPU のモデルだけで文字にします。3 回止まったら、その区切りは失敗にして飛ばします。
・GPU のモデルで文字にしている間だけ %LOCALAPPDATA%\LifeLogPC\gpu-busy.json を置きます。起動したときに残っていれば
  「GPU を使っている最中に止まった」と数え（gpu-crashes.json）、6 時間に 2 回あれば、その起動のあいだは GPU のモデルを
  使わず CPU のモデルだけで文字にします（記録と見守りの画面に出ます）。gpu-crashes.json を消して起動し直すと、また GPU を使います。
・確かめるとき:  LifeLogPC.exe --check-crash（一時のフォルダと作り物のモデルで。GPU は使いません。--check-v8 にも入っています）

GPU のメモリーに余裕を作る（2026-11-07。8GB の GPU に large-v3 と kotoba を float16 で載せると、空きが約 600MB だったため）:
・合計 10GB 未満の GPU では、Whisper（large-v3・kotoba・あなた向け）の重みを 8 ビットにして載せます（int8_float16。
  重みが約半分になり、large-v3 で約 1.5GB 減ります）。config.json の "whisper_compute" で変えられます:
  "auto"（既定）・"float16"（前と同じ）・"int8_float16"・"int8"（このモデルでは int8_float16 と同じになります）。
・GPU に文字起こしのモデルが載っているあいだ（読み込み中も）は、この PC の Ollama（/llm の言語モデルと、意味で探すの bge-m3。
  MCP サーバーの意味で探すも）を CPU だけで動かします（options に num_gpu 0 を付けて頼みます。答えは遅くなります）。
  GPU に載せる前に、LifeLog が使う Ollama のモデルが GPU にいれば下ろします（ほかのソフトのモデルには触りません）。
  夜の割り当てで下ろしているあいだは、今までどおり GPU を使います。config.json の "ollama_gpu" で変えられます:
  "auto"（既定）・"always"（いつも GPU を使ってよい。前と同じ）・"never"（いつも CPU だけ）。
・GPU に載せる前と後の空きを、記録（log.txt）に「GPU のメモリー（whisper を載せる前）: 空き … MB」のように書きます。
  動かすのに要る分と、残しておく分（既定 1024MB。config.json の "gpu_free_min_mb"）が無いときは、Whisper は CPU
  （large-v3-turbo）で動かし、kotoba・あなた向けは使わずに、空きができたら GPU の時間割が載せ直します。
・確かめるとき:  LifeLogPC.exe --check-gpu（一時のフォルダと作り物のモデル・作り物の Ollama で。GPU も Ollama も使いません。
  --check-v8 にも入っています）

■ Qwen3-ASR も使う（NVIDIA の GPU が要ります。使わなくても困りません）
Qwen3-ASR（Alibaba の Qwen、Apache License 2.0、2026 年 1 月公開）の 0.6B を、多数決の5票目「qwen」として加えます。
torch などの大きな部品が要るので、LifeLogPC.exe には入っていません。Python で動かします。
1. Python 3.12 を入れます（https://www.python.org/）。
2. コマンドプロンプトでこのフォルダに移り、Qwen3-ASR 用の置き場（venv）を作って、部品を入れます（合わせて 5GB ほど）。
   GPU 用の torch を先に入れます。requirements.txt はそのまま使いません
   （qwen-asr が使う transformers は huggingface_hub 1.0 より前の版が要り、requirements.txt の版とぶつかるため）。
    python -m venv qwen-env
    qwen-env\Scripts\activate
    pip install torch --index-url https://download.pytorch.org/whl/cu128
    pip install qwen-asr sherpa-onnx==2.0.1 av==19.0.2 faster-whisper==1.2.1 ctranslate2==4.8.5 pykakasi==2.3.0
3. 同じコマンドプロンプトで、--qwen を付けて起動します（exe ではなく Python で）。
    python lifelog_pc.py --qwen
   - 初回だけ、モデル（Qwen/Qwen3-ASR-0.6B、約2GB）を取ってきます（置き場所は下の qwen のフォルダ）。
   - 大きい 1.7B を使うときは  python lifelog_pc.py --qwen --qwen-model Qwen/Qwen3-ASR-1.7B
   - 毎回 --qwen を付ける代わりに、config.json に "qwen": true を足しても同じです。
GPU が使えない・部品が入っていないときは、記録に理由を1行書いて、Qwen3-ASR 抜きで動きます。
iPhone の答え合わせで学ぶ重みの名前は「qwen」です。

■ この PC の言語モデル（Ollama、使わなくても困りません）
iPhone の「仕事の文脈」の文を、クラウドではなくこの PC の中の言語モデルに作ってもらえます。
iPhone の設定でこれをオンにしたときだけ使います（オフのままなら何も送りません）。
LifeLog PC は、この PC の中で動く Ollama（http://127.0.0.1:11434）にだけ取り次ぎます。ほかの所には送りません。
1. Ollama を入れます: https://ollama.com/download/windows
2. コマンドプロンプトで、モデルを取ってきます（約5.2GB）。
    ollama pull qwen3:8b
3. LifeLog PC を起動すると、Ollama とモデルがあるかを確かめます（あとから入れても、1分ほどで気づきます）。
別のモデルにするときは  LifeLogPC.exe --llm-model モデルの名前（config.json の "llm_model" でも同じ）。
使わないときは  LifeLogPC.exe --no-llm。
GPU が使えないと CPU で動くので、答えが返るまで数十秒〜数分かかることがあります。

■ Claude（Anthropic の API。2026-11-13。鍵はこの PC にだけ置きます）
アプリと母艦が、家の PC を通して Claude に頼めるようにしました（中身は claude.py）。鍵が無ければ、今までどおり動きます。
1. 鍵の置き方（どちらか1つ）:
   ・%LOCALAPPDATA%\LifeLogPC\claude-key.txt に、鍵を1行だけ書いて保存します（メモ帳でよい。最初の空でない1行を使います）。
   ・または、環境変数 ANTHROPIC_API_KEY に入れます（こちらがあれば、こちらを先に使います）。
   鍵は記録（log.txt）・答え・エラー・/hello・見守りの画面のどこにも出しません。リポジトリ・アプリ・チャットにも書かないでください。
   置いたら LifeLog PC を起動し直さなくても、次に頼んだときから使います。
2. 上限（1か月に約 100 ドル）:
   ・使った額は %LOCALAPPDATA%\LifeLogPC\claude-usage.jsonl に、1回ごとに1行ずつ書きます（会話の文は書きません。数と値段だけ）。
     母艦（D:\Lifelog の scripts）も同じファイルに書くので、合わせて数えます。
   ・頼む前に今月の合計を見て、上限に届いていたら頼みません（アプリには「今月の上限に達しました」と返ります）。
     1回分だけ少し越えることはあります。月が替わると、また使えます。
   ・上限を変えるときは、%LOCALAPPDATA%\LifeLogPC\claude-config.json を作って、次のように書きます（無ければ 100 ドル）:
       {"monthly_usd": 100, "work": true, "judge": true, "judge_daily": 400}
     monthly_usd が上限（ドル）。起動し直さなくても、次に頼んだときから効きます。
3. 送るもの:
   ・アプリや母艦が頼んだ文（会話の文・題・人の名前を含みます）を、そのまま Claude（外のクラウド）に送ります。
   ・職場の会話も送ります（2026-11-13 の本人の決定「職場もみせてよい」）。やめるときは claude-config.json の "work" を false に
     します（職場の印のある頼み・職場か分からない頼みは 403 で断ります）。アプリの「職場の会話は端末内で」の設定はそのままです。
4. 受け口（どれも iPhone の合言葉が要ります。時計の外の道からは届きません）:
   ・POST /claude {"system", "prompt", "json", "max_tokens", "tier", "purpose", "work"}
     → {"text", "model", "usd", "month_usd", "cap_usd"}
     tier は light（claude-haiku-5-5）・standard（claude-sonnet-5-5）・deep（claude-opus-5-5）。max_tokens は 8192 まで（既定 1024）。
     上限 → 402・鍵が無い → 503・断られた → 422・職場を送らない設定 → 403。work を省くと「職場かもしれない」として扱います。
   ・GET /claude/usage → {"available", "month", "month_usd", "cap_usd", "calls", "by_purpose", "by_who"}（鍵は返しません）
   ・/hello の features に、鍵があって今月の上限の前なら "claude" が付きます。
5. 割れた行の審判（精6）:
   後で受け取る文字起こしで、モデルの書いた文が大きく食い違った行（記録の「食い違いの大きい行」）だけを、Claude（haiku）に
   見てもらい、候補の中から番号で1つ選んでもらいます。Claude は新しい文を書きません。答えの番号がおかしければ、
   多数決の文のままです。替えた行には "judge"（前の文 "before"）を付け、前の文は候補にも残します（答え合わせで比べられます）。
   1日に頼む回数は 400 回まで（"judge_daily"）。やめるときは "judge": false。記録には数だけを書きます
   （「Claude の審判: 食い違いの大きい行 N のうち M 行を見て、K 行を替えました」）。
   iPhone が /jobs に work=0|1 を付けると、職場かどうかが分かります（付けなければ「分からない」）。
6. 自動の材料（精7・仮。いまは使いません）:
   全部のモデル（3つ以上、どれも黙っていない）がほぼ同じ文を書いた 2 秒以上の行を、あなた向けのモデルの材料に足します。
   config.json（claude-config.json ではなく、いつもの config.json）に "auto_samples": true を足したときだけです。
   しきい値は仮です: どのモデルの組も近さ 0.95 以上・1日 30 個まで・自動の材料は全部で 1500 個まで。
   材料には "source": {"origin": "pc-auto", "auto": true} の印を付けるので、あとで外せます。
   学び直しの試験（誤りの割合を測る分）には、自動の材料は使いません（正しい文が人の確かめたものではないため）。
7. 母艦からの写し（中身は appfeeds.py。無ければ {"available": false}）:
   ・GET /proposals … 母艦の state\proposals_for_app.json（母艦からの提案。期限の過ぎたものは返しません）
   ・POST /proposals/answer {"id", "answer": "accept"|"later"|"never"} … 母艦の inbox\proposal_answers.jsonl に1行足します
   ・GET /plaud-fill … 母艦の state\plaud_fill_for_app.json（アプリに行の無い時間の PLAUD の文。見せるだけで、記録には混ぜません）
   ・GET /speaker-doubts … 母艦の state\speaker_doubts_for_app.json（話し手が違うかもしれない行。名前は自動で替えません）
   features は "proposals"・"plaudfill"・"spkdoubt"。文の中身は log.txt に書きません。
8. 施策 1〜21 のアプリ側の口（2026-11-13。中身は appfeeds.py。番号は母艦の docs\system-proposal-2026-11-13.md）:
   読むだけ（母艦の state を確かめて返す。無ければ {"available": false, "reason"}。おかしな行は落とし、長さを切ります）:
   ・GET /weekly … state\weekly_for_app.json（週のふり返り 3 つ・見立ての台帳・出したものの使われ方の数）。features "weekly"
   ・GET /prep … state\prep_for_app.json（これから 36 時間の予定の「会う前の一枚」）。features "prep"
   ・GET /brief-compare … state\brief_compare_for_app.json（同じ日の朝のまとめを Codex と Claude で。7 日まで）。features "briefcmp"
   ・GET /accuracy … state\accuracy_for_app.json（精度の通信簿。週ごと 12 週まで。値の無い所は null）。features "accuracy"
   ・GET /unused … state\unused_features_for_app.json（あまり開かれていない画面。月 1 回）。features "unused"
   1行足すだけ（母艦の inbox の jsonl。/proposals/answer と同じ合言葉・同じ大きさの決まり。おかしな中身は 400）:
   ・POST /feedback {"kind", "id", "value", "day"} → inbox\app_feedback.jsonl（"at" はこの PC が付けます）。features "feedback"
     kind と value の組: today_three: done|skipped／brief: read／weekly: useful|not_useful／prep: useful|not_useful／
     brief_compare: codex|claude／night_review: kept|dropped／same_person: merged|different／promise: added|ignored／bulk: ok
   ・POST /mood {"day", "at", "mood", "energy", "grip", "note"?} → inbox\mood.jsonl（夜の 10 秒。3 つとも 1〜5 の整数。
     energy は 1 がいちばん疲れている。note は 200 文字まで）。features "mood"
   ・POST /app-usage {"at", "app", "event": "open"|"close"|"focus_on"|"focus_off"} → inbox\app_usage.jsonl。features "appusage"
     iPhone のショートカットの個人用オートメーション（「アプリを開いたとき」など）から届きます。スクリーンタイムと
     Safari の履歴は、ほかのアプリからは読めない（Apple の決まり）ので、この形にしました。
   log.txt には種類だけを書きます（id・アプリの名前・気分の値・覚え書きは書きません）。
・確かめるとき:  LifeLogPC.exe --check-v11（一時のフォルダと作り物の Claude で。本物の鍵もネットも使いません。
  8. の口は feedschecks.py がここから確かめます）

■ 精度の記録・同じ人かも・夜の読み直し（2026-11-13。施策 9・10・11・14。中身は quality.py・judgecheck.py・
  sameperson.py・nightreview.py。測った数とやり方は docs/s2-accuracy-2026-11-13.md）
1. 品質の記録: %LOCALAPPDATA%\LifeLogPC\quality-daily.json（母艦の「精度の通信簿」が読みます）
     {"version": 1, "days": {"YYYY-MM-DD": {"judge_calls", "judge_agree_plaud", "night_review_items", "same_person_groups",
      "promise_alerts"}}}
   いつも読んでから、自分の項目だけを書き替えます（ほかの項目は残します）。60 日より古い日は消します。
2. 夜の流れ（01:00〜05:00 に1回。昨日の分）:
   ・judge_calls … 帳簿の asr-judge の回数。judge_agree_plaud … 審判が文を替えた行のうち、PLAUD の公式の文字起こしに
     多数決の文より近かった割合（judgecheck.py。PLAUD が遅れて届くので 3 日前まで測り直します。測れなければ null）
   ・同じ人かも → same_person_groups。夜の読み直し → night_review_items。済んだ日は quality-night.json に覚えます。
3. 割れた行の審判の1日の回数（施策 11）: claude-config.json の "judge_daily"（既定 400 のまま）。
   2026-11-13 に測ったら、審判が PLAUD に近かったのは 23 行・多数決のほうが近かったのは 20 行（53%）で、
   はっきり良いとは言えないので、2000 には上げていません。上げるときは {"judge_daily": 2000} と書きます。
4. 同じ人かも（施策 10）: 同じ日の名前の無い「人物N」を、行の音声（audio・jobs に残っているもの）の声の特徴
   （/speakers と同じ CAM++。その日の平均を引いてから比べる）で組にします。名前のある人・自分は入れません。
   同じ区切りに出た2つは組にしません。まとめはしません（アプリで本人が「同じ人」を押したときだけ、アプリがまとめます）。
   置き場所: same-person\<日>.json（7 日で消します）。
   ・GET /same-person（features の "sameperson"。?refresh=1 で今日と昨日を裏で作り直します）→
       {"available": true, "generated_at", "refreshing"?: true, "days": [{"day", "groups": [{"id", "score",
        "people": [{"id": "12", "name": "人物12", "lines", "seconds",
                    "samples": [{"time", "text"（40 字まで）, "audio", "start", "end"}]（3 つまで）}]（2〜4 人）}]（20 組まで）}]（3 日まで）}
   2026-11-15（強化案 56。voices.py。測り方と数は docs/s7-voices-2026-11-15.md）: 記録の行（話し手の 1 回ぶん）ごとの
   声の特徴を voices\<日>.npz に置きます（音声の名前と区間・声の特徴の数の並びだけ。文・名前は入れません。21 日で消します。
   この PC の外には出しません）。夜（01:00〜）に直近 7 日を 30 分まで、00:00〜01:00 と 08:30〜18:00 は 30 分に 1 回、
   今日と昨日の新しい行だけを測ります。日の平均を引いてから、別の日の人物N どうし（0.65 以上）と、名前のある人
   （0.65 以上・2 番目との差 0.10 以上・1 人に 3 件まで）に照らし、same-person\voices.json に置きます。
   GET /same-person に省ける "across"（日をまたぐ組。上の組の形に "days" を足したもの）と
   "maybe"（[{"id", "day", "score", "margin", "person": 上の人の形, "named": {"id", "name"}}]）が足されます。
   名前は付けません・まとめません（アプリで本人が押したときだけ）。
5. 夜の読み直し（施策 9）: 昨日の記録の文（職場の会話も）を区切って Claude（standard）に読ませ、聞き間違いと話し手の
   取り違えの候補を作ります。答えは入力の文に当てて確かめ、当たらないものは捨てます。記録は変えません。
   1日の上限は claude-config.json の "night_review_usd"（既定 0.5 ドル）。やめるときは "night_review": false。
   置き場所: night-review\<日>.json（14 日で消します）。
   ・GET /night-review（features の "nightreview"）→ {"available": true, "generated_at",
       "items": [{"id", "day", "line_time", "wrong", "guess", "reason"}]}（アプリの「聞き間違いかも」に入ります）
   ・話し手の取り違えは GET /speaker-doubts に why "night" で混ぜます（アプリの表示は「夜の読み直しから」）。
6. まとめて OK の印（施策 14）: GET /self-candidates・/speaker-doubts・/vocab の各行に、母艦が付けた省ける
   "sure": true と "sure_why"（60 字まで）をそのまま通します（true でなければ付けません）。
・確かめるとき:  python pc/v12checks.py（一時のフォルダと作り物の Claude・作り物の声で。本物の鍵もネットも使いません）

■ あなた向けのモデルを作る（NVIDIA の GPU と、300 個以上の材料が要ります）
iPhone で直した文が 300 個以上たまったら、あなたの声と言い回しに合わせて Whisper（kotoba-whisper v2.0）を学び直せます。
NVIDIA の GPU が要ります（メモリ 8GB 以上がおすすめ。CPU だけの PC では学び直しません）。
NVIDIA のドライバーが古いと GPU を使えません。nvidia-smi で版を見て、528 より古ければ先に更新してください。
1. Python 3.12 を入れます（https://www.python.org/）。
2. コマンドプロンプトで、学び直す部品を入れます（LifeLog PC の exe には入っていません。合わせて 5GB ほど）。
    pip install torch --index-url https://download.pytorch.org/whl/cu124
    pip install transformers peft accelerate ctranslate2 numpy faster-whisper
3. LifeLog PC を止めてから（GPU のメモリを空けるため）、このフォルダの train_personal.py を動かします。
    python train_personal.py
   - 初回は元のモデル（約1.5GB）を取ってきます。学び直しは GPU によって 30 分〜数時間かかります。
   - 材料の 1 割は試験用に取り分けて、学び直す前と後で誤りの割合（CER）を比べます。
     良くなったときだけ、あなた向けのモデルを入れ替えます（前のものは personal\model.old に1つ残します）。
   - GPU が無い・材料が 300 より少ないときは、理由を表示して何もせずに終わります。
   - GPU のメモリが足りないと出たら  python train_personal.py --batch 2
4. LifeLog PC を起動し直すと、「あなた向け Whisper」が加わります（起動の画面の「使うモデル」に出ます）。
使わないときは  LifeLogPC.exe --engines haas,reazon,whisper,kotoba
版 7 からは、上の「自動の学び直し」で、毎週 LifeLog PC が自分で学び直します（部品も自分で用意します）。手で動かすこともできます。

■ 置き場所
モデル・合言葉・記録: %LOCALAPPDATA%\LifeLogPC（model・reazon・whisper・cuda・speaker・tagging・enhance・vad・qwen のフォルダ）
預かった区切り・意味で探すための行・取ってきた新しい版: %LOCALAPPDATA%\LifeLogPC（jobs のフォルダ・semantic.db・update のフォルダ）
iPhone から届いた記録・PC で直した分・残した音声: %LOCALAPPDATA%\LifeLogPC（records のフォルダ・edits.db・audio のフォルダ）
版 9: 「聞いて直す」で「合っている」と答えた行は edits.db の reviews に、作った材料は personal\data に置きます
あなた向けのモデルの材料とモデル: %LOCALAPPDATA%\LifeLogPC\personal（data に声と文、model に作ったモデル）
版 7: 実機の様子 diag（summary.md も）・TestFlight の報告 feedback・通知の鍵と様子 apns・App Store Connect のキー asc・
      学び直しの部品 train（どれも %LOCALAPPDATA%\LifeLogPC の下）
2026-11-13: Claude の鍵 claude-key.txt・設定 claude-config.json・使った額の帳簿 claude-usage.jsonl（どれも %LOCALAPPDATA%\LifeLogPC）
2026-11-13: 品質の記録 quality-daily.json・夜の流れの済み quality-night.json・same-person と night-review のフォルダ
2026-11-15: 区間ごとの声の特徴 voices\<日>.npz（強化案 56。21 日で消します）
合言葉を変えたいときは、そこにある config.json を消して起動し直します（iPhone 側も入れ直してください）。

■ モデル
Haas-ja-v1.0（Third Intelligence、Apache License 2.0）の ONNX 版
oboroge0/Haas-ja-v1.0-onnx（非公式の変換、Apache License 2.0）を sherpa-onnx で動かしています。
ReazonSpeech k2 v2（Reazon Research、Apache License 2.0）を sherpa-onnx で動かしています。
Whisper large-v3 / large-v3-turbo（OpenAI、MIT License）の CTranslate2 版を faster-whisper で動かしています。
話し手の声の特徴: 3D-Speaker の CAM++（3dspeaker_speech_campplus_sv_en_voxceleb_16k、Apache License 2.0）。
  （版 4 までは ERes2Net の 3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k）
周りの音: sherpa-onnx-zipformer-small-audio-tagging-2024-04-15（Apache License 2.0）。
雑音を除く: GTCRN（gtcrn_simple.onnx、MIT License）を sherpa-onnx で動かしています。
声のある所を探す: Silero VAD（silero_vad.onnx、MIT License）を sherpa-onnx で動かしています。
Qwen3-ASR（使う設定のときだけ）: Qwen/Qwen3-ASR-0.6B（Apache License 2.0）を公式の qwen-asr の部品で動かしています。
この PC の言語モデル（使う設定のときだけ）: Ollama の qwen3:8b（Apache License 2.0）。
意味で探す（Ollama があるときだけ）: Ollama の bge-m3（BAAI、MIT License）。
あなた向けのモデルの元: kotoba-whisper v2.0（kotoba-tech/kotoba-whisper-v2.0、MIT License）。

■ 母艦のやること（2026-11-09）
iPhone のタスクの「母艦のやること」に、母艦（D:\Lifelog）の TODO を出すための受け口です（中身は mothership.py）。
・GET /todo … 母艦の state\todo_for_app.json をそのまま返します（無ければ {"available": false}）。
・POST /todo/done … iPhone で済みにしたものを、母艦の inbox\app-todo-done\<日>.jsonl に1行足します。
  TODO.md を書き換えるのは母艦だけです（15分ごとに「アプリで済み」として反映します）。
・GET /card … ドライブの「マイドライブ\LifeLog\カード利用\card-mail.json」の支払いを返します（2026-11-09）。
  このファイルは、Google の Apps Script が PayPay カードの利用速報メールから作ります（docs/card-payments.md）。
  別の場所に置くときは config.json に "card_mail_file"。
・GET /vocab … 母艦の state\vocab_for_app.json（母艦が今までの記録から作った辞書）を返します（2026-11-10。無ければ {"available": false}）。
  iPhone の「言葉の登録」に「母艦の辞書からの候補」として出すためのものです。300 個まで。
  iPhone は見せるだけで、押した言葉だけを登録します（この PC からは何も登録しません）。
・どちらも iPhone の合言葉が要ります。時計の外の道（Funnel）からは届きません。やることの文は log.txt に書きません。
・母艦の場所は config.json の "lifelog_home"（無ければ D:\Lifelog）。

■ 会話のあとの約束・記録に質問するを母艦まで（2026-11-13。施策 13・15。中身は promises.py・askmother.py）
・会話の最後の行から 10 分たったら、その会話（iPhone が送った記録。3 時間より前に終わったものは見ない）から
  約束・頼まれごとだけを Claude の軽いモデルで拾い、iPhone に目に見える通知を送ります（通知の種類 promise）。
  - 拾うのは、その行の言葉そのまま（quote）がある約束だけです（無いものは捨てます）。前に拾ったもの・
    ドライブの「同期\頼まれごと帳.json」（別の場所なら config.json の "task_book_file"）・その日のまとめのやることと
    よく似たものは足しません。1 日に Claude に頼むのは 80 回まで。
  - 通知は 1 日 6 回・10 分に 1 回まで、1 時間で届けるのをあきらめます（apns.py の LIMITS・EXPIRE の "promise"）。
    上限で送れなかったものは、1 時間以内なら次にまとめて送ります。届かなくても GET /promises-now（36 時間ぶん）で
    アプリを開いたときに見られます。
  - アプリの設定（POST /promises/settings: 知らせる・Claude を使う・職場の会話も Claude で・通知に中身を出さない）を守ります。
    アプリから一度も設定が届いていなければ何もしません。状態は %LOCALAPPDATA%\LifeLogPC\promises\state.json。
  - 送れた通知の数を %LOCALAPPDATA%\LifeLogPC\quality-daily.json の days.<日>.promise_alerts に足します（ほかの項目は消しません）。
・POST /ask-mothership {"question": "…"} … 母艦の scripts\Search-Lifelog.py（LINE・PLAUD・予定・写真・体調・場所・
  1日のまとめ・仕事のまとめ）と reports\spending（お金）から探して、Claude が出どころつきで答えます（60 秒まで）。
  母艦のスクリプトは Python 3.11（%USERPROFILE%\AppData\Local\Programs\Python\Python311\python.exe。
  別の場所なら config.json の "mothership_python"）で動かします。
・どれも log.txt には数だけを書きます（会話の文・質問・答え・人の名前は書きません）。
・確かめ: python v12checks_promises.py（一時フォルダと作り物の Claude・検索・通知の相手で。本物の鍵もネットも使いません）

■ 1日の流れを1つに・PayPay の写真・位置を当日のうちに・反映の見張り（2026-11-14。強化案 25・28・30・32・34。中身は oneline.py）
・GET /timeline?day=YYYY-MM-DD … 母艦の digests\timeline\YYYY-MM-DD.json（母艦が年表の md の隣に作る）。直近 14 日だけ。
  無い・読めない・形が違うときは {"available": false, "reason"}。行は time（HH:MM）・end・lane（会話・位置・決済・LINE・予定・
  写真・閲覧・PC・iPhone・体調・天気・注文）・text（80 文字まで）・amount（円の整数か null）・place（40 文字まで）。features "timeline"
・POST /pay/paypay-shot … PayPay のアプリの取引履歴のスクリーンショット 1 枚（JPEG・4MB まで）。Claude の軽いモデル（画像つき。
  claude.py の上限と帳簿を通る。purpose "paypay-shot"）で読み、{"rows": [{"time", "day", "shop", "amount", "method"}]} を返します。
  画像はどこにも保存しません。PayPay の画面でなければ 422。features "paypayshot"（Claude が使えるときだけ）
・POST /pay/paypay-rows {"rows": [...]} … 本人が iPhone で「取り込む」を押した行だけ → 母艦の inbox\paypay_shots.jsonl に
  1 行ずつ（"at" 付き。同じ行は 2 回足しません）。features "paypayrows"
・POST /location/stays {"stays": [{"start", "end"|null, "lat", "lon", "name"|null, "kind"|null}]} … 母艦の
  inbox\location_live.jsonl（同じ start は 1 行。閉じた滞在が届いたら置き換えます）。features "livestays"
・GET /reflection … 母艦の state\reflection.json（要素 × 反映先の「最後に反映された日」）を
  {"destinations": [...], "elements": [{"element", "cells": [日|null]}], "today"} にして返します。features "reflection"
・提案の kind に "profile"（本人の台帳の候補。action は none・根拠のあるものだけ）を足しました（appfeeds.py）。
・どれも log.txt には数だけを書きます（店の名前・金額・場所の名前・座標・画像は書きません）。
・確かめ: python v13checks_oneline.py（一時フォルダと作り物の Claude で）

■ 施策の検品表・Claude の費用・正しさの抜き取り（2026-11-15。強化案 36・37・41・49。中身は settle.py・claude.py・appfeeds.py）
・claude-config.json に省ける 2 つ（母艦の scripts\claude_call.py も同じ決まり）:
    {"monthly_usd": 100, "work": true, "daily_caps": {"misheard": 0.5}, "stopped": ["asr-judge"]}
  stopped にある用途（purpose）は Claude に頼みません。daily_caps は、その日（この PC の日付）のその用途の帳簿の合計が
  上限に届いたら頼みません（前方一致のうち一番長いもの）。どちらも 409 {"error", "purpose_off": "stopped"|"daily_cap"}。
  アプリはその用途だけを今までの作り方に戻し、ほかの用途は Claude のまま。割れた行の審判（asr-judge）も同じ決まりで止まります。
・GET /costs … {"available", "month", "month_usd", "projected_usd"（今月のここまでを過ぎた日数で割り、月の日数を掛けた見込み）,
  "monthly_usd", "today": [{"purpose", "usd", "cap", "stopped"}], "month_by_purpose": [{"purpose", "usd", "calls"}]}。
  帳簿（claude-usage.jsonl。母艦の分も入る）から。features "costs"
・GET /rollout … 母艦の state\rollout_for_app.json（入れた施策の様子。status は live・unused・not_started・broken・
  retire_candidate）。features "rollout"
・GET /canonical?day=YYYY-MM-DD … 母艦の digests\canonical\YYYY-MM-DD.json（1日の正本。PLAUD の文にアプリの話し手と時刻を
  重ねたもの。2026-11-15・強化案 57・canonical.py）。直近 14 日だけ。形を確かめ、おかしな行は落とします。features "canonical"
・GET /checks … 母艦の state\checks_for_app.json（正しさの抜き取り。7 つまで）。答えは POST /feedback の kind "check"・
  value right・wrong・unsure。features "checks"
・提案の kind に "wish"（欲しい物）。精度の通信簿の週に省ける "check_right"（合っていた割合）。
・どれも log.txt には数だけを書きます（施策の名前・主張の文は書きません）。
・確かめ: python v14checks_settle.py（一時フォルダと作り物の Claude で）

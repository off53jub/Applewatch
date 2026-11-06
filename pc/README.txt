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
  1つずつ、来た順に文字にします。PC を起動し直しても、預かったものは続きから文字にします。
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

■ GPU について（NVIDIA のドライバー）
Whisper・kotoba-whisper・Qwen3-ASR を GPU で動かすには、NVIDIA のドライバー 528 以上が要ります。
nvidia-smi で版を見られます。古いと記録（log.txt）に「CUDA driver version is insufficient」と出て、
Whisper と kotoba-whisper は CPU で動きます（遅くなります。Qwen3-ASR は使いません）。
ドライバーは NVIDIA のサイト（https://www.nvidia.com/ja-jp/drivers/）から、自分の GPU に合うものを入れます。

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

■ 置き場所
モデル・合言葉・記録: %LOCALAPPDATA%\LifeLogPC（model・reazon・whisper・cuda・speaker・tagging・enhance・vad・qwen のフォルダ）
預かった区切り・意味で探すための行・取ってきた新しい版: %LOCALAPPDATA%\LifeLogPC（jobs のフォルダ・semantic.db・update のフォルダ）
iPhone から届いた記録・PC で直した分・残した音声: %LOCALAPPDATA%\LifeLogPC（records のフォルダ・edits.db・audio のフォルダ）
あなた向けのモデルの材料とモデル: %LOCALAPPDATA%\LifeLogPC\personal（data に声と文、model に作ったモデル）
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

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
  3D-Speaker の ERes2Net（Apache License 2.0、約40MB）を使います。
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
モデル・合言葉・記録: %LOCALAPPDATA%\LifeLogPC（model・reazon・whisper・cuda・speaker・tagging・enhance のフォルダ）
あなた向けのモデルの材料とモデル: %LOCALAPPDATA%\LifeLogPC\personal（data に声と文、model に作ったモデル）
合言葉を変えたいときは、そこにある config.json を消して起動し直します（iPhone 側も入れ直してください）。

■ モデル
Haas-ja-v1.0（Third Intelligence、Apache License 2.0）の ONNX 版
oboroge0/Haas-ja-v1.0-onnx（非公式の変換、Apache License 2.0）を sherpa-onnx で動かしています。
ReazonSpeech k2 v2（Reazon Research、Apache License 2.0）を sherpa-onnx で動かしています。
Whisper large-v3 / large-v3-turbo（OpenAI、MIT License）の CTranslate2 版を faster-whisper で動かしています。
話し手の声の特徴: 3D-Speaker の ERes2Net（3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k、Apache License 2.0）。
周りの音: sherpa-onnx-zipformer-small-audio-tagging-2024-04-15（Apache License 2.0）。
雑音を除く: GTCRN（gtcrn_simple.onnx、MIT License）を sherpa-onnx で動かしています。
あなた向けのモデルの元: kotoba-whisper v2.0（kotoba-tech/kotoba-whisper-v2.0、MIT License）。

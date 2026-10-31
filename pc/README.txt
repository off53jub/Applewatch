LifeLog PC — 家の PC で Haas-ja を動かして、iPhone の録音を文字にする
=====================================================================

■ はじめて使うとき
1. このフォルダごと、好きな場所（例: ドキュメント\LifeLogPC）に置きます。
2. LifeLogPC.exe をダブルクリックします。
   - 初回だけ、Haas-ja のモデル（約2.4GB）をダウンロードします。
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
音声を文字にして、かかった時間を表示します。

■ 置き場所
モデル・合言葉・記録: %LOCALAPPDATA%\LifeLogPC
合言葉を変えたいときは、そこにある config.json を消して起動し直します（iPhone 側も入れ直してください）。

■ モデル
Haas-ja-v1.0（Third Intelligence、Apache License 2.0）の ONNX 版
oboroge0/Haas-ja-v1.0-onnx（非公式の変換、Apache License 2.0）を sherpa-onnx で動かしています。

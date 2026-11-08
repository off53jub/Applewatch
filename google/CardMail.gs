/**
 * LifeLog: PayPay カードの利用速報メール → ドライブの「LifeLog/カード利用/card-mail.json」（2026-11-09）
 *
 * 自分の Google アカウントの Apps Script で動かす。15分ごとに Gmail の利用速報を読み、
 * 「日時・金額・払った先・カードの名前」だけを JSON に書く（カードの番号やメールの本文は残さない）。
 * 家の LifeLog PC がドライブ（Google ドライブ for desktop）からこのファイルを読み、iPhone に渡す（GET /card）。
 * メールをどこかへ送ることはしない。
 *
 * 使い方は docs/card-payments.md。
 *   1. setup を一度実行する（許可を求められる。過去 400 日分を読み、15分ごとの実行を登録する）
 *   2. checkFormat で、メールが読めているかを確かめられる（結果は「実行ログ」に出る）
 */

/** 利用速報の送り主として受け付けるドメイン（件名をまねた詐欺メールを読まないため） */
var SENDERS = ['paypay-card.co.jp'];
var SUBJECT = '利用速報';
var FOLDER = 'カード利用';
var FILE = 'card-mail.json';
/** 残す長さ（日） */
var KEEP_DAYS = 400;

function setup() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'run') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('run').timeBased().everyMinutes(15).create();
  collect_(KEEP_DAYS);
}

/** 15分ごと（ここ14日分を読み直して足す） */
function run() {
  collect_(14);
}

/** メールが読めているか（直近5通の、送り主のドメイン・読めた中身を実行ログに出す） */
function checkFormat() {
  var threads = GmailApp.search('subject:' + SUBJECT + ' newer_than:60d', 0, 5);
  if (threads.length === 0) Logger.log('件名に「' + SUBJECT + '」のあるメールが 60 日分ありません');
  threads.forEach(function (thread) {
    thread.getMessages().forEach(function (m) {
      var domain = senderDomain_(m.getFrom());
      var p = parse_(m.getSubject(), m.getPlainBody() || '', m.getDate());
      Logger.log('送り主: ' + domain + (allowed_(domain) ? '（受け付ける）' : '（受け付けない）') +
                 ' / ' + (p ? JSON.stringify(p) : '読めませんでした'));
    });
  });
}

function collect_(days) {
  var found = {};
  var unreadable = 0;
  for (var start = 0; start < 2000; start += 100) {
    var threads = GmailApp.search('subject:' + SUBJECT + ' newer_than:' + days + 'd', start, 100);
    threads.forEach(function (thread) {
      thread.getMessages().forEach(function (m) {
        if (!allowed_(senderDomain_(m.getFrom()))) return;
        var p = parse_(m.getSubject(), m.getPlainBody() || '', m.getDate());
        if (!p) { unreadable++; return; }
        p.id = m.getId();
        found[p.id] = p;
      });
    });
    if (threads.length < 100) break;
  }
  var file = file_();
  var old = [];
  try {
    old = JSON.parse(file.getBlob().getDataAsString('UTF-8')).items || [];
  } catch (e) {
    old = [];
  }
  var limit = new Date(Date.now() - KEEP_DAYS * 86400000).toISOString();
  old.forEach(function (item) {
    if (item && item.id && !found[item.id] && new Date(item.time).toISOString() >= limit) found[item.id] = item;
  });
  var items = Object.keys(found).map(function (k) { return found[k]; });
  items.sort(function (a, b) { return a.time < b.time ? -1 : a.time > b.time ? 1 : 0; });
  var out = {
    version: 1,
    generated_at: Utilities.formatDate(new Date(), 'Asia/Tokyo', "yyyy-MM-dd'T'HH:mm:ssXXX"),
    unreadable: unreadable,
    items: items
  };
  file.setContent(JSON.stringify(out, null, 1));
}

/**
 * 利用速報の本文（上から「払った先」「2026年10月20日 7:10」「35,000円」の順）から取り出す。
 * 日時の行の前のいちばん近い行を払った先、日時のあとの「〜円」を金額とする。読めなければ null
 */
function parse_(subject, body, mailDate) {
  var lines = body.normalize('NFKC').split(/\r?\n/).map(function (s) { return s.trim(); })
    .filter(function (s) { return s.length > 0; });
  var card = subject.normalize('NFKC').replace(/\s*利用速報.*$/, '').trim();
  var dateRe = /(\d{4})年(\d{1,2})月(\d{1,2})日\s*(\d{1,2}):(\d{2})/;
  for (var i = 0; i < lines.length; i++) {
    var d = lines[i].match(dateRe);
    if (!d) continue;
    var amount = 0;
    var rest = lines.slice(i).join(' ');
    var a = rest.match(/([\d,]+)\s*円/);
    if (a) amount = parseInt(a[1].replace(/,/g, ''), 10);
    if (!(amount > 0)) return null;
    var shop = '';
    for (var j = i - 1; j >= 0; j--) {
      var line = lines[j];
      if (line.indexOf(SUBJECT) >= 0 || line === card || /^https?:/.test(line)) break;
      shop = line;
      break;
    }
    var time = d[1] + '-' + pad_(d[2]) + '-' + pad_(d[3]) + 'T' + pad_(d[4]) + ':' + d[5] + ':00+09:00';
    return { time: time, amount: amount, shop: shop.slice(0, 100), card: card.slice(0, 40) };
  }
  return null;
}

function pad_(s) {
  return ('0' + s).slice(-2);
}

function senderDomain_(from) {
  var m = String(from).match(/@([^>\s]+)>?\s*$/);
  return m ? m[1].toLowerCase() : '';
}

function allowed_(domain) {
  return SENDERS.some(function (s) { return domain === s || domain.slice(-(s.length + 1)) === '.' + s; });
}

/** ドライブの「LifeLog/カード利用/card-mail.json」（無ければ作る） */
function file_() {
  var root = DriveApp.getRootFolder();
  var lifelog = root.getFoldersByName('LifeLog');
  var base = lifelog.hasNext() ? lifelog.next() : root.createFolder('LifeLog');
  var sub = base.getFoldersByName(FOLDER);
  var folder = sub.hasNext() ? sub.next() : base.createFolder(FOLDER);
  var files = folder.getFilesByName(FILE);
  return files.hasNext() ? files.next() : folder.createFile(FILE, '{"items": []}', 'application/json');
}

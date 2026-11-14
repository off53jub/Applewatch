/**
 * LifeLog: 注文・予約・配送のメール → ドライブの「LifeLog/メール/orders.json」（2026-11-14。強化案 35）
 *
 * CardMail.gs と同じ Apps Script のプロジェクトに、2つ目のファイルとして足して動かす（名前はどれも order で始め、
 * CardMail.gs の setup・run などとぶつからないようにしてある）。
 * 決まった送り主（ドメイン）と件名の形のメールだけを読み、「店・題・金額・いつ」だけを JSON に書く。
 * メールの本文は保存しない（読むのは、決まった項目名の付いた短い行だけ）。メールをどこかへ送ることもしない。
 * 家の母艦（D:\Lifelog）が、Google ドライブ for desktop からこのファイルを読み、1日の年表の「注文」に入れる。
 *
 * 形（約束 contract-2026-11-14 の 35）:
 *   {"version": 1, "generated_at": ISO,
 *    "items": [{"id", "time": ISO, "kind": "order"|"reservation"|"delivery", "shop": 40 文字まで, "title": 60 文字まで,
 *               "amount": 円の整数|null, "when": ISO|null}]}
 *   time はメールの届いた時刻。when は予約の日時・届く予定の日（分からなければ null）。
 *
 * 使い方は README.md の「注文・予約・配送のメール」。
 *   1. orderSetup を一度実行する（過去 120 日分を読み、30 分ごとの実行を登録する）
 *   2. orderCheckFormat で、どのメールが読めているかを確かめられる（実行ログに、種類ごとの数と読めた項目だけが出る）
 */

/** 残す長さ（日） */
var ORDER_KEEP_DAYS = 120;
var ORDER_FOLDER = 'メール';
var ORDER_FILE = 'orders.json';
/** 1 回に読むメールの数の上限 */
var ORDER_MAX_MESSAGES = 1500;

/**
 * 読むメールの決まり。senders は送り主のドメイン（件名をまねた詐欺メールを読まないため、ドメインで絞る）、
 * subject は件名の形、kind は種類、shop は店の名前（本文の「店舗名」などの行が読めたらそちらを使う）。
 * cancel に当たる件名は、同じ店・同じ日時の予約を消す（取り消しのメール自体は残さない）。
 */
var ORDER_RULES = [
  // 通販
  { shop: 'Amazon', senders: ['amazon.co.jp'], kind: 'order', subject: /注文済み|ご注文の確認|注文の確認/ },
  { shop: 'Amazon', senders: ['amazon.co.jp'], kind: 'delivery', subject: /発送|配達|お届け/ },
  { shop: '楽天市場', senders: ['rakuten.co.jp'], kind: 'order', subject: /注文内容ご確認|ご注文内容の確認|注文確認/ },
  { shop: '楽天市場', senders: ['rakuten.co.jp'], kind: 'delivery', subject: /発送のお知らせ|発送完了|出荷/ },
  { shop: 'Yahoo!ショッピング', senders: ['shopping.yahoo.co.jp', 'store.shopping.yahoo.co.jp'], kind: 'order',
    subject: /注文確認|ご注文/ },
  { shop: 'Yahoo!ショッピング', senders: ['shopping.yahoo.co.jp', 'store.shopping.yahoo.co.jp'], kind: 'delivery',
    subject: /発送|出荷/ },
  // 配送
  { shop: 'ヤマト運輸', senders: ['kuronekoyamato.co.jp', 'yamato-hd.co.jp'], kind: 'delivery',
    subject: /お届け|配達|お荷物/ },
  { shop: '佐川急便', senders: ['sagawa-exp.co.jp'], kind: 'delivery', subject: /お届け|配達|お荷物/ },
  { shop: '日本郵便', senders: ['post.japanpost.jp', 'japanpost.jp'], kind: 'delivery', subject: /お届け|配達|郵便物|ゆうパック/ },
  // 飲食・宿の予約
  { shop: '食べログ', senders: ['tabelog.com'], kind: 'reservation', subject: /予約/, cancel: /キャンセル|取り消し|取消/ },
  { shop: 'ホットペッパー', senders: ['hotpepper.jp'], kind: 'reservation', subject: /予約/, cancel: /キャンセル|取り消し|取消/ },
  { shop: '一休', senders: ['ikyu.com'], kind: 'reservation', subject: /予約/, cancel: /キャンセル|取り消し|取消/ },
  { shop: '楽天トラベル', senders: ['travel.rakuten.co.jp'], kind: 'reservation', subject: /予約/,
    cancel: /キャンセル|取り消し|取消/ },
  // 乗りもの（件名と、日時の行だけ）
  { shop: 'JR（えきねっと）', senders: ['eki-net.com'], kind: 'reservation', subject: /予約|購入|申込/,
    cancel: /払戻|キャンセル|取消/ },
  { shop: 'JR（e5489）', senders: ['jr-odekake.net'], kind: 'reservation', subject: /予約|購入|申込/,
    cancel: /払戻|キャンセル|取消/ },
  { shop: 'スマートEX', senders: ['smart-ex.jp'], kind: 'reservation', subject: /予約|購入/, cancel: /払戻|キャンセル|取消/ },
  { shop: 'JAL', senders: ['jal.com', 'jal.co.jp'], kind: 'reservation', subject: /予約|購入|搭乗/, cancel: /払戻|キャンセル|取消/ },
  { shop: 'ANA', senders: ['ana.co.jp'], kind: 'reservation', subject: /予約|購入|搭乗/, cancel: /払戻|キャンセル|取消/ }
];

/** 金額の行（項目名のあとの「¥1,234」「1,234円」） */
var ORDER_AMOUNT_RE = /(ご請求額|ご請求金額|お支払い金額|お支払金額|支払金額|注文合計|ご注文合計|合計金額|合計|総額|料金)[^\d¥￥]{0,12}[¥￥]?\s*([\d,]{1,9})\s*円?/;
/** 日時の行の項目名（予約の日時・届く予定）。先にこちらを探す */
var ORDER_WHEN_LABEL_RE = /(ご予約日時|予約日時|ご来店日時|来店日時|ご利用日時|ご利用日|利用日|チェックイン|乗車日|出発日時|出発|搭乗日|お届け予定日|お届け予定|配達予定日|配達予定|お届け日時|お届け日)/;
/** 見つからないときの、ふつうの日時の行（受け付けた日・注文した日・送った日は使わない） */
var ORDER_WHEN_GENERIC_RE = /(日時|日付|ご予約日|予約日)/;
var ORDER_WHEN_SKIP_RE = /(受付|注文日|送信|発行|購入日|申込日)/;
/** 店の名前の行の項目名 */
var ORDER_SHOP_LABEL_RE = /^(店舗名|店名|お店|施設名|ホテル名|宿泊施設|ショップ名|ストア名|販売店|出品者)\s*[:：]?\s*(.+)$/;

function orderSetup() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'orderRun') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('orderRun').timeBased().everyMinutes(30).create();
  orderCollect_(ORDER_KEEP_DAYS);
}

/** 30 分ごと（ここ 14 日分を読み直して足す） */
function orderRun() {
  orderCollect_(14);
}

/** どのメールが読めているか（決まりごとに直近 3 通の、送り主のドメイン・読めた項目を実行ログに出す。本文は出さない） */
function orderCheckFormat() {
  ORDER_RULES.forEach(function (rule) {
    var threads = GmailApp.search(orderQuery_(rule, 60), 0, 3);
    Logger.log(rule.shop + '（' + rule.kind + '）: 60 日で ' + threads.length + ' スレッド');
    threads.forEach(function (thread) {
      thread.getMessages().slice(-1).forEach(function (m) {
        var domain = orderDomain_(m.getFrom());
        var item = orderParse_(rule, m);
        Logger.log('  送り主: ' + domain + (orderAllowed_(rule, domain) ? '（受け付ける）' : '（受け付けない）') +
                   ' / ' + (item ? JSON.stringify(item) : '件名の形が違う'));
      });
    });
  });
}

function orderQuery_(rule, days) {
  var from = rule.senders.map(function (s) { return 'from:' + s; }).join(' OR ');
  return '{' + from + '} newer_than:' + days + 'd';
}

function orderCollect_(days) {
  var found = {};
  var cancels = [];
  var read = 0;
  ORDER_RULES.forEach(function (rule) {
    for (var start = 0; start < 500 && read < ORDER_MAX_MESSAGES; start += 100) {
      var threads = GmailApp.search(orderQuery_(rule, days), start, 100);
      threads.forEach(function (thread) {
        thread.getMessages().forEach(function (m) {
          if (read >= ORDER_MAX_MESSAGES) return;
          read++;
          if (!orderAllowed_(rule, orderDomain_(m.getFrom()))) return;
          var subject = String(m.getSubject() || '').normalize('NFKC');
          if (rule.cancel && rule.cancel.test(subject)) {
            var c = orderParse_(rule, m, true);
            if (c) cancels.push(c);
            return;
          }
          if (found[m.getId()]) return;  // 前の決まり（注文の確認など）で読んだメールは 2 回読まない
          var item = orderParse_(rule, m);
          if (item) found[item.id] = item;
        });
      });
      if (threads.length < 100) break;
    }
  });
  var file = orderFile_();
  var old = [];
  try {
    old = JSON.parse(file.getBlob().getDataAsString('UTF-8')).items || [];
  } catch (e) {
    old = [];
  }
  var limit = new Date(Date.now() - ORDER_KEEP_DAYS * 86400000).getTime();
  old.forEach(function (item) {
    if (item && item.id && !found[item.id] && new Date(item.time).getTime() >= limit) found[item.id] = item;
  });
  // 取り消しのメールがあった予約（同じ店・同じ日時）は消す
  cancels.forEach(function (c) {
    if (!c.when) return;
    Object.keys(found).forEach(function (k) {
      var item = found[k];
      if (item.kind === 'reservation' && item.shop === c.shop && item.when === c.when) delete found[k];
    });
  });
  var items = Object.keys(found).map(function (k) { return found[k]; });
  items.sort(function (a, b) { return a.time < b.time ? -1 : a.time > b.time ? 1 : 0; });
  var out = {
    version: 1,
    generated_at: Utilities.formatDate(new Date(), 'Asia/Tokyo', "yyyy-MM-dd'T'HH:mm:ssXXX"),
    items: items
  };
  file.setContent(JSON.stringify(out, null, 1));
}

/**
 * 1 通から { id, time, kind, shop, title, amount, when } を作る。件名の形が違えば null。
 * 本文は、項目名の付いた短い行（店の名前・金額・日時）を探すためだけに読み、残さない。
 */
function orderParse_(rule, m, cancelled) {
  var subject = String(m.getSubject() || '').normalize('NFKC').replace(/^\s*((re|fwd?)\s*:\s*)+/i, '').trim();
  if (!cancelled && !rule.subject.test(subject)) return null;
  var lines = String(m.getPlainBody() || '').normalize('NFKC').split(/\r?\n/)
    .map(function (s) { return s.trim(); })
    .filter(function (s) { return s.length > 0 && s.length <= 80; })
    .slice(0, 400);
  var shop = rule.shop;
  var amount = null;
  var when = null;
  var mailDate = m.getDate();
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var s = line.match(ORDER_SHOP_LABEL_RE);
    if (s && shop === rule.shop && rule.kind === 'reservation') shop = s[2].slice(0, 40);
    if (amount === null && rule.kind !== 'delivery') {
      var a = line.match(ORDER_AMOUNT_RE);
      if (a) {
        var yen = parseInt(a[2].replace(/,/g, ''), 10);
        if (yen > 0 && yen < 100000000) amount = yen;
      }
    }
    if (when === null && rule.kind !== 'order' && ORDER_WHEN_LABEL_RE.test(line)) {
      when = orderWhen_(line + ' ' + (lines[i + 1] || ''), mailDate);
    }
  }
  for (var j = 0; when === null && rule.kind !== 'order' && j < lines.length; j++) {
    if (ORDER_WHEN_GENERIC_RE.test(lines[j]) && !ORDER_WHEN_SKIP_RE.test(lines[j])) {
      when = orderWhen_(lines[j] + ' ' + (lines[j + 1] || ''), mailDate);
    }
  }
  return {
    id: m.getId(),
    time: Utilities.formatDate(mailDate, 'Asia/Tokyo', "yyyy-MM-dd'T'HH:mm:ssXXX"),
    kind: rule.kind,
    shop: String(shop).slice(0, 40),
    title: orderTitle_(subject),
    amount: amount,
    when: when
  };
}

/** 件名から題を作る（【】の飾り・「様」までの宛名を除き、60 文字まで） */
function orderTitle_(subject) {
  var t = subject.replace(/【[^】]*】/g, ' ').replace(/^.{0,20}様\s*/, '').replace(/\s+/g, ' ').trim();
  return (t || subject).slice(0, 60);
}

/**
 * 「2026年11月20日(金) 19:00」「2026/11/20 19:00」「11月20日 19:00」「11/20」などから ISO を作る。
 * 年が無いときは、メールの届いた日から先のいちばん近い年。時刻が無いときは日だけ（00:00）。読めなければ null
 */
function orderWhen_(text, mailDate) {
  var t = text.normalize('NFKC');
  var y = null, mo = null, d = null, h = null, mi = null;
  var full = t.match(/(\d{4})\s*[年\/.-]\s*(\d{1,2})\s*[月\/.-]\s*(\d{1,2})/);
  var short = t.match(/(\d{1,2})\s*[月\/]\s*(\d{1,2})\s*日?/);
  if (full) {
    y = parseInt(full[1], 10); mo = parseInt(full[2], 10); d = parseInt(full[3], 10);
  } else if (short) {
    mo = parseInt(short[1], 10); d = parseInt(short[2], 10);
    y = mailDate.getFullYear();
    var guess = new Date(y, mo - 1, d);
    if (guess.getTime() < mailDate.getTime() - 30 * 86400000) y += 1;
  } else {
    return null;
  }
  if (!(mo >= 1 && mo <= 12 && d >= 1 && d <= 31)) return null;
  var c = t.match(/(\d{1,2})\s*[:時]\s*(\d{2})/);
  if (c) {
    h = parseInt(c[1], 10); mi = parseInt(c[2], 10);
    if (!(h >= 0 && h <= 23 && mi >= 0 && mi <= 59)) { h = null; mi = null; }
  }
  return y + '-' + orderPad_(mo) + '-' + orderPad_(d) + 'T' + orderPad_(h === null ? 0 : h) + ':' +
    orderPad_(mi === null ? 0 : mi) + ':00+09:00';
}

function orderPad_(n) {
  return ('0' + n).slice(-2);
}

function orderDomain_(from) {
  var m = String(from).match(/@([^>\s]+)>?\s*$/);
  return m ? m[1].toLowerCase() : '';
}

function orderAllowed_(rule, domain) {
  return rule.senders.some(function (s) { return domain === s || domain.slice(-(s.length + 1)) === '.' + s; });
}

/** ドライブの「LifeLog/メール/orders.json」（無ければ作る） */
function orderFile_() {
  var root = DriveApp.getRootFolder();
  var lifelog = root.getFoldersByName('LifeLog');
  var base = lifelog.hasNext() ? lifelog.next() : root.createFolder('LifeLog');
  var sub = base.getFoldersByName(ORDER_FOLDER);
  var folder = sub.hasNext() ? sub.next() : base.createFolder(ORDER_FOLDER);
  var files = folder.getFilesByName(ORDER_FILE);
  return files.hasNext() ? files.next() : folder.createFile(ORDER_FILE, '{"version": 1, "items": []}', 'application/json');
}

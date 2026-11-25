# Privacy Policy — LifeLog Calendar

Last updated: 2026-11-25

LifeLog Calendar is a personal tool used by a single person (the developer) on their own home computer. It is not offered to the public, and no one else can sign in to it.

## What it does

It reads the developer's own chat history that is already saved on the developer's computer, finds plans that were decided there, and adds, moves or deletes the matching events in the developer's own Google Calendar.

## Google user data it uses

- Scope: `https://www.googleapis.com/auth/calendar.events` (view and edit events on the developer's calendars).
- It reads events only to avoid duplicates and to update events it created itself. It changes an event the user created only after the user confirms it in the user's own app.

## Where the data goes

- The sign-in token and all data stay on the developer's own computer. Nothing is sold, shared with third parties, or used for advertising.
- To decide whether a plan was settled, the relevant chat text and event titles are sent to an AI model API (Anthropic) under the developer's own account. Nothing else is shared.

## Keeping and deleting data

- The developer can revoke access at any time at https://myaccount.google.com/permissions , which stops all access immediately.
- Local records of what the tool did can be deleted by the developer at any time.

## Contact

Questions can be raised as an issue in this repository: https://github.com/off53jub/Applewatch/issues

---

# プライバシーポリシー（LifeLog Calendar）

LifeLog Calendar は、開発者本人だけが自宅の PC で使う個人用の道具です。一般には公開しておらず、本人以外はログインできません。

- 本人の PC にすでに保存されている本人のトーク履歴から決まった予定を見つけ、本人の Google カレンダーに予定を入れる・動かす・消すだけに使います。
- 使う権限はカレンダーの予定の表示と編集だけです。本人が自分で入れた予定は、本人がアプリで確かめて押したときだけ直します。
- ログインの鍵とデータは本人の PC の中だけに置き、第三者に渡したり売ったり広告に使ったりしません。予定が決まったかの判断のため、関係するトークの文と予定の題を本人のアカウントの AI（Anthropic）の API に送ります。
- https://myaccount.google.com/permissions からいつでも取り消せます。
- 問い合わせはこのリポジトリの Issue へ。

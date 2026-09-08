# gh-assigned.swift

[gh-assigned](https://github.com/sorafujitani/gh-assigned) のSwift製TUI版です。自分のPR、レビュー依頼、担当PRを端末内で検索し、ブラウザで開きます。GitHub認証とAPI呼び出しには、ログイン済みの `gh` CLIを使います。

## 起動

Swift 6.3.2とGitHub CLIが必要です。macOS 14（Apple Silicon）とLinux arm64（公式Swiftコンテナ）でビルド・動作確認しています。

```sh
gh auth login
swift build -c release
.build/release/gh-assigned
```

Swiftのバージョンは `.swift-version` に指定しています。[公式ツールチェーン](https://www.swift.org/install/)を導入し、`swift --version` が6.3.2であることを確認してください。既存Xcodeとは別にユーザー領域へインストールした場合は、次のように選べます。

```sh
export PATH="$HOME/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH"
```

GitHub CLI拡張として登録する場合は、既存のRust版とコマンド名が重なるため、その登録状態を確認してから実施してください。上記の直接起動では既存の拡張を置き換えません。

## 操作

| キー | 操作 |
| --- | --- |
| 文字入力 | 現在の一覧を検索 |
| Tab / Shift-Tab | Mine / Review requested / Assignedを切り替え |
| Ctrl-F | 検索対象を切り替え |
| Ctrl-T | fuzzy / substring / exactを切り替え |
| ↑ / ↓、Ctrl-P / N、Ctrl-K / J | 選択を移動 |
| PageUp / PageDown | 10行移動 |
| Ctrl-W / U / H | 前の単語 / 全入力 / 前の文字を削除 |
| Enter | ブラウザで開いて終了 |
| O | ブラウザで開き、一覧に残る |
| Y / N | URL / PR番号をコピー |
| Ctrl-R | 再取得 |
| F1、入力が空のときの `?` | ヘルプ |
| Esc / Ctrl-C | 終了（終了コード130）。ヘルプ表示中のEscはヘルプを閉じる |

PRの依存関係をインデントで、CIとレビュー結果を状態表示で確認できます。前回のキャッシュを表示しながら、一覧とCIを別々に取得します。各一覧は最大100件です。

## JSON出力

```sh
.build/release/gh-assigned --json
```

`lists` は `[Mine, Review requested, Assigned]` の固定順です。PRには `repo`, `number`, `title`, `url`, `author`, `is_draft`, `base_ref`, `head_ref`, `checks`, `review` が含まれます。対話画面には端末が必要ですが、JSON出力はパイプでも使えます。

キャッシュはmacOSでは `~/Library/Caches/gh-assigned/snapshot.json`、Linuxでは `~/.cache/gh-assigned/snapshot.json` に保存します。`XDG_CACHE_HOME` 指定時はその配下です。Rust版と同じ保存先・JSON形式を使用するため、同じ環境で実行するとキャッシュを共有します。保存に失敗しても、取得済みのJSONは出力します。

## 構成

- Swift 6言語モード、Swift Package Manager、ArgumentParser
- Swift Concurrencyによる並行取得とイベント処理
- 小さなPOSIX/ANSI端末層と、シグナルを通知するC層
- Swift Testingによるコアテスト、Pythonによる疑似端末テスト

`Sources/AssignedCore` がデータ取得・検索・状態管理、`Sources/AssignedTerminal` が端末操作・描画、`Sources/AssignedCLI` が両者の接続を担当します。

## 検証

```sh
bash scripts/verify.sh
```

Swiftのバージョン確認、debug/releaseビルド、12件のコア・描画テスト、各ビルドの疑似端末テスト、仮想画面テストを実行します。CIも同じスクリプトを使用します。

疑似端末テストは偽の `gh` と一時HOMEで実行し、GitHubには接続しません。JSON、連続入力、終了時の端末属性復元、応答しない外部コマンドのキャンセルを確認します。仮想画面テストは最下行での起動、ヘルプ開閉、長い検索語、高さ縮小、終了時の消去を検査します。必要に応じて一時Python環境へ `pyte==0.8.2` をダウンロードします。Linuxでは `python3-venv` も必要です。

## 互換性と未検証範囲

- fuzzy検索はSwift実装です。Rust版のnucleoと順位が完全一致する保証はありません。
- ヘルプと不正引数の表示はArgumentParserの形式です。
- JSONモードではキャッシュ保存失敗を致命的エラーにしません。
- 実GitHubからの3一覧取得とJSON・キャッシュの一致を確認済みです。
- macOS/Linux arm64で検証済みです。Intel環境、各Linuxディストリビューションへの配布、Windowsは対応保証の対象外です。
- ブラウザ起動要求とキャンセルは偽コマンドで検証しています。実ブラウザ画面と実クリップボードの操作は自動検証していません。
- 高さ縮小時は画面先頭へ表示位置を合わせます。端末自身が縮小に伴って切り取る行は復元しません。全端末エミュレータで同一の描画になる保証はありません。

## ライセンス

[MIT](LICENSE)

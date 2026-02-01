# CLAUDE.md

このファイルはClaude Codeがこのリポジトリを理解するためのコンテキストを提供します。

## プロジェクト概要

Amazon EC2のNVMeインスタンスストアを単一のRAID-0ボリュームとしてセットアップするBashスクリプト。

### 背景

- AWS Deep Learning AMI (DLAMI) にはNVMe RAIDセットアップの公式スクリプトがない
- AWS EKS AMIの`setup-local-disks`はEKS専用でkubelet/containerdのbind mount処理が含まれる
- このスクリプトは`setup-local-disks`の設計を参考に、汎用的なDLAMI向けに作成

### 参考にした公式スクリプト

- https://github.com/awslabs/amazon-eks-ami/blob/main/templates/shared/runtime/bin/setup-local-disks

## ファイル構成

```
nvme-raid-setup/
├── CLAUDE.md              # このファイル（Claude Code用）
├── README.md              # ユーザー向けドキュメント
├── LICENSE                # MITライセンス
├── setup-nvme-raid.sh     # メインスクリプト
└── examples/
    └── user-data.sh       # EC2 User Dataサンプル
```

## 技術的な設計判断

### デバイス検出

```bash
# 推奨: /dev/disk/by-id を使用（udevが作成する安定したシンボリックリンク）
find -L /dev/disk/by-id/ -xtype l -name '*NVMe_Instance_Storage_*'

# フォールバック: nvme list（出力形式に依存するため非推奨）
nvme list | grep "Amazon EC2 NVMe Instance Storage"
```

### XFSフォーマット

```bash
# -l su=8b を指定する理由:
# RAIDのstripe unit (512k) がlog stripe unitの最大値 (256k) を超えるため
# 警告を回避し、32k (8 blocks) を明示的に指定
mkfs.xfs -l su=8b "${device}"
```

### 冪等性の確保

- RAID作成前に既存デバイスをチェック
- フォーマット前にfstypeをチェック
- マウント前にmountpointをチェック

## 開発ガイドライン

### コーディング規約

- Bash strict mode使用: `set -o errexit -o pipefail -o nounset`
- ShellCheck準拠
- 関数名はスネークケース
- ログ出力には `log_info`, `log_warn`, `log_error` を使用

### テスト方法

実際のEC2インスタンス（NVMeインスタンスストア付き）でテストが必要：

```bash
# 推奨テストインスタンス
# - i3.xlarge (1 x 950 GB NVMe) - 単一デバイスのテスト
# - i3.2xlarge (1 x 1.9 TB NVMe) - 単一デバイスのテスト
# - i3.4xlarge (2 x 1.9 TB NVMe) - RAID-0のテスト
# - c5d.xlarge (1 x 100 GB NVMe) - 安価なテスト用
```

### 今後の改善候補

1. **RAID-10サポート**: 4台以上のデバイスでRAID-10オプション追加
2. **個別マウントモード**: RAIDを作らず個別にマウントするオプション
3. **systemd mountユニット**: /etc/fstabの代わりにsystemdユニット生成
4. **ドライラン**: 実際に実行せずに何が起こるかを表示
5. **アンマウント/クリーンアップ**: RAID解除スクリプト

## 関連リソース

- [Amazon EC2 Instance Store Volumes](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html)
- [mdadm man page](https://linux.die.net/man/8/mdadm)
- [XFS mkfs options](https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html)

## コマンド例

```bash
# ローカルでの構文チェック
shellcheck setup-nvme-raid.sh

# ヘルプ表示
./setup-nvme-raid.sh --help

# デフォルト実行
sudo ./setup-nvme-raid.sh

# カスタムマウントポイント
sudo ./setup-nvme-raid.sh --dir /scratch --name scratch_raid
```

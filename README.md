# NVMe RAID Setup for Amazon EC2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Amazon EC2のNVMeインスタンスストアを単一のRAID-0ボリュームとしてセットアップするスクリプトです。Deep Learning AMI (DLAMI) やその他のUbuntu/Amazon Linux AMIで動作します。

## 特徴

- 🚀 **シンプル** - 1コマンドで全NVMeデバイスをRAID-0に構成
- 🔒 **信頼性** - Amazon EKS AMIの[setup-local-disks](https://github.com/awslabs/amazon-eks-ami/blob/main/templates/shared/runtime/bin/setup-local-disks)を参考にした設計
- 🔄 **冪等性** - 複数回実行しても安全
- 📦 **自動依存解決** - 必要なパッケージ(mdadm, xfsprogs)を自動インストール

## 対応インスタンス

| ファミリー | インスタンスタイプ | NVMe容量 |
|-----------|-------------------|----------|
| P5 | p5.48xlarge | 8 x 3.84 TB |
| P5e | p5e.48xlarge | 8 x 3.84 TB |
| P5en | p5en.48xlarge | 8 x 3.84 TB |
| P4d | p4d.24xlarge | 8 x 1 TB |
| I3 | i3.* | 最大 8 x 1.9 TB |
| I4i | i4i.* | 最大 8 x 3.75 TB |
| C5d | c5d.* | 最大 4 x 900 GB |
| G5 | g5.* | 最大 2 x 3.84 TB |

## クイックスタート

### 基本的な使い方

```bash
# スクリプトをダウンロード
curl -O https://raw.githubusercontent.com/koyakimu/nvme-raid-setup/main/setup-nvme-raid.sh
chmod +x setup-nvme-raid.sh

# 実行（デフォルトで /data にマウント）
sudo ./setup-nvme-raid.sh
```

### カスタムマウントポイント

```bash
sudo ./setup-nvme-raid.sh --dir /mnt/nvme
```

### オプション一覧

```
Options:
    -d, --dir DIR       マウントポイント (デフォルト: /data)
    -n, --name NAME     RAIDアレイ名 (デフォルト: local_raid)
    -h, --help          ヘルプを表示
```

## EC2 User Dataで使用

インスタンス起動時に自動でRAIDを構成するには、User Dataに以下を設定：

```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/koyakimu/nvme-raid-setup/main/setup-nvme-raid.sh | bash -s -- --dir /data
```

または、より安全な方法：

```bash
#!/bin/bash
set -e

cd /tmp
curl -O https://raw.githubusercontent.com/koyakimu/nvme-raid-setup/main/setup-nvme-raid.sh
chmod +x setup-nvme-raid.sh
./setup-nvme-raid.sh --dir /data
```

## 動作の詳細

1. **デバイス検出**: `/dev/disk/by-id/` からNVMeインスタンスストアを検出（最も信頼性が高い方法）
2. **RAID作成**: `mdadm`でRAID-0アレイを作成
3. **フォーマット**: XFSでフォーマット（`-l su=8b`オプションでRAIDに最適化）
4. **マウント**: 指定ディレクトリにマウントし、`/etc/fstab`に追加

## 注意事項

⚠️ **インスタンスストアは揮発性です**

- インスタンスを**停止**または**終了**するとデータは**消失**します
- **再起動**の場合はデータは保持されます
- 重要なデータは必ずS3やEBSにバックアップしてください

## 公式スクリプトとの比較

このスクリプトはAmazon EKS AMIの`setup-local-disks`を参考にしていますが、以下の点が異なります：

| 機能 | setup-local-disks | このスクリプト |
|------|-------------------|---------------|
| 対象 | EKS AMI専用 | 汎用（DLAMI等） |
| kubelet/containerd bind mount | あり | なし |
| systemd mountユニット | あり | /etc/fstab |
| RAID-10サポート | あり | なし |
| 個別マウントモード | あり | なし |

EKS環境では公式の`setup-local-disks`を使用することを推奨します。

## ライセンス

MIT License - 詳細は[LICENSE](LICENSE)を参照

## 参考リンク

- [Amazon EKS AMI - setup-local-disks](https://github.com/awslabs/amazon-eks-ami/blob/main/templates/shared/runtime/bin/setup-local-disks)
- [Amazon EC2 Instance Store](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html)
- [Amazon EBS and RAID Configuration](https://docs.aws.amazon.com/ebs/latest/userguide/raid-config.html)

## Contributing

Issue や Pull Request を歓迎します。

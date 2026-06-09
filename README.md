# Linux Automation Toolkit

Production-style Bash scripts automating core Linux sysadmin tasks.
Built on WSL 2 (Ubuntu). Every script runs identically on a real server.

## Scripts

| Script             | Purpose                              | Cron        |
| ------------------ | ------------------------------------ | ----------- |
| `user_manager.sh`  | User lifecycle: create, delete, list | on-demand   |
| `disk_monitor.sh`  | Disk usage alerts at 70/80/90%       | hourly      |
| `log_parser.sh`    | SSH threat intelligence report       | nightly 6am |
| `backup.sh`        | Rotating backup, 7-day retention     | nightly 2am |
| `ssh_hardening.sh` | SSH and fail2ban hardening           | on-demand   |

## Project structure

linux-automation-toolkit/
├── scripts/ # all five automation scripts
├── backups/ # rotating backup archives
├── reports/ # disk alert and SSH threat reports
├── logs/ # script run logs
└── docs/ # extended documentation

## Prerequisites

Ubuntu 20.04+ (or WSL 2). Install dependencies:

```bash
sudo apt install -y git fail2ban mailutils postfix tree curl
```

## Usage

```bash
# user management
sudo ./scripts/user_manager.sh create alice developers
sudo ./scripts/user_manager.sh delete alice
sudo ./scripts/user_manager.sh list

# disk monitoring
./scripts/disk_monitor.sh
./scripts/disk_monitor.sh --threshold 70
./scripts/disk_monitor.sh --test

# SSH log parser
sudo ./scripts/log_parser.sh
sudo ./scripts/log_parser.sh --top 20 --watch

# backup
./scripts/backup.sh
./scripts/backup.sh --list
./scripts/backup.sh --verify backups/backup_host_date.tar.gz

# SSH hardening
sudo ./scripts/ssh_hardening.sh --audit
sudo ./scripts/ssh_hardening.sh
sudo ./scripts/ssh_hardening.sh --revert
```

## Cron schedule

0 \* \* \* _ disk_monitor.sh # hourly disk check
0 2 _ \* _ backup.sh # nightly backup at 2am
0 6 _ \* \* log_parser.sh # nightly SSH report at 6am

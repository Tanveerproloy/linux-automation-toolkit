# Linux Automation Toolkit

Just a quick collection of Bash scripts I put together to automate everyday sysadmin chores. I wrote and tested these on WSL 2 (Ubuntu) on Windows, but they should work perfectly fine on any standard Linux distro.

## What's inside

| Script | What it does |
|--------|---------|
| `user_manager.sh` | Adds or removes users and enforces basic password rules. |
| `disk_monitor.sh` | Warns you if your disk space is getting dangerously low. |
| `log_parser.sh` | Digs through auth.log and spits out a report of failed SSH logins. |
| `backup.sh` | Handles backups and automatically trashes anything older than 7 days. |
| `ssh_hardening.sh` | Locks down standard SSH configs to make things a bit more secure. |

## Quick Start

Before running anything, remember to make the script executable:
`chmod +x script_name.sh`

#!/bin/bash
# MySQL全量备份脚本
set -euo pipefail
umask 077

MYSQL_USER="${MYSQL_USER:-backup}"
MYSQL_PASS="${MYSQL_PASS:?请设置MYSQL_PASS}"
BACKUP_DIR="/data/mysql-backup"
DAT...[truncated]
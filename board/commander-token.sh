#!/usr/bin/env bash
# commander-token —— 随时取回 API token（忘记时不用重装）。
# token 文件是 0600 root，所以非 root 跑这个脚本也读不到；它会直接告诉你该怎么拿。
set -euo pipefail

TOKEN_FILE=/etc/radxa-commander/token
# 安装时 install.sh 会给安装者留一份 0600 副本，免 sudo 就能读
_uhome="$(getent passwd "${SUDO_USER:-$USER}" 2>/dev/null | cut -d: -f6)"
HOME_COPY="${_uhome:-$HOME}/commander-token.txt"

# 先判身份，再判文件。反过来的话，非 root 用户 stat 不到 0700 root 目录里的文件，
# 会得到「板子上还没有 token」这种完全错误的结论 —— 明明有，只是他读不到。
if [[ "$(id -u)" != "0" ]]; then
  echo "token 文件只有 root 能读（/etc/radxa-commander 是 0700 root）。" >&2
  echo "  sudo commander-token" >&2
  if [[ -s "$HOME_COPY" ]]; then
    echo "或者用安装时留的副本（免 sudo）：" >&2
    echo "  cat $HOME_COPY" >&2
  fi
  exit 1
fi

if [[ ! -s "$TOKEN_FILE" ]]; then
  echo "板子上还没有 token。先生成： sudo bash ~/commander-board/install.sh" >&2
  exit 1
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF
板子 IP : ${IP:-?}
管理页  : http://${IP:-<板子IP>}:18080/
token   : $(cat "$TOKEN_FILE")

（App 里填 IP + 上面这串 token；网页版打开管理页后在 token 栏粘贴）
EOF

# Runs inside a case's agent image. Prints facts only.
echo "## id: $(id -u):$(id -g) user=$(whoami 2>/dev/null)"
echo "## os: $(. /etc/os-release 2>/dev/null; echo $PRETTY_NAME)"
echo "## shell: bash=$(command -v bash) sh=$(readlink -f /bin/sh 2>/dev/null)"
echo "## env: HOME=$HOME LANG=$LANG LC_ALL=$LC_ALL TERM=$TERM PATH=$PATH"
echo "## workspace owner: $(stat -c '%u:%g %a' /workspace 2>/dev/null)"
echo "## git: $(cd /workspace 2>/dev/null && git log --oneline 2>&1 | wc -l) commits; $(cd /workspace && git status --short 2>&1 | wc -l) dirty"
echo "## busybox: $(command -v busybox)"
for p in python python3 python2 pip pip3 perl ruby node npm npx yarn pnpm bun deno php lua go cargo rustc java \
  rg ag ack fd fdfind fzf tree jq yq xmllint file xxd hexdump od bc dc \
  patch diff git-apply sed awk gawk mawk grep egrep fgrep find xargs sort uniq cut tr tee head tail wc nl tac rev paste column comm join split csplit expand fold fmt \
  ed ex vi vim nano emacs less more \
  curl wget nc ncat netcat telnet ssh scp rsync ping dig nslookup host ip ifconfig ss netstat \
  ps top htop pgrep pkill kill killall lsof strace free uptime watch \
  tar gzip gunzip zip unzip bzip2 xz zstd \
  make cmake gcc cc g++ clang ld \
  git gh hub svn hg \
  sudo su apt apt-get dpkg apk yum \
  timeout nohup script setsid stdbuf unbuffer expect time \
  realpath readlink dirname basename mktemp stat touch install chmod chown ln cp mv rm mkdir rmdir \
  date sleep env printenv which whereis type locale iconv dos2unix \
  md5sum sha1sum sha256sum base64 openssl \
  sqlite3 psql pg_isready mysql redis-cli clickhouse-client \
  elixir iex mix erl erlc escript rebar3 rebar \
  bash sh zsh dash fish \
  man info apropos tldr \
  docker tmux screen clear tput reset seq yes true false test expr printf echo cat ls du df ; do
  if command -v "$p" >/dev/null 2>&1; then echo "HAVE $p $(command -v $p)"; else echo "MISS $p"; fi
done
echo "## grep: $(grep --version 2>&1 | head -1)"
echo "## sed: $(sed --version 2>&1 | head -1)"
echo "## awk: $(awk --version 2>&1 | head -1; awk -W version 2>&1 | head -1)"
echo "## find: $(find --version 2>&1 | head -1)"
echo "## perl: $(perl -v 2>&1 | sed -n 2p)"
echo "## perl-modules: $(perl -MFile::Slurp -e1 2>&1 | head -1 | cut -c1-60) | $(perl -MJSON::PP -e 'print "JSON::PP ok"' 2>&1 | head -1 | cut -c1-60) | $(perl -MData::Dumper -e 'print "Dumper ok"' 2>&1 | head -1 | cut -c1-60) | $(perl -MFile::Find -e 'print "File::Find ok"' 2>&1 | head -1 | cut -c1-60)"
echo "## node: $(node --version 2>&1 | head -1) /opt/pi/node=$(/opt/pi/node --version 2>&1)"
echo "## mix archives/tasks: $(cd /workspace && ls deps 2>/dev/null | tr '\n' ' ' | grep -o -w -E 'credo|dialyxir|ex_doc|sobelow|excoveralls|mix_test_watch' | tr '\n' ' ')"
echo "## hex: $(ls ${MIX_HOME:-$HOME/.mix}/archives 2>/dev/null | tr '\n' ' ')"
echo "## tmp: $(df -h /tmp 2>/dev/null | tail -1)"

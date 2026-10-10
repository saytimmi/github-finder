#!/usr/bin/env bash
# liveness.sh — скоринг живости GitHub-репозиториев по проверяемым сигналам.
# Зачем: звёзды в 2026 накручиваются (ICSE 2026: 6 млн фейк-звёзд), списки
# звездящих GitHub закрыл 30.06.2026 — судить надо по коммитам, релизам,
# отклику на чужие PR, распределённости авторов, кривой звёзд по неделям и
# росту (последние недели против предыдущих): нужен проект, который идёт вперёд.
#
# Использование:
#   liveness.sh owner/repo[=npm:name|=pypi:name] [...] [--pkg npm:name|pypi:name]
#   Пакет для спроса задаётся на каждый репо через "=", например
#   absadiki/pywhispercpp=pypi:pywhispercpp; глобальный --pkg — только если репо один.
#   --json  — сырой JSON вместо markdown-таблицы.
# Нужно: gh (авторизованный), jq, curl. ecosyste.ms требует контакт в mailto —
# берётся из $LIVENESS_EMAIL, иначе из `gh api user` (email/login).
set -uo pipefail

JSON=0; PKG=""; REPOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --pkg) PKG="${2:-}"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) REPOS+=("$1") ;;
  esac; shift
done
[ ${#REPOS[@]} -eq 0 ] && { echo "usage: liveness.sh owner/repo[=npm:x|=pypi:x] [...] [--pkg npm:x|pypi:x] [--json]" >&2; exit 2; }
for t in gh jq curl bc; do command -v "$t" >/dev/null || { echo "нет $t" >&2; exit 2; }; done
FREE_MB=$(df -m / | awk 'NR==2{print $4}'); [ "${FREE_MB:-0}" -lt 500 ] && { echo "на диске < 500 МБ свободно ($FREE_MB МБ): Bash-вывод Claude Code не запишется — сначала освободи место" >&2; exit 3; }

EMAIL="${LIVENESS_EMAIL:-$(gh api user --jq '.email // (.login + "@users.noreply.github.com")' 2>/dev/null || echo "liveness@example.com")}"
NOW=$(date -u +%s)
SINCE90=$(date -u -v-90d +%FT%TZ 2>/dev/null || date -u -d '90 days ago' +%FT%TZ)
SINCE365=$(date -u -v-365d +%F 2>/dev/null || date -u -d '365 days ago' +%F)

days_since() { # ISO date → дней назад; пусто → 99999
  local d="$1"; [ -z "$d" ] || [ "$d" = "null" ] && { echo 99999; return; }
  local ts; ts=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$d" +%s 2>/dev/null || date -u -d "$d" +%s 2>/dev/null || echo "$NOW")
  echo $(( (NOW - ts) / 86400 ))
}
bucket() { # value thresholds... → score by descending thresholds: bucket v t1:s1 t2:s2 ... default
  local v="$1"; shift; local last="$1"; shift
  for pair in "$@"; do local t="${pair%%:*}" s="${pair##*:}"; if [ "$(echo "$v <= $t" | bc -l)" = 1 ]; then echo "$s"; return; fi; done
  echo "$last"
}

score_repo() {
  local R="${1%%=*}" ENC; ENC="${R/\//%2F}"
  local PKG="$PKG"; case "$1" in *=*) PKG="${1#*=}" ;; esac
  local core err; core=$(gh api "repos/$R" 2>&1) || { err=$(echo "$core" | tr '\n' ' ' | cut -c1-160); jq -nc --arg r "$R" --arg e "gh api repos/$R: $err" '{repo:$r,error:$e}'; return; }
  local pushed archived stars forks subs created
  pushed=$(jq -r '.pushed_at' <<<"$core"); archived=$(jq -r '.archived' <<<"$core")
  stars=$(jq -r '.stargazers_count' <<<"$core"); forks=$(jq -r '.forks_count' <<<"$core")
  subs=$(jq -r '.subscribers_count' <<<"$core"); created=$(jq -r '.created_at' <<<"$core")
  local dp; dp=$(days_since "$pushed")
  # S1 пуш
  local s1; if [ "$archived" = true ]; then s1=0; else s1=$(bucket "$dp" 0 30:1 90:0.6 365:0.2); fi
  # S2 коммиты 90д
  local c90; c90=$(gh api "search/commits?q=repo:$R+committer-date:>=${SINCE90%%T*}&per_page=1" --jq .total_count 2>/dev/null) || c90=""
  [ -z "$c90" ] && c90=$(gh api "repos/$R/commits?since=$SINCE90&per_page=100" --jq length 2>/dev/null || echo 0)
  local s2; s2=$(if [ "$c90" -ge 20 ]; then echo 1; elif [ "$c90" -ge 5 ]; then echo 0.6; elif [ "$c90" -ge 1 ]; then echo 0.3; else echo 0; fi)
  # S3 релиз/тег
  local rel reldate; rel=$(gh api "repos/$R/releases/latest" --jq '.tag_name+"\t"+.published_at' 2>/dev/null) || rel=""
  if [ -z "$rel" ]; then
    local tag; tag=$(gh api "repos/$R/tags?per_page=1" --jq '.[0].commit.sha // empty' 2>/dev/null || true)
    if [ -n "$tag" ]; then reldate=$(gh api "repos/$R/commits/$tag" --jq '.commit.committer.date' 2>/dev/null || true); rel="tag	$reldate"; fi
  fi
  local relname="${rel%%	*}" ; reldate="${rel#*	}"; [ "$rel" = "$relname" ] && reldate=""
  local dr; dr=$(days_since "$reldate")
  local s3; s3=$( [ -z "$reldate" ] && echo 0 || bucket "$dr" 0 180:1 365:0.5 )
  # S4 отклик на PR (ecosyste.ms issues), ttc в секундах
  local iss; iss=$(curl -sf --max-time 20 "https://issues.ecosyste.ms/api/v1/hosts/GitHub/repositories/$ENC?mailto=$EMAIL" 2>/dev/null || echo '{}')
  local ttc prs merged pra bots
  ttc=$(jq -r '.past_year_avg_time_to_close_pull_request // empty' <<<"$iss"); prs=$(jq -r '.past_year_pull_requests_count // 0' <<<"$iss")
  merged=$(jq -r '.past_year_merged_pull_requests_count // 0' <<<"$iss"); pra=$(jq -r '.past_year_pull_request_authors_count // 0' <<<"$iss")
  bots=$(jq -r '.past_year_bot_pull_requests_count // 0' <<<"$iss")
  local ttcd="" s4=0.5 s4note="нет данных ecosyste.ms"
  if [ -n "$ttc" ] && [ "$prs" -gt 0 ]; then
    ttcd=$(echo "scale=1; $ttc/86400" | bc -l); local mr; mr=$(echo "scale=2; $merged/$prs" | bc -l)
    if [ "$(echo "$ttcd <= 7 && $mr >= 0.2" | bc -l)" = 1 ]; then s4=1; elif [ "$(echo "$ttcd <= 30" | bc -l)" = 1 ]; then s4=0.6; else s4=0.2; fi
    if [ "$(echo "$bots*2 > $prs" | bc -l)" = 1 ]; then s4=$(echo "$s4*0.5" | bc -l); fi
    s4note="ttc ${ttcd}д, merged $merged/$prs, авторов $pra, бот-PR $bots"
  else # нет в ecosyste.ms или там 0 PR (молодой/несинхронизированный) → gh search (2 вызова, лимит 30/мин)
    prs=$(gh api "search/issues?q=repo:$R+is:pr+created:>=$SINCE365&per_page=1" --jq .total_count 2>/dev/null || echo "")
    merged=$(gh api "search/issues?q=repo:$R+is:pr+is:merged+created:>=$SINCE365&per_page=1" --jq .total_count 2>/dev/null || echo 0)
    if [ -n "$prs" ] && [ "$prs" -gt 0 ]; then
      local mr; mr=$(echo "scale=2; $merged/$prs" | bc -l)
      if [ "$(echo "$mr >= 0.5" | bc -l)" = 1 ]; then s4=0.8; elif [ "$(echo "$mr >= 0.2" | bc -l)" = 1 ]; then s4=0.5; else s4=0.2; fi
      s4note="gh: merged $merged/$prs за год (без ttc)"
    elif [ "$prs" = 0 ]; then s4=0.2; s4note="gh: PR за год 0"; fi
  fi
  # S5 бас-фактор (ecosyste.ms commits)
  local com; com=$(curl -sf --max-time 20 "https://commits.ecosyste.ms/api/v1/hosts/GitHub/repositories/$ENC?mailto=$EMAIL" 2>/dev/null || echo '{}')
  local cy dds; cy=$(jq -r '.past_year_total_committers // empty' <<<"$com"); dds=$(jq -r '.dds // 0' <<<"$com")
  local s5=0.5 s5note="нет данных ecosyste.ms"
  if [ -n "$cy" ]; then
    if [ "$cy" -ge 5 ] && [ "$(echo "$dds >= 0.3" | bc -l)" = 1 ]; then s5=1; elif [ "$cy" -ge 2 ]; then s5=0.5; elif [ "$cy" -ge 1 ]; then s5=0.1; else s5=0; fi
    s5note="коммитеров/год $cy, dds $(printf '%.2f' "$dds")"
  else # fallback: контрибьюторы за всё время + доля топ-1 (gh contributors)
    local contrib; contrib=$(gh api "repos/$R/contributors?per_page=100" 2>/dev/null || echo '[]')
    local n top total; n=$(jq 'length' <<<"$contrib"); top=$(jq '[.[].contributions]|max // 0' <<<"$contrib"); total=$(jq '[.[].contributions]|add // 0' <<<"$contrib")
    if [ "$n" -gt 0 ] && [ "$total" -gt 0 ]; then
      dds=$(printf '%.2f' "$(echo "scale=4; 1 - $top/$total" | bc -l)")
      if [ "$n" -ge 5 ] && [ "$(echo "$dds >= 0.3" | bc -l)" = 1 ]; then s5=1; elif [ "$n" -ge 2 ]; then s5=0.5; else s5=0.1; fi
      s5note="gh: контрибьюторов $n, доля не-топ1 $dds"
    fi
  fi
  # S6 чистота звёзд: недельная история (GitHub, с 04.09.2026) + forks/stars
  local hist; hist=$(gh api "repos/$R/stargazers/history?per_page=30" 2>/dev/null || echo '[]')
  local maxw medw sumw; maxw=$(jq '[.[].total]|max // 0' <<<"$hist"); medw=$(jq '[.[].total]|sort|.[length/2|floor] // 0' <<<"$hist"); sumw=$(jq '[.[].total]|add // 0' <<<"$hist")
  local s6=1 s6note="ровно"
  if [ "$sumw" -gt 0 ]; then
    local ratio; ratio=$(echo "scale=1; $maxw/($medw+1)" | bc -l)
    if [ "$(echo "$ratio > 10" | bc -l)" = 1 ] || [ "$(echo "$maxw*2 > $sumw && $sumw > 50" | bc -l)" = 1 ]; then
      if [ "$(echo "$forks*100 >= $stars" | bc -l)" = 1 ] && [ "$c90" -ge 20 ]; then s6note="⚠ всплеск (макс-неделя $maxw при медиане $medw), но forks ≥1 % и коммиты идут — без штрафа"
      else s6=0.7; s6note="⚠ всплеск: макс-неделя $maxw при медиане $medw"; fi
    else s6note="макс-неделя $maxw, медиана $medw"; fi
  fi
  if [ "$stars" -gt 1000 ] && [ "$(echo "$forks < $stars/100" | bc -l)" = 1 ]; then s6=$(echo "$s6*0.7" | bc -l); s6note="$s6note; forks/stars < 1 %"; fi
  # S9 рост (momentum): звёзды 4 последних недель vs 4 предыдущих (история GitHub),
  # коммиты 90д vs предыдущие 90д, релизов за 180д
  local st_recent st_prev cm_prev rel180 s9=0.5 s9note="нет истории"
  st_recent=$(jq '[.[0:4][].total]|add // 0' <<<"$hist"); st_prev=$(jq '[.[4:8][].total]|add // 0' <<<"$hist")
  local SINCE180; SINCE180=$(date -u -v-180d +%FT%TZ 2>/dev/null || date -u -d '180 days ago' +%FT%TZ)
  cm_prev=$(gh api "search/commits?q=repo:$R+committer-date:${SINCE180%%T*}..${SINCE90%%T*}&per_page=1" --jq .total_count 2>/dev/null) || cm_prev=""
  [ -z "$cm_prev" ] && cm_prev=$(gh api "repos/$R/commits?since=$SINCE180&until=$SINCE90&per_page=100" --jq length 2>/dev/null || echo 0)
  rel180=$(gh api "repos/$R/releases?per_page=30" --jq "[.[]|select(.published_at >= \"$SINCE180\")]|length" 2>/dev/null || echo 0)
  if [ "$(jq length <<<"$hist")" -ge 8 ] || [ "$c90" -gt 0 ] || [ "$cm_prev" -gt 0 ]; then
    local star_tr commit_tr pts=0
    star_tr=$(echo "scale=2; ($st_recent+1)/($st_prev+1)" | bc -l); commit_tr=$(echo "scale=2; ($c90+1)/($cm_prev+1)" | bc -l)
    [ "$(echo "$star_tr >= 1.2" | bc -l)" = 1 ] && pts=$((pts+1)); [ "$(echo "$star_tr < 0.6" | bc -l)" = 1 ] && pts=$((pts-1))
    [ "$(echo "$commit_tr >= 1.2" | bc -l)" = 1 ] && pts=$((pts+1)); [ "$(echo "$commit_tr < 0.6" | bc -l)" = 1 ] && pts=$((pts-1))
    [ "$rel180" -ge 2 ] && pts=$((pts+1))
    if [ $pts -ge 2 ]; then s9=1; elif [ $pts -ge 1 ]; then s9=0.8; elif [ $pts -ge 0 ]; then s9=0.5; elif [ $pts -ge -1 ]; then s9=0.3; else s9=0.1; fi
    local arrow; if [ $pts -ge 1 ]; then arrow="↑"; elif [ $pts -ge 0 ]; then arrow="→"; else arrow="↓"; fi
    s9note="$arrow ★ ${st_recent}/${st_prev} за 4+4 нед, коммиты ${c90}/${cm_prev} за 90+90 дн, релизов/180д $rel180"
  fi
  # S7 Scorecard
  local sc; sc=$(curl -sf --max-time 20 "https://api.securityscorecards.dev/projects/github.com/$R" 2>/dev/null || echo '')
  local scscore="" s7=0.5 w7=0
  if [ -n "$sc" ]; then scscore=$(jq -r '.score // empty' <<<"$sc"); [ -n "$scscore" ] && { s7=$(echo "scale=2; $scscore/10" | bc -l); w7=0.10; }; fi
  # S8 спрос по пакету
  local s8=0.5 s8note="пакет не задан" w8=0
  if [ -n "$PKG" ]; then
    local eco="${PKG%%:*}" name="${PKG#*:}" weekly=""
    case "$eco" in
      npm) weekly=$(curl -sf --max-time 20 "https://api.npmjs.org/downloads/point/last-week/$name" | jq -r '.downloads // empty') ;;
      pypi) # pypistats режет частые запросы (429) — три попытки с паузой
        for try in 1 2 3; do
          weekly=$(curl -sf --max-time 20 -A "liveness.sh ($EMAIL)" "https://pypistats.org/api/packages/$name/recent" | jq -r '.data.last_week // empty')
          [ -n "$weekly" ] && break; sleep $((try*5))
        done
        [ -z "$weekly" ] && s8note="pypistats 429 — повтори позже" ;;
    esac
    if [ -n "$weekly" ] && [ "$weekly" -gt 0 ]; then s8=$(echo "scale=2; x=l($weekly)/l(10)/7; if (x>1) 1 else x" | bc -l); s8note="$weekly/нед"; w8=0.10; elif [ "$s8note" = "пакет не задан" ]; then s8note="скачивания не получены"; fi
  fi
  # Scorecard и спрос часто недоступны (приложения, не пакеты; Scorecard покрывает ~1 млн репо) — тогда их вес перераспределяется
  local total; total=$(echo "scale=2; (0.15*$s1 + 0.15*$s2 + 0.10*$s3 + 0.15*$s4 + 0.15*$s5 + $w7*$s7 + $w8*$s8 + 0.10*$s9) / (0.80 + $w7 + $w8) * $s6" | bc -l)
  local verdict; if [ "$(echo "$total >= 0.7" | bc -l)" = 1 ]; then verdict="живой"; elif [ "$(echo "$total >= 0.4" | bc -l)" = 1 ]; then verdict="на поддержке"; else verdict="мимо"; fi
  [ "$(echo "$s6 < 1" | bc -l)" = 1 ] && verdict="$verdict ⚠"
  jq -nc --arg r "$R" --arg v "$verdict" --argjson total "$total" --arg pushed "${pushed%%T*}" --argjson dp "$dp" --arg archived "$archived" \
    --argjson stars "$stars" --argjson forks "$forks" --argjson c90 "$c90" --arg rel "$relname" --arg reldate "${reldate%%T*}" \
    --argjson s1 "$s1" --argjson s2 "$s2" --argjson s3 "$s3" --argjson s4 "$s4" --arg s4n "$s4note" --argjson s5 "$s5" --arg s5n "$s5note" \
    --argjson s6 "$s6" --arg s6n "$s6note" --argjson s9 "$s9" --arg s9n "$s9note" --argjson s7 "$s7" --arg sc "$scscore" --argjson s8 "$s8" --arg s8n "$s8note" --arg created "${created%%T*}" \
    '{repo:$r,verdict:$v,score:$total,created:$created,pushed:$pushed,days_since_push:$dp,archived:($archived=="true"),stars:$stars,forks:$forks,commits_90d:$c90,release:$rel,release_date:$reldate,
      s1_push:$s1,s2_commits:$s2,s3_release:$s3,s4_pr_response:$s4,s4_note:$s4n,s5_bus_factor:$s5,s5_note:$s5n,s6_star_purity:$s6,s6_note:$s6n,s9_momentum:$s9,s9_note:$s9n,s7_scorecard:$s7,scorecard:$sc,s8_demand:$s8,s8_note:$s8n}'
}

[ ${#REPOS[@]} -gt 1 ] && PKG=""  # глобальный --pkg только для одного репо; для многих — owner/repo=pypi:name
OUT=$(for r in "${REPOS[@]}"; do score_repo "$r"; done)
ERRS=$(echo "$OUT" | jq -s '[.[]|select(.error)]|length')
if [ $JSON = 1 ]; then echo "$OUT" | jq -s .; exit $([ "$ERRS" -gt 0 ] && echo 1 || echo 0); fi
echo "Проверено $(date -u +%F). Score = 0,15·пуш + 0,15·коммиты90д + 0,10·релиз + 0,15·отклик-PR + 0,15·бас-фактор + 0,10·рост (+0,10·Scorecard и +0,10·спрос, когда доступны; иначе веса перенормированы), × чистота звёзд. ≥0,7 живой · 0,4–0,7 на поддержке · <0,4 мимо."
echo
echo "| Репо | Вердикт | Score | Пуш (дн) | Коммиты 90д | Релиз | ★ / forks | Отклик на PR | Бас-фактор | Рост | Звёзды | Scorecard | Спрос |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
echo "$OUT" | jq -r 'if .error then "| \(.repo) | ошибка | — | \(.error) | | | | | | | | | |" else "| \(.repo) | \(.verdict) | \(.score) | \(.pushed) (\(.days_since_push))\(if .archived then " АРХИВ" else "" end) | \(.commits_90d) | \(if .release=="" then "нет" else .release+" "+.release_date end) | \(.stars) / \(.forks) | \(.s4_note) | \(.s5_note) | \(.s9_note) | \(.s6_note) | \(if .scorecard=="" then "нет" else .scorecard end) | \(.s8_note) |" end'
[ "$ERRS" -gt 0 ] && { echo "ошибок: $ERRS из ${#REPOS[@]}" >&2; exit 1; }
exit 0

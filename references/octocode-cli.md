# octocode 19 — шпаргалка (проверено вживую 2026-09-30, CLI 19.1.0)

## Содержание

- Поиск репозиториев
- Поиск кода (как люди реально это вайрят)
- Дерево и файлы без клона
- Лицензия, issues, форки — через gh
- Пакет → репозиторий-источник
- История
- Запасные движки
- CLI или MCP


Пакеты: CLI `octocode`, MCP `octocode-mcp` (скоуп `@octocodeai/mcp` мёртв — там
максимум 18.0.1). Один движок в двух формах: CLI через Bash = те же тулы без
загрузки схем в контекст; MCP `mcp__octocode__*` — когда нужны десятки вызовов
подряд. Токен берётся из `gh` автоматически; проверка `npx octocode status`.
Флаги: `--compact` (минифицированный JSON), `--json`, `tools <name> --scheme`.
Вызывай **`npx octocode@19`** — голый `npx octocode` берёт из кэша 18.4.0.
`npm warn EBADENGINE` про версию node — предупреждение, работает.

В 19.x тулы переименованы: `ghSearchRepos`/`ghSearchCode`/`ghViewRepoStructure`
→ один **`ghSearch`** с обязательным `operation`. Всего 10 тулов: ghSearch,
ghGetFileContent, ghSearchHistory, ghGetHistoryItem, npmSearch, ghCloneRepo,
localSearch, localAnalyzeGraph, localGetFileContent, lspGetSemantics.

## Поиск репозиториев

```bash
npx octocode tools ghSearch --queries '{
  "operation": "repositories",
  "keywords": ["whatsapp", "crm"],
  "updated": ">2026-01-01",
  "stars": ">50",
  "sort": "best-match",
  "pageSize": 8
}' --compact
```

- `keywords` — AND; фраза = один элемент; альтернативы = отдельные запросы.
  Больше 3 слов → пусто.
- `updated` = `pushed:` GitHub → главный фильтр живости (`">2026-01-01"`).
- `stars`, `forks`, `created`, `size` — range-синтаксис `">100"`, `"10..50"`.
- `topics` — все должны совпасть; у большинства репо топиков нет → только в
  паре с keywords или как отдельный угол.
- `match: ["name","description","readme"]` — readme шире и шумнее.
- `sort`: `best-match` (дефолт) · `stars` · `updated` · `forks`.
- `archived` не задан → архивы исключены (то, что надо).
- `license: "mit"` — SPDX id.
- `include: ["contributors","tags"]` — подтягивает списки, +1 вызов на каждый.
- Выдача: owner, repo, stars, forks, openIssuesCount, language, description,
  pushedAt, createdAt, topics, pagination.hasMore. **Лицензии в выдаче нет** —
  её даёт `gh api repos/O/R --jq .license.spdx_id` или `liveness.sh`.
- Выдача толстая (3–5 КБ на запрос), `head -c` режет посередине. Стандартный
  сжиматель:

```bash
... --compact | jq -r '.results[].data.repositories[]? | "\(.owner)/\(.repo) ★\(.stars) f\(.forks) push \(.pushedAt) — \(.description[0:110])"'
```

- Keywords не видят монорепо и переезды (`mlx_whisper` живёт в
  `ml-explore/mlx-examples`, актуальный MLX-STT — `Blaizzy/mlx-audio`).
  Лечится углом «пакет → репо» (ниже) и поиском по имени:
  `gh search repos "mlx-audio" --match name --json fullName,pushedAt,stargazersCount`.
- Литерал с кавычками внутри keyword (`language="kk"`) → пусто. Кавычки
  убирай, литералы ищи через Grep MCP.
- Пусто? Убери фильтр/topic, синоним, меньше слов. «Пусто» ≠ «нет».

## Поиск кода (как люди реально это вайрят)

```bash
npx octocode tools ghSearch --queries '{"operation":"code","keywords":["createShardManager"],"language":"typescript","pageSize":5}' --compact
# внутри одного репо: + "owner":"x","repo":"y"; match: "file" | "path"
```

Альтернатива для литералов и regex по ~1 млн репо — Grep MCP
(`mcp__grep__searchGitHub`, hosted, без ключа; лимиты не опубликованы, при 429 —
пауза).

## Дерево и файлы без клона

```bash
npx octocode tools ghSearch --queries '{"operation":"tree","owner":"x","repo":"y","path":"","maxDepth":2}' --compact
npx octocode tools ghGetFileContent --queries '{"owner":"x","repo":"y","path":"README.md"}' --compact
# срез по якорю: "matchString":"export function foo","contextLines":8
# большой файл: "minify":"symbols" — только outline
```

Формы выдачи (`--compact | jq`):
- дерево: `.results[0].data.structure[] | {dir, files, folders}`; на больших репо
  `meta.diagnostics.partial:true` без указания, что отрезано — ходи по
  подкаталогам отдельно с `maxDepth:1`;
- файл: `.results[0].data.files[0].content` (+ `isPartial`, `totalLines`);
- ⚠ большие деревья и файлы octocode режет МОЛЧА (проверено 30.09: 94 из 274
  файлов каталога, 158 из 536 строк файла, флаг partial не выставлен). Для
  инвентаря каталога — `gh api repos/O/R/contents/PATH --jq '.[].name'`
  (или `--paginate`); для длинного файла — `ghGetFileContent` кусками
  `startLine`/`endLine` по 150 строк или `gh api repos/O/R/contents/PATH
  -H "Accept: application/vnd.github.raw"`;
- код: `.results[0].data.files[] | {repo, path, matches}`.

## Лицензия, issues, форки — через gh

```bash
gh api repos/O/R --jq '.license.spdx_id'   # NOASSERTION ⇒ читай файл LICENSE (openclaw = MIT, gaia = PolyForm NC)
npx octocode@19 tools ghGetFileContent --queries '{"owner":"O","repo":"R","path":"LICENSE","startLine":1,"endLine":5}' --compact
# топ-5 закрытых issue без PR (sort=comments возвращает и PR — фильтруй)
gh api "repos/O/R/issues?state=closed&per_page=40&sort=updated" --jq '[.[]|select(.pull_request==null)][:5]|.[]|"#\(.number) \(.title[0:60]) [\(.comments) комм, закрыт \(.closed_at[0:10])]"'
gh api "repos/O/R/forks?sort=stargazers&per_page=5" --jq '.[]|"\(.full_name) ★\(.stargazers_count) push \(.pushed_at[0:10])"'   # форк-наследник мёртвого гиганта
```

## Пакет → репозиторий-источник

```bash
npx octocode tools npmSearch --queries '{"packageName":"zod"}' --compact
npx octocode tools npmSearch --queries '{"keywords":["schema","validation"],"pageSize":10}' --compact
```

Python: `curl -s https://pypi.org/pypi/<name>/json | jq '.info.project_urls // empty, .info.version // empty'`
(`// empty` обязателен: несуществующий пакет иначе валит jq с exit 5).
Пакет с большими скачиваниями при мёртвом репо — частый случай (mlx-whisper:
88K/нед, репо без коммитов полгода): скачивания ≠ живость, проверь push.
Для ML/аудио/моделей npm-угол — шум (три AWS SDK на «whisper transcribe»);
сразу PyPI + Hugging Face: `curl -s "https://huggingface.co/api/models?search=<lang> <task>&sort=downloads&limit=20" | jq -r '.[]|.id'`.

## История

`ghSearchHistory` — поиск по PR и коммитам; `ghGetHistoryItem` — один PR/коммит.
Полезно для «когда сломали X» и «кто мейнтейнит».

## Запасные движки

- `gh search repos "TERM" --limit 20 --json fullName,stargazersCount,pushedAt,license,isArchived --sort updated`
- `gh api repos/O/R` · `gh api repos/O/R/releases/latest` · `gh repo read-file O/R path`
- Официальный `github-mcp-server` (`https://api.githubcopilot.com/mcp/x/repos/readonly`)
  — если octocode отвалился; ответы толще по токенам.
- Лимиты GitHub Search: 30 запросов/мин на токен, потолок 1000 результатов.

## CLI или MCP

CLI через Bash ≈ 5–8 с на вызов (npx + сеть). До ~20 вызовов за прогон — CLI
(схемы не грузятся в контекст). Больше 20 (чтение 5+ финалистов по 4–6 файлов)
— грузи MCP `mcp__octocode__*` через ToolSearch: те же тулы, без старта
процесса на каждый вызов.

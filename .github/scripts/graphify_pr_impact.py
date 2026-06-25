#!/usr/bin/env python3
"""graphify PR blast-radius.

Reads the list of changed files and the committed graphify-out/graph.json,
then prints a Markdown comment describing what the changed code is connected to
in the knowledge graph — and flags when a high-degree "god node" is touched.

Pure standard library (no graphify install needed). The committed graph reflects
`main`; new files not yet in the graph are reported separately.

Usage: graphify_pr_impact.py <changed_files.txt> <graph.json>
"""
import json
import sys
from collections import defaultdict, Counter

MARKER = "<!-- graphify-blast-radius -->"
CODE_EXT = (
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".sql",
    ".go", ".rs", ".java", ".rb", ".c", ".h", ".cpp", ".vue", ".svelte",
)
GOD_TOP = 25            # top-degree nodes treated as "god nodes"
MAX_FILES_SHOWN = 20    # cap changed-file rows in the comment
MAX_NEIGHBOR_FILES = 8  # cap related files listed per changed file


def norm(p: str) -> str:
    return p.replace("\\", "/").strip().lstrip("./")


def main() -> None:
    if len(sys.argv) < 3:
        print(MARKER)
        print("graphify: usage error (need changed-files list + graph.json).")
        return
    changed_path, graph_path = sys.argv[1], sys.argv[2]

    with open(changed_path, encoding="utf-8") as f:
        changed = [norm(l) for l in f.read().splitlines() if l.strip()]
    changed_code = [c for c in changed if c.lower().endswith(CODE_EXT)]

    with open(graph_path, encoding="utf-8") as f:
        g = json.load(f)
    nodes = g.get("nodes", [])
    links = g.get("links", [])
    id2node = {n["id"]: n for n in nodes}

    file2ids = defaultdict(list)
    for n in nodes:
        sf = n.get("source_file")
        if sf:
            file2ids[norm(sf)].append(n["id"])

    deg = Counter()
    adj = defaultdict(set)
    for l in links:
        s, t = l.get("source"), l.get("target")
        if s is None or t is None:
            continue
        deg[s] += 1
        deg[t] += 1
        adj[s].add(t)
        adj[t].add(s)
    god_ids = {nid for nid, _ in deg.most_common(GOD_TOP)}

    in_graph = [c for c in changed_code if c in file2ids]
    not_in_graph = [c for c in changed_code if c not in file2ids]

    out = [MARKER, "## 🗺️ graphify — карта влияния (blast radius)\n"]
    commit = g.get("built_at_commit")
    note = "Эвристика по графу, **не** замена тестам и ревью."
    if commit:
        out.append(f"_Граф собран на коммите `{commit[:9]}`. {note}_\n")
    else:
        out.append(f"_{note}_\n")

    if not changed_code:
        out.append("Изменённых файлов кода нет — влияние на граф не оценивается.")
        print("\n".join(out))
        return

    # God nodes touched
    touched_god, seen_god = [], set()
    for c in in_graph:
        for nid in file2ids[c]:
            if nid in god_ids and id2node[nid]["label"] not in seen_god:
                seen_god.add(id2node[nid]["label"])
                touched_god.append((deg[nid], id2node[nid]["label"], c))
    touched_god.sort(reverse=True)
    if touched_god:
        out.append("### ⚠️ Затронуты центральные узлы (god nodes)")
        out.append("Высокий риск регрессий — ревьюй особенно внимательно:\n")
        for d, label, c in touched_god:
            out.append(f"- **`{label}`** ({d} связей) — `{c}`")
        out.append("")

    # Per changed file -> related files
    out.append("### Изменённые файлы → что связано в графе")
    shown = 0
    for c in in_graph:
        if shown >= MAX_FILES_SHOWN:
            out.append(f"\n…и ещё {len(in_graph) - shown} файлов.")
            break
        tids = file2ids[c]
        neigh_ids = set()
        for nid in tids:
            neigh_ids |= adj.get(nid, set())
        neigh_ids -= set(tids)
        neigh_files = Counter()
        for nid in neigh_ids:
            sf = id2node.get(nid, {}).get("source_file")
            if sf and norm(sf) != c:
                neigh_files[norm(sf)] += 1
        if neigh_files:
            top = neigh_files.most_common(MAX_NEIGHBOR_FILES)
            files_str = ", ".join(f"`{f}`" for f, _ in top)
            extra = "" if len(neigh_files) <= MAX_NEIGHBOR_FILES else f" (+{len(neigh_files) - MAX_NEIGHBOR_FILES})"
            out.append(
                f"- `{c}` — связано с {len(neigh_ids)} узлами в "
                f"{len(neigh_files)} файлах:{extra}\n  {files_str}"
            )
        else:
            out.append(f"- `{c}` — изолирован в графе (нет связей)")
        shown += 1
    out.append("")

    if not_in_graph:
        out.append("### 🆕 Новые файлы (ещё не в графе)")
        out.append("Граф их пока не знает — появятся после еженедельного рефреша.\n")
        for c in not_in_graph[:MAX_FILES_SHOWN]:
            out.append(f"- `{c}`")
        out.append("")

    print("\n".join(out))


if __name__ == "__main__":
    main()

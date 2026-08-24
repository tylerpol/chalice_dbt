"""Build the schema description handed to the model as context.

The dbt project runs with `persist_docs` enabled, so every table and column
description written in yml is stored in DuckDB as a native comment. Those
comments are the highest-value context available -- they explain grain, units,
and traps that a bare column list cannot. We read them back here rather than
maintaining a second copy of the documentation.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import duckdb

import config


@dataclass
class Column:
    name: str
    data_type: str
    comment: str | None = None


@dataclass
class Table:
    schema: str
    name: str
    kind: str
    comment: str | None = None
    columns: list[Column] = field(default_factory=list)

    @property
    def qualified(self) -> str:
        return f"{self.schema}.{self.name}"


def load_tables(con: duckdb.DuckDBPyConnection) -> list[Table]:
    """Read tables, views, and their persisted comments from the database."""
    placeholders = ", ".join("?" for _ in config.VISIBLE_SCHEMAS)
    params = list(config.VISIBLE_SCHEMAS)

    relations = con.execute(
        f"""
        select schema_name, table_name as name, comment, 'table' as kind
        from duckdb_tables()
        where schema_name in ({placeholders})
        union all
        select schema_name, view_name as name, comment, 'view' as kind
        from duckdb_views()
        where schema_name in ({placeholders}) and not internal
        order by 1, 2
        """,
        params + params,
    ).fetchall()

    columns = con.execute(
        f"""
        select schema_name, table_name, column_name, data_type, comment
        from duckdb_columns()
        where schema_name in ({placeholders})
        order by schema_name, table_name, column_index
        """,
        params,
    ).fetchall()

    by_table: dict[tuple[str, str], list[Column]] = {}
    for schema, table, col, dtype, comment in columns:
        by_table.setdefault((schema, table), []).append(Column(col, dtype, comment))

    return [
        Table(
            schema=schema,
            name=name,
            kind=kind,
            comment=comment,
            columns=by_table.get((schema, name), []),
        )
        for schema, name, comment, kind in relations
    ]


def table_summaries(tables: list[Table]) -> str:
    """A one-line-per-table catalogue: name plus what it holds.

    This is the only thing shown in the scan pass. It is deliberately cheap --
    enough for the model to decide what is relevant, not enough to write SQL.
    """
    lines = []
    for table in sorted(tables, key=lambda t: (t.schema not in config.PREFERRED_SCHEMAS, t.qualified)):
        summary = _first_sentences(table.comment, 150) if table.comment else "(no description)"
        lines.append(f"{table.qualified} -- {summary}")
    return "\n".join(lines)


def derive_joins(tables: list[Table]) -> str:
    """Work out the join graph from the key naming convention, at answer time.

    Nothing here is hand-maintained: the mart convention puts a table's primary
    key first and names it `<entity>_key`, so the table whose *leading* column is
    `X_key` owns `X_key`, and every other table carrying that column holds a
    foreign key to it. Rename or add a model and this map follows automatically.

    The rule alone is sound, but small models apply it inconsistently -- they will
    happily join `line_item_key` to `advertiser_key`. Spelling out the resulting
    edges costs a few lines of prompt and prevents joins that return silently
    wrong results.
    """
    owner: dict[str, Table] = {}
    for table in tables:
        if table.columns and table.columns[0].name.endswith("_key"):
            owner.setdefault(table.columns[0].name, table)

    edges: list[str] = []
    for table in tables:
        primary = table.columns[0].name if table.columns else None
        for column in table.columns:
            if not column.name.endswith("_key") or column.name == primary:
                continue
            target = owner.get(column.name)
            if target and target is not table:
                edges.append(f"{table.qualified}.{column.name} -> {target.qualified}.{column.name}")

    if not edges:
        return "(no key relationships detected)"
    return "\n".join(sorted(edges))


def _join_graph(tables: list[Table]) -> dict[str, set[str]]:
    """Undirected adjacency of tables connected by a shared `_key`."""
    owner: dict[str, str] = {}
    for table in tables:
        if table.columns and table.columns[0].name.endswith("_key"):
            owner.setdefault(table.columns[0].name, table.qualified)

    graph: dict[str, set[str]] = {t.qualified: set() for t in tables}
    for table in tables:
        primary = table.columns[0].name if table.columns else None
        for column in table.columns:
            if not column.name.endswith("_key") or column.name == primary:
                continue
            target = owner.get(column.name)
            if target and target != table.qualified:
                graph[table.qualified].add(target)
                graph[target].add(table.qualified)
    return graph


def expand_for_joins(tables: list[Table], chosen: list[Table]) -> list[Table]:
    """Add any tables needed to connect the chosen ones.

    The model reliably picks the tables holding the columns it wants, but not the
    ones it has to travel *through* -- asked for advertiser spend it picks the
    fact and `dim_advertisers`, omitting the two dimensions between them. Given
    only those two it cannot write a correct join no matter how good the
    instructions are, and tends to invent a direct one that returns zero rows.

    Connecting them is a shortest-path problem with an exact answer, so the app
    solves it rather than asking the model to.
    """
    if len(chosen) < 2:
        return chosen

    graph = _join_graph(tables)
    by_name = {t.qualified: t for t in tables}
    picked = {t.qualified for t in chosen}
    needed = set(picked)

    from collections import deque

    for source in picked:
        for target in picked:
            if source >= target:
                continue
            # BFS for the shortest connecting path between this pair.
            previous: dict[str, str | None] = {source: None}
            queue = deque([source])
            while queue:
                node = queue.popleft()
                if node == target:
                    break
                for neighbour in graph.get(node, ()):
                    if neighbour not in previous:
                        previous[neighbour] = node
                        queue.append(neighbour)
            if target in previous:
                node: str | None = target
                while node is not None:
                    needed.add(node)
                    node = previous[node]

    return [by_name[name] for name in sorted(needed) if name in by_name]


def subset(tables: list[Table], wanted: list[str]) -> list[Table]:
    """Select tables the model asked for, tolerating unqualified or fuzzy names."""
    if not wanted:
        return tables

    by_qualified = {t.qualified.lower(): t for t in tables}
    by_name = {t.name.lower(): t for t in tables}

    chosen: list[Table] = []
    for raw in wanted:
        key = raw.strip().lower().strip('"`')
        match = by_qualified.get(key) or by_name.get(key.split(".")[-1])
        if match and match not in chosen:
            chosen.append(match)

    # A bad pick should degrade to "show everything", never to "show nothing".
    return chosen or tables


def _first_sentences(text: str, limit: int = 240) -> str:
    """Compact a doc block down to something prompt-sized.

    Descriptions come from dbt doc blocks, which are markdown with headings like
    "## What this model contains". Those headings are noise in a prompt and, left
    in, they crowd out the actual sentence -- so drop heading lines and keep the
    prose that follows.
    """
    prose = [line.strip() for line in text.splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    flat = " ".join(" ".join(prose).split())
    if len(flat) <= limit:
        return flat
    return flat[: limit - 1].rsplit(" ", 1)[0] + "…"


def render_for_prompt(tables: list[Table]) -> str:
    """Render the schema as compact text for the model's system prompt."""
    lines: list[str] = []
    for table in sorted(tables, key=lambda t: (t.schema not in config.PREFERRED_SCHEMAS, t.qualified)):
        header = f"{table.qualified}"
        if table.comment:
            header += f" -- {_first_sentences(table.comment)}"
        lines.append(header)
        for column in table.columns:
            entry = f"  {column.name} {column.data_type}"
            if column.comment:
                entry += f" -- {_first_sentences(column.comment, 160)}"
            lines.append(entry)
        lines.append("")
    return "\n".join(lines).strip()

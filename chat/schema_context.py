"""Build the schema description handed to the model as context.

The dbt project runs with `persist_docs` enabled, so every table and column
description written in yml is stored in DuckDB as a native comment. Those
comments are the highest-value context available -- they explain grain, units,
and traps that a bare column list cannot. We read them back here rather than
maintaining a second copy of the documentation.
"""

from __future__ import annotations

import re
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


def derive_column_owners(tables: list[Table]) -> str:
    """State which table owns each non-key column, for the columns in play.

    The column lists in the schema block already say this, but a small model
    reads them as a menu rather than a constraint: asked for revenue by month it
    will happily write `c.reporting_month` against a dimension that has no such
    column, because it attached the filter to the last alias it declared. The
    database rejects that, and the repair pass tends to swap the column name
    rather than the alias, so the second attempt fails the same way.

    Restating ownership as a flat list -- derived here, never hand-maintained --
    turns "which table has this column" from something to infer into something to
    look up. Keys are omitted: the join map already covers those, and repeating
    them crowds out the columns that actually get misplaced.
    """
    owners: dict[str, list[str]] = {}
    for table in tables:
        for column in table.columns:
            if column.name.endswith("_key") or column.name.endswith("_id"):
                continue
            owners.setdefault(column.name, []).append(table.qualified)

    lines = []
    for table in sorted(tables, key=lambda t: (t.schema not in config.PREFERRED_SCHEMAS, t.qualified)):
        unique = [
            c.name for c in table.columns
            if c.name in owners and len(owners[c.name]) == 1
            and not c.name.endswith(("_key", "_id"))
        ]
        if unique:
            lines.append(f"{table.qualified}: {', '.join(unique)}")

    shared = sorted(name for name, holders in owners.items() if len(holders) > 1)
    if shared:
        lines.append(f"on more than one table (qualify carefully): {', '.join(shared)}")

    if not lines:
        return "(no column ownership detected)"
    return "\n".join(lines)


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


_ALIAS_RE = re.compile(
    r"\b(?:from|join)\s+([A-Za-z_][\w]*\.[A-Za-z_][\w]*)\s*(?:\bas\s+)?([A-Za-z_][\w]*)?",
    re.IGNORECASE,
)
_REF_RE = re.compile(r"\b([A-Za-z_][\w]*)\.([A-Za-z_][\w]*)\b")

_SQL_KEYWORDS = {
    "on", "where", "group", "order", "having", "left", "right", "inner", "outer",
    "full", "cross", "join", "select", "and", "or", "as", "using", "limit",
}


def resolve_column_refs(sql: str, tables: list[Table]) -> tuple[str, list[str], list[str]]:
    """Re-qualify columns the model attached to the wrong alias.

    A small model reliably picks the right columns and then hangs them off
    whichever alias it declared most recently -- `d.pacing_ratio` where `d` is the
    fact and `pacing_ratio` lives on the line item dimension. The database
    rejects it, and the repair pass tends to return the identical query, because
    "look up which table owns it" is exactly the inference the model just failed
    to make.

    Deciding where a column belongs is not inference, though: the catalogue says
    so exactly. Where the answer is unambiguous -- the column is unknown on the
    alias it was written against, and exactly one table already in the query owns
    it -- the reference is rewritten. Where it is not (no table in the query has
    the column at all), nothing is changed and a precise message is returned for
    the repair pass, naming the table that does own it.

    Returns (sql, applied_fixes, unresolved_messages).
    """
    by_qualified = {t.qualified.lower(): t for t in tables}
    columns_of = {t.qualified.lower(): {c.name.lower() for c in t.columns} for t in tables}

    # alias -> qualified table, plus the reference to USE when rewriting. A
    # rewrite has to name the alias the query actually declared: emitting the
    # bare table name where an alias exists is still invalid SQL.
    aliases: dict[str, str] = {}
    preferred: dict[str, str] = {}
    for qualified, alias in _ALIAS_RE.findall(sql):
        key = qualified.lower()
        if key not in by_qualified:
            continue
        aliases[key.split(".")[-1]] = key
        aliases[key] = key
        if alias and alias.lower() not in _SQL_KEYWORDS:
            aliases[alias.lower()] = key
            preferred[key] = alias
        else:
            preferred.setdefault(key, qualified)

    # column -> how to reference it, one entry per owning table in this query
    def owners_in_query(column: str) -> list[str]:
        found: list[str] = []
        for qualified in dict.fromkeys(aliases.values()):
            if column in columns_of.get(qualified, ()):
                found.append(preferred[qualified])
        return found

    fixes: list[str] = []
    unresolved: list[str] = []
    missing: dict[str, set[str]] = {}
    invented: dict[str, set[str]] = {}

    def replace(match: re.Match) -> str:
        alias, column = match.group(1), match.group(2)
        akey, ckey = alias.lower(), column.lower()

        # `mart.fct_delivery_daily` matches this pattern too. It is a table
        # reference, not a column reference -- leave it alone.
        if f"{akey}.{ckey}" in by_qualified:
            return match.group(0)

        qualified = aliases.get(akey)
        if qualified is None:
            # An alias that was never declared -- the model reached for a table
            # it imagined ("m" for a markets table that does not exist). If
            # exactly one table already in the query owns the column, that is
            # unambiguously what was meant.
            candidates = owners_in_query(ckey)
            if len(candidates) == 1:
                target = candidates[0]
                fixes.append(f"{alias}.{column} -> {target}.{column} (undeclared alias)")
                return f"{target}.{column}"
            return match.group(0)

        if ckey in columns_of.get(qualified, ()):
            return match.group(0)

        candidates = owners_in_query(ckey)
        if len(candidates) == 1:
            target = candidates[0]
            fixes.append(f"{alias}.{column} -> {target}.{column}")
            return f"{target}.{column}"

        elsewhere = sorted(
            q for q, cols in columns_of.items() if ckey in cols and q not in aliases.values()
        )
        # A label the model wished for. Dimensions here name their natural key
        # `<entity>_id`; some carry an `<entity>_name` and some do not, and the
        # model assumes one exists. Where `<entity>_name` is absent but
        # `<entity>_id` is present on the same table, the id IS the label, so the
        # substitution is derived from the naming convention rather than guessed.
        # Dropping the column instead would leave a pacing table with no way to
        # tell which line item each row describes.
        if ckey.endswith("_name"):
            fallback = ckey[: -len("_name")] + "_id"
            if fallback in columns_of.get(qualified, ()) and ckey not in {
                c for cols in columns_of.values() for c in cols
            }:
                fixes.append(f"{alias}.{column} -> {alias}.{fallback} (no such column; used the natural key)")
                return f"{alias}.{fallback}"

        if elsewhere:
            missing.setdefault(elsewhere[0], set()).add(column)
        else:
            # Invented outright. Naming the table it was written against, with
            # its real columns, turns "that is wrong" into a menu to choose from
            # -- a small model corrects far more reliably from a list than from
            # a description of its mistake. No substitution is guessed here: a
            # plausible wrong column returns confident wrong data, which is worse
            # than an error.
            invented.setdefault(qualified, set()).add(column)
        return match.group(0)

    rewritten = _REF_RE.sub(replace, sql)

    # One message per owning table, not per column. The model over-selects, so a
    # per-column list runs to dozens of near-identical lines -- long enough to
    # crowd out the repair reply and truncate its JSON mid-string.
    for owner_table, cols in sorted(missing.items()):
        names = ", ".join(f"`{c}`" for c in sorted(cols))
        if owner_table:
            unresolved.append(
                f"{names} are on {owner_table}, which your query does not join. "
                f"Drop them, unless the question is actually about {owner_table.split('.')[-1]}."
            )

    for owner_table, cols in sorted(invented.items()):
        names = ", ".join(f"`{c}`" for c in sorted(cols))
        available = ", ".join(c.name for c in by_qualified[owner_table].columns)
        unresolved.append(
            f"{names} do not exist on any table in the database. "
            f"{owner_table} has exactly these columns: {available}. "
            f"Use one of those, or drop the column from the query."
        )

    return rewritten, fixes, unresolved

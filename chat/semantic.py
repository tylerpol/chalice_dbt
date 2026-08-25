"""Compose SQL from the semantic model, instead of asking the model to write it.

The chat assistant reproduces per-row figures correctly and then gets composition
wrong: it invents a `quarter_total` that repeats the monthly figure, and it omits
billing adjustments because they live in a second fact table. Both are structural
problems with an exact answer, so the app solves them.

The model's job here is narrowed to picking measures and dimensions by name --
a classification task -- and the SQL is built from `semantic/measures.yml`. A
measure added to that file becomes answerable with no code change.

Composition rules:
  * Measures are grouped by the fact table they come from, each aggregated at the
    requested dimensions, then UNION ALL'd and re-aggregated. That avoids an
    n-way outer join and gives every source the same row shape.
  * A source that cannot supply a requested dimension is dropped, and its
    measures are reported as unavailable rather than silently returning zero.
  * Dimension labels are looked up once at the end, so a dimension table is never
    joined to a fact before aggregation and cannot fan rows out.
  * Subtotals use GROUPING SETS, which is what the model could not compose.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from itertools import combinations
from pathlib import Path

import yaml

import config

# Lives with the app, not in the dbt project. It is app configuration read only
# by this module, and a `semantic/` directory inside a dbt project reads as
# dbt's own semantic layer (semantic_models / metrics), which this is not.
#
# The cost of that separation is drift -- rename a mart column and the YAML
# breaks. `validate` below closes that by checking every reference against the
# live database, which is a better guard than sitting next to the models was.
_MEASURES = Path(__file__).resolve().parent / "semantic" / "measures.yml"


@dataclass
class Plan:
    measures: list[str] = field(default_factory=list)
    dimensions: list[str] = field(default_factory=list)
    # dimension name -> allowed values. A filter restricts rows without adding a
    # column, which is the distinction the planner otherwise collapses: asked for
    # "CPM line items" it groups BY pricing_model instead of filtering ON it.
    filters: dict[str, list[str]] = field(default_factory=dict)
    months: list[str] = field(default_factory=list)
    totals: bool = False
    order_by: str | None = None
    descending: bool = True
    limit: int | None = None


class SemanticError(Exception):
    """The plan cannot be built from the model as defined."""


def model_path() -> Path | None:
    return _MEASURES if _MEASURES.exists() else None


def validate(model: dict, con) -> list[str]:
    """Check every table and column the semantic model names actually exists.

    The semantic model is the one place that names warehouse columns outside the
    dbt project, so it is the one place that can drift without anything failing
    until a user asks the wrong question. This turns that into a startup check.
    """
    problems: list[str] = []
    known: dict[str, set[str]] = {}
    for schema, table, column in con.execute(
        "select table_schema, table_name, column_name from information_schema.columns"
    ).fetchall():
        known.setdefault(f"{schema}.{table}", set()).add(column)

    for key, source in model.get("sources", {}).items():
        table = source["table"]
        if table not in known:
            problems.append(f"source {key}: table {table} does not exist")

    for dimension in model.get("dimensions", []):
        for key, column in dimension.get("columns", {}).items():
            table = model["sources"].get(key, {}).get("table")
            if table in known and column not in known[table]:
                problems.append(f"dimension {dimension['name']}: {table} has no column {column}")
        lookup = dimension.get("lookup")
        if lookup:
            table = lookup["table"]
            if table not in known:
                problems.append(f"dimension {dimension['name']}: lookup table {table} does not exist")
            else:
                for column in (lookup["key"], lookup["label"]):
                    if column not in known[table]:
                        problems.append(
                            f"dimension {dimension['name']}: {table} has no column {column}"
                        )

    names = {m["name"] for m in model.get("measures", [])}
    for measure in model.get("measures", []):
        if "derived" in measure:
            expression = measure["derived"]
            for operator in "+-*/()":
                expression = expression.replace(operator, " ")
            for part in expression.split():
                if part not in names:
                    problems.append(f"measure {measure['name']}: unknown base measure {part}")
            continue
        table = model["sources"].get(measure["source"], {}).get("table")
        if table not in known:
            continue
        for column in re.findall(r"[A-Za-z_][\w]*", measure["expr"]):
            # `base` is the alias the composer gives the source table. Measures
            # qualify their columns with it so that a lookup joined for a
            # dimension cannot make a column name ambiguous.
            if column in {"sum", "count", "avg", "min", "max", "distinct", "base"}:
                continue
            if column not in known[table]:
                problems.append(f"measure {measure['name']}: {table} has no column {column}")

    return problems


def load() -> dict | None:
    path = model_path()
    if path is None:
        return None
    return yaml.safe_load(path.read_text())


def describe(model: dict) -> str:
    """The measure and dimension menu shown to the model."""
    lines = ["MEASURES (ask for these by name):"]
    for measure in model["measures"]:
        entry = f"  {measure['name']}"
        if measure.get("description"):
            entry += f" -- {' '.join(measure['description'].split())}"
        elif measure.get("label"):
            entry += f" -- {measure['label']}"
        lines.append(entry)
    lines.append("")
    lines.append("DIMENSIONS (group by these):")
    for dimension in model["dimensions"]:
        entry = f"  {dimension['name']}"
        if dimension.get("description"):
            entry += f" -- {' '.join(dimension['description'].split())}"
        elif dimension.get("label"):
            entry += f" -- {dimension['label']}"
        lines.append(entry)
    return "\n".join(lines)


def _by_name(items: list[dict]) -> dict[str, dict]:
    return {item["name"]: item for item in items}


def _resolve_measures(model: dict, wanted: list[str]) -> tuple[list[dict], list[str]]:
    """Expand derived measures into the base measures they need."""
    catalogue = _by_name(model["measures"])
    resolved: list[dict] = []
    derived: list[str] = []
    for name in wanted:
        measure = catalogue.get(name)
        if measure is None:
            continue
        if "derived" in measure:
            derived.append(name)
            expression = measure["derived"]
            for operator in "+-*/()":
                expression = expression.replace(operator, " ")
            for part in expression.split():
                base = catalogue.get(part.strip())
                if base and base not in resolved and "derived" not in base:
                    resolved.append(base)
        elif measure not in resolved:
            resolved.append(measure)
    return resolved, derived


TOTAL_LABEL = "ALL"


def build(model: dict, plan: Plan) -> tuple[str, list[str], list[str]]:
    """Return (sql, notes, dimension_names).

    The dimension names come back so the caller can tell a subtotal row from a
    detail row: with `totals` on, every dimension of a subtotal row carries
    TOTAL_LABEL.
    """
    dimensions = _by_name(model["dimensions"])
    sources = model["sources"]
    notes: list[str] = []

    filters = {k: v for k, v in plan.filters.items() if v}
    if plan.months:
        filters.setdefault("month", plan.months)
    unknown_filters = [f for f in filters if f not in dimensions]
    if unknown_filters:
        raise SemanticError(f"no dimension defined for filter {', '.join(unknown_filters)}")

    # Drop filter values a dimension declares as malformed. The planner reads
    # "as of 2026-06-30" as a month and emits a full date; applied literally that
    # matches nothing and the answer comes back empty with no explanation.
    for name, values in list(filters.items()):
        pattern = dimensions[name].get("value_pattern")
        if not pattern:
            continue
        kept = [v for v in values if re.match(pattern, str(v))]
        if kept != values:
            rejected = [v for v in values if v not in kept]
            notes.append(
                f"ignored {name} filter value(s) {', '.join(map(str, rejected))} "
                f"-- not a valid {name}."
            )
        if kept:
            filters[name] = kept
        else:
            del filters[name]

    # Take dimensions in the order the semantic model declares them, not the
    # order they were requested. That order is the subtotal hierarchy -- entity
    # first, time last -- so a plan naming month before brand still produces one
    # quarter total per brand rather than one cross-brand total per month.
    order = {d["name"]: i for i, d in enumerate(model["dimensions"])}

    # An unknown dimension means the question wants a breakdown this model does
    # not define. Silently dropping it answers a different, coarser question --
    # "adjustments by reason" collapsing to a single total row -- so refuse and
    # let free-form SQL handle it instead.
    unknown = [d for d in plan.dimensions if d not in dimensions]
    if unknown:
        raise SemanticError(f"no dimension defined for {', '.join(unknown)}")

    requested = list(plan.dimensions)
    requested.sort(key=lambda name: order[name])

    # Drop the finer level when two dimensions describe the same entity.
    chosen_dims: list[dict] = []
    groups_taken: dict[str, str] = {}
    for name in requested:
        dimension = dimensions[name]
        group = dimension.get("exclusive_group")
        if group and group in groups_taken:
            notes.append(
                f"{name} was dropped: it is a finer level of the same entity as "
                f"{groups_taken[group]}, and reporting both would split one line into several."
            )
            continue
        if group:
            groups_taken[group] = name
        chosen_dims.append(dimension)

    base_measures, derived_names = _resolve_measures(model, plan.measures)
    if not base_measures:
        raise SemanticError("no known measures requested")

    # The planner over-picks dimensions: asked for pacing by line item it also
    # names brand and campaign, and because the line item table carries no brand
    # that one extra dimension excludes the only source holding the pacing
    # measures -- turning the answer into revenue by brand.
    #
    # The measures are what was actually asked for, so they win. Try every subset
    # of the requested dimensions and keep the one that retains the most
    # measures, breaking ties toward more detail. Small sets, so this is cheap.
    def survivors(dims: list[dict]) -> int:
        sources_ok = {
            key for key in sources if all(key in d["columns"] for d in dims)
        }
        return sum(1 for m in base_measures if m["source"] in sources_ok)

    if chosen_dims and survivors(chosen_dims) < len(base_measures):
        # The finest entity named is the subject of the question and is kept no
        # matter what. Only coarser context dimensions are candidates for removal
        # -- dropping line item from "which line items are pacing worst" would
        # answer a different question than the one asked, however many measures
        # it rescued.
        ranked = [d for d in chosen_dims if d.get("grain_rank")]
        subject = max(ranked, key=lambda d: d["grain_rank"]) if ranked else None
        droppable = [d for d in chosen_dims if d is not subject]

        best = chosen_dims
        best_score = (survivors(chosen_dims), len(chosen_dims))
        for size in range(len(droppable), -1, -1):
            for combination in combinations(droppable, size):
                candidate = [d for d in chosen_dims if d is subject or d in combination]
                score = (survivors(candidate), len(candidate))
                if score > best_score:
                    best, best_score = candidate, score
        if len(best) < len(chosen_dims):
            removed = [d["name"] for d in chosen_dims if d not in best]
            notes.append(
                f"grouped without {', '.join(removed)}: the measures asked for are "
                f"not available at that level of detail."
            )
            chosen_dims = best

    # A source must be able to supply every grouped dimension -- a missing one
    # cannot be grouped correctly, so the source is out.
    #
    # Filters are different. They are applied per source, wherever the source
    # carries the dimension, and reported where it does not. Excluding a source
    # over an inapplicable filter is what killed "CPM line items pacing worst":
    # pacing has no month grain, so a stray month filter removed the only source
    # holding the pacing measures and the whole answer collapsed.
    usable = {
        key for key in sources
        if all(key in dim["columns"] for dim in chosen_dims)
    }
    dropped = [m["name"] for m in base_measures if m["source"] not in usable]
    if dropped:
        notes.append(
            f"{', '.join(dropped)} could not be included: "
            f"not available at this level of detail."
        )
    base_measures = [m for m in base_measures if m["source"] in usable]
    if not base_measures:
        raise SemanticError("no measures survive the requested dimensions")

    measure_names = [m["name"] for m in base_measures]

    # A derived measure is only computable if every base it needs survived. Left
    # in, its expression references a column that was never selected and the
    # whole query fails to bind.
    catalogue_all = _by_name(model["measures"])
    still_derivable = []
    for name in derived_names:
        expression = catalogue_all[name]["derived"]
        for operator in "+-*/()":
            expression = expression.replace(operator, " ")
        if all(part in measure_names for part in expression.split()):
            still_derivable.append(name)
        else:
            notes.append(f"{name} could not be computed: it needs measures unavailable here.")
    derived_names = still_derivable
    if not measure_names and not derived_names:
        raise SemanticError("no measures survive the requested dimensions")
    used_sources = [s for s in sources if any(m["source"] == s for m in base_measures)]

    # One aggregate per source, same column shape, then union.
    #
    # Lookups are joined INSIDE each source block and grouped by the label, not
    # by the key. Grouping by the key and labelling afterwards looks equivalent
    # and is not: several campaign keys share one market, so a key-grouped query
    # returns a row per campaign wearing a market's name. Joining a dimension on
    # its own primary key is one-to-one, so this cannot fan rows out.
    blocks = []
    unapplied: set[tuple[str, str]] = set()
    for source_key in used_sources:
        table = sources[source_key]["table"]
        select, joins, group_terms = [], [], []
        for index, dim in enumerate(chosen_dims):
            column = dim["columns"][source_key]
            lookup = dim.get("lookup")
            if lookup:
                alias = f"lk{index}"
                expression = f"{alias}.{lookup['label']}"
                joins.append(
                    f"        left join {lookup['table']} as {alias}\n"
                    f"            on base.{column} = {alias}.{lookup['key']}"
                )
            else:
                expression = f"base.{column}"
            select.append(f"        {expression} as {dim['name']}")
            group_terms.append(expression)
        for measure in base_measures:
            if measure["source"] == source_key:
                select.append(f"        {measure['expr']} as {measure['name']}")
            else:
                select.append(f"        cast(0 as decimal(18, 6)) as {measure['name']}")
        where_terms = []
        for name, values in filters.items():
            dimension = dimensions[name]
            if source_key not in dimension["columns"]:
                unapplied.add((name, source_key))
                continue
            column = dimension["columns"][source_key]
            lookup = dimension.get("lookup")
            if lookup:
                # Filter on the label, matching what the user named. The lookup
                # may already be joined for grouping; reuse that alias if so.
                if dimension in chosen_dims:
                    target = f"lk{chosen_dims.index(dimension)}.{lookup['label']}"
                else:
                    alias = f"fk{len(joins)}"
                    joins.append(
                        f"        left join {lookup['table']} as {alias}\n"
                        f"            on base.{column} = {alias}.{lookup['key']}"
                    )
                    target = f"{alias}.{lookup['label']}"
            else:
                target = f"base.{column}"
            literals = ", ".join("'" + str(v).replace("'", "''") + "'" for v in values)
            where_terms.append(f"{target} in ({literals})")
        where = ("\n        where " + "\n          and ".join(where_terms)) if where_terms else ""
        group = ("\n        group by " + ", ".join(group_terms)) if group_terms else ""
        join_sql = ("\n" + "\n".join(joins)) if joins else ""
        blocks.append(
            "    select\n" + ",\n".join(select)
            + f"\n    from {table} as base{join_sql}{where}{group}"
        )

    union = "\n\n    union all\n\n".join(blocks)

    for name, source_key in sorted(unapplied):
        notes.append(
            f"the {name} filter does not apply to {sources[source_key]['table']} "
            f"({sources[source_key]['grain'].strip().splitlines()[0]}), so it was not used there."
        )

    names = [d["name"] for d in chosen_dims]
    agg_select = [f"        {n}" for n in names]
    agg_select += [f"        sum({n}) as {n}" for n in measure_names]
    if plan.totals and names:
        sets = []
        for depth in range(len(names), -1, -1):
            sets.append("(" + ", ".join(names[:depth]) + ")" if depth else "()")
        group_clause = "group by grouping sets (" + ", ".join(sets) + ")"
        agg_select += [f"        grouping({n}) as {n}_is_total" for n in names]
    else:
        group_clause = ("group by " + ", ".join(names)) if names else ""
    combined = (
        "    select\n" + ",\n".join(agg_select) + "\n    from unioned\n    " + group_clause
    )

    catalogue = _by_name(model["measures"])
    final_select = []
    for dim in chosen_dims:
        name = dim["name"]
        null_label = (dim.get("lookup") or {}).get("null_label")
        expression = f"cast({name} as varchar)"
        if null_label:
            expression = f"coalesce({expression}, '{null_label}')"
        if plan.totals:
            expression = f"case when {name}_is_total = 1 then 'ALL' else {expression} end"
        final_select.append(f"    {expression} as {name}")
    for name in measure_names:
        final_select.append(f"    round({name}, 2) as {name}")
    for name in derived_names:
        expression = catalogue[name]["derived"]
        if "/" in expression:
            numerator, denominator = (part.strip() for part in expression.split("/", 1))
            expression = f"{numerator} / nullif({denominator}, 0)"
            final_select.append(f"    round({expression}, 4) as {name}")
        else:
            final_select.append(f"    round({expression}, 2) as {name}")

    order_sql = ""
    if plan.order_by and (plan.order_by in measure_names or plan.order_by in derived_names):
        # A measure may declare which end of it is interesting. Where it does,
        # that wins over the planner's guess at direction.
        declared = catalogue.get(plan.order_by, {}).get("sort")
        direction = declared if declared in {"asc", "desc"} else (
            "desc" if plan.descending else "asc"
        )
        order_sql = f"\norder by {plan.order_by} {direction}"
    elif names:
        parts = [f"{n}_is_total" for n in names] if plan.totals else []
        parts += names
        order_sql = "\norder by " + ", ".join(parts)
    limit_sql = f"\nlimit {int(plan.limit)}" if plan.limit else ""

    sql = (
        "with unioned as (\n" + union + "\n),\n\n"
        "combined as (\n" + combined + "\n)\n\n"
        "select\n" + ",\n".join(final_select) + "\nfrom combined"
        + order_sql + limit_sql
    )
    return sql, notes, names

"""Chalice Chat -- ask the advertising warehouse questions in plain English.

Runs entirely on your machine: a local Ollama model writes the SQL, DuckDB runs
it read-only, and this app renders the result. Nothing is sent anywhere.
"""

from __future__ import annotations

import duckdb
import pandas as pd
import streamlit as st

import charts
import config
import llm
import schema_context
import semantic
from sql_guard import UnsafeSQL, check as check_sql

st.set_page_config(page_title=config.APP_TITLE, page_icon="🍷", layout="wide")

EXAMPLES = [
    "Show daily impressions over time",
    "Which advertiser had the most media spend?",
    "Total media cost by market",
    "Show clicks and impressions by campaign as a table",
    "What are the billing adjustments by reason?",
    "Show me spend by billing month",
]


@st.cache_resource(show_spinner=False)
def get_connection() -> duckdb.DuckDBPyConnection:
    """One read-only connection for the session.

    Read-only matters twice over: the model cannot be talked into mutating the
    warehouse, and DuckDB's single-writer lock stays free for `dbt build`.
    """
    return duckdb.connect(str(config.database_path()), read_only=True)


@st.cache_data(show_spinner=False)
def get_catalogue() -> tuple[str, int]:
    """The lightweight table list used for the scan pass."""
    tables = schema_context.load_tables(get_connection())
    return schema_context.table_summaries(tables), len(tables)


def columns_for(wanted: list[str]) -> tuple[str, str, str, list[str]]:
    """Column detail, the derived join map, and column ownership for the picked tables."""
    tables = schema_context.load_tables(get_connection())
    chosen = schema_context.expand_for_joins(tables, schema_context.subset(tables, wanted))
    return (
        schema_context.render_for_prompt(chosen),
        schema_context.derive_joins(tables),
        schema_context.derive_column_owners(chosen),
        [t.qualified for t in chosen],
    )


def render_sidebar(model_ready: bool, model_status: str, table_count: int) -> None:
    with st.sidebar:
        st.subheader("Status")
        st.write(f"**Model** · `{config.MODEL}`")
        (st.success if model_ready else st.error)(model_status)
        st.write(f"**Database** · `{config.database_path().name}`")
        st.caption(f"{table_count} tables and views · opened read-only")

        # The semantic model names warehouse columns from outside the dbt
        # project, so it is the one thing here that can drift silently. Check it
        # against the live database on load and say so plainly if it has.
        model = semantic.load()
        if model is None:
            st.warning("No semantic model found; every question uses free-form SQL.")
        else:
            problems = semantic.validate(model, get_connection())
            if problems:
                st.error(f"Semantic model is out of date ({len(problems)} problems)")
                with st.expander("What drifted"):
                    for problem in problems:
                        st.write(f"- {problem}")
            else:
                measures = len(model.get("measures", []))
                dimensions = len(model.get("dimensions", []))
                st.success(f"Semantic model · {measures} measures, {dimensions} dimensions")

        st.divider()
        st.subheader("Try asking")
        for example in EXAMPLES:
            if st.button(example, key=f"ex_{example}", width="stretch"):
                st.session_state.pending = example
                st.rerun()

        st.divider()
        if st.button("Clear conversation", width="stretch"):
            st.session_state.history = []
            st.rerun()

        with st.expander("Tables the model can see"):
            st.code(get_catalogue()[0], language="text")
        with st.expander("Analyst guidance (AGENTS.md)"):
            st.caption("Edit chat/AGENTS.md to change behaviour — reloaded each question.")
            st.markdown(llm.guidance())


def run_query(sql: str) -> pd.DataFrame:
    safe = check_sql(sql)
    return get_connection().execute(safe).fetch_df().head(config.MAX_ROWS)


def render_turn(turn: dict, index: int) -> None:
    """Render one completed exchange.

    `index` keys the widgets. Streamlit derives an element id from type plus
    parameters, so replaying two turns that produced identical charts collides.
    Asking the same question twice is normal here, so the key has to come from
    the turn's position rather than its content.
    """
    with st.chat_message("user"):
        st.write(turn["question"])

    with st.chat_message("assistant"):
        if turn.get("error"):
            st.error(turn["error"])
            if turn.get("sql"):
                with st.expander("Generated SQL"):
                    st.code(turn["sql"], language="sql")
            return

        st.markdown(f"**{turn['title']}**")
        if turn.get("explanation"):
            st.caption(turn["explanation"])
        if turn.get("repaired"):
            st.caption("↻ The first query errored; this is the model's corrected attempt.")

        if turn.get("fallback"):
            st.info(turn["fallback"])

        if turn.get("figure") is not None:
            st.plotly_chart(turn["figure"], key=f"chart_{index}")

        df: pd.DataFrame = turn["df"]
        if turn.get("figure") is None:
            st.dataframe(df, hide_index=True, key=f"df_{index}")
        else:
            with st.expander(f"Data ({len(df):,} rows)"):
                st.dataframe(df, hide_index=True, key=f"df_{index}")

        # Always visible, never buried: a small model will sometimes write
        # plausible-looking SQL that answers a subtly different question.
        with st.expander("Generated SQL — check this before trusting the answer"):
            st.code(turn["sql"], language="sql")


def answer(question: str, catalogue: str) -> dict:
    turn: dict = {"question": question}

    # Semantic path first. Where the question maps onto defined measures, the
    # application composes the SQL and the model only names what it wants --
    # which removes the two things it gets wrong: multi-fact composition and
    # subtotals. Anything not covered falls through to free-form SQL below.
    model = semantic.load()
    if model is not None:
        try:
            raw_plan = llm.plan(question, semantic.describe(model))
        except Exception:  # noqa: BLE001 - a failed plan is recoverable
            raw_plan = None
        if raw_plan and raw_plan.get("answerable") and raw_plan.get("measures"):
            try:
                sql, notes, dimension_names = semantic.build(
                    model,
                    semantic.Plan(
                        measures=raw_plan.get("measures", []),
                        dimensions=raw_plan.get("dimensions", []),
                        filters={
                            f["dimension"]: f["values"]
                            for f in raw_plan.get("filters", [])
                            if f.get("dimension") and f.get("values")
                        },
                        months=raw_plan.get("months", []),
                        totals=bool(raw_plan.get("totals")),
                        order_by=(raw_plan.get("order_by") or None),
                        descending=bool(raw_plan.get("descending", True)),
                        limit=raw_plan.get("limit") or None,
                    ),
                )
                df = run_query(sql)

                # Chart the detail rows only. A GROUPING SETS result carries its
                # own subtotals, and the grand total is an order of magnitude
                # larger than any month -- plotted together it flattens every
                # real bar to a sliver. The totals stay in the table below,
                # where they are the point of asking for them.
                chart_df = df
                total_columns = [c for c in dimension_names if c in df.columns]
                if raw_plan.get("totals") and total_columns:
                    is_detail = ~(df[total_columns] == semantic.TOTAL_LABEL).any(axis=1)
                    if is_detail.any():
                        chart_df = df[is_detail]

                # Ranked results come back ordered by the measure, which leaves a
                # time axis out of sequence and draws a zig-zag. Sort the plotted
                # copy by the time dimension; the table keeps the ranked order.
                x_axis = raw_plan.get("x")
                if (
                    raw_plan.get("chart_type") in {"line", "area"}
                    and x_axis in chart_df.columns
                    and x_axis in dimension_names
                ):
                    chart_df = chart_df.sort_values(x_axis)

                # Break the plot into one series per remaining dimension value.
                # With brand and month both grouped, a single line walks through
                # every brand in turn and means nothing -- the reader needs a
                # line per brand. Only when exactly one dimension is left over,
                # since with two there is no unambiguous choice of series.
                series = None
                if raw_plan.get("chart_type") in {
                    "line", "area", "bar", "horizontal_bar", "scatter"
                }:
                    remaining = [
                        d for d in dimension_names
                        if d in chart_df.columns and d != x_axis
                    ]
                    if len(remaining) == 1:
                        series = remaining[0]

                figure, fallback = charts.build(
                    chart_df,
                    raw_plan.get("chart_type", "table"),
                    raw_plan.get("x") or None,
                    raw_plan.get("y") or None,
                    series,
                    raw_plan.get("title", "Result"),
                )
                explanation = raw_plan.get("explanation", "")
                if notes:
                    explanation = (explanation + " " + " ".join(notes)).strip()
                turn.update(
                    sql=sql,
                    title=raw_plan.get("title", "Result"),
                    explanation=explanation,
                    df=df,
                    figure=figure,
                    fallback=fallback,
                    semantic=True,
                )
                return turn
            except (semantic.SemanticError, UnsafeSQL):
                pass  # not expressible as measures -- fall through
            except Exception:  # noqa: BLE001
                pass

    # Pass 1: let the model scan the catalogue and pick what it needs.
    try:
        wanted = llm.scan(question, catalogue)
    except llm.ModelUnavailable as exc:
        turn["error"] = f"Could not reach the model: {exc}"
        return turn
    except Exception:  # noqa: BLE001 - a failed scan is recoverable
        wanted = []

    schema, joins, columns, used = columns_for(wanted)
    turn["tables_used"] = used

    # Pass 2: write the query against those tables' columns.
    try:
        spec = llm.ask(question, schema, joins, columns, st.session_state.history)
    except llm.ModelUnavailable as exc:
        turn["error"] = f"Could not reach the model: {exc}"
        return turn
    except Exception as exc:  # noqa: BLE001
        turn["error"] = f"The model returned something unusable: {exc}"
        return turn

    # Before executing, re-qualify any column hung off the wrong alias. The model
    # picks the right columns and then attaches them to whichever table it
    # aliased last; which table owns a column is a lookup, not a judgement call,
    # so the app settles it rather than spending a repair round on it.
    fixed_sql, applied, unresolved = schema_context.resolve_column_refs(
        spec.sql, schema_context.load_tables(get_connection())
    )
    if applied:
        spec.sql = fixed_sql
        turn["column_fixes"] = applied

    turn.update(
        sql=spec.sql,
        title=spec.title,
        explanation=spec.explanation,
    )

    try:
        df = run_query(spec.sql)
    except UnsafeSQL as exc:
        # A refusal is a policy decision, not a mistake to retry.
        turn["error"] = str(exc)
        return turn
    except Exception as exc:  # noqa: BLE001
        # Database errors are specific and actionable ("column X not found in
        # table Y"), so hand the model its own error and let it correct once.
        first_error = str(exc)
        # A column that belongs to a table the query never joined cannot be
        # re-qualified, but we know exactly where it lives -- say so, rather than
        # handing over DuckDB's "Candidate bindings" guess, which sends the model
        # looking for a similarly named column on the same wrong table.
        if unresolved:
            first_error = first_error + "\n\n" + "\n".join(unresolved)
        try:
            spec = llm.repair(question, schema, spec.sql, first_error, joins, columns)
            df = run_query(spec.sql)
            turn.update(
                sql=spec.sql,
                title=spec.title,
                explanation=spec.explanation,
                repaired=True,
            )
        except UnsafeSQL as retry_exc:
            turn["error"] = str(retry_exc)
            return turn
        except Exception as retry_exc:  # noqa: BLE001
            turn["sql"] = spec.sql
            turn["error"] = (
                f"The query failed, and the retry also failed.\n\n"
                f"First error: {first_error}\n\nRetry error: {retry_exc}"
            )
            return turn

    figure, fallback = charts.build(df, spec.chart_type, spec.x, spec.y, spec.color, spec.title)
    turn.update(df=df, figure=figure, fallback=fallback)
    return turn


def main() -> None:
    st.title("🍷 Chalice Chat")
    st.caption("Ask about the advertising warehouse in plain English. Everything runs locally.")

    if not config.database_exists():
        st.error(
            f"No database found at `{config.database_path()}`.\n\n"
            "Build it with `dbt build` from the dbt project directory, or use the "
            "copy shipped alongside this app."
        )
        st.stop()

    model_ready, model_status = llm.check_ready()

    try:
        catalogue, table_count = get_catalogue()
    except Exception as exc:  # noqa: BLE001
        st.error(
            f"Could not read the database: {exc}\n\n"
            "If another program (a SQL IDE) has it open for writing, close that "
            "connection and reload."
        )
        st.stop()

    render_sidebar(model_ready, model_status, table_count)

    st.session_state.setdefault("history", [])
    st.session_state.setdefault("pending", None)

    for index, turn in enumerate(st.session_state.history):
        render_turn(turn, index)

    if not model_ready:
        st.warning(model_status)

    typed = st.chat_input("Ask a question about the data…", disabled=not model_ready)
    question = typed or st.session_state.pending
    st.session_state.pending = None

    if question:
        with st.chat_message("user"):
            st.write(question)
        with st.chat_message("assistant"), st.spinner("Thinking…"):
            turn = answer(question, catalogue)
        st.session_state.history.append(turn)
        st.rerun()


if __name__ == "__main__":
    main()

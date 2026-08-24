"""Render a chart spec against a dataframe.

The model chooses a chart type and axes; this module decides whether that choice
is actually renderable and falls back to a table when it is not. A wrong chart is
worse than no chart, so every fallback returns a reason the app can show.
"""

from __future__ import annotations

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go

_TEMPLATE = "plotly_white"


def _valid(df: pd.DataFrame, column: str | None) -> bool:
    return bool(column) and column in df.columns


def build(df: pd.DataFrame, chart_type: str, x: str | None, y: str | None,
          color: str | None, title: str) -> tuple[go.Figure | None, str | None]:
    """Return (figure, fallback_reason). A None figure means render a table."""
    if chart_type == "table":
        return None, None

    if df.empty:
        return None, "The query returned no rows."

    # The model sometimes names axes by expression ("SUM(cost)") or by qualified
    # name ("c.market") rather than by the output column. Rather than drop to a
    # table, recover the obvious intent: first non-numeric column is the
    # category, first numeric column is the measure.
    note = None
    if not _valid(df, x) or not _valid(df, y):
        numeric = [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c])]
        other = [c for c in df.columns if c not in numeric]
        guess_x = (other or list(df.columns))[0] if len(df.columns) >= 2 else None
        guess_y = next((c for c in numeric if c != guess_x), None)
        if guess_x and guess_y:
            x, y = guess_x, guess_y
            note = f"Axes inferred from the result ({x} vs {y})."
        else:
            return None, (
                f"The model chose {chart_type} but named axis column(s) that are not "
                f"in the result ({x!r}, {y!r}). Showing the table instead."
            )

    if not pd.api.types.is_numeric_dtype(df[y]):
        return None, f"Column '{y}' is not numeric, so it cannot be plotted on the y axis."

    plot_color = color if _valid(df, color) else None
    common = {"title": title, "template": _TEMPLATE}

    try:
        if chart_type == "line":
            fig = px.line(df, x=x, y=y, color=plot_color, markers=len(df) <= 60, **common)
        elif chart_type == "area":
            fig = px.area(df, x=x, y=y, color=plot_color, **common)
        elif chart_type == "bar":
            fig = px.bar(df, x=x, y=y, color=plot_color, **common)
        elif chart_type == "horizontal_bar":
            fig = px.bar(df, x=y, y=x, color=plot_color, orientation="h", **common)
        elif chart_type == "scatter":
            fig = px.scatter(df, x=x, y=y, color=plot_color, **common)
        elif chart_type == "pie":
            if len(df) > 12:
                return None, "Too many categories for a readable pie chart; showing the table."
            fig = px.pie(df, names=x, values=y, title=title, template=_TEMPLATE)
        else:
            return None, f"Unknown chart type '{chart_type}'."
    except Exception as exc:  # noqa: BLE001 - never let a plot failure kill the answer
        return None, f"Could not render the chart ({exc}). Showing the table instead."

    fig.update_layout(margin={"l": 10, "r": 10, "t": 50, "b": 10}, height=420)
    return fig, note

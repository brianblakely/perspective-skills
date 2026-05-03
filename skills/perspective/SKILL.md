---
name: perspective
description: Build browser data visualizations, dashboards, and interactive analytics with Perspective. Use when implementing Perspective.js, perspective-viewer, @perspective-dev/react, streaming tables, WebAssembly bootstrapping, or browser BI-style data grids/charts. Prefer @perspective-dev/react in React projects.
license: MIT
---

# Perspective browser datavis skill

Use this skill when adding, debugging, or refactoring browser-based data visualization with Perspective.

Perspective is best for interactive analytics over tabular, Arrow, or streaming data where users need pivoting, grouping, filtering, sorting, charting, and data-grid exploration.

## Package selection

Before coding, inspect the project:

- If `package.json` includes `react`, `react-dom`, Next.js, Remix, Gatsby, Vite React, or other React app structure, prefer `@perspective-dev/react`.
- Otherwise use the framework-agnostic `<perspective-viewer>` Custom Element from `@perspective-dev/viewer`.
- Use current package names:
  - `@perspective-dev/client`
  - `@perspective-dev/server`
  - `@perspective-dev/viewer`
  - `@perspective-dev/viewer-datagrid`
  - `@perspective-dev/viewer-charts`
  - `@perspective-dev/workspace` when multi-view layouts are needed
  - `@perspective-dev/react` for React bindings
- Do not introduce legacy `@finos/*` Perspective packages unless the existing project is pinned to pre-4.x Perspective and the user explicitly wants to keep that version line.

## Install dependencies

For a React browser project, add at least:

```bash
npm install @perspective-dev/client @perspective-dev/server @perspective-dev/viewer @perspective-dev/viewer-datagrid @perspective-dev/viewer-charts @perspective-dev/react
```

For non-React browser projects, add at least:

```bash
npm install @perspective-dev/client @perspective-dev/server @perspective-dev/viewer @perspective-dev/viewer-datagrid @perspective-dev/viewer-charts
```

Add `@perspective-dev/workspace` only when the requested UI needs multiple coordinated viewers or saved layouts.

## WebAssembly bootstrapping

Perspective browser ESM builds require explicit WASM bootstrapping. Do this once, near app startup or in a dedicated Perspective setup module.

For Vite-style bundlers:

```ts
import perspective from "@perspective-dev/client";
import perspective_viewer from "@perspective-dev/viewer";

import SERVER_WASM from "@perspective-dev/server/dist/wasm/perspective-server.wasm?url";
import CLIENT_WASM from "@perspective-dev/viewer/dist/wasm/perspective-viewer.wasm?url";

export async function initPerspective() {
  await Promise.all([
    perspective.init_server(fetch(SERVER_WASM)),
    perspective_viewer.init_client(fetch(CLIENT_WASM)),
  ]);
}
```

For Webpack or bundlers that import assets directly, adapt the WASM imports to the project’s asset-loader convention.

If using Vite, ensure the build target supports modern output:

```ts
// vite.config.ts
import { defineConfig } from "vite";

export default defineConfig({
  build: {
    target: "esnext",
  },
});
```

Avoid deprecated inline builds unless the existing project already depends on them and changing the bundler setup is out of scope.

## React default pattern

In React projects, use `PerspectiveViewer` from `@perspective-dev/react` instead of rendering `<perspective-viewer>` directly.

A robust React implementation should:

1. Bootstrap Perspective before rendering viewers or before creating tables.
2. Create a single browser worker with `perspective.worker()`.
3. Create tables from Arrow buffers, arrays of objects, or schemas.
4. Pass a `Table`, `Promise<Table>`, or worker-backed client to `PerspectiveViewer`.
5. Delete tables on unmount when the component owns them.
6. Keep viewer config in React state when the app needs to persist or react to user changes.

Typical component shape:

```tsx
import * as React from "react";
import perspective from "@perspective-dev/client";
import { PerspectiveViewer } from "@perspective-dev/react";

import "@perspective-dev/viewer";
import "@perspective-dev/viewer-datagrid";
import "@perspective-dev/viewer-charts";
import "@perspective-dev/viewer/dist/css/themes.css";

import { initPerspective } from "./initPerspective";

type Row = {
  timestamp: string;
  category: string;
  value: number;
};

export function AnalyticsViewer({ rows }: { rows: Row[] }) {
  const [table, setTable] = React.useState<unknown | null>(null);

  React.useEffect(() => {
    let disposed = false;
    let ownedTable: any;

    async function run() {
      await initPerspective();

      const worker = await perspective.worker();
      ownedTable = await worker.table(rows);

      if (!disposed) {
        setTable(ownedTable);
      } else {
        await ownedTable.delete({ lazy: true });
      }
    }

    run();

    return () => {
      disposed = true;
      setTable(null);
      ownedTable?.delete?.({ lazy: true });
    };
  }, [rows]);

  if (!table) return null;

  return (
    <PerspectiveViewer
      client={table as any}
      config={{
        group_by: ["category"],
        columns: ["value"],
        plugin: "Datagrid",
      }}
      style={{ height: "600px", width: "100%" }}
    />
  );
}
```

Prefer project-specific typing over `any` when the local Perspective package exports the required types cleanly.

## React workspace pattern

Use `PerspectiveWorkspace` only for multi-view dashboards.

```tsx
import { PerspectiveWorkspace } from "@perspective-dev/react";
import "@perspective-dev/workspace";
import "@perspective-dev/workspace/dist/css/pro.css";

<PerspectiveWorkspace
  client={worker}
  layout={layout}
  onLayoutUpdate={setLayout}
/>;
```

Use a workspace when the user asks for dashboards with multiple panels, saved layouts, linked views, or a BI workspace. Use a single `PerspectiveViewer` for one chart/grid.

## Non-React browser pattern

For non-React apps, import the Custom Element and plugins once:

```ts
import perspective from "@perspective-dev/client";
import "@perspective-dev/viewer";
import "@perspective-dev/viewer-datagrid";
import "@perspective-dev/viewer-charts";
import "@perspective-dev/viewer/dist/css/themes.css";

import { initPerspective } from "./initPerspective";

export async function mountPerspectiveViewer(
  container: HTMLElement,
  rows: Array<Record<string, unknown>>,
) {
  await initPerspective();

  const worker = await perspective.worker();
  const table = await worker.table(rows);

  const viewer = document.createElement("perspective-viewer") as any;
  viewer.style.height = "600px";
  viewer.style.width = "100%";

  container.appendChild(viewer);

  await viewer.load(table);
  await viewer.restore({
    group_by: [],
    columns: Object.keys(rows[0] ?? {}),
    plugin: "Datagrid",
  });

  return {
    viewer,
    table,
    dispose: async () => {
      viewer.remove();
      await table.delete({ lazy: true });
    },
  };
}
```

Remember that `<perspective-viewer>` methods are async.

## Data handling rules

- Prefer Apache Arrow for large datasets or server-provided tabular data.
- Use arrays of objects for small to moderate client-side datasets.
- For streaming updates, create the table once and call `table.update(newRows)` rather than replacing the viewer.
- Do not serialize large datasets into React state. Keep only table handles, config, loading state, and lightweight metadata in React state.
- For live feeds, batch updates and throttle UI-affecting state changes.
- When data shape is known, define an explicit schema instead of relying on inference.

## Viewer configuration rules

Use Perspective config for user-facing defaults:

```ts
const config = {
  plugin: "Datagrid",
  columns: ["sales", "profit"],
  group_by: ["region"],
  split_by: [],
  sort: [["sales", "desc"]],
  filter: [["sales", ">", 0]],
};
```

Choose defaults based on the user’s task:

- Tabular exploration: `plugin: "Datagrid"`
- Trend over time: line chart with a timestamp/date column
- Category comparison: bar chart
- Distribution/correlation: scatter or heatmap where appropriate
- Geographic visualization: only if the project already includes a compatible map/plugin setup

Do not hard-code config that hides important columns unless the user asked for a narrow view.

## Events and persistence

In React, use component callbacks such as:

```tsx
<PerspectiveViewer
  client={table}
  config={config}
  onConfigUpdate={(nextConfig) => setConfig(nextConfig)}
  onClick={(detail) => console.log(detail)}
  onSelect={(detail) => console.log(detail)}
/>
```

Persist config or workspace layout only when the app already has a persistence layer or the user requests saved dashboards.

## Styling

- Import Perspective theme CSS once.
- Give the viewer an explicit height; invisible or collapsed viewers are commonly caused by missing layout height.
- In React, pass `className` or `style` to `PerspectiveViewer`.
- In non-React, set dimensions on the custom element or its container.
- Do not override internal Perspective DOM styles unless required by the user’s design system.

## Common fixes

- Missing WASM errors: add proper `@perspective-dev/server` and `@perspective-dev/viewer` WASM imports and call `init_server()` / `init_client()`.
- Viewer renders blank: confirm CSS import, explicit height, table creation success, and that plugins were imported.
- Charts missing from plugin menu: import `@perspective-dev/viewer-charts`.
- Datagrid missing: import `@perspective-dev/viewer-datagrid`.
- React ref/custom-element typing problems: switch to `@perspective-dev/react`.
- Excess memory use: reuse one worker, avoid duplicating tables, delete owned tables on unmount, and avoid storing raw large datasets in component state.
- Slow streaming UI: batch `table.update()` calls and avoid recreating tables/viewers per tick.

## Validation checklist

Before finishing a Perspective browser change:

- The project uses current `@perspective-dev/*` packages.
- React projects use `@perspective-dev/react` unless there is a specific reason not to.
- WASM bootstrapping is present and compatible with the bundler.
- Required plugins and CSS are imported.
- The viewer has an explicit height and width.
- Owned tables are deleted on teardown.
- Large data is not duplicated unnecessarily in component state.
- Streaming updates reuse the table instead of remounting the viewer.
- The implementation fits the host framework’s lifecycle and build system.

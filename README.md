# Clean Keyboard

A Droplet for [Droppy](https://getdroppy.app), built with
[DroppyKit](https://getdroppy.app/docs/droppykit).

## Developing

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce Cleankeyboard.droplet
droppykit validate   # the checks a submission runs
droppykit submit     # open the submission form, filled in from this checkout
```

## With a coding agent

Open this folder in Claude Code, Codex or Cursor. `AGENTS.md` is the brief they read first, and `.mcp.json` / `.cursor/mcp.json` connect the DroppyKit MCP server.

## The surfaces

| Surface | Protocol |
| --- | --- |
| Shelf widget | `ShelfWidgetProviding` |
| Live activity, compact and expanded | `LiveActivityProviding` |
| Settings pane | `SettingsPaneProviding` |
| Menu bar extra | `MenuBarExtraProviding` |

## Repository layout

```
Sources/Cleankeyboard/          the droplet's code
Cleankeyboard.icon/             the app icon artwork
Assets/                         bundled assets (like Creator.png)
droplet.json                    the manifest
```

## Licence

Source-available. See [LICENSE](LICENSE).

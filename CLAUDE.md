# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cashier is a Roblox Luau package that handles in-game purchases, gamepasses, gifting, and inventory management. It's published as `yuzkkj/monetization-service` on Wally (currently v1.4.0).

## Toolchain

Managed via **Rokit** (`rokit.toml`):
- **Wally** (0.3.2) — package manager. `wally install` pulls deps into `Packages/`.
- **Rojo** (7.7.0-rc.1) — syncs source to Roblox Studio.
- **wally-package-types** (1.6.2) — generates Luau type stubs for Wally packages.
- **StyLua** — formatter. Run `stylua src/` (Luau syntax, defaults: 120 col, tabs).
- **Selene** — linter. Run `selene src/` (roblox standard, `mixed_table` allowed).
- **Moonwave** — doc generator. Run `moonwave build` to regenerate `build/`.

No test framework is configured.

## Architecture

Single shared package with a client/server split:

- `src/init.luau` — entry point, exports `{ client, server }`.
- `src/CashierServer.luau` — server module. Handles item registration, `ProcessReceipt`, gamepass tracking, gifting (online + offline via DataService profiles), purchase history (DataStoreService), inventory, and stock-limited "Limiteds" system.
- `src/CashierClient.luau` — client module. Fetches item info via Networker, prompts purchases/gifts through MarketplaceService, exposes signals.

Both modules guard context with `RunService:IsClient()`/`RunService:IsServer()` and return an empty table if loaded in the wrong environment.

**Key dependencies** (from Wally):
- `DataService` — persistent player data (profiles, inventory, gift queues)
- `Networker` — client-server communication abstraction (replaces raw RemoteEvents)
- `ServicePlayerData` — ephemeral per-player session state
- `Sift` — immutable-style array/dictionary helpers
- `Signal` — event/signal system

## Code Conventions

- **Singleton pattern**: modules are plain tables, state initialized in `:init()`, no constructors.
- **Naming**: PascalCase for modules/types, camelCase for methods/variables, `_prefix` for private members, UPPER_SNAKE_CASE for constants.
- **Types**: extensive Luau type annotations. Self-type defined at bottom of each module via `type ModuleName = typeof(Module) & { ... }`, returned with a cast.
- **Docs**: Moonwave comments (`--[=[ ... ]=]`) with `@method`, `@within`, `@param`, `@return` tags on all public API.
- **Error handling**: `pcall` around Roblox API calls, `warn()` for non-fatal errors, boolean returns for success/failure.
- **Data patterns**: predicate/callback separation for items, pending params stored per-player, gift fallback to buyer inventory on delivery failure.

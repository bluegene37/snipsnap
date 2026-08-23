1. Remove `_Pill`, `_PillIconButton`, `_ToggleIconButton`.
2. Rewrite `_HeaderButton` to support `label` (nullable) and `isActive`. It will use `ElevatedButton` and `WidgetStateProperty` to strictly follow `SnipTheme` logic.
3. Update `_buildCaptureGroup` to use the same gap `SizedBox(width: 6)` and include "Open" as `_HeaderButton(label: 'Open', ...)`.
4. Update `_buildEditGroup` to drop `_Pill` and use a Row of `_HeaderButton`s with icon only.
5. Update `_buildZoomGroup` to drop `_Pill` and use a Row of `_HeaderButton`s with icon only, and a clickable text for reset.
6. Update `_buildExportGroup` to use `_HeaderButton`s for Copy, Flatten, Save As.
7. Update `_buildViewGroup` to use `_HeaderButton`s with `isActive` for Sidebar and Properties. Drop the Theme toggle since it's redundant.
8. Reorder groups in `Row`:
   - Left: `Brand`, `Capture Group`
   - Center: `Edit Group`, `Divider`, `Zoom Group`
   - Right: `View Group`, `Divider`, `Export Group`, `Overflow`

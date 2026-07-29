# Variant B - Reason field on the event

Branch: `focus-variant-b-reason`, based on `fix-layout-switch-cancels-rename` (150293cc0f).

GPUI keeps emitting a blur when the window is deactivated, but the blur now carries **why** it happened, so a handler cannot silently conflate "the user moved focus away" with "the OS took the window out of the foreground".

## API shape

```rust
// crates/gpui/src/window.rs

/// Why a focus handle stopped being focused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlurReason {
    /// Focus moved to a different element, or to nothing at all, while the window stayed active.
    FocusMoved,
    /// The window stopped being the OS-active window. The blurred handle is still the window's
    /// focus target and regains focus when the window is activated again.
    WindowDeactivated,
}

impl BlurReason {
    pub fn is_focus_moved(self) -> bool;
}

pub struct FocusOutEvent {
    pub blurred: WeakFocusHandle,
    pub reason: BlurReason,          // new
}

pub(crate) struct WindowFocusEvent {
    previous_focus_path: SmallVec<[FocusId; 8]>,
    current_focus_path: SmallVec<[FocusId; 8]>,
    blur_reason: BlurReason,         // new
}
```

Producer, in `Window::draw()` - the only place that knows both activation states:

```rust
blur_reason: if previous_window_active && !current_window_active {
    BlurReason::WindowDeactivated
} else {
    BlurReason::FocusMoved
},
```

Subscription APIs:

| API                                       | before                                        | after                                                     |
| ----------------------------------------- | --------------------------------------------- | --------------------------------------------------------- |
| `Context::on_blur`                        | `FnMut(&mut T, &mut Window, &mut Context<T>)` | `FnMut(&mut T, BlurReason, &mut Window, &mut Context<T>)` |
| `Context::on_focus_out`                   | `FnMut(&mut T, FocusOutEvent, ..)`            | unchanged signature; `FocusOutEvent.reason` added         |
| `Window::on_focus_out`                    | `FnMut(FocusOutEvent, ..)`                    | unchanged signature; `FocusOutEvent.reason` added         |
| `editor::EditorEvent::Blurred`            | unit variant                                  | `Blurred(BlurReason)`                                     |
| `ui_input::ErasedEditorEvent::Blurred`    | unit variant                                  | `Blurred(BlurReason)`                                     |
| `picker::head::Head::empty` blur handler  | `FnMut(&mut V, &mut Window, &mut Context<V>)` | `FnMut(&mut V, BlurReason, &mut Window, &mut Context<V>)` |
| `agent_ui::MessageEditorEvent::LostFocus` | unit variant                                  | `LostFocus(BlurReason)`                                   |

### Naming decision

`BlurReason` / `FocusMoved` / `WindowDeactivated` over the alternative `FocusChangeReason { FocusMoved, WindowActivationChanged }`.
The enum is only ever consumed on the focus-_out_ side, so a symmetric name would be an invitation to reuse it for focus-in that nothing currently needs. `blur_reason` on the internal `WindowFocusEvent` is documented as meaningful only in the focus-out direction; it is `pub(crate)` and never leaves GPUI in that form.

### No `FocusInEvent` (YAGNI, deliberate)

`Context::on_focus_in` and `Window::on_focus_in` were **not** changed. Reasons:

- No reported bug is caused by a handler reacting to focus-in on window *re*activation. All four historical incidents (#41320, #46866, #47044, #39286) are blur-side.
- `on_focus_in` currently passes no event at all, so adding one would break ~25 call sites for zero known consumer.
- The symmetry is already lopsided in the codebase: `on_focus`/`on_focus_in` take no event while `on_focus_out` takes one.

If a focus-in bug ever appears, the same pattern extends cleanly: add `FocusInEvent { reason: FocusInReason }`.

## Files touched (29)

### GPUI core (2)

| File                             | Why                                                                                                                                                                   |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `crates/gpui/src/window.rs`      | Define `BlurReason`; add `blur_reason` to `WindowFocusEvent`; add `reason` to `FocusOutEvent`; compute the reason in `draw()`; populate it in `Window::on_focus_out`. |
| `crates/gpui/src/app/context.rs` | Thread the reason into `Context::on_blur` (signature change) and `Context::on_focus_out`.                                                                             |

### Event plumbing (4)

| File                                    | Why                                                                                                                           |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `crates/editor/src/editor.rs`           | `EditorEvent::Blurred(BlurReason)`; `handle_blur` takes and re-emits the reason; map to `ErasedEditorEvent::Blurred(reason)`. |
| `crates/ui_input/src/ui_input.rs`       | `ErasedEditorEvent::Blurred(BlurReason)`.                                                                                     |
| `crates/picker/src/head.rs`             | `Head::empty` blur-handler signature.                                                                                         |
| `crates/agent_ui/src/message_editor.rs` | `MessageEditorEvent::LostFocus(BlurReason)` - the reason had to be forwarded because its two consumers want different things. |

### Guards removed (`window.is_window_active()` replaced by the reason) (4 files, 5 guards)

`crates/picker/src/picker.rs` (2), `crates/project_panel/src/project_panel.rs`, `crates/collab_ui/src/collab_panel.rs`, `crates/go_to_line/src/go_to_line.rs`.

### Handler sites revisited (23 more files, listed in the table below)

## Blur-site decision table

`FocusMoved` = ignore window deactivation. `both` = react regardless of reason.

### `EditorEvent::Blurred` / `ErasedEditorEvent::Blurred`

| Site                                                        | What it does                                                                           | Decision                                                                                               | Rationale                                                                                                                    |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `picker/src/picker.rs:652` `on_input_editor_event`          | cancel modal picker                                                                    | **FocusMoved**                                                                                         | Replaces the `is_window_active()` guard from #41320.                                                                         |
| `picker/src/picker.rs` `on_empty_head_blur`                 | cancel picker                                                                          | **FocusMoved**                                                                                         | Same, second guard.                                                                                                          |
| `project_panel/src/project_panel.rs:800`                    | commit/discard rename                                                                  | **FocusMoved**                                                                                         | Replaces the base-branch guard for issue #39286.                                                                             |
| `collab_ui/src/collab_panel.rs:357`                         | commit channel rename                                                                  | **FocusMoved**                                                                                         | Same.                                                                                                                        |
| `go_to_line/src/go_to_line.rs:174`                          | dismiss Go to Line                                                                     | **FocusMoved**                                                                                         | Same.                                                                                                                        |
| `terminal_view/src/terminal_view.rs:459`                    | finish terminal tab rename                                                             | **FocusMoved**                                                                                         | **New fix.** Sibling of #39286 that the base branch missed - alt-tab during a terminal tab rename currently ends the rename. |
| `debugger_ui/.../variable_list.rs:236` (via `on_focus_out`) | drop in-progress variable edit                                                         | **FocusMoved**                                                                                         | **New fix.** Same class.                                                                                                     |
| `repl/src/notebook/cell.rs:388`                             | leave markdown-cell edit mode                                                          | **FocusMoved**                                                                                         | Alt-tab should not kick you out of an editing cell.                                                                          |
| `rules_library/src/rules_library.rs:1028` (title)           | collapse selection to a cursor                                                         | **FocusMoved**                                                                                         | Mutates persistent selection state, not just its rendering.                                                                  |
| `rules_library/src/rules_library.rs:1058` (body)            | collapse selection to a cursor                                                         | **FocusMoved**                                                                                         | Same.                                                                                                                        |
| `agent_ui/src/agent_panel.rs:670`                           | restore default summary when left empty                                                | **FocusMoved**                                                                                         | Rewriting text under a user who cleared the field and stepped away is the same surprise class.                               |
| `agent_ui/src/conversation_view/thread_view.rs:1553`        | restore default thread title when left empty                                           | **FocusMoved**                                                                                         | Same.                                                                                                                        |
| `diagnostics/src/diagnostics.rs:249`                        | close excerpts that no longer have diagnostics                                         | **FocusMoved**                                                                                         | _Behaviour change._ See "judgment calls".                                                                                    |
| `diagnostics/src/buffer_diagnostics.rs:181`                 | `update_all_excerpts`                                                                  | **FocusMoved**                                                                                         | Same, kept consistent with the sibling above.                                                                                |
| `vim/src/vim.rs:1093` -> `Vim::blurred`                      | **split**                                                                              | `FocusMoved`: stop macro recording, store visual marks, clear pending operator. `both`: hollow cursor. | The clearest mixed site in the tree: pending vim state must survive a deactivation, the cursor shape must not.               |
| `agent_ui/src/inline_prompt_editor.rs:469`                  | hide rate-limit notice                                                                 | **both**                                                                                               | Pure presentation.                                                                                                           |
| `search/src/buffer_search.rs:1399`                          | `query_editor_focused = false`                                                         | **both**                                                                                               | Presentation flag; the paired `Focused` arm also fires on reactivation, so both stay symmetric.                              |
| `search/src/buffer_search.rs:1429`                          | `replacement_editor_focused = false`                                                   | **both**                                                                                               | Same.                                                                                                                        |
| `editor/src/editor.rs` `Editor::handle_blur`                | blink off, drop active selections, hide hover, hide context menu, drop edit prediction | **both** (behaviour preserved)                                                                         | See "judgment calls" - two of these are arguably FocusMoved-only.                                                            |

### `Context::on_blur`

| Site                                                                          | What it does                             | Decision                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------------------------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `editor/src/editor.rs:2331`                                                   | `Editor::handle_blur`                    | both (see above)                                                                                                                                                                                                                                                                                                                                                            |
| `ui/src/components/context_menu.rs` x3 (`new`, `build_persistent`, `rebuild`) | dismiss the menu                         | **both**, deliberately. Zed explicitly wants menus to close when the app is no longer frontmost (#46866); that PR's `observe_window_activation` implementation was reverted in ade8749537, so today the behaviour survives only through the conflated blur. This is the counter-example that stops "all cancel handlers become FocusMoved" from being a valid blanket rule. |
| `ui/src/components/context_menu.rs:1179` (submenu)                            | no-op                                    | n/a                                                                                                                                                                                                                                                                                                                                                                         |
| `picker/src/head.rs:50`                                                       | forwards to `Picker::on_empty_head_blur` | FocusMoved (at the consumer)                                                                                                                                                                                                                                                                                                                                                |
| `storybook/src/stories/focus.rs` x3                                           | debug `println!`                         | now prints the reason                                                                                                                                                                                                                                                                                                                                                       |

### `on_focus_out` - changed to FocusMoved

| Site                                             | What it does                                           |
| ------------------------------------------------ | ------------------------------------------------------ |
| `agent_ui/src/threads_archive_view.rs:179`       | clear the selected row                                 |
| `debugger_ui/.../memory_view.rs:189`             | leave query-bar edit mode                              |
| `debugger_ui/.../variable_list.rs:236`           | drop in-progress variable edit                         |
| `git_ui/src/commit_modal.rs:208`                 | dismiss the commit modal                               |
| `recent_projects/src/recent_projects.rs:571`     | dismiss the project popover                            |
| `workspace/src/modal_layer.rs:141`               | `hide_modal` when `dismiss_on_focus_lost`              |
| `diagnostics/src/diagnostics.rs:439` `focus_out` | close diagnosticless buffers                           |
| `diagnostics/src/buffer_diagnostics.rs:135`      | `update_all_excerpts`                                  |
| `agent_ui/src/message_editor.rs:244`             | forwards the reason on `MessageEditorEvent::LostFocus` |

### `on_focus_out` - reviewed, left reacting to both

| Site                                                   | What it does                                                           | Why both                                                                                             |
| ------------------------------------------------------ | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `workspace/src/item.rs:939`                            | autosave when `autosave = on_focus_change`                             | Users expect alt-tab to autosave. Saving is non-destructive; suppressing it would be the regression. |
| `workspace/src/pane.rs:527` -> `Pane::focus_out`        | `was_focused = false`, toolbar focus styling                           | Presentation.                                                                                        |
| `editor/src/editor.rs:2329` -> `handle_focus_out`       | track `last_focused_descendant`, reset drag state, refresh inlay hints | Bookkeeping + presentation; the modifier state really is released when the window goes away.         |
| `terminal_view/src/terminal_view.rs:241` -> `focus_out` | blink off, hollow cursor                                               | Presentation.                                                                                        |
| `agent_ui/src/inline_assistant.rs:1798`                | clear `active_assist_id`, hide unfocused cursor                        | Symmetric with the `on_focus_in` that restores it on reactivation.                                   |
| `debugger_ui/src/session/running.rs:891`               | `serialize_layout`                                                     | Idempotent persistence.                                                                              |
| `repl/src/repl_sessions_ui.rs:162`                     | `cx.notify()`                                                          | Rendering only.                                                                                      |
| `settings_ui/src/components/number_field.rs:610`       | commit the parsed value                                                | Committing a value the user typed is non-destructive; skipping it risks losing it.                   |
| `keymap_editor/.../keystroke_input.rs:82`              | stop intercepting keystrokes                                           | Uncertain - see below.                                                                               |
| `which_key/src/which_key_modal.rs:51`                  | dismiss the hint overlay                                               | Transient overlay, same argument as context menus.                                                   |
| `agent_ui/src/conversation_view.rs:2212` (`LostFocus`) | save the queued message                                                | Saving is non-destructive.                                                                           |
| `agent_ui/.../thread_view.rs:704` (`LostFocus`)        | leave message-edit mode                                                | **FocusMoved** (this one was changed)                                                                |

### Style convention used

`Blurred(_)` marks "any reason"; the two variants are spelled out whenever they differ. No `_ =>` catch-all was added at any lifecycle site.

## Judgment calls a reviewer should scrutinise hardest

1. **`Editor::handle_blur` was left reacting to both** even though `hide_context_menu` and `take_active_edit_prediction(true, ..)` are arguably FocusMoved-only. Alt-tabbing away with a completion popup open and returning to find it gone is the same annoyance class as the rename bug. I preserved the existing behaviour because `Editor` is the highest-blast-radius file in the tree and this is a UX call, not a correctness one. **This is the single most likely thing to want changing.**
2. **Diagnostics excerpt closing** (`diagnostics.rs`, `buffer_diagnostics.rs`) - I changed it to FocusMoved. That is a real behaviour change: the diagnostics list no longer reflows when you alt-tab away. Justification is that reflowing a list the user is reading, while they are not looking, loses their scroll position. Reasonable people will disagree; it is a one-word revert per site.
3. **Context menus deliberately keep reacting to both.** If a reviewer expects "the whole point is that cancel handlers become FocusMoved-only", this site looks like an oversight. It is not - see #46866 and its revert in ade8749537. It is the strongest evidence that the reason field is genuinely needed rather than a blanket policy.
4. **`keystroke_input` (keybinding recorder)** left on both. On Wayland, pressing the keyboard-layout-switch combo deactivates the window and would abort a keybinding recording. That is arguably the exact bug this whole change exists to kill. I did not change it because recording a layout-switch chord as a Zed keybinding is a strange thing to want, and I could not test it.
5. **`Vim::blurred` split.** Whether `store_visual_marks` belongs on the FocusMoved side is not obvious; I grouped it with the other pending-state operations because it pairs with `clear_operator`.
6. **`MessageEditorEvent::LostFocus` now carries `BlurReason`.** This demonstrates the propagation cost: the reason has to be threaded through every intermediate domain event that was derived from a blur. There are probably more such events in the tree that nobody has needed yet.
7. **Semantics of a simultaneous deactivation + focus move.** `draw()` reports `WindowDeactivated` when `previous_window_active && !current_window_active`, even if the focus path also changed in that frame. In practice the focus path is blanked on deactivation so this cannot produce a spurious `FocusMoved`, but the precedence is a choice.

## Honest weaknesses of this design

1. **It forces a decision; it cannot force a _correct_ one.** Every site I touched is a place where I guessed at product intent from a 20-line function body. The compiler made me _look_; it did not tell me the answer. A future contributor under time pressure will write `Blurred(_)` and the bug reappears - with the added cost that the code now _looks_ like it was considered.

2. **The enforcement is uneven.** `on_blur`, `EditorEvent::Blurred` and `ErasedEditorEvent::Blurred` are compiler-breaking (good). `on_focus_out` is **not** - adding a field to `FocusOutEvent` breaks nobody, so all 21 `on_focus_out` sites compiled unchanged and were only revisited because I grepped for them. That is exactly the failure mode the design claims to prevent, present in half the API. A stricter version would pass `BlurReason` as its own callback parameter (breaking all 21), at the cost of duplicating data already inside the event. I chose the natural struct shape and am flagging the gap rather than hiding it.

3. **It does not remove the underlying conflation, it documents it.** GPUI still synthesises a fake focus change on deactivation: `previous_focus_path` is still blanked, `is_focus_out()` still returns true, `on_focus_lost` still fires. Anything reading the focus path directly still sees a lie. Variant A (not emitting the blur at all) attacks the cause; this attacks the symptom with better labels.

4. **The reason must be manually re-plumbed through every derived event.** `EditorEvent::Blurred` -> `ErasedEditorEvent::Blurred` -> `MessageEditorEvent::LostFocus` was three hops in this change alone. Nothing stops the next abstraction layer from dropping the reason on the floor, and the compiler will not complain when it does.

5. **Big diff for a defaults problem.** 29 files, mostly mechanical. The signal-to-noise ratio for review is poor: the four or five decisions that actually matter are buried among twenty `Blurred(_)` rewrites. Bisecting a behaviour regression to one of these arms will be unpleasant.

6. **`BlurReason` is a two-variant enum that will want a third.** Plausible future cases: the window was closed, the focused element was removed from the tree (today that goes through `on_focus_lost` separately), or focus moved to a child of the same widget. Adding a variant later breaks every exhaustive match - which is the design working as intended, but it is a recurring tax, not a one-time one.

7. **Not compiled.** See below.

## Not verified

Nothing in this branch has been compiled, type-checked, clippy'd or run; the machine this was written on cannot build Zed. Specific things a build will catch that reading cannot:

- `cx.on_blur(&focus_handle, window, Self::handle_blur)` in `ContextMenu` relies on a `&mut self` method item coercing to `impl FnMut(&mut T, BlurReason, &mut Window, &mut Context<T>)`. `Editor` already does exactly this with the old arity, so it should hold, but the added parameter is untested.
- Unused-variable warnings (`-D warnings` is on in CI) after guards were removed. `go_to_line::on_line_editor_event`'s `window` was renamed to `_window` for this reason; other sites were checked by hand for remaining uses of `window` but not proven.
- Import-list edits across 20 crates.
- `crates/agent/src/edit_agent/evals/fixtures/disable_cursor_blinking/before.rs` contains a frozen snapshot of `editor.rs` including `EditorEvent::Blurred` and `on_blur`. It is `include_str!`'d as eval input, not compiled, and was deliberately left untouched so the eval diffs still apply.

The regression test `test_rename_survives_window_deactivation` (`crates/project_panel/src/project_panel_tests.rs:4662`) should still pass: `cx.deactivate_window()` drives `draw()` with `previous_window_active && !current_window_active`, yielding `WindowDeactivated`, which the project panel's rename arm now ignores.

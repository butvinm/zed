# Variant A - SUBTRACTIVE

Window activation stops producing focus events. Element focus and OS window activation become two
genuinely independent signals with two separate subscription APIs.

## The API / behavior change

In `crates/gpui/src/window.rs` `draw()`, the focus-event block used to be:

```rust
if previous_focus_path != current_focus_path || previous_window_active != current_window_active {
    if !previous_focus_path.is_empty() && current_focus_path.is_empty() { /* focus_lost */ }
    let event = WindowFocusEvent {
        previous_focus_path: if previous_window_active { previous_focus_path } else { Default::default() },
        current_focus_path:  if current_window_active  { current_focus_path  } else { Default::default() },
    };
    ...
}
```

It is now:

```rust
if previous_focus_path != current_focus_path {
    if !previous_focus_path.is_empty() && current_focus_path.is_empty() { /* focus_lost */ }
    let event = WindowFocusEvent { previous_focus_path, current_focus_path };
    ...
}
```

Consequences, stated as contract:

- `on_focus`, `on_blur`, `on_focus_in`, `on_focus_out` (both the `Context<T>` and `Window` variants),
  and therefore `EditorEvent::Focused` / `EditorEvent::Blurred`, fire **only** when the focused
  element inside the window actually changes.
- Deactivating the window emits nothing. Reactivating the window emits nothing.
- `window.focus` was already **not** cleared on deactivation, so `FocusHandle::is_focused` keeps
  returning `true` across an activation cycle. The two sources of truth described in the problem
  statement now agree: neither the flag nor the event stream claims a blur happened.
- Anything that cares about the window losing OS focus subscribes with
  `cx.observe_window_activation(window, ...)` and reads `window.is_window_active()`.

### Why the `previous_window_active != current_window_active` disjunct was deleted entirely

I checked whether that condition drives anything besides the blanked event.

- `focus_lost_listeners` fire on `!previous_focus_path.is_empty() && current_focus_path.is_empty()`.
  Those use the **raw** paths, never the blanked ones. And they are nested inside the outer `if`, so
  they can only fire when `previous_focus_path != current_focus_path` - activation alone can never
  satisfy the inner condition. Deleting the disjunct is therefore a no-op for `on_focus_lost`
  (`crates/workspace/src/workspace.rs:1546` is the only real consumer).
- All four registrations that reach `focus_listeners` (`app/context.rs:559/585/608/654` and
  `window.rs:4002/4022`) compare `previous_focus_path` against `current_focus_path`. With the paths
  no longer blanked, an activation-only change produces `previous == current`, so every predicate is
  false and the event is a pure no-op. Keeping the disjunct would only allocate and walk the
  subscriber list for nothing.

So the disjunct is dead once the blanking is gone, and `Frame::window_active` becomes entirely
unreferenced (verified by grep: the field had exactly 6 uses, all in the block being changed). I
removed the field rather than leave dead state.

## Files touched

| File                                              | Why                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `crates/gpui/src/window.rs`                       | The core change: stop blanking focus paths, drop the activation disjunct, delete the now-dead `Frame::window_active` field, document the new contract on `WindowFocusEvent`.                                                                                                                                                                                                      |
| `crates/gpui/src/key_dispatch.rs`                 | New test `test_window_activation_does_not_produce_focus_events`. Asserts no focus events on deactivate **and** on reactivate, that `is_focused` stays true across the cycle, and - as a vacuity guard - that a real intra-window focus move still fires `focus_out`.                                                                                                              |
| `crates/editor/src/editor.rs`                     | Migration. Extracted `Editor::hide_transient_ui` (hover popover, completion/context menu, active edit prediction) out of `handle_blur`, and called it from the existing `observe_window_activation` subscription when the window deactivates _and_ this editor is the focused element. Cursor blink was already migrated at editor.rs:2537.                                       |
| `crates/ui/src/components/context_menu.rs`        | Migration. Extracted the four duplicated `on_blur` closures into `ContextMenu::handle_blur`, and added `ContextMenu::observe_window_deactivation` which calls it when the window deactivates while the menu is the focused element. This preserves the dismiss-on-window-blur behavior that PR #46866 wanted and that the tree currently gets for free from the synthesized blur. |
| `crates/terminal_view/src/terminal_view.rs`       | Migration. Added an `observe_window_activation` subscription that calls the existing `focus_in`/`focus_out` when the terminal contains focus, so xterm focus reporting (`\x1b[I` / `\x1b[O`, used by vim/tmux autoread) and the hollow cursor keep tracking window activation.                                                                                                    |
| `crates/picker/src/picker.rs`                     | Removed two now-redundant `window.is_window_active()` guards (PR #41320).                                                                                                                                                                                                                                                                                                         |
| `crates/project_panel/src/project_panel.rs`       | Removed the guard added by the base commit for issue #39286.                                                                                                                                                                                                                                                                                                                      |
| `crates/collab_ui/src/collab_panel.rs`            | Same.                                                                                                                                                                                                                                                                                                                                                                             |
| `crates/go_to_line/src/go_to_line.rs`             | Same; the `window` parameter reverts to `_window`.                                                                                                                                                                                                                                                                                                                                |
| `crates/project_panel/src/project_panel_tests.rs` | Extended `test_rename_survives_window_deactivation` to also assert the rename survives **re**activation, which is the half that the old code broke via the synthesized focus-in.                                                                                                                                                                                                  |

Total: 10 files, ~160 insertions / ~111 deletions, of which the gpui change is 8 net-removed lines.

## `is_window_active()` guards deliberately left alone

Grep found 19 non-gpui call sites. These are not about focus and must stay:

- `crates/agent_ui/src/conversation_view.rs:2270,2286` - whether to show/sound an agent notification.
- `crates/agent_ui/src/context_server_configuration.rs:86` - don't pop a modal onto a background window.
- `crates/title_bar/src/title_bar.rs:1017`, `crates/platform_title_bar/src/platform_title_bar.rs:56` - rendering.
- `crates/zed/src/main.rs:1108,1126` - defer a git-clone flow until the window is active.
- `crates/workspace/src/workspace.rs:2971,5952,6167` - close-global, follower updates, the activation observer itself.
- `crates/collab/tests/integration/following_tests.rs:85`, `crates/zed/src/zed.rs:5297` - test assertions.
- `crates/editor/src/editor.rs:2538` - the blink/mouse-cursor activation observer (now also the transient-UI migration point).
- `crates/agent/src/edit_agent/...` - eval fixture text, not live code.

## Judgment calls

1. **Faithfulness over "correctness" in the migrations.** Every migrated handler is gated on the
   same focus predicate the old synthesized blur implied (`is_focused` for editor and context menu,
   `contains_focused` for the terminal, matching `on_blur` vs `on_focus_out` semantics). So a
   deactivation now does exactly what it did before for these three, and nothing else. The
   alternative - firing them unconditionally, as PR #46866 did - would have _widened_ behavior
   (e.g. cancelling a context menu that was open but not focused).
2. **`ContextMenu::_on_window_deactivation_subscription` is `Option<Subscription>`, `None` for
   submenus.** A submenu's `on_blur` handler is an explicit no-op today, so a focused submenu is not
   dismissed by window deactivation. `None` reproduces that exactly. Registering a real observer
   that calls `cancel` would have been a behavior change smuggled in under a refactor.
3. **I did not migrate `Editor::handle_blur`'s `remove_active_selections` or `GitBlame::blur`.**
   Both have an asymmetric partner in `handle_focus` (`set_active_selections`, `GitBlame::focus`).
   Migrating only the deactivation half would leave collab presence and blame permanently stale
   after one alt-tab; migrating both halves means re-deriving "should this editor re-broadcast its
   selection" on every activation, which is more machinery than the win justifies. Net effect: your
   selection highlight stays visible to collaborators while you are in another app. That is a real
   behavior change; see weaknesses.
4. **I did not migrate `Vim::blurred` (`crates/vim/src/vim.rs:1530`).** It is a mixed bag:
   `stop_recording_immediately` and `store_visual_marks` are state mutations that arguably should
   _never_ have fired on window deactivation (alt-tabbing currently aborts an in-progress macro
   recording), while `set_cursor_shape(Hollow)` is presentation. Migrating only the cursor shape
   requires a symmetric restore path through `Vim::focused`, which does a lot of unrelated work
   (mode restoration, `prior_selections` handling) and is not safe to call on reactivation. So vim
   loses the hollow cursor on window blur and gains uninterrupted macro recording.
5. **`Frame::window_active` deleted rather than left in place.** Subtractive variant; leaving a
   field that nothing reads invites someone to "fix" the regression by reading it again.
6. **Test placed in `crates/gpui/src/key_dispatch.rs`**, which is where the (later reverted) PR
   #47044 activation/focus test lived, and which already imports everything needed.

## What a reviewer should scrutinize hardest

1. **The enumeration of "consumers that genuinely wanted blur-on-deactivation" is the whole risk of
   this design.** I claim it is {editor transient UI, context menu, terminal focus reporting}, with
   {vim cursor shape, which-key modal, collab selection presence, blame laziness} knowingly dropped.
   That list was produced by grepping `on_blur|on_focus_out|on_focus_in|on_focus` (~60 sites) and
   `EditorEvent::Blurred` (~18 sites) and reading each. A missed site is a silent regression that
   only shows up as "this popup no longer closes when I switch apps" - a class of bug that is hard
   to notice and easy to blame on something else.
2. **Reactivation no longer fires `on_focus` / `on_focus_in`.** Things that ran on every window
   reactivation now do not: `Editor::handle_focus` (`buffer.finalize_last_transaction`,
   `show_cursor_names`, `set_active_selections`, the synthetic `mouse_moved`), `Pane::focus_in`
   (`update_history`, `update_active_tab`, `Event::Focus`), `Workspace::handle_panel_focused`,
   `Dock`'s focus-in zoom bookkeeping. I believe every one of these is symmetric - it was only
   re-running to undo the spurious blur - but "I read it and it looks symmetric" is not a proof.
   The concrete user-visible loss I did find: undo no longer breaks a transaction at an app switch,
   so typing / alt-tab / typing then undo now removes both runs of text at once.
3. **`Editor::hide_transient_ui` on deactivation ordering.** `activation_observers` fire
   synchronously inside `on_active_status_change`, _before_ `window.refresh()` and the next draw,
   and `window.focus` is untouched at that point, so `editor.focus_handle.is_focused(window)` reads
   the pre-deactivation focus. That is what I want, but it depends on gpui not clearing
   `window.focus` on deactivation - exactly the thing PR #47044 tried to add and #47835 reverted.
   If someone re-lands focus save/restore on deactivation, all three migrated guards silently stop
   matching and the migrations become no-ops.
4. **Re-adding context-menu dismissal on window deactivation re-lands the shape of PR #46866**,
   which was reverted by #47835 ("Fix typing emoji using the macOS system palette"). I believe the
   emoji bug came from #47044's `focus_before_deactivation` (which cleared `window.focus` and so
   broke IME insertion), not from #46866, and that #46866 was reverted only because it was stacked
   on top. But I could not verify that, and the macOS character palette is exactly the kind of thing
   that deactivates the window while the user still expects to be typing into it. **Test the emoji
   palette on macOS before merging.**
5. **The gpui test's vacuity guard.** `test_window_activation_does_not_produce_focus_events` is only
   meaningful because its last assertion proves focus events _do_ fire in this harness. If that last
   assertion is ever weakened, the test becomes a tautology.

## Honest weaknesses of this design

- **It is a breaking semantic change to a framework primitive, applied globally, verified by
  reading.** Roughly 60 focus-subscription sites across ~40 crates change behavior at once. There is
  no compiler error for a handler that _wanted_ the old behavior - it just stops running. The other
  two variants presumably keep the blast radius smaller. If the reviewer's tolerance for "silent
  behavioral regression discovered by users three weeks later" is low, this is the wrong variant.
- **It trades a known bug class for an unknown one.** The old bug ("my input got cancelled when I
  switched apps") is loud, reproducible, and files itself as an issue. The new bug ("this popover
  didn't close when I switched apps") is quiet and gets attributed to compositor weirdness.
- **It does not actually remove the coupling, it inverts who pays.** Every present and future
  presentation-on-window-blur behavior now needs an explicit `observe_window_activation`
  subscription, plus a focus predicate to scope it, plus (for anything stateful) a symmetric
  reactivation branch. The context-menu migration cost a new struct field threaded through four
  construction sites. The claim "correct with zero code, including handlers written in the future"
  is only true for the _cancel/commit_ half; the _dismiss/stop-animating_ half now costs more code
  than before, and gets it wrong by omission rather than by commission.
- **Known behavior regressions I am shipping deliberately** (each is small; together they are the
  real price):
  - vim's block cursor no longer goes hollow when the window loses focus.
  - The which-key overlay (`crates/which_key/src/which_key_modal.rs:51`) no longer dismisses on
    window deactivation.
  - Your selection is still broadcast to collaborators while you are in another application.
  - `AutosaveSetting::OnFocusChange` no longer double-fires on window deactivation. (This one is
    arguably a fix - `on_window_activation_changed` already autosaves both `OnWindowChange` and
    `OnFocusChange` - but it is a change.)
- **Platform inconsistency is untouched and now more visible.** See below.
- **I could not compile or run any of this.** No `cargo check`, no `cargo test`. Specific things
  that are plausible-but-unverified: the `Self::handle_blur` fn-item -> `impl FnMut` coercion in
  `cx.on_blur` (the editor does the same at editor.rs:2331, so this should be fine); the let-chain
  in `ContextMenu::handle_blur`; `crate::div().track_focus(...)` inside the key_dispatch test module
  (I added a local `use crate::InteractiveElement;` for it); whether `focus_events` in the new test
  needs its explicit type annotation. `rustfmt --check` passes on all ten files.

## Platform-layer notes

`on_active_status_change` is the single entry point on every platform, so the gpui change itself is
platform-neutral. What differs is _when_ each platform calls it - and that difference, which used to
be masked by "deactivation blurs everything anyway", is now the thing that decides whether user
input survives:

- **Wayland** (`crates/gpui_linux/src/linux/wayland/client.rs:1415`): `wl_keyboard::Event::Leave`
  -> `window.set_focused(false)`. This is _keyboard_ focus, not window activation. A compositor hands
  keyboard focus to an on-screen keyboard-layout switcher, an input-method popup, or a portal file
  chooser without the user leaving the window. This is the origin of issue #39286 and the reason
  the variant exists. It is also the platform where this fix matters most.
- **X11** (`crates/gpui_linux/src/linux/x11/client.rs:932/943`): `FocusIn`/`FocusOut` ->
  `set_active(true/false)`. X11 `FocusOut` also fires for grabs and for override-redirect popups,
  so the same class of spurious deactivation exists, though less often than on Wayland.
- **macOS** (`crates/gpui_macos/src/window.rs:1492`): key-window transitions, with an existing
  workaround at window.rs:2144 for a spurious `becomeKeyWindow`. The character palette
  (`cmd-ctrl-space`) deactivates the window while the user is still logically typing - see the
  #47835 caveat above.
- **Windows** (`crates/gpui_windows/src/events.rs:724`): `WM_ACTIVATE`, dispatched through
  `executor.spawn`, so the callback is asynchronous relative to the message. Nothing in this change
  depends on synchrony, but note that Windows is the one platform where `observe_window_activation`
  callbacks do not run inside the platform event.

I did **not** change any platform layer. After this change all four behave the same way (activation
never touches focus), but they still disagree about _what counts as deactivation_ - Wayland reports
it far more eagerly than macOS. Making that consistent (e.g. distinguishing "keyboard focus left"
from "window is no longer the user's active window" on Wayland) is a separate, larger fix that this
variant makes possible but does not perform.

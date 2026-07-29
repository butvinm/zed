# Variant C: centralized helper

Branch: `focus-variant-c-helper`, based on `fix-layout-switch-cancels-rename`.

## The abstraction

Two subscription constructors on `gpui::Context<T>`, in `crates/gpui/src/app/context.rs`, placed directly next to the two methods that carry the trap:

```rust
pub fn on_blur_by_user(
    &mut self,
    handle: &FocusHandle,
    window: &mut Window,
    listener: impl FnMut(&mut T, &mut Window, &mut Context<T>) + 'static,
) -> Subscription

pub fn on_focus_out_by_user(
    &mut self,
    handle: &FocusHandle,
    window: &mut Window,
    listener: impl FnMut(&mut T, FocusOutEvent, &mut Window, &mut Context<T>) + 'static,
) -> Subscription
```

Each is a three-line wrapper around its unguarded twin:

```rust
self.on_blur(handle, window, move |view, window, cx| {
    if window.is_window_active() {
        listener(view, window, cx)
    }
})
```

GPUI's event semantics are untouched: no change to `WindowFocusEvent` synthesis in `Window::draw`, no change to `on_blur` / `on_focus_out` / `focus_lost_listeners`, no change to what any existing subscriber observes. The only additions are two constructors and doc text.

### Why this shape

Shape (a) from the brief - a subscription constructor - over (b) an "edit session" struct or (c) an extension trait.

- (b) an edit-session struct owning focus handle + subscription + commit/cancel callbacks would have to model five genuinely different lifecycles: the project panel commits on blur but only when `processing_filename.is_none()`, the collab panel discards but only when there is no pending name, `GoToLine` emits `DismissEvent`, the picker cancels only when `is_modal`, and the terminal defers a frame and re-checks that the editor it captured is still the current one. The only thing all five share is _when_ to run, not _what_ to run. A struct would have ended up as a callback bag with one extra indirection.
- (c) an extension trait buys nothing over inherent methods, since `Context<T>` is a gpui type and gpui is where the methods belong.

### Why gpui and not `ui` or `workspace`

The trap is `Context::on_blur`, which lives in gpui. Any helper that lives further out (in `ui` or `workspace`) is invisible at the moment a contributor types `cx.on_bl` and takes the completion - and it would be unreachable from `crates/picker` without a new dependency edge, and unreachable from gpui-only code entirely. Putting the correct constructor immediately below the incorrect one in the same `impl` block is the only placement where autocomplete and rustdoc do the teaching. gpui cannot depend on `workspace`, but nothing here needs to.

### Why `is_window_active()` and not "the new focus path is non-empty"

The purer-looking predicate - fire only when focus actually landed on something else in the window - would also suppress the callback when focus is cleared entirely while the window is still active (`Window::blur`, or the focused element being removed from the tree). Today, in an active window, that path _does_ commit a project-panel rename. Using `is_window_active()` makes every migrated call site byte-identical to the guarded code on the base branch, which matters a lot when the change cannot be compiled locally. See "Weaknesses" for what this costs.

## Files touched

| File                                              | Why                                                                                                                                                                     |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `crates/gpui/src/app/context.rs`                  | Adds `on_blur_by_user` and `on_focus_out_by_user`; adds warnings to the `on_blur` and `on_focus_out` doc comments pointing at them; adds two unit tests for the helper. |
| `crates/gpui/src/window.rs`                       | Doc-only: `Window::on_focus_out` gets the same warning and cross-reference.                                                                                             |
| `crates/project_panel/src/project_panel.rs`       | Rename/create filename editor: `EditorEvent::Blurred` arm moved out of the `subscribe_in` match onto `on_blur_by_user`.                                                 |
| `crates/project_panel/src/project_panel_tests.rs` | Repairs `test_rename_survives_window_deactivation`, which was vacuous. See "Findings".                                                                                  |
| `crates/collab_ui/src/collab_panel.rs`            | Channel rename editor: the whole `subscribe_in` (which only handled `Blurred`) becomes one `on_blur_by_user`.                                                           |
| `crates/go_to_line/src/go_to_line.rs`             | `Blurred` arm split out of `on_line_editor_event` into `on_line_editor_blur`, registered with `on_blur_by_user`.                                                        |
| `crates/picker/src/head.rs`                       | `Head::editor` gains a `blur_handler` parameter routed through `on_blur_by_user`; `Head::empty` switches from `on_blur` to `on_blur_by_user`.                           |
| `crates/picker/src/picker.rs`                     | `Blurred` arm removed from `on_input_editor_event`, replaced by `on_input_editor_blur`; both blur handlers lose their `is_window_active()` guard.                       |
| `crates/terminal_view/src/terminal_view.rs`       | Tab rename editor moved from `subscribe_in` to `on_blur_by_user`; its defer-and-recheck logic is kept verbatim.                                                         |
| `crates/ui_input/src/ui_input.rs`                 | Removes `ErasedEditorEvent::Blurred`, which became dead once the picker migrated, and documents why blur is deliberately not re-emitted here.                           |
| `crates/editor/src/editor.rs`                     | Drops the `EditorEvent::Blurred -> ErasedEditorEvent::Blurred` mapping line (falls through the existing `_ => return`).                                                 |
| `crates/workspace/src/modal_layer.rs`             | `show_modal`'s `cx.on_focus_out` becomes `cx.on_focus_out_by_user`.                                                                                                     |

13 files including this one.

## How each call site fit

**`crates/picker/src/head.rs` `Head::empty` - perfect fit.** One identifier changed, `on_blur` to `on_blur_by_user`, and the `window.is_window_active()` line inside `Picker::on_empty_head_blur` deleted. This is the only site that was already subscribing to a focus handle, and it is the shape the helper was designed for.

**`crates/workspace/src/modal_layer.rs` - perfect fit,** but only after I added `on_focus_out_by_user`. One identifier changed. This site is the reason the second constructor exists (see "Judgment calls").

**`crates/collab_ui/src/collab_panel.rs` - clean fit.** The `subscribe_in` existed solely to filter for `Blurred`, so the migration deletes a level of nesting and two early-return guards.

**`crates/go_to_line/src/go_to_line.rs` - clean fit,** at the cost of splitting one handler method into two and adding an entry to `_subscriptions`. The remaining `on_line_editor_event` handles only `BufferEdited`, so its `match` collapsed to an `if let` (also avoids `clippy::single_match`).

**`crates/project_panel/src/project_panel.rs` - acceptable fit, slightly awkward.** The editor subscription is a three-arm match (`BufferEdited`, `SelectionsChanged`, `Blurred`); pulling one arm out means the panel now has two subscriptions on the same editor for what a reader might think of as one concern, and the surviving closure's `window` parameter had to be renamed `_window`. The result is arguably clearer - the commit-on-blur logic is no longer buried in a match arm - but it is not a strict reduction in code.

**`crates/terminal_view/src/terminal_view.rs` - partial fit, and diagnostic.** This site was already correct by accident, because after deferring a frame it re-checks `!rename_editor.focus_handle(cx).is_focused(window)`, and `Window::focus` is _not_ cleared on deactivation, so that check is genuinely window-activation-independent. Migrating removed the `if let EditorEvent::Blurred` wrapper but kept the defer, the `still_current` check, and the `is_focused` re-check verbatim, because those solve a _different_ problem: a double-click transiently blurs and refocuses within the window. So the helper subsumes exactly one of this site's three guards. That is honest evidence that "did the user really leave?" is not a single question, and a one-predicate helper cannot answer all of it.

**`crates/picker/src/picker.rs` - the awkward one, and the riskiest.** The picker did not subscribe to a focus handle at all; it subscribed to `ErasedEditorEvent`, an erased re-emission of `EditorEvent::Blurred` that exists so `crates/picker` need not depend on `crates/editor`. The helper is invisible from behind that indirection. Making it fit required threading a second callback through `Head::editor` and deleting the `Blurred` variant from `ErasedEditorEvent` (the picker was its only consumer). That is the single place in this change where the convention became an actual constraint - a future `ui_input` consumer now _cannot_ hand-roll a blur subscription through the erased editor, because there is no blur event to subscribe to. It is also the change with the largest unverifiable blast radius, since every picker in the app goes through it.

## Judgment calls

1. **Two constructors, not one.** YAGNI argued for shipping only `on_blur_by_user`. I added `on_focus_out_by_user` because `modal_layer` is a concrete existing call site with a concrete latent bug, not a speculative future one: `ModalLayer::hide_modal` sets `dismiss_on_focus_lost = true` whenever a modal's `on_before_dismiss` returns `Dismiss(false)`, and `crates/file_finder/src/file_finder.rs:67` does exactly that while a submenu popover is focused. With that flag set, the old `on_focus_out` would hide the file finder when the user switched apps. Without the second constructor, `modal_layer` could not be migrated at all, and "does the abstraction fit the site the brief called the good prior art" would have gone unanswered.

2. **`on_blur` semantics, not `on_focus_out` semantics, for the five editor sites.** `EditorEvent::Blurred` is emitted from `cx.on_blur(&editor.focus_handle)`, i.e. "this exact handle stopped being the innermost focused". `on_focus_out` fires for a subtree and would _not_ fire when, say, an editor's completion menu takes focus. Using `on_blur_by_user` preserves current behavior exactly.

3. **Deleted `ErasedEditorEvent::Blurred` rather than leaving a dead variant.** After the picker migration nothing produced or consumed it usefully. Leaving it would have meant a permanently dead enum variant plus an `ErasedEditorEvent::Blurred => {}` arm in the picker. Cost: two extra files in the diff (`ui_input`, `editor`).

4. **Left `crates/ui/src/components/context_menu.rs` alone,** even though it has four raw `cx.on_blur` subscriptions. See "Findings" - dismiss-on-deactivation is _wanted_ there, and it was tried and reverted for unrelated reasons. Converting it would be a behavior change nobody asked for.

5. **Kept `is_modal` / `edit_state` / `pending_name` guards where they were.** The helper answers "did focus really leave?"; it deliberately does not try to own "should we then commit or cancel?".

6. **Repaired the existing regression test instead of leaving it green-but-meaningless.** The brief said to keep it passing; leaving a test that cannot fail would have misrepresented this variant's evidence.

## Findings (out of scope, reported not fixed)

**The regression test on the base branch is vacuous.** `TestWindow::is_active()` in `crates/gpui/src/platform/test/window.rs:205` is hardcoded `false`, and `Window::new` seeds `active` from it (`crates/gpui/src/window.rs:1175`). Nothing activates a test window unless the test calls `window.activate_window()` explicitly, as `crates/zed/src/zed.rs:5282` does. So in `test_rename_survives_window_deactivation`, `VisualTestContext::deactivate_window` (`crates/gpui/src/app/test_context.rs:878`) hits its `if Some(self.window) == self.test_platform.active_window()` guard, does nothing, no blur is ever emitted, and the assertion passes with or without the fix. The test now activates the window first and asserts both that the window is active and that the filename editor holds focus before deactivating, so it can actually fail. **Any variant of this fix that relies on that test as evidence should re-check this.**

**Window deactivation is sometimes a legitimate reason to dismiss.** PR #46866 deliberately made context menus close on deactivation via `observe_window_activation`, and #47044 tried to preserve and restore focus across activation cycles; both were reverted together in `ade8749537` ("Fix typing emoji") because they broke the macOS system emoji palette. Two lessons: dismiss-on-deactivation is a real requirement for some controls, so the right design keeps "focus moved" and "window went away" separately expressible rather than merging them; and globally changing focus behavior across activation has already blown up once in this codebase, which is a point in favor of this variant's conservatism and against any variant that changes `WindowFocusEvent` synthesis.

**`crates/workspace/src/modal_layer.rs` is not the good prior art the brief assumes.** Its `on_focus_out` handler is not window-activation-aware at all. It looks correct only because `dismiss_on_focus_lost` is `false` in the common case, so the handler is usually a no-op. The actual prior art for the correct pattern is the `window.is_window_active()` guard added to `crates/picker/src/picker.rs` in #41320.

**Dead commented-out code** at `crates/picker/src/head.rs:37-43` (an old `cx.subscribe_in` call). Left untouched to keep the diff focused.

## Weaknesses - read this part

**This is a convention, not a constraint, and mostly it stays one.** `cx.on_blur` and `cx.on_focus_out` still exist, still compile, and still do the wrong thing for any control that cancels on blur. `EditorEvent::Blurred` still exists and still fires on window deactivation, and there are twelve other subscribers to it that this change does not touch (`crates/vim/src/vim.rs:1093`, `crates/search/src/buffer_search.rs:1399`, `crates/agent_ui/src/inline_prompt_editor.rs:469`, `crates/diagnostics/src/diagnostics.rs:249`, `crates/rules_library/src/rules_library.rs:1028`, and others). Most of those are harmless - they toggle a boolean or hide a popover - but nothing in this change _tells_ the next contributor that. A new panel with a rename field, written by copying the collab panel from before this commit, is exactly as broken as it was. What was actually bought:

- Three doc warnings that appear in autocomplete and rustdoc at the moment of choosing. Real, but easy to skim past.
- One genuine constraint, at `ErasedEditorEvent`: a `ui_input` consumer can no longer subscribe to blur, because the event is gone. This closes the bug class for that one channel only.
- Six call sites that now demonstrate the correct pattern rather than the guard-after-the-fact pattern.

If the goal is "no future contributor can reintroduce this bug", this variant does not achieve it and cannot, short of removing or renaming `on_blur` - which would be a large, mechanical, and separately reviewable change (`cx.on_blur` has ~10 call sites outside gpui, but the equivalent surgery on `EditorEvent::Blurred` touches a dozen crates). The honest claim is narrower: it makes the correct pattern _cheaper to write than the incorrect one_ at the sites that matter, and leaves a trail of six examples plus three doc warnings for the next person. That is a real reduction in expected future bugs, not an elimination.

**The predicate is coarser than its name.** `on_blur_by_user` fires for _any_ focus move inside an active window, including one made programmatically by a background task; and it suppresses genuine user-initiated blur that happens while the window is inactive (a click on an inactive window can move focus before activation lands, depending on platform). Naming it `by_user` states intent, not mechanism. `on_blur_while_window_active` would be honest and unusable as guidance. I chose intent and documented the mechanism.

**Merging is not the same as fixing.** Because the helper is `is_window_active()` in a wrapper, it inherits every property of the hand-written guards, including that GPUI still blanks the focus path on deactivation. Anything that observes focus paths directly - `contains_focused`, `within_focused`, custom `new_focus_listener` users - still sees the blanked path and is unaffected by this change. This variant does not fix the underlying conflation; it makes it survivable at the sites that care.

**The five editor migrations change callback ordering, and I could not verify it.** Previously the handlers ran as `EditorEvent::Blurred` subscribers, which fire during GPUI's effect flush, _after_ all focus listeners for that frame. They now run as focus listeners, synchronously inside `focus_listeners.retain(...)` in `Window::draw`, immediately after the editor's own `handle_blur`. Registration order means they still run after the editor's internal cleanup, but they now run _before_ other focus listeners registered later - most notably `ModalLayer`'s. For the picker that means `Picker::cancel` (and the `DismissEvent` it emits) now runs earlier relative to modal-layer bookkeeping and focus restoration. I reasoned through the modal-open path and expect no difference in outcome, since both paths converge on the same effect flush, but this is the single change I would most want exercised by hand in a real build: open the command palette, the file finder, and a file-finder submenu, and confirm dismissal and focus restoration still behave.

**Nothing here was compiled.** Per the task constraints I ran no `cargo` command. Specific things a compiler would catch that I checked only by reading: the two-phase borrow in `cx.on_blur_by_user(&editor.focus_handle(cx), ...)` (precedent: the pre-existing `cx.on_blur(&head.focus_handle(cx), ...)` in `crates/picker/src/head.rs`); `Focusable` being in scope in each migrated file (verified by grep, each file already called `.focus_handle(cx)`); the new `#[cfg(test)] mod tests` in `crates/gpui/src/app/context.rs` importing `TestAppContext` and `add_window_view` (modelled on the existing test in `crates/gpui/src/elements/uniform_list.rs:709`); and clippy's `single_match` on the reduced matches.

**The two new gpui tests are the least-verified code in the change.** They assert that `on_blur` fires and `on_blur_by_user` does not when `deactivate_window()` is called, and that both fire on an in-window focus move. The logic follows from reading `Window::draw`, but the test scaffolding (does a window with two `track_focus` divs produce the focus paths I expect after `run_until_parked`?) is exactly the kind of thing that is obvious once run and easy to get subtly wrong on paper. If CI fails, look here first.

## Suggested `.rules` addition (not applied, per the repo's rules-hygiene policy)

Proposed for `crates/gpui/.rules`:

> Do not use `cx.on_blur` / `cx.on_focus_out` / `EditorEvent::Blurred` to cancel, dismiss, or commit in-progress user input. Window deactivation blanks the window's focus path, so those fire when the user merely switches apps - or, on Wayland, switches keyboard layout - and the control destroys what the user typed. Use `cx.on_blur_by_user` / `cx.on_focus_out_by_user`. If the control genuinely should also react to the window going away, say so separately with `cx.observe_window_activation`.

Proposed for `crates/gpui/.rules` (second, independent rule):

> Test windows start inactive: `TestWindow::is_active()` returns `false` and nothing activates a window implicitly. A test that calls `cx.deactivate_window()` without first calling `window.activate_window()` and running until parked is a no-op and proves nothing.

package app.marginalia.readium

import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem

/**
 * The menu shown over selected text: Highlight, Note, Share, Define, Who's this?, Explain,
 * Translate and Copy. Picking one hands the
 * action to [onAction] (which reads the selection from the navigator) and closes the menu.
 * [onActiveChanged] reports when a selection starts and ends, so Flutter can hand every
 * touch to the page while handles are being dragged.
 */
class SelectionMenu(
    private val onAction: (String) -> Unit,
    private val onActiveChanged: (Boolean) -> Unit,
) : ActionMode.Callback {

    private val actions = listOf(
        "highlight" to "Highlight",
        "note" to "Note",
        "share" to "Share",
        "define" to "Define",
        "who" to "Who's this?",
        "explain" to "Explain",
        "translate" to "Translate",
        "copy" to "Copy",
    )

    /**
     * The menus open now. A WebView can start a new one for a changed selection before the old
     * one is gone, so the selection is active while any is open, not just after the last start.
     */
    private val open = mutableSetOf<ActionMode>()

    private fun report() {
        val active = open.isNotEmpty()
        if (active != reported) {
            reported = active
            onActiveChanged(active)
        }
    }

    private var reported = false

    val isOpen: Boolean get() = open.isNotEmpty()

    /** Closes the menu (the selection was cleared from outside it, so it would linger). */
    fun finish() {
        open.toList().forEach { runCatching { it.finish() } }
        open.clear()
        report()
    }

    override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
        open += mode
        report()
        menu.clear()
        actions.forEachIndexed { index, (_, title) ->
            // The first few stay in view; the rest go to the menu's overflow when space runs out.
            menu.add(Menu.NONE, index + 1, index, title)
                .setShowAsAction(if (index < 3) MenuItem.SHOW_AS_ACTION_ALWAYS else MenuItem.SHOW_AS_ACTION_IF_ROOM)
        }
        return true
    }

    override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean = false

    override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
        val action = actions.getOrNull(item.itemId - 1)?.first ?: return false
        onAction(action)
        mode.finish()
        return true
    }

    override fun onDestroyActionMode(mode: ActionMode) {
        open -= mode
        report()
    }
}

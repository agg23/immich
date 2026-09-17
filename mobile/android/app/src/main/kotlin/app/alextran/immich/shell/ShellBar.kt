package app.alextran.immich.shell

import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp

/**
 * The bar Dart published for a route, drawn as a Material top app bar. Taps go back over the
 * channel by index; Dart resolves them against the bar it last published.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShellTopBar(
  route: String,
  title: String,
  actions: List<Map<String, Any?>>,
  hero: Boolean = false,
  collapsed: Boolean = false,
  heroProgress: Float = 0f,
  onBack: (() -> Unit)? = null,
  scrollBehavior: TopAppBarScrollBehavior? = null,
) {
  // Dart reports both the crossing and the fraction; the fraction is what a Material bar wants.
  val solid = if (hero) heroProgress.coerceIn(0f, 1f) else 1f
  val defaults = TopAppBarDefaults.topAppBarColors()
  val colors = if (hero) {
    TopAppBarDefaults.topAppBarColors(
      containerColor = lerp(Color.Transparent, defaults.containerColor, solid),
      titleContentColor = defaults.titleContentColor.copy(alpha = solid),
      navigationIconContentColor = lerp(Color.White, defaults.navigationIconContentColor, solid),
      actionIconContentColor = lerp(Color.White, defaults.actionIconContentColor, solid),
    )
  } else {
    defaults
  }
  TopAppBar(
    title = { Text(title) },
    navigationIcon = {
      if (onBack != null) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = null) }
      }
    },
    actions = { BarActions(route, actions) },
    colors = colors,
    scrollBehavior = scrollBehavior,
  )
}

/** The actions of a published bar, for a bar drawn by something other than [ShellTopBar]. */
@Composable
fun BarActions(route: String, actions: List<Map<String, Any?>>) {
  actions.forEachIndexed { index, raw -> BarAction(route, index, raw) }
}

/**
 * The search tab's field: Material's docked search bar, submit-driven like the Flutter field it
 * replaces. Nothing is searched until the keyboard's search key, and clearing submits empty.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShellSearchBar(modifier: Modifier = Modifier) {
  val text = ShellBridge.searchText
  val focus = LocalFocusManager.current
  val keyboard = LocalSoftwareKeyboardController.current
  SearchBar(
    inputField = {
      SearchBarDefaults.InputField(
        query = text,
        onQueryChange = { ShellBridge.searchText = it },
        onSearch = {
          keyboard?.hide()
          focus.clearFocus()
          ShellBridge.submitSearch(it)
        },
        expanded = false,
        onExpandedChange = {},
        placeholder = { Text(ShellBridge.searchPlaceholder ?: "") },
        leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) },
        trailingIcon = {
          if (text.isNotEmpty()) {
            IconButton(onClick = {
              ShellBridge.searchText = ""
              ShellBridge.submitSearch("")
            }) { Icon(Icons.Rounded.Close, contentDescription = null) }
          }
        },
      )
    },
    expanded = false,
    onExpandedChange = {},
    modifier = modifier,
  ) {}
}

@Composable
private fun BarAction(route: String, index: Int, raw: Map<String, Any?>) {
  val enabled = raw["enabled"] as? Boolean ?: true
  val icon = ShellIcon.from(raw["icon"])
  val label = raw["label"] as? String
  @Suppress("UNCHECKED_CAST")
  val menu = raw["menu"] as? List<Map<String, Any?>>

  if (menu != null) {
    var expanded by remember { mutableStateOf(false) }
    Box {
      if (icon != null) {
        IconButton(onClick = { expanded = true }, enabled = enabled) { Icon(icon.image, contentDescription = label) }
      } else {
        TextButton(onClick = { expanded = true }, enabled = enabled) { Text(label ?: "") }
      }
      BarMenu(route, index, menu, expanded) { expanded = false }
    }
    return
  }
  val fire = {
    shellLog("[shell:nav] bar action $route #$index")
    ShellBridge.barAction(route, index, -1)
  }
  if (icon != null) {
    IconButton(onClick = fire, enabled = enabled) { Icon(icon.image, contentDescription = label) }
  } else if (label != null) {
    TextButton(onClick = fire, enabled = enabled) { Text(label) }
  }
}

/** Destructive rows sit below a divider in the error colour: Android's grouping, not iOS's. */
@Composable
private fun BarMenu(route: String, index: Int, rows: List<Map<String, Any?>>, expanded: Boolean, dismiss: () -> Unit) {
  val indexed = rows.withIndex()
  val ordinary = indexed.filter { it.value["destructive"] != true }
  val destructive = indexed.filter { it.value["destructive"] == true }
  DropdownMenu(expanded = expanded, onDismissRequest = dismiss) {
    for ((row, raw) in ordinary) MenuRow(route, index, row, raw, destructive = false, dismiss)
    if (destructive.isNotEmpty()) {
      if (ordinary.isNotEmpty()) HorizontalDivider()
      for ((row, raw) in destructive) MenuRow(route, index, row, raw, destructive = true, dismiss)
    }
  }
}

@Composable
private fun MenuRow(route: String, index: Int, row: Int, raw: Map<String, Any?>, destructive: Boolean, dismiss: () -> Unit) {
  val icon = ShellIcon.from(raw["icon"])
  val error = MaterialTheme.colorScheme.error
  DropdownMenuItem(
    text = { Text(raw["label"] as? String ?: "") },
    onClick = {
      dismiss()
      shellLog("[shell:nav] bar menu $route #$index row $row")
      ShellBridge.barAction(route, index, row)
    },
    leadingIcon = icon?.let { { Icon(it.image, contentDescription = null) } },
    // A selected row is the current choice in a single-select menu, such as the search type.
    trailingIcon = if (raw["selected"] == true) ({ Icon(Icons.Rounded.Check, contentDescription = null) }) else null,
    enabled = raw["enabled"] as? Boolean ?: true,
    colors = if (destructive) {
      MenuDefaults.itemColors(textColor = error, leadingIconColor = error)
    } else {
      MenuDefaults.itemColors()
    },
  )
}
